//! NIP-42 public policy, narrow signing interface and independent verification.
//! No transport, process launch or key ingestion lives here.
const std = @import("std");
const nostr = @import("nostr.zig");
const keys = @import("nostr_keys.zig");
const json_out = @import("json_out.zig");

pub const revision = "656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab";
pub const format = "boris-nostr-auth-ipc";
pub const version: u32 = 1;
pub const max_frame: usize = 32768;
pub const max_challenge: usize = 4096;
pub const session_ms: u32 = 600000;
pub const teardown_ms: u32 = 1000;
pub const Declaration = struct { mode: []const u8, relays: []const []const u8 };

/// Artifact readers remain tolerant of unrelated legacy fields, but the new
/// auth declaration itself is closed, even under that tolerant outer parser.
pub fn checkDeclarationShape(gpa: std.mem.Allocator, bytes: []const u8) !void {
    const Envelope = struct { delivery: struct { auth: std.json.Value } };
    var envelope = try std.json.parseFromSlice(Envelope, gpa, bytes, .{ .ignore_unknown_fields = true });
    defer envelope.deinit();
    const value = envelope.value.delivery.auth;
    if (value != .object or value.object.count() != 2 or !value.object.contains("mode") or !value.object.contains("relays")) return error.InvalidAuth;
}

pub fn contains(relays: []const []const u8, relay: []const u8) bool {
    for (relays) |r| if (std.mem.eql(u8, r, relay)) return true;
    return false;
}

pub fn validateDeclaration(gpa: std.mem.Allocator, auth: Declaration, relays: []const []const u8) !void {
    if (!std.mem.eql(u8, auth.mode, "nip42") or auth.relays.len == 0 or auth.relays.len > nostr.max_relays) return error.InvalidAuth;
    for (auth.relays, 0..) |r, i| {
        if (r.len > 1024 or !std.unicode.utf8ValidateSlice(r) or !contains(relays, r)) return error.InvalidAuth;
        const normalized = try nostr.normalizeRelayUrl(gpa, r);
        defer gpa.free(normalized);
        if (!std.mem.eql(u8, r, normalized)) return error.InvalidAuth;
        if (i > 0 and std.mem.order(u8, auth.relays[i - 1], r) != .lt) return error.InvalidAuth;
    }
}

pub fn validateVersion(schema: u32, auth: ?Declaration) !void {
    if (schema != (if (auth == null) @as(u32, 1) else 2)) return error.InvalidAuthSchema;
}

pub fn writeDeclaration(out: *std.ArrayList(u8), gpa: std.mem.Allocator, relays: []const []const u8) !void {
    try out.appendSlice(gpa, "{\"mode\":\"nip42\",\"relays\":[");
    for (relays, 0..) |r, i| {
        if (i != 0) try out.appendSlice(gpa, ",");
        try json_out.writeString(out, gpa, r);
    }
    try out.appendSlice(gpa, "]}");
}

pub const Deadline = struct {
    end: i96,
    pub fn after(io: std.Io, ms: u32) Deadline {
        return .{ .end = std.Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, ms) * std.time.ns_per_ms };
    }
    pub fn remaining(self: Deadline, io: std.Io) !u32 {
        return self.at(std.Io.Timestamp.now(io, .awake).nanoseconds);
    }
    pub fn at(self: Deadline, now: i96) !u32 {
        if (now >= self.end) return error.Timeout;
        return @intCast(@min(std.math.maxInt(u32), @divFloor(self.end - now + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }
    pub fn clip(self: Deadline, other: Deadline) Deadline {
        return .{ .end = @min(self.end, other.end) };
    }
};

pub const Policy = struct {
    plan_digest: []const u8,
    bundle_digest: []const u8,
    nips_revision: []const u8,
    pubkey: []const u8,
    relays: []const []const u8,
    timeout_ms: u32,
};
pub const Correlation = struct {
    plan_digest: []const u8,
    bundle_digest: []const u8,
    nips_revision: []const u8,
    run: []const u8,
    connection: []const u8,
    request: u64,
    relay: []const u8,
    generation: u8,
};
pub const Ready = struct { format: []const u8 = format, version: u32 = version, type: []const u8 = "ready", policy: Policy };
pub const Begin = struct { format: []const u8 = format, version: u32 = version, type: []const u8 = "begin", run: []const u8 };
pub const Request = struct { format: []const u8 = format, version: u32 = version, type: []const u8 = "sign", correlation: Correlation, challenge: []const u8 };
pub const Control = struct { format: []const u8 = format, version: u32 = version, type: []const u8, correlation: Correlation };
pub const Finish = struct { format: []const u8 = format, version: u32 = version, type: []const u8 = "finish" };
pub const Event = struct {
    id: []const u8,
    pubkey: []const u8,
    created_at: i64,
    kind: u32,
    tags: []const []const []const u8,
    content: []const u8,
    sig: []const u8,
};
pub const Response = struct {
    format: []const u8 = format,
    version: u32 = version,
    type: []const u8 = "response",
    correlation: Correlation,
    refusal: ?[]const u8,
    event: ?Event,
};

pub fn hex(text: []const u8, n: usize) bool {
    if (text.len != n) return false;
    for (text) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub fn challengeValid(challenge: []const u8) !void {
    if (challenge.len > max_challenge) return error.Oversized;
    if (challenge.len == 0 or !std.unicode.utf8ValidateSlice(challenge)) return error.Malformed;
    for (challenge) |c| if (c < 32 or c == 127) return error.Malformed;
}

/// Bound nesting before the JSON parser allocates. Strings do not count.
pub fn checkJson(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > max_frame) return error.Oversized;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Malformed;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false;
        } else if (c == '"') {
            quoted = true;
        } else if (c == '[' or c == '{') {
            depth += 1;
            if (depth > 8) return error.Malformed;
        } else if (c == ']' or c == '}') {
            if (depth == 0) return error.Malformed;
            depth -= 1;
        }
    }
    if (quoted or depth != 0) return error.Malformed;
}

pub fn parse(comptime T: type, gpa: std.mem.Allocator, bytes: []const u8, wanted: []const u8) !std.json.Parsed(T) {
    try checkJson(bytes);
    var shape = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.Malformed;
    defer shape.deinit();
    if (shape.value != .object) return error.Malformed;
    inline for (std.meta.fields(T)) |field| {
        if (!shape.value.object.contains(field.name)) return error.Malformed;
    }
    const parsed = std.json.parseFromSlice(T, gpa, bytes, .{ .allocate = .alloc_always }) catch return error.Malformed;
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.format, format) or parsed.value.version != version or !std.mem.eql(u8, parsed.value.type, wanted)) return error.SessionInvalid;
    return parsed;
}

pub fn equalPolicy(a: Policy, b: Policy) bool {
    if (!std.mem.eql(u8, a.plan_digest, b.plan_digest) or !std.mem.eql(u8, a.bundle_digest, b.bundle_digest) or
        !std.mem.eql(u8, a.nips_revision, b.nips_revision) or !std.mem.eql(u8, a.pubkey, b.pubkey) or
        a.timeout_ms != b.timeout_ms or a.relays.len != b.relays.len) return false;
    for (a.relays, b.relays) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

pub fn equalCorrelation(a: Correlation, b: Correlation) bool {
    inline for (.{ "plan_digest", "bundle_digest", "nips_revision", "run", "connection", "relay" }) |field| {
        if (!std.mem.eql(u8, @field(a, field), @field(b, field))) return false;
    }
    return a.request == b.request and a.generation == b.generation;
}

pub const Budget = struct {
    used: [nostr.max_relays]u8 = @splat(0),
    retired: [nostr.max_relays]bool = @splat(false),
    connections: [nostr.max_relays][32]u8 = undefined,
    hashes: [nostr.max_relays][2][32]u8 = undefined,
    last_request: u64 = 0,
    pub fn admit(self: *Budget, policy: Policy, run: []const u8, request: Request) !usize {
        const c = request.correlation;
        if (!hex(run, 32) or !hex(c.connection, 32) or !std.mem.eql(u8, run, c.run) or
            !std.mem.eql(u8, policy.plan_digest, c.plan_digest) or !std.mem.eql(u8, policy.bundle_digest, c.bundle_digest) or
            !std.mem.eql(u8, policy.nips_revision, c.nips_revision) or c.request <= self.last_request) return error.SessionInvalid;
        try challengeValid(request.challenge);
        var index: ?usize = null;
        for (policy.relays, 0..) |r, i| if (std.mem.eql(u8, r, c.relay)) {
            index = i;
            break;
        };
        const i = index orelse return error.RelayMismatch;
        if (self.retired[i] or self.used[i] >= 2 or c.generation != self.used[i] + 1) return error.ReplacementLimit;
        if (self.used[i] != 0 and !std.mem.eql(u8, &self.connections[i], c.connection)) return error.SessionInvalid;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(request.challenge, &hash, .{});
        for (self.hashes[i][0..self.used[i]]) |old| if (std.mem.eql(u8, &old, &hash)) return error.Replay;
        @memcpy(&self.connections[i], c.connection);
        self.hashes[i][self.used[i]] = hash;
        self.used[i] += 1;
        self.last_request = c.request;
        return i;
    }
};

pub fn sign(gpa: std.mem.Allocator, ctx: keys.Context, pair: keys.KeyPair, pubkey: []const u8, relay: []const u8, challenge: []const u8, now: i64, aux: [32]u8) ![]u8 {
    try challengeValid(challenge);
    const tags = [_]nostr.Tag{ .{ .name = "relay", .value = relay }, .{ .name = "challenge", .value = challenge } };
    var preimage: std.ArrayList(u8) = .empty;
    defer preimage.deinit(gpa);
    try nostr.appendEventPreimage(&preimage, gpa, pubkey, now, 22242, &tags, "");
    var id: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(preimage.items, &id, .{});
    const sig = try ctx.signId(id, pair, aux);
    if (!ctx.verify(sig, id, pair.public_key)) return error.SignatureInvalid;
    const id_hex = std.fmt.bytesToHex(id, .lower);
    const sig_hex = std.fmt.bytesToHex(sig, .lower);
    const relay_tag = [_][]const u8{ "relay", relay };
    const challenge_tag = [_][]const u8{ "challenge", challenge };
    const event: Event = .{ .id = &id_hex, .pubkey = pubkey, .created_at = now, .kind = 22242, .tags = &.{ &relay_tag, &challenge_tag }, .content = "", .sig = &sig_hex };
    return std.json.Stringify.valueAlloc(gpa, event, .{});
}

pub fn verify(gpa: std.mem.Allocator, event: Event, pubkey: []const u8, relay: []const u8, challenge: []const u8, now: i64) !void {
    if (!hex(pubkey, 64) or !std.mem.eql(u8, event.pubkey, pubkey)) return error.IdentityMismatch;
    if (event.created_at < 0 or @abs(@as(i128, event.created_at) - now) > 60) return error.Stale;
    if (event.kind != 22242 or event.content.len != 0 or event.tags.len != 2 or
        event.tags[0].len != 2 or event.tags[1].len != 2 or
        !std.mem.eql(u8, event.tags[0][0], "relay") or !std.mem.eql(u8, event.tags[1][0], "challenge")) return error.Malformed;
    if (!std.mem.eql(u8, event.tags[0][1], relay)) return error.RelayMismatch;
    if (!std.mem.eql(u8, event.tags[1][1], challenge)) return error.Malformed;
    if (!hex(event.id, 64)) return error.EventIdMismatch;
    if (!hex(event.sig, 128)) return error.SignatureInvalid;
    const tags = [_]nostr.Tag{ .{ .name = "relay", .value = relay }, .{ .name = "challenge", .value = challenge } };
    var preimage: std.ArrayList(u8) = .empty;
    defer preimage.deinit(gpa);
    try nostr.appendEventPreimage(&preimage, gpa, pubkey, event.created_at, 22242, &tags, "");
    var id: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(preimage.items, &id, .{});
    const id_hex = std.fmt.bytesToHex(id, .lower);
    if (!std.mem.eql(u8, event.id, &id_hex)) return error.EventIdMismatch;
    var sig: [64]u8 = undefined;
    var pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig, event.sig) catch return error.SignatureInvalid;
    _ = std.fmt.hexToBytes(&pk, pubkey) catch return error.IdentityMismatch;
    var ctx = try keys.Context.init();
    defer ctx.deinit();
    if (!ctx.verify(sig, id, pk)) return error.SignatureInvalid;
}

test "auth IPC rejects duplicates, unknown fields, trailing bytes and nesting" {
    const a = std.testing.allocator;
    inline for (.{ "{\"format\":\"boris-nostr-auth-ipc\",\"version\":1,\"type\":\"finish\",\"extra\":0}", "{\"format\":\"boris-nostr-auth-ipc\",\"version\":1,\"version\":1,\"type\":\"finish\"}", "{\"type\":\"finish\"}", "{\"format\":\"boris-nostr-auth-ipc\",\"version\":1,\"type\":\"finish\"}x" }) |bad| {
        try std.testing.expectError(error.Malformed, parse(Finish, a, bad, "finish"));
    }
    try std.testing.expectError(error.Malformed, checkJson("[[[[[[[[[]]]]]]]]]"));
}

test "auth local challenge and non-renewing deadline boundaries" {
    try challengeValid("x" ** max_challenge);
    try std.testing.expectError(error.Oversized, challengeValid("x" ** (max_challenge + 1)));
    for ([_][]const u8{ "", "x\n", "\xff", "\x7f" }) |bad| try std.testing.expectError(error.Malformed, challengeValid(bad));
    const deadline: Deadline = .{ .end = 600000 * std.time.ns_per_ms };
    try std.testing.expectEqual(@as(u32, 1), try deadline.at(deadline.end - 1));
    try std.testing.expectError(error.Timeout, deadline.at(deadline.end));
}

test "new artifact auth declaration stays closed under tolerant outer readers" {
    try checkDeclarationShape(std.testing.allocator, "{\"delivery\":{\"auth\":{\"mode\":\"nip42\",\"relays\":[\"wss://r.example\"]}},\"legacy\":\"ignored\"}");
    try std.testing.expectError(error.InvalidAuth, checkDeclarationShape(std.testing.allocator, "{\"delivery\":{\"auth\":{\"mode\":\"nip42\",\"relays\":[\"wss://r.example\"],\"helper\":\"forbidden\"}}}"));
}
