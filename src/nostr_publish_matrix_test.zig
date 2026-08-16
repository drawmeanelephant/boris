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

const Io = std.Io;
const posix = std.posix;
const testing = std.testing;

const rfc_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Relay URL format used by the plain loopback scenarios; the TLS scenarios
/// use `wss://localhost:{d}` against the pinned test CA instead. The quotes
/// are part of the JSON artifact (the plan embeds the URL as a string).
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
    var frame_buf: [1024]u8 = undefined;
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
    var relay_threaded = Io.Threaded.init(testing.allocator, .{ .environ = std.process.Environ.empty });
    defer relay_threaded.deinit();
    const relay_io = relay_threaded.io();

    var client_threaded = Io.Threaded.init(testing.allocator, .{ .environ = std.process.Environ.empty });
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
    defer sent.deinit(testing.allocator);

    for (fragment_sizes) |frag_size| {
        sent.clearRetainingCapacity();
        var relay = try WriteRecorderRelay.init(relay_io, testing.allocator);
        errdefer relay.deinit();
        const relay_thread = try std.Thread.spawn(.{}, serveWriteRecorder, .{ &relay, testing.allocator });
        // pthread_join must run exactly once: the flag keeps the error path
        // from double-joining after the explicit join below.
        var joined = false;
        errdefer if (!joined) relay_thread.join();

        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{relay.port});
        {
            var client = try ws.Client.connect(client_io, testing.allocator, url, .{
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
                const copy = try testing.allocator.dupe(u8, payload_buf[0..plen]);
                try sent.append(testing.allocator, copy);
            }
        } // client.deinit() sends Close; the relay reads it and exits

        // Join before verifying: only a quiesced relay has a complete record.
        relay_thread.join();
        joined = true;
        try verifyRecordedMessages(&relay, sent.items, frag_size);
        for (sent.items) |item| testing.allocator.free(item);
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
