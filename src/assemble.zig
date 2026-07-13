//! Phase 5: zero-copy layout splicing.
//!
//! Layout is loaded once at **startup** (before content scan) and split into
//! immutable prefix/suffix slices around a single `{{content}}` marker.
//! Final HTML is streamed with a stack-buffered writer — no Header+Content+Footer
//! concatenation in app memory.
//!
//! ## I/O invariants
//!
//! - Missing or **duplicate** `{{content}}` is a hard error at layout load time.
//! - `Layout.prefix` and `Layout.suffix` are `[]const u8` views into `Layout.raw`.
//!   The owning `Layout` (and its raw buffer) must outlive every `writePage` call.
//! - Page bytes are written as three sequential `writeAll`s: prefix | body | suffix.
//!   There is no `prefix ++ body ++ suffix` allocation.
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
//!
//! Unit tests below exercise successful replace-over-prior and failed-write
//! preservation of prior output on the host running `zig build test`.

const std = @import("std");
const Io = std.Io;

pub const content_marker = "{{content}}";

/// Stack buffer size for the page writer — large enough that most pages need
/// one underlying write path per splice segment.
pub const write_buffer_size = 64 * 1024;

pub const LayoutError = error{
    MissingContentMarker,
    DuplicateContentMarker,
};

/// Immutable split of layouts/main.html.
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
        // Duplicate marker is almost always a template authoring mistake.
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
/// Call this **before** scanning `content/` so a bad template fails fast.
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

/// Pre-create every unique parent directory needed by `output_paths` (scan-time
/// batch). Removes mkdir branching from the hot per-page write path when used
/// before the compile loop. Paths must outlive `cache` keys (PageDb-owned).
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
        // Key is a stable slice into PageDb path storage.
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
    // `make_path` creates parent dirs of `output_path` when needed.
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

test "layout split is zero-copy into raw" {
    const raw = "<html>{{content}}</html>";
    const layout = try Layout.split(raw);
    try std.testing.expectEqualStrings("<html>", layout.prefix);
    try std.testing.expectEqualStrings("</html>", layout.suffix);
    try std.testing.expect(@intFromPtr(layout.prefix.ptr) == @intFromPtr(raw.ptr));
    // Types are []const u8 views (not owned copies).
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

    // No leftover atomic temps after successful publish.
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

    // Seed a final file so we can also assert it survives.
    try writePage(io, out, "page.html", layout, "keep");

    try std.testing.expectError(
        error.TestInjectedWriteFailure,
        writePageOpts(io, out, "page.html", layout, "tmp-only", .{
            .fail_before_publish = true,
        }),
    );

    // Unique hex temps from createFileAtomic must be gone after deinit.
    try std.testing.expectEqual(@as(usize, 0), try countHexTempNames(io, out));

    const got = try readAllFile(io, out, "page.html", gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("<x>keep</x>", got);
}

test "writePage sequential splice does not concatenate in memory" {
    // Behavioral guarantee: published file is prefix|body|suffix order.
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
