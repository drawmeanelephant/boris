//! Hostile mock-relay conformance matrix for `boris nostr publish` (#496).
//!
//! A scripted RFC-6455 server (MockRelay) binds 127.0.0.1 on an ephemeral
//! port and drives `nostr_publish.run` against it over a loopback socket.
//! Every scenario exercises a hostile or awkward relay behavior from the
//! settled #494 contract: fragmented OK, Ping-before-OK, Close-before-OK,
//! a masked server frame, silence (deadline + retry), NOTICE-then-OK,
//! `auth-required:` rejection (NIP-42 out of v1, #493), OK for the wrong
//! event id, garbage text, an oversized declared length, a handshake
//! refusal, and a `ws://localhost` hostname (not `127.0.0.1`) so DNS
//! lookup is gated (#545). The client must never hang, never accept a
//! wrong answer, and must classify every outcome honestly in the report
//! artifact.

const std = @import("std");
const np = @import("nostr_publish.zig");
const keys = @import("nostr_keys.zig");
const nostr = @import("nostr.zig");
const ws = @import("ws_client.zig");
const auth = @import("nostr_auth.zig");
const auth_ipc = @import("nostr_auth_ipc.zig");

const Io = std.Io;
const posix = std.posix;
const testing = std.testing;

const rfc_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const auth_scalar = "0000000000000000000000000000000000000000000000000000000000000003";
const auth_challenge = "raw-auth-challenge-test";

const AuthScenario = enum {
    success,
    rejected,
    auth_required,
    restricted,
    article_rejected,
    challenge_close,
    auth_close,
    empty,
    non_string,
    control,
    extra,
    invalid_utf8,
    garbage,
    oversized,
    frame_oversized,
    masked,
    wrong_ok,
    malformed_ok,
    challenge_silence,
    auth_silence,
    notice_flood,
    partial_message,
    replay,
    replacement,
    third,
    post_article,
    inflight_replacement,
    retry,
    article_silence,
    exact_fragmented,
    oversized_fragmented,
    ping_flood,
    multibyte,
    multibyte_oversized,
    acceptance_close,
    acceptance_large,
    acceptance_auth_required,
    acceptance_rejected,
    acceptance_closed,
    acceptance_premature,
};
const AuthRelay = struct {
    base: MockRelay,
    scenario: AuthScenario,
    expected: []const []const u8,
    saw_auth: usize = 0,
    auth_verified: bool = true,
    exact_articles: bool = true,
    auth_sig: [128]u8 = @splat(0),
    phase: std.atomic.Value(u8) = .init(0),
    acceptance: ?*AcceptanceSync = null,
};

fn makeAuthArtifacts(gpa: std.mem.Allocator, ports: []const u16, subset: []const u16, timeout_ms: u32) !MatrixArtifacts {
    return makeAuthArtifactsWithContent(gpa, ports, subset, timeout_ms, "article bytes");
}

fn makeAuthArtifactsWithContent(gpa: std.mem.Allocator, ports: []const u16, subset: []const u16, timeout_ms: u32, content: []const u8) !MatrixArtifacts {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx = try keys.Context.init();
    defer ctx.deinit();
    const kp = try ctx.keyPairFromSecretKey([_]u8{0} ** 31 ++ [_]u8{3});
    const pubkey = std.fmt.bytesToHex(kp.public_key, .lower);
    const relays = try a.alloc([]const u8, ports.len);
    for (ports, relays) |port, *url| url.* = try std.fmt.allocPrint(a, "ws://127.0.0.1:{d}", .{port});
    const auth_relays = try a.alloc([]const u8, subset.len);
    for (subset, auth_relays) |port, *url| url.* = try std.fmt.allocPrint(a, "ws://127.0.0.1:{d}", .{port});
    std.mem.sort([]const u8, auth_relays, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    const Article = struct { entity_id: []const u8, kind: u32 = 30023, tags: []const []const []const u8, content: []const u8, intention_digest: []const u8 };
    var articles: [2]Article = undefined;
    for ([_][]const u8{ "articles/first", "articles/second" }, &articles) |id, *article| {
        const tags = [_]nostr.Tag{ .{ .name = "d", .value = id }, .{ .name = "published_at", .value = "1000" } };
        var digest: [64]u8 = undefined;
        try nostr.intentionDigestHex(a, &tags, content, &digest);
        const pairs = try a.alloc([]const []const u8, 2);
        pairs[0] = try a.dupe([]const u8, &.{ "d", id });
        pairs[1] = try a.dupe([]const u8, &.{ "published_at", "1000" });
        article.* = .{ .entity_id = id, .tags = pairs, .content = content, .intention_digest = try a.dupe(u8, &digest) };
    }
    const plan = try std.json.Stringify.valueAlloc(gpa, .{
        .format = "boris-nostr-publication-plan",
        .schema_version = @as(u32, 2),
        .protocol = .{ .kind = @as(u32, 30023), .nips_revision = auth.revision },
        .author = .{ .expected_pubkey = &pubkey },
        .delivery = .{ .relays = relays, .timeout_ms = timeout_ms, .retries = @as(u8, 1), .auth = auth.Declaration{ .mode = "nip42", .relays = auth_relays } },
        .articles = &articles,
    }, .{});
    errdefer gpa.free(plan);
    var signed = try @import("nostr_sign.zig").run(testing.io, gpa, .{ .plan = plan, .key = auth_scalar, .created_at = 1700000000, .aux_rand = @splat(0) });
    defer signed.deinit();
    return .{ .plan = plan, .bundle = try gpa.dupe(u8, signed.bundle orelse return error.TestUnexpectedResult) };
}

fn expectedArticles(gpa: std.mem.Allocator, bundle: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(struct { articles: []const np.SignedArticle }, gpa, bundle, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const out = try gpa.alloc([]u8, parsed.value.articles.len);
    for (out, parsed.value.articles) |*wire, article| wire.* = try np.renderEventMessage(gpa, article);
    return out;
}

fn serveAuthThread(relay: *AuthRelay, gpa: std.mem.Allocator) void {
    serveAuth(relay, gpa) catch {};
}
fn acceptAuthRelay(base: *MockRelay) !Io.net.Stream {
    return base.server.accept(base.io);
}
fn serveAuth(relay: *AuthRelay, gpa: std.mem.Allocator) !void {
    const stream = try ws.raceDeadline(relay.base.io, 3000, acceptAuthRelay, .{&relay.base});
    defer stream.close(relay.base.io);
    const fd: std.c.fd_t = @intCast(stream.socket.handle);
    if (relay.acceptance) |sync| sync.relay_fd.store(fd, .release);
    var read_buf: [16384]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    if (!try performHandshakeFd(fd, &read_buf, &write_buf, .ok)) return;
    relay.phase.store(1, .release);
    switch (relay.scenario) {
        .challenge_close => try sendServerClose(fd),
        .empty => try sendServerText(fd, "[\"AUTH\",\"\"]"),
        .non_string => try sendServerText(fd, "[\"AUTH\",7]"),
        .control => try sendServerText(fd, "[\"AUTH\",\"x\\n\"]"),
        .extra => try sendServerText(fd, "[\"AUTH\",\"x\",0]"),
        .invalid_utf8 => try sendServerText(fd, "[\"AUTH\",\"\xff\"]"),
        .garbage => try sendServerText(fd, "garbage"),
        .oversized => {
            const text = "[\"AUTH\",\"" ++ "x" ** 4097 ++ "\"]";
            var frame: [8192]u8 = undefined;
            const n = try ws.encodeFrame(&frame, .text, text, @splat(0), true, false);
            try writeAllFd(fd, frame[0..n]);
        },
        .frame_oversized => try writeAllFd(fd, &.{ 0x81, 126, 0x80, 0x01 }),
        .masked => try sendMaskedServerText(fd, "[\"AUTH\",\"x\"]"),
        .challenge_silence => {},
        .notice_flood, .ping_flood => {
            const end = auth.Deadline.after(relay.base.io, 250);
            while (end.remaining(relay.base.io)) |_| {
                if (relay.scenario == .ping_flood) sendServerPing(fd) catch break else sendServerText(fd, "[\"NOTICE\",\"ignored\"]") catch break;
                std.Io.sleep(relay.base.io, .fromMilliseconds(5), .awake) catch break;
            } else |_| {}
        },
        .partial_message => {
            try writeAllFd(fd, &.{ 0x81, 126, 0, 100, '[' });
            std.Io.sleep(relay.base.io, .fromMilliseconds(250), .awake) catch {};
        },
        .exact_fragmented, .oversized_fragmented => {
            const text = try gpa.alloc(u8, auth.max_frame + @as(usize, if (relay.scenario == .oversized_fragmented) 1 else 0));
            defer gpa.free(text);
            @memset(text, ' ');
            @memcpy(text[0..13], "[\"NOTICE\",\"\"]");
            var frame: [auth.max_frame + 16]u8 = undefined;
            const split = text.len / 2;
            var n = try ws.encodeFrame(&frame, .text, text[0..split], @splat(0), false, false);
            try writeAllFd(fd, frame[0..n]);
            n = try ws.encodeFrame(&frame, .continuation, text[split..], @splat(0), true, false);
            try writeAllFd(fd, frame[0..n]);
            if (relay.scenario == .exact_fragmented) try sendServerText(fd, "[\"AUTH\",\"" ++ auth_challenge ++ "\"]");
        },
        .multibyte => try sendServerText(fd, "[\"AUTH\",\"" ++ "€" ** 1365 ++ "x\"]"),
        .multibyte_oversized => try sendServerText(fd, "[\"AUTH\",\"" ++ "€" ** 1366 ++ "\"]"),
        else => try sendServerText(fd, "[\"AUTH\",\"" ++ auth_challenge ++ "\"]"),
    }
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    while (true) {
        scratch.clearRetainingCapacity();
        const frame = readClientFrame(fd, gpa, &scratch, if (relay.scenario == .acceptance_large) 65536 else auth.max_frame) catch return;
        if (frame.opcode == 8) return;
        if (frame.opcode == 10) continue;
        if (frame.opcode != 1 or !frame.fin) return error.Malformed;
        if (std.mem.startsWith(u8, frame.payload, "[\"AUTH\"")) {
            relay.saw_auth += 1;
            relay.phase.store(2, .release);
            var parsed = try std.json.parseFromSlice(std.json.Value, gpa, frame.payload, .{});
            defer parsed.deinit();
            const event_bytes = try std.json.Stringify.valueAlloc(gpa, parsed.value.array.items[1], .{});
            defer gpa.free(event_bytes);
            var event = try std.json.parseFromSlice(auth.Event, gpa, event_bytes, .{});
            defer event.deinit();
            var url_buf: [80]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{relay.base.port});
            auth.verify(gpa, event.value, "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9", url, if (relay.scenario == .multibyte) "€" ** 1365 ++ "x" else if (relay.saw_auth == 1) auth_challenge else "replacement-challenge", Io.Timestamp.now(relay.base.io, .real).toSeconds()) catch {
                relay.auth_verified = false;
            };
            @memcpy(&relay.auth_sig, event.value.sig);
            const id = event.value.id;
            if (relay.scenario == .auth_close or (relay.scenario == .acceptance_closed and relay.saw_auth == 2)) {
                try sendServerClose(fd);
                continue;
            }
            if (relay.scenario == .auth_silence) continue;
            if (relay.scenario == .replay) {
                try sendServerText(fd, "[\"AUTH\",\"" ++ auth_challenge ++ "\"]");
                continue;
            }
            if ((relay.scenario == .replacement or relay.scenario == .third) and relay.saw_auth == 1) {
                try sendServerText(fd, "[\"AUTH\",\"replacement-challenge\"]");
            } else if (relay.scenario == .third and relay.saw_auth == 2) {
                try sendServerText(fd, "[\"AUTH\",\"third-challenge\"]");
                continue;
            }
            var ok_buf: [512]u8 = undefined;
            const rejection: ?[]const u8 = switch (relay.scenario) {
                .rejected => "blocked: " ++ auth_challenge,
                .auth_required => "auth-required: " ++ auth_challenge,
                .restricted => "restricted: " ++ auth_challenge,
                .acceptance_auth_required => if (relay.saw_auth == 2) "auth-required: " ++ auth_challenge else null,
                .acceptance_rejected => if (relay.saw_auth == 2) "blocked: " ++ auth_challenge else null,
                else => null,
            };
            const ok = if (relay.scenario == .wrong_ok) "[\"OK\",\"" ++ "0" ** 64 ++ "\",true,\"\"]" else if (relay.scenario == .malformed_ok) "[\"OK\",\"" ++ "0" ** 64 ++ "\",true]" else try std.fmt.bufPrint(&ok_buf, "[\"OK\",\"{s}\",{s},\"{s}\"]", .{ id, if (rejection == null) "true" else "false", rejection orelse "" });
            try sendServerText(fd, ok);
        } else if (std.mem.startsWith(u8, frame.payload, "[\"EVENT\"")) {
            relay.base.saw_events += 1;
            relay.phase.store(3, .release);
            if (relay.scenario == .article_silence) continue;
            if (relay.saw_auth == 0) relay.auth_verified = false;
            if (relay.expected.len == 0) {
                relay.exact_articles = false;
                continue;
            }
            const index = if (relay.scenario == .retry) (relay.base.saw_events - 1) -| 1 else relay.base.saw_events - 1;
            const wanted = if (relay.scenario == .retry and relay.base.saw_events <= 2) relay.expected[0] else relay.expected[@min(index, relay.expected.len - 1)];
            if (!std.mem.eql(u8, wanted, frame.payload)) relay.exact_articles = false;
            if (relay.scenario == .retry and relay.base.saw_events == 1) continue;
            const id = try extractEventId(gpa, frame.payload);
            defer gpa.free(id);
            var ok_buf: [512]u8 = undefined;
            if (relay.scenario == .inflight_replacement) {
                try sendServerText(fd, "[\"AUTH\",\"after-write\"]");
                continue;
            }
            const ok = try std.fmt.bufPrint(&ok_buf, "[\"OK\",\"{s}\",{s},\"{s}\"]", .{ id, if (relay.scenario == .article_rejected) "false" else "true", if (relay.scenario == .article_rejected) "restricted: " ++ auth_challenge else "" });
            try sendServerText(fd, ok);
            if (relay.scenario == .post_article) try sendServerText(fd, "[\"AUTH\",\"after-write\"]");
        } else return error.Malformed;
    }
}

fn runAuthProcess(gpa: std.mem.Allocator, plan: []const u8, bundle: []const u8) !std.process.RunResult {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "plan.json", .data = plan });
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle.json", .data = bundle });
    const plan_path = try tmp.dir.realPathFileAlloc(io, "plan.json", gpa);
    defer gpa.free(plan_path);
    const bundle_path = try tmp.dir.realPathFileAlloc(io, "bundle.json", gpa);
    defer gpa.free(bundle_path);
    var child = try std.process.spawn(io, .{ .argv = &.{ @import("nostr_test_binary").path, "nostr", "sign", "--auth-session", "--plan", plan_path, "--bundle", bundle_path, "--key-stdin" }, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    var input_buffer: [256]u8 = undefined;
    var writer = child.stdin.?.writer(io, &input_buffer);
    try writer.interface.writeAll(auth_scalar ++ "\n");
    try writer.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(gpa, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(4096, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(5000) } })) |_| {} else |err| {
        if (err != error.EndOfStream) return err;
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try reader.toOwnedSlice(0), .stderr = try reader.toOwnedSlice(1) };
}

fn authScenario(scenario: AuthScenario, expected_status: []const u8, expected_events: usize, expected_class: []const u8) !void {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    var base = try MockRelay.init(threaded.io(), .ok);
    defer base.deinit();
    var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 150);
    defer artifacts.deinit(gpa);
    const expected = try expectedArticles(gpa, artifacts.bundle);
    defer {
        for (expected) |e| gpa.free(e);
        gpa.free(expected);
    }
    var relay: AuthRelay = .{ .base = base, .scenario = scenario, .expected = expected };
    const thread = try std.Thread.spawn(.{}, serveAuthThread, .{ &relay, gpa });
    const output = runAuthProcess(gpa, artifacts.plan, artifacts.bundle) catch |err| {
        // Cancel a listener if startup failed before connect.
        relay.base.server.deinit(relay.base.io);
        thread.join();
        return err;
    };
    defer gpa.free(output.stdout);
    defer gpa.free(output.stderr);
    if (output.term != .exited or output.term.exited != 0) std.debug.print("auth test process failed: {any}: {s}\n", .{ output.term, output.stderr });
    thread.join();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, output.term);
    var report = try std.json.parseFromSlice(struct {
        classification: []const u8,
        schema_version: u32,
        relays: []const struct { auth: struct { status: []const u8, signing_requests: usize, auth_sends: usize }, attempts: usize },
    }, gpa, output.stdout, .{ .ignore_unknown_fields = true });
    defer report.deinit();
    try testing.expectEqual(@as(u32, 2), report.value.schema_version);
    try testing.expectEqualStrings(expected_status, report.value.relays[0].auth.status);
    try testing.expectEqualStrings(expected_class, report.value.classification);
    // Recording-relay evidence is required, a failure report is not enough.
    try testing.expectEqual(expected_events, relay.base.saw_events);
    try testing.expect(relay.auth_verified);
    try testing.expect(relay.exact_articles);
    try testing.expect(report.value.relays[0].auth.signing_requests <= 2);
    try testing.expect(report.value.relays[0].auth.auth_sends <= 2);
    if (expected_events == 0) try testing.expectEqual(@as(usize, 0), report.value.relays[0].attempts);
    for ([_][]const u8{ output.stdout, output.stderr }) |text| {
        try testing.expect(std.mem.indexOf(u8, text, auth_scalar) == null);
        try testing.expect(std.mem.indexOf(u8, text, auth_challenge) == null);
        try testing.expect(std.mem.indexOf(u8, text, "\"sig\"") == null);
        if (relay.saw_auth > 0) try testing.expect(std.mem.indexOf(u8, text, &relay.auth_sig) == null);
    }
}

test "NIP-42 actual supervisor success sends two unchanged articles after auth OK" {
    try authScenario(.success, "authenticated", 2, "complete");
}
test "NIP-42 rejected auth never writes EVENT, including standardized prefixes" {
    for ([_]AuthScenario{ .rejected, .auth_required, .restricted }) |scenario| try authScenario(scenario, "rejected", 0, "failed");
}
test "NIP-42 auth success is separate from restricted article rejection" {
    try authScenario(.article_rejected, "authenticated", 2, "failed");
}
test "NIP-42 relay Close during challenge or auth OK writes zero articles" {
    for ([_]AuthScenario{ .challenge_close, .auth_close }) |scenario|
        try authScenario(scenario, "closed", 0, "failed");
}
test "NIP-42 malformed and oversized challenges and OKs write zero articles" {
    for ([_]AuthScenario{ .empty, .non_string, .control, .extra, .invalid_utf8, .garbage, .oversized, .frame_oversized, .masked, .wrong_ok, .malformed_ok }) |scenario|
        try authScenario(scenario, "protocol-error", 0, "failed");
}
test "NIP-42 proactive-only silence, notice floods, partial messages and auth silence expire" {
    for ([_]AuthScenario{ .challenge_silence, .notice_flood, .ping_flood, .partial_message, .auth_silence }) |scenario| try authScenario(scenario, "timeout", 0, "incomplete");
}
test "NIP-42 exact-limit auth reassembly and multibyte challenge boundaries" {
    try authScenario(.exact_fragmented, "authenticated", 2, "complete");
    try authScenario(.multibyte, "authenticated", 2, "complete");
    try authScenario(.oversized_fragmented, "protocol-error", 0, "failed");
    try authScenario(.multibyte_oversized, "protocol-error", 0, "failed");
}
test "NIP-42 one replacement retires old OK; repeat and third challenges fail" {
    try authScenario(.replacement, "authenticated", 2, "complete");
    try authScenario(.replay, "protocol-error", 0, "failed");
    try authScenario(.third, "protocol-error", 0, "failed");
}
test "NIP-42 post-write replacement preserves acceptance or unknown in-flight evidence" {
    try authScenario(.post_article, "protocol-error", 1, "partial");
    try authScenario(.inflight_replacement, "protocol-error", 1, "incomplete");
}
test "NIP-42 article retry is byte-identical and consumes no additional auth" {
    try authScenario(.retry, "authenticated", 3, "complete");
}

// The acceptance regressions reuse the recording relay and anonymous-pipe
// interface. Only test Io callbacks schedule the hostile message ordering.
const AcceptanceSync = struct {
    scenario: AuthScenario,
    native: Io,
    owner: std.Thread.Id,
    relay_fd: std.atomic.Value(std.c.fd_t) = .init(-1),
    client_fd: std.atomic.Value(std.c.fd_t) = .init(-1),
    premature_armed: std.atomic.Value(bool) = .init(false),
    verification_seen: bool = false,
    injected: bool = false,
    ok_payload_finished: std.atomic.Value(bool) = .init(false),
    awake_after_ok: usize = 0,
    signer_requests: usize = 0,
    retire_seen: usize = 0,
    signer_error: ?anyerror = null,
    hook_error: ?anyerror = null,
    // netRead deliberately returns one byte, so the final OK payload byte
    // cannot be prefetched before the publisher actually consumes the frame.
    incoming: [256]u8 = undefined,
    incoming_len: usize = 0,
    premature_ok: [128]u8 = undefined,
    premature_ok_len: usize = 0,

    var current: *AcceptanceSync = undefined;

    fn read(userdata: ?*anyopaque, socket: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
        current.client_fd.store(@intCast(socket), .release);
        var one = [_][]u8{data[0][0..1]};
        const n = try current.native.vtable.netRead(userdata, socket, &one);
        if (n == 1) {
            const byte = one[0][0];
            if (current.incoming_len < current.incoming.len) {
                current.incoming[current.incoming_len] = byte;
                current.incoming_len += 1;
            } else {
                std.mem.copyForwards(u8, &current.incoming, current.incoming[1..]);
                current.incoming[current.incoming.len - 1] = byte;
            }
            if (!current.ok_payload_finished.load(.acquire) and std.mem.endsWith(u8, current.incoming[0..current.incoming_len], ",true,\"\"]")) {
                current.ok_payload_finished.store(true, .release);
            }
        }
        return n;
    }

    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        const self = current;
        const timestamp = self.native.vtable.now(userdata, clock);
        if (std.Thread.getCurrentId() != self.owner) return timestamp;
        if (clock == .real and self.premature_armed.load(.acquire)) self.verification_seen = true;
        if (clock != .awake or self.injected) return timestamp;
        if (self.verification_seen) {
            self.injected = true;
            // This is the deadline check immediately after independent event
            // verification. The next loop has active_id, but AUTH is unsent.
            self.queueControl(self.premature_ok[0..self.premature_ok_len]) catch |err| {
                self.hook_error = err;
            };
        } else if (self.ok_payload_finished.load(.acquire) and self.scenario != .acceptance_close) {
            self.awake_after_ok += 1;
            // First: authenticate's next loop checks its original deadline,
            // observes gate=true and returns. Second: publishToRelay checks
            // the session ceiling, strictly before calling beforeArticle.
            if (self.awake_after_ok == 2) {
                self.injected = true;
                self.queueControl("[\"AUTH\",\"replacement-challenge\"]") catch |err| {
                    self.hook_error = err;
                };
            }
        }
        return timestamp;
    }

    fn queueControl(self: *AcceptanceSync, text: []const u8) !void {
        try sendServerText(self.relay_fd.load(.acquire), text);
        // A successful server write alone does not prove arrival at the
        // client. Wait for kernel readability before returning to its gate.
        var fds = [_]std.c.pollfd{.{ .fd = self.client_fd.load(.acquire), .events = posix.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 1000) != 1 or fds[0].revents & posix.POLL.IN == 0) return error.ControlNotQueued;
    }
};

fn acceptanceSignerThread(channel: *auth_ipc.Channel, sync: *AcceptanceSync, policy: auth.Policy, gpa: std.mem.Allocator) void {
    acceptanceSigner(channel, sync, policy, gpa) catch |err| {
        sync.signer_error = err;
    };
}

fn acceptanceSigner(channel: *auth_ipc.Channel, sync: *AcceptanceSync, policy: auth.Policy, gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx = try keys.Context.init();
    defer ctx.deinit();
    const pair = try ctx.keyPairFromSecretKey([_]u8{0} ** 31 ++ [_]u8{3});
    var budget: auth.Budget = .{};
    var last: ?auth.Correlation = null;
    const deadline = auth.Deadline.after(channel.io, 3000);
    while (true) {
        const bytes = try channel.read(gpa, deadline);
        defer gpa.free(bytes);
        var envelope = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        defer envelope.deinit();
        const kind = envelope.value.object.get("type").?.string;
        if (std.mem.eql(u8, kind, "retire") or std.mem.eql(u8, kind, "cancel")) {
            const control = try auth.parse(auth.Control, arena.allocator(), bytes, kind);
            if (last == null or !auth.equalCorrelation(last.?, control.value.correlation)) return error.SessionInvalid;
            if (std.mem.eql(u8, kind, "retire")) {
                sync.retire_seen += 1;
                for (policy.relays, 0..) |relay, i| {
                    if (std.mem.eql(u8, relay, control.value.correlation.relay)) budget.retired[i] = true;
                }
                if (sync.scenario != .acceptance_close or sync.retire_seen == 2) return;
            }
            continue;
        }
        const request = try auth.parse(auth.Request, arena.allocator(), bytes, "sign");
        _ = try budget.admit(policy, "1" ** 32, request.value);
        last = request.value.correlation;
        sync.signer_requests += 1;
        const signed = try auth.sign(gpa, ctx, pair, policy.pubkey, request.value.correlation.relay, request.value.challenge, Io.Timestamp.now(channel.io, .real).toSeconds(), @splat(0));
        defer gpa.free(signed);
        var event = try std.json.parseFromSlice(auth.Event, gpa, signed, .{});
        defer event.deinit();
        if (sync.scenario == .acceptance_close and sync.signer_requests == 1) {
            // The request is outstanding and no response has crossed the pipe.
            try sendServerClose(sync.relay_fd.load(.acquire));
            const retired_bytes = try channel.read(gpa, deadline);
            defer gpa.free(retired_bytes);
            var retired = try auth.parse(auth.Control, gpa, retired_bytes, "retire");
            defer retired.deinit();
            if (!auth.equalCorrelation(last.?, retired.value.correlation)) return error.SessionInvalid;
            sync.retire_seen += 1;
            for (policy.relays, 0..) |relay, i| {
                if (std.mem.eql(u8, relay, retired.value.correlation.relay)) budget.retired[i] = true;
            }
            // Deliberately return the already-computed proof after retirement,
            // just as a synchronous supervisor's in-flight reply can arrive.
        }
        if (sync.scenario == .acceptance_premature) {
            const ok = try std.fmt.bufPrint(&sync.premature_ok, "[\"OK\",\"{s}\",true,\"\"]", .{event.value.id});
            sync.premature_ok_len = ok.len;
            sync.premature_armed.store(true, .release);
        }
        try channel.send(gpa, auth.Response{ .correlation = request.value.correlation, .refusal = null, .event = event.value }, deadline);
    }
}

const AcceptanceReport = struct {
    classification: []const u8,
    relays: []const struct {
        outcome: []const u8,
        attempts: usize,
        auth: struct {
            status: []const u8,
            reason: []const u8,
            signing_requests: usize,
            auth_sends: usize,
            exchanges: []const struct { generation: u8, result: []const u8 },
        },
        events: []const struct { result: []const u8 },
    },
};

fn acceptanceScenario(scenario: AuthScenario) !void {
    if (comptime !auth_ipc.supported) return error.SkipZigTest;
    auth_ipc.canceled.store(false, .unordered);
    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const native = threaded.io();
    var base = try MockRelay.init(native, .ok);
    defer base.deinit();
    var second_base = try MockRelay.init(native, .ok);
    defer second_base.deinit();
    const ports: []const u16 = if (scenario == .acceptance_close) &.{ base.port, second_base.port } else &.{base.port};
    var artifacts = try makeAuthArtifactsWithContent(gpa, ports, ports, 1000, if (scenario == .acceptance_large) "x" ** 40000 else "article bytes");
    defer artifacts.deinit(gpa);
    const expected = try expectedArticles(gpa, artifacts.bundle);
    defer {
        for (expected) |wire| gpa.free(wire);
        gpa.free(expected);
    }
    if (scenario == .acceptance_large) try testing.expect(expected[0].len > auth.max_frame);
    var sync: AcceptanceSync = .{ .scenario = scenario, .native = native, .owner = std.Thread.getCurrentId() };
    AcceptanceSync.current = &sync;
    var vtable = native.vtable.*;
    vtable.netRead = AcceptanceSync.read;
    vtable.now = AcceptanceSync.now;
    const client_io: Io = .{ .userdata = native.userdata, .vtable = &vtable };
    var first: AuthRelay = .{ .base = base, .scenario = scenario, .expected = expected, .acceptance = &sync };
    var second: AuthRelay = .{ .base = second_base, .scenario = .success, .expected = expected };
    var to_child: [2]std.c.fd_t = undefined;
    var to_parent: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&to_child));
    defer for (to_child) |fd| {
        _ = std.c.close(fd);
    };
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&to_parent));
    defer for (to_parent) |fd| {
        _ = std.c.close(fd);
    };
    var child = try auth_ipc.Channel.init(client_io, to_child[0], to_parent[1]);
    child.run = @splat('1');
    child.ceiling = auth.Deadline.after(client_io, auth.session_ms);
    child.frame_timeout_ms = 1000;
    var signer = try auth_ipc.Channel.init(native, to_parent[0], to_child[1]);
    signer.frame_timeout_ms = 1000;
    var plan_digest: [64]u8 = undefined;
    var bundle_digest: [64]u8 = undefined;
    nostr.digestHex(artifacts.plan, &plan_digest);
    nostr.digestHex(artifacts.bundle, &bundle_digest);
    var parsed_plan = try std.json.parseFromSlice(np.PlanJson, gpa, artifacts.plan, .{ .ignore_unknown_fields = true });
    defer parsed_plan.deinit();
    const policy: auth.Policy = .{ .plan_digest = &plan_digest, .bundle_digest = &bundle_digest, .nips_revision = auth.revision, .pubkey = parsed_plan.value.author.expected_pubkey, .relays = parsed_plan.value.delivery.auth.?.relays, .timeout_ms = 1000 };
    const server = try std.Thread.spawn(.{}, serveAuthThread, .{ &first, gpa });
    var joined = false;
    defer if (!joined) server.join();
    const second_server = if (scenario == .acceptance_close) try std.Thread.spawn(.{}, serveAuthThread, .{ &second, gpa }) else null;
    defer if (!joined) {
        if (second_server) |thread| thread.join();
    };
    const signer_thread = try std.Thread.spawn(.{}, acceptanceSignerThread, .{ &signer, &sync, policy, gpa });
    defer if (!joined) signer_thread.join();
    var result = np.run(client_io, gpa, .{ .plan = artifacts.plan, .bundle = artifacts.bundle, .auth_channel = &child }) catch |err| {
        signer_thread.join();
        server.join();
        if (second_server) |thread| thread.join();
        joined = true;
        std.debug.print("acceptance {s}: run={s}, requests={d}, retired={d}, AUTH={d}/{d}, EVENT={d}/{d}\n", .{ @tagName(scenario), @errorName(err), sync.signer_requests, sync.retire_seen, first.saw_auth, second.saw_auth, first.base.saw_events, second.base.saw_events });
        return err;
    };
    defer result.deinit();
    signer_thread.join();
    server.join();
    if (second_server) |thread| thread.join();
    joined = true;
    try testing.expect(sync.hook_error == null);
    try testing.expect(sync.signer_error == null);
    var report = try std.json.parseFromSlice(AcceptanceReport, gpa, result.report.?, .{ .ignore_unknown_fields = true });
    defer report.deinit();
    const relay = report.value.relays[0];
    try testing.expectEqual(first.saw_auth, relay.auth.auth_sends);
    for (result.diagnostics.items) |diagnostic| {
        for ([_][]const u8{ auth_scalar, auth_challenge, "replacement-challenge", "\"sig\"", "\"correlation\"" }) |forbidden| {
            try testing.expect(std.mem.indexOf(u8, diagnostic.message, forbidden) == null);
            try testing.expect(std.mem.indexOf(u8, diagnostic.remediation, forbidden) == null);
        }
    }
    for ([_][]const u8{ auth_scalar, auth_challenge, "replacement-challenge", "\"sig\"", "\"correlation\"" }) |forbidden|
        try testing.expect(std.mem.indexOf(u8, result.report.?, forbidden) == null);
    if (first.saw_auth > 0) try testing.expect(std.mem.indexOf(u8, result.report.?, &first.auth_sig) == null);
    if (scenario == .acceptance_close) {
        try testing.expectEqual(@as(usize, 0), first.saw_auth);
        try testing.expectEqual(@as(usize, 0), first.base.saw_events);
        try testing.expectEqualStrings("closed", relay.auth.status);
        try testing.expectEqualStrings("closed", relay.outcome);
        try testing.expectEqual(@as(usize, 0), relay.attempts);
        for (relay.events) |event| try testing.expectEqualStrings("not-attempted", event.result);
        try testing.expectEqual(@as(usize, 1), second.saw_auth);
        try testing.expectEqual(@as(usize, 2), second.base.saw_events);
        try testing.expect(second.auth_verified and second.exact_articles);
        try testing.expectEqualStrings("authenticated", report.value.relays[1].auth.status);
        try testing.expectEqualStrings("partial", report.value.classification);
        return;
    }
    try testing.expect(sync.injected);
    if (scenario == .acceptance_premature) {
        try testing.expect(sync.verification_seen);
        try testing.expectEqual(@as(usize, 0), first.saw_auth);
        try testing.expectEqual(@as(usize, 0), first.base.saw_events);
        try testing.expectEqualStrings("protocol-error", relay.auth.status);
        try testing.expectEqualStrings("unexpected-ok", relay.auth.reason);
        try testing.expectEqualStrings("error", relay.outcome);
        try testing.expectEqual(@as(usize, 0), relay.attempts);
        for (relay.events) |event| try testing.expectEqualStrings("not-attempted", event.result);
        return;
    }
    try testing.expectEqual(@as(usize, 2), sync.awake_after_ok);
    try testing.expectEqual(@as(usize, 2), first.saw_auth);
    try testing.expect(first.auth_verified);
    try testing.expectEqual(@as(usize, 2), relay.auth.signing_requests);
    try testing.expectEqual(@as(usize, 2), relay.auth.auth_sends);
    try testing.expectEqual(@as(usize, 2), relay.auth.exchanges.len);
    try testing.expectEqualStrings("superseded", relay.auth.exchanges[0].result);
    try testing.expectEqual(@as(u8, 2), relay.auth.exchanges[1].generation);
    if (scenario == .acceptance_large) {
        try testing.expectEqual(@as(usize, 2), first.base.saw_events);
        try testing.expect(first.exact_articles);
        try testing.expectEqualStrings("authenticated", relay.auth.status);
        try testing.expectEqualStrings("accepted", relay.outcome);
        try testing.expectEqualStrings("complete", report.value.classification);
    } else {
        try testing.expectEqual(@as(usize, 0), first.base.saw_events);
        try testing.expectEqual(@as(usize, 0), relay.attempts);
        for (relay.events) |event| try testing.expectEqualStrings("not-attempted", event.result);
        try testing.expectEqualStrings(if (scenario == .acceptance_closed) "closed" else "rejected", relay.auth.status);
        try testing.expectEqualStrings(if (scenario == .acceptance_closed) "relay-closed" else if (scenario == .acceptance_auth_required) "auth-required" else "relay-rejected", relay.auth.reason);
        try testing.expect(result.diagnostics.items.len > 0);
        try testing.expectEqual(@import("diag.zig").Code.ENOSTRRELAY, result.diagnostics.items[0].code);
        try testing.expectEqualStrings(if (scenario == .acceptance_closed) "closed" else if (scenario == .acceptance_auth_required) "auth-required" else "rejected", relay.outcome);
        try testing.expectEqualStrings("failed", report.value.classification);
    }
}

test "NIP-42 acceptance retired signer reply stays local to a closed relay" {
    try acceptanceScenario(.acceptance_close);
}
test "NIP-42 acceptance post-success replacement preserves large article bytes" {
    try acceptanceScenario(.acceptance_large);
}
test "NIP-42 acceptance matching OK before AUTH writes no AUTH or EVENT" {
    try acceptanceScenario(.acceptance_premature);
}
test "NIP-42 acceptance post-success replacement retains auth-required outcome" {
    try acceptanceScenario(.acceptance_auth_required);
}
test "NIP-42 acceptance post-success replacement retains rejected outcome" {
    try acceptanceScenario(.acceptance_rejected);
}
test "NIP-42 acceptance post-success replacement retains closed outcome" {
    try acceptanceScenario(.acceptance_closed);
}

test "NIP-42 mixed opted-in and ordinary relays retain separate evidence and verdicts" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    for ([_]AuthScenario{ .success, .rejected, .challenge_silence, .challenge_close, .auth_close }) |scenario| {
        var threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
        defer threaded.deinit();
        var auth_base = try MockRelay.init(threaded.io(), .ok);
        defer auth_base.deinit();
        var plain = try MockRelay.init(threaded.io(), .ok);
        defer plain.deinit();
        var artifacts = try makeAuthArtifacts(gpa, &.{ auth_base.port, plain.port }, &.{auth_base.port}, 150);
        defer artifacts.deinit(gpa);
        const expected = try expectedArticles(gpa, artifacts.bundle);
        defer {
            for (expected) |e| gpa.free(e);
            gpa.free(expected);
        }
        var relay: AuthRelay = .{ .base = auth_base, .scenario = scenario, .expected = expected };
        const first = try std.Thread.spawn(.{}, serveAuthThread, .{ &relay, gpa });
        const second = try std.Thread.spawn(.{}, serveOneThread, .{ &plain, gpa });
        const output = try runAuthProcess(gpa, artifacts.plan, artifacts.bundle);
        defer gpa.free(output.stdout);
        defer gpa.free(output.stderr);
        first.join();
        second.join();
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, output.term);
        var parsed = try std.json.parseFromSlice(struct { classification: []const u8, relays: []const struct { auth: struct { status: []const u8 } } }, gpa, output.stdout, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try testing.expectEqualStrings(if (scenario == .success) "complete" else "partial", parsed.value.classification);
        try testing.expectEqualStrings("not-requested", parsed.value.relays[1].auth.status);
        try testing.expectEqual(@as(usize, 2), plain.saw_events);
        try testing.expectEqual(@as(usize, if (scenario == .success) 2 else 0), relay.base.saw_events);
    }
}

extern "c" fn proc_listchildpids(pid: c_int, buffer: ?*anyopaque, length: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, length: c_int) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: ?*anyopaque, length: u32) c_int;
extern "c" fn proc_pidfdinfo(pid: c_int, fd: c_int, flavor: c_int, buffer: ?*anyopaque, length: c_int) c_int;

fn spawnFaultProcess(tmp: *testing.TmpDir, scenario: []const u8, artifacts: MatrixArtifacts, stdin: std.process.SpawnOptions.StdIo) !std.process.Child {
    const gpa = testing.allocator;
    const name = try std.fmt.allocPrint(gpa, "{s}.json", .{scenario});
    defer gpa.free(name);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = artifacts.plan });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bundle.json", .data = artifacts.bundle });
    const plan_path = try tmp.dir.realPathFileAlloc(testing.io, name, gpa);
    defer gpa.free(plan_path);
    const bundle_path = try tmp.dir.realPathFileAlloc(testing.io, "bundle.json", gpa);
    defer gpa.free(bundle_path);
    return std.process.spawn(testing.io, .{
        .argv = &.{ @import("nostr_fault_binary").path, "nostr", "sign", "--auth-session", "--plan", plan_path, "--bundle", bundle_path, "--key-stdin" },
        .stdin = stdin,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

fn collectFaultProcess(child: *std.process.Child) !std.process.RunResult {
    const gpa = testing.allocator;
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(gpa, testing.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const deadline = auth.Deadline.after(testing.io, 5000);
    while (reader.fill(4096, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(try deadline.remaining(testing.io)) } })) |_| {} else |err| {
        if (err != error.EndOfStream) return err;
    }
    try reader.checkAnyError();
    return .{ .term = try child.wait(testing.io), .stdout = try reader.toOwnedSlice(0), .stderr = try reader.toOwnedSlice(1) };
}

fn fixtureCounter(log: []const u8, child: bool, name: []const u8) !usize {
    const prefix: []const u8 = if (child) "fixture-stats child=1 " else "fixture-stats child=0 ";
    const start = std.mem.indexOf(u8, log, prefix) orelse return error.MissingFixtureStats;
    const tail = log[start..];
    const line = tail[0 .. std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len];
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..eq], name)) return std.fmt.parseInt(usize, field[eq + 1 ..], 10);
    }
    return error.MissingFixtureCounter;
}

fn expectFaultHygiene(output: std.process.RunResult) !void {
    for ([_][]const u8{ output.stdout, output.stderr }) |text| {
        for ([_][]const u8{ auth_scalar, auth_challenge, "process-fixture-challenge", "\"sig\"", "\"correlation\"", "\"boris-nostr-auth-ipc\"" }) |forbidden|
            try testing.expect(std.mem.indexOf(u8, text, forbidden) == null);
    }
    try testing.expectEqual(@as(usize, 0), try fixtureCounter(output.stderr, false, "contexts"));
    if (try fixtureCounter(output.stderr, false, "reads") > 0)
        try testing.expectEqual(@as(usize, 1), try fixtureCounter(output.stderr, false, "cores"));
}

fn expectNoConnect(base: *MockRelay) !void {
    var listener = [_]std.c.pollfd{.{ .fd = @intCast(base.server.socket.handle), .events = posix.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&listener, 1, 0));
}

test "NIP-42 process exec and forged ready failures never read queued key stdin" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    for ([_][]const u8{ "exec_fail", "ready_eof", "ready_silence", "ready_policy", "ready_author", "ready_digest", "ready_relay", "ready_revision", "ready_version", "ready_unknown", "ready_truncated" }) |scenario| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var base = try MockRelay.init(testing.io, .ok);
        defer base.deinit();
        var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 200);
        defer artifacts.deinit(gpa);
        // Retain a read endpoint for FIONREAD after the supervisor exits.
        // This independently observes the kernel queue, not just a mock count.
        var pipe: [2]std.c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe));
        defer for (pipe) |fd| {
            _ = std.c.close(fd);
        };
        try testing.expectEqual(@as(isize, 65), std.c.write(pipe[1], auth_scalar ++ "\n", 65));
        const file: Io.File = .{ .handle = pipe[0], .flags = .{ .nonblocking = false } };
        var child = try spawnFaultProcess(&tmp, scenario, artifacts, .{ .file = file });
        defer child.kill(testing.io);
        const output = try collectFaultProcess(&child);
        defer gpa.free(output.stdout);
        defer gpa.free(output.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, output.term);
        try testing.expectEqual(@as(usize, 0), output.stdout.len);
        try testing.expectEqual(@as(usize, 0), try fixtureCounter(output.stderr, false, "reads"));
        var queued: c_int = 0;
        try testing.expectEqual(@as(c_int, 0), std.c.ioctl(pipe[0], 0x4004667f, &queued)); // Darwin FIONREAD
        try testing.expectEqual(@as(c_int, 65), queued);
        try expectNoConnect(&base);
        try expectFaultHygiene(output);
    }
}

test "NIP-42 process context and seed failures destroy custody before begin" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    for ([_][]const u8{ "seed_entropy", "context_fail", "randomize_fail", "keypair_fail" }) |scenario| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var base = try MockRelay.init(testing.io, .ok);
        defer base.deinit();
        var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 200);
        defer artifacts.deinit(gpa);
        var child = try spawnFaultProcess(&tmp, scenario, artifacts, .pipe);
        defer child.kill(testing.io);
        try child.stdin.?.writeStreamingAll(testing.io, auth_scalar ++ "\n");
        child.stdin.?.close(testing.io);
        child.stdin = null;
        const output = try collectFaultProcess(&child);
        defer gpa.free(output.stdout);
        defer gpa.free(output.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = if (std.mem.eql(u8, scenario, "keypair_fail")) 1 else 3 }, output.term);
        try testing.expectEqual(@as(usize, 0), output.stdout.len);
        try testing.expectEqual(@as(usize, 1), try fixtureCounter(output.stderr, false, "reads"));
        try testing.expectEqual(@as(usize, 0), try fixtureCounter(output.stderr, false, "signs"));
        try expectNoConnect(&base);
        try expectFaultHygiene(output);
    }
}

test "NIP-42 process invalid or wrong-identity key is a content refusal before begin" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    for ([_][]const u8{ "invalid-key\n", "0" ** 64 ++ "\n", "0" ** 63 ++ "4\n", "x" ** 130 ++ "\n" }) |input| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var base = try MockRelay.init(testing.io, .ok);
        defer base.deinit();
        var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 200);
        defer artifacts.deinit(gpa);
        var child = try spawnFaultProcess(&tmp, "key_input", artifacts, .pipe);
        defer child.kill(testing.io);
        try child.stdin.?.writeStreamingAll(testing.io, input);
        child.stdin.?.close(testing.io);
        child.stdin = null;
        const output = try collectFaultProcess(&child);
        defer gpa.free(output.stdout);
        defer gpa.free(output.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, output.term);
        try testing.expectEqual(@as(usize, 0), output.stdout.len);
        try testing.expect(std.mem.indexOf(u8, output.stderr, std.mem.trimEnd(u8, input, "\n")) == null);
        try testing.expectEqual(@as(usize, 0), try fixtureCounter(output.stderr, false, "signs"));
        try expectNoConnect(&base);
        try expectFaultHygiene(output);
    }
}

test "NIP-42 process hostile requests and controls terminate without relay writes" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    for ([_][]const u8{
        "request_extra",     "request_hash",     "request_run",    "request_connection",    "request_relay", "request_generation",
        "request_revision",  "request_digest",   "request_number", "cancel_before_request", "cancel_wrong",  "cancel_duplicate",
        "retire_wrong",      "retire_duplicate", "sign_retired",   "control_unknown",       "finish_extra",  "request_eof",
        "request_truncated", "begin_run",        "begin_version",  "begin_unknown",
    }) |scenario| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var base = try MockRelay.init(testing.io, .ok);
        defer base.deinit();
        var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 200);
        defer artifacts.deinit(gpa);
        var child = try spawnFaultProcess(&tmp, scenario, artifacts, .pipe);
        defer child.kill(testing.io);
        try child.stdin.?.writeStreamingAll(testing.io, auth_scalar ++ "\n");
        child.stdin.?.close(testing.io);
        child.stdin = null;
        const output = try collectFaultProcess(&child);
        defer gpa.free(output.stdout);
        defer gpa.free(output.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, output.term);
        try testing.expectEqual(@as(usize, 0), output.stdout.len);
        try testing.expectEqual(@as(usize, 1), try fixtureCounter(output.stderr, false, "reads"));
        if (std.mem.startsWith(u8, scenario, "begin_"))
            try testing.expectEqual(@as(usize, 0), try fixtureCounter(output.stderr, true, "reads"));
        const signed = std.mem.eql(u8, scenario, "cancel_wrong") or std.mem.eql(u8, scenario, "cancel_duplicate") or
            std.mem.eql(u8, scenario, "retire_wrong") or std.mem.eql(u8, scenario, "retire_duplicate") or std.mem.eql(u8, scenario, "sign_retired");
        try testing.expectEqual(@as(usize, if (signed) 1 else 0), try fixtureCounter(output.stderr, false, "signs"));
        try expectNoConnect(&base);
        try expectFaultHygiene(output);
    }
}

test "NIP-42 process transient signing failures persist while plain relays still publish" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    for ([_][]const u8{ "aux_entropy", "sign_fail", "verify_fail" }) |scenario| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
        defer threaded.deinit();
        var first = try MockRelay.init(threaded.io(), .ok);
        defer first.deinit();
        var second = try MockRelay.init(threaded.io(), .ok);
        defer second.deinit();
        var plain = try MockRelay.init(threaded.io(), .ok);
        defer plain.deinit();
        var artifacts = try makeAuthArtifacts(gpa, &.{ first.port, second.port, plain.port }, &.{ first.port, second.port }, 250);
        defer artifacts.deinit(gpa);
        var first_auth: AuthRelay = .{ .base = first, .scenario = .success, .expected = &.{} };
        var second_auth: AuthRelay = .{ .base = second, .scenario = .success, .expected = &.{} };
        var joined = false;
        const one = try std.Thread.spawn(.{}, serveAuthThread, .{ &first_auth, gpa });
        defer if (!joined) one.join();
        const two = try std.Thread.spawn(.{}, serveAuthThread, .{ &second_auth, gpa });
        defer if (!joined) two.join();
        const three = try std.Thread.spawn(.{}, serveOneThread, .{ &plain, gpa });
        defer if (!joined) three.join();
        var child = try spawnFaultProcess(&tmp, scenario, artifacts, .pipe);
        defer child.kill(testing.io);
        try child.stdin.?.writeStreamingAll(testing.io, auth_scalar ++ "\n");
        child.stdin.?.close(testing.io);
        child.stdin = null;
        const output = try collectFaultProcess(&child);
        defer gpa.free(output.stdout);
        defer gpa.free(output.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, output.term);
        var report = try std.json.parseFromSlice(struct {
            classification: []const u8,
            relays: []const struct { attempts: usize, auth: struct { status: []const u8, reason: []const u8, signing_requests: usize, auth_sends: usize } },
        }, gpa, output.stdout, .{ .ignore_unknown_fields = true });
        defer report.deinit();
        try testing.expectEqualStrings("partial", report.value.classification);
        for (report.value.relays[0..2]) |r| {
            try testing.expectEqualStrings("signer-error", r.auth.status);
            try testing.expectEqualStrings("signer-refused", r.auth.reason);
            try testing.expectEqual(@as(usize, 1), r.auth.signing_requests);
            try testing.expectEqual(@as(usize, 0), r.auth.auth_sends);
            try testing.expectEqual(@as(usize, 0), r.attempts);
        }
        try testing.expectEqualStrings("not-requested", report.value.relays[2].auth.status);
        try testing.expectEqual(@as(usize, if (std.mem.eql(u8, scenario, "aux_entropy")) 0 else 1), try fixtureCounter(output.stderr, false, "signs"));
        try testing.expectEqual(@as(usize, if (std.mem.eql(u8, scenario, "verify_fail")) 1 else 0), try fixtureCounter(output.stderr, false, "verifies"));
        try testing.expectEqual(@as(usize, 3), try fixtureCounter(output.stderr, false, "entropy"));
        try testing.expectEqual(@as(usize, 0), try fixtureCounter(output.stderr, true, "reads"));
        try expectFaultHygiene(output);
        // Process exit closes the sockets. Join before reading relay counters.
        one.join();
        two.join();
        three.join();
        joined = true;
        try testing.expectEqual(@as(usize, 0), first_auth.saw_auth + second_auth.saw_auth);
        try testing.expectEqual(@as(usize, 0), first_auth.base.saw_events + second_auth.base.saw_events);
        try testing.expectEqual(@as(usize, 2), plain.saw_events);
    }
}

fn processRunning(pid: c_int) bool {
    if (std.c.kill(pid, @enumFromInt(0)) != 0) return false;
    var info: [64]u32 = @splat(0);
    if (proc_pidinfo(pid, 3, 0, &info, @sizeOf(@TypeOf(info))) > 0 and info[1] == 5) return false; // SZOMB: terminated; reaping belongs to init after parent SIGKILL
    return true;
}

const BlockedExit = enum { cancel, supervisor_death, publisher_death, deadline };

fn blockedProcessFault(scenario: []const u8, target: BlockedExit) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    var base = try MockRelay.init(threaded.io(), .ok);
    defer base.deinit();
    var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, if (target == .deadline) 200 else 2000);
    defer artifacts.deinit(gpa);
    var relay: AuthRelay = .{ .base = base, .scenario = .success, .expected = &.{} };
    const networked = std.mem.eql(u8, scenario, "block_request") or std.mem.eql(u8, scenario, "block_network");
    const server = if (networked) try std.Thread.spawn(.{}, serveAuthThread, .{ &relay, gpa }) else null;
    var joined = false;
    defer if (!joined) {
        if (server) |thread| thread.join();
    };
    var process = try spawnFaultProcess(&tmp, scenario, artifacts, .pipe);
    defer process.kill(io);
    try process.stdin.?.writeStreamingAll(io, auth_scalar ++ "\n");
    process.stdin.?.close(io);
    process.stdin = null;
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(gpa, io, buffer.toStreams(), &.{ process.stdout.?, process.stderr.? });
    defer reader.deinit();
    const marker = try std.fmt.allocPrint(gpa, "fixture-blocked-{s}\n", .{scenario});
    defer gpa.free(marker);
    const startup = auth.Deadline.after(io, 1500);
    while (std.mem.indexOf(u8, reader.reader(1).buffered(), marker) == null) {
        try reader.fill(4096, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(try startup.remaining(io)) } });
    }
    var children: [4]c_int = @splat(0);
    _ = proc_listchildpids(process.id.?, &children, @sizeOf(@TypeOf(children)));
    try testing.expect(children[0] != 0);
    const child_pid = children[0];
    const teardown = auth.Deadline.after(io, 1500);
    switch (target) {
        .cancel => try testing.expectEqual(@as(c_int, 0), std.c.kill(process.id.?, .TERM)),
        .supervisor_death => try testing.expectEqual(@as(c_int, 0), std.c.kill(process.id.?, .KILL)),
        .publisher_death => try testing.expectEqual(@as(c_int, 0), std.c.kill(child_pid, .KILL)),
        .deadline => {},
    }
    while (reader.fill(4096, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(try teardown.remaining(io)) } })) |_| {} else |err| {
        if (err != error.EndOfStream) return err;
    }
    try reader.checkAnyError();
    const output: std.process.RunResult = .{
        .term = try process.wait(io),
        .stdout = try reader.toOwnedSlice(0),
        .stderr = try reader.toOwnedSlice(1),
    };
    defer gpa.free(output.stdout);
    defer gpa.free(output.stderr);
    while (processRunning(child_pid)) {
        _ = try teardown.remaining(io);
        try Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    if (target == .supervisor_death) {
        try testing.expect(output.term == .signal);
        for ([_][]const u8{ auth_scalar, auth_challenge, "process-fixture-challenge", "\"sig\"", "\"correlation\"" }) |forbidden|
            try testing.expect(std.mem.indexOf(u8, output.stderr, forbidden) == null);
    } else {
        try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, output.term);
        try expectFaultHygiene(output);
    }
    try testing.expectEqual(@as(usize, 0), output.stdout.len); // no fabricated completed report
    if (server) |thread| thread.join();
    joined = true;
    if (!networked) try expectNoConnect(&base);
    try testing.expectEqual(@as(usize, 0), relay.saw_auth);
    try testing.expectEqual(@as(usize, 0), relay.base.saw_events);
}

test "NIP-42 process cancellation and death during blocked IPC and transport writes" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    for ([_][]const u8{ "block_begin", "block_request", "block_response", "block_network" }) |scenario| {
        for ([_]BlockedExit{ .cancel, .supervisor_death, .publisher_death }) |target|
            try blockedProcessFault(scenario, target);
    }
}

test "NIP-42 process full kernel pipes retain bounded startup and complete-frame writes" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    for ([_][]const u8{ "block_begin", "block_request", "block_response" }) |scenario|
        try blockedProcessFault(scenario, .deadline);
}

test "NIP-42 actual exec custody, key-input cancellation and supervisor loss are bounded" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    // No key is supplied: the child must already be exec'd and waiting for
    // begin, with /dev/null stdin and exactly the two private pipe endpoints.
    for ([_]std.posix.SIG{ .TERM, .KILL }) |sig| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var base = try MockRelay.init(io, .ok);
        defer base.deinit();
        var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 2000);
        defer artifacts.deinit(gpa);
        try tmp.dir.writeFile(io, .{ .sub_path = "plan.json", .data = artifacts.plan });
        try tmp.dir.writeFile(io, .{ .sub_path = "bundle.json", .data = artifacts.bundle });
        const plan_path = try tmp.dir.realPathFileAlloc(io, "plan.json", gpa);
        defer gpa.free(plan_path);
        const bundle_path = try tmp.dir.realPathFileAlloc(io, "bundle.json", gpa);
        defer gpa.free(bundle_path);
        var process = try std.process.spawn(io, .{ .argv = &.{ @import("nostr_test_binary").path, "nostr", "sign", "--auth-session", "--plan", plan_path, "--bundle", bundle_path, "--key-stdin" }, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
        defer process.kill(io);
        var children: [4]c_int = @splat(0);
        const startup = auth.Deadline.after(io, 1000);
        while (children[0] == 0) {
            _ = proc_listchildpids(process.id.?, &children, @sizeOf(@TypeOf(children)));
            _ = try startup.remaining(io);
            try Io.sleep(io, .fromMilliseconds(5), .awake);
        }
        const child_pid = children[0];
        var path: [4096]u8 = undefined;
        try testing.expect(proc_pidpath(child_pid, &path, path.len) > 0);
        const actual_path = std.mem.sliceTo(&path, 0);
        try testing.expect(std.mem.endsWith(u8, actual_path, "/boris"));
        const Fd = extern struct { number: i32, kind: u32 };
        var fds: [64]Fd = undefined;
        try Io.sleep(io, .fromMilliseconds(20), .awake);
        const fd_bytes = proc_pidinfo(child_pid, 1, 0, &fds, @sizeOf(@TypeOf(fds)));
        try testing.expect(fd_bytes > 0);
        var stdin_null = false;
        var in_pipe = false;
        var out_pipe = false;
        for (fds[0..@intCast(@divExact(fd_bytes, @sizeOf(Fd)))]) |fd| {
            try testing.expect(fd.number <= 4);
            if (fd.number == 0) stdin_null = fd.kind == 1; // vnode, not the key-input pipe
            if (fd.number == 3) in_pipe = fd.kind == 6;
            if (fd.number == 4) out_pipe = fd.kind == 6;
        }
        try testing.expect(stdin_null and in_pipe and out_pipe);
        var vnode: [4096]u8 = @splat(0);
        const vnode_bytes = proc_pidfdinfo(child_pid, 0, 2, &vnode, vnode.len);
        try testing.expect(vnode_bytes > 0);
        try testing.expect(std.mem.indexOf(u8, vnode[0..@intCast(vnode_bytes)], "/dev/null\x00") != null);
        var listener = [_]std.c.pollfd{.{ .fd = @intCast(base.server.socket.handle), .events = posix.POLL.IN, .revents = 0 }};
        try testing.expectEqual(@as(c_int, 0), std.c.poll(&listener, 1, 0)); // no socket before key/begin
        const teardown = auth.Deadline.after(io, 1500);
        try testing.expectEqual(@as(c_int, 0), std.c.kill(process.id.?, sig));
        process.stdin.?.close(io);
        process.stdin = null;
        _ = try ws.raceDeadline(io, 1500, std.process.Child.wait, .{ &process, io });
        while (processRunning(child_pid)) {
            _ = try teardown.remaining(io);
            try Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
}

test "NIP-42 absent-session and schema downgrade refuse before any relay connect" {
    const gpa = testing.allocator;
    var base = try MockRelay.init(testing.io, .ok);
    defer base.deinit();
    var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 150);
    defer artifacts.deinit(gpa);
    var result = try np.run(testing.io, gpa, .{ .plan = artifacts.plan, .bundle = artifacts.bundle });
    defer result.deinit();
    try testing.expect(result.usage_refusal and result.report == null);
    var listener = [_]std.c.pollfd{.{ .fd = @intCast(base.server.socket.handle), .events = posix.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&listener, 1, 0));
    try testing.expectError(error.InvalidAuthSchema, auth.validateVersion(1, .{ .mode = "nip42", .relays = &.{"wss://r.example"} }));
    try testing.expectError(error.InvalidAuthSchema, auth.validateVersion(2, null));
}

test "NIP-42 policy negotiation does not change offline article event bytes" {
    const gpa = testing.allocator;
    var base = try MockRelay.init(testing.io, .ok);
    defer base.deinit();
    var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 150);
    defer artifacts.deinit(gpa);
    var document = try std.json.parseFromSlice(std.json.Value, gpa, artifacts.plan, .{});
    defer document.deinit();
    try document.value.object.put(document.arena.allocator(), "schema_version", .{ .integer = 1 });
    const delivery = document.value.object.getPtr("delivery").?;
    _ = delivery.object.swapRemove("auth");
    const ordinary = try std.json.Stringify.valueAlloc(gpa, document.value, .{});
    defer gpa.free(ordinary);
    var signed = try @import("nostr_sign.zig").run(testing.io, gpa, .{ .plan = ordinary, .key = auth_scalar, .created_at = 1700000000, .aux_rand = @splat(0) });
    defer signed.deinit();
    const before = try expectedArticles(gpa, signed.bundle.?);
    defer {
        for (before) |e| gpa.free(e);
        gpa.free(before);
    }
    const after = try expectedArticles(gpa, artifacts.bundle);
    defer {
        for (after) |e| gpa.free(e);
        gpa.free(after);
    }
    for (before, after) |a, b| try testing.expectEqualStrings(a, b);
}

test "NIP-42 cancellation and supervisor loss during live challenge, auth OK and article OK" {
    if (comptime !@import("nostr_auth_session.zig").supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    for ([_]AuthScenario{ .challenge_silence, .auth_silence, .article_silence }, [_]u8{ 1, 2, 3 }) |scenario, phase| {
        for ([_]std.posix.SIG{ .TERM, .KILL }) |sig| {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var base = try MockRelay.init(io, .ok);
            defer base.deinit();
            var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 2000);
            defer artifacts.deinit(gpa);
            const expected = try expectedArticles(gpa, artifacts.bundle);
            defer {
                for (expected) |e| gpa.free(e);
                gpa.free(expected);
            }
            var relay: AuthRelay = .{ .base = base, .scenario = scenario, .expected = expected };
            const server = try std.Thread.spawn(.{}, serveAuthThread, .{ &relay, gpa });
            defer server.join();
            try tmp.dir.writeFile(io, .{ .sub_path = "plan.json", .data = artifacts.plan });
            try tmp.dir.writeFile(io, .{ .sub_path = "bundle.json", .data = artifacts.bundle });
            const plan_path = try tmp.dir.realPathFileAlloc(io, "plan.json", gpa);
            defer gpa.free(plan_path);
            const bundle_path = try tmp.dir.realPathFileAlloc(io, "bundle.json", gpa);
            defer gpa.free(bundle_path);
            const report_path = try std.fmt.allocPrint(gpa, "{s}report.json", .{plan_path[0 .. plan_path.len - "plan.json".len]});
            defer gpa.free(report_path);
            const log_file = try tmp.dir.createFile(io, "process.log", .{});
            defer log_file.close(io);
            var process = try std.process.spawn(io, .{ .argv = &.{ @import("nostr_test_binary").path, "nostr", "sign", "--auth-session", "--plan", plan_path, "--bundle", bundle_path, "--key-stdin", "--report-out", report_path }, .stdin = .pipe, .stdout = .ignore, .stderr = .{ .file = log_file } });
            defer process.kill(io);
            var children: [4]c_int = @splat(0);
            try process.stdin.?.writeStreamingAll(io, auth_scalar ++ "\n");
            process.stdin.?.close(io);
            process.stdin = null;
            const startup = auth.Deadline.after(io, 1500);
            while (relay.phase.load(.acquire) < phase) {
                _ = try startup.remaining(io);
                try Io.sleep(io, .fromMilliseconds(5), .awake);
            }
            _ = proc_listchildpids(process.id.?, &children, @sizeOf(@TypeOf(children)));
            try testing.expect(children[0] != 0);
            const teardown = auth.Deadline.after(io, 1500);
            try testing.expectEqual(@as(c_int, 0), std.c.kill(process.id.?, sig));
            _ = try ws.raceDeadline(io, 1500, std.process.Child.wait, .{ &process, io });
            while (processRunning(children[0])) {
                _ = teardown.remaining(io) catch |err| {
                    var info: [64]u32 = @splat(0);
                    const rc = proc_pidinfo(children[0], 3, 0, &info, @sizeOf(@TypeOf(info)));
                    std.debug.print("active custody teardown exceeded: scenario={s} signal={d} child={d} info={d} status={d}\n", .{ @tagName(scenario), @intFromEnum(sig), children[0], rc, info[1] });
                    const log_bytes = try tmp.dir.readFileAlloc(io, "process.log", gpa, .limited(4096));
                    defer gpa.free(log_bytes);
                    std.debug.print("process refusal diagnostics: {s}\n", .{log_bytes});
                    return err;
                };
                try Io.sleep(io, .fromMilliseconds(5), .awake);
            }
            try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "report.json", .{}));
        }
    }
}

const InvalidSigner = enum {
    pubkey,
    relay,
    challenge,
    kind,
    content,
    tags,
    stale,
    event_id,
    signature,
    run,
    connection,
    generation,
    request,
    plan_digest,
    bundle_digest,
    revision,
    refusal,
    hang,
    oversized_frame,
    partial_header,
    valid,
    duplicate,
    late,
    blocked_write,
};

const BlockingAuthWrite = struct {
    var native: Io = undefined;
    var writes: std.atomic.Value(usize) = .init(0);
    fn write(userdata: ?*anyopaque, socket: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
        // First write is HTTP Upgrade. Stall the next complete AUTH write.
        if (writes.fetchAdd(1, .acq_rel) == 1) {
            try Io.sleep(native, .fromMilliseconds(10000), .awake);
            return error.Unexpected;
        }
        return native.vtable.netWrite(userdata, socket, header, data, splat);
    }
};

fn invalidSignerThread(channel: *auth_ipc.Channel, scenario: InvalidSigner, gpa: std.mem.Allocator) void {
    invalidSigner(channel, scenario, gpa) catch {};
}
fn invalidSigner(channel: *auth_ipc.Channel, scenario: InvalidSigner, gpa: std.mem.Allocator) !void {
    const bytes = try channel.read(gpa, auth.Deadline.after(channel.io, 2000));
    defer gpa.free(bytes);
    var parsed = try auth.parse(auth.Request, gpa, bytes, "sign");
    defer parsed.deinit();
    if (scenario == .hang) {
        try Io.sleep(channel.io, .fromMilliseconds(180), .awake);
        return;
    }
    if (scenario == .oversized_frame or scenario == .partial_header) {
        const prefix: []const u8 = if (scenario == .oversized_frame) &.{ 0, 0, 0x80, 1 } else &.{0};
        _ = std.c.write(channel.output, prefix.ptr, prefix.len);
        if (scenario == .partial_header) try Io.sleep(channel.io, .fromMilliseconds(180), .awake);
        return;
    }
    const request = parsed.value;
    if (scenario == .late) try Io.sleep(channel.io, .fromMilliseconds(180), .awake);
    var ctx = try keys.Context.init();
    defer ctx.deinit();
    const pair = try ctx.keyPairFromSecretKey([_]u8{0} ** 31 ++ [_]u8{3});
    const pk = std.fmt.bytesToHex(pair.public_key, .lower);
    const signed = try auth.sign(gpa, ctx, pair, &pk, request.correlation.relay, request.challenge, Io.Timestamp.now(channel.io, .real).toSeconds(), @splat(0));
    defer gpa.free(signed);
    var document = try std.json.parseFromSlice(auth.Event, gpa, signed, .{});
    defer document.deinit();
    var event = document.value;
    var correlation = request.correlation;
    switch (scenario) {
        .pubkey => event.pubkey = "0" ** 64,
        .relay => event.tags = &.{ &.{ "relay", "wss://wrong.example" }, &.{ "challenge", request.challenge } },
        .challenge => event.tags = &.{ &.{ "relay", request.correlation.relay }, &.{ "challenge", "wrong" } },
        .kind => event.kind = 30023,
        .content => event.content = "forbidden",
        .tags => event.tags = &.{ &.{ "relay", request.correlation.relay }, &.{ "challenge", request.challenge }, &.{"extra"} },
        .stale => event.created_at -= 61,
        .event_id => event.id = "0" ** 64,
        .signature => event.sig = "0" ** 128,
        .run => correlation.run = "f" ** 32,
        .connection => correlation.connection = "f" ** 32,
        .generation => correlation.generation = 2,
        .request => correlation.request += 1,
        .plan_digest => correlation.plan_digest = "f" ** 64,
        .bundle_digest => correlation.bundle_digest = "f" ** 64,
        .revision => correlation.nips_revision = "f" ** 40,
        else => {},
    }
    const response: auth.Response = .{ .correlation = correlation, .refusal = if (scenario == .refusal) "signer-refused" else null, .event = if (scenario == .refusal) null else event };
    if (scenario == .duplicate) {
        const encoded = try std.json.Stringify.valueAlloc(gpa, response, .{});
        defer gpa.free(encoded);
        var frames: std.ArrayList(u8) = .empty;
        defer frames.deinit(gpa);
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(encoded.len), .big);
        for (0..2) |_| {
            try frames.appendSlice(gpa, &header);
            try frames.appendSlice(gpa, encoded);
        }
        if (std.c.write(channel.output, frames.items.ptr, frames.items.len) != frames.items.len) return error.WriteFailed;
        return;
    }
    try channel.send(gpa, response, auth.Deadline.after(channel.io, 1000));
}

test "NIP-42 malicious signer substitutions, refusals and IPC stalls emit no AUTH or article" {
    if (comptime !auth_ipc.supported) return error.SkipZigTest;
    auth_ipc.canceled.store(false, .unordered);
    const gpa = testing.allocator;
    for (std.meta.tags(InvalidSigner)) |scenario| {
        if (scenario == .valid) continue;
        var threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
        defer threaded.deinit();
        var base = try MockRelay.init(threaded.io(), .ok);
        defer base.deinit();
        var artifacts = try makeAuthArtifacts(gpa, &.{base.port}, &.{base.port}, 100);
        defer artifacts.deinit(gpa);
        const expected = try expectedArticles(gpa, artifacts.bundle);
        defer {
            for (expected) |e| gpa.free(e);
            gpa.free(expected);
        }
        var relay: AuthRelay = .{ .base = base, .scenario = .success, .expected = expected };
        const server = try std.Thread.spawn(.{}, serveAuthThread, .{ &relay, gpa });
        var server_joined = false;
        defer if (!server_joined) server.join();
        var to_child: [2]std.c.fd_t = undefined;
        var to_parent: [2]std.c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&to_child));
        defer {
            _ = std.c.close(to_child[0]);
            _ = std.c.close(to_child[1]);
        }
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&to_parent));
        defer {
            _ = std.c.close(to_parent[0]);
            _ = std.c.close(to_parent[1]);
        }
        var child = try auth_ipc.Channel.init(threaded.io(), to_child[0], to_parent[1]);
        child.run = @splat('1');
        child.ceiling = auth.Deadline.after(threaded.io(), auth.session_ms);
        var signer = try auth_ipc.Channel.init(threaded.io(), to_parent[0], to_child[1]);
        const signer_thread = try std.Thread.spawn(.{}, invalidSignerThread, .{ &signer, scenario, gpa });
        if (scenario == .duplicate or (@intFromEnum(scenario) >= @intFromEnum(InvalidSigner.run) and @intFromEnum(scenario) <= @intFromEnum(InvalidSigner.revision))) {
            try testing.expectError(error.SessionInvalid, np.run(threaded.io(), gpa, .{ .plan = artifacts.plan, .bundle = artifacts.bundle, .auth_channel = &child }));
            signer_thread.join();
            server.join();
            server_joined = true;
            try testing.expectEqual(@as(u64, 1), child.request);
            try testing.expectEqual(@as(usize, 0), relay.saw_auth);
            try testing.expectEqual(@as(usize, 0), relay.base.saw_events);
            continue;
        }
        var vtable = threaded.io().vtable.*;
        if (scenario == .blocked_write) {
            BlockingAuthWrite.native = threaded.io();
            BlockingAuthWrite.writes.store(0, .release);
            vtable.netWrite = BlockingAuthWrite.write;
        }
        const client_io: Io = .{ .userdata = threaded.io().userdata, .vtable = &vtable };
        var result = try np.run(client_io, gpa, .{ .plan = artifacts.plan, .bundle = artifacts.bundle, .auth_channel = &child });
        defer result.deinit();
        signer_thread.join();
        server.join();
        server_joined = true;
        try testing.expect(result.report != null);
        var parsed = try std.json.parseFromSlice(struct { relays: []const struct { auth: struct { status: []const u8, signing_requests: usize, auth_sends: usize } } }, gpa, result.report.?, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const evidence = parsed.value.relays[0].auth;
        try testing.expectEqualStrings(if (scenario == .refusal) "signer-error" else if (scenario == .hang or scenario == .partial_header or scenario == .late or scenario == .blocked_write) "timeout" else "protocol-error", evidence.status);
        try testing.expectEqual(@as(usize, 1), evidence.signing_requests);
        try testing.expectEqual(@as(usize, 0), evidence.auth_sends);
        try testing.expectEqual(@as(usize, 0), relay.saw_auth);
        try testing.expectEqual(@as(usize, 0), relay.base.saw_events);
    }
}

/// Relay URL format used by the plain loopback scenarios; the TLS scenarios
/// use `wss://localhost:{d}` against the pinned test CA instead. The quotes
/// are part of the JSON artifact (the plan embeds the URL as a string).
const TestClock = struct {
    var offset: std.atomic.Value(i64) = .init(0);
    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        var timestamp = testing.io.vtable.now(userdata, clock);
        if (clock == .awake) timestamp.nanoseconds += offset.load(.acquire);
        return timestamp;
    }
};

test "NIP-42 injected total ceiling preserves acceptance and bounds ordinary-relay traffic" {
    if (comptime !auth_ipc.supported) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    TestClock.offset.store(0, .release);
    defer TestClock.offset.store(0, .release);
    var vtable = io.vtable.*;
    vtable.now = TestClock.now;
    const timed_io: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var first_base = try MockRelay.init(io, .ok);
    defer first_base.deinit();
    var ordinary = try MockRelay.init(io, .clock_expiry);
    defer ordinary.deinit();
    var third = try MockRelay.init(io, .ok);
    defer third.deinit();
    var artifacts = try makeAuthArtifacts(gpa, &.{ first_base.port, ordinary.port, third.port }, &.{ first_base.port, third.port }, 200);
    defer artifacts.deinit(gpa);
    const expected = try expectedArticles(gpa, artifacts.bundle);
    defer {
        for (expected) |e| gpa.free(e);
        gpa.free(expected);
    }
    var first: AuthRelay = .{ .base = first_base, .scenario = .success, .expected = expected };
    const first_thread = try std.Thread.spawn(.{}, serveAuthThread, .{ &first, gpa });
    defer first_thread.join();
    const ordinary_thread = try std.Thread.spawn(.{}, serveOneThread, .{ &ordinary, gpa });
    defer ordinary_thread.join();
    var to_child: [2]std.c.fd_t = undefined;
    var to_parent: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&to_child));
    defer {
        _ = std.c.close(to_child[0]);
        _ = std.c.close(to_child[1]);
    }
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&to_parent));
    defer {
        _ = std.c.close(to_parent[0]);
        _ = std.c.close(to_parent[1]);
    }
    var child = try auth_ipc.Channel.init(timed_io, to_child[0], to_parent[1]);
    child.run = @splat('1');
    child.ceiling = auth.Deadline.after(timed_io, auth.session_ms);
    var signer = try auth_ipc.Channel.init(io, to_parent[0], to_child[1]);
    const signer_thread = try std.Thread.spawn(.{}, invalidSignerThread, .{ &signer, InvalidSigner.valid, gpa });
    defer signer_thread.join();
    var result = try np.run(timed_io, gpa, .{ .plan = artifacts.plan, .bundle = artifacts.bundle, .auth_channel = &child });
    defer result.deinit();
    try testing.expectEqual(np.Classification.partial, result.classification.?);
    const Document = struct { relays: []const struct { outcome: []const u8, attempts: usize, auth: struct { status: []const u8, reason: []const u8 }, events: []const struct { result: []const u8 } } };
    var parsed = try std.json.parseFromSlice(Document, gpa, result.report.?, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const relays = parsed.value.relays;
    try testing.expectEqualStrings("accepted", relays[0].outcome);
    for (relays[0].events) |event| try testing.expectEqualStrings("accepted", event.result);
    try testing.expectEqualStrings("not-requested", relays[1].auth.status);
    try testing.expectEqualStrings("session-timeout", relays[1].auth.reason);
    try testing.expectEqual(@as(usize, 1), relays[1].attempts);
    try testing.expectEqualStrings("timeout", relays[2].auth.status);
    try testing.expectEqualStrings("session-timeout", relays[2].auth.reason);
    for (relays[2].events) |event| try testing.expectEqualStrings("not-attempted", event.result);
    try testing.expectEqual(@as(u64, 1), child.request);
    var listener = [_]std.c.pollfd{.{ .fd = @intCast(third.server.socket.handle), .events = posix.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&listener, 1, 0));
}

const loopback_url_fmt = "\"ws://127.0.0.1:{d}\"";

const Scenario = enum {
    /// Answer every EVENT with `["OK", id, true, ""]`.
    ok,
    /// Split the OK across two text frames; the client must reassemble.
    fragmented_ok,
    /// Send a Ping before the OK; the client must answer Pong.
    ping_before_ok,
    /// Send a NOTICE, then the OK.
    notice_then_ok,
    /// Close the connection right after the EVENT, without any OK.
    close_immediately,
    /// Send a masked server text frame (RFC-6455 violation).
    masked_server_frame,
    /// Never answer; the client must hit its deadline and retry budget.
    silent,
    /// Reply `["OK", id, false, "auth-required: please authenticate"]`.
    auth_required,
    /// Reply `["OK", id, false, "blocked: spam"]` — a plain rejection.
    rejected,
    /// Reply OK for a different event id (must fail closed).
    wrong_id,
    /// Send a text frame that is not JSON.
    garbage,
    /// Declare an oversized frame length (must be refused pre-allocation).
    oversized_frame,
    /// Refuse the WebSocket upgrade with a plain 400.
    bad_handshake,
    /// Spray a deterministic stream of random frames (random opcodes, fin
    /// bits, lengths, payloads) plus raw garbage at the client.
    fuzz_stream,
    clock_expiry,
};

const MockRelay = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,
    scenario: Scenario,
    saw_pong: bool = false,
    saw_events: usize = 0,

    fn init(io: Io, scenario: Scenario) !MockRelay {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = address.listen(io, .{
            .kernel_backlog = 1,
            .reuse_address = false,
        }) catch return error.BindFailed;
        errdefer server.deinit(io);
        const port = server.socket.address.getPort();
        if (port == 0) return error.BindFailed;
        return .{ .io = io, .server = server, .port = port, .scenario = scenario };
    }

    fn deinit(self: *MockRelay) void {
        self.server.deinit(self.io);
        self.* = undefined;
    }
};

/// One masked client frame, payload unmasked into the caller's scratch
/// buffer (which owns the bytes until the next call).
const ClientFrame = struct {
    fin: bool,
    opcode: u4,
    /// The wire mask bit (RFC 6455 §5.1: client frames MUST be masked).
    masked: bool,
    /// The raw 7-bit length code from the wire: a direct length (0-125),
    /// 126 (2-byte extended length), or 127 (8-byte extended length).
    length_code: u8,
    payload: []const u8,
};

fn readClientFrame(fd: std.c.fd_t, gpa: std.mem.Allocator, scratch: *std.ArrayList(u8), max_payload: usize) !ClientFrame {
    var header: [14]u8 = undefined;
    try readExactlyFd(fd, header[0..2]);
    const fin = (header[0] & 0x80) != 0;
    const opcode: u4 = @intCast(header[0] & 0x0F);
    const masked = (header[1] & 0x80) != 0;
    const length_code = header[1] & 0x7F;
    var payload_len: u64 = length_code;
    var extra: usize = 0;
    if (payload_len == 126) extra = 2 else if (payload_len == 127) extra = 8;
    if (extra > 0) try readExactlyFd(fd, header[2 .. 2 + extra]);
    if (payload_len == 126) {
        payload_len = (@as(u64, header[2]) << 8) | header[3];
    } else if (payload_len == 127) {
        payload_len = 0;
        for (header[2..10]) |b| payload_len = (payload_len << 8) | b;
    }
    if (payload_len > max_payload) return error.Oversized;

    var mask: [4]u8 = undefined;
    try readExactlyFd(fd, &mask);
    const base = scratch.items.len;
    try scratch.resize(gpa, base + @as(usize, @intCast(payload_len)));
    const payload = scratch.items[base..];
    try readExactlyFd(fd, payload);
    for (payload, 0..) |*byte, i| byte.* ^= mask[i % 4];
    return .{ .fin = fin, .opcode = opcode, .masked = masked, .length_code = length_code, .payload = payload };
}

/// Read the client's HTTP upgrade request and answer with the computed
/// Sec-WebSocket-Accept. Returns false if the request is malformed.
fn readAllFd(fd: std.c.fd_t, buf: []u8, needed: []const u8) !usize {
    var len: usize = 0;
    while (std.mem.indexOf(u8, buf[0..len], needed) == null) {
        if (len == buf.len) return error.ProtocolError;
        const got = posix.read(fd, buf[len..]) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.EndOfStream,
            else => return err,
        };
        if (got == 0) return error.EndOfStream;
        len += got;
    }
    return len;
}

/// Read exactly `buf.len` bytes (loop until full).
fn readExactlyFd(fd: std.c.fd_t, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const got = posix.read(fd, buf[filled..]) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.EndOfStream,
            else => return err,
        };
        if (got == 0) return error.EndOfStream;
        filled += got;
    }
}

/// Raw socket write. `std.posix` no longer wraps write in 0.16, so the relay
/// (which deliberately avoids the Io interface layer) goes through libc.
fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (n < 0) return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        i += @intCast(n);
    }
}

/// Serve the client's HTTP upgrade request over the raw accepted socket, so
/// the relay never touches the Io interface layer: plain blocking syscalls
/// on its own thread.
fn performHandshakeFd(fd: std.c.fd_t, read_buf: *[16384]u8, write_buf: *[4096]u8, scenario: Scenario) !bool {
    _ = write_buf;
    const len = try readAllFd(fd, read_buf, "\r\n\r\n");
    const headers = read_buf[0..len];
    if (scenario == .bad_handshake) {
        try writeAllFd(fd, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
        return false;
    }

    var key: ?[]const u8 = null;
    var rest = headers;
    while (std.mem.indexOf(u8, rest, "\r\n")) |line_end| {
        const line = rest[0..line_end];
        rest = rest[line_end + 2 ..];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) key = value;
    }
    if (key == null) return error.ProtocolError;

    var digest: [20]u8 = undefined;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key.?);
    sha1.update(rfc_guid);
    sha1.final(&digest);
    var accept_buf: [32]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    var response_buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    try writeAllFd(fd, response);

    return true;
}

fn sendServerText(fd: std.c.fd_t, payload: []const u8) !void {
    var frame_buf: [8192]u8 = undefined;
    const len = try ws.encodeFrame(&frame_buf, .text, payload, .{ 0, 0, 0, 0 }, true, false);
    try writeAllFd(fd, frame_buf[0..len]);
}

fn sendServerFragmentedOk(fd: std.c.fd_t, id: []const u8) !void {
    var head_buf: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "[\"OK\",\"{s}\",", .{id});
    var frame_buf: [1024]u8 = undefined;
    const head_len = try ws.encodeFrame(&frame_buf, .text, head, .{ 0, 0, 0, 0 }, false, false);
    try writeAllFd(fd, frame_buf[0..head_len]);
    const tail_len = try ws.encodeFrame(&frame_buf, .continuation, "true,\"\"]", .{ 0, 0, 0, 0 }, true, false);
    try writeAllFd(fd, frame_buf[0..tail_len]);
}

fn sendServerPing(fd: std.c.fd_t) !void {
    var frame_buf: [16]u8 = undefined;
    const len = try ws.encodeFrame(&frame_buf, .ping, "p", .{ 0, 0, 0, 0 }, true, false);
    try writeAllFd(fd, frame_buf[0..len]);
}

fn sendServerClose(fd: std.c.fd_t) !void {
    const payload = [_]u8{ 0x03, 0xE8 }; // 1000 normal closure
    var frame_buf: [16]u8 = undefined;
    const len = try ws.encodeFrame(&frame_buf, .close, &payload, .{ 0, 0, 0, 0 }, true, false);
    try writeAllFd(fd, frame_buf[0..len]);
}

/// Send a *masked* server text frame: an RFC-6455 violation the client must
/// refuse.
fn sendMaskedServerText(fd: std.c.fd_t, payload: []const u8) !void {
    var frame_buf: [1024]u8 = undefined;
    const len = try ws.encodeFrame(&frame_buf, .text, payload, .{ 1, 2, 3, 4 }, true, true);
    try writeAllFd(fd, frame_buf[0..len]);
}

fn sendOversizedHeader(fd: std.c.fd_t) !void {
    // FIN|text, 127-form length = maxInt(u64)/2 + 1 (refused pre-allocation).
    const header = [_]u8{ 0x81, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
    try writeAllFd(fd, &header);
}

fn extractEventId(gpa: std.mem.Allocator, msg: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, msg, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array or root.array.items.len < 2) return error.Malformed;
    const event = root.array.items[1];
    if (event != .object) return error.Malformed;
    const id = event.object.get("id") orelse return error.Malformed;
    if (id != .string) return error.Malformed;
    return gpa.dupe(u8, id.string);
}

fn serveOne(self: *MockRelay, gpa: std.mem.Allocator) !void {
    const stream = try self.server.accept(self.io);
    defer stream.close(self.io);
    const fd: std.c.fd_t = @intCast(stream.socket.handle);
    var read_buf: [16384]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    const upgraded = performHandshakeFd(fd, &read_buf, &write_buf, self.scenario) catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };
    if (!upgraded) return;

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);

    while (true) {
        const frame = readClientFrame(fd, gpa, &scratch, 64 * 1024) catch |err| switch (err) {
            error.EndOfStream, error.Oversized => return,
            else => return err,
        };
        switch (frame.opcode) {
            0xA => self.saw_pong = true, // client answered our Ping
            0x8 => return, // client Close; exchange over
            0x1 => {
                // A conforming client may fragment a message (RFC 6455 §5.4);
                // reassemble the text + continuation frames before handling
                // it so the matrix accepts the client's fragmentation too.
                var msg: std.ArrayList(u8) = .empty;
                defer msg.deinit(gpa);
                try msg.appendSlice(gpa, frame.payload);
                var fin = frame.fin;
                while (!fin) {
                    const next = readClientFrame(fd, gpa, &scratch, 64 * 1024) catch |err| switch (err) {
                        error.EndOfStream, error.Oversized => return,
                        else => return err,
                    };
                    if (next.opcode != 0x0) return error.ProtocolError; // continuation expected
                    try msg.appendSlice(gpa, next.payload);
                    fin = next.fin;
                }
                if (!std.mem.startsWith(u8, msg.items, "[\"EVENT\"")) return error.ProtocolError;
                self.saw_events += 1;
                const id = try extractEventId(gpa, msg.items);
                defer gpa.free(id);
                try actOnEvent(self, fd, id);
            },
            else => return error.ProtocolError,
        }
    }
}

fn actOnEvent(self: *MockRelay, fd: std.c.fd_t, id: []const u8) !void {
    switch (self.scenario) {
        .clock_expiry => {
            TestClock.offset.store(@as(i64, auth.session_ms) * std.time.ns_per_ms, .release);
            try sendServerText(fd, "[\"NOTICE\",\"ordinary traffic cannot renew ceiling\"]");
        },
        .ok, .notice_then_ok => {
            if (self.scenario == .notice_then_ok) {
                try sendServerText(fd, "[\"NOTICE\",\"will accept\"]");
            }
            var ok_buf: [512]u8 = undefined;
            const ok = try std.fmt.bufPrint(&ok_buf, "[\"OK\",\"{s}\",true,\"\"]", .{id});
            try sendServerText(fd, ok);
        },
        .fragmented_ok => try sendServerFragmentedOk(fd, id),
        .ping_before_ok => {
            try sendServerPing(fd);
            // The client answers with a masked Pong before continuing; read it
            // so the exchange stays clean, then deliver the OK.
            var scratch: std.ArrayList(u8) = .empty;
            defer scratch.deinit(testing.allocator);
            const pong = readClientFrame(fd, testing.allocator, &scratch, 1024) catch return;
            if (pong.opcode != 0xA) return error.ProtocolError;
            self.saw_pong = true;
            var ok_buf: [512]u8 = undefined;
            const ok = try std.fmt.bufPrint(&ok_buf, "[\"OK\",\"{s}\",true,\"\"]", .{id});
            try sendServerText(fd, ok);
        },
        .close_immediately => try sendServerClose(fd),
        .masked_server_frame => {
            var ok_buf: [512]u8 = undefined;
            const ok = try std.fmt.bufPrint(&ok_buf, "[\"OK\",\"{s}\",true,\"\"]", .{id});
            try sendMaskedServerText(fd, ok);
        },
        .silent => {}, // never answer; the client must time out
        .auth_required => {
            var ok_buf: [512]u8 = undefined;
            const ok = try std.fmt.bufPrint(&ok_buf, "[\"OK\",\"{s}\",false,\"auth-required: please authenticate\"]", .{id});
            try sendServerText(fd, ok);
        },
        .rejected => {
            var ok_buf: [512]u8 = undefined;
            const ok = try std.fmt.bufPrint(&ok_buf, "[\"OK\",\"{s}\",false,\"blocked: spam\"]", .{id});
            try sendServerText(fd, ok);
        },
        .wrong_id => {
            var ok_buf: [512]u8 = undefined;
            const ok = try std.fmt.bufPrint(&ok_buf, "[\"OK\",\"{s}\",true,\"\"]", .{"1111111111111111111111111111111111111111111111111111111111111111"});
            try sendServerText(fd, ok);
        },
        .garbage => try sendServerText(fd, "this is not json"),
        .oversized_frame => try sendOversizedHeader(fd),
        .bad_handshake => unreachable, // handled at the handshake stage
        .fuzz_stream => try sendFuzzStream(fd),
    }
}

/// Spray a deterministic stream of random frames at the client after its
/// EVENT: frame 0 is guaranteed text with a random, non-JSON payload (the
/// publish loop must fail closed on the very first message), then a mix of
/// random-opcode / random-fin / random-length server frames. The client must
/// never hang, never crash, and never mistake any of it for an OK.
fn sendFuzzStream(fd: std.c.fd_t) !void {
    var prng = std.Random.DefaultPrng.init(0xF0D0_5EED);
    const rand = prng.random();
    var frame_buf: [2048]u8 = undefined;
    var payload_buf: [256]u8 = undefined;

    rand.bytes(&payload_buf);
    var len = try ws.encodeFrame(&frame_buf, .text, &payload_buf, .{ 0, 0, 0, 0 }, true, false);
    try writeAllFd(fd, frame_buf[0..len]);

    var i: usize = 0;
    while (i < 31) : (i += 1) {
        const opcode: ws.Opcode = switch (rand.intRangeAtMost(u8, 0, 2)) {
            0 => .continuation,
            1 => .text,
            else => .binary,
        };
        const fin = rand.boolean();
        const plen = rand.intRangeAtMost(usize, 0, payload_buf.len);
        rand.bytes(payload_buf[0..plen]);
        len = try ws.encodeFrame(&frame_buf, opcode, payload_buf[0..plen], .{ 0, 0, 0, 0 }, fin, false);
        try writeAllFd(fd, frame_buf[0..len]);
    }
}

// =============================================================================
// Artifact building: a real plan + a genuinely signed bundle (re-verified by
// nostr_publish before anything is sent).
// =============================================================================

fn buildPlan(gpa: std.mem.Allocator, ports: []const u16, timeout_ms: u32, retries: u8, pub_hex: []const u8, comptime url_fmt: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"format\":\"boris-nostr-publication-plan\",\"schema_version\":1,\"protocol\":{\"kind\":30023},\"author\":{\"expected_pubkey\":\"");
    try out.appendSlice(gpa, pub_hex);
    try out.appendSlice(gpa, "\"},\"delivery\":{\"relays\":[");
    for (ports, 0..) |port, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, url_fmt, .{port});
        try out.appendSlice(gpa, url);
    }
    try out.appendSlice(gpa, "],\"timeout_ms\":");
    var num_buf: [16]u8 = undefined;
    const timeout = try std.fmt.bufPrint(&num_buf, "{d}", .{timeout_ms});
    try out.appendSlice(gpa, timeout);
    try out.appendSlice(gpa, ",\"retries\":");
    const retry = try std.fmt.bufPrint(&num_buf, "{d}", .{retries});
    try out.appendSlice(gpa, retry);
    try out.appendSlice(gpa, "},\"articles\":[{\"entity_id\":\"");
    try out.appendSlice(gpa, event_entity);
    try out.appendSlice(gpa, "\"}]}");
    return out.toOwnedSlice(gpa);
}

const event_entity = "articles/matrix";
const event_content = "A bounded in-repo RFC-6455 client, exercised by a hostile mock relay.";

fn buildBundle(gpa: std.mem.Allocator, plan_bytes: []const u8, kp: keys.KeyPair, pub_hex: []const u8) ![]u8 {
    var ctx = try keys.Context.init();
    defer ctx.deinit();

    // Event fields; the id is the SHA-256 of the canonical NIP-01 preimage.
    const created_at: i64 = 1_700_000_000;
    const kind: u32 = 30023;
    var tags: [2]nostr.Tag = .{
        .{ .name = "d", .value = event_entity },
        .{ .name = "title", .value = "Matrix" },
    };
    var preimage: std.ArrayList(u8) = .empty;
    defer preimage.deinit(gpa);
    try nostr.appendEventPreimage(&preimage, gpa, pub_hex, created_at, kind, &tags, event_content);
    var id_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(preimage.items, &id_bytes, .{});
    var id_hex_buf: [64]u8 = undefined;
    const id_hex = try std.fmt.bufPrint(&id_hex_buf, "{x}", .{&id_bytes});
    const sig = try ctx.signId(id_bytes, kp, null);
    var sig_hex_buf: [128]u8 = undefined;
    const sig_hex = try std.fmt.bufPrint(&sig_hex_buf, "{x}", .{&sig});

    var plan_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plan_bytes, &plan_digest, .{});
    var pd_hex_buf: [64]u8 = undefined;
    const pd_hex = try std.fmt.bufPrint(&pd_hex_buf, "{x}", .{&plan_digest});

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"format\":\"boris-nostr-signed-bundle\",\"schema_version\":1,\"plan\":{\"format\":\"boris-nostr-publication-plan\",\"schema_version\":1,\"digest\":\"");
    try out.appendSlice(gpa, pd_hex);
    try out.appendSlice(gpa, "\"},\"signer\":{\"pubkey\":\"");
    try out.appendSlice(gpa, pub_hex);
    try out.appendSlice(gpa, "\"},\"articles\":[{\"entity_id\":\"");
    try out.appendSlice(gpa, event_entity);
    try out.appendSlice(gpa, "\",\"event_id\":\"");
    try out.appendSlice(gpa, id_hex);
    try out.appendSlice(gpa, "\",\"event\":{\"id\":\"");
    try out.appendSlice(gpa, id_hex);
    try out.appendSlice(gpa, "\",\"pubkey\":\"");
    try out.appendSlice(gpa, pub_hex);
    try out.appendSlice(gpa, "\",\"created_at\":");
    var num_buf: [16]u8 = undefined;
    const created = try std.fmt.bufPrint(&num_buf, "{d}", .{created_at});
    try out.appendSlice(gpa, created);
    try out.appendSlice(gpa, ",\"kind\":30023,\"tags\":[[\"d\",\"");
    try out.appendSlice(gpa, event_entity);
    try out.appendSlice(gpa, "\"],[\"title\",\"Matrix\"]],\"content\":\"");
    try out.appendSlice(gpa, event_content);
    try out.appendSlice(gpa, "\",\"sig\":\"");
    try out.appendSlice(gpa, sig_hex);
    try out.appendSlice(gpa, "\"}}]}");
    return out.toOwnedSlice(gpa);
}

const MatrixArtifacts = struct {
    plan: []u8,
    bundle: []u8,

    fn deinit(self: *MatrixArtifacts, gpa: std.mem.Allocator) void {
        gpa.free(self.plan);
        gpa.free(self.bundle);
        self.* = undefined;
    }
};

fn makeArtifacts(gpa: std.mem.Allocator, ports: []const u16, timeout_ms: u32, retries: u8, comptime url_fmt: []const u8) !MatrixArtifacts {
    var ctx = try keys.Context.init();
    defer ctx.deinit();
    const kp = try ctx.keyPairFromSecretKey(.{
        0xb7, 0xe1, 0x51, 0x62, 0x8a, 0xed, 0x2a, 0x6a, 0xbf, 0x71, 0x58, 0x80, 0x9c, 0xf4, 0xf3, 0xc7,
        0x62, 0xe7, 0x16, 0x0f, 0x38, 0xb4, 0xda, 0x56, 0xa7, 0x84, 0xd9, 0x04, 0x51, 0x0f, 0xcf, 0x39,
    });
    var pub_hex_buf: [64]u8 = undefined;
    const pub_hex = try std.fmt.bufPrint(&pub_hex_buf, "{x}", .{&kp.public_key});
    const plan = try buildPlan(gpa, ports, timeout_ms, retries, pub_hex, url_fmt);
    errdefer gpa.free(plan);
    const bundle = try buildBundle(gpa, plan, kp, pub_hex);
    return .{ .plan = plan, .bundle = bundle };
}

// =============================================================================
// Driver: the relay runs on its own dedicated thread with its own Io, so its
// blocking socket calls never share a thread pool with the client's nested
// deadline selects; the client runs `nostr_publish.run` on the test thread.
// =============================================================================

fn serveOneThread(relay: *MockRelay, gpa: std.mem.Allocator) void {
    serveOne(relay, gpa) catch {};
}

fn runMatrix(gpa: std.mem.Allocator, relay: *MockRelay, plan: []const u8, bundle: []const u8, tls: ws.TlsOptions) !np.Result {
    const relay_thread = try std.Thread.spawn(.{}, serveOneThread, .{ relay, gpa });
    defer relay_thread.join();

    var client_threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
    defer client_threaded.deinit();
    const io = client_threaded.io();
    return np.run(io, gpa, .{ .plan = plan, .bundle = bundle, .tls = tls });
}

/// Like `runMatrix`, but serves two relays concurrently so a multi-relay plan
/// can be exercised end to end.
fn runMatrixTwo(gpa: std.mem.Allocator, relay_a: *MockRelay, relay_b: *MockRelay, plan: []const u8, bundle: []const u8, tls: ws.TlsOptions) !np.Result {
    const thread_a = try std.Thread.spawn(.{}, serveOneThread, .{ relay_a, gpa });
    defer thread_a.join();
    const thread_b = try std.Thread.spawn(.{}, serveOneThread, .{ relay_b, gpa });
    defer thread_b.join();

    var client_threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
    defer client_threaded.deinit();
    const io = client_threaded.io();
    return np.run(io, gpa, .{ .plan = plan, .bundle = bundle, .tls = tls });
}

// =============================================================================
// Assertions over the report artifact.
// =============================================================================

const ReportJson = struct {
    classification: []const u8,
    relays: []const struct {
        url: []const u8,
        outcome: []const u8,
        attempts: usize = 0,
        events: []const struct {
            entity_id: []const u8 = "",
            event_id: []const u8 = "",
            result: []const u8,
            message: []const u8 = "",
        } = &.{},
    },
};

fn parseReport(gpa: std.mem.Allocator, result: *const np.Result) !std.json.Parsed(ReportJson) {
    return std.json.parseFromSlice(ReportJson, gpa, result.report.?, .{ .ignore_unknown_fields = true });
}

const Expect = struct {
    classification: np.Classification,
    outcome: []const u8,
    event_result: []const u8,
    attempts: usize = 1,
    message: []const u8 = "",
    saw_pong: bool = false,
    saw_events: usize = 1,
};

fn runScenario(scenario: Scenario, expect: Expect) !void {
    try runScenarioUrl(scenario, expect, loopback_url_fmt);
}

fn runScenarioUrl(scenario: Scenario, expect: Expect, comptime url_fmt: []const u8) !void {
    var relay_threaded = Io.Threaded.init(testing.allocator, .{ .environ = std.process.Environ.empty });
    defer relay_threaded.deinit();
    const relay_io = relay_threaded.io();

    var relay = try MockRelay.init(relay_io, scenario);
    defer relay.deinit();

    var artifacts = try makeArtifacts(testing.allocator, &.{relay.port}, 250, 0, url_fmt);
    defer artifacts.deinit(testing.allocator);

    var result = try runMatrix(testing.allocator, &relay, artifacts.plan, artifacts.bundle, .{});
    defer result.deinit();

    try testing.expectEqual(expect.classification, result.classification.?);
    var parsed = try parseReport(testing.allocator, &result);
    defer parsed.deinit();
    const report = parsed.value;
    try testing.expectEqual(@as(usize, 1), report.relays.len);
    try testing.expectEqualStrings(expect.outcome, report.relays[0].outcome);
    try testing.expectEqual(expect.attempts, report.relays[0].attempts);
    try testing.expectEqual(@as(usize, 1), report.relays[0].events.len);
    try testing.expectEqualStrings(expect.event_result, report.relays[0].events[0].result);
    if (expect.message.len > 0) try testing.expectEqualStrings(expect.message, report.relays[0].events[0].message);
    try testing.expectEqual(expect.saw_events, relay.saw_events);
    try testing.expectEqual(expect.saw_pong, relay.saw_pong);
}

// =============================================================================
// The matrix
// =============================================================================

test "matrix: an honest relay accepts the event (complete)" {
    try runScenario(.ok, .{
        .classification = .complete,
        .outcome = "accepted",
        .event_result = "accepted",
    });
}

test "matrix: hostname localhost resolves (not just 127.0.0.1)" {
    // #545: IpAddress.resolve is not DNS. `localhost` must go through
    // HostName.lookup. This is the CI-safe hostname path; public relays
    // are a live-smoke card, not this matrix.
    try runScenarioUrl(.ok, .{
        .classification = .complete,
        .outcome = "accepted",
        .event_result = "accepted",
    }, "\"ws://localhost:{d}\"");
}

test "matrix: a fragmented OK is reassembled and accepted" {
    try runScenario(.fragmented_ok, .{
        .classification = .complete,
        .outcome = "accepted",
        .event_result = "accepted",
    });
}

test "matrix: a Ping before the OK is answered with Pong, then accepted" {
    try runScenario(.ping_before_ok, .{
        .classification = .complete,
        .outcome = "accepted",
        .event_result = "accepted",
        .saw_pong = true,
    });
}

test "matrix: a NOTICE followed by the OK is accepted" {
    try runScenario(.notice_then_ok, .{
        .classification = .complete,
        .outcome = "accepted",
        .event_result = "accepted",
    });
}

test "matrix: the relay closing before an OK is a per-relay closed outcome" {
    try runScenario(.close_immediately, .{
        .classification = .failed,
        .outcome = "closed",
        .event_result = "closed",
    });
}

test "matrix: a masked server frame is a protocol error, not accepted" {
    try runScenario(.masked_server_frame, .{
        .classification = .failed,
        .outcome = "error",
        .event_result = "error",
        .message = "ProtocolError",
    });
}

test "matrix: a silent relay hits the deadline and the run is incomplete" {
    try runScenario(.silent, .{
        .classification = .incomplete,
        .outcome = "timeout",
        .event_result = "timeout",
    });
}

test "matrix: auth-required is an honest unsupported outcome (NIP-42 out of v1)" {
    try runScenario(.auth_required, .{
        .classification = .failed,
        .outcome = "auth-required",
        .event_result = "auth-required",
        .message = "auth-required",
    });
}

test "matrix: a plain OK-false is rejected, not a protocol error" {
    try runScenario(.rejected, .{
        .classification = .failed,
        .outcome = "rejected",
        .event_result = "rejected",
        .message = "blocked: spam",
    });
}

test "matrix: an OK for the wrong event id fails closed" {
    try runScenario(.wrong_id, .{
        .classification = .failed,
        .outcome = "wrong-id",
        .event_result = "wrong-id",
        .message = "wrong-id",
    });
}

test "matrix: garbage text is a protocol error, not accepted" {
    try runScenario(.garbage, .{
        .classification = .failed,
        .outcome = "error",
        .event_result = "error",
        .message = "Malformed",
    });
}

test "matrix: an oversized declared frame length is refused before allocation" {
    try runScenario(.oversized_frame, .{
        .classification = .failed,
        .outcome = "error",
        .event_result = "error",
        .message = "ProtocolError",
    });
}

test "matrix: a fuzzed server frame stream fails closed without hanging" {
    // The relay sprays a deterministic stream of random frames (guaranteed
    // garbage text first, then random opcode/fin/length frames). The client
    // must fail closed on the first message and return promptly.
    try runScenario(.fuzz_stream, .{
        .classification = .failed,
        .outcome = "error",
        .event_result = "error",
        .message = "Malformed",
    });
}

test "matrix: a refused upgrade is a connect failure, not a hang" {
    try runScenario(.bad_handshake, .{
        .classification = .failed,
        .outcome = "error",
        .event_result = "error",
        .saw_events = 0,
    });
}

test "matrix: a relay that retries on timeout sends the identical event again" {
    // retries = 1: the silent relay forces two attempts of the same event.
    var threaded = Io.Threaded.init(testing.allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();

    var relay = try MockRelay.init(io, .silent);
    defer relay.deinit();

    var artifacts = try makeArtifacts(testing.allocator, &.{relay.port}, 120, 1, loopback_url_fmt);
    defer artifacts.deinit(testing.allocator);

    var result = try runMatrix(testing.allocator, &relay, artifacts.plan, artifacts.bundle, .{});
    defer result.deinit();

    try testing.expectEqual(np.Classification.incomplete, result.classification.?);
    var parsed = try parseReport(testing.allocator, &result);
    defer parsed.deinit();
    const report = parsed.value;
    try testing.expectEqualStrings("timeout", report.relays[0].outcome);
    try testing.expectEqual(@as(usize, 2), report.relays[0].attempts);
    // The relay saw both identical sends (two EVENT frames).
    try testing.expectEqual(@as(usize, 2), relay.saw_events);
}

test "matrix: mixed relays classify partial and keep per-relay evidence" {
    var threaded = Io.Threaded.init(testing.allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();

    var ok_relay = try MockRelay.init(io, .ok);
    defer ok_relay.deinit();
    var auth_relay = try MockRelay.init(io, .auth_required);
    defer auth_relay.deinit();

    var artifacts = try makeArtifacts(testing.allocator, &.{ ok_relay.port, auth_relay.port }, 250, 0, loopback_url_fmt);
    defer artifacts.deinit(testing.allocator);

    var result = try runMatrixTwo(testing.allocator, &ok_relay, &auth_relay, artifacts.plan, artifacts.bundle, .{});
    defer result.deinit();

    try testing.expectEqual(np.Classification.partial, result.classification.?);
    var parsed = try parseReport(testing.allocator, &result);
    defer parsed.deinit();
    const report = parsed.value;
    try testing.expectEqual(@as(usize, 2), report.relays.len);
    try testing.expectEqualStrings("accepted", report.relays[0].outcome);
    try testing.expectEqualStrings("accepted", report.relays[0].events[0].result);
    try testing.expectEqualStrings("auth-required", report.relays[1].outcome);
    try testing.expectEqualStrings("auth-required", report.relays[1].events[0].result);
}

test "matrix: the golden publish-report fixture matches the contract shape" {
    const path = "docs/contracts/fixtures/nostr-publication/expected/publish-report.json";
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024)) catch |err| {
        std.debug.print("cannot read golden report fixture: {s}\n", .{@errorName(err)});
        return err;
    };
    defer testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(ReportJson, testing.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const report = parsed.value;
    try testing.expectEqualStrings("complete", report.classification);
    try testing.expectEqual(@as(usize, 1), report.relays.len);
    try testing.expectEqualStrings("wss://relay.example.com/", report.relays[0].url);
    try testing.expectEqualStrings("accepted", report.relays[0].outcome);
    try testing.expectEqual(@as(usize, 2), report.relays[0].events.len);
    for (report.relays[0].events) |event| {
        try testing.expectEqualStrings("accepted", event.result);
        try testing.expectEqual(@as(usize, 64), event.event_id.len);
        try testing.expect(event.entity_id.len > 0);
    }
}

// =============================================================================
// wss:// end-to-end: a real TLS mock relay. std 0.16 has no TLS *server*, so
// the relay is a tiny python `ssl` process (scripts/nostr-mock-relay-tls.py)
// pinned by the committed self-signed CA (docs/contracts/fixtures/.../tls/).
// =============================================================================

const tls_fixture_dir = "docs/contracts/fixtures/nostr-publication/tls";
const tls_ca_pem_path = tls_fixture_dir ++ "/ca.pem";
const tls_server_cert_path = tls_fixture_dir ++ "/server.pem";
const tls_server_key_path = tls_fixture_dir ++ "/server.key";
const tls_relay_script_path = "scripts/nostr-mock-relay-tls.py";

fn sleepMs(io: Io, ms: u32) void {
    (Io.Timeout{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(ms) } }).sleep(io) catch {};
}

fn readTlsFixture(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
}

/// The python `ssl` WebSocket mock relay on its own process, bound to
/// 127.0.0.1. It writes its ephemeral port to a temp file right after bind;
/// the test polls for the file so it never races the accept.
const TlsRelay = struct {
    child: std.process.Child,
    port: u16,

    fn spawn() !TlsRelay {
        // Reserve a free port for the child; loopback reuse races between
        // probe-close and child-bind are negligible in a test.
        const probe: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var probe_server = probe.listen(testing.io, .{ .kernel_backlog = 1, .reuse_address = false }) catch return error.BindFailed;
        const port = probe_server.socket.address.getPort();
        probe_server.deinit(testing.io);

        var port_file_buf: [160]u8 = undefined;
        const port_file = try std.fmt.bufPrint(&port_file_buf, "/tmp/boris-nostr-tls-relay-{d}.port", .{port});
        std.Io.Dir.cwd().deleteFile(testing.io, port_file) catch {};

        var port_buf: [16]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
        var child = std.process.spawn(testing.io, .{
            .argv = &.{ "python3", tls_relay_script_path, port_str, tls_server_cert_path, tls_server_key_path, port_file },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        }) catch return error.SpawnFailed;
        errdefer {
            // `Child.kill` in 0.16 blocks until the child is reaped; a later
            // `wait` would assert on the already-cleared id.
            if (child.id != null) child.kill(testing.io);
        }

        var attempts: usize = 0;
        var relay_port: ?u16 = null;
        while (attempts < 200) : (attempts += 1) {
            if (std.Io.Dir.cwd().readFileAlloc(testing.io, port_file, testing.allocator, .limited(64))) |bytes| {
                defer testing.allocator.free(bytes);
                relay_port = std.fmt.parseInt(u16, std.mem.trim(u8, bytes, " \t\r\n"), 10) catch null;
                if (relay_port != null) break;
            } else |_| {}
            sleepMs(testing.io, 25);
        }
        const bound_port = relay_port orelse return error.RelayNeverReady;
        return .{ .child = child, .port = bound_port };
    }

    fn deinit(self: *TlsRelay) void {
        if (self.child.id != null) self.child.kill(testing.io);
        self.* = undefined;
    }
};

/// Run the publish pipeline without an in-process MockRelay (the TLS relay
/// is an external process).
fn runPublish(gpa: std.mem.Allocator, plan: []const u8, bundle: []const u8, tls: ws.TlsOptions) !np.Result {
    var client_threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
    defer client_threaded.deinit();
    const io = client_threaded.io();
    return np.run(io, gpa, .{ .plan = plan, .bundle = bundle, .tls = tls });
}

test "tls: a real wss:// relay with a pinned self-signed CA accepts the event" {
    // #552: the first TLS application read is often a 0-byte NewSessionTicket,
    // not the 101. This test is the gate that the upgrade still completes.
    var relay = try TlsRelay.spawn();
    defer relay.deinit();

    const ca_pem = try readTlsFixture(tls_ca_pem_path);
    defer testing.allocator.free(ca_pem);

    var artifacts = try makeArtifacts(testing.allocator, &.{relay.port}, 10_000, 0, "\"wss://127.0.0.1:{d}\"");
    defer artifacts.deinit(testing.allocator);

    var result = try runPublish(testing.allocator, artifacts.plan, artifacts.bundle, .{ .extra_ca_pem = ca_pem, .verify_host = "localhost" });
    defer result.deinit();

    try testing.expectEqual(np.Classification.complete, result.classification.?);
    var parsed = try parseReport(testing.allocator, &result);
    defer parsed.deinit();
    const report = parsed.value;
    try testing.expectEqual(@as(usize, 1), report.relays.len);
    try testing.expectEqualStrings("accepted", report.relays[0].outcome);
    try testing.expectEqualStrings("accepted", report.relays[0].events[0].result);

    // The relay served exactly one full session over TLS and exited cleanly.
    const term = try relay.child.wait(testing.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
}

test "tls: a pinned CA does not excuse a hostname mismatch" {
    var relay = try TlsRelay.spawn();
    defer relay.deinit();

    const ca_pem = try readTlsFixture(tls_ca_pem_path);
    defer testing.allocator.free(ca_pem);

    // The leaf carries SAN DNS:localhost only; connecting to 127.0.0.1 must
    // fail hostname verification even though the CA is trusted.
    var artifacts = try makeArtifacts(testing.allocator, &.{relay.port}, 10_000, 0, "\"wss://127.0.0.1:{d}\"");
    defer artifacts.deinit(testing.allocator);

    var result = try runPublish(testing.allocator, artifacts.plan, artifacts.bundle, .{ .extra_ca_pem = ca_pem });
    defer result.deinit();

    try testing.expectEqual(np.Classification.failed, result.classification.?);
    var parsed = try parseReport(testing.allocator, &result);
    defer parsed.deinit();
    const report = parsed.value;
    try testing.expectEqualStrings("error", report.relays[0].outcome);
    try testing.expectEqualStrings("TlsFailed", report.relays[0].events[0].message);
}

// =============================================================================
// Write-side fuzz: random payloads and fragmentation patterns through
// `sendText`, verified byte-exact by a recording mock relay. Where the
// parser fuzz feeds hostile bytes *to* the client, this drives the client's
// own encoder: for every (payload, fragment-size) pair, the relay records
// exactly what a server would receive — frame structure, mask bits, length
// codes, and the unmasked payload — and the test asserts it matches what
// `sendText` was asked to send, byte for byte.
// =============================================================================

/// What the recorder observed for one client message.
const RecordedMessage = struct {
    /// Frames the message arrived in (1 = unfragmented).
    fragments: usize,
    /// The mask bit was set on every frame (client frames MUST be masked).
    all_masked: bool,
    /// FIN was clear on every frame but the last (and set on a lone frame).
    fin_pattern_ok: bool,
    /// Every frame's raw length code matches RFC-6455 for its payload.
    length_pattern_ok: bool,
    /// The unmasked bytes as a server would deliver them; owned by the
    /// relay and freed in `WriteRecorderRelay.deinit`.
    payload: []u8,
};

const WriteRecorderRelay = struct {
    io: Io,
    gpa: std.mem.Allocator,
    server: Io.net.Server,
    port: u16,
    /// Appended by the relay thread; read by the test only after join.
    records: std.ArrayList(RecordedMessage) = .empty,

    fn init(io: Io, gpa: std.mem.Allocator) !WriteRecorderRelay {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = address.listen(io, .{
            .kernel_backlog = 1,
            .reuse_address = false,
        }) catch return error.BindFailed;
        errdefer server.deinit(io);
        const port = server.socket.address.getPort();
        if (port == 0) return error.BindFailed;
        return .{ .io = io, .gpa = gpa, .server = server, .port = port };
    }

    fn deinit(self: *WriteRecorderRelay) void {
        for (self.records.items) |rec| self.gpa.free(rec.payload);
        self.records.deinit(self.gpa);
        self.server.deinit(self.io);
        self.* = undefined;
    }
};

/// True when the wire's raw 7-bit length code is the RFC-6455 encoding for
/// `payload_len`: direct length below 126, 126 for the 2-byte extended
/// form, 127 for the 8-byte form.
fn lengthCodeOk(length_code: u8, payload_len: usize) bool {
    if (payload_len < 126) return length_code == payload_len;
    if (payload_len <= std.math.maxInt(u16)) return length_code == 126;
    return length_code == 127;
}

fn serveWriteRecorder(relay: *WriteRecorderRelay, gpa: std.mem.Allocator) void {
    serveWriteRecorderInner(relay, gpa) catch {};
}

fn serveWriteRecorderInner(relay: *WriteRecorderRelay, gpa: std.mem.Allocator) !void {
    const stream = try relay.server.accept(relay.io);
    defer stream.close(relay.io);
    const fd: std.c.fd_t = @intCast(stream.socket.handle);
    var read_buf: [16384]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    _ = try performHandshakeFd(fd, &read_buf, &write_buf, .ok);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);

    while (true) {
        const frame = readClientFrame(fd, gpa, &scratch, 16 * 1024 * 1024) catch |err| switch (err) {
            error.EndOfStream, error.Oversized => return,
            else => return err,
        };
        switch (frame.opcode) {
            0x8 => return, // client Close ends the session
            0x1 => {
                // Reassemble the fragmented message, recording the wire
                // structure of every frame for the test to verify.
                var msg: std.ArrayList(u8) = .empty;
                defer msg.deinit(gpa);
                try msg.appendSlice(gpa, frame.payload);
                const first_fin = frame.fin;
                var fragments: usize = 1;
                var all_masked = frame.masked;
                var length_pattern_ok = lengthCodeOk(frame.length_code, frame.payload.len);
                var fin = frame.fin;
                while (!fin) {
                    const next = readClientFrame(fd, gpa, &scratch, 16 * 1024 * 1024) catch |err| switch (err) {
                        error.EndOfStream, error.Oversized => return,
                        else => return err,
                    };
                    // Any non-continuation frame here means the client broke
                    // the fragmentation sequence; fail the session loudly.
                    if (next.opcode != 0x0) return error.ProtocolError;
                    fragments += 1;
                    all_masked = all_masked and next.masked;
                    length_pattern_ok = length_pattern_ok and lengthCodeOk(next.length_code, next.payload.len);
                    try msg.appendSlice(gpa, next.payload);
                    fin = next.fin;
                }
                // The loop exits exactly when a FIN frame arrives, so the
                // last frame carries FIN by construction; a valid sequence
                // additionally opens with FIN clear when fragmented.
                const fin_pattern_ok = (fragments == 1) or !first_fin;
                const payload = try gpa.dupe(u8, msg.items);
                try relay.records.append(gpa, .{
                    .fragments = fragments,
                    .all_masked = all_masked,
                    .fin_pattern_ok = fin_pattern_ok,
                    .length_pattern_ok = length_pattern_ok,
                    .payload = payload,
                });
            },
            else => return error.ProtocolError,
        }
    }
}

/// Every recorded message must match its `sent` counterpart byte-exact and
/// arrive with the exact frame structure the chosen fragment size implies.
fn verifyRecordedMessages(relay: *const WriteRecorderRelay, sent: []const []const u8, frag_size: usize) !void {
    try testing.expectEqual(sent.len, relay.records.items.len);
    for (sent, relay.records.items) |expected, rec| {
        const expected_fragments: usize = if (expected.len == 0) 1 else (expected.len + frag_size - 1) / frag_size;
        try testing.expectEqual(expected_fragments, rec.fragments);
        try testing.expect(rec.all_masked);
        try testing.expect(rec.fin_pattern_ok);
        try testing.expect(rec.length_pattern_ok);
        try testing.expectEqualStrings(expected, rec.payload);
    }
}

test "write fuzz: random payloads and fragmentation patterns arrive byte-exact" {
    // Hundreds of thousands of frames allocate transport/task scratch. Keep
    // allocator safety and leak checks without unwinding a stack per allocation.
    var allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 0, .safety = true }) = .init;
    defer if (allocator.deinit() == .leak) @panic("write-fuzz allocator leaked");
    const gpa = allocator.allocator();
    var relay_threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
    defer relay_threaded.deinit();
    const relay_io = relay_threaded.io();

    var client_threaded = Io.Threaded.init(gpa, .{ .environ = std.process.Environ.empty });
    defer client_threaded.deinit();
    const client_io = client_threaded.io();

    var prng = std.Random.DefaultPrng.init(0x57A1_1E5E);
    const rand = prng.random();

    // Fragment sizes hitting every header-encoding boundary: the 125-byte
    // control bound, the 2-byte extended-length entry (126), and the 8-byte
    // entry (65536), plus the degenerate 1-byte case that maximizes the
    // frame count. max_fragment_bytes is a per-client limit, so each size
    // gets its own connection and the recorded messages stay attributable.
    const fragment_sizes = [_]usize{ 1, 125, 126, 65535, 65536 };
    // Exact boundary payload lengths (0 through the 16-bit boundary and
    // past it), exercised at every fragment size.
    const boundary_lengths = [_]usize{ 0, 1, 2, 124, 125, 126, 127, 254, 255, 256, 65534, 65535, 65536, 65537, 131072 };

    var payload_buf: [200_000]u8 = undefined;
    var sent: std.ArrayList([]u8) = .empty;
    defer sent.deinit(gpa);

    for (fragment_sizes) |frag_size| {
        sent.clearRetainingCapacity();
        var relay = try WriteRecorderRelay.init(relay_io, gpa);
        errdefer relay.deinit();
        const relay_thread = try std.Thread.spawn(.{}, serveWriteRecorder, .{ &relay, gpa });
        // pthread_join must run exactly once: the flag keeps the error path
        // from double-joining after the explicit join below.
        var joined = false;
        errdefer if (!joined) relay_thread.join();

        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{relay.port});
        {
            var client = try ws.Client.connect(client_io, gpa, url, .{
                .handshake_timeout_ms = 5_000,
                .read_timeout_ms = 5_000,
                .max_fragment_bytes = frag_size,
                .max_frame_payload = 256 * 1024,
                .max_message_bytes = 256 * 1024,
            });
            defer client.deinit();

            var iteration: usize = 0;
            while (iteration < 16) : (iteration += 1) {
                // Exact boundary lengths first, then random lengths, so both
                // the length-encoding edges and the general case are fuzzed
                // at every fragment size.
                const plen = if (iteration < boundary_lengths.len)
                    boundary_lengths[iteration]
                else
                    rand.intRangeAtMost(usize, 0, payload_buf.len);
                rand.bytes(payload_buf[0..plen]);
                try client.sendText(payload_buf[0..plen]);
                const copy = try gpa.dupe(u8, payload_buf[0..plen]);
                try sent.append(gpa, copy);
            }
        } // client.deinit() sends Close; the relay reads it and exits

        // Join before verifying: only a quiesced relay has a complete record.
        relay_thread.join();
        joined = true;
        try verifyRecordedMessages(&relay, sent.items, frag_size);
        for (sent.items) |item| gpa.free(item);
        relay.deinit();
    }
}

// =============================================================================
// Write deadline: a relay that completes the handshake and then stops
// reading. A payload larger than the loopback socket buffers blocks the
// client's flush, so the per-write deadline must interrupt it mid-flush
// instead of hanging until the run's outer budget.
// =============================================================================

const StalledRelay = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,

    fn init(io: Io) !StalledRelay {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = address.listen(io, .{
            .kernel_backlog = 1,
            .reuse_address = false,
        }) catch return error.BindFailed;
        errdefer server.deinit(io);
        const port = server.socket.address.getPort();
        if (port == 0) return error.BindFailed;
        return .{ .io = io, .server = server, .port = port };
    }

    fn deinit(self: *StalledRelay) void {
        self.server.deinit(self.io);
        self.* = undefined;
    }
};

fn serveStalledRelay(relay: *StalledRelay) void {
    serveStalledRelayInner(relay) catch {};
}

fn serveStalledRelayInner(relay: *StalledRelay) !void {
    const stream = try relay.server.accept(relay.io);
    defer stream.close(relay.io);
    const fd: std.c.fd_t = @intCast(stream.socket.handle);
    var read_buf: [16384]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    _ = try performHandshakeFd(fd, &read_buf, &write_buf, .ok);
    // Leave the connection open and unread: long enough that the client's
    // write deadline (hundreds of ms) fires well inside this window, short
    // enough that the test's join does not drag.
    sleepMs(relay.io, 1_500);
}

test "write side: the write deadline fires mid-flush when the relay stops reading" {
    var relay_threaded = Io.Threaded.init(testing.allocator, .{ .environ = std.process.Environ.empty });
    defer relay_threaded.deinit();
    const relay_io = relay_threaded.io();

    var relay = try StalledRelay.init(relay_io);
    defer relay.deinit();
    const relay_thread = try std.Thread.spawn(.{}, serveStalledRelay, .{&relay});
    defer relay_thread.join();

    var client_threaded = Io.Threaded.init(testing.allocator, .{ .environ = std.process.Environ.empty });
    defer client_threaded.deinit();
    const client_io = client_threaded.io();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{relay.port});
    var client = try ws.Client.connect(client_io, testing.allocator, url, .{
        .handshake_timeout_ms = 2_000,
        .read_timeout_ms = 400, // also the per-write deadline (sendAllAndFlush)
        .max_fragment_bytes = 16 * 1024 * 1024,
        .max_frame_payload = 16 * 1024 * 1024,
        .max_message_bytes = 16 * 1024 * 1024,
    });
    defer client.deinit();

    // Larger than any plausible autotuned loopback socket buffer, so the
    // send blocks after the buffers fill and only the deadline can unblock
    // it.
    const big = try testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 0x5A);

    const started = Io.Timestamp.now(testing.io, .real).toMilliseconds();
    try testing.expectError(error.WriteTimeout, client.sendText(big));
    const elapsed = Io.Timestamp.now(testing.io, .real).toMilliseconds() - started;
    // The deadline must fire promptly (well inside the relay's 1.5 s stall),
    // not hang until the socket drains or the relay closes.
    try testing.expect(elapsed < 1_200);
}
