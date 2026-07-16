//! Narrow, reversible Filed.fyi migration proof.  This intentionally knows only
//! the observed Astro collection layout: src/content/changelog/* (one record)
//! and src/content/releases/* (three records).  It never imports Boris core.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-filed-fyi-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const RunOptions = struct {
    source_root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

const Collection = enum { changelog, releases };

const Record = struct {
    collection: Collection,
    source_path: []const u8,
    output_path: []const u8,
    id: []const u8,
    title: []const u8,
    raw_frontmatter: []const u8,
    body: []const u8,
    unsupported_mdx: bool,
};

fn collectionName(c: Collection) []const u8 {
    return switch (c) { .changelog => "changelog", .releases => "releases" };
}

fn isMarkdown(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".mdx");
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn parseSource(allocator: std.mem.Allocator, raw: []const u8, fallback_title: []const u8) !struct { title: []const u8, frontmatter: []const u8, body: []const u8 } {
    if (!std.mem.startsWith(u8, raw, "---\n")) return .{ .title = fallback_title, .frontmatter = "", .body = raw };
    const end_start = std.mem.indexOfPos(u8, raw, 4, "\n---\n") orelse return .{ .title = fallback_title, .frontmatter = raw, .body = "" };
    const frontmatter = raw[4..end_start];
    var title: []const u8 = fallback_title;
    var pos: usize = 0;
    while (pos < frontmatter.len) {
        const line_end = std.mem.indexOfScalarPos(u8, frontmatter, pos, '\n') orelse frontmatter.len;
        const line = frontmatter[pos..line_end];
        if (std.mem.startsWith(u8, line, "title:")) {
            var value = trim(line["title:".len..]);
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
            if (value.len > 0) title = try allocator.dupe(u8, value);
        }
        pos = if (line_end == frontmatter.len) frontmatter.len else line_end + 1;
    }
    return .{ .title = title, .frontmatter = frontmatter, .body = raw[end_start + "\n---\n".len ..] };
}

fn slugAlloc(allocator: std.mem.Allocator, source_name: []const u8) ![]u8 {
    const stem = if (std.mem.endsWith(u8, source_name, ".mdx")) source_name[0 .. source_name.len - 4] else source_name[0 .. source_name.len - 3];
    var out: std.ArrayList(u8) = .empty;
    var dash = false;
    for (stem) |c| {
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            try out.append(allocator, lower);
            dash = false;
        } else if (!dash and out.items.len > 0) {
            try out.append(allocator, '-');
            dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') out.items.len -= 1;
    if (out.items.len == 0) return error.InvalidSourceName;
    return try out.toOwnedSlice(allocator);
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeFile(io: Io, root: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try root.createDirPath(io, parent);
    try root.writeFile(io, .{ .sub_path = path, .data = data });
}

fn appendJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""), '\\' => try buf.appendSlice(a, "\\\\"), '\n' => try buf.appendSlice(a, "\\n"), '\r' => try buf.appendSlice(a, "\\r"), '\t' => try buf.appendSlice(a, "\\t"),
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn emitPage(a: std.mem.Allocator, r: Record) ![]u8 {
    return try std.fmt.allocPrint(a,
        "---\nid: {s}\ntitle: {s}\nparent: {s}\nstatus: published\ntags: [filed, {s}]\n---\n<!-- boris-migration-provenance\n  format: {s}\n  source_path: {s}\n  tool_version: {s}\n-->\n{s}",
        .{ r.id, r.title, collectionName(r.collection), collectionName(r.collection), format_id, r.source_path, tool_version, r.body },
    );
}

fn emitIndex(a: std.mem.Allocator, collection: Collection) ![]u8 {
    const name = collectionName(collection);
    const title = if (collection == .changelog) "Changelog" else "Releases";
    return try std.fmt.allocPrint(a, "---\nid: {s}\ntitle: {s}\nstatus: published\ntags: [filed, collection]\n---\n\nMigrated Filed.fyi {s} collection index.\n", .{ name, title, name });
}

fn collectCollection(io: Io, a: std.mem.Allocator, root: Io.Dir, collection: Collection, out: *std.ArrayList(Record)) !void {
    const name = collectionName(collection);
    const source_dir = try std.fmt.allocPrint(a, "src/content/{s}", .{name});
    var dir = try root.openDir(io, source_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isMarkdown(entry.name)) continue;
        const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ source_dir, entry.name });
        const raw = try readFileAlloc(io, root, rel, a);
        const fallback = try slugAlloc(a, entry.name);
        const parsed = try parseSource(a, raw, fallback);
        const slug = try slugAlloc(a, entry.name);
        const id = try std.fmt.allocPrint(a, "{s}/{s}", .{ name, slug });
        const output = try std.fmt.allocPrint(a, "content/{s}/{s}.md", .{ name, slug });
        try out.append(a, .{ .collection = collection, .source_path = rel, .output_path = output, .id = id, .title = parsed.title, .raw_frontmatter = parsed.frontmatter, .body = parsed.body, .unsupported_mdx = std.mem.indexOfScalar(u8, parsed.body, '{') != null or std.mem.indexOfScalar(u8, parsed.body, '<') != null });
    }
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    // Keep the source root read-only even when a caller supplies relative paths.
    if (std.mem.eql(u8, opts.source_root_dir, opts.out_dir) or
        (opts.out_dir.len > opts.source_root_dir.len and
            std.mem.startsWith(u8, opts.out_dir, opts.source_root_dir) and
            (opts.out_dir[opts.source_root_dir.len] == '/' or opts.out_dir[opts.source_root_dir.len] == '\\')))
        return error.OutputInsideSource;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Io.Dir.cwd().openDir(io, opts.source_root_dir, .{ .iterate = true });
    defer source.close(io);
    var records: std.ArrayList(Record) = .empty;
    try collectCollection(io, a, source, .changelog, &records);
    const changelog_count = records.items.len;
    try collectCollection(io, a, source, .releases, &records);
    if (changelog_count != 1 or records.items.len - changelog_count != 3) return error.UnexpectedCollectionCardinality;
    std.mem.sort(Record, records.items, {}, struct { fn less(_: void, x: Record, y: Record) bool { return std.mem.order(u8, x.source_path, y.source_path) == .lt; } }.less);

    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out.close(io);
    for ([_]Collection{ .changelog, .releases }) |c| {
        const index_path = try std.fmt.allocPrint(a, "content/{s}/index.md", .{collectionName(c)});
        try writeFile(io, out, index_path, try emitIndex(a, c));
    }
    for (records.items) |r| try writeFile(io, out, r.output_path, try emitPage(a, r));

    var manifest: std.ArrayList(u8) = .empty;
    try manifest.appendSlice(a, "{\n  \"format\": \"boris-filed-fyi-provenance\",\n  \"schema_version\": 1,\n  \"records\": [\n");
    var report: std.ArrayList(u8) = .empty;
    try report.appendSlice(a, "{\n  \"format\": \"boris-filed-fyi-migration-lab\",\n  \"schema_version\": 1,\n  \"source_root\": "); try appendJson(&report, a, opts.source_root_dir); try report.appendSlice(a, ",\n  \"converted_records\": 4,\n  \"unsupported_content\": [\n");
    var markdown: std.ArrayList(u8) = .empty;
    try markdown.appendSlice(a, "# Filed.fyi → Boris first-slice report\n\nConverted exactly one `changelog` record and three `releases` records. Source remains read-only.\n\n## Unsupported content\n\n");
    var unsupported_count: usize = 0;
    for (records.items, 0..) |r, i| {
        try manifest.appendSlice(a, "    { \"collection\": "); try appendJson(&manifest, a, collectionName(r.collection)); try manifest.appendSlice(a, ", \"source_path\": "); try appendJson(&manifest, a, r.source_path); try manifest.appendSlice(a, ", \"output_path\": "); try appendJson(&manifest, a, r.output_path); try manifest.appendSlice(a, ", \"raw_frontmatter\": "); try appendJson(&manifest, a, r.raw_frontmatter); try manifest.appendSlice(a, " }"); if (i + 1 < records.items.len) try manifest.append(a, ','); try manifest.append(a, '\n');
        if (r.unsupported_mdx) { if (unsupported_count > 0) try report.appendSlice(a, ",\n"); try report.appendSlice(a, "    { \"source_path\": "); try appendJson(&report, a, r.source_path); try report.appendSlice(a, ", \"kind\": \"mdx_or_html\", \"handling\": \"body retained verbatim; human review required\" }"); try markdown.appendSlice(a, "- `"); try markdown.appendSlice(a, r.source_path); try markdown.appendSlice(a, "` — MDX/HTML-like body retained verbatim; review before compiling.\n"); unsupported_count += 1; }
    }
    try manifest.appendSlice(a, "  ]\n}\n");
    try report.appendSlice(a, "\n  ]\n}\n");
    if (unsupported_count == 0) try markdown.appendSlice(a, "None detected by this deliberately small heuristic.\n");
    try writeFile(io, out, "provenance_manifest.json", manifest.items);
    try writeFile(io, out, "report.json", report.items);
    try writeFile(io, out, "REPORT.md", markdown.items);
    if (!opts.quiet) std.debug.print("filed-migration-lab: wrote {s}/content/, provenance_manifest.json, report.json, REPORT.md\n", .{opts.out_dir});
}

test "fixture: Filed slice is deterministic, preserves source, and reports unsupported MDX" {
    const io = std.testing.io;
    const a = "fixtures/.test-filed-a";
    const b = "fixtures/.test-filed-b";
    Io.Dir.cwd().deleteTree(io, a) catch {};
    Io.Dir.cwd().deleteTree(io, b) catch {};
    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/mini-filed", .{}); defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "src/content/releases/v0.2.0.mdx", std.testing.allocator); defer std.testing.allocator.free(before);
    try run(io, std.testing.allocator, .{ .source_root_dir = "fixtures/mini-filed", .out_dir = a, .quiet = true });
    try run(io, std.testing.allocator, .{ .source_root_dir = "fixtures/mini-filed", .out_dir = b, .quiet = true });
    var ao = try Io.Dir.cwd().openDir(io, a, .{}); defer ao.close(io);
    var bo = try Io.Dir.cwd().openDir(io, b, .{}); defer bo.close(io);
    const ma = try readFileAlloc(io, ao, "provenance_manifest.json", std.testing.allocator); defer std.testing.allocator.free(ma);
    const mb = try readFileAlloc(io, bo, "provenance_manifest.json", std.testing.allocator); defer std.testing.allocator.free(mb);
    try std.testing.expectEqualStrings(ma, mb);
    try std.testing.expect(std.mem.indexOf(u8, ma, "releaseChannel") != null);
    const report = try readFileAlloc(io, ao, "report.json", std.testing.allocator); defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "mdx_or_html") != null);
    const page = try readFileAlloc(io, ao, "content/releases/v0-2-0.md", std.testing.allocator); defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "parent: releases") != null);
    const after = try readFileAlloc(io, fixture, "src/content/releases/v0.2.0.mdx", std.testing.allocator); defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    Io.Dir.cwd().deleteTree(io, a) catch {};
    Io.Dir.cwd().deleteTree(io, b) catch {};
}
