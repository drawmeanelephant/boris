const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;
const authoring = @import("authoring.zig");
const file_api = @import("file_api.zig");
const project = @import("project.zig");
const preview = @import("preview.zig");
const recovery = @import("recovery.zig");
const runner = @import("runner.zig");
const security = @import("security.zig");

pub const editor_id = "boris-editor/0.1.0";

pub const Config = struct {
    project_root: []const u8,
    ui_dir: []const u8,
    boris_path: []const u8,
    state_root: []const u8,
    port: u16 = 0,
    token: [32]u8,
    preview: *preview.Manager,
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
    const target = stripQuery(request.head.target);
    const headers = collectHeaders(request);
    if (!validHost(headers.host, port)) {
        return respondText(request, .forbidden, "Invalid Host", "text/plain; charset=utf-8", config.preview.port);
    }

    if (std.mem.startsWith(u8, target, "/api/")) {
        security.validate(headers, port, &config.token) catch {
            return respondText(request, .forbidden, "Forbidden", "text/plain; charset=utf-8", config.preview.port);
        };
        if (std.mem.eql(u8, target, "/api/health")) {
            if (!isReadMethod(request.head.method)) return methodNotAllowed(request, "GET, HEAD");
            return serveHealth(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/version")) {
            if (!isReadMethod(request.head.method)) return methodNotAllowed(request, "GET, HEAD");
            return serveVersion(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/files")) {
            if (!isReadMethod(request.head.method)) return methodNotAllowed(request, "GET, HEAD");
            return serveFileList(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/files/open")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            return serveFileOpen(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/files/save")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            return serveFileSave(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/files/create")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            return serveFileCreate(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/files/rename")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            return serveFileRename(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/files/delete")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            return serveFileDelete(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/recovery")) {
            if (!isReadMethod(request.head.method)) return methodNotAllowed(request, "GET, HEAD");
            return serveRecoveryList(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/recovery/snapshot")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            return serveRecoverySnapshot(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/recovery/clear")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            return serveRecoveryClear(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/commands/run")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            return serveCommandRun(io, allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/authoring")) {
            if (!isReadMethod(request.head.method)) return methodNotAllowed(request, "GET, HEAD");
            const bytes = authoring.render(allocator, io, config.project_root) catch |err| return respondApiError(request, err);
            defer allocator.free(bytes);
            return respondJson(request, .ok, bytes);
        }
        if (std.mem.eql(u8, target, "/api/preview/state")) {
            if (!isReadMethod(request.head.method)) return methodNotAllowed(request, "GET, HEAD");
            return servePreviewState(allocator, request, config);
        }
        if (std.mem.eql(u8, target, "/api/preview/rebuild")) {
            if (request.head.method != .POST) return methodNotAllowed(request, "POST");
            config.preview.rebuild(allocator, io) catch |err| return respondApiError(request, err);
            return servePreviewState(allocator, request, config);
        }
        return respondText(request, .not_found, "Not found", "text/plain; charset=utf-8", config.preview.port);
    }

    if (!isReadMethod(request.head.method)) {
        return methodNotAllowed(request, "GET, HEAD");
    }

    if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/index.html")) {
        return serveUiFile(io, allocator, request, config.ui_dir, "index.html", true, config.preview.port);
    }
    if (std.mem.startsWith(u8, target, "/assets/")) {
        const path = target[1..];
        if (!safeStaticPath(path)) return respondText(request, .bad_request, "Invalid path", "text/plain; charset=utf-8", config.preview.port);
        return serveUiFile(io, allocator, request, config.ui_dir, path, false, config.preview.port);
    }
    return respondText(request, .not_found, "Not found", "text/plain; charset=utf-8", config.preview.port);
}

fn servePreviewState(allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const bytes = try config.preview.renderState(allocator, &config.token);
    defer allocator.free(bytes);
    return respondJson(request, .ok, bytes);
}

const PathRequest = struct {
    path: []const u8,
};

const SaveRequest = struct {
    path: []const u8,
    content: []const u8,
    fingerprint: []const u8,
    recreate: bool = false,
};

const CreateRequest = struct {
    path: []const u8,
    content: []const u8 = "",
};

const RenameRequest = struct {
    path: []const u8,
    new_path: []const u8,
};

const DeleteRequest = struct {
    path: []const u8,
    confirmed: bool = false,
};

const SnapshotRequest = struct {
    path: []const u8,
    content: []const u8,
    fingerprint: []const u8,
};

fn serveFileList(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    var files = file_api.list(allocator, io, config.project_root) catch |err| return respondApiError(request, err);
    defer files.deinit(allocator);
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .files = files.entries }, .{});
    defer allocator.free(bytes);
    return respondJson(request, .ok, bytes);
}

fn serveFileOpen(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const body = readJsonBody(allocator, request) catch |err| return respondApiError(request, err);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(PathRequest, allocator, body, .{}) catch return respondApiError(request, error.InvalidJson);
    defer parsed.deinit();
    var buffer = file_api.open(allocator, io, config.project_root, parsed.value.path) catch |err| return respondApiError(request, err);
    defer buffer.deinit(allocator);
    return respondBuffer(allocator, request, .ok, "opened", parsed.value.path, buffer);
}

fn serveFileSave(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const body = readJsonBody(allocator, request) catch |err| return respondApiError(request, err);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(SaveRequest, allocator, body, .{}) catch return respondApiError(request, error.InvalidJson);
    defer parsed.deinit();
    var outcome = file_api.save(
        allocator,
        io,
        config.project_root,
        parsed.value.path,
        parsed.value.content,
        parsed.value.fingerprint,
        parsed.value.recreate,
    ) catch |err| return respondApiError(request, err);
    defer outcome.deinit(allocator);
    switch (outcome) {
        .saved => |buffer| {
            recovery.clear(io, config.state_root, parsed.value.path) catch |err| {
                std.log.warn("could not clear recovery snapshot after save: {s}", .{@errorName(err)});
            };
            return respondBuffer(allocator, request, .ok, "saved", parsed.value.path, buffer);
        },
        .conflict => |buffer| return respondBuffer(allocator, request, .conflict, "conflict", parsed.value.path, buffer),
        .deleted => return respondJson(request, .conflict, "{\"status\":\"deleted\"}"),
    }
}

fn serveFileCreate(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const body = readJsonBody(allocator, request) catch |err| return respondApiError(request, err);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(CreateRequest, allocator, body, .{}) catch return respondApiError(request, error.InvalidJson);
    defer parsed.deinit();
    var buffer = file_api.create(allocator, io, config.project_root, parsed.value.path, parsed.value.content) catch |err| return respondApiError(request, err);
    defer buffer.deinit(allocator);
    return respondBuffer(allocator, request, .created, "created", parsed.value.path, buffer);
}

fn serveFileRename(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const body = readJsonBody(allocator, request) catch |err| return respondApiError(request, err);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(RenameRequest, allocator, body, .{}) catch return respondApiError(request, error.InvalidJson);
    defer parsed.deinit();
    file_api.rename(io, config.project_root, parsed.value.path, parsed.value.new_path) catch |err| return respondApiError(request, err);
    recovery.clear(io, config.state_root, parsed.value.path) catch |err| {
        std.log.warn("could not clear recovery snapshot after rename: {s}", .{@errorName(err)});
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .status = "renamed", .path = parsed.value.new_path }, .{});
    defer allocator.free(bytes);
    return respondJson(request, .ok, bytes);
}

fn serveFileDelete(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const body = readJsonBody(allocator, request) catch |err| return respondApiError(request, err);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(DeleteRequest, allocator, body, .{}) catch return respondApiError(request, error.InvalidJson);
    defer parsed.deinit();
    file_api.delete(io, config.project_root, parsed.value.path, parsed.value.confirmed) catch |err| return respondApiError(request, err);
    recovery.clear(io, config.state_root, parsed.value.path) catch |err| {
        std.log.warn("could not clear recovery snapshot after delete: {s}", .{@errorName(err)});
    };
    return respondJson(request, .ok, "{\"status\":\"deleted\"}");
}

fn serveRecoveryList(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    var snapshots = recovery.loadAll(allocator, io, config.state_root) catch |err| return respondApiError(request, err);
    defer snapshots.deinit(allocator);
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .snapshots = snapshots.snapshots }, .{});
    defer allocator.free(bytes);
    return respondJson(request, .ok, bytes);
}

fn serveRecoverySnapshot(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const body = readJsonBody(allocator, request) catch |err| return respondApiError(request, err);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(SnapshotRequest, allocator, body, .{}) catch return respondApiError(request, error.InvalidJson);
    defer parsed.deinit();
    file_api.validatePath(parsed.value.path) catch |err| return respondApiError(request, err);
    recovery.save(allocator, io, config.state_root, parsed.value.path, parsed.value.content, parsed.value.fingerprint) catch |err| return respondApiError(request, err);
    return respondJson(request, .ok, "{\"status\":\"snapshotted\"}");
}

fn serveRecoveryClear(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const body = readJsonBody(allocator, request) catch |err| return respondApiError(request, err);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(PathRequest, allocator, body, .{}) catch return respondApiError(request, error.InvalidJson);
    defer parsed.deinit();
    file_api.validatePath(parsed.value.path) catch |err| return respondApiError(request, err);
    recovery.clear(io, config.state_root, parsed.value.path) catch |err| return respondApiError(request, err);
    return respondJson(request, .ok, "{\"status\":\"cleared\"}");
}

fn serveCommandRun(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, config: Config) !void {
    const body = readJsonBody(allocator, request) catch |err| return respondApiError(request, err);
    defer allocator.free(body);
    const parsed = std.json.parseFromSlice(runner.Request, allocator, body, .{}) catch return respondApiError(request, error.InvalidJson);
    defer parsed.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const result = runner.run(arena.allocator(), io, .{
        .project_root = config.project_root,
        .boris_path = config.boris_path,
        .editor_id = editor_id,
    }, parsed.value) catch |err| return respondApiError(request, err);
    const bytes = try std.json.Stringify.valueAlloc(allocator, result, .{});
    defer allocator.free(bytes);
    return respondJson(request, .ok, bytes);
}

fn respondBuffer(
    allocator: std.mem.Allocator,
    request: *http.Server.Request,
    status: http.Status,
    outcome: []const u8,
    path: []const u8,
    buffer: file_api.Buffer,
) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{
        .status = outcome,
        .path = path,
        .content = buffer.content,
        .fingerprint = buffer.fingerprint[0..],
        .read_only = buffer.read_only,
    }, .{});
    defer allocator.free(bytes);
    return respondJson(request, status, bytes);
}

fn readJsonBody(allocator: std.mem.Allocator, request: *http.Server.Request) ![]u8 {
    const content_type = request.head.content_type orelse return error.UnsupportedMediaType;
    if (!isJsonContentType(content_type)) return error.UnsupportedMediaType;
    const max_body_bytes = file_api.max_file_bytes + 1024 * 1024;
    if (request.head.content_length) |length| {
        if (length > max_body_bytes) return error.PayloadTooLarge;
    }
    var read_buffer: [16 * 1024]u8 = undefined;
    const reader = try request.readerExpectContinue(&read_buffer);
    return reader.allocRemaining(allocator, .limited(max_body_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.PayloadTooLarge,
        else => |other| other,
    };
}

fn respondApiError(request: *http.Server.Request, err: anyerror) !void {
    const result: struct { status: http.Status, code: []const u8 } = switch (err) {
        error.InvalidJson => .{ .status = .bad_request, .code = "invalid_json" },
        error.InvalidPath => .{ .status = .bad_request, .code = "invalid_path" },
        error.PathNotAuthorOwned => .{ .status = .forbidden, .code = "path_not_author_owned" },
        error.FileNotFound => .{ .status = .not_found, .code = "file_not_found" },
        error.PathAlreadyExists => .{ .status = .conflict, .code = "path_already_exists" },
        error.ReadOnly => .{ .status = .conflict, .code = "read_only" },
        error.ConfirmationRequired => .{ .status = .conflict, .code = "confirmation_required" },
        error.InvalidFingerprint => .{ .status = .bad_request, .code = "invalid_fingerprint" },
        error.InvalidUtf8 => .{ .status = .unprocessable_entity, .code = "invalid_utf8" },
        error.FileTooLarge, error.SnapshotTooLarge, error.PayloadTooLarge => .{ .status = .payload_too_large, .code = "payload_too_large" },
        error.UnsupportedMediaType => .{ .status = .unsupported_media_type, .code = "unsupported_media_type" },
        error.TooManyFiles => .{ .status = .payload_too_large, .code = "too_many_files" },
        error.CorruptRecovery => .{ .status = .internal_server_error, .code = "corrupt_recovery" },
        error.ImpactIdRequired, error.UnexpectedImpactId, error.InvalidImpactId => .{ .status = .bad_request, .code = "invalid_command_request" },
        error.UnsupportedArtifact => .{ .status = .bad_gateway, .code = "unsupported_boris_artifact" },
        error.InvalidBorisVersion => .{ .status = .bad_gateway, .code = "invalid_boris_version" },
        error.BorisUnavailable => .{ .status = .service_unavailable, .code = "boris_unavailable" },
        error.UnsafeArtifact, error.SymLinkLoop => .{ .status = .conflict, .code = "unsafe_artifact_path" },
        else => .{ .status = .internal_server_error, .code = "io_error" },
    };
    var buffer: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&buffer, "{{\"error\":\"{s}\"}}", .{result.code}) catch unreachable;
    return respondJson(request, result.status, body);
}

fn isReadMethod(method: http.Method) bool {
    return method == .GET or method == .HEAD;
}

fn isJsonContentType(value: []const u8) bool {
    const media_type = "application/json";
    if (!std.ascii.startsWithIgnoreCase(value, media_type)) return false;
    return value.len == media_type.len or value[media_type.len] == ';';
}

fn methodNotAllowed(request: *http.Server.Request, allow: []const u8) !void {
    const headers = [_]http.Header{.{ .name = "allow", .value = allow }};
    try request.respond("Method not allowed", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &headers });
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

fn serveUiFile(io: Io, allocator: std.mem.Allocator, request: *http.Server.Request, ui_dir_path: []const u8, relative_path: []const u8, html: bool, preview_port: u16) !void {
    var ui_dir = Io.Dir.cwd().openDir(io, ui_dir_path, .{}) catch {
        return respondText(request, .service_unavailable, "Editor UI is not built", "text/plain; charset=utf-8", preview_port);
    };
    defer ui_dir.close(io);
    const bytes = ui_dir.readFileAlloc(io, relative_path, allocator, .limited(16 * 1024 * 1024)) catch {
        return respondText(request, .not_found, "Not found", "text/plain; charset=utf-8", preview_port);
    };
    defer allocator.free(bytes);
    return respondText(request, .ok, bytes, if (html) "text/html; charset=utf-8" else contentType(relative_path), preview_port);
}

fn respondJson(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &headers });
}

fn respondText(request: *http.Server.Request, status: http.Status, body: []const u8, content_type: []const u8, preview_port: u16) !void {
    var csp_buffer: [256]u8 = undefined;
    const csp = std.fmt.bufPrint(&csp_buffer, "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-src 'self' http://127.0.0.1:{d}; connect-src 'self'; base-uri 'none'; form-action 'none'", .{preview_port}) catch unreachable;
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "content-security-policy", .value = csp },
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
