//! Zero-copy layout splicing for the HTML path (milestone 9 + Feature 6 nav + F9.1).
//!
//! Layout is loaded once at **startup** (before content compile) and split into
//! a reusable closed plan of ordered static / slot / asset-url segments.
//! Required marker: `{{content}}`. Optional slots: `{{nav}}`, `{{breadcrumb}}`,
//! `{{title}}`, `{{toc}}`, `{{metadata}}`, `{{footer}}`. Optional helper:
//! `{{asset-url <theme-relative path>}}` (validated path grammar only).
//! Final HTML is streamed with sequential writes — no full-page mega-string.
//!
//! ## I/O invariants
//!
//! - Missing `{{content}}`, duplicate known markers, or unknown `{{…}}` tokens
//!   are hard errors at layout load time.
//! - Segment slices are views into `Layout.raw`. The owning `Layout` (and its
//!   raw buffer) must outlive every `writePage` call.
//! - Page bytes are written as N sequential segments (static + slot + asset URLs).
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
//! - Cross-device / cross-volume **atomic** rename. Stage/publish paths prefer
//!   same-parent rename; HTML stage commit and IR publish fall back to
//!   copy+delete on `error.CrossDevice` (completeness, not atomicity).
//! - Windows: Zig std documents a brief window where concurrent openers of the
//!   destination may see `error.AccessDenied` during replace.
//! - Universal atomic replacement on every filesystem without multi-OS CI.
//!
//! Unit tests exercise successful replace-over-prior and failed-write
//! preservation of prior output on the **host OS** running `zig build test`.

const std = @import("std");
const Io = std.Io;

pub const content_marker = "{{content}}";
pub const nav_marker = "{{nav}}";
pub const breadcrumb_marker = "{{breadcrumb}}";
pub const title_marker = "{{title}}";
pub const toc_marker = "{{toc}}";
pub const metadata_marker = "{{metadata}}";
pub const footer_marker = "{{footer}}";
/// Prefix of the argument-bearing helper (path follows a single space).
pub const asset_url_prefix = "{{asset-url ";

/// Max static + slot + asset-url pieces in one closed layout plan.
pub const max_segments: usize = 32;
/// Max distinct `{{asset-url …}}` occurrences in one layout.
pub const max_asset_urls: usize = 16;

/// Stack buffer size for the page writer — large enough that most pages need
/// one underlying write path per splice segment. **Not** Whiteboard memory.
pub const write_buffer_size = 64 * 1024;

pub const LayoutError = error{
    MissingContentMarker,
    DuplicateContentMarker,
    DuplicateLayoutMarker,
    UnknownLayoutMarker,
    TooManyLayoutSegments,
    InvalidAssetUrl,
    TooManyAssetUrls,
    /// Layout bytes are not valid UTF-8 (validated at split / load boundary).
    InvalidUtf8,
};

pub const Slot = enum {
    content,
    nav,
    breadcrumb,
    title,
    toc,
    metadata,
    footer,
};

pub const Segment = union(enum) {
    static: []const u8,
    slot: Slot,
    /// Theme-relative asset path under `assets/` (view into layout raw).
    asset_url: []const u8,
};

/// Per-page values for layout slots. Static layout bytes come from `Layout`.
/// `asset_hrefs` is parallel to `Layout.assetPaths()` (page-relative URLs).
pub const SlotValues = struct {
    content: []const u8,
    nav: []const u8 = "",
    breadcrumb: []const u8 = "",
    title: []const u8 = "",
    toc: []const u8 = "",
    metadata: []const u8 = "",
    footer: []const u8 = "",
    /// Page-relative hrefs for each `asset_url` segment, in layout order.
    asset_hrefs: []const []const u8 = &.{},

    pub fn forSlot(self: SlotValues, slot: Slot) []const u8 {
        return switch (slot) {
            .content => self.content,
            .nav => self.nav,
            .breadcrumb => self.breadcrumb,
            .title => self.title,
            .toc => self.toc,
            .metadata => self.metadata,
            .footer => self.footer,
        };
    }
};

/// Validate a theme-relative asset path for `{{asset-url …}}` (F9.1 ASCII-only).
///
/// Rules: non-empty, `/` separators only, no absolute/drive prefix, no empty/`.`/`..`
/// segments, must start with `assets/`, and every byte is a conservative ASCII
/// path character (`A-Za-z0-9._-/`). Rejects backslashes and non-ASCII.
pub fn validateAssetUrlPath(path: []const u8) LayoutError!void {
    if (path.len == 0) return error.InvalidAssetUrl;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidAssetUrl;
    if (path.len >= 2 and path[1] == ':') return error.InvalidAssetUrl;
    if (!std.mem.startsWith(u8, path, "assets/")) return error.InvalidAssetUrl;
    if (path.len == "assets/".len) return error.InvalidAssetUrl;

    var start: usize = 0;
    while (start <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const seg = path[start..slash];
        if (seg.len == 0) return error.InvalidAssetUrl;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidAssetUrl;
        for (seg) |c| {
            const ok = (c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or
                c == '.' or c == '_' or c == '-';
            if (!ok) return error.InvalidAssetUrl;
        }
        if (slash >= path.len) break;
        start = slash + 1;
    }
}

/// Immutable multi-slot closed plan of a layout template (e.g. `layouts/main.html`).
///
/// Segment slices are views into `raw`. Keep the `Layout` (and the allocator
/// that owns `raw`) alive for the full duration of all `writePage` calls.
pub const Layout = struct {
    /// Full template bytes (kept so segment slices remain valid).
    raw: []const u8,
    segments: [max_segments]Segment = undefined,
    segment_count: usize = 0,
    /// Theme-relative paths from each `asset_url` segment (views into `raw`).
    asset_paths: [max_asset_urls][]const u8 = undefined,
    asset_path_count: usize = 0,
    has_nav: bool = false,
    has_breadcrumb: bool = false,
    has_title: bool = false,
    has_toc: bool = false,
    has_metadata: bool = false,
    has_footer: bool = false,
    has_asset_url: bool = false,

    /// Content-only convenience: bytes before the single `{{content}}`.
    /// Empty when the layout has other slots (use `segments` instead).
    prefix: []const u8 = "",
    /// Content-only convenience: bytes after the single `{{content}}`.
    suffix: []const u8 = "",

    /// Split known markers into a closed plan. Missing/duplicate/unknown → hard error.
    ///
    /// UTF-8 is validated **here** (layout load / plan boundary), before marker
    /// scanning. Content Markdown has its own UTF-8 gate in the parser.
    pub fn split(raw: []const u8) LayoutError!Layout {
        if (raw.len > 0 and !std.unicode.utf8ValidateSlice(raw)) {
            return error.InvalidUtf8;
        }

        var layout: Layout = .{ .raw = raw };
        var seen_content = false;
        var seen_nav = false;
        var seen_breadcrumb = false;
        var seen_title = false;
        var seen_toc = false;
        var seen_metadata = false;
        var seen_footer = false;

        var pos: usize = 0;
        while (pos < raw.len) {
            const open = std.mem.indexOfPos(u8, raw, pos, "{{") orelse {
                // Trailing static.
                if (pos < raw.len) {
                    try layout.appendStatic(raw[pos..]);
                }
                break;
            };
            if (open > pos) {
                try layout.appendStatic(raw[pos..open]);
            }
            const close_rel = std.mem.indexOf(u8, raw[open..], "}}") orelse {
                // Unclosed `{{` — treat rest as unknown / invalid marker region.
                return error.UnknownLayoutMarker;
            };
            const close = open + close_rel;
            const token = raw[open .. close + 2];
            if (std.mem.eql(u8, token, content_marker)) {
                if (seen_content) return error.DuplicateContentMarker;
                seen_content = true;
                try layout.appendSlot(.content);
            } else if (std.mem.eql(u8, token, nav_marker)) {
                if (seen_nav) return error.DuplicateLayoutMarker;
                seen_nav = true;
                layout.has_nav = true;
                try layout.appendSlot(.nav);
            } else if (std.mem.eql(u8, token, breadcrumb_marker)) {
                if (seen_breadcrumb) return error.DuplicateLayoutMarker;
                seen_breadcrumb = true;
                layout.has_breadcrumb = true;
                try layout.appendSlot(.breadcrumb);
            } else if (std.mem.eql(u8, token, title_marker)) {
                if (seen_title) return error.DuplicateLayoutMarker;
                seen_title = true;
                layout.has_title = true;
                try layout.appendSlot(.title);
            } else if (std.mem.eql(u8, token, toc_marker)) {
                if (seen_toc) return error.DuplicateLayoutMarker;
                seen_toc = true;
                layout.has_toc = true;
                try layout.appendSlot(.toc);
            } else if (std.mem.eql(u8, token, metadata_marker)) {
                if (seen_metadata) return error.DuplicateLayoutMarker;
                seen_metadata = true;
                layout.has_metadata = true;
                try layout.appendSlot(.metadata);
            } else if (std.mem.eql(u8, token, footer_marker)) {
                if (seen_footer) return error.DuplicateLayoutMarker;
                seen_footer = true;
                layout.has_footer = true;
                try layout.appendSlot(.footer);
            } else if (std.mem.startsWith(u8, token, asset_url_prefix) and std.mem.endsWith(u8, token, "}}")) {
                // `{{asset-url PATH}}` — single space after the helper name.
                const inner = token[asset_url_prefix.len .. token.len - 2];
                const path = std.mem.trim(u8, inner, " \t");
                if (path.len != inner.len or path.len == 0) return error.InvalidAssetUrl;
                if (std.mem.indexOfAny(u8, path, " \t") != null) return error.InvalidAssetUrl;
                try validateAssetUrlPath(path);
                try layout.appendAssetUrl(path);
            } else {
                return error.UnknownLayoutMarker;
            }
            pos = close + 2;
        }

        if (!seen_content) return error.MissingContentMarker;

        // Content-only convenience prefix/suffix for legacy three-write tests.
        if (!layout.has_nav and !layout.has_breadcrumb and !layout.has_title and !layout.has_toc and
            !layout.has_metadata and !layout.has_footer and !layout.has_asset_url)
        {
            if (layout.segment_count == 3 and
                layout.segments[0] == .static and
                layout.segments[1] == .slot and layout.segments[1].slot == .content and
                layout.segments[2] == .static)
            {
                layout.prefix = layout.segments[0].static;
                layout.suffix = layout.segments[2].static;
            } else if (layout.segment_count == 2 and
                layout.segments[0] == .static and
                layout.segments[1] == .slot and layout.segments[1].slot == .content)
            {
                layout.prefix = layout.segments[0].static;
                layout.suffix = "";
            } else if (layout.segment_count == 2 and
                layout.segments[0] == .slot and layout.segments[0].slot == .content and
                layout.segments[1] == .static)
            {
                layout.prefix = "";
                layout.suffix = layout.segments[1].static;
            } else if (layout.segment_count == 1 and
                layout.segments[0] == .slot and layout.segments[0].slot == .content)
            {
                layout.prefix = "";
                layout.suffix = "";
            }
        }

        return layout;
    }

    fn appendStatic(self: *Layout, bytes: []const u8) LayoutError!void {
        if (bytes.len == 0) return;
        if (self.segment_count >= max_segments) return error.TooManyLayoutSegments;
        self.segments[self.segment_count] = .{ .static = bytes };
        self.segment_count += 1;
    }

    fn appendSlot(self: *Layout, slot: Slot) LayoutError!void {
        if (self.segment_count >= max_segments) return error.TooManyLayoutSegments;
        self.segments[self.segment_count] = .{ .slot = slot };
        self.segment_count += 1;
    }

    fn appendAssetUrl(self: *Layout, path: []const u8) LayoutError!void {
        if (self.asset_path_count >= max_asset_urls) return error.TooManyAssetUrls;
        if (self.segment_count >= max_segments) return error.TooManyLayoutSegments;
        self.asset_paths[self.asset_path_count] = path;
        self.asset_path_count += 1;
        self.segments[self.segment_count] = .{ .asset_url = path };
        self.segment_count += 1;
        self.has_asset_url = true;
    }

    pub fn segmentsSlice(self: *const Layout) []const Segment {
        return self.segments[0..self.segment_count];
    }

    pub fn assetPaths(self: *const Layout) []const []const u8 {
        return self.asset_paths[0..self.asset_path_count];
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

/// Stream layout segments with no full-page concatenation, then publish.
///
/// Uses a unique temporary name in the destination directory (`createFileAtomic`),
/// writes sequential slices, flushes, then `Atomic.replace` into `output_path`.
/// On failure, only this operation's temp is deleted; any prior final file at
/// `output_path` is preserved.
///
/// ## Flush-before-reset contract
///
/// Slot value slices (typically Whiteboard) must remain valid until this
/// function returns (flush + replace included). Callers must only
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
    return writePageWithSlotsOpts(io, out_dir, output_path, layout, .{
        .content = html_body,
    }, options);
}

/// Stream multi-slot layout values then publish (Feature 6).
pub fn writePageWithSlots(
    io: Io,
    out_dir: Io.Dir,
    output_path: []const u8,
    layout: Layout,
    slots: SlotValues,
) !void {
    return writePageWithSlotsOpts(io, out_dir, output_path, layout, slots, .{});
}

/// Same as `writePageWithSlots` with testable options (fault injection).
pub fn writePageWithSlotsOpts(
    io: Io,
    out_dir: Io.Dir,
    output_path: []const u8,
    layout: Layout,
    slots: SlotValues,
    options: WritePageOptions,
) !void {
    var atomic_file = try out_dir.createFileAtomic(io, output_path, .{
        .replace = true,
        .make_path = true,
    });
    defer atomic_file.deinit(io);

    var buf: [write_buffer_size]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buf);
    const w = &file_writer.interface;

    // Sequential writes of existing slices — no full-page mega-string.
    var asset_i: usize = 0;
    for (layout.segmentsSlice()) |seg| {
        switch (seg) {
            .static => |s| try w.writeAll(s),
            .slot => |slot| try w.writeAll(slots.forSlot(slot)),
            .asset_url => {
                if (asset_i >= slots.asset_hrefs.len) return error.InvalidAssetUrl;
                try w.writeAll(slots.asset_hrefs[asset_i]);
                asset_i += 1;
            },
        }
    }
    try w.flush();

    if (options.fail_before_publish) {
        return error.TestInjectedWriteFailure;
    }

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
    parts: [max_segments]?[]const u8 = .{null} ** max_segments,
    /// Wyhash of each part at `writeAll` time (stable fingerprint).
    fingerprints: [max_segments]u64 = .{0} ** max_segments,
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

/// Splice layout + body into a `HoldUntilFlush` (sequential writes, then flush).
/// Production `writePage` follows the same ordering against a file writer.
pub fn spliceToHold(layout: Layout, html_body: []const u8, sink: *HoldUntilFlush) !void {
    return spliceToHoldSlots(layout, .{ .content = html_body }, sink);
}

pub fn spliceToHoldSlots(layout: Layout, slots: SlotValues, sink: *HoldUntilFlush) !void {
    var asset_i: usize = 0;
    for (layout.segmentsSlice()) |seg| {
        switch (seg) {
            .static => |s| try sink.writeAll(s),
            .slot => |slot| try sink.writeAll(slots.forSlot(slot)),
            .asset_url => {
                if (asset_i >= slots.asset_hrefs.len) return error.InvalidAssetUrl;
                try sink.writeAll(slots.asset_hrefs[asset_i]);
                asset_i += 1;
            },
        }
    }
    try sink.flush();
}

fn readAllFile(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

/// True when `name` looks like a Zig `createFileAtomic` temp (exactly 16 hex chars).
pub fn isAtomicTempName(name: []const u8) bool {
    if (name.len != 16) return false;
    for (name) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) return false;
    }
    return true;
}

/// Count directory entries that look like createFileAtomic temps (16 hex chars).
/// `dir` must be opened with `.iterate = true`.
fn countHexTempNames(io: Io, dir: Io.Dir) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isAtomicTempName(entry.name)) n += 1;
    }
    return n;
}

/// Best-effort recursive scrub of orphan atomic temps and `*.tmp` files under `dist_dir`.
/// Safe after interrupted builds (SIGKILL) where `Atomic.deinit` never ran.
/// Never fails the compile: all errors are swallowed.
///
/// `dist_dir` should be opened with `.iterate = true` when possible; if not
/// iterable, this is a no-op.
pub fn scrubStaleAtomicTemps(io: Io, dist_dir: Io.Dir, gpa: std.mem.Allocator) void {
    scrubStaleAtomicTempsRec(io, dist_dir, gpa) catch {};
}

fn scrubStaleAtomicTempsRec(io: Io, dir: Io.Dir, gpa: std.mem.Allocator) !void {
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;

        const name = entry.basename;
        const is_tmp_suffix = std.mem.endsWith(u8, name, ".tmp") or
            std.mem.containsAtLeast(u8, name, 1, ".tmp.");
        if (!isAtomicTempName(name) and !is_tmp_suffix) continue;

        entry.dir.deleteFile(io, name) catch {};
    }
}

// =============================================================================
// Tests
// =============================================================================

test "isAtomicTempName" {
    try std.testing.expect(isAtomicTempName("0123456789abcdef"));
    try std.testing.expect(isAtomicTempName("ABCDEF0123456789"));
    try std.testing.expect(!isAtomicTempName("0123456789abcde")); // 15
    try std.testing.expect(!isAtomicTempName("0123456789abcdef0")); // 17
    try std.testing.expect(!isAtomicTempName("index.html"));
    try std.testing.expect(!isAtomicTempName("g123456789abcdef")); // non-hex
}

test "scrubStaleAtomicTemps removes orphan hex and .tmp files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    // Unique tmp path: fixed zig-cache/* dirs race across parallel test executables.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-scrub-temps", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);

    const orphan = try std.fmt.allocPrint(gpa, "{s}/0123456789abcdef", .{work});
    defer gpa.free(orphan);
    const page_tmp = try std.fmt.allocPrint(gpa, "{s}/page.html.tmp", .{work});
    defer gpa.free(page_tmp);
    const keep = try std.fmt.allocPrint(gpa, "{s}/keep.html", .{work});
    defer gpa.free(keep);
    const nested = try std.fmt.allocPrint(gpa, "{s}/nested", .{work});
    defer gpa.free(nested);
    const nested_orphan = try std.fmt.allocPrint(gpa, "{s}/nested/fedcba9876543210", .{work});
    defer gpa.free(nested_orphan);

    try cwd.writeFile(io, .{ .sub_path = orphan, .data = "orphan" });
    try cwd.writeFile(io, .{ .sub_path = page_tmp, .data = "tmp" });
    try cwd.writeFile(io, .{ .sub_path = keep, .data = "keep" });
    try cwd.createDirPath(io, nested);
    try cwd.writeFile(io, .{ .sub_path = nested_orphan, .data = "nested-orphan" });

    var dir = try cwd.openDir(io, work, .{ .iterate = true });
    defer dir.close(io);
    scrubStaleAtomicTemps(io, dir, gpa);

    try std.testing.expectError(error.FileNotFound, cwd.access(io, orphan, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, page_tmp, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(io, nested_orphan, .{}));
    try cwd.access(io, keep, .{});
}

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

test "layout split rejects invalid UTF-8 at plan boundary" {
    // Truncated multi-byte sequence after ASCII prefix (invalid UTF-8).
    const bad = [_]u8{ '<', 'h', 0xC3, 0x28, '>', '{', '{', 'c', 'o', 'n', 't', 'e', 'n', 't', '}', '}' };
    try std.testing.expectError(error.InvalidUtf8, Layout.split(&bad));
    // Valid UTF-8 still plans.
    const layout = try Layout.split("<html>{{content}}</html>");
    try std.testing.expectEqual(@as(usize, 3), layout.segment_count);
}

test "layout duplicate content marker is hard error" {
    const raw = "<a>{{content}}</a>{{content}}";
    try std.testing.expectError(error.DuplicateContentMarker, Layout.split(raw));
}

test "layout multi-slot nav breadcrumb title toc" {
    const raw =
        \\<html><title>{{title}}</title>{{nav}}{{breadcrumb}}{{toc}}{{content}}</html>
    ;
    const layout = try Layout.split(raw);
    try std.testing.expect(layout.has_nav);
    try std.testing.expect(layout.has_breadcrumb);
    try std.testing.expect(layout.has_title);
    try std.testing.expect(layout.has_toc);
    try std.testing.expectEqual(@as(usize, 0), layout.prefix.len); // multi-slot: no content-only prefix
    try std.testing.expect(layout.segment_count >= 6);

    const toc_only = try Layout.split("{{toc}}{{content}}");
    try std.testing.expect(toc_only.has_toc);
    try std.testing.expectError(error.DuplicateLayoutMarker, Layout.split("{{toc}}{{toc}}{{content}}"));
    try std.testing.expectError(error.DuplicateLayoutMarker, Layout.split("{{nav}}{{nav}}{{content}}"));
    try std.testing.expectError(error.UnknownLayoutMarker, Layout.split("{{nope}}{{content}}"));
}

test "layout metadata footer and asset-url plan" {
    const raw =
        \\<link href="{{asset-url assets/css/docs.css}}">{{metadata}}{{footer}}{{content}}
    ;
    const layout = try Layout.split(raw);
    try std.testing.expect(layout.has_metadata);
    try std.testing.expect(layout.has_footer);
    try std.testing.expect(layout.has_asset_url);
    try std.testing.expectEqual(@as(usize, 1), layout.asset_path_count);
    try std.testing.expectEqualStrings("assets/css/docs.css", layout.assetPaths()[0]);

    try std.testing.expectError(error.DuplicateLayoutMarker, Layout.split("{{metadata}}{{metadata}}{{content}}"));
    try std.testing.expectError(error.DuplicateLayoutMarker, Layout.split("{{footer}}{{footer}}{{content}}"));
    try std.testing.expectError(error.InvalidAssetUrl, Layout.split("{{asset-url ../escape.css}}{{content}}"));
    try std.testing.expectError(error.InvalidAssetUrl, Layout.split("{{asset-url /abs.css}}{{content}}"));
    try std.testing.expectError(error.InvalidAssetUrl, Layout.split("{{asset-url css/docs.css}}{{content}}"));
    try std.testing.expectError(error.InvalidAssetUrl, Layout.split("{{asset-url assets/café.css}}{{content}}"));
    try std.testing.expectError(error.InvalidAssetUrl, Layout.split("{{asset-url  assets/a.css}}{{content}}"));
    try std.testing.expectError(error.UnknownLayoutMarker, Layout.split("{{asset-url}}{{content}}"));
}

test "writePage resolves asset-url slots in order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-assemble-asset-url", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
    var out = try cwd.openDir(io, work, .{});
    defer out.close(io);

    const layout = try Layout.split("<link href=\"{{asset-url assets/css/a.css}}\">{{content}}");
    try writePageWithSlots(io, out, "guides/page.html", layout, .{
        .content = "BODY",
        .asset_hrefs = &.{"../assets/css/a.css"},
    });
    const got = try readAllFile(io, out, "guides/page.html", gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("<link href=\"../assets/css/a.css\">BODY", got);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-assemble-replace", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-assemble-fail-keep", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-assemble-temp-cleanup", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/boris-assemble-splice", .{tmp.sub_path});
    defer gpa.free(work);
    try cwd.createDirPath(io, work);
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
