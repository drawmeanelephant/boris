//! Ephemeral IPv4 loopback callback listener for one native OAuth attempt.
//!
//! The listener binds only 127.0.0.1 on an OS-selected port, accepts exactly
//! one bounded HTTP request under one deadline, checks the Host header, and
//! never exposes a general local web server.

const std = @import("std");
const authorization = @import("atproto_authorization.zig");

pub const Error = std.mem.Allocator.Error || error{
    AlreadyConsumed,
    BindFailed,
    InvalidRequest,
    ResponseFailed,
    Timeout,
};

pub const Listener = struct {
    io: std.Io,
    server: std.Io.net.Server,
    port: u16,
    consumed: bool = false,

    pub fn init(io: std.Io) Error!Listener {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = address.listen(io, .{
            .kernel_backlog = 1,
            .reuse_address = false,
        }) catch return error.BindFailed;
        errdefer server.deinit(io);
        const port = server.socket.address.getPort();
        if (port == 0) return error.BindFailed;
        return .{ .io = io, .server = server, .port = port };
    }

    pub fn deinit(listener: *Listener) void {
        listener.server.deinit(listener.io);
        listener.* = undefined;
    }

    pub fn redirectUri(listener: *const Listener, buffer: *[256]u8) Error![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ listener.port, authorization.callback_path }) catch error.BindFailed;
    }

    /// Returns an owned request target. The listener itself remains open only
    /// until `deinit`, allowing the caller to close it immediately after this
    /// single operation regardless of validation outcome.
    pub fn waitTarget(listener: *Listener, allocator: std.mem.Allocator, timeout_ms: u32) Error![]u8 {
        if (listener.consumed) return error.AlreadyConsumed;
        listener.consumed = true;
        const AcceptResult = Error![]u8;
        const TimerResult = std.Io.Cancelable!void;
        const Race = union(enum) { accept: AcceptResult, timer: TimerResult };
        var race_buffer: [2]Race = undefined;
        var race: std.Io.Select(Race) = .init(listener.io, &race_buffer);
        race.async(.accept, acceptOne, .{ listener, allocator });
        race.async(.timer, timeoutTask, .{ listener.io, timeout_ms });
        const first = race.await() catch {
            drainRace(&race, allocator);
            return error.Timeout;
        };
        return switch (first) {
            .accept => |result| value: {
                drainRace(&race, allocator);
                break :value result;
            },
            .timer => timed_out: {
                drainRace(&race, allocator);
                break :timed_out error.Timeout;
            },
        };
    }
};

fn acceptOne(listener: *Listener, allocator: std.mem.Allocator) Error![]u8 {
    const stream = listener.server.accept(listener.io) catch return error.InvalidRequest;
    defer stream.close(listener.io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [2048]u8 = undefined;
    var stream_reader = stream.reader(listener.io, &read_buffer);
    var stream_writer = stream.writer(listener.io, &write_buffer);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = http_server.receiveHead() catch return error.InvalidRequest;

    const target_path_end = std.mem.indexOfScalar(u8, request.head.target, '?') orelse request.head.target.len;
    const valid = request.head.method == .GET and
        request.head.content_length == null and
        request.head.transfer_encoding == .none and
        request.head.target.len <= authorization.max_callback_target_bytes and
        std.mem.eql(u8, request.head.target[0..target_path_end], authorization.callback_path) and
        validHost(&request, listener.port);
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "content-security-policy", .value = "default-src 'none'" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    if (!valid) {
        request.respond("Invalid OAuth callback.\n", .{
            .status = .bad_request,
            .keep_alive = false,
            .extra_headers = &headers,
        }) catch return error.ResponseFailed;
        return error.InvalidRequest;
    }
    const owned = try allocator.dupe(u8, request.head.target);
    errdefer allocator.free(owned);
    request.respond("Authorization received. You can return to Boris.\n", .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &headers,
    }) catch return error.ResponseFailed;
    return owned;
}

fn validHost(request: *const std.http.Server.Request, port: u16) bool {
    var expected_buffer: [32]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buffer, "127.0.0.1:{d}", .{port}) catch return false;
    var found = false;
    var count: usize = 0;
    var total: usize = 0;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        count += 1;
        total = std.math.add(usize, total, header.name.len + header.value.len) catch return false;
        if (count > 32 or total > 8192) return false;
        if (!std.ascii.eqlIgnoreCase(header.name, "host")) continue;
        if (found or !std.mem.eql(u8, header.value, expected)) return false;
        found = true;
    }
    return found;
}

fn timeoutTask(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    return (std.Io.Timeout{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    } }).sleep(io);
}

fn drainRace(race: anytype, allocator: std.mem.Allocator) void {
    while (race.cancel()) |remaining| switch (remaining) {
        .accept => |result| if (result) |target| allocator.free(target) else |_| {},
        .timer => {},
    };
}

test "listener binds only ephemeral IPv4 loopback and formats exact callback" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();
    var listener = try Listener.init(io);
    defer listener.deinit();
    try std.testing.expect(listener.port != 0);
    var buffer: [256]u8 = undefined;
    const redirect = try listener.redirectUri(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, redirect, "http://127.0.0.1:"));
    try std.testing.expect(std.mem.endsWith(u8, redirect, authorization.callback_path));
}

fn testCallbackClient(io: std.Io, port: u16) !void {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print(
        "GET /oauth/callback?state=test&iss=https%3A%2F%2Fauth.example.com&code=abc HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{port},
    );
    try writer.interface.flush();
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var response: [256]u8 = undefined;
    const count = try reader.interface.readSliceShort(&response);
    if (!std.mem.startsWith(u8, response[0..count], "HTTP/1.1 200")) return error.InvalidRequest;
}

test "listener accepts one exact callback request and rejects reuse" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();
    var listener = try Listener.init(io);
    defer listener.deinit();

    const Result = union(enum) {
        server: Error![]u8,
        client: anyerror!void,
    };
    var select_buffer: [2]Result = undefined;
    var select: std.Io.Select(Result) = .init(io, &select_buffer);
    select.async(.server, Listener.waitTarget, .{ &listener, std.testing.allocator, 2000 });
    select.async(.client, testCallbackClient, .{ io, listener.port });
    var target: ?[]u8 = null;
    defer if (target) |value| std.testing.allocator.free(value);
    var completed: usize = 0;
    while (completed < 2) : (completed += 1) switch (try select.await()) {
        .server => |result| target = try result,
        .client => |result| try result,
    };
    try std.testing.expectEqualStrings(
        "/oauth/callback?state=test&iss=https%3A%2F%2Fauth.example.com&code=abc",
        target.?,
    );
    try std.testing.expectError(error.AlreadyConsumed, listener.waitTarget(std.testing.allocator, 1));
}
