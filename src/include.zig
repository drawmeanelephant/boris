//! Boris-mediated Markdown includes (`{{include path}}`).
//!
//! Apex file includes stay off; this module expands directives in Zig before
//! Apex runs. Fence-aware: directives inside fenced code are left literal.
//!
//! Normative: `docs/contracts/includes-and-wiki-links.md`.

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const diag = @import("diag.zig");

pub const max_include_depth: usize = 32;

pub const IncludeError = error{
    IncludeSyntax,
    IncludeMissing,
    IncludeCycle,
    InvalidPath,
    DepthExceeded,
    OutOfMemory,
    ReadFailed,
};

pub const ScanHit = struct {
    path: []const u8,
    offset: usize,
    line: u32,
    column: u32,
};

/// Content-root-relative path grammar for include targets.
pub fn validateIncludePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;

    var i: usize = 0;
    var seg_start: usize = 0;
    while (i <= path.len) : (i += 1) {
        const at_end = i == path.len;
        const c: u8 = if (at_end) '/' else path[i];
        if (c == '/') {
            const seg = path[seg_start..i];
            if (seg.len == 0) return false;
            if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
            for (seg) |ch| {
                const ok = (ch >= 'A' and ch <= 'Z') or
                    (ch >= 'a' and ch <= 'z') or
                    (ch >= '0' and ch <= '9') or
                    ch == '.' or ch == '_' or ch == '-';
                if (!ok) return false;
            }
            seg_start = i + 1;
        }
    }
    return true;
}

pub fn lineColAt(source: []const u8, offset: usize) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    const lim = @min(offset, source.len);
    while (i < lim) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

fn atLineStart(body: []const u8, i: usize) bool {
    if (i == 0) return true;
    return body[i - 1] == '\n';
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn fenceAtLineStart(body: []const u8, i: usize) ?struct { u8, usize } {
    if (i >= body.len) return null;
    const ch = body[i];
    if (ch != '`' and ch != '~') return null;
    var run: usize = 0;
    var j = i;
    while (j < body.len and body[j] == ch) : (j += 1) run += 1;
    if (run < 3) return null;
    return .{ ch, run };
}

fn lineEndIndex(body: []const u8, i: usize) usize {
    var j = i;
    while (j < body.len and body[j] != '\n') : (j += 1) {}
    return j;
}

/// Body of a file: if frontmatter parses cleanly, return body slice; else whole source.
pub fn bodyOfSource(source: []const u8) []const u8 {
    const parsed = parser.parse(source);
    if (parsed.diagnostic != null) return source;
    return parsed.doc.body;
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) IncludeError![]u8 {
    var file = dir.openFile(io, path, .{}) catch return error.IncludeMissing;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .unlimited) catch return error.ReadFailed;
}

/// Scan body for `{{include path}}` outside fences. Paths are views into `body`.
pub fn scanIncludeDirectives(body: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(ScanHit)) IncludeError!void {
    var i: usize = 0;
    var fence_ch: u8 = 0;
    var fence_run: usize = 0;

    while (i < body.len) {
        if (atLineStart(body, i)) {
            if (fenceAtLineStart(body, i)) |f| {
                const ch = f[0];
                const run = f[1];
                if (fence_ch == 0) {
                    fence_ch = ch;
                    fence_run = run;
                    i = lineEndIndex(body, i);
                    if (i < body.len and body[i] == '\n') i += 1;
                    continue;
                } else if (ch == fence_ch and run >= fence_run) {
                    fence_ch = 0;
                    fence_run = 0;
                    i = lineEndIndex(body, i);
                    if (i < body.len and body[i] == '\n') i += 1;
                    continue;
                }
            }
        }

        if (fence_ch != 0) {
            i += 1;
            continue;
        }

        if (i + 9 <= body.len and std.mem.eql(u8, body[i .. i + 9], "{{include")) {
            const start = i;
            i += 9;
            if (i >= body.len or !isSpace(body[i])) {
                // Not a directive (e.g. `{{includeX`) — skip keyword chars only.
                continue;
            }
            while (i < body.len and isSpace(body[i])) : (i += 1) {}
            const path_start = i;
            while (i < body.len) {
                const c = body[i];
                if (c == '}' or c == '\n' or c == '\r') break;
                i += 1;
            }
            var path_end = i;
            while (path_end > path_start and isSpace(body[path_end - 1])) : (path_end -= 1) {}
            if (i + 1 >= body.len or body[i] != '}' or body[i + 1] != '}') {
                return error.IncludeSyntax;
            }
            i += 2;
            const path = body[path_start..path_end];
            if (path.len == 0 or !validateIncludePath(path)) {
                return error.InvalidPath;
            }
            const lc = lineColAt(body, start);
            try out.append(allocator, .{
                .path = path,
                .offset = start,
                .line = lc.line,
                .column = lc.column,
            });
            continue;
        }
        i += 1;
    }
}

/// Collect unique transitive include paths starting from a page body.
/// On cycle / missing / syntax error, returns the matching IncludeError.
/// Paths in `out_paths` are allocator-owned duplicates.
pub fn collectTransitiveIncludes(
    io: Io,
    content_dir: Io.Dir,
    allocator: std.mem.Allocator,
    root_body: []const u8,
    out_paths: *std.ArrayList([]const u8),
) IncludeError!void {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    try walkIncludes(io, content_dir, allocator, root_body, &stack, &seen, out_paths, 0);
}

fn walkIncludes(
    io: Io,
    content_dir: Io.Dir,
    allocator: std.mem.Allocator,
    body: []const u8,
    stack: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    out_paths: *std.ArrayList([]const u8),
    depth: usize,
) IncludeError!void {
    if (depth > max_include_depth) return error.DepthExceeded;

    var hits: std.ArrayList(ScanHit) = .empty;
    defer hits.deinit(allocator);
    try scanIncludeDirectives(body, allocator, &hits);

    for (hits.items) |hit| {
        for (stack.items) |s| {
            if (std.mem.eql(u8, s, hit.path)) return error.IncludeCycle;
        }

        var already = false;
        for (out_paths.items) |p| {
            if (std.mem.eql(u8, p, hit.path)) {
                already = true;
                break;
            }
        }
        if (!already) {
            try out_paths.append(allocator, try allocator.dupe(u8, hit.path));
        }

        if (seen.contains(hit.path)) continue;
        try seen.put(allocator, hit.path, {});

        const file_bytes = try readFileAlloc(io, content_dir, hit.path, allocator);
        defer allocator.free(file_bytes);
        const nested = bodyOfSource(file_bytes);

        try stack.append(allocator, hit.path);
        defer _ = stack.pop();

        try walkIncludes(io, content_dir, allocator, nested, stack, seen, out_paths, depth + 1);
    }
}

/// Expand includes in `body` into `arena`-owned markdown. `owner_path` seeds the cycle stack.
pub fn expandIncludes(
    io: Io,
    content_dir: Io.Dir,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    owner_path: []const u8,
) IncludeError![]u8 {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, owner_path);
    return expandRecursive(io, content_dir, gpa, arena, body, &stack, 0);
}

fn expandRecursive(
    io: Io,
    content_dir: Io.Dir,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    stack: *std.ArrayList([]const u8),
    depth: usize,
) IncludeError![]u8 {
    if (depth > max_include_depth) return error.DepthExceeded;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    var i: usize = 0;
    var fence_ch: u8 = 0;
    var fence_run: usize = 0;
    var copy_from: usize = 0;

    while (i < body.len) {
        if (atLineStart(body, i)) {
            if (fenceAtLineStart(body, i)) |f| {
                const ch = f[0];
                const run = f[1];
                if (fence_ch == 0) {
                    fence_ch = ch;
                    fence_run = run;
                    i = lineEndIndex(body, i);
                    if (i < body.len and body[i] == '\n') i += 1;
                    continue;
                } else if (ch == fence_ch and run >= fence_run) {
                    fence_ch = 0;
                    fence_run = 0;
                    i = lineEndIndex(body, i);
                    if (i < body.len and body[i] == '\n') i += 1;
                    continue;
                }
            }
        }

        if (fence_ch != 0) {
            i += 1;
            continue;
        }

        if (i + 9 <= body.len and std.mem.eql(u8, body[i .. i + 9], "{{include")) {
            const start = i;
            var j = i + 9;
            if (j >= body.len or !isSpace(body[j])) {
                i += 1;
                continue;
            }
            while (j < body.len and isSpace(body[j])) : (j += 1) {}
            const path_start = j;
            while (j < body.len) {
                const c = body[j];
                if (c == '}' or c == '\n' or c == '\r') break;
                j += 1;
            }
            var path_end = j;
            while (path_end > path_start and isSpace(body[path_end - 1])) : (path_end -= 1) {}
            if (j + 1 >= body.len or body[j] != '}' or body[j + 1] != '}') {
                return error.IncludeSyntax;
            }
            j += 2;
            const path = body[path_start..path_end];
            if (path.len == 0 or !validateIncludePath(path)) return error.InvalidPath;

            for (stack.items) |s| {
                if (std.mem.eql(u8, s, path)) return error.IncludeCycle;
            }

            try out.appendSlice(arena, body[copy_from..start]);

            const file_bytes = try readFileAlloc(io, content_dir, path, gpa);
            defer gpa.free(file_bytes);
            const nested_body = bodyOfSource(file_bytes);

            try stack.append(gpa, path);
            const expanded = try expandRecursive(io, content_dir, gpa, arena, nested_body, stack, depth + 1);
            _ = stack.pop();
            try out.appendSlice(arena, expanded);

            copy_from = j;
            i = j;
            continue;
        }
        i += 1;
    }

    try out.appendSlice(arena, body[copy_from..]);
    return try out.toOwnedSlice(arena);
}

pub fn errorCode(err: IncludeError) diag.Code {
    return switch (err) {
        error.IncludeSyntax => .EINCLUDESYNTAX,
        error.IncludeMissing => .EINCLUDEMISSING,
        error.IncludeCycle => .EINCLUDECYCLE,
        error.InvalidPath => .EINVALIDPATH,
        error.DepthExceeded => .EINCLUDECYCLE,
        error.OutOfMemory => .EIO,
        error.ReadFailed => .EIO,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "validateIncludePath accepts relative fragments" {
    try std.testing.expect(validateIncludePath("includes/sidebar.md"));
    try std.testing.expect(validateIncludePath("a/b_c-1.md"));
    try std.testing.expect(!validateIncludePath(""));
    try std.testing.expect(!validateIncludePath("/abs.md"));
    try std.testing.expect(!validateIncludePath("../x.md"));
    try std.testing.expect(!validateIncludePath("a/../b.md"));
    try std.testing.expect(!validateIncludePath("a//b.md"));
}

test "scanIncludeDirectives finds one and skips fences" {
    const body =
        \\Before
        \\{{include includes/a.md}}
        \\```
        \\{{include includes/skipped.md}}
        \\```
        \\After {{include includes/b.md}}
        \\
    ;
    var list: std.ArrayList(ScanHit) = .empty;
    defer list.deinit(std.testing.allocator);
    try scanIncludeDirectives(body, std.testing.allocator, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("includes/a.md", list.items[0].path);
    try std.testing.expectEqualStrings("includes/b.md", list.items[1].path);
}

test "scanIncludeDirectives rejects empty path" {
    const body = "{{include   }}";
    var list: std.ArrayList(ScanHit) = .empty;
    defer list.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidPath, scanIncludeDirectives(body, std.testing.allocator, &list));
}

test "bodyOfSource strips frontmatter" {
    const src =
        \\---
        \\title: X
        \\---
        \\Hello body
        \\
    ;
    const b = bodyOfSource(src);
    try std.testing.expect(std.mem.startsWith(u8, b, "Hello body"));
}

test "expandIncludes simple nested and cycle" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-include-expand";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try cwd.createDirPath(io, work ++ "/content/includes");
    try cwd.writeFile(io, .{ .sub_path = work ++ "/content/includes/a.md", .data = "FROM_A {{include includes/b.md}}\n" });
    try cwd.writeFile(io, .{ .sub_path = work ++ "/content/includes/b.md", .data = "FROM_B\n" });
    try cwd.writeFile(io, .{ .sub_path = work ++ "/content/includes/c.md", .data = "{{include includes/d.md}}" });
    try cwd.writeFile(io, .{ .sub_path = work ++ "/content/includes/d.md", .data = "{{include includes/c.md}}" });

    var content_dir = try cwd.openDir(io, work ++ "/content", .{});
    defer content_dir.close(io);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const body = "Start {{include includes/a.md}} End";
    const out = try expandIncludes(io, content_dir, gpa, a, body, "page.md");
    try std.testing.expect(std.mem.indexOf(u8, out, "FROM_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FROM_B") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "End") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "{{include") == null);

    try std.testing.expectError(
        error.IncludeCycle,
        expandIncludes(io, content_dir, gpa, a, "{{include includes/c.md}}", "page.md"),
    );

    try std.testing.expectError(
        error.IncludeMissing,
        expandIncludes(io, content_dir, gpa, a, "{{include includes/nope.md}}", "page.md"),
    );
}
