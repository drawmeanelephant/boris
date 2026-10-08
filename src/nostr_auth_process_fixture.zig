//! Compile-time-only fault root for the existing Nostr process matrix.
//! Never installed. No production flag, environment override, or helper API.
const std = @import("std");

fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const arr = comptime blk: {
        @setEvalBranchQuota(s.len * n * 4 + 100);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        break :blk out;
    };
    return &arr;
}

const boris = @import("main.zig");
const auth = @import("nostr_auth.zig");
const ipc = @import("nostr_auth_ipc.zig");
const session = @import("nostr_auth_session.zig");
const np = @import("nostr_publish.zig");
const nostr = @import("nostr.zig");
const secp = @import("secp256k1");
const Io = std.Io;

pub const Scenario = enum {
    exec_fail,
    ready_eof,
    ready_silence,
    ready_policy,
    ready_author,
    ready_digest,
    ready_relay,
    ready_revision,
    ready_version,
    ready_unknown,
    ready_truncated,
    begin_run,
    begin_version,
    begin_unknown,
    key_input,
    seed_entropy,
    context_fail,
    randomize_fail,
    keypair_fail,
    aux_entropy,
    sign_fail,
    verify_fail,
    request_extra,
    request_hash,
    request_run,
    request_connection,
    request_relay,
    request_generation,
    request_revision,
    request_digest,
    request_number,
    cancel_before_request,
    cancel_wrong,
    cancel_duplicate,
    retire_wrong,
    retire_duplicate,
    sign_retired,
    control_unknown,
    finish_extra,
    request_eof,
    request_truncated,
    block_begin,
    block_request,
    block_response,
    block_network,
};

var scenario: Scenario = .exec_fail;
var underlying: Io = undefined;
var child_process = false;
var block_input = false;
var reads: std.atomic.Value(usize) = .init(0);
var entropy: std.atomic.Value(usize) = .init(0);
var contexts: std.atomic.Value(usize) = .init(0);
var signs: std.atomic.Value(usize) = .init(0);
var verifies: std.atomic.Value(usize) = .init(0);
var writes: std.atomic.Value(usize) = .init(0);
var cores_disabled: std.atomic.Value(bool) = .init(false);
var ready_validated: std.atomic.Value(bool) = .init(false);

pub const nostr_auth_faults = struct {
    pub fn executablePathAlloc(io: Io, gpa: std.mem.Allocator) ![:0]u8 {
        if (scenario == .exec_fail) return gpa.dupeSentinel(u8, "/nonexistent/boris-nip42-process-fixture", 0);
        return std.process.executablePathAlloc(io, gpa);
    }
    pub fn readyValidated() void {
        ready_validated.store(true, .unordered);
    }
    pub fn beforeSend(channel: *ipc.Channel, kind: []const u8) !void {
        if (!child_process and std.mem.eql(u8, kind, "begin")) switch (scenario) {
            .begin_run => try sendRaw(channel, "{\"format\":\"boris-nostr-auth-ipc\",\"version\":1,\"type\":\"begin\",\"run\":\"not-hex\"}"),
            .begin_version => try sendRaw(channel, "{\"format\":\"boris-nostr-auth-ipc\",\"version\":2,\"type\":\"begin\",\"run\":\"" ++ rep("a", 32) ++ "\"}"),
            .begin_unknown => try sendRaw(channel, "{\"format\":\"boris-nostr-auth-ipc\",\"version\":1,\"type\":\"begin\",\"run\":\"" ++ rep("a", 32) ++ "\",\"extra\":true}"),
            else => {},
        };
        if (!child_process and scenario == .block_request and std.mem.eql(u8, kind, "begin")) block_input = true;
        const block = (!child_process and scenario == .block_begin and std.mem.eql(u8, kind, "begin")) or
            (!child_process and scenario == .block_response and std.mem.eql(u8, kind, "response")) or
            (child_process and scenario == .block_request and std.mem.eql(u8, kind, "sign"));
        if (!block) return;
        // Fill this real nonblocking anonymous pipe while its peer deliberately
        // does not read. The following production send waits on kernel POLLOUT.
        const filler: [1024]u8 = @splat(0);
        while (std.c.write(channel.output, &filler, filler.len) > 0) {}
        var fds = [_]std.c.pollfd{.{ .fd = channel.output, .events = std.posix.POLL.OUT, .revents = 0 }};
        if (std.c.poll(&fds, 1, 0) != 0) return error.PipeNotBlocked;
        std.debug.print("fixture-blocked-{s}\n", .{@tagName(scenario)});
    }
    pub const Pipes = struct {
        pub fn poll(fds: [*]std.c.pollfd, count: std.c.nfds_t, timeout: c_int) c_int {
            const n = std.c.poll(fds, count, timeout);
            // Preserve real HUP/ERR while holding the supervisor's request
            // reader. This creates actual child-writer backpressure.
            if (block_input and !child_process and count == 1 and fds[0].events == std.posix.POLL.IN) {
                fds[0].revents &= ~@as(i16, std.posix.POLL.IN);
                return if (fds[0].revents == 0) 0 else n;
            }
            return n;
        }
    };
    pub const Crypto = struct {
        pub fn secp256k1_context_create(flags: c_uint) ?*secp.secp256k1_context {
            if (reads.load(.unordered) > 0 and scenario == .context_fail) return null;
            const ctx = secp.secp256k1_context_create(flags);
            if (ctx != null) _ = contexts.fetchAdd(1, .monotonic);
            return ctx;
        }
        pub fn secp256k1_context_destroy(ctx: anytype) void {
            secp.secp256k1_context_destroy(ctx);
            _ = contexts.fetchSub(1, .monotonic);
        }
        pub fn secp256k1_context_randomize(ctx: anytype, seed: anytype) c_int {
            if (scenario == .randomize_fail) return 0;
            return secp.secp256k1_context_randomize(ctx, seed);
        }
        pub fn secp256k1_keypair_create(ctx: anytype, pair: anytype, secret: anytype) c_int {
            if (reads.load(.unordered) > 0 and scenario == .keypair_fail) return 0;
            return secp.secp256k1_keypair_create(ctx, pair, secret);
        }
        pub fn secp256k1_schnorrsig_sign32(ctx: anytype, sig: anytype, id: anytype, pair: anytype, aux: anytype) c_int {
            const call = signs.fetchAdd(1, .monotonic) + 1;
            if (scenario == .sign_fail and call == 1) return 0;
            return secp.secp256k1_schnorrsig_sign32(ctx, sig, id, pair, aux);
        }
        pub fn secp256k1_schnorrsig_verify(ctx: anytype, sig: anytype, id: anytype, len: anytype, pubkey: anytype) c_int {
            if (reads.load(.unordered) > 0) {
                const call = verifies.fetchAdd(1, .monotonic) + 1;
                if (scenario == .verify_fail and call == 1) return 0;
            }
            return secp.secp256k1_schnorrsig_verify(ctx, sig, id, len, pubkey);
        }
    };
};

fn operate(_: ?*anyopaque, op: Io.Operation) Io.Cancelable!Io.Operation.Result {
    if (op == .file_read_streaming and op.file_read_streaming.file.handle == 0) {
        std.debug.assert(!child_process and ready_validated.load(.unordered));
        _ = reads.fetchAdd(1, .monotonic);
        var limits: std.c.rlimit = undefined;
        std.debug.assert(std.c.getrlimit(.CORE, &limits) == 0);
        cores_disabled.store(limits.cur == 0 and limits.max == 0, .unordered);
    }
    if (op == .net_write) {
        const call = writes.fetchAdd(1, .monotonic) + 1;
        if (scenario == .block_network and call > 1) {
            std.debug.print("fixture-blocked-block_network\n", .{});
            while (!ipc.canceled.load(.unordered)) try Io.sleep(underlying, .fromMilliseconds(5), .awake);
            return error.Canceled;
        }
    }
    return underlying.vtable.operate(underlying.userdata, op);
}
fn randomSecure(_: ?*anyopaque, bytes: []u8) Io.RandomSecureError!void {
    const call = entropy.fetchAdd(1, .monotonic) + 1;
    if ((scenario == .seed_entropy and call == 1) or (scenario == .aux_entropy and call == 2)) return error.EntropyUnavailable;
    return underlying.randomSecure(bytes);
}

fn sendRaw(channel: *ipc.Channel, bytes: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .big);
    const file: Io.File = .{ .handle = channel.output, .flags = .{ .nonblocking = false } };
    try file.writeStreamingAll(channel.io, &header);
    try file.writeStreamingAll(channel.io, bytes);
}

fn hostileChild(io: Io, gpa: std.mem.Allocator, plan_path: []const u8, bundle_path: []const u8) !void {
    session.installCancellation();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const plan_bytes = try Io.Dir.cwd().readFileAlloc(io, plan_path, a, .limited(16 * 1024 * 1024));
    const bundle_bytes = try Io.Dir.cwd().readFileAlloc(io, bundle_path, a, .limited(16 * 1024 * 1024));
    const plan = try np.preflight(gpa, a, plan_bytes, bundle_bytes);
    var pd: [64]u8 = undefined;
    var bd: [64]u8 = undefined;
    nostr.digestHex(plan_bytes, &pd);
    nostr.digestHex(bundle_bytes, &bd);
    var policy: auth.Policy = .{ .plan_digest = &pd, .bundle_digest = &bd, .nips_revision = auth.revision, .pubkey = plan.author.expected_pubkey, .relays = plan.delivery.auth.?.relays, .timeout_ms = plan.delivery.timeout_ms };
    var channel = try ipc.Channel.init(io, 3, 4);
    channel.frame_timeout_ms = policy.timeout_ms;
    switch (scenario) {
        .ready_eof => return,
        .ready_silence => {
            try channel.monitor();
            return;
        },
        .ready_policy => policy.timeout_ms += 1,
        .ready_author => policy.pubkey = rep("b", 64),
        .ready_digest => policy.bundle_digest = rep("b", 64),
        .ready_relay => policy.relays = &.{"wss://unconsented.example/"},
        .ready_revision => policy.nips_revision = rep("b", 40),
        .ready_version => {
            try channel.send(gpa, .{ .format = "boris-nostr-auth-ipc", .version = @as(u32, 2), .type = "ready", .policy = policy }, auth.Deadline.after(io, 1000));
            try channel.monitor();
            return;
        },
        .ready_unknown => {
            try channel.send(gpa, .{ .format = "boris-nostr-auth-ipc", .version = @as(u32, 1), .type = "ready", .policy = policy, .extra = true }, auth.Deadline.after(io, 1000));
            try channel.monitor();
            return;
        },
        .ready_truncated => {
            const file: Io.File = .{ .handle = 4, .flags = .{ .nonblocking = false } };
            try file.writeStreamingAll(io, &.{ 0, 0, 0, 100, '{' });
            return;
        },
        else => {},
    }
    if (scenario == .block_begin) {
        try channel.send(gpa, auth.Ready{ .policy = policy }, auth.Deadline.after(io, policy.timeout_ms));
        try channel.monitor();
        return;
    }
    try session.childBegin(&channel, gpa, policy);
    if (scenario == .request_eof) return;
    if (scenario == .request_truncated) {
        const file: Io.File = .{ .handle = 4, .flags = .{ .nonblocking = false } };
        try file.writeStreamingAll(io, &.{ 0, 0, 0, 100, '{' });
        return;
    }
    var correlation: auth.Correlation = .{
        .plan_digest = &pd,
        .bundle_digest = &bd,
        .nips_revision = auth.revision,
        .run = &channel.run,
        .connection = rep("a", 32),
        .request = 1,
        .relay = policy.relays[0],
        .generation = 1,
    };
    if (scenario == .cancel_before_request) {
        try channel.send(gpa, auth.Control{ .type = "cancel", .correlation = correlation }, auth.Deadline.after(io, 1000));
    } else if (scenario == .control_unknown) {
        try sendRaw(&channel, "{\"format\":\"boris-nostr-auth-ipc\",\"version\":1,\"type\":\"unknown\"}");
    } else if (scenario == .finish_extra) {
        try sendRaw(&channel, "{\"format\":\"boris-nostr-auth-ipc\",\"version\":1,\"type\":\"finish\",\"extra\":true}");
    } else {
        switch (scenario) {
            .request_run => correlation.run = rep("b", 32),
            .request_connection => correlation.connection = "not-hex",
            .request_relay => correlation.relay = "wss://unconsented.example/",
            .request_generation => correlation.generation = 2,
            .request_revision => correlation.nips_revision = rep("b", 40),
            .request_digest => correlation.plan_digest = rep("b", 64),
            .request_number => correlation.request = 0,
            else => {},
        }
        const request: auth.Request = .{ .correlation = correlation, .challenge = "process-fixture-challenge" };
        if (scenario == .request_extra or scenario == .request_hash) {
            const bytes = try std.json.Stringify.valueAlloc(a, request, .{});
            const poisoned = try std.fmt.allocPrint(a, "{s},\"{s}\":\"{s}\"}}", .{ bytes[0 .. bytes.len - 1], if (scenario == .request_hash) "hash" else "event", rep("0", 64) });
            try sendRaw(&channel, poisoned);
        } else {
            try channel.send(gpa, request, auth.Deadline.after(io, 1000));
            if (scenario == .block_response) {
                try channel.monitor();
                return;
            }
            if (@backingInt(scenario) >= @backingInt(Scenario.cancel_wrong) and @backingInt(scenario) <= @backingInt(Scenario.sign_retired)) {
                const response = try channel.read(gpa, auth.Deadline.after(io, 1000));
                defer gpa.free(response);
                var parsed = try auth.parse(auth.Response, gpa, response, "response");
                defer parsed.deinit();
                if (!auth.equalCorrelation(correlation, parsed.value.correlation) or parsed.value.event == null) return error.TestResponseInvalid;
                const kind: []const u8 = if (scenario == .cancel_wrong or scenario == .cancel_duplicate) "cancel" else "retire";
                if (scenario == .cancel_wrong or scenario == .retire_wrong) correlation.request += 1;
                try channel.send(gpa, auth.Control{ .type = kind, .correlation = correlation }, auth.Deadline.after(io, 1000));
                if (scenario == .cancel_duplicate or scenario == .retire_duplicate) try channel.send(gpa, auth.Control{ .type = kind, .correlation = correlation }, auth.Deadline.after(io, 1000));
                if (scenario == .sign_retired) {
                    correlation.request += 1;
                    correlation.generation = 2;
                    try channel.send(gpa, auth.Request{ .correlation = correlation, .challenge = "second-process-fixture-challenge" }, auth.Deadline.after(io, 1000));
                }
            }
        }
    }
    try channel.monitor();
}

pub fn main(init: std.process.Init) u8 {
    if (comptime !session.supported) return 2;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 3;
    var plan_path: []const u8 = "";
    var bundle_path: []const u8 = "";
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--plan") and i + 1 < args.len) plan_path = args[i + 1];
        if (std.mem.eql(u8, arg, "--bundle") and i + 1 < args.len) bundle_path = args[i + 1];
        if (std.mem.eql(u8, arg, "--auth-pipes")) child_process = true;
    }
    const base = std.fs.path.stem(plan_path);
    scenario = std.meta.stringToEnum(Scenario, base) orelse return 2;
    underlying = init.io;
    var vtable = init.io.vtable.*;
    vtable.operate = operate;
    vtable.randomSecure = randomSecure;
    var wrapped = init;
    wrapped.io.vtable = &vtable;
    const malicious = @backingInt(scenario) <= @backingInt(Scenario.ready_truncated) or
        (@backingInt(scenario) >= @backingInt(Scenario.request_extra) and @backingInt(scenario) <= @backingInt(Scenario.request_truncated)) or
        scenario == .block_begin or scenario == .block_response;
    const code = if (child_process and malicious) blk: {
        hostileChild(wrapped.io, init.gpa, plan_path, bundle_path) catch break :blk @as(u8, 3);
        break :blk @as(u8, 0);
    } else boris.main(wrapped);
    // Counts only, never key input, challenges, signatures or pipe transcripts.
    std.debug.print("fixture-stats child={d} reads={d} entropy={d} contexts={d} signs={d} verifies={d} cores={d}\n", .{
        @intFromBool(child_process),                   reads.load(.unordered), entropy.load(.unordered),
        contexts.load(.unordered),                     signs.load(.unordered), verifies.load(.unordered),
        @intFromBool(cores_disabled.load(.unordered)),
    });
    return code;
}
