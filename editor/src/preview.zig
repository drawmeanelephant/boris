//! Real-compiler preview fallback used until `boris serve` lands.
//!
//! This module invokes one fixed incremental HTML command and serves the
//! committed `dist/` bytes unchanged on a second loopback origin.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;
const project = @import("project.zig");

pub const Phase = enum { idle, running, success, failed, stale };

pub const Manager = struct {
    project_root: []const u8,
    boris_path: []const u8,
    port: u16,
    phase: Phase,
    generation: u64 = 0,
    exit_code: ?u8 = null,
    used_stderr_fallback: bool = false,
    message: [1024]u8 = undefined,
    message_len: usize = 0,

    pub fn init(io: Io, project_root: []const u8, boris_path: []const u8, port: u16) Manager {
        var result: Manager = .{
            .project_root = project_root,
            .boris_path = boris_path,
            .port = port,
            .phase = if (hasIndex(io, project_root)) .stale else .idle,
        };
        result.setMessage(if (result.phase == .stale) "Existing preview output is previous/stale until rebuilt." else "Preview has not been built yet.");
        return result;
    }

    pub fn rebuild(self: *Manager, allocator: std.mem.Allocator, io: Io) !void {
        self.phase = .running;
        self.exit_code = null;
        self.used_stderr_fallback = false;
        self.setMessage("Boris incremental preview build is running.");
        const discovered = project.discover(io, self.project_root) catch project.Discovery{
            .content = false,
            .default_layout = false,
            .publication_profile = false,
            .input_mode = .empty,
        };
        const argv: []const []const u8 = if (discovered.input_mode == .cooklang)
            &.{ self.boris_path, "build", "--input", "content", "--incremental", "--html-dir", "dist", "--cooklang" }
        else
            &.{ self.boris_path, "build", "--input", "content", "--incremental", "--html-dir", "dist" };
        const execution = std.process.run(allocator, io, .{
            .argv = argv,
            .cwd = .{ .path = self.project_root },
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(16 * 1024 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(120) } },
        }) catch |err| {
            self.phase = if (hasIndex(io, self.project_root)) .stale else .failed;
            self.setMessage(if (err == error.Timeout) "Boris preview build timed out; last valid output is stale." else "Boris preview process could not complete; last valid output is stale.");
            return;
        };
        defer allocator.free(execution.stdout);
        defer allocator.free(execution.stderr);
        self.exit_code = exitCode(execution.term);
        if (self.exit_code == 0) {
            if (!hasIndex(io, self.project_root)) return error.PreviewOutputMissing;
            self.phase = .success;
            self.generation += 1;
            self.setMessage("Preview is current from a successful Boris incremental build.");
        } else {
            self.phase = if (hasIndex(io, self.project_root)) .stale else .failed;
            self.used_stderr_fallback = true;
            self.setStderrSummary(execution.stderr);
        }
    }

    pub fn renderState(self: *const Manager, allocator: std.mem.Allocator, token: *const [32]u8) ![]u8 {
        const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/?token={s}", .{ self.port, token });
        defer allocator.free(url);
        return std.json.Stringify.valueAlloc(allocator, .{
            .phase = self.phase,
            .generation = self.generation,
            .exit_code = self.exit_code,
            .used_stderr_fallback = self.used_stderr_fallback,
            .message = self.message[0..self.message_len],
            .preview_url = url,
        }, .{});
    }

    fn setMessage(self: *Manager, value: []const u8) void {
        self.message_len = @min(value.len, self.message.len);
        @memcpy(self.message[0..self.message_len], value[0..self.message_len]);
    }

    fn setStderrSummary(self: *Manager, stderr: []const u8) void {
        var chosen: []const u8 = "Boris preview build failed; last valid output is stale.";
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0 and (std.mem.startsWith(u8, line, "error:") or std.mem.startsWith(u8, line, "warning:"))) chosen = line;
        }
        if (std.mem.indexOf(u8, chosen, self.project_root) != null) chosen = "Boris preview build failed; private path removed. Last valid output is stale.";
        self.message_len = @min(chosen.len, self.message.len);
        for (chosen[0..self.message_len], 0..) |byte, index| self.message[index] = if (byte < 0x20 and byte != '\t') ' ' else byte;
    }
};

const StaticContext = struct {
    io: Io,
    listener: net.Server,
    project_root: []const u8,
    token: [32]u8,
    port: u16,
};

pub fn startStatic(io: Io, project_root: []const u8, token: [32]u8) !u16 {
    const address = try net.IpAddress.parseIp4("127.0.0.1", 0);
    const listener = try address.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    const context = try std.heap.page_allocator.create(StaticContext);
    context.* = .{ .io = io, .listener = listener, .project_root = project_root, .token = token, .port = port };
    const thread = try std.Thread.spawn(.{}, staticLoop, .{context});
    thread.detach();
    return port;
}

fn staticLoop(context: *StaticContext) void {
    defer std.heap.page_allocator.destroy(context);
    defer context.listener.deinit(context.io);
    while (true) {
        var stream = context.listener.accept(context.io) catch return;
        handleStatic(context, stream) catch {};
        stream.close(context.io);
    }
}

fn handleStatic(context: *StaticContext, stream: net.Stream) !void {
    var send_buffer: [16 * 1024]u8 = undefined;
    var receive_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(context.io, &receive_buffer);
    var connection_writer = stream.writer(context.io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    var request = try server.receiveHead();
    if (request.head.method != .GET and request.head.method != .HEAD) return staticResponse(&request, .method_not_allowed, "Method not allowed", "text/plain", null);
    var host: ?[]const u8 = null;
    var cookie: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) host = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) cookie = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) origin = header.value;
    }
    if (!validHost(host, context.port)) return staticResponse(&request, .forbidden, "Forbidden", "text/plain", null);
    if (!validOrigin(origin, context.port)) return staticResponse(&request, .forbidden, "Forbidden", "text/plain", null);
    const query_authorized = queryHasToken(request.head.target, &context.token);
    if (!query_authorized and !cookieHasToken(cookie, context.port, &context.token)) return staticResponse(&request, .forbidden, "Forbidden", "text/plain", null);
    const target = stripQuery(request.head.target);
    const relative = if (std.mem.eql(u8, target, "/")) "index.html" else target[1..];
    if (!safePath(relative)) return staticResponse(&request, .bad_request, "Invalid path", "text/plain", null);
    var root = Io.Dir.cwd().openDir(context.io, context.project_root, .{ .follow_symlinks = false }) catch return staticResponse(&request, .service_unavailable, "Preview unavailable", "text/plain", null);
    defer root.close(context.io);
    var dist = root.openDir(context.io, "dist", .{ .follow_symlinks = false }) catch return staticResponse(&request, .not_found, "Not found", "text/plain", null);
    defer dist.close(context.io);
    const bytes = dist.readFileAlloc(context.io, relative, std.heap.smp_allocator, .limited(32 * 1024 * 1024)) catch return staticResponse(&request, .not_found, "Not found", "text/plain", null);
    defer std.heap.smp_allocator.free(bytes);
    var cookie_buffer: [96]u8 = undefined;
    const set_cookie = if (query_authorized) std.fmt.bufPrint(&cookie_buffer, "BorisPreview_{d}={s}; Path=/; HttpOnly; SameSite=Strict", .{ context.port, context.token }) catch null else null;
    return staticResponse(&request, .ok, bytes, contentType(relative), set_cookie);
}

fn staticResponse(request: *http.Server.Request, status: http.Status, body: []const u8, content_type: []const u8, set_cookie: ?[]const u8) !void {
    const base = [_]http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    var with_cookie: [4]http.Header = undefined;
    @memcpy(with_cookie[0..3], &base);
    if (set_cookie) |value| {
        with_cookie[3] = .{ .name = "set-cookie", .value = value };
        return request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &with_cookie });
    }
    return request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &base });
}

fn hasIndex(io: Io, project_root: []const u8) bool {
    var root = Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false }) catch return false;
    defer root.close(io);
    var dist = root.openDir(io, "dist", .{ .follow_symlinks = false }) catch return false;
    defer dist.close(io);
    var file = dist.openFile(io, "index.html", .{ .allow_directory = false, .follow_symlinks = false }) catch return false;
    file.close(io);
    return true;
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

fn stripQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

fn queryHasToken(target: []const u8, token: *const [32]u8) bool {
    const marker = "?token=";
    const start = std.mem.indexOf(u8, target, marker) orelse return false;
    const value = target[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, value, '&') orelse value.len;
    if (end != token.len) return false;
    return constantTimeToken(value[0..end], token);
}

fn cookieHasToken(cookie: ?[]const u8, port: u16, token: *const [32]u8) bool {
    const value = cookie orelse return false;
    var name_buffer: [48]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "BorisPreview_{d}=", .{port}) catch return false;
    var parts = std.mem.splitScalar(u8, value, ';');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, part, name)) {
            const candidate = part[name.len..];
            if (candidate.len != token.len) return false;
            return constantTimeToken(candidate, token);
        }
    }
    return false;
}

fn constantTimeToken(candidate: []const u8, token: *const [32]u8) bool {
    if (candidate.len != token.len) return false;
    var difference: u8 = 0;
    for (candidate, token) |left, right| difference |= left ^ right;
    return difference == 0;
}

fn validHost(host_optional: ?[]const u8, port: u16) bool {
    const host = host_optional orelse return false;
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    return std.ascii.eqlIgnoreCase(host, std.fmt.bufPrint(&a, "127.0.0.1:{d}", .{port}) catch return false) or std.ascii.eqlIgnoreCase(host, std.fmt.bufPrint(&b, "localhost:{d}", .{port}) catch return false);
}

fn validOrigin(origin_optional: ?[]const u8, port: u16) bool {
    const origin = origin_optional orelse return true;
    var a: [72]u8 = undefined;
    var b: [72]u8 = undefined;
    return std.ascii.eqlIgnoreCase(origin, std.fmt.bufPrint(&a, "http://127.0.0.1:{d}", .{port}) catch return false) or std.ascii.eqlIgnoreCase(origin, std.fmt.bufPrint(&b, "http://localhost:{d}", .{port}) catch return false);
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\%\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    return "application/octet-stream";
}

test "preview authorization and path guards are exact" {
    const token: [32]u8 = "0123456789abcdef0123456789abcdef".*;
    try std.testing.expect(queryHasToken("/?token=0123456789abcdef0123456789abcdef", &token));
    try std.testing.expect(!queryHasToken("/?token=0123456789abcdef0123456789abcdeg", &token));
    try std.testing.expect(cookieHasToken("x=1; BorisPreview_8123=0123456789abcdef0123456789abcdef", 8123, &token));
    try std.testing.expect(safePath("guides/start.html"));
    try std.testing.expect(!safePath("guides/../secret"));
    try std.testing.expect(!safePath("%2e%2e/secret"));
}
