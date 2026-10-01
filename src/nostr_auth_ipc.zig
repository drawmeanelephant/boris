//! Anonymous-pipe framing. One complete frame owns a non-renewing deadline.
const std = @import("std");
const auth = @import("nostr_auth.zig");
const builtin = @import("builtin");
const root = @import("root");
const system = if (@hasDecl(root, "nostr_auth_faults")) root.nostr_auth_faults.Pipes else std.c;

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;
pub var canceled: std.atomic.Value(bool) = .init(false);
pub const Channel = struct {
    io: std.Io,
    input: std.c.fd_t,
    output: std.c.fd_t,
    run: [32]u8 = undefined,
    request: u64 = 0,
    ceiling: ?auth.Deadline = null,
    frame_timeout_ms: u32 = 60000,

    pub fn init(io: std.Io, input: std.c.fd_t, output: std.c.fd_t) !Channel {
        if (!supported) return error.UnsupportedPlatform;
        if (input == output) return error.SessionInvalid;
        inline for (.{ input, output }) |fd| {
            if (fd < 3) return error.SessionInvalid;
            const flags = std.c.fcntl(fd, std.posix.F.GETFL);
            const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            const metadata = file.stat(io) catch return error.SessionInvalid;
            if (metadata.kind != .named_pipe or flags & 3 != (if (fd == input) @as(c_int, 0) else 1)) return error.SessionInvalid;
            if (flags < 0 or std.c.fcntl(fd, std.posix.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))) < 0) return error.SessionInvalid;
            if (std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) < 0) return error.SessionInvalid;
        }
        return .{ .io = io, .input = input, .output = output };
    }

    fn wait(self: *Channel, fd: std.c.fd_t, writing: bool, deadline: auth.Deadline) !void {
        while (true) {
            if (canceled.load(.unordered)) return error.Canceled;
            _ = try deadline.remaining(self.io);
            var fds = [_]std.c.pollfd{.{ .fd = fd, .events = if (writing) std.posix.POLL.OUT else std.posix.POLL.IN, .revents = 0 }};
            const n = system.poll(&fds, 1, 0);
            if (n < 0) return error.ChannelLost;
            if (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.ChannelLost;
            if (fds[0].revents & (if (writing) @as(i16, std.posix.POLL.OUT) else std.posix.POLL.IN) != 0) return;
            if (fds[0].revents & std.posix.POLL.HUP != 0) return error.ChannelLost;
            try (std.Io.Timeout{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(2) } }).sleep(self.io);
        }
    }

    fn readExact(self: *Channel, bytes: []u8, deadline: auth.Deadline) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.wait(self.input, false, deadline);
            const n = std.c.read(self.input, bytes[offset..].ptr, bytes.len - offset);
            if (n <= 0) return error.ChannelLost;
            offset += @intCast(n);
        }
    }
    fn writeExact(self: *Channel, bytes: []const u8, deadline: auth.Deadline) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.wait(self.output, true, deadline);
            const n = std.c.write(self.output, bytes[offset..].ptr, @min(1024, bytes.len - offset));
            if (n <= 0) return error.ChannelLost;
            offset += @intCast(n);
        }
    }
    pub fn read(self: *Channel, gpa: std.mem.Allocator, deadline: auth.Deadline) ![]u8 {
        var header: [4]u8 = undefined;
        // Idle supervisor waits may use the session ceiling; once a frame
        // starts, no partial-byte traffic can renew its shorter budget.
        try self.readExact(header[0..1], deadline);
        const frame_deadline = auth.Deadline.after(self.io, self.frame_timeout_ms).clip(deadline);
        try self.readExact(header[1..], frame_deadline);
        const length = std.mem.readInt(u32, &header, .big);
        if (length == 0 or length > auth.max_frame) return error.Oversized;
        const bytes = try gpa.alloc(u8, length);
        errdefer gpa.free(bytes);
        try self.readExact(bytes, frame_deadline);
        try auth.checkJson(bytes);
        return bytes;
    }
    pub fn send(self: *Channel, gpa: std.mem.Allocator, value: anytype, deadline: auth.Deadline) !void {
        if (comptime @hasDecl(root, "nostr_auth_faults")) try root.nostr_auth_faults.beforeSend(self, value.type);
        const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{});
        defer gpa.free(bytes);
        try auth.checkJson(bytes);
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(bytes.len), .big);
        try self.writeExact(&header, deadline);
        try self.writeExact(bytes, deadline);
    }
    pub fn control(self: *Channel, gpa: std.mem.Allocator, correlation: auth.Correlation, kind: []const u8, timeout: u32) !void {
        if (self.ceiling.?.remaining(self.io)) |_| {} else |_| return;
        try self.send(gpa, auth.Control{ .type = kind, .correlation = correlation }, auth.Deadline.after(self.io, timeout).clip(self.ceiling.?));
    }
    pub fn monitor(self: *Channel) !void {
        while (true) {
            if (canceled.load(.unordered)) return error.Canceled;
            // Darwin suppresses pipe HUP with an empty requested-event mask.
            // Observe readability, but never consume the protocol reader's data.
            var fds = [_]std.c.pollfd{.{ .fd = self.input, .events = std.posix.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 0) < 0 or fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.ChannelLost;
            try (std.Io.Timeout{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(10) } }).sleep(self.io);
        }
    }
};

const TestPipes = struct {
    fds: [4]std.c.fd_t,
    fn init() !TestPipes {
        var first: [2]std.c.fd_t = undefined;
        var second: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&first) != 0) return error.PipeFailed;
        errdefer {
            _ = std.c.close(first[0]);
            _ = std.c.close(first[1]);
        }
        if (std.c.pipe(&second) != 0) return error.PipeFailed;
        return .{ .fds = first ++ second };
    }
    fn close(self: *TestPipes, index: usize) void {
        if (self.fds[index] >= 0) _ = std.c.close(self.fds[index]);
        self.fds[index] = -1;
    }
    fn deinit(self: *TestPipes) void {
        for (0..4) |i| self.close(i);
    }
};

fn testWriteFrame(peer: *Channel, bytes: []const u8) void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .big);
    const deadline = auth.Deadline.after(peer.io, 1000);
    peer.writeExact(&header, deadline) catch return;
    // Deliberately fragment the payload into single-byte writes.
    for (bytes) |byte| peer.writeExact(&.{byte}, deadline) catch return;
}

fn testDripFrame(peer: *Channel) void {
    for ([_]u8{ 0, 0, 0, 10, '{', '}', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ' }) |byte| {
        peer.writeExact(&.{byte}, auth.Deadline.after(peer.io, 1000)) catch return;
        std.Io.sleep(peer.io, .fromMilliseconds(10), .awake) catch return;
    }
}

test "auth IPC exact-limit fragmented frames, oversized prefix and truncation" {
    if (comptime !supported) return error.SkipZigTest;
    canceled.store(false, .unordered);
    var pipes = try TestPipes.init();
    defer pipes.deinit();
    var channel = try Channel.init(std.testing.io, pipes.fds[0], pipes.fds[3]);
    var peer = try Channel.init(std.testing.io, pipes.fds[2], pipes.fds[1]);
    const bytes = try std.testing.allocator.alloc(u8, auth.max_frame);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, ' ');
    bytes[0..2].* = .{ '{', '}' };
    const thread = try std.Thread.spawn(.{}, testWriteFrame, .{ &peer, bytes });
    const got = try channel.read(std.testing.allocator, auth.Deadline.after(std.testing.io, 2000));
    defer std.testing.allocator.free(got);
    thread.join();
    try std.testing.expectEqualSlices(u8, bytes, got);
    try peer.writeExact(&.{ 0, 0, 0x80, 1 }, auth.Deadline.after(std.testing.io, 100));
    try std.testing.expectError(error.Oversized, channel.read(std.testing.allocator, auth.Deadline.after(std.testing.io, 100)));
    try peer.writeExact(&.{ 0, 0, 0, 10, '{', '}' }, auth.Deadline.after(std.testing.io, 100));
    pipes.close(1);
    try std.testing.expectError(error.ChannelLost, channel.read(std.testing.allocator, auth.Deadline.after(std.testing.io, 100)));
}

test "auth IPC partial header cannot renew complete-frame deadline" {
    if (comptime !supported) return error.SkipZigTest;
    canceled.store(false, .unordered);
    var pipes = try TestPipes.init();
    defer pipes.deinit();
    var channel = try Channel.init(std.testing.io, pipes.fds[0], pipes.fds[3]);
    channel.frame_timeout_ms = 25;
    var peer = try Channel.init(std.testing.io, pipes.fds[2], pipes.fds[1]);
    const thread = try std.Thread.spawn(.{}, testDripFrame, .{&peer});
    defer thread.join();
    const start = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    try std.testing.expectError(error.Timeout, channel.read(std.testing.allocator, auth.Deadline.after(std.testing.io, 1000)));
    const elapsed = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - start;
    try std.testing.expect(elapsed < 100 * std.time.ns_per_ms);
}

test "auth IPC rejects ordinary files and same endpoint before handshake" {
    if (comptime !supported) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "not-a-pipe", .{});
    defer file.close(std.testing.io);
    var pipes = try TestPipes.init();
    defer pipes.deinit();
    try std.testing.expectError(error.SessionInvalid, Channel.init(std.testing.io, pipes.fds[0], file.handle));
    try std.testing.expectError(error.SessionInvalid, Channel.init(std.testing.io, pipes.fds[0], pipes.fds[0]));
}
