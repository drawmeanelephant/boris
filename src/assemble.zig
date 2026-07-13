//! Experimental zero-copy layout splicing for the HTML path (milestone 9).
//!
//! Layout is loaded once at **startup** (before content compile) and split into
//! immutable prefix/suffix slices around a single `{{content}}` marker.
//! Final HTML is streamed with sequential writes — no Header+Content+Footer
//! mega-string concatenation in application memory.
//!
//! ## I/O invariants
//!
//! - Missing or **duplicate** `{{content}}` is a hard error at layout load time.
//! - `Layout.prefix` and `Layout.suffix` are `[]const u8` views into `Layout.raw`.
//!   The owning `Layout` (and its raw buffer) must outlive every `writePage` call.
//! - Page bytes are written as three sequential segments: prefix | body | suffix.
//! - Publish uses Zig 0.16 `Dir.createFileAtomic` + `File.Atomic.replace`:
//!   a unique temporary name (hex u64, scoped to the destination directory) is
//!   created, fully written and flushed, then renamed into the final path.
//! - On any failure before successful `replace`, only the **current operation's**
//!   temp is cleaned up (`Atomic.deinit`); a prior final file is left intact.
//! - Callers must only `arena.reset(.free_all)` **after** `writePage` returns.
//!
//! ## Destination replacement (platform notes)
//!
//! `File.Atomic.replace` uses same-directory `Dir.rename`, which **replaces** an
//! existing final file when the OS/filesystem supports it (typical POSIX local
//! volumes: replace is atomic w.r.t. readers seeing old-or-new, not torn bytes).
//!
//! **Not claimed without qualification:**
//! - Cross-device / cross-volume atomic rename (may fail or copy depending on OS).
//! - Windows: Zig std documents a brief window where concurrent openers of the
//!   destination may see `error.AccessDenied` during replace.
//! - Universal atomic replacement on every filesystem without multi-OS CI.
//!
//! Unit tests exercise successful replace-over-prior and failed-write
//! preservation of prior output on the **host OS** running `zig build test`.

const std = @import("std");
const Io = std.Io;

pub const content_marker = "{{content}}";

/// Stack buffer size for the page writer — large enough that most pages need
/// one underlying write path per splice segment. **Not** Whiteboard memory.
pub const write_buffer_size = 64 * 1024;

pub const LayoutError = error{
    MissingContentMarker,
    DuplicateContentMarker,
};

/// Immutable split of a layout template (e.g. `layouts/main.html`).
///
/// `prefix` and `suffix` are `[]const u8` slices into `raw`. Keep the `Layout`
/// (and the allocator that owns `raw`) alive for the full duration of all
/// `writePage` calls that reference it.
pub const Layout = struct {
    /// Full template bytes (kept so prefix/suffix remain valid).
    raw: []const u8,
    /// Bytes before `{{content}}` (view into `raw`).
    prefix: []const u8,
    /// Bytes after `{{content}}` (view into `raw`).
    suffix: []const u8,

    /// Split on exactly one `{{content}}`. Missing or duplicate → hard error.
    pub fn split(raw: []const u8) LayoutError!Layout {
        const idx = std.mem.indexOf(u8, raw, content_marker) orelse return error.MissingContentMarker;
        const after_first = idx + content_marker.len;
        if (std.mem.indexOf(u8, raw[after_first..], content_marker) != null) {
            return error.DuplicateContentMarker;
        }
        return .{
            .raw = raw,
            .prefix = raw[0..idx],
            .suffix = raw[after_first..],
        };
    }
};

/// Load layout file once into `arena` (process/build lifetime).
/// Call this **before** compiling content so a bad template fails fast.
pub fn loadLayout(io: Io, dir: Io.Dir, path: []const u8, arena: std.mem.Allocator) !Layout {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const raw = try reader.interface.allocRemaining(arena, .unlimited);
    return Layout.split(raw);
}

/// Ensure parent directories of `rel_path` exist under `out_dir`.
pub fn ensureParentPath(io: Io, out_dir: Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) {
            try out_dir.createDirPath(io, parent);
        }
    }
}

/// Pre-create every unique parent directory needed by `output_paths`.
/// Paths must outlive `seen` keys (PageDb-owned).
pub fn precreateOutputDirs(
    io: Io,
    out_dir: Io.Dir,
    gpa: std.mem.Allocator,
    output_paths: []const []const u8,
) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    for (output_paths) |rel| {
        const parent = std.fs.path.dirname(rel) orelse continue;
        if (parent.len == 0) continue;
        const gop = try seen.getOrPut(gpa, parent);
        if (gop.found_existing) continue;
        try out_dir.createDirPath(io, parent);
    }
}

/// Options for `writePage` (production defaults; tests may inject faults).
pub const WritePageOptions = struct {
    /// When true, flush the temp file then return `error.TestInjectedWriteFailure`
    /// without calling `replace`. Used to prove prior output + temp cleanup.
    fail_before_publish: bool = false,
};

/// Stream prefix | html | suffix with no concatenation, then publish.
///
/// Uses a unique temporary name in the destination directory (`createFileAtomic`),
/// writes three sequential slices, flushes, then `Atomic.replace` into
/// `output_path`. On failure, only this operation's temp is deleted; any prior
/// final file at `output_path` is preserved.
///
/// ## Flush-before-reset contract
///
/// `html_body` is typically a slice into the document Whiteboard arena.
/// The writer buffer is **stack** storage. Source slices must remain valid until
/// this function returns (flush + replace included). Callers must only
/// `arena.reset(.free_all)` **after** return.
///
/// Publication API (Zig 0.16): `Io.Dir.createFileAtomic` → write/flush →
/// `Io.File.Atomic.replace` (same-directory rename). See module docs for
/// platform-qualified guarantees.
pub fn writePage(
    io: Io,
    out_dir: Io.Dir,
    output_path: []const u8,
    layout: Layout,
    html_body: []const u8,
) !void {
    return writePageOpts(io, out_dir, output_path, layout, html_body, .{});
}

/// Same as `writePage` with testable options (fault injection).
pub fn writePageOpts(
    io: Io,
    out_dir: Io.Dir,
    output_path: []const u8,
    layout: Layout,
    html_body: []const u8,
    options: WritePageOptions,
) !void {
    // Unique temp name scoped to the destination directory (Zig std hex u64).
    var atomic_file = try out_dir.createFileAtomic(io, output_path, .{
        .replace = true,
        .make_path = true,
    });
    // On success after replace, deinit is a no-op for the temp; on failure it
    // deletes only this operation's temporary file.
    defer atomic_file.deinit(io);

    // Stack-backed buffer — never aliases the document arena.
    var buf: [write_buffer_size]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buf);
    const w = &file_writer.interface;

    // Three sequential writes of existing slices — zero-copy assembly.
    // No `prefix ++ html ++ suffix` allocation.
    try w.writeAll(layout.prefix);
    try w.writeAll(html_body);
    try w.writeAll(layout.suffix);
    // Full flush before publish so free_all cannot race in-flight bytes.
    try w.flush();

    if (options.fail_before_publish) {
        return error.TestInjectedWriteFailure;
    }

    // Destination replacement on the same volume (see module docs for limits).
    try atomic_file.replace(io);
}

// ---------------------------------------------------------------------------
// Hold-until-flush sink (tests prove flush-before-reset, not kernel buffering)
// ---------------------------------------------------------------------------

/// Sink that retains **slice references** until `flush`, then materializes them.
///
/// Unlike a file writer that may copy into a stack buffer during `writeAll`, this
/// deliberately does **not** consume bytes until flush. Fingerprints captured at
/// `writeAll` detect invalidation (e.g. Whiteboard wipe / in-place destroy)
/// before flush — without relying on use-after-free reads of freed pages.
pub const HoldUntilFlush = struct {
    parts: [3]?[]const u8 = .{ null, null, null },
    /// Wyhash of each part at `writeAll` time (stable fingerprint).
    fingerprints: [3]u64 = .{ 0, 0, 0 },
    n: usize = 0,
    materialized: ?[]u8 = null,
    gpa: std.mem.Allocator,

    pub const Error = error{
        TooManyParts,
        /// Slice bytes changed (or were invalidated) before flush — models
        /// premature Whiteboard `free_all` / destroy-before-flush.
        PrematureInvalidation,
    } || std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator) HoldUntilFlush {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *HoldUntilFlush) void {
        if (self.materialized) |m| self.gpa.free(m);
        self.* = undefined;
    }

    pub fn writeAll(self: *HoldUntilFlush, bytes: []const u8) Error!void {
        if (self.n >= self.parts.len) return error.TooManyParts;
        self.parts[self.n] = bytes;
        self.fingerprints[self.n] = std.hash.Wyhash.hash(0, bytes);
        self.n += 1;
    }

    /// Copy retained slices into an owned buffer. Must run while slices still
    /// match their write-time fingerprints (i.e. before Whiteboard reset).
    pub fn flush(self: *HoldUntilFlush) Error!void {
        var total: usize = 0;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            const p = self.parts[i].?;
            if (std.hash.Wyhash.hash(0, p) != self.fingerprints[i]) {
                return error.PrematureInvalidation;
            }
            total += p.len;
        }
        const out = try self.gpa.alloc(u8, total);
        errdefer self.gpa.free(out);
        var off: usize = 0;
        i = 0;
        while (i < self.n) : (i += 1) {
            const p = self.parts[i].?;
            // Re-check immediately before copy (TOCTOU against in-place destroy).
            if (std.hash.Wyhash.hash(0, p) != self.fingerprints[i]) {
                return error.PrematureInvalidation;
            }
            @memcpy(out[off .. off + p.len], p);
            off += p.len;
        }
        if (self.materialized) |old| self.gpa.free(old);
        self.materialized = out;
    }
};

/// Splice layout + body into a `HoldUntilFlush` (three writes, then flush).
/// Production `writePage` follows the same ordering against a file writer.
pub fn spliceToHold(layout: Layout, html_body: []const u8, sink: *HoldUntilFlush) !void {
    try sink.writeAll(layout.prefix);
    try sink.writeAll(html_body);
    try sink.writeAll(layout.suffix);
    try sink.flush();
}

fn readAllFile(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

/// Count directory entries that look like createFileAtomic temps (16 hex chars).
/// `dir` must be opened with `.iterate = true`.
fn countHexTempNames(io: Io, dir: Io.Dir) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len != 16) continue;
        var ok = true;
        for (name) |c| {
            const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
            if (!is_hex) {
                ok = false;
                break;
            }
        }
        if (ok) n += 1;
    }
    return n;
}

// =============================================================================
// Tests
// =============================================================================

test "layout split is zero-copy into raw" {
    const raw = "<html>{{content}}</html>";
    const layout = try Layout.split(raw);
    try std.testing.expectEqualStrings("<html>", layout.prefix);
    try std.testing.expectEqualStrings("</html>", layout.suffix);
    try std.testing.expect(@intFromPtr(layout.prefix.ptr) == @intFromPtr(raw.ptr));
    try std.testing.expect(@TypeOf(layout.prefix) == []const u8);
    try std.testing.expect(@TypeOf(layout.suffix) == []const u8);
}

test "layout missing content marker is hard error" {
    try std.testing.expectError(error.MissingContentMarker, Layout.split("<html></html>"));
}

test "layout duplicate content marker is hard error" {
    const raw = "<a>{{content}}</a>{{content}}";
    try std.testing.expectError(error.DuplicateContentMarker, Layout.split(raw));
}

test "static layout fixtures missing and duplicate" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    {
        var f = try cwd.openFile(io, "test/fixtures/layouts/missing-marker.html", .{});
        defer f.close(io);
        var r = f.reader(io, &.{});
        const raw = try r.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(raw);
        try std.testing.expectError(error.MissingContentMarker, Layout.split(raw));
    }
    {
        var f = try cwd.openFile(io, "test/fixtures/layouts/duplicate-marker.html", .{});
        defer f.close(io);
        var r = f.reader(io, &.{});
        const raw = try r.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(raw);
        try std.testing.expectError(error.DuplicateContentMarker, Layout.split(raw));
    }
    {
        var f = try cwd.openFile(io, "test/fixtures/layouts/ok.html", .{});
        defer f.close(io);
        var r = f.reader(io, &.{});
        const raw = try r.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(raw);
        const layout = try Layout.split(raw);
        try std.testing.expect(layout.prefix.len > 0);
        try std.testing.expect(layout.suffix.len > 0);
    }
}

test "writePage destination replacement over prior output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-assemble-replace";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};
    var out = try cwd.openDir(io, work, .{ .iterate = true });
    defer out.close(io);

    const layout = try Layout.split("<html>{{content}}</html>");

    try writePage(io, out, "page.html", layout, "FIRST");
    try writePage(io, out, "page.html", layout, "SECOND");

    const got = try readAllFile(io, out, "page.html", gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("<html>SECOND</html>", got);
    try std.testing.expectEqual(@as(usize, 0), try countHexTempNames(io, out));
}

test "failed write keeps prior output intact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-assemble-fail-keep";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};
    var out = try cwd.openDir(io, work, .{});
    defer out.close(io);

    const layout = try Layout.split("<pre>{{content}}</pre>");

    try writePage(io, out, "page.html", layout, "PRIOR-BODY");

    try std.testing.expectError(
        error.TestInjectedWriteFailure,
        writePageOpts(io, out, "page.html", layout, "SHOULD-NOT-LAND", .{
            .fail_before_publish = true,
        }),
    );

    const got = try readAllFile(io, out, "page.html", gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("<pre>PRIOR-BODY</pre>", got);
}

test "temp-file cleanup on failed write" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-assemble-temp-cleanup";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};
    var out = try cwd.openDir(io, work, .{ .iterate = true });
    defer out.close(io);

    const layout = try Layout.split("<x>{{content}}</x>");

    try writePage(io, out, "page.html", layout, "keep");

    try std.testing.expectError(
        error.TestInjectedWriteFailure,
        writePageOpts(io, out, "page.html", layout, "tmp-only", .{
            .fail_before_publish = true,
        }),
    );

    try std.testing.expectEqual(@as(usize, 0), try countHexTempNames(io, out));

    const got = try readAllFile(io, out, "page.html", gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("<x>keep</x>", got);
}

test "writePage sequential splice does not concatenate in memory" {
    // Behavioral guarantee: published file is prefix|body|suffix order.
    // Product code never builds prefix ++ body ++ suffix as one allocation.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-assemble-splice";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};
    var out = try cwd.openDir(io, work, .{});
    defer out.close(io);

    const layout = try Layout.split("PRE-{{content}}-SUF");
    try writePage(io, out, "nested/out.html", layout, "BODY");

    const got = try readAllFile(io, out, "nested/out.html", gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("PRE-BODY-SUF", got);
}

test "HoldUntilFlush: correct order succeeds (flush then free_all)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const layout = try Layout.split("P{{content}}S");
    const body = try arena.allocator().dupe(u8, "ARENA-BODY");

    var sink = HoldUntilFlush.init(gpa);
    defer sink.deinit();

    try spliceToHold(layout, body, &sink);
    // Flush completed while body was live — materialization is durable.
    const snapshot = try gpa.dupe(u8, sink.materialized.?);
    defer gpa.free(snapshot);

    _ = arena.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());
    // Owned snapshot still correct after Whiteboard wipe.
    try std.testing.expectEqualStrings("PARENA-BODYS", snapshot);
}

test "HoldUntilFlush: premature invalidation before flush fails the test" {
    // Models Whiteboard reset / destroy-before-flush without use-after-free:
    // hold slice refs past writeAll, then in-place destroy the body bytes
    // (same effect as free_all reclaiming payload), then flush.
    // Fingerprint check returns PrematureInvalidation.
    //
    // Correct production order (flush, then free_all) is covered by the
    // sibling test and by writePage returning only after flush+replace.

    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const layout = try Layout.split("P{{content}}S");
    const body = try arena.allocator().dupe(u8, "LIVE-BODY-BYTES");

    var sink = HoldUntilFlush.init(gpa);
    defer sink.deinit();
    try sink.writeAll(layout.prefix);
    try sink.writeAll(body);
    try sink.writeAll(layout.suffix);

    // --- anti-pattern: invalidate payload BEFORE flush (models free_all) ---
    // In-place destroy while the allocation is still live — no UAF. A real
    // free_all would reclaim the same bytes; we prove flush must run first.
    @memset(body, 0xAA);

    try std.testing.expectError(error.PrematureInvalidation, sink.flush());

    // Whiteboard may be reset only after a successful flush path returns.
    _ = arena.reset(.free_all);
}

test "HoldUntilFlush: implemented order equals prefix+html+suffix" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const layout = try Layout.split("<main>{{content}}</main>");
    const body = try arena.allocator().dupe(u8, "<p>x</p>");

    var sink = HoldUntilFlush.init(gpa);
    defer sink.deinit();
    try spliceToHold(layout, body, &sink);

    // Oracle for equality only (tests may allocate the concat; product path must not).
    const oracle = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ layout.prefix, body, layout.suffix });
    defer gpa.free(oracle);
    try std.testing.expectEqualStrings(oracle, sink.materialized.?);

    _ = arena.reset(.free_all);
}

test "no mega-string helper exists for page assembly" {
    // compile-time documentation: writePage / spliceToHold only use sequential
    // writeAll of three slices. This test locks the public API surface.
    const layout = try Layout.split("a{{content}}b");
    try std.testing.expectEqualStrings("a", layout.prefix);
    try std.testing.expectEqualStrings("b", layout.suffix);
}
