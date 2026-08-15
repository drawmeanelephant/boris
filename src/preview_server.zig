//! Local preview HTTP server for `boris watch --serve` (#392).
//!
//! Loopback-only static file server over `std.Io.net`. A background accept
//! thread owns the listener; each accepted connection is handled on its own
//! thread, because SSE clients hold the connection open and handling inline
//! would stall the accept loop. The watch loop drives reloads through a
//! generation counter: `notifyRebuild` bumps it after every successful
//! rebuild and broadcasts, and every connected `/__boris/events` client
//! wakes, compares generations, and emits an SSE `reload` event when it
//! changed.
//!
//! Routes:
//!   `/`               static files under the served root (`index.html` default)
//!   `/__boris/`       helper page (site iframe + EventSource), generated on the fly
//!   `/__boris/events` SSE stream
//!
//! Artifacts on disk are never modified: the helper page and SSE stream are
//! server-generated responses only, and static responses are served with
//! `cache-control: no-store` so the reloaded page always reads fresh bytes.
//! Targets are served only when they are safe relative paths — no `..`,
//! backslashes, percent escapes, or non-ASCII bytes.

const std = @import("std");
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
    /// Bumped under `mutex` after each successful rebuild; SSE clients
    /// compare against their last-seen value.
    generation: u64 = 0,
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

    /// Signal a successful rebuild: bump the generation and wake SSE clients.
    pub fn notifyRebuild(self: *Server) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
            self.wakeAccept();
            self.listener.socket.close(self.io);
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
        self.gpa.free(self.root_path);
        self.* = undefined;
    }
};

fn acceptLoop(self: *Server) void {
    while (!self.shutdown.load(.monotonic)) {
        const stream = self.listener.accept(self.io) catch {
            if (self.shutdown.load(.monotonic)) break;
            // Transient accept failures (fd pressure, etc.): back off briefly.
            Io.sleep(self.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
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

    request.respond(bytes, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = contentType(rel) },
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
    // first event and only reloads on a *change*.
    //
    // `BodyWriter.flush` only flushes the underlying output; the chunked
    // `bw.writer` must be flushed first so its buffered frame actually drains
    // to the socket.
    var last: u64 = self.generation;
    bw.writer.print("event: reload\ndata: {d}\n\n", .{last}) catch {
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

    while (!self.shutdown.load(.monotonic)) {
        self.mutex.lockUncancelable(self.io);
        const gen = self.generation;
        if (gen != last) {
            self.mutex.unlock(self.io);
            last = gen;
            bw.writer.print("event: reload\ndata: {d}\n\n", .{gen}) catch break;
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
    \\let last = null;
    \\es.addEventListener('reload', (e) => {
    \\  const g = Number(e.data);
    \\  if (last === null) { last = g; return; }  // initial sync, no reload
    \\  if (g === last) return;
    \\  last = g;
    \\  const f = document.getElementById('site');
    \\  if (f && f.contentWindow) f.contentWindow.location.reload();
    \\});
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

        server.notifyRebuild();

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

            server.notifyRebuild();

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
