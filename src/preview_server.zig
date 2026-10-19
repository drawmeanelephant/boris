//! Local preview HTTP server for `boris watch --serve` (#392).
//!
//! Loopback-only static file server over `std.Io.net`. A background accept
//! thread owns the listener; each accepted connection is handled on its own
//! thread, because SSE clients hold the connection open and handling inline
//! would stall the accept loop. The watch loop drives reloads through a
//! generation counter: `notifyRebuild` bumps it after every successful
//! rebuild and `notifyBuildFailed` bumps it after every failed one, then
//! broadcasts; every connected `/__boris/events` client wakes, compares
//! generations, and emits an SSE `reload` or `stale` event when it changed.
//!
//! Routes:
//!   `/`               static files under the served root (`index.html` default)
//!   `/__boris/`       helper page (site iframe + EventSource), generated on the fly
//!   `/__boris/events` SSE stream (`reload` after a successful rebuild,
//!                     `stale` after a failed one)
//!   `/__boris/status` build-state JSON (`{state, stale_reason, last_error,
//!                     last_build_ms}`) for external tooling (#1114)
//!
//! Artifacts on disk are never modified: the helper page, SSE stream, status
//! response, and the stale banner injected into served HTML while the last
//! build is failed are server-generated responses only, and static responses
//! are served with `cache-control: no-store` so the reloaded page always reads
//! fresh bytes.
//! Targets are served only when they are safe relative paths — no `..`,
//! backslashes, percent escapes, or non-ASCII bytes.

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const Io = std.Io;

/// Default loopback port for `--serve` (override with `--port N`).
pub const default_port: u16 = 8090;

const max_static_bytes: usize = 64 * 1024 * 1024;

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Owned copy of the served root (duped in `init`).
    root_path: []const u8,
    /// Opened lazily on the first request: `watch --serve` binds before the
    /// initial build creates the output directory, so the dir may not exist
    /// at `init` time (and a recoverable failed build may never create it).
    root_dir: ?Io.Dir = null,
    listener: Io.net.Server,
    bound_port: u16,
    /// Bumped under `mutex` after each completed rebuild (success or
    /// failure); SSE clients compare against their last-seen value.
    generation: u64 = 0,
    /// Last completed build cycle's outcome, guarded by `mutex`. When
    /// `build_failed` is set, `/__boris/status` reports `state:"failed"`,
    /// SSE clients get `stale` events, and served HTML carries the stale
    /// banner (#1114).
    build_failed: bool = false,
    /// Owned one-line summary of the last failure (the first error
    /// diagnostic in prose form, or the error name). `null` when the last
    /// build succeeded or no diagnostic was collected.
    last_error: ?[]u8 = null,
    /// Wall time of the last completed build cycle; `null` before the first.
    last_build_ms: ?u64 = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    accept_thread: ?std.Thread = null,
    /// Number of handler threads currently alive (guards `stop` teardown).
    active_handlers: usize = 0,
    /// The listener socket is closed once by `stop` (to unblock a pending
    /// accept); `deinit` must not close it again (EBADF in Debug).
    listener_closed: bool = false,

    /// Bind a loopback listener on 127.0.0.1. `port == 0` selects an
    /// ephemeral port (reported via `boundPort`). `root_path` is
    /// workspace-relative (the HTML output directory being served).
    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        root_path: []const u8,
        port: u16,
    ) !Server {
        var addr = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
        const listener = try Io.net.IpAddress.listen(&addr, io, .{
            .reuse_address = true,
            .kernel_backlog = 16,
        });
        const owned_root = try gpa.dupe(u8, root_path);
        return .{
            .gpa = gpa,
            .io = io,
            .root_path = owned_root,
            .listener = listener,
            .bound_port = Io.net.IpAddress.getPort(listener.socket.address),
        };
    }

    pub fn boundPort(self: *const Server) u16 {
        return self.bound_port;
    }

    /// Start the accept thread. Call once after `init`.
    pub fn start(self: *Server) !void {
        if (self.accept_thread != null) return;
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Signal a successful rebuild: clear the stale flag, record the cycle's
    /// wall time, bump the generation, and wake SSE clients.
    pub fn notifyRebuild(self: *Server, duration_ms: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.build_failed = false;
        self.last_build_ms = duration_ms;
        if (self.last_error) |old| {
            self.gpa.free(old);
            self.last_error = null;
        }
        self.generation +%= 1;
        self.cond.broadcast(self.io);
    }

    /// Signal a failed rebuild (#1114): mark the served tree stale, record a
    /// one-line diagnostic summary and the cycle's wall time, bump the
    /// generation, and wake SSE clients (they emit `stale`, not `reload`).
    /// `summary` may be empty when no structured diagnostic was collected.
    pub fn notifyBuildFailed(self: *Server, summary: []const u8, duration_ms: u64) void {
        const owned: ?[]u8 = if (summary.len > 0)
            self.gpa.dupe(u8, summary) catch null
        else
            null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.build_failed = true;
        self.last_build_ms = duration_ms;
        if (self.last_error) |old| self.gpa.free(old);
        self.last_error = owned;
        self.generation +%= 1;
        self.cond.broadcast(self.io);
    }

    /// Best-effort probe connection to our own listener so a blocked
    /// `accept()` returns (see `stop`). The kernel completes the handshake
    /// into the listen backlog, so this connect never blocks; the accept loop
    /// drains it, sees `shutdown`, and exits. Any failure is ignorable: the
    /// accept loop also exits when the listener is closed afterwards.
    fn wakeAccept(self: *Server) void {
        var addr = Io.net.IpAddress.parseIp4("127.0.0.1", self.bound_port) catch return;
        var conn = addr.connect(self.io, .{ .mode = .stream }) catch return;
        conn.close(self.io);
    }

    /// Open the served root on first use (cached for the server lifetime).
    fn rootDir(self: *Server) !Io.Dir {
        if (self.root_dir) |d| return d;
        const d = try Io.Dir.cwd().openDir(self.io, self.root_path, .{});
        self.root_dir = d;
        return d;
    }

    /// Stop accepting, unblock the accept loop, join the accept thread, and
    /// wait (bounded) for in-flight handlers. Safe to call twice; does not
    /// free `root_path`/`listener` (see `deinit`).
    pub fn stop(self: *Server) void {
        self.shutdown.store(true, .monotonic);
        self.mutex.lockUncancelable(self.io);
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        // Unblock the accept loop portably. Closing the listener socket alone
        // does NOT reliably wake a thread blocked in accept(): it does on
        // BSD/macOS (the accept errors out with EBADF) but on Linux the
        // blocked accept(2) keeps waiting on the closed description, which
        // would wedge the join below. A self-connect makes accept() return a
        // real connection; the loop sees `shutdown` and exits. The listener is
        // still closed afterwards (harmless once the loop is gone).
        if (!self.listener_closed) {
            self.listener_closed = true;
            if (comptime builtin.os.tag == .windows) {
                // Windows accept is overlapped: closing the socket while an
                // accept is in flight completes it with INVALID_HANDLE and
                // panics inside std's cleanup path. Wake with a
                // self-connect, join the loop first, then close.
                self.wakeAccept();
                if (self.accept_thread) |t| {
                    t.join();
                    self.accept_thread = null;
                }
                self.listener.socket.close(self.io);
            } else {
                self.wakeAccept();
                self.listener.socket.close(self.io);
            }
        }
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
        // Bounded drain: a wedged handler must not hang teardown.
        var waited: usize = 0;
        while (waited < 2000) {
            self.mutex.lockUncancelable(self.io);
            const n = self.active_handlers;
            self.mutex.unlock(self.io);
            if (n == 0) break;
            Io.sleep(self.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            waited += 10;
        }
    }

    pub fn deinit(self: *Server) void {
        // `stop` closes the listener socket (unblocking the accept loop); the
        // socket must not be closed again here.
        self.stop();
        if (self.root_dir) |d| d.close(self.io);
        if (self.last_error) |e| self.gpa.free(e);
        self.gpa.free(self.root_path);
        self.* = undefined;
    }
};

fn acceptLoop(self: *Server) void {
    var consecutive_failures: usize = 0;
    while (!self.shutdown.load(.monotonic)) {
        const stream = self.listener.accept(self.io) catch {
            if (self.shutdown.load(.monotonic)) break;
            // Transient accept failures (fd pressure, etc.): back off briefly.
            // On Windows a listener that has gone bad keeps returning
            // INVALID_HANDLE forever — bound the retries instead of spinning
            // on an unusable socket. POSIX keeps retrying indefinitely.
            consecutive_failures += 1;
            if (comptime builtin.os.tag == .windows) {
                if (consecutive_failures >= 32) break;
            }
            Io.sleep(self.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        consecutive_failures = 0;
        if (self.shutdown.load(.monotonic)) {
            stream.close(self.io);
            break;
        }
        self.mutex.lockUncancelable(self.io);
        self.active_handlers += 1;
        self.mutex.unlock(self.io);
        const thread = std.Thread.spawn(.{}, handlerEntry, .{ self, stream }) catch {
            self.mutex.lockUncancelable(self.io);
            self.active_handlers -= 1;
            self.mutex.unlock(self.io);
            stream.close(self.io);
            continue;
        };
        thread.detach();
    }
}

fn handlerEntry(self: *Server, stream: Io.net.Stream) void {
    defer {
        self.mutex.lockUncancelable(self.io);
        self.active_handlers -= 1;
        self.mutex.unlock(self.io);
        self.cond.broadcast(self.io);
    }
    handleConnection(self, stream);
}

fn handleConnection(self: *Server, stream: Io.net.Stream) void {
    defer stream.close(self.io);
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var io_reader = stream.reader(self.io, &read_buf);
    var io_writer = stream.writer(self.io, &write_buf);
    var server = http.Server.init(&io_reader.interface, &io_writer.interface);

    var request = server.receiveHead() catch return;
    if (request.head.method != .GET and request.head.method != .HEAD) {
        request.respond("method not allowed", .{
            .status = .method_not_allowed,
            .keep_alive = false,
            .extra_headers = &plain_headers,
        }) catch {};
        return;
    }

    const target = request.head.target;
    if (std.mem.eql(u8, target, "/__boris/events")) {
        handleSse(self, &request);
        return;
    }
    if (std.mem.eql(u8, target, "/__boris/status")) {
        handleStatus(self, &request);
        return;
    }
    if (std.mem.eql(u8, target, "/__boris") or std.mem.eql(u8, target, "/__boris/")) {
        request.respond(helper_page, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        }) catch {};
        return;
    }
    handleStatic(self, &request, target);
}

const plain_headers = [_]http.Header{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }};

/// `GET /__boris/status` (#1114): machine-readable build state for the
/// served tree, so external tooling (and authors) can tell the preview is
/// stale without reading watch-process stderr.
///
/// `{"state":"ok","stale_reason":null,"last_error":null,"last_build_ms":45}`
/// `{"state":"failed","stale_reason":"failed_rebuild","last_error":"error: EPARENTMISSING: …","last_build_ms":12}`
///
/// `stale_reason` shares vocabulary with the editor host's
/// `/api/preview/state` (docs/contracts/editor-host.md): `"failed_rebuild"`
/// names "the last build failed and the served tree is the previous good
/// output". `last_error` is the first error diagnostic in prose form
/// (`error: CODE: path:line:col: message`), `null` when no diagnostic was
/// collected or the last build succeeded. `last_build_ms` is `null` until
/// the first cycle completes.
fn handleStatus(self: *Server, request: *http.Server.Request) void {
    self.mutex.lockUncancelable(self.io);
    const failed = self.build_failed;
    const last_ms = self.last_build_ms;
    const err_copy: ?[]u8 = if (self.last_error) |e| self.gpa.dupe(u8, e) catch null else null;
    self.mutex.unlock(self.io);
    defer if (err_copy) |e| self.gpa.free(e);

    const Sink = @import("structured_out.zig").Sink;
    var sink = Sink.init(self.gpa);
    defer sink.deinit();
    sink.lit("{\"state\":") catch return;
    sink.jsonString(if (failed) "failed" else "ok") catch return;
    sink.lit(",\"stale_reason\":") catch return;
    if (failed) sink.jsonString("failed_rebuild") catch return else sink.lit("null") catch return;
    sink.lit(",\"last_error\":") catch return;
    if (err_copy) |e| sink.jsonString(e) catch return else sink.lit("null") catch return;
    sink.lit(",\"last_build_ms\":") catch return;
    if (last_ms) |ms| sink.num(@intCast(ms)) catch return else sink.lit("null") catch return;
    sink.lit("}") catch return;

    request.respond(sink.items(), .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    }) catch {};
}

/// Append `s` to `list` with HTML special characters escaped for element
/// content (`&`, `<`, `>`).
fn appendHtmlEscaped(list: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try list.appendSlice(gpa, "&amp;"),
            '<' => try list.appendSlice(gpa, "&lt;"),
            '>' => try list.appendSlice(gpa, "&gt;"),
            else => try list.append(gpa, c),
        }
    }
}

/// Render the stale-preview banner injected into served HTML while the last
/// build is failed (#1114). Fixed-position top bar; the diagnostic summary is
/// escaped for element content. Returns a gpa-owned slice.
fn renderStaleBanner(gpa: std.mem.Allocator, summary: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "<div id=\"__boris-stale\" role=\"alert\" style=\"position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#8f1d1d;color:#fff;padding:8px 14px;font:13px/1.45 system-ui,sans-serif;box-shadow:0 1px 4px rgba(0,0,0,.5);\">Boris preview is stale: the last rebuild failed.");
    if (summary.len > 0) {
        try list.appendSlice(gpa, " <code style=\"font:inherit;color:#ffd7d7;\">");
        try appendHtmlEscaped(&list, gpa, summary);
        try list.appendSlice(gpa, "</code>");
    }
    try list.appendSlice(gpa, " Fix the error and save; this is the last good build.</div>");
    return list.toOwnedSlice(gpa);
}

/// First index of `needle` in `haystack`, ASCII case-insensitive. Used to
/// locate `<body>` in served HTML without assuming a casing convention.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// First index of a `<body` open tag in `html` (ASCII case-insensitive);
/// the byte after `body` must end the tag or start an attribute so
/// `<bodyguard`-style element names do not match.
fn bodyTagStart(html: []const u8) ?usize {
    var from: usize = 0;
    while (indexOfIgnoreCase(html[from..], "<body")) |hit| {
        const start = from + hit;
        const next = start + "<body".len;
        if (next >= html.len) return null;
        switch (html[next]) {
            '>', ' ', '\t', '\n', '\r', '/' => return start,
            else => {
                from = next;
                continue;
            },
        }
    }
    return null;
}

/// Splice `banner` into `html` immediately after the `<body …>` open tag,
/// falling back to the top of the document when no body tag exists. The
/// banner is `position:fixed`, so either anchor renders identically.
/// Returns a gpa-owned slice.
fn injectBanner(gpa: std.mem.Allocator, html: []const u8, banner: []const u8) ![]u8 {
    var at: usize = 0;
    if (bodyTagStart(html)) |body_start| {
        if (std.mem.indexOfScalarPos(u8, html, body_start, '>')) |close| {
            at = close + 1;
        }
    }
    var out = try gpa.alloc(u8, html.len + banner.len);
    @memcpy(out[0..at], html[0..at]);
    @memcpy(out[at..][0..banner.len], banner);
    @memcpy(out[at + banner.len ..], html[at..]);
    return out;
}

/// When the last build failed, return `bytes` with the stale banner spliced
/// in (gpa-owned); `null` when the build state is ok or on allocation
/// failure (serve the file unmodified — a dev preview must never 500 on
/// banner bookkeeping).
fn maybeInjectStaleBanner(self: *Server, bytes: []const u8) ?[]u8 {
    self.mutex.lockUncancelable(self.io);
    const failed = self.build_failed;
    const err_copy: ?[]u8 = if (failed and self.last_error != null)
        self.gpa.dupe(u8, self.last_error.?) catch null
    else
        null;
    self.mutex.unlock(self.io);
    if (!failed) return null;
    defer if (err_copy) |e| self.gpa.free(e);

    const banner = renderStaleBanner(self.gpa, err_copy orelse "") catch return null;
    defer self.gpa.free(banner);
    return injectBanner(self.gpa, bytes, banner) catch null;
}

fn handleStatic(self: *Server, request: *http.Server.Request, target: []const u8) void {
    var rel = stripQueryFragment(target);
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) rel = "index.html"; // `/` serves the site root
    if (!isSafeTarget(rel)) {
        notFound(request);
        return;
    }

    const root_dir = self.rootDir() catch {
        notFound(request);
        return;
    };
    var file = root_dir.openFile(self.io, rel, .{}) catch |open_err| switch (open_err) {
        error.FileNotFound, error.NotDir, error.IsDir => blk: {
            // Directory-style targets (`/guides/` or `/guides`) fall back to
            // `index.html` under the same prefix.
            var dir = rel;
            while (dir.len > 0 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
            const idx = std.fmt.allocPrint(self.gpa, "{s}/index.html", .{dir}) catch {
                notFound(request);
                return;
            };
            defer self.gpa.free(idx);
            break :blk root_dir.openFile(self.io, idx, .{}) catch {
                notFound(request);
                return;
            };
        },
        else => {
            notFound(request);
            return;
        },
    };
    defer file.close(self.io);

    var reader = file.reader(self.io, &.{});
    const bytes = reader.interface.allocRemaining(self.gpa, .limited(max_static_bytes)) catch {
        notFound(request);
        return;
    };
    defer self.gpa.free(bytes);

    const ct = contentType(rel);
    var body: []const u8 = bytes;
    var bannered: ?[]u8 = null;
    defer if (bannered) |b| self.gpa.free(b);
    if (std.mem.eql(u8, ct, "text/html; charset=utf-8")) {
        bannered = maybeInjectStaleBanner(self, bytes);
        if (bannered) |b| body = b;
    }

    request.respond(body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = ct },
            .{ .name = "cache-control", .value = "no-store" },
        },
    }) catch {};
}

fn notFound(request: *http.Server.Request) void {
    request.respond("404 not found\n", .{
        .status = .not_found,
        .keep_alive = false,
        .extra_headers = &plain_headers,
    }) catch {};
}

fn handleSse(self: *Server, request: *http.Server.Request) void {
    var chunk_buf: [1024]u8 = undefined;
    var bw = request.respondStreaming(&chunk_buf, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = true,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        },
    }) catch return;

    // Send the current generation on connect so a (re)connecting client can
    // resync without a missed-rebuild gap; the helper page suppresses the
    // first event and only reloads on a *change*. The event name reflects
    // the current build state: `stale` while the last build is failed,
    // `reload` otherwise (#1114).
    //
    // `BodyWriter.flush` only flushes the underlying output; the chunked
    // `bw.writer` must be flushed first so its buffered frame actually drains
    // to the socket.
    self.mutex.lockUncancelable(self.io);
    const last: u64 = self.generation;
    const failed_at_connect = self.build_failed;
    self.mutex.unlock(self.io);
    bw.writer.print("event: {s}\ndata: {d}\n\n", .{ if (failed_at_connect) "stale" else "reload", last }) catch {
        bw.end() catch {};
        return;
    };
    bw.writer.flush() catch {
        bw.end() catch {};
        return;
    };
    bw.flush() catch {
        bw.end() catch {};
        return;
    };

    var seen: u64 = last;
    while (!self.shutdown.load(.monotonic)) {
        self.mutex.lockUncancelable(self.io);
        const gen = self.generation;
        const failed = self.build_failed;
        if (gen != seen) {
            self.mutex.unlock(self.io);
            seen = gen;
            bw.writer.print("event: {s}\ndata: {d}\n\n", .{ if (failed) "stale" else "reload", gen }) catch break;
            bw.writer.flush() catch break;
            bw.flush() catch break;
            continue;
        }
        self.cond.waitUncancelable(self.io, &self.mutex);
        self.mutex.unlock(self.io);
    }
    bw.end() catch {};
}

fn stripQueryFragment(target: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, target, "?#")) |idx| return target[0..idx];
    return target;
}

/// Servable targets are plain relative ASCII paths: no `..`, backslashes,
/// percent escapes, NUL/control bytes, or empty segments (`//`).
fn isSafeTarget(rel: []const u8) bool {
    if (rel.len == 0) return true; // served as index.html
    for (rel) |c| {
        if (c < 0x20 or c > 0x7e) return false;
    }
    if (std.mem.indexOf(u8, rel, "..") != null) return false;
    if (std.mem.indexOfScalar(u8, rel, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, rel, '%') != null) return false;
    if (std.mem.indexOf(u8, rel, "//") != null) return false;
    return true;
}

fn contentType(rel: []const u8) []const u8 {
    const ext = std.fs.path.extension(rel);
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".xml")) return "application/xml";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    return "application/octet-stream";
}

const helper_page =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<title>Boris preview</title>
    \\<style>
    \\  body{margin:0;font:13px/1.5 system-ui,sans-serif;background:#111;color:#ddd}
    \\  #bar{position:fixed;top:0;left:0;right:0;background:#1d2b36;color:#cde;padding:6px 14px;z-index:10;font-size:12px;box-shadow:0 1px 3px #000a}
    \\  #bar a{color:#7cc;text-decoration:none}
    \\  #site{width:100vw;height:100vh;border:0;display:block}
    \\</style>
    \\</head>
    \\<body>
    \\<div id="bar">Boris preview &mdash; auto-reloads after each successful rebuild. <a href="/" target="_blank" rel="noopener">Open site in a new tab</a></div>
    \\<iframe id="site" src="/" title="site preview"></iframe>
    \\<script>
    \\const es = new EventSource('/__boris/events');
    \\const bar = document.getElementById('bar');
    \\const barHtml = bar.innerHTML;
    \\let last = null;
    \\// `reload` follows a successful rebuild; `stale` follows a failed one —
    \\// the served tree is the previous good output plus an injected banner,
    \\// and the bar goes red until the next successful reload (#1114).
    \\function onChange(e, stale) {
    \\  const g = Number(e.data);
    \\  const first = last === null;
    \\  if (!first && g === last) return;
    \\  last = g;
    \\  if (stale) {
    \\    bar.style.background = '#8f1d1d';
    \\    bar.style.color = '#fff';
    \\    bar.textContent = 'Boris preview — last rebuild failed; showing the previous build. Check the watch process output.';
    \\  } else {
    \\    bar.style.background = '';
    \\    bar.style.color = '';
    \\    bar.innerHTML = barHtml;
    \\  }
    \\  if (first) return;  // initial sync, no reload
    \\  const f = document.getElementById('site');
    \\  if (f && f.contentWindow) f.contentWindow.location.reload();
    \\}
    \\es.addEventListener('reload', (e) => onChange(e, false));
    \\es.addEventListener('stale', (e) => onChange(e, true));
    \\</script>
    \\</body>
    \\</html>
    \\
;

test "isSafeTarget rejects traversal and escapes" {
    try std.testing.expect(isSafeTarget(""));
    try std.testing.expect(isSafeTarget("index.html"));
    try std.testing.expect(isSafeTarget("guides/intro.html"));
    try std.testing.expect(!isSafeTarget("../secret"));
    try std.testing.expect(!isSafeTarget("a/../b"));
    try std.testing.expect(!isSafeTarget(".."));
    try std.testing.expect(!isSafeTarget("a\\b"));
    try std.testing.expect(!isSafeTarget("a%2e%2e"));
    try std.testing.expect(!isSafeTarget("a//b"));
    try std.testing.expect(!isSafeTarget("a\x00b"));
    try std.testing.expect(!isSafeTarget("h\xc3\xa9llo.html"));
}

test "stripQueryFragment trims ? and # suffixes" {
    try std.testing.expectEqualStrings("index.html", stripQueryFragment("index.html"));
    try std.testing.expectEqualStrings("index.html", stripQueryFragment("index.html?v=2"));
    try std.testing.expectEqualStrings("a/b.css", stripQueryFragment("a/b.css#x"));
}

test "renderStaleBanner escapes HTML in the diagnostic summary" {
    const gpa = std.testing.allocator;
    const banner = try renderStaleBanner(gpa, "error: EFRONTMATTER: a.md:1:1: bad <key> & \"value\"");
    defer gpa.free(banner);
    try std.testing.expect(std.mem.indexOf(u8, banner, "__boris-stale") != null);
    try std.testing.expect(std.mem.indexOf(u8, banner, "bad &lt;key&gt; &amp; \"value\"") != null);
    // No raw markup from the diagnostic leaks into the injected element.
    try std.testing.expect(std.mem.indexOf(u8, banner, "bad <key>") == null);
}

test "injectBanner splices after <body> and falls back to prepend" {
    const gpa = std.testing.allocator;

    const with_body = try injectBanner(gpa, "<html><body class=\"x\"><p>hi</p></body></html>", "BANNER");
    defer gpa.free(with_body);
    try std.testing.expectEqualStrings("<html><body class=\"x\">BANNER<p>hi</p></body></html>", with_body);

    // Body tag casing is not assumed.
    const upper = try injectBanner(gpa, "<html><BODY>hi</BODY></html>", "BANNER");
    defer gpa.free(upper);
    try std.testing.expectEqualStrings("<html><BODY>BANNERhi</BODY></html>", upper);

    // Fragments without a body still get the banner (fixed-position element).
    const frag = try injectBanner(gpa, "<p>hi</p>", "BANNER");
    defer gpa.free(frag);
    try std.testing.expectEqualStrings("BANNER<p>hi</p>", frag);

    // A `<body`-prefixed element name is not the body tag.
    const not_body = try injectBanner(gpa, "<bodyguard>x</bodyguard><body>y</body>", "BANNER");
    defer gpa.free(not_body);
    try std.testing.expectEqualStrings("<bodyguard>x</bodyguard><body>BANNERy</body>", not_body);
}

// #1114: a failed rebuild must be visible from the preview itself — the
// status endpoint reports `failed`, served HTML carries the stale banner,
// and SSE clients get a `stale` event instead of `reload`.
test "preview server reports failed build via status, banner, and stale event" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-1114-serve", .{tmp.sub_path});
    defer gpa.free(root_path);
    try tmp.dir.createDirPath(io, "boris-1114-serve/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "boris-1114-serve/index.html", .data = "<html><body><h1>hi</h1></body></html>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "boris-1114-serve/assets/site.css", .data = "body{}" });

    var server = try Server.init(gpa, io, root_path, 0);
    defer server.deinit();
    try server.start();
    const port = server.boundPort();
    var addr = try Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Before any build completes: state ok, null fields.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /__boris/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"state\":\"ok\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"stale_reason\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"last_build_ms\":null") != null);
    }

    server.notifyRebuild(45);
    server.notifyBuildFailed("error: EPARENTMISSING: about.md:4:1: parent \"nope\" does not exist", 12);

    // Failed state: status JSON names the failure in editor vocabulary.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /__boris/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"state\":\"failed\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"stale_reason\":\"failed_rebuild\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"last_error\":\"error: EPARENTMISSING: about.md:4:1: parent \\\"nope\\\" does not exist\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"last_build_ms\":12") != null);
    }

    // Served HTML carries the visible banner; non-HTML is untouched.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "__boris-stale") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "parent \"nope\" does not exist") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "EPARENTMISSING") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "<body>") != null);
    }
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /assets/site.css HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "__boris-stale") == null);
    }

    // SSE: a mid-stream failure emits `stale`, not `reload`.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /__boris/events HTTP/1.1\r\nHost: localhost\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        // Connect-time sync event reflects the already-failed state.
        var buf: [4096]u8 = undefined;
        try std.testing.expect(try readUntil(&reader.interface, &buf, "event: stale"));

        server.notifyRebuild(30);
        var buf2: [4096]u8 = undefined;
        try std.testing.expect(try readUntil(&reader.interface, &buf2, "event: reload"));
    }

    // Recovery: status clears and the banner is gone from served HTML.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /__boris/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"state\":\"ok\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"last_error\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "\"last_build_ms\":30") != null);
    }
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "__boris-stale") == null);
    }
}

/// Read until `needle` appears (or the buffer fills), returning whether it
/// was found. Uses `readVec` so a single call never blocks for the full
/// buffer — SSE keep-alive connections never send EOF.
fn readVecOrEof(reader: *Io.Reader, buf: []u8) !usize {
    var vecs = [_][]u8{buf};
    return reader.readVec(&vecs) catch |err| switch (err) {
        // The peer closed the connection cleanly.
        error.EndOfStream => 0,
        else => return err,
    };
}

fn readUntil(reader: *Io.Reader, buf: []u8, needle: []const u8) !bool {
    var n: usize = 0;
    while (n < buf.len) {
        const got = try readVecOrEof(reader, buf[n..]);
        if (got == 0) return false;
        n += got;
        if (std.mem.indexOf(u8, buf[0..n], needle) != null) return true;
    }
    return false;
}

/// Read a `Connection: close` response to EOF (the server closes after each
/// static/404 response), appending to `list`.
fn slurpToEof(reader: *Io.Reader, gpa: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = try readVecOrEof(reader, scratch[0..]);
        if (got == 0) return;
        try list.appendSlice(gpa, scratch[0..got]);
    }
}

// Live loopback test: static serving, 404s, and the SSE reload event.
test "preview server serves files and pushes reload events" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-392-serve", .{tmp.sub_path});
    defer gpa.free(root_path);
    try tmp.dir.createDirPath(io, "boris-392-serve/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "boris-392-serve/index.html", .data = "<h1>hi</h1>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "boris-392-serve/assets/site.css", .data = "body{}" });

    var server = try Server.init(gpa, io, root_path, 0);
    defer server.deinit();
    try server.start();
    const port = server.boundPort();
    try std.testing.expect(port != 0);

    var addr = try Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // 1. Static file with content-length.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "<h1>hi</h1>") != null);
    }

    // 2. 404 for a missing file.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /nope.html HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "404") != null);
    }

    // 3. Traversal is rejected with 404.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /../secret HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        try slurpToEof(&reader.interface, gpa, &got);
        try std.testing.expect(std.mem.indexOf(u8, got.items, "404") != null);
    }

    // 4. SSE: connect, then a rebuild bumps the generation and pushes an event.
    {
        var conn = try addr.connect(io, .{ .mode = .stream });
        defer conn.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = conn.writer(io, &wbuf);
        try writer.interface.writeAll("GET /__boris/events HTTP/1.1\r\nHost: localhost\r\n\r\n");
        try writer.interface.flush();
        var rbuf: [8192]u8 = undefined;
        var reader = conn.reader(io, &rbuf);
        var buf: [4096]u8 = undefined;
        try std.testing.expect(try readUntil(&reader.interface, &buf, "event: reload"));

        server.notifyRebuild(9);

        var buf2: [4096]u8 = undefined;
        try std.testing.expect(try readUntil(&reader.interface, &buf2, "event: reload"));
    }
}

// Teardown stress guard: repeated start/stop cycles must never wedge the
// accept thread or the handler drain. On Linux, closing the listener socket
// alone does not reliably unblock a thread blocked in accept(2) — stop()
// self-connects (`wakeAccept`) to make the accept loop exit — so this test
// hammers that path: a real request every cycle, an SSE connection held open
// across `stop()` every few cycles (the handler is blocked in cond.wait and
// must be woken by broadcast), an explicit stop followed by deinit's stop
// (double-stop is documented safe), and a never-started server.
test "preview server: repeated start/stop cycles tear down cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-392-serve", .{tmp.sub_path});
    defer gpa.free(root_path);
    try tmp.dir.createDirPath(io, "boris-392-serve");
    try tmp.dir.writeFile(io, .{ .sub_path = "boris-392-serve/index.html", .data = "<h1>hi</h1>" });

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var server = try Server.init(gpa, io, root_path, 0);
        defer server.deinit();
        try server.start();
        const port = server.boundPort();
        try std.testing.expect(port != 0);
        var addr = try Io.net.IpAddress.parseIp4("127.0.0.1", port);

        // A real request every cycle: the accept loop has work and a handler
        // thread is alive when teardown runs.
        {
            var conn = try addr.connect(io, .{ .mode = .stream });
            defer conn.close(io);
            var wbuf: [4096]u8 = undefined;
            var writer = conn.writer(io, &wbuf);
            try writer.interface.writeAll("GET /index.html HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();
            var rbuf: [8192]u8 = undefined;
            var reader = conn.reader(io, &rbuf);
            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(gpa);
            try slurpToEof(&reader.interface, gpa, &got);
            try std.testing.expect(std.mem.indexOf(u8, got.items, "200 OK") != null);
        }

        if (i % 5 == 0) {
            // Hold an SSE client open across stop(): the handler is blocked
            // in cond.wait, so teardown must wake it via broadcast before the
            // bounded handler drain can finish.
            var conn = try addr.connect(io, .{ .mode = .stream });
            defer conn.close(io);
            var wbuf: [4096]u8 = undefined;
            var writer = conn.writer(io, &wbuf);
            try writer.interface.writeAll("GET /__boris/events HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();
            var rbuf: [8192]u8 = undefined;
            var reader = conn.reader(io, &rbuf);
            var buf: [4096]u8 = undefined;
            try std.testing.expect(try readUntil(&reader.interface, &buf, "event: reload"));

            server.notifyRebuild(9);

            var buf2: [4096]u8 = undefined;
            try std.testing.expect(try readUntil(&reader.interface, &buf2, "event: reload"));

            // Explicit stop while the SSE connection is still open, then
            // deinit()'s own stop() runs again (double-stop is safe).
            server.stop();
        } else {
            server.stop();
        }
    }

    // A server that was never started must also tear down cleanly (no accept
    // thread to join; the self-connect just closes the probe).
    {
        var server = try Server.init(gpa, io, root_path, 0);
        server.deinit();
    }
}
