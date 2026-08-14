const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;
const project = @import("project.zig");
const security = @import("security.zig");

pub const editor_id = "boris-editor/0.1.0";

pub const Config = struct {
    project_root: []const u8,
    ui_dir: []const u8,
    boris_path: []const u8,
    port: u16 = 0,
    token: [32]u8,
};

pub fn serve(io: Io, allocator: std.mem.Allocator, config: Config) !void {
    const address = try net.IpAddress.parseIp4("127.0.0.1", config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    std.debug.print("BORIS_EDITOR_URL=http://127.0.0.1:{d}/#token={s}\n", .{ port, config.token });

    while (true) {
        var stream = try listener.accept(io);
        handleConnection(io, allocator, stream, config, port) catch |err| {
            std.log.warn("editor request failed: {s}", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn handleConnection(io: Io, allocator: std.mem.Allocator, stream: net.Stream, config: Config, port: u16) !void {
    var send_buffer: [16 * 1024]u8 = undefined;
    var receive_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &receive_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var http_server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    var request = try http_server.receiveHead();
    try route(io, allocator, &request, config, port);
}

fn route(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config, port: u16) !void {
    if (request.head.method != .GET and request.head.method != .HEAD) {
        return respondText(request, .method_not_allowed, "Method not allowed", "text/plain; charset=utf-8");
    }

    const target = stripQuery(request.head.target);
    const headers = collectHeaders(request);
    if (!validHost(headers.host, port)) {
        return respondText(request, .forbidden, "Invalid Host", "text/plain; charset=utf-8");
    }

    if (std.mem.startsWith(u8, target, "/api/")) {
        security.validate(headers, port, &config.token) catch {
            return respondText(request, .forbidden, "Forbidden", "text/plain; charset=utf-8");
        };
        if (std.mem.eql(u8, target, "/api/health")) return serveHealth(io, allocator, request, config);
        if (std.mem.eql(u8, target, "/api/version")) return serveVersion(io, allocator, request, config);
        return respondText(request, .not_found, "Not found", "text/plain; charset=utf-8");
    }

    if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/index.html")) {
        return serveUiFile(io, allocator, request, config.ui_dir, "index.html", true);
    }
    if (std.mem.startsWith(u8, target, "/assets/")) {
        const path = target[1..];
        if (!safeStaticPath(path)) return respondText(request, .bad_request, "Invalid path", "text/plain; charset=utf-8");
        return serveUiFile(io, allocator, request, config.ui_dir, path, false);
    }
    return respondText(request, .not_found, "Not found", "text/plain; charset=utf-8");
}

fn serveHealth(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const found = project.discover(io, config.project_root) catch project.Discovery{
        .content = false,
        .default_layout = false,
        .publication_profile = false,
    };
    const response = .{
        .status = "ok",
        .editor_id = editor_id,
        .project = .{
            .content = found.content,
            .default_layout = found.default_layout,
            .publication_profile = found.publication_profile,
        },
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(bytes);
    return respondJson(request, .ok, bytes);
}

fn serveVersion(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ config.boris_path, "--version" },
        .cwd = .{ .path = config.project_root },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return respondJson(request, .service_unavailable, "{\"error\":\"boris_unavailable\"}");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    const compiler_id = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (exit_code != 0 or compiler_id.len == 0 or !std.mem.startsWith(u8, compiler_id, "boris/") or std.mem.indexOfAny(u8, compiler_id, "\r\n") != null) {
        return respondJson(request, .bad_gateway, "{\"error\":\"invalid_boris_version\"}");
    }
    const response = .{
        .compiler_id = compiler_id,
        .supported = .{
            .completion = [_]u8{1},
            .ir = [_][]const u8{ "0.2.0", "0.3.0", "0.4.0" },
            .documentation_intelligence = [_][]const u8{"0.2.0"},
            .publication_plan = [_]u8{1},
            .frontmatter = [_]u8{1},
        },
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(bytes);
    return respondJson(request, .ok, bytes);
}

fn serveUiFile(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, ui_dir_path: []const u8, relative_path: []const u8, html: bool) !void {
    var ui_dir = Io.Dir.cwd().openDir(io, ui_dir_path, .{}) catch {
        return respondText(request, .service_unavailable, "Editor UI is not built", "text/plain; charset=utf-8");
    };
    defer ui_dir.close(io);
    const bytes = ui_dir.readFileAlloc(io, relative_path, allocator, .limited(16 * 1024 * 1024)) catch {
        return respondText(request, .not_found, "Not found", "text/plain; charset=utf-8");
    };
    defer allocator.free(bytes);
    return respondText(request, .ok, bytes, if (html) "text/html; charset=utf-8" else contentType(relative_path));
}

fn respondJson(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &headers });
}

fn respondText(request: *http.Server.Request, status: http.Status, body: []const u8, content_type: []const u8) !void {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'" },
    };
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &headers });
}

fn collectHeaders(request: *const http.Server.Request) security.Headers {
    var result: security.Headers = .{};
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) result.host = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) result.origin = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "x-boris-editor-token")) result.token = header.value;
    }
    return result;
}

fn validHost(host_optional: ?[]const u8, port: u16) bool {
    const host = host_optional orelse return false;
    var expected_ip_buffer: [64]u8 = undefined;
    const expected_ip = std.fmt.bufPrint(&expected_ip_buffer, "127.0.0.1:{d}", .{port}) catch return false;
    var expected_localhost_buffer: [64]u8 = undefined;
    const expected_localhost = std.fmt.bufPrint(&expected_localhost_buffer, "localhost:{d}", .{port}) catch return false;
    return std.ascii.eqlIgnoreCase(host, expected_ip) or std.ascii.eqlIgnoreCase(host, expected_localhost);
}

fn stripQuery(target: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..end];
}

fn safeStaticPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\%\x00") != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    return "application/octet-stream";
}

test "static path guard refuses encoded and lexical traversal" {
    try std.testing.expect(safeStaticPath("assets/app.js"));
    try std.testing.expect(!safeStaticPath("assets/../secret"));
    try std.testing.expect(!safeStaticPath("assets/%2e%2e/secret"));
    try std.testing.expect(!safeStaticPath("/absolute"));
}
