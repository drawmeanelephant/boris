//! Deterministic audit of local links in an already-generated static tree.
//! This is intentionally a migration-lab aid, not ordinary-link validation in
//! the Boris compiler.

const std = @import("std");
const Io = std.Io;
const archaeology = @import("archaeology.zig");

pub const format_id = "boris-link-audit-lab";
pub const schema_version: u32 = 1;

pub const RunOptions = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

const Finding = struct {
    source: []const u8,
    target: []const u8,
    line: u32,
    kind: []const u8,
    reason: []const u8,
};

fn stripQueryFragment(target: []const u8) []const u8 {
    var end = target.len;
    if (std.mem.indexOfScalar(u8, target, '#')) |i| end = @min(end, i);
    if (std.mem.indexOfScalar(u8, target, '?')) |i| end = @min(end, i);
    return target[0..end];
}

fn isIgnoredHref(href: []const u8) bool {
    return href.len == 0 or href[0] == '#' or
        std.mem.startsWith(u8, href, "http://") or
        std.mem.startsWith(u8, href, "https://") or
        std.mem.startsWith(u8, href, "mailto:") or
        std.mem.startsWith(u8, href, "tel:") or
        std.mem.startsWith(u8, href, "data:");
}

fn findOutputPath(gpa: std.mem.Allocator, root: Io.Dir, io: Io, source: []const u8, href: []const u8) !?[]const u8 {
    const clean = stripQueryFragment(href);
    const resolved = try archaeology.resolveRelativeUrl(gpa, source, clean);
    errdefer gpa.free(resolved);
    if (resolved.len == 0) return null;
    if (root.statFile(io, resolved, .{})) |_| return resolved else |_| {}

    if (std.mem.endsWith(u8, resolved, "/")) {
        const candidate = try std.fmt.allocPrint(gpa, "{s}index.html", .{resolved});
        gpa.free(resolved);
        if (root.statFile(io, candidate, .{})) |_| return candidate else |_| gpa.free(candidate);
        return null;
    }
    if (!std.mem.endsWith(u8, resolved, ".html")) {
        const candidate = try std.fmt.allocPrint(gpa, "{s}.html", .{resolved});
        gpa.free(resolved);
        if (root.statFile(io, candidate, .{})) |_| return candidate else |_| gpa.free(candidate);
        return null;
    }
    return null;
}

fn lineNumber(source: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (source[0..@min(offset, source.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn collectHrefFindings(
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    root: Io.Dir,
    io: Io,
    source_path: []const u8,
    html: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, html, cursor, "href=\"")) |start| {
        const value_start = start + "href=\"".len;
        const end = std.mem.indexOfScalarPos(u8, html, value_start, '"') orelse {
            // Unterminated value: skip it and keep scanning for later hrefs.
            cursor = value_start;
            continue;
        };
        const href = html[value_start..end];
        cursor = end + 1;
        if (isIgnoredHref(href)) continue;

        const target_path = try findOutputPath(retain, root, io, source_path, href);
        if (target_path) |path| {
            defer retain.free(path);
            if (std.mem.indexOfScalar(u8, href, '#')) |hash| {
                const fragment = href[hash + 1 ..];
                const target_html = try archaeology.readFileAlloc(io, root, path, retain);
                const marker = try std.fmt.allocPrint(retain, "id=\"{s}\"", .{fragment});
                if (std.mem.indexOf(u8, target_html, marker) == null) {
                    try findings.append(gpa, .{ .source = try retain.dupe(u8, source_path), .target = try retain.dupe(u8, href), .line = lineNumber(html, start), .kind = "missing_fragment", .reason = "target exists but fragment id was not found" });
                }
            }
        } else {
            try findings.append(gpa, .{ .source = try retain.dupe(u8, source_path), .target = try retain.dupe(u8, href), .line = lineNumber(html, start), .kind = "missing_route", .reason = "local href did not resolve to a generated file" });
        }
    }
}

fn writeFile(io: Io, out: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try out.createDirPath(io, parent);
    try out.writeFile(io, .{ .sub_path = path, .data = data });
}

fn appendFmt(list: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const rendered = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(rendered);
    try list.appendSlice(gpa, rendered);
}

/// JSON string escaping: quotes, backslashes, and control characters are all
/// neutralized so an attacker-controlled href/path cannot corrupt the manifest.
fn appendJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => if (c < 0x20) {
            var esc: [6]u8 = undefined;
            try buf.appendSlice(a, try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}));
        } else try buf.append(a, c),
    };
    try buf.append(a, '"');
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var retain = std.heap.ArenaAllocator.init(gpa);
    defer retain.deinit();
    var root = try Io.Dir.cwd().openDir(io, opts.root_dir, .{ .iterate = true });
    defer root.close(io);
    const paths = try archaeology.collectFiles(io, retain.allocator(), retain.allocator(), root);
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);

    var html_count: usize = 0;
    for (paths) |path| {
        if (!std.mem.endsWith(u8, path, ".html")) continue;
        html_count += 1;
        const html = try archaeology.readFileAlloc(io, root, path, retain.allocator());
        try collectHrefFindings(gpa, retain.allocator(), root, io, path, html, &findings);
    }

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\n  \"format\": \"boris-link-audit-lab\",\n  \"schema_version\": 1,\n  \"html_files\": ");
    try appendFmt(&json, gpa, "{d},\n  \"findings\": [\n", .{html_count});
    for (findings.items, 0..) |f, i| {
        if (i > 0) try json.appendSlice(gpa, ",\n");
        try json.appendSlice(gpa, "    {\"source\":");
        try appendJson(&json, gpa, f.source);
        try json.appendSlice(gpa, ",\"target\":");
        try appendJson(&json, gpa, f.target);
        try json.appendSlice(gpa, ",\"line\":");
        try appendFmt(&json, gpa, "{d}", .{f.line});
        try json.appendSlice(gpa, ",\"kind\":");
        try appendJson(&json, gpa, f.kind);
        try json.appendSlice(gpa, ",\"reason\":");
        try appendJson(&json, gpa, f.reason);
        try json.appendSlice(gpa, "}");
    }
    try json.appendSlice(gpa, "\n  ]\n}\n");

    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(gpa);
    try appendFmt(&md, gpa, "# Link audit\n\nScanned **{d}** HTML files. Found **{d}** local-link findings.\n\n", .{ html_count, findings.items.len });
    if (findings.items.len == 0) {
        try md.appendSlice(gpa, "No missing local routes or fragments were found.\n");
    } else {
        try md.appendSlice(gpa, "| Source | Line | Target | Kind | Reason |\n|---|---:|---|---|---|\n");
        for (findings.items) |f| try appendFmt(&md, gpa, "| `{s}` | {d} | `{s}` | `{s}` | {s} |\n", .{ f.source, f.line, f.target, f.kind, f.reason });
    }
    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out.close(io);
    try writeFile(io, out, "link_audit.json", json.items);
    try writeFile(io, out, "REPORT.md", md.items);
    if (!opts.quiet) std.debug.print("link-audit: scanned {d} HTML files, found {d} findings\n", .{ html_count, findings.items.len });
}

test "link audit ignores external and hash links" {
    try std.testing.expect(isIgnoredHref("#top"));
    try std.testing.expect(isIgnoredHref("https://example.com"));
    try std.testing.expect(!isIgnoredHref("../missing.html"));
}

test "link audit appendJson escapes href control characters and quotes" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendJson(&buf, a, "a\"b\\c\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\u0001\"", buf.items);
}
