//! Deterministic community `llms.txt` export.
//!
//! This is a small, human-readable projection of the validated Boris graph.
//! It deliberately does not invent a second parser or URL/frontmatter dialect.

const std = @import("std");
const Io = std.Io;
const github_pages = @import("github_pages.zig");
const identity = @import("identity.zig");
const timings = @import("timings.zig");
const pipeline = @import("pipeline.zig");
const structured_out = @import("structured_out.zig");
const target_mod = @import("target.zig");
const source_io = @import("source_io.zig");
const graph = @import("graph.zig");

pub const format = "llms.txt";

pub const Options = struct {
    content_root: []const u8 = "content",
    out_path: []const u8 = "llms.txt",
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
    /// Optional normalized Pages identity. When present, links are absolute
    /// public URLs rooted at that identity; otherwise links are root-relative
    /// `.html` paths naming the default HTML output layout.
    publication_location: ?*const github_pages.Location = null,
    /// Opt-in phase timing/counter recorder (`--timings`); null by default.
    timings: ?*timings.Recorder = null,
};

pub const Result = struct {
    compile: pipeline.Result,
    published: bool = false,

    pub fn deinit(self: *Result) void {
        self.compile.deinit();
    }

    pub fn ok(self: *const Result) bool {
        return self.compile.ok and self.published;
    }
};

fn log(opts: Options, comptime fmt: []const u8, args: anytype) void {
    if (!opts.quiet) std.debug.print(fmt, args);
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn ensureParent(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try Io.Dir.cwd().createDirPath(io, parent);
    }
}

fn appendInline(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| {
        if (c == '\\' or c == '[' or c == ']' or c == '(' or c == ')') try buf.append(gpa, '\\');
        if (c == '\n' or c == '\r' or c == '\t') {
            try buf.append(gpa, ' ');
        } else {
            try buf.append(gpa, c);
        }
    }
}

fn pageTitle(page: graph.Node) []const u8 {
    return page.title orelse page.id;
}

/// Contract maximum for a summary excerpt, in bytes (`docs/contracts/llms-txt.md`).
const summary_max_bytes: usize = 240;

/// Returns the length of the longest valid UTF-8 prefix of `bytes` that is no
/// longer than `max_bytes`, without ever splitting a multibyte scalar.
///
/// When `bytes` is already within the limit, returns `bytes.len` unchanged.
/// When the limit falls inside a multibyte scalar, the prefix is shortened to
/// the nearest preceding scalar boundary, so the output is always valid UTF-8.
fn utf8TruncateLen(bytes: []const u8, max_bytes: usize) usize {
    if (bytes.len <= max_bytes) return bytes.len;
    var end = max_bytes;
    // The first excluded byte is a continuation byte when the scalar it belongs
    // to began before `end`; step back to that scalar's lead byte so the prefix
    // ends on a valid boundary.
    while (end > 0 and (bytes[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

/// CommonMark thematic break: three or more matching `-`, `_`, or `*`
/// characters, optionally separated by spaces or tabs. Decoration, not prose.
fn isThematicBreak(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const marker = trimmed[0];
    if (marker != '-' and marker != '_' and marker != '*') return false;
    var count: usize = 0;
    for (trimmed) |ch| {
        if (ch == marker) {
            count += 1;
        } else if (ch != ' ' and ch != '\t') {
            return false;
        }
    }
    return count >= 3;
}

fn summary(gpa: std.mem.Allocator, source: []const u8, fallback: []const u8) ![]u8 {
    const body = if (std.mem.startsWith(u8, source, "---\n"))
        if (std.mem.indexOfPos(u8, source, 4, "---\n")) |end| source[end + 4 ..] else source
    else
        source;
    var line_start: usize = 0;
    var paragraph: std.ArrayList(u8) = .empty;
    errdefer paragraph.deinit(gpa);
    var saw_text = false;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        if (i < body.len and body[i] != '\n' and body[i] != '\r') continue;
        const line = body[line_start..i];
        line_start = i + 1;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            if (saw_text) break;
            continue;
        }
        if (trimmed[0] == '#') continue;
        // A thematic break is not a paragraph (#879): skip it while hunting,
        // and let it close a paragraph that already started.
        if (isThematicBreak(trimmed)) {
            if (saw_text) break;
            continue;
        }
        if (saw_text) try paragraph.append(gpa, ' ');
        try paragraph.appendSlice(gpa, trimmed);
        saw_text = true;
        if (paragraph.items.len >= summary_max_bytes) break;
    }
    if (!saw_text) return try gpa.dupe(u8, fallback);
    const keep = utf8TruncateLen(paragraph.items, summary_max_bytes);
    if (keep < paragraph.items.len) paragraph.shrinkRetainingCapacity(keep);
    return try paragraph.toOwnedSlice(gpa);
}

fn appendUrl(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    id: []const u8,
    location: ?*const github_pages.Location,
) !void {
    const output_path = try identity.safeOutputRelativePath(gpa, id);
    defer gpa.free(output_path);
    var url = structured_out.Sink.init(gpa);
    defer url.deinit();
    if (location) |public_location| {
        try url.rawTrusted("github_pages.parse validates the normalized publication base URL", public_location.base_url);
    }
    try url.lit("/");
    try url.uriPath(output_path);
    try buf.appendSlice(gpa, url.items());
}

const ChildrenIndex = struct {
    by_parent: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,

    fn build(gpa: std.mem.Allocator, pages: []const graph.Node) !ChildrenIndex {
        var index: ChildrenIndex = .{};
        errdefer index.deinit(gpa);
        try index.by_parent.ensureTotalCapacity(gpa, @intCast(pages.len));

        // `pages` is already in canonical entity-id order, so appending while
        // scanning it once preserves the export's existing child order without
        // depending on hash-map iteration order.
        for (pages, 0..) |page, child_index| {
            if (page.parent) |parent| {
                const entry = try index.by_parent.getOrPut(gpa, parent);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, child_index);
            }
        }
        return index;
    }

    fn deinit(self: *ChildrenIndex, gpa: std.mem.Allocator) void {
        var iterator = self.by_parent.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(gpa);
        self.by_parent.deinit(gpa);
    }
};

fn findChildren(index: *const ChildrenIndex, parent: []const u8) []const usize {
    if (index.by_parent.getPtr(parent)) |children| return children.items;
    return &.{};
}

fn renderPage(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    pages: []const graph.Node,
    sources: []const []const u8,
    visited: []bool,
    children_index: *const ChildrenIndex,
    index: usize,
    depth: usize,
    location: ?*const github_pages.Location,
) !void {
    if (visited[index]) return;
    visited[index] = true;
    const page = pages[index];
    var indent: usize = 0;
    while (indent < depth) : (indent += 1) try buf.appendSlice(gpa, "  ");
    try buf.appendSlice(gpa, "- [");
    try appendInline(buf, gpa, pageTitle(page));
    // Keep the URL fallback deterministic and independent of host deployment.
    try buf.appendSlice(gpa, "](");
    try appendUrl(buf, gpa, page.id, location);
    try buf.appendSlice(gpa, "): ");
    const text = try summary(gpa, sources[index], pageTitle(page));
    defer gpa.free(text);
    try appendInline(buf, gpa, text);
    try buf.append(gpa, '\n');

    for (findChildren(children_index, page.id)) |child| {
        // Keep the existing per-render visited check. It is what makes the
        // unvisited-page fallback below remain total if a future graph role
        // is not reachable from a trunk.
        if (!visited[child]) try renderPage(gpa, buf, pages, sources, visited, children_index, child, depth + 1, location);
    }
}

fn render(
    gpa: std.mem.Allocator,
    result: *pipeline.Result,
    sources: []const []const u8,
    location: ?*const github_pages.Location,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "# Boris documentation\n\n");
    try buf.appendSlice(gpa, "> This file is generated by Boris from a validated Trunk/Satellite content graph.\n\n");
    try buf.appendSlice(gpa, "## Documentation\n\n");
    const visited = try gpa.alloc(bool, result.pages.items.len);
    defer gpa.free(visited);
    @memset(visited, false);
    var children_index = try ChildrenIndex.build(gpa, result.pages.items);
    defer children_index.deinit(gpa);
    for (result.pages.items, 0..) |page, index| {
        if (page.parent == null) try renderPage(gpa, &buf, result.pages.items, sources, visited, &children_index, index, 0, location);
    }
    // Validated graphs should make this unnecessary, but keeping an explicit
    // fallback makes the exporter total if a future graph role is introduced.
    for (visited, 0..) |seen, index| if (!seen) try renderPage(gpa, &buf, result.pages.items, sources, visited, &children_index, index, 0, location);
    return try buf.toOwnedSlice(gpa);
}

fn publish(io: Io, gpa: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const stage = try std.fmt.allocPrint(gpa, "{s}.boris-llms-stage", .{path});
    defer gpa.free(stage);
    const previous = try std.fmt.allocPrint(gpa, "{s}.boris-llms-prev", .{path});
    defer gpa.free(previous);
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io, stage) catch {};
    cwd.deleteFile(io, previous) catch {};
    try ensureParent(io, stage);
    try cwd.writeFile(io, .{ .sub_path = stage, .data = data });
    cwd.rename(path, cwd, previous, io) catch {};
    cwd.rename(stage, cwd, path, io) catch |err| {
        cwd.rename(previous, cwd, path, io) catch {};
        return err;
    };
    cwd.deleteFile(io, previous) catch {};
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !Result {
    if (std.fs.path.isAbsolute(opts.content_root) or std.fs.path.isAbsolute(opts.out_path)) return error.AbsolutePath;
    try target_mod.validateExportPath(io, gpa, opts.content_root, opts.out_path);
    var result = Result{ .compile = try pipeline.compile(io, gpa, .{
        .content_root = opts.content_root,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .timings = opts.timings,
    }) };
    errdefer result.deinit();
    if (!result.compile.ok) return result;
    const arena = result.compile.arena.allocator();
    var content_dir = try Io.Dir.cwd().openDir(io, opts.content_root, .{});
    defer content_dir.close(io);
    const sources = try gpa.alloc([]const u8, result.compile.pages.items.len);
    defer {
        gpa.free(sources);
    }
    for (result.compile.pages.items, 0..) |page, index| sources[index] = try source_io.readPageAlloc(io, content_dir, page.source_path, arena);
    const output = try render(gpa, &result.compile, sources, opts.publication_location);
    defer gpa.free(output);
    try publish(io, gpa, opts.out_path, output);
    result.published = true;
    log(opts, "llms.txt export complete: {s} ({d} page(s))\n", .{ opts.out_path, result.compile.pages.items.len });
    return result;
}

test "summary uses first body paragraph and falls back to title" {
    const gpa = std.testing.allocator;
    const got = try summary(gpa, "---\nid: x\n---\n\n# Heading\n\nFirst useful sentence.", "Fallback");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("First useful sentence.", got);
    const fallback = try summary(gpa, "---\nid: x\n---\n\n# Heading\n", "Fallback");
    defer gpa.free(fallback);
    try std.testing.expectEqualStrings("Fallback", fallback);
}

test "summary skips thematic breaks instead of describing them (#879)" {
    const gpa = std.testing.allocator;
    const dashes = try summary(gpa, "---\nid: x\n---\n\n# Heading\n\n---\n\nNested body.", "Fallback");
    defer gpa.free(dashes);
    try std.testing.expectEqualStrings("Nested body.", dashes);
    // Space-separated and alternative marker forms are thematic breaks too.
    const spaced = try summary(gpa, "---\nid: x\n---\n\n# H\n\n- - -\n\nReal paragraph.", "Fallback");
    defer gpa.free(spaced);
    try std.testing.expectEqualStrings("Real paragraph.", spaced);
    const stars = try summary(gpa, "---\nid: x\n---\n\n***\n\nReal paragraph.", "Fallback");
    defer gpa.free(stars);
    try std.testing.expectEqualStrings("Real paragraph.", stars);
    // A break after prose closes that paragraph rather than joining it.
    const closes = try summary(gpa, "---\nid: x\n---\n\nFirst paragraph.\n---\nSecond.", "Fallback");
    defer gpa.free(closes);
    try std.testing.expectEqualStrings("First paragraph.", closes);
    // Lookalikes that are not thematic breaks still count as prose.
    const two = try summary(gpa, "---\nid: x\n---\n\n--\nBody.", "Fallback");
    defer gpa.free(two);
    try std.testing.expectEqualStrings("-- Body.", two);
    const mixed = try summary(gpa, "---\nid: x\n---\n\n- * -\nBody.", "Fallback");
    defer gpa.free(mixed);
    try std.testing.expectEqualStrings("- * - Body.", mixed);
}

test "summary truncates to the 240-byte contract on a UTF-8 scalar boundary" {
    const gpa = std.testing.allocator;
    const a237 = "a" ** 237;
    const a238 = "a" ** 238;
    const em_dash = [_]u8{ 0xE2, 0x80, 0x94 }; // U+2014 EM DASH, 3 bytes
    const emoji = [_]u8{ 0xF0, 0x9F, 0x98, 0x80 }; // U+1F600 GRINNING FACE, 4 bytes

    // 237 ASCII bytes + em dash = exactly 240 bytes: keep everything.
    {
        const source = a237 ++ em_dash;
        const got = try summary(gpa, source, "Fallback");
        defer gpa.free(got);
        try std.testing.expectEqual(@as(usize, 240), got.len);
        try std.testing.expectEqualSlices(u8, source, got);
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    }

    // 238 ASCII bytes + em dash = 241 bytes: truncate to the 238 ASCII bytes.
    {
        const source = a238 ++ em_dash;
        const got = try summary(gpa, source, "Fallback");
        defer gpa.free(got);
        try std.testing.expectEqual(@as(usize, 238), got.len);
        try std.testing.expectEqualSlices(u8, a238, got);
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    }

    // 237 ASCII bytes + 4-byte emoji = 241 bytes: truncate to the 237 ASCII bytes.
    {
        const source = a237 ++ emoji;
        const got = try summary(gpa, source, "Fallback");
        defer gpa.free(got);
        try std.testing.expectEqual(@as(usize, 237), got.len);
        try std.testing.expectEqualSlices(u8, a237, got);
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    }

    // A paragraph already below the limit is preserved byte-for-byte.
    {
        const source = "A short paragraph that fits under the byte budget.";
        const got = try summary(gpa, source, "Fallback");
        defer gpa.free(got);
        try std.testing.expectEqualStrings(source, got);
        try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    }
}

test "two llms runs over identical input emit byte-identical output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "content");
    const em_dash = [_]u8{ 0xE2, 0x80, 0x94 };
    const body = ("a" ** 238) ++ em_dash; // paragraph crosses byte 240 inside a scalar
    const page = "---\nid: utf8-check\ntitle: Utf8 Check\nstatus: published\n---\n\n# Utf8 Check\n\n" ++ body ++ "\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "content/utf8-check.md", .data = page });

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/content", .{tmp.sub_path});
    defer gpa.free(root);
    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/llms-a.txt", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/llms-b.txt", .{tmp.sub_path});
    defer gpa.free(out_b);

    var result_a = try run(io, gpa, .{ .content_root = root, .out_path = out_a, .quiet = true });
    defer result_a.deinit();
    try std.testing.expect(result_a.ok());
    var result_b = try run(io, gpa, .{ .content_root = root, .out_path = out_b, .quiet = true });
    defer result_b.deinit();
    try std.testing.expect(result_b.ok());

    const bytes_a = try readFileAlloc(io, Io.Dir.cwd(), out_a, gpa);
    defer gpa.free(bytes_a);
    const bytes_b = try readFileAlloc(io, Io.Dir.cwd(), out_b, gpa);
    defer gpa.free(bytes_b);
    try std.testing.expectEqualSlices(u8, bytes_a, bytes_b);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bytes_a));
}

test "llms export renders arbitrary-depth hierarchy recursively" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/hierarchy-llms.txt", .{tmp.sub_path});
    defer gpa.free(out);
    var result = try run(io, gpa, .{
        .content_root = "fixtures/content/valid",
        .out_path = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok());

    const output = try readFileAlloc(io, Io.Dir.cwd(), out, gpa);
    defer gpa.free(output);
    const chain = [_][]const u8{
        "[Hierarchy Trunk](/hierarchy-trunk.html)",
        "[Hierarchy Mid](/hierarchy-mid.html)",
        "[Hierarchy Leaf](/hierarchy-leaf.html)",
        "[Hierarchy Great-Grandchild](/hierarchy-great-grandchild.html)",
    };
    var prior: usize = 0;
    for (chain) |entry| {
        const found = std.mem.indexOfPos(u8, output, prior, entry) orelse return error.TestExpectedEqual;
        prior = found + entry.len;
    }
    // Default-export links must name the flat .html layout (#762): they have
    // to resolve against a plain static serve of the built dist/ tree.
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const open = std.mem.indexOf(u8, line, "](") orelse continue;
        const close = std.mem.indexOfScalarPos(u8, line, open + 2, ')') orelse return error.TestExpectedEqual;
        const url = line[open + 2 .. close];
        try std.testing.expect(std.mem.endsWith(u8, url, ".html"));
        try std.testing.expect(!std.mem.endsWith(u8, url, "/"));
    }
}

test "llms parent children index preserves existing page order" {
    const gpa = std.testing.allocator;
    const pages = [_]graph.Node{
        .{ .id = "root", .source_path = "root.md" },
        .{ .id = "z-child", .source_path = "z.md", .parent = "root" },
        .{ .id = "a-child", .source_path = "a.md", .parent = "root" },
        .{ .id = "leaf", .source_path = "leaf.md", .parent = "z-child" },
    };
    var index = try ChildrenIndex.build(gpa, &pages);
    defer index.deinit(gpa);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 2 }, findChildren(&index, "root"));
    try std.testing.expectEqualSlices(usize, &[_]usize{3}, findChildren(&index, "z-child"));
    try std.testing.expectEqual(@as(usize, 0), findChildren(&index, "missing").len);
}

test "llms valid fixture remains byte-identical to its golden" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/valid-llms.txt", .{tmp.sub_path});
    defer gpa.free(out);
    var result = try run(io, gpa, .{
        .content_root = "fixtures/content/valid",
        .out_path = out,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok());

    const actual = try readFileAlloc(io, Io.Dir.cwd(), out, gpa);
    defer gpa.free(actual);
    const expected = try readFileAlloc(io, Io.Dir.cwd(), "fixtures/expected/valid/llms.txt", gpa);
    defer gpa.free(expected);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "location-aware llms export uses the normalized public base path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const shapes = [_]struct {
        base_url: []const u8,
        origin: []const u8,
        base_path: []const u8,
    }{
        .{ .base_url = "https://owner.github.io/boris", .origin = "https://owner.github.io", .base_path = "/boris" },
        .{ .base_url = "https://owner.github.io", .origin = "https://owner.github.io", .base_path = "" },
        .{ .base_url = "https://docs.example.com", .origin = "https://docs.example.com", .base_path = "" },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (shapes, 0..) |shape, index| {
        const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/location-llms-{d}.txt", .{ tmp.sub_path, index });
        defer gpa.free(out);
        const out_again = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/location-llms-{d}-again.txt", .{ tmp.sub_path, index });
        defer gpa.free(out_again);
        var location = try github_pages.parse(gpa, shape.base_url, shape.origin, shape.base_path);
        defer location.deinit(gpa);
        var first = try run(io, gpa, .{
            .content_root = "docs/contracts/fixtures/publication-location/content",
            .out_path = out,
            .quiet = true,
            .publication_location = &location,
        });
        defer first.deinit();
        try std.testing.expect(first.ok());
        var second = try run(io, gpa, .{
            .content_root = "docs/contracts/fixtures/publication-location/content",
            .out_path = out_again,
            .quiet = true,
            .publication_location = &location,
        });
        defer second.deinit();
        try std.testing.expect(second.ok());
        const output = try readFileAlloc(io, Io.Dir.cwd(), out, gpa);
        defer gpa.free(output);
        const output_again = try readFileAlloc(io, Io.Dir.cwd(), out_again, gpa);
        defer gpa.free(output_again);
        try std.testing.expectEqualSlices(u8, output, output_again);
        const expected = try std.fmt.allocPrint(gpa, "{s}/guides/start.html", .{shape.base_url});
        defer gpa.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
        const legacy_directory_url = try std.fmt.allocPrint(gpa, "{s}/guides/start/", .{shape.base_url});
        defer gpa.free(legacy_directory_url);
        try std.testing.expect(std.mem.indexOf(u8, output, legacy_directory_url) == null);
    }
}
