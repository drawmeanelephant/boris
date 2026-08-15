//! Portable one-shot AT Protocol OAuth authorization-code flow.
//!
//! The host supplies a previously validated account, fresh entropy and DPoP
//! proof material, a bounded transport, and an exact IPv4 loopback redirect.
//! This module owns PAR, callback binding, and token exchange, but no sockets,
//! browser process, clock, ambient randomness, persistence, or publication.

const std = @import("std");
const identity = @import("atproto_identity.zig");
const oauth = @import("atproto_oauth.zig");
const transport = @import("atproto_transport.zig");

pub const requested_scope = "atproto include:site.standard.authFull";
pub const callback_path = "/oauth/callback";
pub const par_limits: transport.Limits = .{ .max_body_bytes = 16 * 1024 };
pub const token_limits: transport.Limits = .{ .max_body_bytes = 64 * 1024 };
pub const max_callback_target_bytes = 8 * 1024;

pub const Error = transport.Error || oauth.Error || std.mem.Allocator.Error || error{
    AuthorizationDenied,
    CallbackAlreadyConsumed,
    CallbackMalformed,
    CodeAlreadyConsumed,
    DpopNonceMissing,
    DpopNonceRepeated,
    InvalidClientId,
    InvalidContentType,
    InvalidGrant,
    InvalidIssuer,
    InvalidLoopbackRedirect,
    InvalidParResponse,
    InvalidScope,
    InvalidTokenResponse,
    OAuthRequestFailed,
    ProofUnavailable,
    InvalidWallClock,
    StateMismatch,
    UnexpectedStatus,
};

pub const SessionEntropy = struct {
    key_seed: [oauth.Scheme.KeyPair.seed_length]u8,
    pkce: [32]u8,
    state: [32]u8,
};

pub const ProofMaterial = struct {
    issued_at: u64,
    jti_entropy: [32]u8,
    signing_noise: [oauth.Scheme.noise_length]u8,
};

pub const ProofSource = struct {
    context: *anyopaque,
    next_fn: *const fn (*anyopaque) Error!ProofMaterial,

    pub fn next(source: ProofSource) Error!ProofMaterial {
        return source.next_fn(source.context);
    }
};

const Phase = enum { waiting_callback, ready_for_token, consumed };
const ClientId = Fixed(2048);
const RedirectUri = Fixed(256);
const RequestUri = Fixed(2048);
const Nonce = Fixed(oauth.max_nonce_length);
const AuthorizationCode = Fixed(2048);
const Token = Fixed(oauth.max_access_token_length);
const Scope = Fixed(4096);

pub const PendingAuthorization = struct {
    account: identity.DiscoveredAccount,
    key_pair: oauth.KeyPair,
    verifier: [oauth.verifier_length]u8,
    state: [oauth.digest_encoded_length]u8,
    redirect_uri: RedirectUri,
    client_id: ClientId,
    request_uri: RequestUri,
    request_uri_expires_in: u64,
    authorization_server_nonce: Nonce,
    authorization_code: AuthorizationCode = .{},
    phase: Phase = .waiting_callback,

    pub fn browserUrl(pending: *const PendingAuthorization, allocator: std.mem.Allocator) Error![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.appendSlice(allocator, pending.account.authorization_endpoint.slice());
        try result.append(allocator, if (std.mem.indexOfScalar(u8, pending.account.authorization_endpoint.slice(), '?') == null) '?' else '&');
        try appendFormPair(&result, allocator, "client_id", pending.client_id.slice());
        try result.append(allocator, '&');
        try appendFormPair(&result, allocator, "request_uri", pending.request_uri.slice());
        if (result.items.len > transport.max_url_bytes) return error.InvalidParResponse;
        return result.toOwnedSlice(allocator);
    }

    /// Consume exactly one callback request target. Any attempt, including a
    /// malformed or hostile one, burns this authorization attempt.
    pub fn acceptCallback(pending: *PendingAuthorization, target: []const u8) Error!void {
        if (pending.phase != .waiting_callback) return error.CallbackAlreadyConsumed;
        pending.phase = .consumed;
        if (target.len == 0 or target.len > max_callback_target_bytes) return error.CallbackMalformed;
        const question = std.mem.indexOfScalar(u8, target, '?') orelse return error.CallbackMalformed;
        if (!std.mem.eql(u8, target[0..question], callback_path)) return error.CallbackMalformed;
        if (std.mem.indexOfScalar(u8, target, '#') != null) return error.CallbackMalformed;

        var values = CallbackValues{};
        var pairs = std.mem.splitScalar(u8, target[question + 1 ..], '&');
        var pair_count: usize = 0;
        while (pairs.next()) |pair| {
            pair_count += 1;
            if (pair_count > 16 or pair.len == 0) return error.CallbackMalformed;
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return error.CallbackMalformed;
            var decoded: [2048]u8 = undefined;
            const value = try formDecode(&decoded, pair[equals + 1 ..]);
            const name = pair[0..equals];
            if (std.mem.eql(u8, name, "state")) {
                if (values.state_present) return error.CallbackMalformed;
                try values.state.set(value);
                values.state_present = true;
            } else if (std.mem.eql(u8, name, "iss")) {
                if (values.issuer_present) return error.CallbackMalformed;
                try values.issuer.set(value);
                values.issuer_present = true;
            } else if (std.mem.eql(u8, name, "code")) {
                if (values.code_present) return error.CallbackMalformed;
                try values.code.set(value);
                values.code_present = true;
            } else if (std.mem.eql(u8, name, "error")) {
                if (values.error_present) return error.CallbackMalformed;
                try values.oauth_error.set(value);
                values.error_present = true;
            }
        }
        if (!values.state_present or !values.issuer_present) return error.CallbackMalformed;
        if (!constantTimeEqual(values.state.slice(), &pending.state)) return error.StateMismatch;
        if (!std.mem.eql(u8, values.issuer.slice(), pending.account.authorization_server_origin.slice())) return error.InvalidIssuer;
        if (values.error_present and values.code_present) return error.CallbackMalformed;
        if (values.error_present) return error.AuthorizationDenied;
        if (!values.code_present or values.code.slice().len == 0) return error.CallbackMalformed;
        try pending.authorization_code.set(values.code.slice());
        pending.phase = .ready_for_token;
    }

    /// Exchange the accepted code once. Success or failure burns the code.
    pub fn exchange(
        pending: *PendingAuthorization,
        allocator: std.mem.Allocator,
        client: transport.Client,
        proofs: ProofSource,
    ) Error!AuthorizedSession {
        if (pending.phase != .ready_for_token) return error.CodeAlreadyConsumed;
        pending.phase = .consumed;

        const body = try buildTokenBody(allocator, pending);
        defer {
            secureZero(body);
            allocator.free(body);
        }
        var nonce = pending.authorization_server_nonce;
        var response = try postWithProof(
            allocator,
            client,
            proofs,
            pending.key_pair,
            pending.account.token_endpoint.slice(),
            body,
            nonce.slice(),
            token_limits,
        );
        defer {
            secureZero(response.body);
            response.deinit();
        }
        const first_nonce = try requiredNonce(response);
        try nonce.set(first_nonce);
        if (response.status == 400) try requireJson(response);
        if (response.status == 400 and isUseDpopNonce(allocator, response.body)) {
            secureZero(response.body);
            response.deinit();
            response = try postWithProof(
                allocator,
                client,
                proofs,
                pending.key_pair,
                pending.account.token_endpoint.slice(),
                body,
                nonce.slice(),
                token_limits,
            );
            const retry_nonce = try requiredNonce(response);
            try nonce.set(retry_nonce);
            if (response.status == 400) try requireJson(response);
            if (response.status == 400 and isUseDpopNonce(allocator, response.body)) return error.DpopNonceRepeated;
        }
        if (response.status != 200) return classifyTokenFailure(allocator, response.body);
        try requireJson(response);
        const authorized = try parseTokenResponse(allocator, pending, response.body, nonce);
        pending.clearSecrets();
        return authorized;
    }

    pub fn deinit(pending: *PendingAuthorization) void {
        pending.clearSecrets();
        pending.* = undefined;
    }

    fn clearSecrets(pending: *PendingAuthorization) void {
        secureZero(std.mem.asBytes(&pending.key_pair));
        secureZero(&pending.verifier);
        secureZero(&pending.state);
        secureZero(pending.authorization_code.mutableSlice());
        pending.authorization_code.len = 0;
        secureZero(pending.request_uri.mutableSlice());
        pending.request_uri.len = 0;
    }
};

pub const AuthorizedSession = struct {
    account: identity.DiscoveredAccount,
    key_pair: oauth.KeyPair,
    access_token: Token,
    refresh_token: ?Token,
    scope: Scope,
    authorization_server_nonce: Nonce,
    access_token_expires_in: u64,

    pub fn deinit(session: *AuthorizedSession) void {
        secureZero(std.mem.asBytes(&session.key_pair));
        secureZero(session.access_token.mutableSlice());
        if (session.refresh_token) |*token| secureZero(token.mutableSlice());
        session.* = undefined;
    }
};

/// Start PAR. A `use_dpop_nonce` response is retried exactly once with a fresh
/// DPoP proof and the server nonce. Every DPoP response must supply a nonce.
pub fn begin(
    allocator: std.mem.Allocator,
    client: transport.Client,
    account: identity.DiscoveredAccount,
    redirect_uri_text: []const u8,
    entropy: SessionEntropy,
    proofs: ProofSource,
) Error!PendingAuthorization {
    try validateLoopbackRedirect(redirect_uri_text);
    const key_pair = try oauth.keyPairFromEntropy(entropy.key_seed);
    const pkce = oauth.pkceFromEntropy(entropy.pkce);
    const state = oauth.identifierFromEntropy(entropy.state);
    const redirect_uri = try RedirectUri.from(redirect_uri_text);
    const client_id = try buildClientId(&redirect_uri);

    var pending: PendingAuthorization = .{
        .account = account,
        .key_pair = key_pair,
        .verifier = pkce.verifier,
        .state = state,
        .redirect_uri = redirect_uri,
        .client_id = client_id,
        .request_uri = .{},
        .request_uri_expires_in = 0,
        .authorization_server_nonce = .{},
    };
    errdefer pending.deinit();
    const body = try buildParBody(allocator, &pending, &pkce.challenge);
    defer {
        secureZero(body);
        allocator.free(body);
    }

    var response = try postWithProof(
        allocator,
        client,
        proofs,
        key_pair,
        account.pushed_authorization_request_endpoint.slice(),
        body,
        null,
        par_limits,
    );
    defer {
        secureZero(response.body);
        response.deinit();
    }
    var nonce = Nonce{};
    try nonce.set(try requiredNonce(response));
    if (response.status == 400) try requireJson(response);
    if (response.status == 400 and isUseDpopNonce(allocator, response.body)) {
        secureZero(response.body);
        response.deinit();
        response = try postWithProof(
            allocator,
            client,
            proofs,
            key_pair,
            account.pushed_authorization_request_endpoint.slice(),
            body,
            nonce.slice(),
            par_limits,
        );
        try nonce.set(try requiredNonce(response));
        if (response.status == 400) try requireJson(response);
        if (response.status == 400 and isUseDpopNonce(allocator, response.body)) return error.DpopNonceRepeated;
    }
    if (response.status != 201) return error.OAuthRequestFailed;
    try requireJson(response);
    const parsed = try parseParResponse(allocator, response.body);
    pending.request_uri = parsed.request_uri;
    pending.request_uri_expires_in = parsed.expires_in;
    pending.authorization_server_nonce = nonce;
    return pending;
}

fn postWithProof(
    allocator: std.mem.Allocator,
    client: transport.Client,
    proofs: ProofSource,
    key_pair: oauth.KeyPair,
    endpoint: []const u8,
    body: []const u8,
    nonce: ?[]const u8,
    limits: transport.Limits,
) Error!transport.Response {
    var material = try proofs.next();
    defer secureZero(std.mem.asBytes(&material));
    const jti = oauth.identifierFromEntropy(material.jti_entropy);
    const proof = try oauth.buildDpopProof(allocator, key_pair, .{
        .method = "POST",
        .target_uri = endpoint,
        .issued_at = material.issued_at,
        .jti = &jti,
        .nonce = nonce,
    }, material.signing_noise);
    defer allocator.free(proof);
    const headers = [_]transport.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "dpop", .value = proof },
    };
    return client.request(allocator, .{
        .method = .post,
        .url = endpoint,
        .headers = &headers,
        .body = body,
        .limits = limits,
    });
}

fn buildClientId(redirect_uri: *const RedirectUri) Error!ClientId {
    var result = ClientId{};
    var output: std.Io.Writer = .fixed(&result.bytes);
    output.writeAll("http://localhost?redirect_uri=") catch return error.InvalidClientId;
    writeFormEncoded(&output, redirect_uri.slice()) catch return error.InvalidClientId;
    output.writeAll("&scope=") catch return error.InvalidClientId;
    writeFormEncoded(&output, requested_scope) catch return error.InvalidClientId;
    result.len = @intCast(output.end);
    return result;
}

fn buildParBody(allocator: std.mem.Allocator, pending: *const PendingAuthorization, challenge: []const u8) Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "client_id", .value = pending.client_id.slice() },
        .{ .name = "response_type", .value = "code" },
        .{ .name = "redirect_uri", .value = pending.redirect_uri.slice() },
        .{ .name = "scope", .value = requested_scope },
        .{ .name = "state", .value = &pending.state },
        .{ .name = "code_challenge", .value = challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "login_hint", .value = pending.account.did.slice() },
    };
    for (fields, 0..) |field, index| {
        if (index != 0) try result.append(allocator, '&');
        try appendFormPair(&result, allocator, field.name, field.value);
    }
    if (result.items.len > par_limits.max_request_body_bytes) return error.InvalidClientId;
    return result.toOwnedSlice(allocator);
}

fn buildTokenBody(allocator: std.mem.Allocator, pending: *const PendingAuthorization) Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "code", .value = pending.authorization_code.slice() },
        .{ .name = "redirect_uri", .value = pending.redirect_uri.slice() },
        .{ .name = "client_id", .value = pending.client_id.slice() },
        .{ .name = "code_verifier", .value = &pending.verifier },
    };
    for (fields, 0..) |field, index| {
        if (index != 0) try result.append(allocator, '&');
        try appendFormPair(&result, allocator, field.name, field.value);
    }
    return result.toOwnedSlice(allocator);
}

const ParResult = struct { request_uri: RequestUri, expires_in: u64 };

fn parseParResponse(allocator: std.mem.Allocator, body: []const u8) Error!ParResult {
    const Wire = struct { request_uri: []const u8, expires_in: u64 };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = 4096,
    }) catch return error.InvalidParResponse;
    defer parsed.deinit();
    if (parsed.value.expires_in == 0 or !validOpaque(parsed.value.request_uri, 2048)) return error.InvalidParResponse;
    return .{
        .request_uri = try RequestUri.from(parsed.value.request_uri),
        .expires_in = parsed.value.expires_in,
    };
}

fn parseTokenResponse(
    allocator: std.mem.Allocator,
    pending: *const PendingAuthorization,
    body: []const u8,
    nonce: Nonce,
) Error!AuthorizedSession {
    const Wire = struct {
        access_token: []const u8,
        token_type: []const u8,
        sub: []const u8,
        scope: []const u8,
        expires_in: u64,
        refresh_token: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = oauth.max_access_token_length,
        .allocate = .alloc_always,
    }) catch return error.InvalidTokenResponse;
    defer parsed.deinit();
    const value = parsed.value;
    defer {
        secureZero(@constCast(value.access_token));
        if (value.refresh_token) |text| secureZero(@constCast(text));
    }
    if (!std.ascii.eqlIgnoreCase(value.token_type, "DPoP") or
        !std.mem.eql(u8, value.sub, pending.account.did.slice()) or
        value.expires_in == 0 or
        !validOpaque(value.access_token, oauth.max_access_token_length) or
        !validScope(value.scope) or
        !scopeContains(value.scope, "atproto") or
        !scopeContains(value.scope, "include:site.standard.authFull")) return error.InvalidTokenResponse;
    var access = try Token.from(value.access_token);
    errdefer secureZero(access.mutableSlice());
    var refresh: ?Token = null;
    if (value.refresh_token) |text| {
        if (!validOpaque(text, oauth.max_access_token_length)) return error.InvalidTokenResponse;
        refresh = try Token.from(text);
    }
    return .{
        .account = pending.account,
        .key_pair = pending.key_pair,
        .access_token = access,
        .refresh_token = refresh,
        .scope = try Scope.from(value.scope),
        .authorization_server_nonce = nonce,
        .access_token_expires_in = value.expires_in,
    };
}

fn classifyTokenFailure(allocator: std.mem.Allocator, body: []const u8) Error {
    const Wire = struct { @"error": []const u8 };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = 1024,
    }) catch return error.OAuthRequestFailed;
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.@"error", "invalid_grant")) return error.InvalidGrant;
    return error.OAuthRequestFailed;
}

fn isUseDpopNonce(allocator: std.mem.Allocator, body: []const u8) bool {
    const Wire = struct { @"error": []const u8 };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = 1024,
    }) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.@"error", "use_dpop_nonce");
}

fn requiredNonce(response: transport.Response) Error![]const u8 {
    const value = response.header("dpop-nonce") orelse return error.DpopNonceMissing;
    if (!validOpaque(value, oauth.max_nonce_length)) return error.DpopNonceMissing;
    return value;
}

fn requireJson(response: transport.Response) Error!void {
    const value = response.header("content-type") orelse return error.InvalidContentType;
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..separator], " \t"), "application/json")) return error.InvalidContentType;
}

fn validateLoopbackRedirect(value: []const u8) Error!void {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, value, prefix) or !std.mem.endsWith(u8, value, callback_path)) return error.InvalidLoopbackRedirect;
    const port_text = value[prefix.len .. value.len - callback_path.len];
    if (port_text.len == 0 or (port_text.len > 1 and port_text[0] == '0')) return error.InvalidLoopbackRedirect;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidLoopbackRedirect;
    if (port == 0) return error.InvalidLoopbackRedirect;
}

fn appendFormPair(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try list.appendSlice(allocator, name);
    try list.append(allocator, '=');
    for (value) |byte| {
        if (isUnreserved(byte)) {
            try list.append(allocator, byte);
        } else {
            const hex = "0123456789ABCDEF";
            try list.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 15] });
        }
    }
}

fn writeFormEncoded(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (isUnreserved(byte)) try writer.writeByte(byte) else try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
}

fn formDecode(buffer: []u8, encoded: []const u8) Error![]const u8 {
    var out: usize = 0;
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        if (out >= buffer.len) return error.CallbackMalformed;
        const byte = encoded[index];
        if (byte == '+') {
            buffer[out] = ' ';
        } else if (byte == '%') {
            if (index + 2 >= encoded.len or !std.ascii.isHex(encoded[index + 1]) or !std.ascii.isHex(encoded[index + 2])) return error.CallbackMalformed;
            buffer[out] = std.fmt.parseInt(u8, encoded[index + 1 ..][0..2], 16) catch return error.CallbackMalformed;
            index += 2;
        } else {
            buffer[out] = byte;
        }
        if (buffer[out] <= 0x20 or buffer[out] >= 0x7f) return error.CallbackMalformed;
        out += 1;
    }
    return buffer[0..out];
}

fn validOpaque(value: []const u8, limit: usize) bool {
    if (value.len == 0 or value.len > limit) return false;
    for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

fn validScope(value: []const u8) bool {
    if (value.len == 0 or value.len > 4096 or value[0] == ' ' or value[value.len - 1] == ' ') return false;
    var previous_space = false;
    for (value) |byte| {
        if (byte == ' ') {
            if (previous_space) return false;
            previous_space = true;
        } else {
            if (byte < 0x21 or byte > 0x7e or byte == '"' or byte == '\\') return false;
            previous_space = false;
        }
    }
    return true;
}

fn scopeContains(scope: []const u8, expected: []const u8) bool {
    var values = std.mem.splitScalar(u8, scope, ' ');
    while (values.next()) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |left, right| difference |= left ^ right;
    return difference == 0;
}

fn secureZero(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

fn Fixed(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: u16 = 0,

        const Self = @This();

        pub fn from(value: []const u8) Error!Self {
            var result = Self{};
            try result.set(value);
            return result;
        }

        pub fn set(result: *Self, value: []const u8) Error!void {
            if (value.len > capacity) return error.NoSpaceLeft;
            @memcpy(result.bytes[0..value.len], value);
            result.len = @intCast(value.len);
        }

        pub fn slice(result: *const Self) []const u8 {
            return result.bytes[0..result.len];
        }

        pub fn mutableSlice(result: *Self) []u8 {
            return result.bytes[0..result.len];
        }
    };
}

const CallbackValues = struct {
    state: Fixed(oauth.digest_encoded_length) = .{},
    issuer: Fixed(identity.max_origin_bytes) = .{},
    code: AuthorizationCode = .{},
    oauth_error: Fixed(256) = .{},
    state_present: bool = false,
    issuer_present: bool = false,
    code_present: bool = false,
    error_present: bool = false,
};

const TestProofSource = struct {
    next_value: u8 = 1,

    fn source(self: *TestProofSource) ProofSource {
        return .{ .context = self, .next_fn = next };
    }

    fn next(context: *anyopaque) Error!ProofMaterial {
        const self: *TestProofSource = @ptrCast(@alignCast(context));
        const value = self.next_value;
        self.next_value +%= 1;
        return .{
            .issued_at = 1_700_000_000 + @as(u64, value),
            .jti_entropy = @splat(value),
            .signing_noise = @splat(value),
        };
    }
};

fn testAccount() !identity.DiscoveredAccount {
    return .{
        .did = try identity.Did.parse("did:plc:ewvi7nxzyoun6zhxrhs64oiz"),
        .verified_handle = null,
        .pds_origin = try identity.Origin.parse("https://pds.example.com"),
        .authorization_server_origin = try identity.Origin.parse("https://auth.example.com"),
        .authorization_endpoint = try identity.Endpoint.parse("https://auth.example.com/authorize"),
        .token_endpoint = try identity.Endpoint.parse("https://auth.example.com/token"),
        .pushed_authorization_request_endpoint = try identity.Endpoint.parse("https://auth.example.com/par"),
    };
}

test "loopback redirect and callback validation fail closed and burn attempts" {
    try std.testing.expectError(error.InvalidLoopbackRedirect, validateLoopbackRedirect("http://localhost:8080/oauth/callback"));
    try std.testing.expectError(error.InvalidLoopbackRedirect, validateLoopbackRedirect("https://127.0.0.1:8080/oauth/callback"));
    try std.testing.expectError(error.InvalidLoopbackRedirect, validateLoopbackRedirect("http://127.0.0.1:08080/oauth/callback"));
    try validateLoopbackRedirect("http://127.0.0.1:8080/oauth/callback");

    var pending: PendingAuthorization = .{
        .account = try testAccount(),
        .key_pair = try oauth.keyPairFromEntropy(@splat(7)),
        .verifier = oauth.pkceFromEntropy(@splat(8)).verifier,
        .state = oauth.identifierFromEntropy(@splat(9)),
        .redirect_uri = try RedirectUri.from("http://127.0.0.1:8080/oauth/callback"),
        .client_id = try ClientId.from("http://localhost?redirect_uri=x&scope=y"),
        .request_uri = try RequestUri.from("urn:example:par"),
        .request_uri_expires_in = 90,
        .authorization_server_nonce = try Nonce.from("nonce"),
    };
    defer pending.deinit();
    try std.testing.expectError(error.StateMismatch, pending.acceptCallback(
        "/oauth/callback?state=wrong&iss=https%3A%2F%2Fauth.example.com&code=abc",
    ));
    try std.testing.expectError(error.CallbackAlreadyConsumed, pending.acceptCallback(
        "/oauth/callback?state=wrong&iss=https%3A%2F%2Fauth.example.com&code=abc",
    ));
}

test "form encoding and token response enforce identity and publication scope" {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    try appendFormPair(&encoded, std.testing.allocator, "scope", requested_scope);
    try std.testing.expectEqualStrings("scope=atproto%20include%3Asite.standard.authFull", encoded.items);

    var pending: PendingAuthorization = .{
        .account = try testAccount(),
        .key_pair = try oauth.keyPairFromEntropy(@splat(7)),
        .verifier = oauth.pkceFromEntropy(@splat(8)).verifier,
        .state = oauth.identifierFromEntropy(@splat(9)),
        .redirect_uri = try RedirectUri.from("http://127.0.0.1:8080/oauth/callback"),
        .client_id = try ClientId.from("client"),
        .request_uri = try RequestUri.from("urn:example:par"),
        .request_uri_expires_in = 90,
        .authorization_server_nonce = try Nonce.from("nonce"),
    };
    defer pending.deinit();
    var session = try parseTokenResponse(
        std.testing.allocator,
        &pending,
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"token_type\":\"DPoP\",\"sub\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"scope\":\"atproto include:site.standard.authFull\",\"expires_in\":3600}",
        try Nonce.from("next-nonce"),
    );
    defer session.deinit();
    try std.testing.expectEqualStrings("access", session.access_token.slice());
    try std.testing.expectError(error.InvalidTokenResponse, parseTokenResponse(
        std.testing.allocator,
        &pending,
        "{\"access_token\":\"access\",\"token_type\":\"Bearer\",\"sub\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"scope\":\"atproto\",\"expires_in\":3600}",
        try Nonce.from("next-nonce"),
    ));
}

test "PAR response is bounded and requires positive lifetime" {
    const parsed = try parseParResponse(std.testing.allocator, "{\"request_uri\":\"urn:ietf:params:oauth:request_uri:abc\",\"expires_in\":90}");
    try std.testing.expectEqualStrings("urn:ietf:params:oauth:request_uri:abc", parsed.request_uri.slice());
    try std.testing.expectError(error.InvalidParResponse, parseParResponse(std.testing.allocator, "{\"request_uri\":\"urn:x\",\"expires_in\":0}"));
}

test "proof source is injected and deterministic" {
    var source = TestProofSource{};
    const first = try source.source().next();
    const second = try source.source().next();
    try std.testing.expectEqual(@as(u64, 1_700_000_001), first.issued_at);
    try std.testing.expectEqual(@as(u8, 2), second.jti_entropy[0]);
}

const FlowMock = struct {
    call: usize = 0,
    proof_hashes: [4][32]u8 = undefined,

    fn client(self: *FlowMock) transport.Client {
        return .{ .context = self, .request_fn = request };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: transport.Request,
    ) transport.Error!transport.Response {
        const self: *FlowMock = @ptrCast(@alignCast(context));
        if (self.call >= 4 or value.method != .post or value.headers.len != 3 or
            !std.ascii.eqlIgnoreCase(value.headers[2].name, "dpop") or value.headers[2].value.len == 0)
        {
            return error.UnexpectedRequest;
        }
        std.crypto.hash.sha2.Sha256.hash(value.headers[2].value, &self.proof_hashes[self.call], .{});
        if (self.call > 0 and std.mem.eql(u8, &self.proof_hashes[self.call - 1], &self.proof_hashes[self.call])) {
            return error.UnexpectedRequest;
        }
        const par = self.call < 2;
        if (par) {
            if (!std.mem.eql(u8, value.url, "https://auth.example.com/par") or
                std.mem.indexOf(u8, value.body, "response_type=code") == null or
                std.mem.indexOf(u8, value.body, "code_challenge_method=S256") == null or
                std.mem.indexOf(u8, value.body, "login_hint=did%3Aplc%3Aewvi7nxzyoun6zhxrhs64oiz") == null or
                std.mem.indexOf(u8, value.body, "code_verifier") != null)
            {
                return error.UnexpectedRequest;
            }
        } else if (!std.mem.eql(u8, value.url, "https://auth.example.com/token") or
            std.mem.indexOf(u8, value.body, "grant_type=authorization_code") == null or
            std.mem.indexOf(u8, value.body, "code=auth-code") == null or
            std.mem.indexOf(u8, value.body, "code_verifier=") == null)
        {
            return error.UnexpectedRequest;
        }

        const responses = [_]struct {
            status: u16,
            nonce: []const u8,
            body: []const u8,
        }{
            .{ .status = 400, .nonce = "par-nonce-1", .body = "{\"error\":\"use_dpop_nonce\"}" },
            .{ .status = 201, .nonce = "par-nonce-2", .body = "{\"request_uri\":\"urn:ietf:params:oauth:request_uri:abc\",\"expires_in\":90}" },
            .{ .status = 400, .nonce = "token-nonce-1", .body = "{\"error\":\"use_dpop_nonce\"}" },
            .{ .status = 200, .nonce = "token-nonce-2", .body = "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"token_type\":\"DPoP\",\"sub\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"scope\":\"atproto include:site.standard.authFull\",\"expires_in\":3600}" },
        };
        const selected = responses[self.call];
        self.call += 1;
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "dpop-nonce", .value = selected.nonce },
        };
        return transport.Response.initCopy(allocator, selected.status, &headers, selected.body, value.limits);
    }
};

test "one-shot PAR callback and token exchange retry nonce challenges offline" {
    var mock = FlowMock{};
    var proofs = TestProofSource{};
    var pending = try begin(
        std.testing.allocator,
        mock.client(),
        try testAccount(),
        "http://127.0.0.1:49152/oauth/callback",
        .{ .key_seed = @splat(10), .pkce = @splat(11), .state = @splat(12) },
        proofs.source(),
    );
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 2), mock.call);
    const browser_url = try pending.browserUrl(std.testing.allocator);
    defer std.testing.allocator.free(browser_url);
    try std.testing.expect(std.mem.startsWith(u8, browser_url, "https://auth.example.com/authorize?client_id="));
    try std.testing.expect(std.mem.indexOf(u8, browser_url, "&request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3Aabc") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_url, "state=") == null);
    try std.testing.expect(std.mem.indexOf(u8, browser_url, "code_challenge=") == null);

    const callback = try std.fmt.allocPrint(
        std.testing.allocator,
        "/oauth/callback?code=auth-code&iss=https%3A%2F%2Fauth.example.com&state={s}",
        .{&pending.state},
    );
    defer std.testing.allocator.free(callback);
    try pending.acceptCallback(callback);
    try std.testing.expectError(error.CallbackAlreadyConsumed, pending.acceptCallback(callback));
    var session = try pending.exchange(std.testing.allocator, mock.client(), proofs.source());
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 4), mock.call);
    try std.testing.expectEqualStrings("access", session.access_token.slice());
    try std.testing.expectEqual(@as(u64, 3600), session.access_token_expires_in);
    try std.testing.expectEqualStrings("token-nonce-2", session.authorization_server_nonce.slice());
    try std.testing.expectError(error.CodeAlreadyConsumed, pending.exchange(std.testing.allocator, mock.client(), proofs.source()));
}
