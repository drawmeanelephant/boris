//! Custody supervisor. Spawn/exec/ready precede the only key read.
const std = @import("std");
const builtin = @import("builtin");
const auth = @import("nostr_auth.zig");
const ipc = @import("nostr_auth_ipc.zig");
const publish = @import("nostr_publish.zig");
const keys = @import("nostr_keys.zig");
const nostr = @import("nostr.zig");

// Custody is currently implemented with Darwin's explicit descriptor allowlist.
// Other platforms must refuse, not approximate this security boundary.
pub const supported = builtin.os.tag == .macos;

fn signal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    ipc.canceled.store(true, .unordered);
}
pub fn installCancellation() void {
    if (comptime supported) {
        ipc.canceled.store(false, .unordered);
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = signal }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
        std.posix.sigaction(std.posix.SIG.INT, &action, null);
        std.posix.sigaction(std.posix.SIG.TERM, &action, null);
        const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
        std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    }
}

fn check(rc: c_int) !void {
    if (rc != 0) return error.LaunchFailed;
}

fn pipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.LaunchFailed;
    for (fds) |fd| if (std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) < 0) {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return error.LaunchFailed;
    };
    return fds;
}

fn spawn(io: std.Io, gpa: std.mem.Allocator, plan: []const u8, bundle: []const u8, report: ?[]const u8, input: std.c.fd_t, output: std.c.fd_t) !std.c.pid_t {
    if (comptime !supported) return error.UnsupportedPlatform;
    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);
    const plan_z = try gpa.dupeZ(u8, plan);
    defer gpa.free(plan_z);
    const bundle_z = try gpa.dupeZ(u8, bundle);
    defer gpa.free(bundle_z);
    const report_z = if (report) |r| try gpa.dupeZ(u8, r) else null;
    defer if (report_z) |r| gpa.free(r);
    var argv: [14:null]?[*:0]const u8 = @splat(null);
    argv[0..10].* = .{ executable.ptr, "nostr", "publish", "--plan", plan_z.ptr, "--bundle", bundle_z.ptr, "--auth-pipes", "3,4", "--quiet" };
    if (report_z) |r| {
        argv[10] = "--out";
        argv[11] = r.ptr;
    }
    const env = [_:null]?[*:0]const u8{};
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    try check(std.c.posix_spawn_file_actions_init(&actions));
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    var attr: std.c.posix_spawnattr_t = undefined;
    try check(std.c.posix_spawnattr_init(&attr));
    defer _ = std.c.posix_spawnattr_destroy(&attr);
    try check(std.c.posix_spawnattr_setflags(&attr, .{ .CLOEXEC_DEFAULT = true }));
    try check(std.c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", 0, 0));
    try check(std.c.posix_spawn_file_actions_addinherit_np(&actions, 1));
    try check(std.c.posix_spawn_file_actions_addinherit_np(&actions, 2));
    // Pipe endpoints were allocated in order: input cannot be descriptor 4,
    // so duplicating it to 3 cannot destroy the source for output -> 4.
    try check(std.c.posix_spawn_file_actions_adddup2(&actions, input, 3));
    try check(std.c.posix_spawn_file_actions_adddup2(&actions, output, 4));
    try check(std.c.posix_spawn_file_actions_addinherit_np(&actions, 3));
    try check(std.c.posix_spawn_file_actions_addinherit_np(&actions, 4));
    var pid: std.c.pid_t = undefined;
    try check(std.c.posix_spawn(&pid, executable, &actions, &attr, &argv, &env));
    return pid;
}

fn reap(io: std.Io, pid: std.c.pid_t, deadline: auth.Deadline) !u8 {
    while (true) {
        var status: c_int = 0;
        const got = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (got == pid) {
            const bits: u32 = @bitCast(status);
            if (!std.c.W.IFEXITED(bits)) return error.ChildFailed;
            return std.c.W.EXITSTATUS(bits);
        }
        if (got < 0) return error.ChildFailed;
        _ = try deadline.remaining(io);
        try (std.Io.Timeout{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(10) } }).sleep(io);
    }
}

fn terminate(io: std.Io, pid: std.c.pid_t, deadline: auth.Deadline) void {
    _ = std.c.kill(pid, std.posix.SIG.TERM);
    if (reap(io, pid, deadline)) |_| return else |_| {}
    _ = std.c.kill(pid, std.posix.SIG.KILL);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
}

fn readKey(reader: *std.Io.Reader) !?[]const u8 {
    return reader.takeDelimiter('\n');
}

fn readKeyGuarded(channel: *ipc.Channel, reader: *std.Io.Reader) !?[]const u8 {
    const U = union(enum) { key: anyerror!?[]const u8, lost: anyerror!void };
    var slots: [2]U = undefined;
    var select: std.Io.Select(U) = .init(channel.io, &slots);
    defer while (select.cancel()) |_| {};
    try select.concurrent(.key, readKey, .{reader});
    try select.concurrent(.lost, ipc.Channel.monitor, .{channel});
    const result = try select.await();
    return switch (result) {
        .key => |key| key,
        .lost => error.Canceled,
    };
}

pub fn supervise(io: std.Io, gpa: std.mem.Allocator, plan_path: []const u8, bundle_path: []const u8, report_path: ?[]const u8) !u8 {
    if (comptime !supported) return error.UnsupportedPlatform;
    installCancellation();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plan_bytes = try std.Io.Dir.cwd().readFileAlloc(io, plan_path, gpa, .limited(@import("nostr_sign.zig").max_plan_bytes));
    defer gpa.free(plan_bytes);
    const bundle_bytes = try std.Io.Dir.cwd().readFileAlloc(io, bundle_path, gpa, .limited(@import("nostr_sign.zig").max_plan_bytes));
    defer gpa.free(bundle_bytes);
    const plan = try publish.preflight(gpa, arena, plan_bytes, bundle_bytes);
    const declaration = plan.delivery.auth orelse return error.InvalidAuth;
    var plan_digest: [64]u8 = undefined;
    var bundle_digest: [64]u8 = undefined;
    nostr.digestHex(plan_bytes, &plan_digest);
    nostr.digestHex(bundle_bytes, &bundle_digest);
    const policy: auth.Policy = .{ .plan_digest = &plan_digest, .bundle_digest = &bundle_digest, .nips_revision = auth.revision, .pubkey = plan.author.expected_pubkey, .relays = declaration.relays, .timeout_ms = plan.delivery.timeout_ms };

    const to_child = try pipe();
    defer _ = std.c.close(to_child[1]);
    var input_open = true;
    defer if (input_open) {
        _ = std.c.close(to_child[0]);
    };
    const to_parent = try pipe();
    defer _ = std.c.close(to_parent[0]);
    var output_open = true;
    defer if (output_open) {
        _ = std.c.close(to_parent[1]);
    };
    const pid = try spawn(io, gpa, plan_path, bundle_path, report_path, to_child[0], to_parent[1]);
    var child_live = true;
    var teardown_deadline: ?auth.Deadline = null;
    defer if (child_live) terminate(io, pid, teardown_deadline orelse auth.Deadline.after(io, auth.teardown_ms));
    _ = std.c.close(to_child[0]);
    input_open = false;
    _ = std.c.close(to_parent[1]);
    output_open = false;
    var channel = try ipc.Channel.init(io, to_parent[0], to_child[1]);
    channel.frame_timeout_ms = policy.timeout_ms;
    const ready_bytes = try channel.read(gpa, auth.Deadline.after(io, policy.timeout_ms));
    defer gpa.free(ready_bytes);
    var ready = try auth.parse(auth.Ready, gpa, ready_bytes, "ready");
    defer ready.deinit();
    if (!auth.equalPolicy(policy, ready.value.policy)) return error.SessionInvalid;

    // No key-bearing state existed at process creation or in the exec child.
    const no_core: std.c.rlimit = .{ .cur = 0, .max = 0 };
    if (std.c.setrlimit(.CORE, &no_core) != 0) return error.CustodyUnavailable;
    var input_buf: [130]u8 = undefined;
    defer std.crypto.secureZero(u8, &input_buf);
    var reader = std.Io.File.stdin().reader(io, &input_buf);
    const raw = try @import("ws_client.zig").raceDeadline(io, policy.timeout_ms, readKeyGuarded, .{ &channel, &reader.interface });
    const key_text = std.mem.trim(u8, raw orelse "", " \t\r\n");
    if (key_text.len == 0 or (if (raw) |text| text.len else 0) > 128) return error.InvalidKey;
    var secret: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    if (!nostr.decodeSecretKey(key_text, &secret)) return error.InvalidKey;
    var ctx = try keys.Context.initRandomized(io);
    defer ctx.deinit();
    var pair = try ctx.keyPairFromSecretKey(secret);
    defer std.crypto.secureZero(u8, &pair.secret_key);
    const pubkey = std.fmt.bytesToHex(pair.public_key, .lower);
    if (!std.mem.eql(u8, &pubkey, policy.pubkey)) return error.IdentityMismatch;
    // Input no longer needed while waiting on a live relay.
    std.crypto.secureZero(u8, &input_buf);
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    channel.run = std.fmt.bytesToHex(nonce, .lower);
    channel.ceiling = auth.Deadline.after(io, auth.session_ms);
    try channel.send(gpa, auth.Begin{ .run = &channel.run }, auth.Deadline.after(io, policy.timeout_ms));
    var budget: auth.Budget = .{};
    var last: ?auth.Correlation = null;
    var canceled_request = false;
    var retired_request = false;
    var signing_disabled = false;
    while (true) {
        const bytes = channel.read(gpa, channel.ceiling.?) catch |err| {
            if (err == error.Timeout) {
                std.crypto.secureZero(u8, &secret);
                std.crypto.secureZero(u8, &pair.secret_key);
                teardown_deadline = auth.Deadline.after(io, auth.teardown_ms);
                const code = try reap(io, pid, teardown_deadline.?);
                child_live = false;
                return code;
            }
            return err;
        };
        defer gpa.free(bytes);
        var value = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        defer value.deinit();
        if (value.value != .object) return error.SessionInvalid;
        const type_value = value.value.object.get("type") orelse return error.SessionInvalid;
        if (type_value != .string) return error.SessionInvalid;
        if (std.mem.eql(u8, type_value.string, "finish")) {
            var finish = try auth.parse(auth.Finish, gpa, bytes, "finish");
            defer finish.deinit();
            std.crypto.secureZero(u8, &secret);
            std.crypto.secureZero(u8, &pair.secret_key);
            teardown_deadline = auth.Deadline.after(io, auth.teardown_ms);
            const code = try reap(io, pid, teardown_deadline.?);
            child_live = false;
            return code;
        }
        if (std.mem.eql(u8, type_value.string, "retire") or std.mem.eql(u8, type_value.string, "cancel")) {
            var control = try auth.parse(auth.Control, gpa, bytes, type_value.string);
            defer control.deinit();
            if (last == null or !auth.equalCorrelation(last.?, control.value.correlation)) return error.SessionInvalid;
            if (std.mem.eql(u8, type_value.string, "retire")) {
                if (retired_request) return error.SessionInvalid;
                retired_request = true;
                for (policy.relays, 0..) |r, i| if (std.mem.eql(u8, r, control.value.correlation.relay)) {
                    budget.retired[i] = true;
                };
            } else {
                if (canceled_request or retired_request) return error.SessionInvalid;
                canceled_request = true;
            }
            continue;
        }
        var request = try auth.parse(auth.Request, gpa, bytes, "sign");
        defer request.deinit();
        _ = try budget.admit(policy, &channel.run, request.value);
        canceled_request = false;
        retired_request = false;
        last = request.value.correlation;
        // Keep correlation alive independently of the transient request parse.
        var saved = try std.json.Stringify.valueAlloc(arena, last.?, .{});
        const parsed_saved = try std.json.parseFromSlice(auth.Correlation, arena, saved, .{});
        last = parsed_saved.value;
        _ = &saved;
        var aux: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &aux);
        io.randomSecure(&aux) catch {
            signing_disabled = true;
        };
        const event_bytes = if (!signing_disabled) auth.sign(gpa, ctx, pair, policy.pubkey, request.value.correlation.relay, request.value.challenge, std.Io.Timestamp.now(io, .real).toSeconds(), aux) catch blk: {
            signing_disabled = true;
            break :blk null;
        } else null;
        if (event_bytes == null) {
            try channel.send(gpa, auth.Response{ .correlation = request.value.correlation, .refusal = "signer-refused", .event = null }, auth.Deadline.after(io, policy.timeout_ms).clip(channel.ceiling.?));
            continue;
        }
        defer gpa.free(event_bytes.?);
        var event = try std.json.parseFromSlice(auth.Event, gpa, event_bytes.?, .{});
        defer event.deinit();
        try channel.send(gpa, auth.Response{ .correlation = request.value.correlation, .refusal = null, .event = event.value }, auth.Deadline.after(io, policy.timeout_ms).clip(channel.ceiling.?));
    }
}

pub fn childBegin(channel: *ipc.Channel, gpa: std.mem.Allocator, policy: auth.Policy) !void {
    if (comptime !supported) return error.UnsupportedPlatform;
    installCancellation();
    channel.frame_timeout_ms = policy.timeout_ms;
    try channel.send(gpa, auth.Ready{ .policy = policy }, auth.Deadline.after(channel.io, policy.timeout_ms));
    const bytes = try channel.read(gpa, auth.Deadline.after(channel.io, policy.timeout_ms));
    defer gpa.free(bytes);
    var begin = try auth.parse(auth.Begin, gpa, bytes, "begin");
    defer begin.deinit();
    if (!auth.hex(begin.value.run, 32)) return error.SessionInvalid;
    @memcpy(&channel.run, begin.value.run);
    channel.ceiling = auth.Deadline.after(channel.io, auth.session_ms);
}
