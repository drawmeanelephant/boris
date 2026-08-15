//! Portable cryptographic and wire-format primitives for AT Protocol OAuth.
//!
//! This module deliberately has no HTTP, filesystem, process, wall-clock, or
//! ambient-randomness dependency. Host applications provide entropy, time,
//! transport, callback, and session storage at their own boundary. That keeps
//! the protocol core reusable by Boris, freestanding targets, and other Zig
//! systems without smuggling a host runtime into the trust boundary.

const std = @import("std");
const json_out = @import("json_out.zig");

pub const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
pub const KeyPair = Scheme.KeyPair;
pub const PublicKey = Scheme.PublicKey;

pub const verifier_length = std.base64.url_safe_no_pad.Encoder.calcSize(32);
pub const digest_encoded_length = std.base64.url_safe_no_pad.Encoder.calcSize(32);
pub const max_htu_length = 2048;
pub const max_nonce_length = 1024;
pub const max_access_token_length = 16 * 1024;

pub const Error = std.mem.Allocator.Error || error{
    IdentityElement,
    InvalidAccessToken,
    InvalidHtu,
    InvalidJti,
    InvalidMethod,
    InvalidNonce,
    InvalidPkceVerifier,
    NoSpaceLeft,
    NonCanonical,
    TimestampOutOfRange,
};

pub const Pkce = struct {
    verifier: [verifier_length]u8,
    challenge: [digest_encoded_length]u8,
};

pub const Jwk = struct {
    x: [digest_encoded_length]u8,
    y: [digest_encoded_length]u8,
};

pub const DpopInput = struct {
    method: []const u8,
    target_uri: []const u8,
    issued_at: u64,
    jti: []const u8,
    nonce: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
};

/// Derive a P-256 key pair from 32 bytes supplied by a cryptographically
/// secure host entropy source. A session keeps this key for its whole life.
pub fn keyPairFromEntropy(entropy: [Scheme.KeyPair.seed_length]u8) Error!KeyPair {
    return Scheme.KeyPair.generateDeterministic(entropy);
}

/// Produce the RFC 7636 verifier and S256 challenge from host entropy.
pub fn pkceFromEntropy(entropy: [32]u8) Pkce {
    var verifier: [verifier_length]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &entropy);
    return .{
        .verifier = verifier,
        .challenge = pkceChallenge(&verifier) catch unreachable,
    };
}

/// Compute an S256 challenge for a caller-provided RFC 7636 verifier.
pub fn pkceChallenge(verifier: []const u8) Error![digest_encoded_length]u8 {
    if (verifier.len < 43 or verifier.len > 128) return error.InvalidPkceVerifier;
    for (verifier) |byte| {
        if (!isUnreserved(byte)) return error.InvalidPkceVerifier;
    }
    return hashEncoded(verifier);
}

/// Produce a base64url identifier suitable for OAuth state or a DPoP `jti`.
/// Callers must supply fresh host entropy for every value.
pub fn identifierFromEntropy(entropy: [32]u8) [digest_encoded_length]u8 {
    var encoded: [digest_encoded_length]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &entropy);
    return encoded;
}

pub fn publicJwk(public_key: PublicKey) Jwk {
    const sec1 = public_key.toUncompressedSec1();
    std.debug.assert(sec1[0] == 0x04);
    var x: [digest_encoded_length]u8 = undefined;
    var y: [digest_encoded_length]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&x, sec1[1..33]);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&y, sec1[33..65]);
    return .{ .x = x, .y = y };
}

/// Return the RFC 7638 SHA-256 thumbprint of a public EC JWK.
pub fn jwkThumbprint(allocator: std.mem.Allocator, public_key: PublicKey) Error![digest_encoded_length]u8 {
    const jwk = publicJwk(public_key);
    var canonical: std.ArrayList(u8) = .empty;
    defer canonical.deinit(allocator);

    // RFC 7638 requires the members in Unicode code-point order.
    try canonical.appendSlice(allocator, "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":");
    try json_out.writeString(&canonical, allocator, &jwk.x);
    try canonical.appendSlice(allocator, ",\"y\":");
    try json_out.writeString(&canonical, allocator, &jwk.y);
    try canonical.append(allocator, '}');
    return hashEncoded(canonical.items);
}

/// Base64url(SHA-256(access-token)), for the DPoP `ath` claim.
pub fn accessTokenHash(access_token: []const u8) Error![digest_encoded_length]u8 {
    if (access_token.len == 0 or access_token.len > max_access_token_length) return error.InvalidAccessToken;
    return hashEncoded(access_token);
}

/// Return the request URI used by the DPoP `htu` claim. Query and fragment
/// components are excluded. The caller remains responsible for full endpoint
/// discovery and transport policy; this function enforces an unambiguous,
/// normalized ASCII HTTP(S) shape at the signing boundary.
pub fn canonicalHtu(target_uri: []const u8) Error![]const u8 {
    if (target_uri.len == 0 or target_uri.len > max_htu_length) return error.InvalidHtu;
    const scheme_len: usize = if (std.mem.startsWith(u8, target_uri, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, target_uri, "http://"))
        "http://".len
    else
        return error.InvalidHtu;

    const parsed = std.Uri.parse(target_uri) catch return error.InvalidHtu;
    if (parsed.host == null or parsed.user != null or parsed.password != null) return error.InvalidHtu;

    var end = target_uri.len;
    if (std.mem.indexOfAny(u8, target_uri, "?#")) |at| end = at;
    const htu = target_uri[0..end];
    if (htu.len == scheme_len) return error.InvalidHtu;

    const authority_end = std.mem.indexOfScalarPos(u8, htu, scheme_len, '/') orelse htu.len;
    const authority = htu[scheme_len..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidHtu;

    var i: usize = 0;
    while (i < htu.len) : (i += 1) {
        const byte = htu[i];
        if (byte <= 0x20 or byte >= 0x7f or byte == '\\') return error.InvalidHtu;
        if (byte == '%') {
            if (i + 2 >= htu.len or !std.ascii.isHex(htu[i + 1]) or !std.ascii.isHex(htu[i + 2])) return error.InvalidHtu;
            i += 2;
        }
    }
    return htu;
}

/// Build and ES256-sign one DPoP proof. `signing_noise` must be fresh host
/// entropy; requiring it in the API prevents a production caller from
/// accidentally falling back to deterministic ECDSA signatures.
pub fn buildDpopProof(
    allocator: std.mem.Allocator,
    key_pair: KeyPair,
    input: DpopInput,
    signing_noise: [Scheme.noise_length]u8,
) Error![]u8 {
    const htu = try canonicalHtu(input.target_uri);
    var method_buf: [16]u8 = undefined;
    const method = try normalizedMethod(&method_buf, input.method);
    if (!validJti(input.jti)) return error.InvalidJti;
    if (input.issued_at > std.math.maxInt(usize)) return error.TimestampOutOfRange;
    if (input.nonce) |nonce| {
        if (!validNonce(nonce)) return error.InvalidNonce;
    }

    const jwk = publicJwk(key_pair.public_key);
    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(allocator);
    try header.appendSlice(allocator, "{\"typ\":\"dpop+jwt\",\"alg\":\"ES256\",\"jwk\":{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":");
    try json_out.writeString(&header, allocator, &jwk.x);
    try header.appendSlice(allocator, ",\"y\":");
    try json_out.writeString(&header, allocator, &jwk.y);
    try header.appendSlice(allocator, "}}");

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"jti\":");
    try json_out.writeString(&payload, allocator, input.jti);
    try payload.appendSlice(allocator, ",\"htm\":");
    try json_out.writeString(&payload, allocator, method);
    try payload.appendSlice(allocator, ",\"htu\":");
    try json_out.writeString(&payload, allocator, htu);
    try payload.appendSlice(allocator, ",\"iat\":");
    try json_out.writeUsize(&payload, allocator, @intCast(input.issued_at));
    if (input.nonce) |nonce| {
        try payload.appendSlice(allocator, ",\"nonce\":");
        try json_out.writeString(&payload, allocator, nonce);
    }
    if (input.access_token) |token| {
        const ath = try accessTokenHash(token);
        try payload.appendSlice(allocator, ",\"ath\":");
        try json_out.writeString(&payload, allocator, &ath);
    }
    try payload.append(allocator, '}');

    const header_encoded = try base64Alloc(allocator, header.items);
    defer allocator.free(header_encoded);
    const payload_encoded = try base64Alloc(allocator, payload.items);
    defer allocator.free(payload_encoded);

    var signing_input: std.ArrayList(u8) = .empty;
    defer signing_input.deinit(allocator);
    try signing_input.appendSlice(allocator, header_encoded);
    try signing_input.append(allocator, '.');
    try signing_input.appendSlice(allocator, payload_encoded);

    const signature = try key_pair.sign(signing_input.items, signing_noise);
    const signature_bytes = signature.toBytes();
    const signature_encoded = try base64Alloc(allocator, &signature_bytes);
    defer allocator.free(signature_encoded);

    var proof: std.ArrayList(u8) = .empty;
    errdefer proof.deinit(allocator);
    try proof.appendSlice(allocator, signing_input.items);
    try proof.append(allocator, '.');
    try proof.appendSlice(allocator, signature_encoded);
    return proof.toOwnedSlice(allocator);
}

fn hashEncoded(value: []const u8) [digest_encoded_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    var encoded: [digest_encoded_length]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &digest);
    return encoded;
}

fn base64Alloc(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(value.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, value);
    return out;
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn validJti(jti: []const u8) bool {
    if (jti.len < 16 or jti.len > 128) return false;
    for (jti) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return true;
}

fn validNonce(nonce: []const u8) bool {
    if (nonce.len == 0 or nonce.len > max_nonce_length) return false;
    for (nonce) |byte| {
        if (!(byte == 0x21 or (byte >= 0x23 and byte <= 0x5b) or (byte >= 0x5d and byte <= 0x7e))) return false;
    }
    return true;
}

fn normalizedMethod(out: *[16]u8, method: []const u8) Error![]const u8 {
    if (method.len == 0 or method.len > out.len) return error.InvalidMethod;
    for (method, 0..) |byte, i| {
        if (!std.ascii.isAlphabetic(byte)) return error.InvalidMethod;
        out[i] = std.ascii.toUpper(byte);
    }
    return out[0..method.len];
}

fn decodeSegment(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, len);
    errdefer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded);
    return decoded;
}

test "RFC 7636 S256 challenge vector" {
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = try pkceChallenge(verifier);
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &challenge);
    try std.testing.expectError(error.InvalidPkceVerifier, pkceChallenge("short"));
    try std.testing.expectError(error.InvalidPkceVerifier, pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r/wW1gFWFOEjXk"));
}

test "entropy helpers produce bounded base64url values" {
    var entropy: [32]u8 = undefined;
    for (&entropy, 0..) |*byte, i| byte.* = @intCast(i);
    const pkce = pkceFromEntropy(entropy);
    const identifier = identifierFromEntropy(entropy);
    try std.testing.expectEqual(@as(usize, 43), pkce.verifier.len);
    try std.testing.expectEqualStrings(&pkce.verifier, &identifier);
    _ = try pkceChallenge(&pkce.verifier);
}

test "RFC 9449 example public key has the published JWK thumbprint" {
    var x: [32]u8 = undefined;
    var y: [32]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&x, "l8tFrhx-34tV3hRICRDY9zCkDlpBhF42UQUfWVAWBFs");
    try std.base64.url_safe_no_pad.Decoder.decode(&y, "9VE4jf_Ok_o64zbTTlcuNJajHmt6v9TDVrU0CdvGRDA");
    var sec1: [PublicKey.uncompressed_sec1_encoded_length]u8 = undefined;
    sec1[0] = 0x04;
    @memcpy(sec1[1..33], &x);
    @memcpy(sec1[33..65], &y);
    const public_key = try PublicKey.fromSec1(&sec1);
    const thumbprint = try jwkThumbprint(std.testing.allocator, public_key);
    try std.testing.expectEqualStrings("0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I", &thumbprint);
}

test "DPoP proof has canonical claims and a raw ES256 signature" {
    const key_pair = try keyPairFromEntropy([_]u8{0x41} ** Scheme.KeyPair.seed_length);
    const input: DpopInput = .{
        .method = "post",
        .target_uri = "https://server.example.com/token?ignored=yes#fragment",
        .issued_at = 1_562_262_616,
        .jti = "0123456789abcdef",
        .nonce = "nonce-value",
        .access_token = "access-token",
    };
    const noise = [_]u8{0x93} ** Scheme.noise_length;
    const proof = try buildDpopProof(std.testing.allocator, key_pair, input, noise);
    defer std.testing.allocator.free(proof);
    const repeated = try buildDpopProof(std.testing.allocator, key_pair, input, noise);
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(proof, repeated);

    var parts = std.mem.splitScalar(u8, proof, '.');
    const header_encoded = parts.next().?;
    const payload_encoded = parts.next().?;
    const signature_encoded = parts.next().?;
    try std.testing.expect(parts.next() == null);

    const header = try decodeSegment(std.testing.allocator, header_encoded);
    defer std.testing.allocator.free(header);
    const payload = try decodeSegment(std.testing.allocator, payload_encoded);
    defer std.testing.allocator.free(payload);
    const signature_bytes = try decodeSegment(std.testing.allocator, signature_encoded);
    defer std.testing.allocator.free(signature_bytes);

    try std.testing.expect(std.mem.indexOf(u8, header, "\"typ\":\"dpop+jwt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\"alg\":\"ES256\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\"d\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"htm\":\"POST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"htu\":\"https://server.example.com/token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "ignored") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "fragment") == null);
    const ath = try accessTokenHash("access-token");
    try std.testing.expect(std.mem.indexOf(u8, payload, &ath) != null);
    try std.testing.expectEqual(@as(usize, Scheme.Signature.encoded_length), signature_bytes.len);

    var raw_signature: [Scheme.Signature.encoded_length]u8 = undefined;
    @memcpy(&raw_signature, signature_bytes);
    const signature = Scheme.Signature.fromBytes(raw_signature);
    const signing_end = header_encoded.len + 1 + payload_encoded.len;
    try signature.verify(proof[0..signing_end], key_pair.public_key);
}

test "signing boundary rejects ambiguous request values" {
    const key_pair = try keyPairFromEntropy([_]u8{0x21} ** Scheme.KeyPair.seed_length);
    const noise = [_]u8{0x52} ** Scheme.noise_length;
    const base: DpopInput = .{
        .method = "POST",
        .target_uri = "https://example.com/token",
        .issued_at = 1_700_000_000,
        .jti = "0123456789abcdef",
    };

    var input = base;
    input.method = "PO ST";
    try std.testing.expectError(error.InvalidMethod, buildDpopProof(std.testing.allocator, key_pair, input, noise));
    input = base;
    input.target_uri = "https://user@example.com/token";
    try std.testing.expectError(error.InvalidHtu, buildDpopProof(std.testing.allocator, key_pair, input, noise));
    input = base;
    input.target_uri = "file:///token";
    try std.testing.expectError(error.InvalidHtu, buildDpopProof(std.testing.allocator, key_pair, input, noise));
    input = base;
    input.target_uri = "https://example.com:not-a-port/token";
    try std.testing.expectError(error.InvalidHtu, buildDpopProof(std.testing.allocator, key_pair, input, noise));
    input = base;
    input.target_uri = "https://[::1/token";
    try std.testing.expectError(error.InvalidHtu, buildDpopProof(std.testing.allocator, key_pair, input, noise));
    input = base;
    input.jti = "too-short";
    try std.testing.expectError(error.InvalidJti, buildDpopProof(std.testing.allocator, key_pair, input, noise));
    input = base;
    input.nonce = "has a space";
    try std.testing.expectError(error.InvalidNonce, buildDpopProof(std.testing.allocator, key_pair, input, noise));
}
