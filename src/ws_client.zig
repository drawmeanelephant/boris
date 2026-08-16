//! Minimal RFC-6455 WebSocket client owned by Boris (#494, settled decision).
//!
//! The publish protocol is genuinely narrow — one EVENT frame in, `OK` /
//! `NOTICE` frames out, bounded time — and this module owns exactly the
//! client surface that decision requires and nothing else:
//!
//! - opening-handshake validation (`101`, `Upgrade`, `Connection`,
//!   `Sec-WebSocket-Accept` computed over the key + RFC GUID);
//! - mandatory client masking, including control frames;
//! - bounded fragmented-message reassembly (servers are free to fragment
//!   `OK`);
//! - control frames: `Ping` → `Pong` while waiting, `Close` handshake and
//!   protocol-error handling;
//! - frame/message size ceilings and a per-read deadline budget;
//! - TLS via `std.crypto.tls.Client` with explicit hostname verification and
//!   a real CA bundle (`Certificate.Bundle` system roots).
//!
//! It is deliberately **not** a general-purpose WebSocket stack. #494 is
//! normative here: *dependency minimization alone is not justification for
//! owning a protocol; if the publish slice ever requires materially broader
//! WebSocket functionality than this contract, reopen the dependency
//! decision instead of growing WebSocket.zig inside Boris.*
//!
//! Everything the server sends is untrusted input: lengths are clamped to
//! declared ceilings before any allocation, a masked server frame is a
//! protocol error (RFC 6455 §5.1: server frames MUST NOT be masked), control
//! frames with payloads over 125 bytes are a protocol error, and a malformed
//! frame fails closed.

const std = @import("std");
const Io = std.Io;

pub const TlsOptions = struct {
    /// PEM text of an extra CA certificate (e.g. a self-signed test CA)
    /// trusted *in addition to* the system root bundle. Null trusts only
    /// the system roots. The bytes are borrowed: the caller must keep the
    /// buffer alive for the lifetime of the connection. Used by the
    /// conformance matrix to pin a local TLS mock relay's CA.
    extra_ca_pem: ?[]const u8 = null,
    /// Hostname verified against the server certificate (and sent as SNI),
    /// overriding the URL host. The conformance matrix connects to
    /// `wss://127.0.0.1:<port>` (deterministic loopback resolution) while
    /// verifying a certificate issued for `localhost`.
    verify_host: ?[]const u8 = null,
};

pub const Limits = struct {
    /// Reassembled text-message ceiling in bytes (outgoing and incoming).
    max_message_bytes: usize = 1 * 1024 * 1024,
    /// Single frame payload ceiling in bytes (also bounds control payloads).
    max_frame_payload: usize = 1 * 1024 * 1024,
    /// Outgoing text messages larger than this are fragmented on the wire
    /// (an initial text frame with FIN clear, then continuation frames, the
    /// last with FIN set). RFC 6455 requires every server to accept
    /// fragmented messages, so this only affects frame size on the wire, not
    /// what a conforming relay may deliver. Control frames are never
    /// fragmented regardless of this value.
    max_fragment_bytes: usize = 64 * 1024,
    /// Whole handshake (TCP connect + TLS + HTTP upgrade) deadline, ms.
    handshake_timeout_ms: u32 = 10_000,
    /// Per-read and per-write deadline, ms. Each read is individually
    /// bounded; the publish loop additionally budgets the whole relay
    /// interaction so a sequence of reads is never unbounded overall.
    read_timeout_ms: u32 = 10_000,
    /// TLS client configuration for `wss://` connections.
    tls: TlsOptions = .{},
};

pub const Error = error{
    InvalidUrl,
    ResolveFailed,
    ConnectFailed,
    TlsFailed,
    /// The handshake did not complete within the handshake deadline.
    HandshakeTimeout,
    /// The HTTP status was not 101.
    BadStatus,
    /// The response omitted `Upgrade: websocket` or `Connection: Upgrade`.
    BadUpgrade,
    /// `Sec-WebSocket-Accept` did not match the computed value.
    BadAccept,
    /// The response headers exceeded the header ceiling or were malformed.
    BadHandshake,
    /// `ws://` was used for a non-loopback target (the relay contract).
    InsecureWsRefused,
    /// A read did not complete within the read deadline.
    ReadTimeout,
    /// The underlying socket read failed.
    ReadFailed,
    /// A write did not complete within the write deadline.
    WriteTimeout,
    /// The underlying socket write failed.
    WriteFailed,
    /// A frame violated RFC 6455 (masked server frame, bad opcode, oversized
    /// control frame, fragmented control frame, payload over ceiling).
    ProtocolError,
    /// A message exceeded `max_message_bytes` during reassembly.
    OversizedMessage,
    /// The peer closed the connection (Close frame received).
    Closed,
    /// The peer closed the TCP connection without a Close frame.
    EndOfStream,
} || std.mem.Allocator.Error;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

/// A parsed relay endpoint. `host`/`path` are views into the input URL, so
/// the caller must keep the URL alive for the lifetime of the target.
pub const Target = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    path: []const u8,

    pub const default_secure_port: u16 = 443;
    pub const default_plain_port: u16 = 80;

    pub fn parse(raw: []const u8) Error!Target {
        const secure_prefix = "wss://";
        const plain_prefix = "ws://";
        const secure = std.ascii.startsWithIgnoreCase(raw, secure_prefix);
        const plain = !secure and std.ascii.startsWithIgnoreCase(raw, plain_prefix);
        if (!secure and !plain) return error.InvalidUrl;
        const rest = raw[(if (secure) secure_prefix.len else plain_prefix.len)..];
        if (rest.len == 0) return error.InvalidUrl;
        if (std.mem.indexOfScalar(u8, rest, '@') != null) return error.InvalidUrl;
        if (std.mem.indexOfScalar(u8, rest, '?') != null) return error.InvalidUrl;
        if (std.mem.indexOfScalar(u8, rest, '#') != null) return error.InvalidUrl;

        const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..path_start];
        var path = rest[path_start..];
        if (authority.len == 0) return error.InvalidUrl;
        if (path.len == 0) path = "/";

        var host = authority;
        var port: u16 = if (secure) Target.default_secure_port else Target.default_plain_port;
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            const in_ipv6 = authority[0] == '[' and colon < (std.mem.indexOfScalar(u8, authority, ']') orelse 0);
            if (!in_ipv6) {
                host = authority[0..colon];
                const digits = authority[colon + 1 ..];
                if (digits.len == 0 or digits.len > 5) return error.InvalidUrl;
                var value: u32 = 0;
                for (digits) |c| {
                    if (c < '0' or c > '9') return error.InvalidUrl;
                    value = value * 10 + (c - '0');
                }
                if (value == 0 or value > std.math.maxInt(u16)) return error.InvalidUrl;
                port = @intCast(value);
            }
        }
        if (host.len == 0) return error.InvalidUrl;
        for (host) |c| {
            const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '[' or c == ']' or c == ':';
            if (!ok) return error.InvalidUrl;
        }
        return .{ .secure = secure, .host = host, .port = port, .path = path };
    }
};

pub const Message = union(enum) {
    /// One complete text message (possibly reassembled from fragments).
    /// Owned by the client; invalidated by the next call.
    text: []const u8,
    /// The peer sent a Close frame. `code` is the wire close code.
    close: struct { code: u16, reason: []const u8 },
};

const rfc_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Parse every PEM certificate block in `pem` into `bundle`. std 0.16 only
/// loads bundles from the system or a file path, so this mirrors
/// `Certificate.Bundle.addCertsFromFile` for an in-memory buffer: base64-
/// decode each `BEGIN CERTIFICATE` block into `bundle.bytes` and index it
/// with `parseCert`, exactly the representation `Bundle.verify` expects.
fn addPemToBundle(
    gpa: std.mem.Allocator,
    bundle: *std.crypto.Certificate.Bundle,
    pem: []const u8,
    now_sec: i64,
) (std.mem.Allocator.Error || std.base64.Error || std.crypto.Certificate.Bundle.ParseCertError || error{ MissingEndCertificateMarker, NoCertificates, CertificateAuthorityBundleTooBig })!void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    var rest = pem;
    var found: usize = 0;
    while (std.mem.indexOf(u8, rest, begin_marker)) |begin_start| {
        const cert_start = begin_start + begin_marker.len;
        const relative_end = std.mem.indexOf(u8, rest[cert_start..], end_marker) orelse
            return error.MissingEndCertificateMarker;
        const cert_end = cert_start + relative_end;
        const encoded = std.mem.trim(u8, rest[cert_start..cert_end], " \t\r\n");
        rest = rest[cert_end + end_marker.len ..];

        const decoded_start = std.math.cast(u32, bundle.bytes.items.len) orelse
            return error.CertificateAuthorityBundleTooBig;
        // PEM wraps base64 at 64 columns; `trim` only removes leading/trailing
        // whitespace, so strip every whitespace byte before decoding.
        var clean: [16 * 1024]u8 = undefined;
        var clean_len: usize = 0;
        for (encoded) |c| {
            switch (c) {
                ' ', '\t', '\r', '\n' => {},
                else => {
                    if (clean_len == clean.len) return error.CertificateAuthorityBundleTooBig;
                    clean[clean_len] = c;
                    clean_len += 1;
                },
            }
        }
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(clean[0..clean_len]);
        try bundle.bytes.ensureUnusedCapacity(gpa, decoded_len);
        const dest = bundle.bytes.allocatedSlice()[decoded_start .. decoded_start + decoded_len];
        try std.base64.standard.Decoder.decode(dest, clean[0..clean_len]);
        bundle.bytes.items.len = decoded_start + decoded_len;
        try bundle.parseCert(gpa, decoded_start, now_sec);
        found += 1;
    }
    if (found == 0) return error.NoCertificates;
}

fn isLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "[::1]");
}

// ---------------------------------------------------------------------------
// Deadline-raced blocking operations (std.Io.Select + cancellation)
// ---------------------------------------------------------------------------

fn deadlineSleep(io: Io, timeout_ms: u32) Io.Cancelable!void {
    try (Io.Timeout{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    } }).sleep(io);
}

/// Run `target(args)` on a Select, racing a `timeout_ms` timer. Returns
/// `error.Timeout` if the timer wins; otherwise returns the target's result.
/// The loser is cancelled and drained before returning, so no task leaks.
fn RacePayload(comptime ReturnT: type) type {
    const info = @typeInfo(ReturnT);
    return if (info == .error_union) info.error_union.payload else ReturnT;
}

/// The error set of one deadline-bounded transport op: the op's own errors
/// plus `Timeout` for the deadline firing first.
fn RaceErrors(comptime ReturnT: type) type {
    const info = @typeInfo(ReturnT);
    if (info == .error_union) return info.error_union.error_set || error{Timeout};
    return error{Timeout};
}

/// Run `target` under a single deadline budget. If the deadline fires first,
/// the pending operation is cancelled and `error.Timeout` is returned; op
/// errors propagate unchanged.
fn raceDeadline(io: Io, timeout_ms: u32, comptime target: anytype, args: anytype) RaceErrors(@typeInfo(@TypeOf(target)).@"fn".return_type.?)!RacePayload(@typeInfo(@TypeOf(target)).@"fn".return_type.?) {
    const FnInfo = @typeInfo(@TypeOf(target)).@"fn";
    const ReturnT = FnInfo.return_type.?;
    const U = union(enum) { op: ReturnT, timer: Io.Cancelable!void };
    var slots: [2]U = undefined;
    var select: Io.Select(U) = .init(io, &slots);
    select.async(.op, target, args);
    select.async(.timer, deadlineSleep, .{ io, timeout_ms });
    const result = select.await() catch return error.Timeout;
    var op_result: ?ReturnT = null;
    switch (result) {
        .op => |r| op_result = r,
        .timer => {},
    }
    while (select.cancel()) |_| {}
    if (op_result == null) return error.Timeout;
    return op_result.? catch |err| return err;
}

fn connectStream(io: Io, address: Io.net.IpAddress) Io.net.IpAddress.ConnectError!Io.net.Stream {
    return address.connect(io, .{ .mode = .stream, .protocol = .tcp });
}

fn readSliceShortFn(self: *Client, buffer: []u8) Io.Reader.ShortError!usize {
    return self.reader().readSliceShort(buffer);
}

/// One underlying read that returns whatever is currently available (bounded
/// by `buffer.len`), rather than blocking until the buffer is full. The
/// handshake needs this: the peer answers with a short HTTP response, and
/// `readSliceShort` would block trying to fill the whole request buffer.
fn readVecFn(reader: *Io.Reader, buffer: []u8) Io.Reader.Error!usize {
    var data: [1][]u8 = .{buffer};
    return reader.readVec(&data);
}

/// The `Io.Writer` interface buffers short writes; every outgoing frame must
/// be flushed to the socket or the peer never sees it.
fn writeAllAndFlushFn(writer: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    try writer.writeAll(bytes);
    try writer.flush();
}

fn flushFn(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.flush();
}

/// Write `bytes` through the plaintext layer and flush it all the way to
/// the socket. For `wss://`, the TLS writer's `flush` only encrypts the
/// records into the underlying socket writer's buffer (std 0.16 never
/// drains it), so the socket writer must be drained explicitly.
fn sendAllAndFlush(self: *Client, bytes: []const u8) Error!void {
    raceDeadline(self.io, self.limits.read_timeout_ms, writeAllAndFlushFn, .{ self.writer(), bytes }) catch |err| switch (err) {
        error.Timeout, error.WriteFailed => return error.WriteTimeout,
    };
    if (self.box.tls != null) {
        raceDeadline(self.io, self.limits.read_timeout_ms, flushFn, .{&self.box.socket_writer.interface}) catch |err| switch (err) {
            error.Timeout, error.WriteFailed => return error.WriteTimeout,
        };
    }
}

// ---------------------------------------------------------------------------
// Frame encoding (client → server) and decoding (server → client)
// ---------------------------------------------------------------------------

/// Append one client frame: FIN + opcode + mask bit + masked payload.
/// Returns the frame length (header + payload). Bounded by `max_frame_payload`.
/// Encode one RFC-6455 frame. `masked` selects client mode (mask bit set,
/// payload XORed with `mask`); server frames pass `masked = false`. Production
/// client frames always mask; the unmasked form exists so the mock relay in the
/// conformance matrix can encode server frames with the same helper.
pub fn encodeFrame(
    buf: []u8,
    opcode: Opcode,
    payload: []const u8,
    mask: [4]u8,
    fin: bool,
    masked: bool,
) Error!usize {
    const header_len = frameHeaderLen(payload.len);
    const total = header_len + payload.len;
    if (total > buf.len) return error.ProtocolError;

    var i: usize = 0;
    buf[i] = (@as(u8, if (fin) 0x80 else 0x00)) | @as(u8, @intFromEnum(opcode));
    i += 1;
    if (payload.len < 126) {
        buf[i] = @as(u8, @intCast(payload.len));
        i += 1;
    } else if (payload.len <= std.math.maxInt(u16)) {
        buf[i] = 126;
        i += 1;
        buf[i] = @as(u8, @intCast((payload.len >> 8) & 0xFF));
        buf[i + 1] = @as(u8, @intCast(payload.len & 0xFF));
        i += 2;
    } else {
        buf[i] = 127;
        i += 1;
        const len64: u64 = payload.len;
        var shift: u6 = 56;
        while (true) : (shift -%= 8) {
            buf[i] = @as(u8, @intCast((len64 >> shift) & 0xFF));
            i += 1;
            if (shift == 0) break;
        }
    }
    if (masked) {
        buf[1] |= 0x80;
        @memcpy(buf[i..][0..4], &mask);
        i += 4;
        for (payload, 0..) |byte, j| {
            buf[i + j] = byte ^ mask[j % 4];
        }
    } else {
        @memcpy(buf[i..][0..payload.len], payload);
    }
    i += payload.len;
    return i;
}

fn frameHeaderLen(payload_len: usize) usize {
    if (payload_len < 126) return 2;
    if (payload_len <= std.math.maxInt(u16)) return 4;
    return 10;
}

const Frame = struct {
    fin: bool,
    opcode: Opcode,
    /// Payload view into the caller's read buffer (not owned by the frame).
    payload: []const u8,
};

/// Parse one server frame header + payload out of `bytes` (which must hold
/// the full frame). Server frames MUST NOT be masked (RFC 6455 §5.1).
fn parseFrame(bytes: []const u8, max_payload: usize) Error!Frame {
    if (bytes.len < 2) return error.ProtocolError;
    const fin = (bytes[0] & 0x80) != 0;
    const opcode_raw = bytes[0] & 0x0F;
    const masked = (bytes[1] & 0x80) != 0;
    if (masked) return error.ProtocolError;
    const opcode: Opcode = switch (opcode_raw) {
        0x0 => .continuation,
        0x1 => .text,
        0x2 => .binary,
        0x8 => .close,
        0x9 => .ping,
        0xA => .pong,
        else => return error.ProtocolError,
    };

    var offset: usize = 2;
    var len64: u64 = bytes[1] & 0x7F;
    if (len64 == 126) {
        if (bytes.len < offset + 2) return error.ProtocolError;
        len64 = (@as(u64, bytes[offset]) << 8) | bytes[offset + 1];
        offset += 2;
    } else if (len64 == 127) {
        if (bytes.len < offset + 8) return error.ProtocolError;
        len64 = 0;
        for (bytes[offset..][0..8]) |b| len64 = (len64 << 8) | b;
        offset += 8;
        if (len64 > std.math.maxInt(u64) / 2) return error.ProtocolError;
    }
    if (len64 > max_payload) return error.ProtocolError;

    // Control frames: FIN required and payload ≤ 125 (RFC 6455 §5.5).
    const is_control = switch (opcode) {
        .close, .ping, .pong => true,
        else => false,
    };
    if (is_control) {
        if (!fin) return error.ProtocolError;
        if (len64 > 125) return error.ProtocolError;
    }

    if (bytes.len < offset + len64) return error.ProtocolError;
    return .{
        .fin = fin,
        .opcode = opcode,
        .payload = bytes[offset .. offset + len64],
    };
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// The socket reader/writer and the optional TLS client live in one heap
/// box that never moves. `std.crypto.tls.Client` stores `*Reader`/`*Writer`
/// pointers to the socket interfaces *inside itself* (its `input`/`output`
/// fields), so the trio must stay at a stable address: `connect` returns the
/// `Client` by value, and any self-pointer inside it would dangle the moment
/// the frame returns. The box is the only self-referential part; the
/// `Client` value itself holds just the box pointer and plain data.
const TlsBox = struct {
    socket_reader: Io.net.Stream.Reader,
    socket_writer: Io.net.Stream.Writer,
    /// Set for `wss://`. Its `input`/`output` point at `socket_reader`/
    /// `socket_writer` above; that is why this box must never move.
    tls: ?std.crypto.tls.Client = null,
};

pub const Client = struct {
    io: Io,
    gpa: std.mem.Allocator,
    limits: Limits,
    stream: Io.net.Stream,
    /// Socket + TLS state (see `TlsBox`); owned and freed in `deinit`.
    box: *TlsBox,
    // gpa-owned buffers (freed in deinit).
    socket_read_buf: []u8,
    socket_write_buf: []u8,
    tls_read_buf: []u8,
    tls_write_buf: []u8,
    /// Incoming-frame scratch. Frames larger than this are `OversizedMessage`
    /// even if `max_frame_payload` is higher: a relay `OK`/`NOTICE` never
    /// needs more, and a 1 MiB stack buffer is not worth it.
    read_buf: [16384]u8 = undefined,
    /// Owned by the client; returned from `readMessage` as `.text`.
    message_buf: std.ArrayList(u8) = .empty,
    closed: bool = false,

    pub fn connect(io: Io, gpa: std.mem.Allocator, url: []const u8, limits: Limits) Error!Client {
        const target = try Target.parse(url);
        if (!target.secure and !isLoopbackHost(target.host)) return error.InsecureWsRefused;

        // The relay contract guarantees normalized URLs, but the client still
        // parses them so a future caller cannot smuggle an odd target through.
        const address: Io.net.IpAddress = Io.net.IpAddress.resolve(io, target.host, target.port) catch return error.ResolveFailed;
        const stream = raceDeadline(io, limits.handshake_timeout_ms, connectStream, .{ io, address }) catch |err| switch (err) {
            error.Timeout => return error.HandshakeTimeout,
            else => return error.ConnectFailed,
        };
        // The stream is closed by `deinit` once the Client owns it; until then a
        // failure path closes it here. The flag is cleared once ownership moves.
        var close_on_error = true;
        defer if (close_on_error) stream.close(io);

        // Each alloc's failure frees what came before; from here on, every
        // later failure is owned by `self.deinit()` alone (no per-buffer
        // errdefers, or they would double-free after deinit runs).
        // The TLS layer writes ciphertext directly into the underlying
        // writer's buffer via `writableSliceGreedy(min_buffer_len)`, so the
        // socket buffers must be at least as large as a ciphertext record
        // even for plain `ws://` connections (they are harmless there).
        const socket_read_buf = gpa.alloc(u8, std.crypto.tls.Client.min_buffer_len) catch return error.OutOfMemory;
        const socket_write_buf = gpa.alloc(u8, std.crypto.tls.Client.min_buffer_len) catch {
            gpa.free(socket_read_buf);
            return error.OutOfMemory;
        };
        const tls_read_buf = gpa.alloc(u8, std.crypto.tls.Client.min_buffer_len) catch {
            gpa.free(socket_read_buf);
            gpa.free(socket_write_buf);
            return error.OutOfMemory;
        };
        const tls_write_buf = gpa.alloc(u8, std.crypto.tls.Client.min_buffer_len) catch {
            gpa.free(socket_read_buf);
            gpa.free(socket_write_buf);
            gpa.free(tls_read_buf);
            return error.OutOfMemory;
        };

        const box = gpa.create(TlsBox) catch {
            gpa.free(socket_read_buf);
            gpa.free(socket_write_buf);
            gpa.free(tls_read_buf);
            gpa.free(tls_write_buf);
            return error.OutOfMemory;
        };
        box.* = .{
            .socket_reader = stream.reader(io, socket_read_buf),
            .socket_writer = stream.writer(io, socket_write_buf),
        };

        var self = Client{
            .io = io,
            .gpa = gpa,
            .limits = limits,
            .stream = stream,
            .box = box,
            .socket_read_buf = socket_read_buf,
            .socket_write_buf = socket_write_buf,
            .tls_read_buf = tls_read_buf,
            .tls_write_buf = tls_write_buf,
        };
        // From here the Client owns the stream, the box, and every buffer;
        // any failure (including a TLS init failure) unwinds through deinit
        // alone, so the per-allocation frees above are the only ones needed
        // before this point and there is no double-free or leak.
        close_on_error = false;
        errdefer self.deinit();

        if (target.secure) {
            var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            var ca_bundle = std.crypto.Certificate.Bundle.empty;
            defer ca_bundle.deinit(gpa);
            const now = Io.Timestamp.now(io, .real);
            if (self.limits.tls.extra_ca_pem) |pem| {
                // A pinned CA is authoritative even when the system bundle
                // cannot be rescanned (e.g. a container with no roots).
                ca_bundle.rescan(gpa, io, now) catch {};
                addPemToBundle(gpa, &ca_bundle, pem, now.toSeconds()) catch return error.TlsFailed;
            } else {
                ca_bundle.rescan(gpa, io, now) catch return error.TlsFailed;
            }
            var lock: Io.RwLock = .init;
            const tls = std.crypto.tls.Client.init(
                &self.box.socket_reader.interface,
                &self.box.socket_writer.interface,
                .{
                    .host = .{ .explicit = self.limits.tls.verify_host orelse target.host },
                    .ca = .{ .bundle = .{
                        .gpa = gpa,
                        .io = io,
                        .lock = &lock,
                        .bundle = &ca_bundle,
                    } },
                    .read_buffer = self.tls_read_buf,
                    .write_buffer = self.tls_write_buf,
                    .entropy = &entropy,
                    .realtime_now = Io.Timestamp.now(io, .real),
                },
            ) catch return error.TlsFailed;
            // `tls.input`/`tls.output` point at `box.socket_reader`/
            // `box.socket_writer`; the box stays put for the Client's life.
            self.box.tls = tls;
        }

        try self.upgrade(target);
        return self;
    }

    /// The plaintext reader interface, addressed in place. The interface must
    /// never be copied: its vtable resolves the concrete reader via
    /// `@fieldParentPtr`, so `&box.socket_reader.interface` (or the TLS
    /// reader field) is the only valid address.
    fn reader(self: *Client) *Io.Reader {
        return if (self.box.tls) |*tls| &tls.reader else &self.box.socket_reader.interface;
    }

    /// The plaintext writer interface, addressed in place (see `reader`).
    fn writer(self: *Client) *Io.Writer {
        return if (self.box.tls) |*tls| &tls.writer else &self.box.socket_writer.interface;
    }

    /// Release everything: a best-effort Close frame, the gpa-owned buffers,
    /// and the TCP connection. Idempotent; safe to call once from `defer`.
    pub fn deinit(self: *Client) void {
        if (!self.closed) {
            self.closed = true;
            var buf: [8]u8 = undefined;
            if (encodeFrame(&buf, .close, &.{}, [_]u8{ 0, 0, 0, 0 }, true, true) catch null) |len| {
                sendAllAndFlush(self, buf[0..len]) catch {};
            }
        }
        self.message_buf.deinit(self.gpa);
        self.gpa.free(self.socket_read_buf);
        self.gpa.free(self.socket_write_buf);
        self.gpa.free(self.tls_read_buf);
        self.gpa.free(self.tls_write_buf);
        self.gpa.destroy(self.box);
        self.stream.close(self.io);
    }

    fn upgrade(self: *Client, target: Target) Error!void {
        var key_bytes: [16]u8 = undefined;
        self.io.random(&key_bytes);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

        var request_buf: std.ArrayList(u8) = .empty;
        defer request_buf.deinit(self.gpa);
        try request_buf.appendSlice(self.gpa, "GET ");
        try request_buf.appendSlice(self.gpa, target.path);
        try request_buf.appendSlice(self.gpa, " HTTP/1.1\r\nHost: ");
        try request_buf.appendSlice(self.gpa, target.host);
        try request_buf.appendSlice(self.gpa, "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ");
        try request_buf.appendSlice(self.gpa, key);
        try request_buf.appendSlice(self.gpa, "\r\nSec-WebSocket-Version: 13\r\n\r\n");

        raceDeadline(self.io, self.limits.handshake_timeout_ms, writeAllAndFlushFn, .{ self.writer(), request_buf.items }) catch |err| switch (err) {
            error.Timeout => return error.HandshakeTimeout,
            else => return error.BadHandshake,
        };
        if (self.box.tls != null) {
            // Drain the TLS records out of the socket writer (see
            // `sendAllAndFlush`); a stalled upgrade is a handshake timeout.
            raceDeadline(self.io, self.limits.handshake_timeout_ms, flushFn, .{&self.box.socket_writer.interface}) catch |err| switch (err) {
                error.Timeout => return error.HandshakeTimeout,
                else => return error.BadHandshake,
            };
        }

        // Read response headers, bounded, then validate the upgrade. Each
        // iteration takes whatever bytes are available (readVec, not
        // readSliceShort — the latter would block until the whole 16 KiB
        // request buffer is full). The read is raced so a relay that accepts
        // the TCP connection but never answers the HTTP upgrade cannot hold
        // the client open.
        var header_buf: [16 * 1024]u8 = undefined;
        var header_len: usize = 0;
        while (std.mem.indexOf(u8, header_buf[0..header_len], "\r\n\r\n") == null) {
            if (header_len == header_buf.len) return error.BadHandshake;
            var got = raceDeadline(self.io, self.limits.handshake_timeout_ms, readVecFn, .{ self.reader(), header_buf[header_len..] }) catch |err| switch (err) {
                error.Timeout => return error.HandshakeTimeout,
                else => return error.BadHandshake,
            };
            if (got == 0 and self.box.tls != null) {
                // The TLS reader decrypts a record into its own buffer and
                // returns 0; the cleartext is only delivered on the next
                // call. Drain exactly the pending bytes so the call's copy
                // fills the buffer and the reader does not eagerly decrypt
                // the *next* record (which would block until the relay sends
                // data it has no reason to send).
                const pending = self.box.tls.?.reader.bufferedLen();
                if (pending == 0) return error.BadHandshake;
                const drain_len = @min(pending, header_buf.len - header_len);
                got = raceDeadline(self.io, self.limits.handshake_timeout_ms, readVecFn, .{ self.reader(), header_buf[header_len..][0..drain_len] }) catch |err| switch (err) {
                    error.Timeout => return error.HandshakeTimeout,
                    else => return error.BadHandshake,
                };
            }
            if (got == 0) return error.BadHandshake;
            header_len += got;
        }
        const headers = header_buf[0..header_len];
        try self.validateHandshake(headers, &key_buf, key.len);
    }

    fn validateHandshake(self: *Client, headers: []const u8, key_buf: *[24]u8, key_len: usize) Error!void {
        _ = self;
        const head_end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.BadHandshake;
        const status_line = headers[0..head_end];
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101") and
            !std.mem.startsWith(u8, status_line, "HTTP/1.0 101"))
        {
            return error.BadStatus;
        }

        var upgrade_ok = false;
        var connection_ok = false;
        var accept: ?[]const u8 = null;

        var rest = headers[head_end + 2 ..];
        while (std.mem.indexOf(u8, rest, "\r\n")) |line_end| {
            const line = rest[0..line_end];
            rest = rest[line_end + 2 ..];
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                if (std.ascii.eqlIgnoreCase(value, "websocket")) upgrade_ok = true;
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                var tokens = std.mem.tokenizeAny(u8, value, ", \t");
                while (tokens.next()) |token| {
                    if (std.ascii.eqlIgnoreCase(token, "upgrade")) connection_ok = true;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                accept = value;
            }
        }
        if (!upgrade_ok or !connection_ok) return error.BadUpgrade;
        if (accept == null) return error.BadAccept;

        var digest: [20]u8 = undefined;
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key_buf[0..key_len]);
        sha1.update(rfc_guid);
        sha1.final(&digest);

        var expect_buf: [32]u8 = undefined;
        const expect = std.base64.standard.Encoder.encode(&expect_buf, &digest);
        if (!std.mem.eql(u8, accept.?, expect)) return error.BadAccept;
    }

    /// Send one masked text message. Payloads larger than
    /// `limits.max_fragment_bytes` are fragmented on the wire: an initial
    /// text frame with FIN clear, then continuation frames, the last with
    /// FIN set. Fragmenting is mandatory client behavior a conforming server
    /// must accept; the frame ceiling (`max_frame_payload`) bounds each
    /// fragment and `max_message_bytes` bounds the whole message.
    pub fn sendText(self: *Client, payload: []const u8) Error!void {
        if (self.closed) return error.Closed;
        if (payload.len > self.limits.max_message_bytes) return error.ProtocolError;
        // Guard against a zero fragment limit (would loop forever) and never
        // exceed the single-frame ceiling even if the limits disagree.
        const fragment_size = @max(@as(usize, 1), @min(self.limits.max_fragment_bytes, self.limits.max_frame_payload));
        if (payload.len <= fragment_size) {
            try self.sendFrames(.text, payload, true);
            return;
        }
        var offset: usize = 0;
        var first = true;
        while (true) {
            const end = @min(offset + fragment_size, payload.len);
            const chunk = payload[offset..end];
            const last = end == payload.len;
            try self.sendFrames(if (first) .text else .continuation, chunk, last);
            if (last) break;
            offset = end;
            first = false;
        }
    }

    /// Encode and send one masked data frame with a fresh random mask. `fin`
    /// marks the final frame of a message; the text/continuation callers
    /// clear it for all but the last fragment.
    fn sendFrames(self: *Client, opcode: Opcode, payload: []const u8, fin: bool) Error!void {
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.gpa);
        frame.ensureTotalCapacity(self.gpa, frameHeaderLen(payload.len) + payload.len) catch return error.OutOfMemory;
        const len = encodeFrame(frame.unusedCapacitySlice(), opcode, payload, mask, fin, true) catch return error.ProtocolError;
        frame.items.len += len;
        try sendAllAndFlush(self, frame.items);
    }

    /// Read the next complete message: a text message (possibly reassembled
    /// from fragments), or a Close. `Ping` frames are answered with `Pong`
    /// transparently; `Pong` frames are ignored. Binary frames are a
    /// protocol error (Nostr relays carry JSON text only).
    pub fn readMessage(self: *Client) Error!Message {
        self.message_buf.clearRetainingCapacity();
        var expecting_continuation = false;
        while (true) {
            const frame = self.readFrame() catch |err| switch (err) {
                error.EndOfStream => {
                    if (self.closed) return error.Closed;
                    return error.EndOfStream;
                },
                else => return err,
            };
            switch (frame.opcode) {
                .ping => {
                    try self.sendControl(.pong, frame.payload);
                    continue;
                },
                .pong => continue,
                .close => {
                    self.closed = true;
                    const code: u16 = if (frame.payload.len >= 2)
                        (@as(u16, frame.payload[0]) << 8) | frame.payload[1]
                    else
                        1005;
                    const reason = if (frame.payload.len > 2) frame.payload[2..] else "";
                    var reply: [8]u8 = undefined;
                    if (encodeFrame(&reply, .close, &.{}, [_]u8{ 0, 0, 0, 0 }, true, true) catch null) |len| {
                        sendAllAndFlush(self, reply[0..len]) catch {};
                    }
                    return .{ .close = .{ .code = code, .reason = reason } };
                },
                .binary => return error.ProtocolError,
                .text, .continuation => {},
            }

            if (frame.opcode == .text) {
                if (expecting_continuation) return error.ProtocolError;
                expecting_continuation = !frame.fin;
                try self.message_buf.appendSlice(self.gpa, frame.payload);
            } else {
                // continuation
                if (!expecting_continuation) return error.ProtocolError;
                expecting_continuation = !frame.fin;
                try self.message_buf.appendSlice(self.gpa, frame.payload);
            }
            if (self.message_buf.items.len > self.limits.max_message_bytes) return error.OversizedMessage;
            if (frame.fin and !expecting_continuation) {
                return .{ .text = self.message_buf.items };
            }
        }
    }

    /// Send one masked control frame (close/ping/pong). Control payloads are
    /// bounded at 125 bytes by the frame encoder.
    fn sendControl(self: *Client, opcode: Opcode, payload: []const u8) Error!void {
        if (self.closed) return error.Closed;
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        var frame: [2 + 4 + 125]u8 = undefined;
        const len = encodeFrame(&frame, opcode, payload, mask, true, true) catch return error.ProtocolError;
        try sendAllAndFlush(self, frame[0..len]);
    }

    /// Read one complete frame (header + payload) from the server. The
    /// payload is copied into `self.read_buf`; the frame borrows it until the
    /// next `readFrame` call.
    ///
    /// Each read requests *exactly* the bytes it needs (2 header bytes, then
    /// the extended length if any, then the payload). Requesting more than
    /// needed (e.g. the whole 14-byte header array at once) leaks part of the
    /// payload out of the reader's buffer into the caller's header bytes; the
    /// reader would then block waiting for those already-captured bytes on
    /// the next read.
    fn readFrame(self: *Client) Error!Frame {
        var header: [14]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < 2) {
            const got = raceDeadline(self.io, self.limits.read_timeout_ms, readSliceShortFn, .{ self, header[header_len..2] }) catch |err| switch (err) {
                error.Timeout, error.ReadFailed => return error.ReadTimeout,
            };
            if (got == 0) return error.EndOfStream;
            header_len += got;
        }

        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;
        var extra: usize = 0;
        if (payload_len == 126) extra = 2 else if (payload_len == 127) extra = 8;
        const total_header = 2 + extra;
        while (header_len < total_header) {
            const got = raceDeadline(self.io, self.limits.read_timeout_ms, readSliceShortFn, .{ self, header[header_len..total_header] }) catch |err| switch (err) {
                error.Timeout, error.ReadFailed => return error.ReadTimeout,
            };
            if (got == 0) return error.EndOfStream;
            header_len += got;
        }

        if (payload_len == 126) {
            payload_len = (@as(u64, header[2]) << 8) | header[3];
        } else if (payload_len == 127) {
            payload_len = 0;
            for (header[2..10]) |b| payload_len = (payload_len << 8) | b;
            if (payload_len > std.math.maxInt(u64) / 2) return error.ProtocolError;
        }
        if (payload_len > self.limits.max_frame_payload) return error.ProtocolError;
        if (payload_len > self.read_buf.len) return error.OversizedMessage;
        if (masked) return error.ProtocolError;

        const payload: []u8 = self.read_buf[0..@intCast(payload_len)];
        var filled: usize = 0;
        while (filled < payload.len) {
            const got = raceDeadline(self.io, self.limits.read_timeout_ms, readSliceShortFn, .{ self, payload[filled..] }) catch |err| switch (err) {
                error.Timeout, error.ReadFailed => return error.ReadTimeout,
            };
            if (got == 0) return error.EndOfStream;
            filled += got;
        }

        // Rebuild the full frame bytes for parseFrame's bounds checks by
        // parsing the header we already read and validating consistency.
        const opcode_raw = header[0] & 0x0F;
        const fin = (header[0] & 0x80) != 0;
        const opcode: Opcode = switch (opcode_raw) {
            0x0 => .continuation,
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => return error.ProtocolError,
        };
        const is_control = switch (opcode) {
            .close, .ping, .pong => true,
            else => false,
        };
        if (is_control and (!fin or payload.len > 125)) return error.ProtocolError;

        return .{ .fin = fin, .opcode = opcode, .payload = payload };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "target: parse wss, ws, ports, paths, and refuse garbage" {
    const wss = try Target.parse("wss://relay.example.org/path");
    try testing.expect(wss.secure);
    try testing.expectEqualStrings("relay.example.org", wss.host);
    try testing.expectEqual(@as(u16, 443), wss.port);
    try testing.expectEqualStrings("/path", wss.path);

    const ws = try Target.parse("ws://127.0.0.1:8090");
    try testing.expect(!ws.secure);
    try testing.expectEqualStrings("127.0.0.1", ws.host);
    try testing.expectEqual(@as(u16, 8090), ws.port);
    try testing.expectEqualStrings("/", ws.path);

    const explicit = try Target.parse("wss://host.example:8443/sub");
    try testing.expectEqual(@as(u16, 8443), explicit.port);

    try testing.expectError(error.InvalidUrl, Target.parse("https://relay.example.org"));
    try testing.expectError(error.InvalidUrl, Target.parse("wss://"));
    try testing.expectError(error.InvalidUrl, Target.parse("ws://host:0"));
    try testing.expectError(error.InvalidUrl, Target.parse("ws://host:70000"));
    try testing.expectError(error.InvalidUrl, Target.parse("ws://host:port"));
}

test "frame: client frames are masked and round-trip through parseFrame" {
    var buf: [512]u8 = undefined;
    const mask = [4]u8{ 1, 2, 3, 4 };
    const payload = "hello world";
    const len = try encodeFrame(&buf, .text, payload, mask, true, true);
    _ = len;
    // The client frame carries the mask bit set on the wire.
    try testing.expect((buf[1] & 0x80) != 0);
    // The server-side view (unmasked) round-trips through parseFrame.
    var server_view: [512]u8 = undefined;
    const slen = try encodeFrame(&server_view, .text, payload, .{ 0, 0, 0, 0 }, true, false);
    const frame = try parseFrame(server_view[0..slen], 1024);
    try testing.expect(frame.fin);
    try testing.expectEqual(Opcode.text, frame.opcode);
    try testing.expectEqualStrings(payload, frame.payload);
}

test "frame: a server frame must not be masked" {
    // Manually build a masked server frame: FIN|text, mask bit + len, mask key, payload.
    const payload = "OK";
    var frame: [8]u8 = .{ 0x81, 0x80 | 2, 1, 2, 3, 4, 0, 0 };
    frame[6] = payload[0] ^ 1;
    frame[7] = payload[1] ^ 2;
    try testing.expectError(error.ProtocolError, parseFrame(&frame, 1024));
}

test "frame: an oversized declared length is refused before allocation" {
    // FIN|text, 127 (8-byte length), length = maxInt(u64)/2 + 1, no payload.
    var frame: [10]u8 = .{ 0x81, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
    try testing.expectError(error.ProtocolError, parseFrame(&frame, 1024));
}

test "frame: a fragmented control frame and an oversized control payload are refused" {
    // FIN clear + ping opcode.
    var ping_frag: [2]u8 = .{ 0x09, 0x00 };
    try testing.expectError(error.ProtocolError, parseFrame(&ping_frag, 1024));
    // FIN set + ping, payload length 126 is over the control bound.
    var ping_big: [4]u8 = .{ 0x89, 126, 0, 1 };
    try testing.expectError(error.ProtocolError, parseFrame(&ping_big, 1024));
}

test "frame: fuzz — random bytes never panic and parsed frames satisfy invariants" {
    // Feed seeded random byte sequences to parseFrame. Whatever the input,
    // the parser must never panic (this runs under safety checks) and every
    // accepted frame must satisfy the RFC-6455 invariants the client relies
    // on: an accepted frame is a *server* frame (mask bit clear), its payload
    // lies inside the input and under the ceiling, its opcode/fin match the
    // wire bytes, and control frames carry FIN and at most 125 payload bytes.
    var prng = std.Random.DefaultPrng.init(0xF0D0_5EED);
    const rand = prng.random();
    var buf: [512]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 20_000) : (iteration += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..len]);
        const max_payload: usize = rand.intRangeAtMost(usize, 0, 4096);
        const result = parseFrame(buf[0..len], max_payload);
        if (result) |frame| {
            try testing.expect(frame.payload.len <= max_payload);
            try testing.expect(frame.payload.len <= len);
            const payload_start = @intFromPtr(frame.payload.ptr);
            const buf_start = @intFromPtr(&buf);
            try testing.expect(payload_start >= buf_start);
            try testing.expect(payload_start + frame.payload.len <= buf_start + len);
            try testing.expectEqual(frame.fin, (buf[0] & 0x80) != 0);
            try testing.expectEqual(@as(u4, @intCast(buf[0] & 0x0F)), @intFromEnum(frame.opcode));
            try testing.expect((buf[1] & 0x80) == 0); // server frames are never masked
            switch (frame.opcode) {
                .close, .ping, .pong => {
                    try testing.expect(frame.fin);
                    try testing.expect(frame.payload.len <= 125);
                },
                else => {},
            }
        } else |err| {
            // ProtocolError is the parser's only failure mode; anything else
            // would be an allocator or logic bug.
            try testing.expectEqual(error.ProtocolError, err);
        }
    }
}

test "frame: fuzz — encodeFrame round-trips through parseFrame" {
    // Random payloads and masks: the client-side wire form must carry the
    // mask bit and the server-side (unmasked) view must parse back to the
    // exact payload, for both short and extended-length frames.
    var prng = std.Random.DefaultPrng.init(0xCAD0_0D15);
    const rand = prng.random();
    var payload_buf: [2048]u8 = undefined;
    var frame_buf: [4096]u8 = undefined;
    var server_view: [4096]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 2_000) : (iteration += 1) {
        const plen = rand.intRangeAtMost(usize, 0, payload_buf.len);
        rand.bytes(payload_buf[0..plen]);
        var mask: [4]u8 = undefined;
        rand.bytes(&mask);

        _ = try encodeFrame(&frame_buf, .text, payload_buf[0..plen], mask, true, true);
        try testing.expect((frame_buf[1] & 0x80) != 0); // client frames are masked
        const declared: u64 = frame_buf[1] & 0x7F;
        if (plen < 126) {
            try testing.expectEqual(@as(u8, @intCast(plen)), @as(u8, @intCast(declared)));
        } else {
            try testing.expectEqual(@as(u8, 126), @as(u8, @intCast(declared)));
        }

        const slen = try encodeFrame(&server_view, .text, payload_buf[0..plen], .{ 0, 0, 0, 0 }, true, false);
        const frame = try parseFrame(server_view[0..slen], 2048);
        try testing.expectEqualStrings(payload_buf[0..plen], frame.payload);
        try testing.expectEqual(Opcode.text, frame.opcode);
        try testing.expect(frame.fin);
    }
}

test "target: ws is refused for a non-loopback host" {
    // connect() refuses; the parse itself is scheme-agnostic.
    try testing.expect(!isLoopbackHost("relay.example.org"));
    try testing.expect(isLoopbackHost("127.0.0.1"));
    try testing.expect(isLoopbackHost("localhost"));
}
