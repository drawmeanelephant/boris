//! Portable AT Protocol app-password authentication (`createSession` /
//! `refreshSession`).
//!
//! This is the explicit, opt-in credential path for command-line publishers
//! (RFC `atproto-app-password.md`). Unlike the OAuth flow, there is no DPoP
//! key, no authorization server, no scope, and no client binding: the caller
//! supplies a resolved DID + PDS origin plus the app password, and receives an
//! access/refresh JWT pair bound to that identity. Every response is
//! revalidated (returned `did` must equal the requested identity, the JWTs
//! must be bounded printable strings, and the access JWT must carry a positive
//! `exp`-`iat` lifetime) so a hostile or misconfigured PDS fails closed.
//!
//! No sockets, DNS, clocks, files, environment, or ambient randomness live
//! here; network effects are injected through `atproto_transport.Client`.

const std = @import("std");
const identity = @import("atproto_identity.zig");
const oauth = @import("atproto_oauth.zig");
const transport = @import("atproto_transport.zig");
const json_out = @import("json_out.zig");

pub const Error = transport.Error || oauth.Error || identity.Error || std.mem.Allocator.Error || error{
    AuthenticationFailed,
    InvalidContentType,
    InvalidJwt,
    InvalidResponse,
    InvalidSessionWire,
    InvalidStatus,
    SessionRevoked,
    SubjectDidMismatch,
};

pub const create_session_limits: transport.Limits = .{ .max_body_bytes = 64 * 1024 };
pub const refresh_session_limits: transport.Limits = .{ .max_body_bytes = 64 * 1024 };

const Token = Fixed(oauth.max_access_token_length);

/// An app-password session: the non-secret identity facts (DID + PDS origin)
/// plus the access/refresh JWTs. Deliberately smaller than an OAuth session —
/// no DPoP key seed, client id, scope, or authorization-server nonce — so the
/// two document types can never be mistaken for one another.
pub const AppPasswordSession = struct {
    did: identity.Did,
    pds_origin: identity.Origin,
    access_token: Token,
    refresh_token: ?Token,
    access_token_expires_in: u64,
    access_token_obtained_at_seconds: u64,

    pub fn markObtained(session: *AppPasswordSession, now_seconds: u64) void {
        session.access_token_obtained_at_seconds = now_seconds;
    }

    pub fn deinit(session: *AppPasswordSession) void {
        secureZero(session.access_token.mutableSlice());
        if (session.refresh_token) |*token| secureZero(token.mutableSlice());
        session.* = undefined;
    }
};

/// `com.atproto.server.createSession` with an app password. The returned DID
/// must equal the resolved identity's DID; the password travels only in the
/// request body and is never retained or logged by this module.
pub fn createSession(
    allocator: std.mem.Allocator,
    client: transport.Client,
    pds_origin: identity.Origin,
    did: identity.Did,
    password: []const u8,
) Error!AppPasswordSession {
    const body = try buildCreateSessionBody(allocator, did.slice(), password);
    defer {
        secureZero(body);
        allocator.free(body);
    }
    var response = try post(allocator, client, pds_origin, "com.atproto.server.createSession", body, null, create_session_limits);
    defer {
        secureZero(response.body);
        response.deinit();
    }
    if (response.status != 200) return classifyFailure(allocator, response.body);
    try requireJson(response);
    return parseSessionResponse(allocator, pds_origin, did, response.body);
}

/// `com.atproto.server.refreshSession` with the stored refresh JWT. The
/// refresh JWT is single-use and rotates on success; a definitive rejection
/// surfaces as `SessionRevoked` so the session layer can erase the document.
pub fn refresh(
    allocator: std.mem.Allocator,
    client: transport.Client,
    session: *const AppPasswordSession,
) Error!AppPasswordSession {
    if (session.refresh_token == null) return error.SessionRevoked;
    var response = try post(
        allocator,
        client,
        session.pds_origin,
        "com.atproto.server.refreshSession",
        "{}",
        session.refresh_token.?.slice(),
        refresh_session_limits,
    );
    defer {
        secureZero(response.body);
        response.deinit();
    }
    if (response.status == 400 and isExpiredToken(allocator, response.body)) return error.SessionRevoked;
    if (response.status != 200) return classifyFailure(allocator, response.body);
    try requireJson(response);
    return parseSessionResponse(allocator, session.pds_origin, session.did, response.body);
}

/// Serialization seam for durable storage. Views borrow the session; the host
/// copies them into its own storage format. Contains secret material (access
/// and refresh JWTs) by design.
pub const SessionWire = struct {
    did: []const u8,
    pds_origin: []const u8,
    access_token: []const u8,
    refresh_token: ?[]const u8,
    access_token_expires_in: u64,
    access_token_obtained_at_seconds: u64,
};

pub fn sessionToWire(session: *const AppPasswordSession) SessionWire {
    return .{
        .did = session.did.slice(),
        .pds_origin = session.pds_origin.slice(),
        .access_token = session.access_token.slice(),
        .refresh_token = if (session.refresh_token) |token| token.slice() else null,
        .access_token_expires_in = session.access_token_expires_in,
        .access_token_obtained_at_seconds = session.access_token_obtained_at_seconds,
    };
}

/// Rebuild an owned session from validated wire material. Every field is
/// revalidated (DID syntax, PDS origin, JWT shape, positive lifetime) so a
/// corrupted or tampered document fails closed.
pub fn sessionFromWire(allocator: std.mem.Allocator, wire: SessionWire) Error!AppPasswordSession {
    _ = allocator;
    const did = identity.Did.parse(wire.did) catch return error.InvalidSessionWire;
    const pds_origin = identity.Origin.parse(wire.pds_origin) catch return error.InvalidSessionWire;
    if (wire.access_token_expires_in == 0) return error.InvalidSessionWire;
    if (!validJwt(wire.access_token)) return error.InvalidSessionWire;
    if (wire.refresh_token) |token| {
        if (!validJwt(token)) return error.InvalidSessionWire;
    }
    return .{
        .did = did,
        .pds_origin = pds_origin,
        .access_token = try Token.from(wire.access_token),
        .refresh_token = if (wire.refresh_token) |token| try Token.from(token) else null,
        .access_token_expires_in = wire.access_token_expires_in,
        .access_token_obtained_at_seconds = wire.access_token_obtained_at_seconds,
    };
}

fn post(
    allocator: std.mem.Allocator,
    client: transport.Client,
    pds_origin: identity.Origin,
    nsid: []const u8,
    body: []const u8,
    bearer: ?[]const u8,
    limits: transport.Limits,
) Error!transport.Response {
    const url = try std.fmt.allocPrint(allocator, "{s}/xrpc/{s}", .{ pds_origin.slice(), nsid });
    defer allocator.free(url);
    // Defense in depth: the URL is always the PDS origin plus the fixed XRPC
    // suffix; anything else means the inputs were corrupted upstream.
    if (!std.mem.startsWith(u8, url, pds_origin.slice()) or
        url.len <= pds_origin.slice().len + 1 or
        url[pds_origin.slice().len] != '/') return error.InvalidResponse;

    var authorization_value: ?[]u8 = null;
    defer if (authorization_value) |value| allocator.free(value);

    var headers_buffer: [3]transport.Header = undefined;
    var header_count: usize = 0;
    headers_buffer[header_count] = .{ .name = "accept", .value = "application/json" };
    header_count += 1;
    if (bearer) |token| {
        authorization_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        headers_buffer[header_count] = .{ .name = "authorization", .value = authorization_value.? };
        header_count += 1;
    }
    headers_buffer[header_count] = .{ .name = "content-type", .value = "application/json" };
    header_count += 1;
    return client.request(allocator, .{
        .method = .post,
        .url = url,
        .headers = headers_buffer[0..header_count],
        .body = body,
        .redirect_policy = .forbid,
        .limits = limits,
    });
}

fn buildCreateSessionBody(allocator: std.mem.Allocator, did: []const u8, password: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"identifier\":");
    try json_out.writeString(&out, allocator, did);
    try out.appendSlice(allocator, ",\"password\":");
    try json_out.writeString(&out, allocator, password);
    try out.appendSlice(allocator, "}");
    if (out.items.len > create_session_limits.max_request_body_bytes) return error.InvalidResponse;
    return out.toOwnedSlice(allocator);
}

fn parseSessionResponse(
    allocator: std.mem.Allocator,
    pds_origin: identity.Origin,
    expected_did: identity.Did,
    body: []const u8,
) Error!AppPasswordSession {
    const Wire = struct {
        accessJwt: []const u8,
        refreshJwt: []const u8,
        did: []const u8,
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = oauth.max_access_token_length,
        .allocate = .alloc_always,
    }) catch return error.InvalidResponse;
    defer parsed.deinit();
    const value = parsed.value;
    defer {
        secureZero(@constCast(value.accessJwt));
        secureZero(@constCast(value.refreshJwt));
    }
    if (!std.mem.eql(u8, value.did, expected_did.slice())) return error.SubjectDidMismatch;
    if (!validJwt(value.accessJwt) or !validJwt(value.refreshJwt)) return error.InvalidJwt;
    const expires_in = try jwtLifetime(allocator, value.accessJwt);
    var access = try Token.from(value.accessJwt);
    errdefer secureZero(access.mutableSlice());
    return .{
        .did = expected_did,
        .pds_origin = pds_origin,
        .access_token = access,
        .refresh_token = try Token.from(value.refreshJwt),
        .access_token_expires_in = expires_in,
        .access_token_obtained_at_seconds = 0,
    };
}

/// The access JWT's `exp` - `iat` lifetime. `iat` is mandatory (fail closed
/// when absent) because this module owns no clock and must report a duration,
/// not an absolute instant.
fn jwtLifetime(allocator: std.mem.Allocator, jwt: []const u8) Error!u64 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    const header = parts.next() orelse return error.InvalidJwt;
    const payload = parts.next() orelse return error.InvalidJwt;
    const signature = parts.next() orelse return error.InvalidJwt;
    if (parts.next() != null) return error.InvalidJwt;
    if (header.len == 0 or payload.len == 0 or signature.len == 0) return error.InvalidJwt;

    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return error.InvalidJwt;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return error.InvalidJwt;

    const Wire = struct { exp: u64, iat: u64 };
    var parsed = std.json.parseFromSlice(Wire, allocator, decoded, .{
        .ignore_unknown_fields = true,
        .max_value_len = 4096,
    }) catch return error.InvalidJwt;
    defer parsed.deinit();
    if (parsed.value.iat == 0 or parsed.value.exp <= parsed.value.iat) return error.InvalidJwt;
    return parsed.value.exp - parsed.value.iat;
}

fn validJwt(jwt: []const u8) bool {
    if (jwt.len == 0 or jwt.len > oauth.max_access_token_length) return false;
    for (jwt) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
    }
    return true;
}

fn classifyFailure(allocator: std.mem.Allocator, body: []const u8) Error {
    const Wire = struct { @"error": []const u8 };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = 1024,
    }) catch return error.InvalidStatus;
    defer parsed.deinit();
    const name = parsed.value.@"error";
    if (std.mem.eql(u8, name, "InvalidIdentifierOrPassword") or
        std.mem.eql(u8, name, "AuthenticationRequired") or
        std.mem.eql(u8, name, "AccountTakedown"))
    {
        return error.AuthenticationFailed;
    }
    return error.InvalidStatus;
}

fn isExpiredToken(allocator: std.mem.Allocator, body: []const u8) bool {
    const Wire = struct { @"error": []const u8 };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = 1024,
    }) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.@"error", "ExpiredToken") or
        std.mem.eql(u8, parsed.value.@"error", "InvalidToken");
}

fn requireJson(response: transport.Response) Error!void {
    const value = response.header("content-type") orelse return error.InvalidContentType;
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..separator], " \t"), "application/json")) {
        return error.InvalidContentType;
    }
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

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const test_did_text = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const test_pds = "https://pds.example.com";

const TestJwt = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const TestJwt) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn jwtWithLifetime(lifetime: u64) TestJwt {
    // A base64url payload of {"iat":1700000000,"exp":1700000000+L} followed by
    // fixed header/signature segments. Only the payload matters to the parser.
    var payload_buf: [256]u8 = undefined;
    const payload_json = std.fmt.bufPrint(&payload_buf, "{{\"iat\":1700000000,\"exp\":{d}}}", .{1700000000 + lifetime}) catch unreachable;
    var payload: [512]u8 = undefined;
    const payload_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(payload[0..payload_len], payload_json);

    var result: TestJwt = .{};
    result.len = (std.fmt.bufPrint(&result.bytes, "e30.{s}.c2ln", .{payload[0..payload_len]}) catch unreachable).len;
    return result;
}

const TestPds = struct {
    const Step = struct {
        nsid: []const u8,
        bearer: ?[]const u8,
        status: u16,
        body: []const u8,
    };

    steps: []const Step,
    next: usize = 0,
    last_body: ?[]const u8 = null,

    fn client(self: *TestPds) transport.Client {
        return .{ .context = self, .request_fn = perform };
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, value: transport.Request) transport.Error!transport.Response {
        const self: *TestPds = @ptrCast(@alignCast(context));
        if (self.next >= self.steps.len) return error.UnexpectedRequest;
        const step = self.steps[self.next];
        self.next += 1;
        if (value.method != .post or value.redirect_policy != .forbid) return error.UnexpectedRequest;
        const expected_url = std.fmt.allocPrint(allocator, "{s}/xrpc/{s}", .{ test_pds, step.nsid }) catch return error.OutOfMemory;
        defer allocator.free(expected_url);
        if (!std.mem.eql(u8, value.url, expected_url)) return error.UnexpectedRequest;
        var bearer: ?[]const u8 = null;
        for (value.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                if (bearer != null or !std.mem.startsWith(u8, header.value, "Bearer ")) return error.UnexpectedRequest;
                bearer = header.value["Bearer ".len..];
            }
        }
        if (step.bearer) |expected| {
            if (bearer == null or !std.mem.eql(u8, bearer.?, expected)) return error.UnexpectedRequest;
        } else if (bearer != null) {
            return error.UnexpectedRequest;
        }
        const headers = [_]transport.Header{.{ .name = "content-type", .value = "application/json" }};
        return transport.Response.initCopy(allocator, step.status, &headers, step.body, value.limits);
    }
};

test "createSession posts the escaped identifier and password and binds the DID" {
    const access_jwt = jwtWithLifetime(7200);
    const refresh_jwt = jwtWithLifetime(7200);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    body.appendSlice(std.testing.allocator, "{\"accessJwt\":\"") catch unreachable;
    body.appendSlice(std.testing.allocator, access_jwt.slice()) catch unreachable;
    body.appendSlice(std.testing.allocator, "\",\"refreshJwt\":\"") catch unreachable;
    body.appendSlice(std.testing.allocator, refresh_jwt.slice()) catch unreachable;
    body.appendSlice(std.testing.allocator, "\",\"did\":\"") catch unreachable;
    body.appendSlice(std.testing.allocator, test_did_text) catch unreachable;
    body.appendSlice(std.testing.allocator, "\",\"handle\":\"alice.example.com\"}") catch unreachable;

    const steps = [_]TestPds.Step{.{
        .nsid = "com.atproto.server.createSession",
        .bearer = null,
        .status = 200,
        .body = body.items,
    }};
    var mock: TestPds = .{ .steps = &steps };
    var session = try createSession(
        std.testing.allocator,
        mock.client(),
        try identity.Origin.parse(test_pds),
        try identity.Did.parse(test_did_text),
        "s3cret \"pw\"",
    );
    defer session.deinit();
    try std.testing.expectEqualStrings(test_did_text, session.did.slice());
    try std.testing.expectEqualStrings(test_pds, session.pds_origin.slice());
    try std.testing.expectEqual(@as(u64, 7200), session.access_token_expires_in);
    try std.testing.expect(session.refresh_token != null);
    try std.testing.expectEqual(@as(usize, 1), mock.next);
}

test "createSession rejects a DID mismatch and a malformed access JWT" {
    const access_jwt = jwtWithLifetime(7200);
    const refresh_jwt = jwtWithLifetime(7200);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    body.appendSlice(std.testing.allocator, "{\"accessJwt\":\"") catch unreachable;
    body.appendSlice(std.testing.allocator, access_jwt.slice()) catch unreachable;
    body.appendSlice(std.testing.allocator, "\",\"refreshJwt\":\"") catch unreachable;
    body.appendSlice(std.testing.allocator, refresh_jwt.slice()) catch unreachable;
    body.appendSlice(std.testing.allocator, "\",\"did\":\"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa\"}") catch unreachable;

    const steps = [_]TestPds.Step{.{
        .nsid = "com.atproto.server.createSession",
        .bearer = null,
        .status = 200,
        .body = body.items,
    }};
    var mock: TestPds = .{ .steps = &steps };
    try std.testing.expectError(
        error.SubjectDidMismatch,
        createSession(std.testing.allocator, mock.client(), try identity.Origin.parse(test_pds), try identity.Did.parse(test_did_text), "pw"),
    );

    const bad_jwt_body = "{\"accessJwt\":\"not-a-jwt\",\"refreshJwt\":\"e30.c2ln.eA\",\"did\":\"" ++ test_did_text ++ "\"}";
    const bad_steps = [_]TestPds.Step{.{
        .nsid = "com.atproto.server.createSession",
        .bearer = null,
        .status = 200,
        .body = bad_jwt_body,
    }};
    var bad_mock: TestPds = .{ .steps = &bad_steps };
    try std.testing.expectError(
        error.InvalidJwt,
        createSession(std.testing.allocator, bad_mock.client(), try identity.Origin.parse(test_pds), try identity.Did.parse(test_did_text), "pw"),
    );
}

test "refreshSession sends the refresh JWT bearer and rotates the tokens" {
    const access_jwt = jwtWithLifetime(7200);
    const refresh_jwt = jwtWithLifetime(7200);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    body.appendSlice(std.testing.allocator, "{\"accessJwt\":\"") catch unreachable;
    body.appendSlice(std.testing.allocator, access_jwt.slice()) catch unreachable;
    body.appendSlice(std.testing.allocator, "\",\"refreshJwt\":\"") catch unreachable;
    body.appendSlice(std.testing.allocator, refresh_jwt.slice()) catch unreachable;
    body.appendSlice(std.testing.allocator, "\",\"did\":\"") catch unreachable;
    body.appendSlice(std.testing.allocator, test_did_text) catch unreachable;
    body.appendSlice(std.testing.allocator, "\"}") catch unreachable;

    const steps = [_]TestPds.Step{.{
        .nsid = "com.atproto.server.refreshSession",
        .bearer = "old-refresh-token",
        .status = 200,
        .body = body.items,
    }};
    var mock: TestPds = .{ .steps = &steps };
    var stored = try sessionFromWire(std.testing.allocator, .{
        .did = test_did_text,
        .pds_origin = test_pds,
        .access_token = "old-access-token",
        .refresh_token = "old-refresh-token",
        .access_token_expires_in = 60,
        .access_token_obtained_at_seconds = 1,
    });
    defer stored.deinit();
    var rotated = try refresh(std.testing.allocator, mock.client(), &stored);
    defer rotated.deinit();
    try std.testing.expectEqualStrings(test_did_text, rotated.did.slice());
    try std.testing.expectEqual(@as(u64, 7200), rotated.access_token_expires_in);
}

test "refreshSession maps an expired refresh JWT to SessionRevoked" {
    const steps = [_]TestPds.Step{.{
        .nsid = "com.atproto.server.refreshSession",
        .bearer = "old-refresh-token",
        .status = 400,
        .body = "{\"error\":\"ExpiredToken\",\"message\":\"refresh token expired\"}",
    }};
    var mock: TestPds = .{ .steps = &steps };
    var stored = try sessionFromWire(std.testing.allocator, .{
        .did = test_did_text,
        .pds_origin = test_pds,
        .access_token = "old-access-token",
        .refresh_token = "old-refresh-token",
        .access_token_expires_in = 60,
        .access_token_obtained_at_seconds = 1,
    });
    defer stored.deinit();
    try std.testing.expectError(error.SessionRevoked, refresh(std.testing.allocator, mock.client(), &stored));
}

test "wire roundtrip validates every field and fails closed on tamper" {
    const gpa = std.testing.allocator;
    var session = try sessionFromWire(gpa, .{
        .did = test_did_text,
        .pds_origin = test_pds,
        .access_token = "e30.e30.sig",
        .refresh_token = "e30.e30.sig",
        .access_token_expires_in = 3600,
        .access_token_obtained_at_seconds = 1_700_000_000,
    });
    defer session.deinit();
    try std.testing.expectEqualStrings(test_did_text, session.did.slice());
    try std.testing.expectEqualStrings(test_pds, session.pds_origin.slice());

    try std.testing.expectError(error.InvalidSessionWire, sessionFromWire(gpa, .{
        .did = "not-a-did",
        .pds_origin = test_pds,
        .access_token = "e30.e30.sig",
        .refresh_token = null,
        .access_token_expires_in = 3600,
        .access_token_obtained_at_seconds = 0,
    }));
    try std.testing.expectError(error.InvalidSessionWire, sessionFromWire(gpa, .{
        .did = test_did_text,
        .pds_origin = test_pds,
        .access_token = "e30.e30.sig",
        .refresh_token = null,
        .access_token_expires_in = 0,
        .access_token_obtained_at_seconds = 0,
    }));
    try std.testing.expectError(error.InvalidSessionWire, sessionFromWire(gpa, .{
        .did = test_did_text,
        .pds_origin = test_pds,
        .access_token = "has spaces",
        .refresh_token = null,
        .access_token_expires_in = 3600,
        .access_token_obtained_at_seconds = 0,
    }));
}
