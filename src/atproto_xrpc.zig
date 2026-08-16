//! Portable, typed AT Protocol XRPC record client for Standard.site
//! publication (com.atproto.repo.getRecord / putRecord / deleteRecord).
//!
//! This is protocol infrastructure for the publication slice, not a generic
//! ATProto SDK. The host supplies a session binding (validated DID + PDS
//! origin + session DPoP key + access token), a bounded transport, and a
//! fresh DPoP proof source. Every request is bound to the session's exact DID
//! and validated PDS origin; PDS DPoP nonces are tracked as separate
//! per-origin state from Authorization Server nonces.
//!
//! No sockets, DNS, clocks, files, environment, or ambient randomness live
//! here. The module compiles under the repository's wasm32-freestanding gate.

const std = @import("std");
const authorization = @import("atproto_authorization.zig");
const identity = @import("atproto_identity.zig");
const oauth = @import("atproto_oauth.zig");
const transport = @import("atproto_transport.zig");

pub const max_collection_bytes = 128;
pub const max_rkey_bytes = 512;
pub const max_cid_bytes = 128;
pub const max_record_bytes = 256 * 1024;
pub const max_response_body_bytes = 256 * 1024;
pub const max_json_value_len = 16 * 1024;
pub const max_at_uri_bytes = 2048;

pub const response_limits: transport.Limits = .{ .max_body_bytes = max_response_body_bytes };

pub const Error = transport.Error || oauth.Error || authorization.Error || std.mem.Allocator.Error || error{
    DpopNonceRepeated,
    InvalidAtUri,
    InvalidCid,
    InvalidCollection,
    InvalidContentType,
    InvalidNonce,
    InvalidRecord,
    InvalidResponse,
    InvalidRkey,
    InvalidStatus,
    RecordNotFound,
    SessionPdsMismatch,
    WrongRecordIdentity,
};

const Nonce = Fixed(oauth.max_nonce_length);

/// Borrowed view of the authorized account the client is bound to. Production
/// code derives it from an `AuthorizedSession`; tests and mocks construct it
/// directly so the portable core never depends on private token storage types.
pub const SessionBinding = struct {
    did: identity.Did,
    pds_origin: identity.Origin,
    /// Present for DPoP-bound OAuth sessions; `null` selects Bearer auth
    /// (app-password sessions), which sends the access token directly with no
    /// proof and no DPoP nonce requirement.
    key_pair: ?oauth.KeyPair,
    access_token: []const u8,
};

pub const SessionClient = struct {
    binding: SessionBinding,
    transport_client: transport.Client,
    proofs: authorization.ProofSource,
    /// PDS DPoP nonce, tracked separately from the Authorization Server nonce
    /// that lives in the session. This is per-origin state for the PDS only.
    pds_nonce: Nonce = .{},
    pds_nonce_present: bool = false,

    pub fn fromAuthorizedSession(
        session: *const authorization.AuthorizedSession,
        transport_client: transport.Client,
        proofs: authorization.ProofSource,
    ) SessionClient {
        return .{
            .binding = .{
                .did = session.account.did,
                .pds_origin = session.account.pds_origin,
                .key_pair = session.key_pair,
                .access_token = session.access_token.slice(),
            },
            .transport_client = transport_client,
            .proofs = proofs,
        };
    }

    /// Bearer-authenticated client for an app-password session: no DPoP key,
    /// no proof, no nonce — the access JWT travels in `Authorization: Bearer`.
    pub fn fromBearerSession(
        did: identity.Did,
        pds_origin: identity.Origin,
        access_token: []const u8,
        transport_client: transport.Client,
    ) SessionClient {
        return .{
            .binding = .{
                .did = did,
                .pds_origin = pds_origin,
                .key_pair = null,
                .access_token = access_token,
            },
            .transport_client = transport_client,
            .proofs = bearerProofSource(),
        };
    }

    pub fn init(
        binding: SessionBinding,
        transport_client: transport.Client,
        proofs: authorization.ProofSource,
    ) SessionClient {
        return .{ .binding = binding, .transport_client = transport_client, .proofs = proofs };
    }

    pub fn getRecord(
        client: *SessionClient,
        allocator: std.mem.Allocator,
        collection: []const u8,
        rkey: []const u8,
    ) Error!GetRecordResult {
        try validateCollection(collection);
        try validateRkey(rkey);
        const url = try buildGetUrl(allocator, client, collection, rkey);
        defer allocator.free(url);

        var response = try client.sendWithNonceRetry(allocator, .get, url, "");
        defer {
            std.crypto.secureZero(u8, response.body);
            response.deinit();
        }
        if (response.status == 400 and isRecordNotFound(allocator, response.body)) return .not_found;
        if (response.status != 200) return error.InvalidStatus;
        try requireJson(response);
        return .{ .found = try parseGetRecord(allocator, client, collection, rkey, response.body) };
    }

    pub fn putRecord(
        client: *SessionClient,
        allocator: std.mem.Allocator,
        collection: []const u8,
        rkey: []const u8,
        record: []const u8,
        swap_record: ?[]const u8,
    ) Error!PutResult {
        try validateCollection(collection);
        try validateRkey(rkey);
        try validateRecordBytes(allocator, record);
        const body = try buildPutBody(allocator, client, collection, rkey, record, swap_record);
        defer {
            std.crypto.secureZero(u8, body);
            allocator.free(body);
        }
        const url = try buildMethodUrl(allocator, client, "com.atproto.repo.putRecord");
        defer allocator.free(url);

        var response = try client.sendWithNonceRetry(allocator, .post, url, body);
        defer {
            std.crypto.secureZero(u8, response.body);
            response.deinit();
        }
        if (response.status != 200) return error.InvalidStatus;
        try requireJson(response);
        return parsePutResult(allocator, client, collection, rkey, response.body);
    }

    pub fn deleteRecord(
        client: *SessionClient,
        allocator: std.mem.Allocator,
        collection: []const u8,
        rkey: []const u8,
        swap_record: ?[]const u8,
    ) Error!DeleteResult {
        try validateCollection(collection);
        try validateRkey(rkey);
        const body = try buildDeleteBody(allocator, client, collection, rkey, swap_record);
        defer {
            std.crypto.secureZero(u8, body);
            allocator.free(body);
        }
        const url = try buildMethodUrl(allocator, client, "com.atproto.repo.deleteRecord");
        defer allocator.free(url);

        var response = try client.sendWithNonceRetry(allocator, .post, url, body);
        defer {
            std.crypto.secureZero(u8, response.body);
            response.deinit();
        }
        if (response.status != 200) return error.InvalidStatus;
        try requireJson(response);
        return parseDeleteResult(allocator, response.body);
    }

    /// One XRPC request with exactly one `use_dpop_nonce` retry. A second
    /// challenge, a redirect, a downgrade, or an ambiguous response fails
    /// closed. The PDS nonce is stored as per-origin state between calls.
    fn sendWithNonceRetry(
        client: *SessionClient,
        allocator: std.mem.Allocator,
        method: transport.Method,
        url: []const u8,
        body: []const u8,
    ) Error!transport.Response {
        // Bearer (app-password) requests carry no DPoP nonce and never retry
        // a `use_dpop_nonce` challenge.
        if (client.binding.key_pair == null) {
            return client.sendOnce(allocator, method, url, body);
        }
        var response = try client.sendOnce(allocator, method, url, body);
        errdefer {
            std.crypto.secureZero(u8, response.body);
            response.deinit();
        }
        if (isRedirectStatus(response.status)) return error.RedirectRejected;
        const first_nonce = try requiredNonce(response);
        try client.setNonce(first_nonce);
        if (response.status == 400 and isUseDpopNonce(allocator, response.body)) {
            std.crypto.secureZero(u8, response.body);
            response.deinit();
            response = try client.sendOnce(allocator, method, url, body);
            if (isRedirectStatus(response.status)) return error.RedirectRejected;
            const retry_nonce = try requiredNonce(response);
            try client.setNonce(retry_nonce);
            if (response.status == 400 and isUseDpopNonce(allocator, response.body)) return error.DpopNonceRepeated;
        }
        return response;
    }

    fn sendOnce(
        client: *SessionClient,
        allocator: std.mem.Allocator,
        method: transport.Method,
        url: []const u8,
        body: []const u8,
    ) Error!transport.Response {
        const authorization_value = if (client.binding.key_pair) |_| value: {
            const proof = try client.buildProof(allocator, method, url);
            defer allocator.free(proof);
            break :value try std.fmt.allocPrint(allocator, "DPoP {s}", .{proof});
        } else value: {
            break :value try std.fmt.allocPrint(allocator, "Bearer {s}", .{client.binding.access_token});
        };
        defer allocator.free(authorization_value);
        var headers: [3]transport.Header = undefined;
        headers[0] = .{ .name = "accept", .value = "application/json" };
        headers[1] = .{ .name = "authorization", .value = authorization_value };
        headers[2] = .{ .name = "content-type", .value = "application/json" };
        const header_slice: []const transport.Header = if (method == .get) headers[0..2] else headers[0..3];
        return client.transport_client.request(allocator, .{
            .method = method,
            .url = url,
            .headers = header_slice,
            .body = body,
            .redirect_policy = .forbid,
            .limits = response_limits,
        });
    }

    /// One fresh ES256 DPoP proof with exact `htu`, `htm`, `ath`, `iat`,
    /// `jti`, and the current PDS nonce. The access token travels only inside
    /// the `ath` claim hash; the raw token is never sent as a header value.
    fn buildProof(
        client: *SessionClient,
        allocator: std.mem.Allocator,
        method: transport.Method,
        url: []const u8,
    ) Error![]u8 {
        var material = try client.proofs.next();
        defer std.crypto.secureZero(u8, std.mem.asBytes(&material));
        const jti = oauth.identifierFromEntropy(material.jti_entropy);
        return oauth.buildDpopProof(allocator, client.binding.key_pair.?, .{
            .method = if (method == .get) "GET" else "POST",
            .target_uri = url,
            .issued_at = material.issued_at,
            .jti = &jti,
            .nonce = if (client.pds_nonce_present) client.pds_nonce.slice() else null,
            .access_token = client.binding.access_token,
        }, material.signing_noise);
    }

    fn setNonce(client: *SessionClient, value: []const u8) Error!void {
        try client.pds_nonce.set(value);
        client.pds_nonce_present = true;
    }

    fn pdsPrefix(client: *const SessionClient) []const u8 {
        return client.binding.pds_origin.slice();
    }

    fn requirePds(client: *const SessionClient, url: []const u8) Error!void {
        const prefix = client.pdsPrefix();
        const xrpc = "/xrpc/";
        if (!std.mem.startsWith(u8, url, prefix) or
            url.len < prefix.len + xrpc.len or
            !std.mem.eql(u8, url[prefix.len .. prefix.len + xrpc.len], xrpc))
        {
            return error.SessionPdsMismatch;
        }
    }
};

pub const GetRecordResult = union(enum) {
    found: GetRecordResponse,
    not_found,
};

pub const GetRecordResponse = struct {
    allocator: std.mem.Allocator,
    uri: []u8,
    cid: ?[]u8,
    value: std.json.Parsed(std.json.Value),
    validation_status: ?[]u8,

    pub fn deinit(self: *GetRecordResponse) void {
        self.allocator.free(self.uri);
        if (self.cid) |cid| self.allocator.free(cid);
        if (self.validation_status) |status| self.allocator.free(status);
        self.value.deinit();
        self.* = undefined;
    }
};

pub const PutResult = struct {
    allocator: std.mem.Allocator,
    uri: []u8,
    cid: []u8,
    validation_status: ?[]u8,

    pub fn deinit(self: *PutResult) void {
        self.allocator.free(self.uri);
        self.allocator.free(self.cid);
        if (self.validation_status) |status| self.allocator.free(status);
        self.* = undefined;
    }
};

pub const DeleteResult = struct {
    allocator: std.mem.Allocator,
    /// Present only when the PDS returns one in the 200 body.
    commit: ?[]u8,

    pub fn deinit(self: *DeleteResult) void {
        if (self.commit) |commit| self.allocator.free(commit);
        self.* = undefined;
    }
};

fn buildGetUrl(
    allocator: std.mem.Allocator,
    client: *const SessionClient,
    collection: []const u8,
    rkey: []const u8,
) Error![]u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/xrpc/com.atproto.repo.getRecord?repo={s}&collection={s}&rkey={s}",
        .{ client.pdsPrefix(), client.binding.did.slice(), collection, rkey },
    );
    errdefer allocator.free(url);
    try client.requirePds(url);
    return url;
}

fn buildMethodUrl(
    allocator: std.mem.Allocator,
    client: *const SessionClient,
    nsid: []const u8,
) Error![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/xrpc/{s}", .{ client.pdsPrefix(), nsid });
    errdefer allocator.free(url);
    try client.requirePds(url);
    return url;
}

fn buildPutBody(
    allocator: std.mem.Allocator,
    client: *const SessionClient,
    collection: []const u8,
    rkey: []const u8,
    record: []const u8,
    swap_record: ?[]const u8,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"repo\":\"");
    try out.appendSlice(allocator, client.binding.did.slice());
    try out.appendSlice(allocator, "\",\"collection\":\"");
    try out.appendSlice(allocator, collection);
    try out.appendSlice(allocator, "\",\"rkey\":\"");
    try out.appendSlice(allocator, rkey);
    try out.appendSlice(allocator, "\"");
    if (swap_record) |swap| {
        try out.appendSlice(allocator, ",\"swapRecord\":\"");
        try out.appendSlice(allocator, swap);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, ",\"record\":");
    try out.appendSlice(allocator, record);
    try out.appendSlice(allocator, "}");
    if (out.items.len > response_limits.max_request_body_bytes) return error.InvalidRecord;
    return out.toOwnedSlice(allocator);
}

fn buildDeleteBody(
    allocator: std.mem.Allocator,
    client: *const SessionClient,
    collection: []const u8,
    rkey: []const u8,
    swap_record: ?[]const u8,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"repo\":\"");
    try out.appendSlice(allocator, client.binding.did.slice());
    try out.appendSlice(allocator, "\",\"collection\":\"");
    try out.appendSlice(allocator, collection);
    try out.appendSlice(allocator, "\",\"rkey\":\"");
    try out.appendSlice(allocator, rkey);
    try out.appendSlice(allocator, "\"");
    if (swap_record) |swap| {
        try out.appendSlice(allocator, ",\"swapRecord\":\"");
        try out.appendSlice(allocator, swap);
        try out.appendSlice(allocator, "\"");
    }
    try out.appendSlice(allocator, "}");
    if (out.items.len > response_limits.max_request_body_bytes) return error.InvalidRecord;
    return out.toOwnedSlice(allocator);
}

fn parseGetRecord(
    allocator: std.mem.Allocator,
    client: *const SessionClient,
    collection: []const u8,
    rkey: []const u8,
    body: []const u8,
) Error!GetRecordResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = max_json_value_len,
        .allocate = .alloc_always,
    }) catch return error.InvalidResponse;
    errdefer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    const uri = root.object.get("uri") orelse return error.InvalidResponse;
    if (uri != .string or !validateAtUri(uri.string, client.binding.did.slice(), collection, rkey)) return error.WrongRecordIdentity;
    const cid = root.object.get("cid");
    if (cid) |value| {
        if (value != .string or !validCid(value.string)) return error.InvalidCid;
    }
    const record_value = root.object.get("value") orelse return error.InvalidResponse;
    if (record_value != .object) return error.InvalidResponse;
    const validation_status = root.object.get("validationStatus");
    if (validation_status) |status| {
        if (status != .string) return error.InvalidResponse;
    }
    const uri_owned = try allocator.dupe(u8, uri.string);
    errdefer allocator.free(uri_owned);
    const cid_owned = if (cid) |value| try allocator.dupe(u8, value.string) else null;
    errdefer if (cid_owned) |value| allocator.free(value);
    const status_owned = if (validation_status) |status| try allocator.dupe(u8, status.string) else null;
    errdefer if (status_owned) |value| allocator.free(value);
    return .{
        .allocator = allocator,
        .uri = uri_owned,
        .cid = cid_owned,
        .value = parsed,
        .validation_status = status_owned,
    };
}

fn parsePutResult(
    allocator: std.mem.Allocator,
    client: *const SessionClient,
    collection: []const u8,
    rkey: []const u8,
    body: []const u8,
) Error!PutResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = max_json_value_len,
        .allocate = .alloc_always,
    }) catch return error.InvalidResponse;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    const uri = root.object.get("uri") orelse return error.InvalidResponse;
    const cid = root.object.get("cid") orelse return error.InvalidResponse;
    if (uri != .string or !validateAtUri(uri.string, client.binding.did.slice(), collection, rkey)) return error.WrongRecordIdentity;
    if (cid != .string or !validCid(cid.string)) return error.InvalidCid;
    const validation_status = root.object.get("validationStatus");
    if (validation_status) |status| {
        if (status != .string) return error.InvalidResponse;
    }
    return .{
        .allocator = allocator,
        .uri = try allocator.dupe(u8, uri.string),
        .cid = try allocator.dupe(u8, cid.string),
        .validation_status = if (validation_status) |status| try allocator.dupe(u8, status.string) else null,
    };
}

fn parseDeleteResult(allocator: std.mem.Allocator, body: []const u8) Error!DeleteResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = max_json_value_len,
        .allocate = .alloc_always,
    }) catch return error.InvalidResponse;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    const commit = root.object.get("commit");
    if (commit) |value| {
        if (value != .string) return error.InvalidResponse;
    }
    return .{ .allocator = allocator, .commit = if (commit) |value| try allocator.dupe(u8, value.string) else null };
}

pub fn buildAtUri(
    allocator: std.mem.Allocator,
    did: []const u8,
    collection: []const u8,
    rkey: []const u8,
) Error![]u8 {
    try validateCollection(collection);
    try validateRkey(rkey);
    const uri = try std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ did, collection, rkey });
    errdefer allocator.free(uri);
    if (uri.len > max_at_uri_bytes) return error.InvalidAtUri;
    return uri;
}

fn validateAtUri(uri: []const u8, did: []const u8, collection: []const u8, rkey: []const u8) bool {
    if (uri.len > max_at_uri_bytes) return false;
    const prefix = "at://";
    if (!std.mem.startsWith(u8, uri, prefix)) return false;
    const rest = uri[prefix.len..];
    if (rest.len < did.len + collection.len + rkey.len + 2) return false;
    if (!std.mem.eql(u8, rest[0..did.len], did) or rest[did.len] != '/') return false;
    const after_did = rest[did.len + 1 ..];
    if (!std.mem.eql(u8, after_did[0..collection.len], collection) or after_did[collection.len] != '/') return false;
    return std.mem.eql(u8, after_did[collection.len + 1 ..], rkey);
}

pub fn validateCollection(collection: []const u8) Error!void {
    if (collection.len == 0 or collection.len > max_collection_bytes) return error.InvalidCollection;
    if (collection[0] == '.' or collection[collection.len - 1] == '.') return error.InvalidCollection;
    var segment: usize = 0;
    var dots: usize = 0;
    for (collection) |byte| {
        if (byte == '.') {
            if (segment == 0) return error.InvalidCollection;
            segment = 0;
            dots += 1;
        } else if (std.ascii.isAlphanumeric(byte)) {
            segment += 1;
        } else {
            return error.InvalidCollection;
        }
    }
    if (dots == 0 or segment == 0) return error.InvalidCollection;
}

pub fn validateRkey(rkey: []const u8) Error!void {
    if (rkey.len == 0 or rkey.len > max_rkey_bytes) return error.InvalidRkey;
    if (std.mem.eql(u8, rkey, ".") or std.mem.eql(u8, rkey, "..")) return error.InvalidRkey;
    for (rkey) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == ':' or byte == '~' or byte == '-')) {
            return error.InvalidRkey;
        }
    }
}

fn validateRecordBytes(allocator: std.mem.Allocator, record: []const u8) Error!void {
    if (record.len == 0 or record.len > max_record_bytes) return error.InvalidRecord;
    if (!std.unicode.utf8ValidateSlice(record)) return error.InvalidRecord;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, record, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_json_value_len,
        .allocate = .alloc_always,
    }) catch return error.InvalidRecord;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRecord;
}

fn validCid(cid: []const u8) bool {
    if (cid.len < 32 or cid.len > max_cid_bytes) return false;
    for (cid) |byte| {
        const lowercase = byte | 0x20;
        if (!(lowercase >= 'a' and lowercase <= 'z') and !(byte >= '0' and byte <= '7')) return false;
    }
    return true;
}

fn requireJson(response: transport.Response) Error!void {
    const value = response.header("content-type") orelse return error.InvalidContentType;
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..separator], " \t"), "application/json")) return error.InvalidContentType;
}

fn requiredNonce(response: transport.Response) Error![]const u8 {
    const value = response.header("dpop-nonce") orelse return error.InvalidNonce;
    if (!validOpaque(value, oauth.max_nonce_length)) return error.InvalidNonce;
    return value;
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

fn isRecordNotFound(allocator: std.mem.Allocator, body: []const u8) bool {
    const Wire = struct { @"error": []const u8 };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = 1024,
    }) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.@"error", "RecordNotFound");
}

fn isRedirectStatus(status: u16) bool {
    return status >= 300 and status < 400;
}

fn validOpaque(value: []const u8, limit: usize) bool {
    if (value.len == 0 or value.len > limit) return false;
    for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

/// Placeholder proof source for Bearer sessions. It must never be invoked;
/// the bearer branch of `sendOnce` never asks for a proof, and returning an
/// error here turns an accidental call into a hard failure.
fn bearerProofSource() authorization.ProofSource {
    return .{ .context = undefined, .next_fn = bearerNoProofs };
}

fn bearerNoProofs(_: *anyopaque) authorization.Error!authorization.ProofMaterial {
    return error.ProofUnavailable;
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
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_did_text = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const test_pds = "https://pds.example.com";

fn proofHasAth(proof: []const u8) bool {
    var segments = std.mem.splitScalar(u8, proof, '.');
    _ = segments.next() orelse return false;
    const payload_encoded = segments.next() orelse return false;
    var decoded: [4 * 1024]u8 = undefined;
    const len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_encoded) catch return false;
    if (len > decoded.len) return false;
    std.base64.url_safe_no_pad.Decoder.decode(decoded[0..len], payload_encoded) catch return false;
    return std.mem.indexOf(u8, decoded[0..len], "\"ath\"") != null;
}

const TestProofSource = struct {
    next_value: u8 = 1,

    fn source(self: *TestProofSource) authorization.ProofSource {
        return .{ .context = self, .next_fn = next };
    }

    fn next(context: *anyopaque) authorization.Error!authorization.ProofMaterial {
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

fn testBinding() !SessionBinding {
    return .{
        .did = try identity.Did.parse(test_did_text),
        .pds_origin = try identity.Origin.parse(test_pds),
        .key_pair = try oauth.keyPairFromEntropy(@splat(7)),
        .access_token = "access-token",
    };
}

test "collection and rkey grammar fail closed" {
    try std.testing.expectError(error.InvalidCollection, validateCollection(""));
    try std.testing.expectError(error.InvalidCollection, validateCollection("site.standard."));
    try std.testing.expectError(error.InvalidCollection, validateCollection(".standard.document"));
    try std.testing.expectError(error.InvalidCollection, validateCollection("site/standard/document"));
    try std.testing.expectError(error.InvalidCollection, validateCollection("nodots"));
    try validateCollection("site.standard.document");

    try std.testing.expectError(error.InvalidRkey, validateRkey(""));
    try std.testing.expectError(error.InvalidRkey, validateRkey("."));
    try std.testing.expectError(error.InvalidRkey, validateRkey(".."));
    try std.testing.expectError(error.InvalidRkey, validateRkey("bad%rkey"));
    try validateRkey("guides~intro");
}

test "AT-URI construction and validation bind did collection rkey exactly" {
    const uri = try buildAtUri(std.testing.allocator, test_did_text, "site.standard.document", "guides~intro");
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides~intro", uri);
    try std.testing.expect(validateAtUri(uri, test_did_text, "site.standard.document", "guides~intro"));
    try std.testing.expect(!validateAtUri(uri, "did:plc:otherxxxxxxxxxxxxxxxxxx", "site.standard.document", "guides~intro"));
    try std.testing.expect(!validateAtUri(uri, test_did_text, "site.standard.publication", "guides~intro"));
    try std.testing.expect(!validateAtUri(uri, test_did_text, "site.standard.document", "other"));
    try std.testing.expect(!validateAtUri("https://not-at-uri", test_did_text, "site.standard.document", "guides~intro"));
}

test "CID shape validation is bounded" {
    try std.testing.expect(validCid("bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4"));
    try std.testing.expect(!validCid("short"));
    try std.testing.expect(!validCid("BAFYREIHWN3GFVNOP"));
    try std.testing.expect(!validCid("bafy@reihwn3gfvnop"));
}

test "record bytes must be a bounded JSON object" {
    try validateRecordBytes(std.testing.allocator, "{\"title\":\"x\"}");
    try std.testing.expectError(error.InvalidRecord, validateRecordBytes(std.testing.allocator, "[1,2]"));
    try std.testing.expectError(error.InvalidRecord, validateRecordBytes(std.testing.allocator, "\"just a string\""));
    try std.testing.expectError(error.InvalidRecord, validateRecordBytes(std.testing.allocator, "{broken"));
    try std.testing.expectError(error.InvalidRecord, validateRecordBytes(std.testing.allocator, "{\"a\":1}{\"b\":2}"));
}

/// Deterministic offline PDS double. Validates the exact method, URL, headers,
/// DPoP proof freshness, and body, then returns scripted responses with PDS
/// nonces. Records every request for post-hoc assertion.
const XrpcMock = struct {
    const Entry = struct {
        method: transport.Method,
        url: []u8,
        proof: []u8,
        body: []u8,
    };

    const Scripted = struct {
        status: u16,
        body: []const u8,
    };

    allocator: std.mem.Allocator,
    requests: std.ArrayList(Entry) = .empty,
    scripted: []const Scripted,
    next: usize = 0,
    /// Fresh proofs must never repeat a prior proof hash for the same key.
    previous_proof_hash: ?[32]u8 = null,

    fn init(allocator: std.mem.Allocator, scripted: []const Scripted) XrpcMock {
        return .{ .allocator = allocator, .scripted = scripted };
    }

    fn deinit(self: *XrpcMock) void {
        for (self.requests.items) |entry| {
            self.allocator.free(entry.url);
            self.allocator.free(entry.proof);
            self.allocator.free(entry.body);
        }
        self.requests.deinit(self.allocator);
        self.* = undefined;
    }

    fn client(self: *XrpcMock) transport.Client {
        return .{ .context = self, .request_fn = request };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: transport.Request,
    ) transport.Error!transport.Response {
        const self: *XrpcMock = @ptrCast(@alignCast(context));
        if (self.next >= self.scripted.len) return error.UnexpectedRequest;
        if (value.redirect_policy != .forbid) return error.UnexpectedRequest;

        var auth: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;
        for (value.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                if (auth != null) return error.UnexpectedRequest;
                auth = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                if (content_type != null) return error.UnexpectedRequest;
                content_type = header.value;
            }
        }
        if (auth == null or !std.mem.startsWith(u8, auth.?, "DPoP ") or auth.?.len <= "DPoP ".len) {
            return error.UnexpectedRequest;
        }
        if (value.method == .post and (content_type == null or !std.mem.eql(u8, content_type.?, "application/json"))) {
            return error.UnexpectedRequest;
        }

        // The proof must carry an `ath` claim (access-token hash) and must be
        // fresh: no two requests in one client lifetime reuse a proof. The
        // payload segment is decoded before the claim check because base64url
        // never preserves the literal bytes.
        if (!proofHasAth(auth.?)) return error.UnexpectedRequest;
        var proof_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(auth.?, &proof_hash, .{});
        if (self.previous_proof_hash) |previous| {
            if (std.mem.eql(u8, &previous, &proof_hash)) return error.UnexpectedRequest;
        }
        self.previous_proof_hash = proof_hash;

        const proof_copy = try allocator.dupe(u8, auth.?);
        errdefer allocator.free(proof_copy);
        const url_copy = try allocator.dupe(u8, value.url);
        errdefer allocator.free(url_copy);
        const body_copy = try allocator.dupe(u8, value.body);
        errdefer allocator.free(body_copy);
        try self.requests.append(allocator, .{
            .method = value.method,
            .url = url_copy,
            .proof = proof_copy,
            .body = body_copy,
        });

        const selected = self.scripted[self.next];
        self.next += 1;
        var nonce_buf: [32]u8 = undefined;
        const nonce = std.fmt.bufPrint(&nonce_buf, "pds-nonce-{d}", .{self.next}) catch unreachable;
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "dpop-nonce", .value = nonce },
        };
        return transport.Response.initCopy(allocator, selected.status, &headers, selected.body, value.limits);
    }
};

test "getRecord success returns bound uri cid value and refreshes pds nonce" {
    const scripted = [_]XrpcMock.Scripted{.{
        .status = 200,
        .body = "{\"uri\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides~intro\",\"cid\":\"bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4\",\"value\":{\"site\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self\",\"title\":\"Intro\",\"path\":\"/guides/intro.html\"},\"validationStatus\":\"valid\"}",
    }};
    var mock = XrpcMock.init(std.testing.allocator, &scripted);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var client = SessionClient.init(try testBinding(), mock.client(), proofs.source());

    const result = try client.getRecord(std.testing.allocator, "site.standard.document", "guides~intro");
    var found = switch (result) {
        .found => |response| response,
        .not_found => return error.UnexpectedRequest,
    };
    defer found.deinit();
    try std.testing.expectEqualStrings("at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides~intro", found.uri);
    try std.testing.expectEqualStrings("bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4", found.cid.?);
    try std.testing.expectEqualStrings("valid", found.validation_status.?);
    try std.testing.expect(found.value.value == .object);
    try std.testing.expectEqualStrings("Intro", found.value.value.object.get("value").?.object.get("title").?.string);
    try std.testing.expectEqual(@as(usize, 1), mock.requests.items.len);
    try std.testing.expectEqualStrings(
        "https://pds.example.com/xrpc/com.atproto.repo.getRecord?repo=did:plc:ewvi7nxzyoun6zhxrhs64oiz&collection=site.standard.document&rkey=guides~intro",
        mock.requests.items[0].url,
    );
    try std.testing.expectEqualStrings("pds-nonce-1", client.pds_nonce.slice());
}

test "getRecord classifies missing records without failing the request" {
    const scripted = [_]XrpcMock.Scripted{.{
        .status = 400,
        .body = "{\"error\":\"RecordNotFound\",\"message\":\"Could not locate record\"}",
    }};
    var mock = XrpcMock.init(std.testing.allocator, &scripted);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var client = SessionClient.init(try testBinding(), mock.client(), proofs.source());
    const result = try client.getRecord(std.testing.allocator, "site.standard.document", "missing");
    try std.testing.expect(result == .not_found);
}

test "putRecord writes the exact canonical record bytes and validates the response identity" {
    const record = "{\"site\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self\",\"title\":\"Intro\",\"path\":\"/guides/intro.html\",\"publishedAt\":\"2026-01-20T14:30:00.000Z\"}";
    const scripted = [_]XrpcMock.Scripted{.{
        .status = 200,
        .body = "{\"uri\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides~intro\",\"cid\":\"bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4\",\"validationStatus\":\"valid\"}",
    }};
    var mock = XrpcMock.init(std.testing.allocator, &scripted);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var client = SessionClient.init(try testBinding(), mock.client(), proofs.source());

    var result = try client.putRecord(std.testing.allocator, "site.standard.document", "guides~intro", record, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides~intro", result.uri);
    try std.testing.expectEqual(@as(usize, 1), mock.requests.items.len);
    try std.testing.expectEqualStrings("https://pds.example.com/xrpc/com.atproto.repo.putRecord", mock.requests.items[0].url);
    const expected_body = "{\"repo\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"collection\":\"site.standard.document\",\"rkey\":\"guides~intro\",\"record\":" ++ record ++ "}";
    try std.testing.expectEqualStrings(expected_body, mock.requests.items[0].body);
}

test "putRecord rejects a response whose AT-URI does not match the request" {
    const record = "{\"title\":\"x\"}";
    const scripted = [_]XrpcMock.Scripted{.{
        .status = 200,
        .body = "{\"uri\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/other\",\"cid\":\"bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4\"}",
    }};
    var mock = XrpcMock.init(std.testing.allocator, &scripted);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var client = SessionClient.init(try testBinding(), mock.client(), proofs.source());
    try std.testing.expectError(error.WrongRecordIdentity, client.putRecord(std.testing.allocator, "site.standard.document", "guides~intro", record, null));
}

test "deleteRecord posts the bound triple" {
    const scripted = [_]XrpcMock.Scripted{.{
        .status = 200,
        .body = "{\"commit\":\"bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4\"}",
    }};
    var mock = XrpcMock.init(std.testing.allocator, &scripted);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var client = SessionClient.init(try testBinding(), mock.client(), proofs.source());
    var result = try client.deleteRecord(std.testing.allocator, "site.standard.document", "old-rkey", null);
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "{\"repo\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"collection\":\"site.standard.document\",\"rkey\":\"old-rkey\"}",
        mock.requests.items[0].body,
    );
}

test "use_dpop_nonce is retried once with a fresh proof and fails closed on a second challenge" {
    const retried = [_]XrpcMock.Scripted{
        .{ .status = 400, .body = "{\"error\":\"use_dpop_nonce\",\"message\":\"Nonce required\"}" },
        .{ .status = 200, .body = "{\"uri\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides~intro\",\"cid\":\"bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4\",\"value\":{\"title\":\"Intro\"}}" },
    };
    var mock = XrpcMock.init(std.testing.allocator, &retried);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var client = SessionClient.init(try testBinding(), mock.client(), proofs.source());
    const result = try client.getRecord(std.testing.allocator, "site.standard.document", "guides~intro");
    var found = switch (result) {
        .found => |response| response,
        .not_found => return error.UnexpectedRequest,
    };
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 2), mock.requests.items.len);
    // The second proof must be a fresh proof (mock rejects repeated hashes).
    try std.testing.expectEqualStrings("pds-nonce-2", client.pds_nonce.slice());

    const challenged = [_]XrpcMock.Scripted{
        .{ .status = 400, .body = "{\"error\":\"use_dpop_nonce\",\"message\":\"Nonce required\"}" },
        .{ .status = 400, .body = "{\"error\":\"use_dpop_nonce\",\"message\":\"Still required\"}" },
    };
    var challenged_mock = XrpcMock.init(std.testing.allocator, &challenged);
    defer challenged_mock.deinit();
    var second_proofs = TestProofSource{};
    var second_client = SessionClient.init(try testBinding(), challenged_mock.client(), second_proofs.source());
    try std.testing.expectError(
        error.DpopNonceRepeated,
        second_client.getRecord(std.testing.allocator, "site.standard.document", "guides~intro"),
    );
}

test "hostile responses fail closed: redirect, bad JSON, wrong did" {
    // Redirect: transport forbidden policy rejects it before the mock.
    const redirect = [_]XrpcMock.Scripted{.{
        .status = 302,
        .body = "",
    }};
    var redirect_mock = XrpcMock.init(std.testing.allocator, &redirect);
    defer redirect_mock.deinit();
    var proofs = TestProofSource{};
    var client = SessionClient.init(try testBinding(), redirect_mock.client(), proofs.source());
    try std.testing.expectError(
        error.RedirectRejected,
        client.getRecord(std.testing.allocator, "site.standard.document", "guides~intro"),
    );

    // Malformed JSON body.
    const malformed = [_]XrpcMock.Scripted{.{
        .status = 200,
        .body = "{not json",
    }};
    var malformed_mock = XrpcMock.init(std.testing.allocator, &malformed);
    defer malformed_mock.deinit();
    var malformed_proofs = TestProofSource{};
    var malformed_client = SessionClient.init(try testBinding(), malformed_mock.client(), malformed_proofs.source());
    try std.testing.expectError(
        error.InvalidResponse,
        malformed_client.getRecord(std.testing.allocator, "site.standard.document", "guides~intro"),
    );

    // Response URI binds a different DID than the session.
    const wrong_did = [_]XrpcMock.Scripted{.{
        .status = 200,
        .body = "{\"uri\":\"at://did:plc:otherxxxxxxxxxxxxxxxxxx/site.standard.document/guides~intro\",\"cid\":\"bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4\"}",
    }};
    var wrong_mock = XrpcMock.init(std.testing.allocator, &wrong_did);
    defer wrong_mock.deinit();
    var wrong_proofs = TestProofSource{};
    var wrong_client = SessionClient.init(try testBinding(), wrong_mock.client(), wrong_proofs.source());
    try std.testing.expectError(
        error.WrongRecordIdentity,
        wrong_client.getRecord(std.testing.allocator, "site.standard.document", "guides~intro"),
    );
}

const BearerMock = struct {
    call: usize = 0,

    fn client(self: *BearerMock) transport.Client {
        return .{ .context = self, .request_fn = request };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: transport.Request,
    ) transport.Error!transport.Response {
        const self: *BearerMock = @ptrCast(@alignCast(context));
        if (self.call >= 1 or value.method != .get or value.redirect_policy != .forbid) {
            return error.UnexpectedRequest;
        }
        var auth: ?[]const u8 = null;
        for (value.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                if (auth != null) return error.UnexpectedRequest;
                auth = header.value;
            }
        }
        if (auth == null or !std.mem.eql(u8, auth.?, "Bearer access-token")) return error.UnexpectedRequest;
        self.call += 1;
        // No dpop-nonce header: Bearer requests never require or track one.
        const headers = [_]transport.Header{.{
            .name = "content-type",
            .value = "application/json",
        }};
        return transport.Response.initCopy(
            allocator,
            200,
            &headers,
            "{\"uri\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides~intro\",\"cid\":\"bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4\",\"value\":{\"title\":\"Intro\"}}",
            value.limits,
        );
    }
};

test "bearer session sends the access token directly and skips the DPoP nonce" {
    var mock = BearerMock{};
    var client = SessionClient.fromBearerSession(
        try identity.Did.parse(test_did_text),
        try identity.Origin.parse(test_pds),
        "access-token",
        mock.client(),
    );
    const result = try client.getRecord(std.testing.allocator, "site.standard.document", "guides~intro");
    var found = switch (result) {
        .found => |response| response,
        .not_found => return error.UnexpectedRequest,
    };
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 1), mock.call);
    try std.testing.expectEqualStrings("Intro", found.value.value.object.get("value").?.object.get("title").?.string);
}

test "a response without a pds nonce fails closed" {
    const NoNonceMock = struct {
        fn request(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            value: transport.Request,
        ) transport.Error!transport.Response {
            const headers = [_]transport.Header{.{
                .name = "content-type",
                .value = "application/json",
            }};
            return transport.Response.initCopy(
                allocator,
                200,
                &headers,
                "{\"uri\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides~intro\",\"cid\":\"bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4\"}",
                value.limits,
            );
        }
    };
    var no_nonce = NoNonceMock{};
    var proofs = TestProofSource{};
    var client = SessionClient.init(try testBinding(), .{ .context = &no_nonce, .request_fn = NoNonceMock.request }, proofs.source());
    try std.testing.expectError(
        error.InvalidNonce,
        client.getRecord(std.testing.allocator, "site.standard.document", "guides~intro"),
    );
}
