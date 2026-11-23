const std = @import("std");
const provider = @import("atproto_session_provider.zig");
const store = @import("atproto_session_store.zig");
const authorization = @import("atproto_authorization.zig");
const password = @import("atproto_password.zig");
const transport = @import("atproto_transport.zig");

const test_did = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const test_seed = "CV-DPOP-SEED-CANARY-0123456789XX";

const MemoryChannel = struct {
    incoming: []const u8,
    incoming_owned: bool = false,
    offset: usize = 0,
    outgoing: std.ArrayList(u8) = .empty,

    fn channel(self: *MemoryChannel) provider.Channel {
        return .{ .context = self, .read_fn = read, .write_fn = write };
    }

    fn read(context: *anyopaque, buffer: []u8) provider.Channel.Error!usize {
        const self: *MemoryChannel = @ptrCast(@alignCast(context));
        if (self.offset == self.incoming.len) return 0;
        const count = @min(buffer.len, self.incoming.len - self.offset);
        @memcpy(buffer[0..count], self.incoming[self.offset..][0..count]);
        self.offset += count;
        return count;
    }

    fn write(context: *anyopaque, bytes: []const u8) provider.Channel.Error!void {
        const self: *MemoryChannel = @ptrCast(@alignCast(context));
        self.outgoing.appendSlice(std.testing.allocator, bytes) catch return error.WriteFailed;
    }

    fn deinit(self: *MemoryChannel) void {
        if (self.incoming_owned) std.testing.allocator.free(self.incoming);
        std.crypto.secureZero(u8, self.outgoing.items);
        self.outgoing.deinit(std.testing.allocator);
    }
};

fn frame(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

fn connect(allocator: std.mem.Allocator, memory: *MemoryChannel, suffix: []const u8) !provider.Provider {
    const hello = try frame(allocator, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "hello",
        .instance = "test-instance",
    });
    defer allocator.free(hello);
    memory.incoming = try std.mem.concat(allocator, u8, &.{ hello, suffix });
    memory.incoming_owned = true;
    return provider.Provider.connect(allocator, memory.channel(), "test-instance");
}

fn oauthSession(allocator: std.mem.Allocator, access: []const u8, refresh: []const u8, obtained: u64) !authorization.AuthorizedSession {
    const seed: [32]u8 = test_seed.*;
    return authorization.sessionFromWire(allocator, .{
        .did = test_did,
        .pds_origin = "https://pds.example.com",
        .authorization_server_origin = "https://auth.example.com",
        .authorization_endpoint = "https://auth.example.com/authorize",
        .token_endpoint = "https://auth.example.com/token",
        .pushed_authorization_request_endpoint = "https://auth.example.com/par",
        .verified_handle = null,
        .client_id = "http://localhost?redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Foauth%2Fcallback&scope=atproto%20repo%3Asite.standard.document%20repo%3Asite.standard.publication",
        .scope = "atproto repo:site.standard.document repo:site.standard.publication",
        .access_token = access,
        .refresh_token = refresh,
        .key_seed = &seed,
        .authorization_server_nonce = "nonce",
        .access_token_expires_in = 3600,
        .access_token_obtained_at_seconds = obtained,
    });
}

fn passwordSession(allocator: std.mem.Allocator, access: []const u8, refresh: []const u8, obtained: u64) !password.AppPasswordSession {
    return password.sessionFromWire(allocator, .{
        .did = test_did,
        .pds_origin = "https://pds.example.com",
        .access_token = access,
        .refresh_token = refresh,
        .access_token_expires_in = 3600,
        .access_token_obtained_at_seconds = obtained,
    });
}

fn encodedPassword(allocator: std.mem.Allocator, access: []const u8, refresh: []const u8, obtained: u64) ![]u8 {
    var session = try passwordSession(allocator, access, refresh, obtained);
    defer session.deinit();
    const wire = try store.passwordToWireBytes(allocator, &session);
    defer {
        std.crypto.secureZero(u8, wire);
        allocator.free(wire);
    }
    const size = std.base64.standard.Encoder.calcSize(wire.len);
    const encoded = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(encoded, wire);
    return encoded;
}

const RejectClient = struct {
    fn client(self: *RejectClient) transport.Client {
        return .{ .context = self, .request_fn = request };
    }
    fn request(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) transport.Error!transport.Response {
        return error.UnexpectedRequest;
    }
};

const Proof = struct {
    fn source(self: *Proof) authorization.ProofSource {
        return .{ .context = self, .next_fn = next };
    }
    fn next(_: *anyopaque) authorization.Error!authorization.ProofMaterial {
        return .{ .issued_at = 1_700_000_100, .jti_entropy = @splat(1), .signing_noise = @splat(2) };
    }
};

test "protected fresh load creates no files and keeps canaries out of public outputs" {
    const gpa = std.testing.allocator;
    const encoded = try encodedPassword(gpa, "CANARY-ACCESS", "CANARY-REFRESH", 1_700_000_000);
    defer gpa.free(encoded);
    const response = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 1,
        .operation = "load",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
        .found = true,
        .flavor = "app-password",
        .session = encoded,
    });
    defer gpa.free(response);
    var memory = MemoryChannel{ .incoming = "" };
    defer memory.deinit();
    var p = try connect(gpa, &memory, response);
    defer p.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var reject = RejectClient{};
    var loaded = try p.acquirePassword(test_did, reject.client(), 1_700_000_100);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("CANARY-ACCESS", loaded.access_token.slice());
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(std.testing.io, "sessions", .{}));
    const public_outputs = "boris standard-site publish\nerror: session layer failure\n{\"ok\":false}\n";
    try std.testing.expect(std.mem.indexOf(u8, public_outputs, "CANARY-ACCESS") == null);
    try std.testing.expect(std.mem.indexOf(u8, @errorName(error.ProviderMalformed), "CANARY") == null);
}

test "protected save is acknowledged before login returns and forget is DID-bound" {
    const gpa = std.testing.allocator;
    const save_ack = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 1,
        .operation = "save",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
    });
    defer gpa.free(save_ack);
    const remove_ack = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 2,
        .operation = "remove",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
        .removed = true,
    });
    defer gpa.free(remove_ack);
    var memory = MemoryChannel{ .incoming = "" };
    defer memory.deinit();
    const suffix = try std.mem.concat(gpa, u8, &.{ save_ack, remove_ack });
    defer gpa.free(suffix);
    var p = try connect(gpa, &memory, suffix);
    defer p.deinit();
    var session = try passwordSession(gpa, "INITIAL-ACCESS", "INITIAL-REFRESH", 1_700_000_000);
    defer session.deinit();
    try p.storeNewPassword(test_did, &session);
    try std.testing.expect(try p.remove(test_did));
    try std.testing.expect(std.mem.indexOf(u8, memory.outgoing.items, "\"operation\":\"save\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory.outgoing.items, "\"operation\":\"remove\"") != null);
}

test "provider rejects wrong version, response id, DID, operation, and oversized frame" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "{\"protocol\":\"boris-session-provider\",\"version\":2,\"kind\":\"hello\",\"instance\":\"test-instance\"}\n",
        "{\"protocol\":\"boris-session-provider\",\"version\":1,\"kind\":\"hello\",\"instance\":\"wrong\"}\n",
    };
    for (cases) |incoming| {
        var memory = MemoryChannel{ .incoming = incoming };
        defer memory.deinit();
        try std.testing.expectError(error.ProviderMalformed, provider.Provider.connect(gpa, memory.channel(), "test-instance"));
    }
    var oversized: [provider.max_frame_bytes + 2]u8 = @splat('x');
    oversized[oversized.len - 1] = '\n';
    var memory = MemoryChannel{ .incoming = &oversized };
    defer memory.deinit();
    try std.testing.expectError(error.ProviderMalformed, provider.Provider.connect(gpa, memory.channel(), "test-instance"));
}

test "provider response mismatch fails closed without exposing supplied bytes" {
    const gpa = std.testing.allocator;
    const response = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 99,
        .operation = "remove",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
        .removed = true,
        .secret = "NEVER-REPORT-THIS",
    });
    defer gpa.free(response);
    var memory = MemoryChannel{ .incoming = "" };
    defer memory.deinit();
    var p = try connect(gpa, &memory, response);
    defer p.deinit();
    try std.testing.expectError(error.ProviderMalformed, p.remove(test_did));
}

fn encodedOAuth(allocator: std.mem.Allocator, access: []const u8, refresh: []const u8, obtained: u64) ![]u8 {
    var session = try oauthSession(allocator, access, refresh, obtained);
    defer session.deinit();
    const wire = try store.sessionToWireBytes(allocator, &session);
    defer {
        std.crypto.secureZero(u8, wire);
        allocator.free(wire);
    }
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(wire.len));
    _ = std.base64.standard.Encoder.encode(encoded, wire);
    return encoded;
}

const RefreshMock = struct {
    calls: usize = 0,
    fail: bool = false,

    fn client(self: *RefreshMock) transport.Client {
        return .{ .context = self, .request_fn = request };
    }

    fn request(context: *anyopaque, allocator: std.mem.Allocator, value: transport.Request) transport.Error!transport.Response {
        const self: *RefreshMock = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.fail) return error.Timeout;
        if (value.method != .post or !std.mem.eql(u8, value.url, "https://auth.example.com/token") or
            std.mem.indexOf(u8, value.body, "grant_type=refresh_token") == null) return error.UnexpectedRequest;
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "dpop-nonce", .value = "rotated-nonce" },
        };
        return transport.Response.initCopy(allocator, 200, &headers, "{\"access_token\":\"ROTATED-ACCESS\",\"refresh_token\":\"ROTATED-REFRESH\",\"token_type\":\"DPoP\",\"sub\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"scope\":\"atproto repo:site.standard.document repo:site.standard.publication\",\"expires_in\":7200}", value.limits);
    }
};

test "protected refresh rotation is saved and acknowledged before use" {
    const gpa = std.testing.allocator;
    const encoded = try encodedOAuth(gpa, "OLD-ACCESS", "OLD-REFRESH", 1_700_000_000);
    defer gpa.free(encoded);
    const loaded = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 1,
        .operation = "load",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
        .found = true,
        .flavor = "oauth",
        .session = encoded,
    });
    defer gpa.free(loaded);
    const saved = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 2,
        .operation = "save",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
    });
    defer gpa.free(saved);
    const suffix = try std.mem.concat(gpa, u8, &.{ loaded, saved });
    defer gpa.free(suffix);
    var memory = MemoryChannel{ .incoming = "" };
    defer memory.deinit();
    var p = try connect(gpa, &memory, suffix);
    defer p.deinit();
    var mock = RefreshMock{};
    var proof = Proof{};
    var session = try p.acquire(test_did, mock.client(), proof.source(), 1_700_010_000);
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqualStrings("ROTATED-ACCESS", session.access_token.slice());
    try std.testing.expectEqual(@as(u64, 1_700_010_000), session.access_token_obtained_at_seconds);
    try std.testing.expect(std.mem.indexOf(u8, memory.outgoing.items, "\"operation\":\"save\"") != null);
    const public = "argv=boris standard-site publish\\nenv=HOME=/tmp\\nlog=published\\nreport={}\\nerror=ProviderDenied";
    for ([_][]const u8{ "OLD-ACCESS", "OLD-REFRESH", "ROTATED-ACCESS", "ROTATED-REFRESH", "rotated-nonce", test_seed }) |canary| {
        try std.testing.expect(std.mem.indexOf(u8, public, canary) == null);
    }
}

test "ambiguous refresh forgets stale broker session and fails closed" {
    const gpa = std.testing.allocator;
    const encoded = try encodedOAuth(gpa, "OLD-ACCESS", "OLD-REFRESH", 1_700_000_000);
    defer gpa.free(encoded);
    const loaded = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 1,
        .operation = "load",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
        .found = true,
        .flavor = "oauth",
        .session = encoded,
    });
    defer gpa.free(loaded);
    const removed = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 2,
        .operation = "remove",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
        .removed = true,
    });
    defer gpa.free(removed);
    const suffix = try std.mem.concat(gpa, u8, &.{ loaded, removed });
    defer gpa.free(suffix);
    var memory = MemoryChannel{ .incoming = "" };
    defer memory.deinit();
    var p = try connect(gpa, &memory, suffix);
    defer p.deinit();
    var mock = RefreshMock{ .fail = true };
    var proof = Proof{};
    try std.testing.expectError(error.RefreshAmbiguous, p.acquire(test_did, mock.client(), proof.source(), 1_700_010_000));
    try std.testing.expect(std.mem.indexOf(u8, memory.outgoing.items, "\"operation\":\"remove\"") != null);
}

test "initial app password arrives only through an acknowledged broker response" {
    const gpa = std.testing.allocator;
    const response = try frame(gpa, .{
        .protocol = provider.protocol_name,
        .version = provider.protocol_version,
        .kind = "response",
        .id = 1,
        .operation = "app-password",
        .did = test_did,
        .instance = "test-instance",
        .status = "ok",
        .app_password = "CANARY-APP-PASSWORD",
    });
    defer gpa.free(response);
    var memory = MemoryChannel{ .incoming = "" };
    defer memory.deinit();
    var p = try connect(gpa, &memory, response);
    defer p.deinit();
    const secret = try p.readAppPassword(test_did);
    defer {
        std.crypto.secureZero(u8, secret);
        gpa.free(secret);
    }
    try std.testing.expectEqualStrings("CANARY-APP-PASSWORD", secret);
    try std.testing.expect(std.mem.indexOf(u8, memory.outgoing.items, "CANARY-APP-PASSWORD") == null);
}

test "wrong operation and DID responses fail closed" {
    const gpa = std.testing.allocator;
    const variants = [_]struct { operation: []const u8, did: []const u8 }{
        .{ .operation = "load", .did = test_did },
        .{ .operation = "remove", .did = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa" },
    };
    for (variants) |variant| {
        const response = try frame(gpa, .{
            .protocol = provider.protocol_name,
            .version = provider.protocol_version,
            .kind = "response",
            .id = 1,
            .operation = variant.operation,
            .did = variant.did,
            .instance = "test-instance",
            .status = "ok",
            .removed = true,
        });
        defer gpa.free(response);
        var memory = MemoryChannel{ .incoming = "" };
        defer memory.deinit();
        var p = try connect(gpa, &memory, response);
        defer p.deinit();
        try std.testing.expectError(error.ProviderMalformed, p.remove(test_did));
    }
}
