//! Boris-mediated Markdown includes (`{{include path}}`).
//!
//! Apex file includes stay off; this module expands directives in Zig before
//! Apex runs. Fence-aware: directives inside fenced code are left literal.
//!
//! Normative: `docs/contracts/includes-and-wiki-links.md`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const parser = @import("parser.zig");
const diag = @import("diag.zig");

pub const max_include_depth: usize = 32;
pub const max_expanded_bytes: usize = 16 * 1024 * 1024;
pub const max_include_expansions: usize = 4096;

pub const IncludeError = error{
    IncludeSyntax,
    IncludeMissing,
    IncludeCycle,
    InvalidPath,
    DepthExceeded,
    ExpansionBudgetExceeded,
    OutOfMemory,
    ReadFailed,
};

/// Max bytes retained for fail detail / locus paths (content-root-relative).
pub const max_fail_str: usize = 512;

/// Location + detail for the first include failure.
/// Strings are **copied into inline buffers** so nested file buffers can be freed safely.
pub const FailInfo = struct {
    line: u32 = 1,
    column: u32 = 1,
    detail_len: usize = 0,
    detail_buf: [max_fail_str]u8 = undefined,
    /// File where line/col apply (e.g. nested include path). Empty → caller page path.
    locus_len: usize = 0,
    locus_buf: [max_fail_str]u8 = undefined,

    pub fn detail(self: *const FailInfo) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    pub fn locus(self: *const FailInfo) []const u8 {
        return self.locus_buf[0..self.locus_len];
    }

    pub fn set(self: *FailInfo, line: u32, column: u32, detail_s: []const u8, locus_s: []const u8) void {
        self.line = line;
        self.column = column;
        self.detail_len = copyCap(&self.detail_buf, detail_s);
        self.locus_len = copyCap(&self.locus_buf, locus_s);
    }

    pub fn setAt(self: *FailInfo, body: []const u8, offset: usize, detail_s: []const u8, locus_s: []const u8) void {
        const lc = lineColAt(body, offset);
        self.set(lc.line, lc.column, detail_s, locus_s);
    }
};

fn copyCap(buf: *[max_fail_str]u8, s: []const u8) usize {
    const n = @min(s.len, buf.len);
    if (n > 0) @memcpy(buf[0..n], s[0..n]);
    return n;
}

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
            if (seg[0] == '.') return false;
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
    // Resolve every directory component through a no-follow handle. A no-follow
    // open only on the final file would still permit an intermediate symlink.
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');
    var current_dir = dir;
    var owned_dir: ?Io.Dir = null;
    defer if (owned_dir) |d| d.close(io);

    if (last_slash) |last| {
        var segments = std.mem.splitScalar(u8, path[0..last], '/');
        while (segments.next()) |segment| {
            const next_dir = current_dir.openDir(io, segment, .{
                .follow_symlinks = false,
            }) catch return error.IncludeMissing;
            if (owned_dir) |d| d.close(io);
            owned_dir = next_dir;
            current_dir = next_dir;
        }
    }

    const basename = if (last_slash) |last| path[last + 1 ..] else path;
    var file = current_dir.openFile(io, basename, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return error.IncludeMissing;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_expanded_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.ExpansionBudgetExceeded,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

fn setFail(fail_out: ?*FailInfo, body: []const u8, offset: usize, detail_s: []const u8, locus_s: []const u8) void {
    if (fail_out) |f| f.setAt(body, offset, detail_s, locus_s);
}

/// Scan body for `{{include path}}` outside fences. Paths are views into `body`.
/// On syntax/path errors, fills `fail_out` when provided.
/// `locus_path` is the content-root path of this body (page or include fragment).
pub fn scanIncludeDirectives(
    body: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ScanHit),
    fail_out: ?*FailInfo,
    locus_path: []const u8,
) IncludeError!void {
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
                setFail(fail_out, body, start, "", locus_path);
                return error.IncludeSyntax;
            }
            i += 2;
            const path = body[path_start..path_end];
            if (path.len == 0 or !validateIncludePath(path)) {
                setFail(fail_out, body, start, path, locus_path);
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
/// On cycle / missing / syntax error, returns the matching IncludeError and
/// fills `fail_out` when provided. Paths in `out_paths` are allocator-owned duplicates.
pub fn collectTransitiveIncludes(
    io: Io,
    content_dir: Io.Dir,
    allocator: std.mem.Allocator,
    root_body: []const u8,
    out_paths: *std.ArrayList([]const u8),
    fail_out: ?*FailInfo,
) IncludeError!void {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    // Root body locus is empty: caller supplies the page source_path when printing.
    try walkIncludes(io, content_dir, allocator, root_body, "", &stack, &seen, out_paths, 0, fail_out);
}

fn walkIncludes(
    io: Io,
    content_dir: Io.Dir,
    allocator: std.mem.Allocator,
    body: []const u8,
    /// Content-root path of `body` (empty at page root; include path when nested).
    locus_path: []const u8,
    stack: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    out_paths: *std.ArrayList([]const u8),
    depth: usize,
    fail_out: ?*FailInfo,
) IncludeError!void {
    if (depth > max_include_depth) {
        if (fail_out) |f| f.set(1, 1, "", locus_path);
        return error.DepthExceeded;
    }

    var hits: std.ArrayList(ScanHit) = .empty;
    defer hits.deinit(allocator);
    try scanIncludeDirectives(body, allocator, &hits, fail_out, locus_path);

    for (hits.items) |hit| {
        for (stack.items) |s| {
            if (std.mem.eql(u8, s, hit.path)) {
                if (fail_out) |f| f.set(hit.line, hit.column, hit.path, locus_path);
                return error.IncludeCycle;
            }
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

        const file_bytes = readFileAlloc(io, content_dir, hit.path, allocator) catch |err| {
            if (fail_out) |f| f.set(hit.line, hit.column, hit.path, locus_path);
            return err;
        };
        defer allocator.free(file_bytes);
        const nested = bodyOfSource(file_bytes);

        try stack.append(allocator, hit.path);
        defer _ = stack.pop();

        // Nested FailInfo copies strings into inline buffers before file_bytes free.
        var nested_fail: FailInfo = .{};
        walkIncludes(io, content_dir, allocator, nested, hit.path, stack, seen, out_paths, depth + 1, &nested_fail) catch |err| {
            if (fail_out) |f| f.* = nested_fail;
            return err;
        };
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
    fail_out: ?*FailInfo,
) IncludeError![]u8 {
    var budget: ExpansionBudget = .{};
    return expandIncludesWithBudget(io, content_dir, gpa, arena, body, owner_path, fail_out, &budget);
}

const ExpansionBudget = struct {
    byte_limit: usize = max_expanded_bytes,
    expansion_limit: usize = max_include_expansions,
    bytes: usize = 0,
    expansions: usize = 0,

    fn chargeExpansion(self: *ExpansionBudget) IncludeError!void {
        if (self.expansions >= self.expansion_limit) return error.ExpansionBudgetExceeded;
        self.expansions += 1;
    }

    fn chargeBytes(self: *ExpansionBudget, count: usize) IncludeError!void {
        if (count > self.byte_limit -| self.bytes) return error.ExpansionBudgetExceeded;
        self.bytes += count;
    }
};

fn expandIncludesWithBudget(
    io: Io,
    content_dir: Io.Dir,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    owner_path: []const u8,
    fail_out: ?*FailInfo,
    budget: *ExpansionBudget,
) IncludeError![]u8 {
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(gpa);
    var cache: std.StringHashMapUnmanaged([]const u8) = .{};
    defer cache.deinit(gpa);
    try stack.append(gpa, owner_path);
    // Root expansion: locus empty so diagnostics use owner_path from the caller.
    return expandRecursive(io, content_dir, gpa, arena, body, "", &stack, &cache, budget, 0, fail_out);
}

fn expandRecursive(
    io: Io,
    content_dir: Io.Dir,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    body: []const u8,
    locus_path: []const u8,
    stack: *std.ArrayList([]const u8),
    cache: *std.StringHashMapUnmanaged([]const u8),
    budget: *ExpansionBudget,
    depth: usize,
    fail_out: ?*FailInfo,
) IncludeError![]u8 {
    if (depth > max_include_depth) {
        if (fail_out) |f| f.set(1, 1, "", locus_path);
        return error.DepthExceeded;
    }

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
                setFail(fail_out, body, start, "", locus_path);
                return error.IncludeSyntax;
            }
            j += 2;
            const path = body[path_start..path_end];
            if (path.len == 0 or !validateIncludePath(path)) {
                setFail(fail_out, body, start, path, locus_path);
                return error.InvalidPath;
            }

            for (stack.items) |s| {
                if (std.mem.eql(u8, s, path)) {
                    setFail(fail_out, body, start, path, locus_path);
                    return error.IncludeCycle;
                }
            }

            budget.chargeExpansion() catch |err| {
                setFail(fail_out, body, start, path, locus_path);
                return err;
            };

            try out.appendSlice(arena, body[copy_from..start]);

            const expanded = cache.get(path) orelse expanded: {
                const file_bytes = readFileAlloc(io, content_dir, path, gpa) catch |err| {
                    setFail(fail_out, body, start, path, locus_path);
                    return err;
                };
                defer gpa.free(file_bytes);
                const nested_body = bodyOfSource(file_bytes);

                try stack.append(gpa, path);
                var nested_fail: FailInfo = .{};
                const value = expandRecursive(io, content_dir, gpa, arena, nested_body, path, stack, cache, budget, depth + 1, &nested_fail) catch |err| {
                    _ = stack.pop();
                    // nested_fail owns its strings; copy before nested buffers go out of scope.
                    if (fail_out) |f| f.* = nested_fail;
                    return err;
                };
                _ = stack.pop();

                const cache_key = try arena.dupe(u8, path);
                try cache.put(gpa, cache_key, value);
                break :expanded value;
            };
            budget.chargeBytes(expanded.len) catch |err| {
                setFail(fail_out, body, start, path, locus_path);
                return err;
            };
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
        error.ExpansionBudgetExceeded => .EINCLUDECYCLE,
        error.OutOfMemory => .EIO,
        error.ReadFailed => .EIO,
    };
}

pub fn remediationFor(code: diag.Code) []const u8 {
    return switch (code) {
        .EINCLUDESYNTAX => "Use {{include path/to/file.md}} with whitespace before the path and closing }}",
        .EINCLUDEMISSING => "Create the include file under the content root or fix the path",
        .EINCLUDECYCLE => "Break cycles or reduce nested/fan-out include expansion",
        .EINVALIDPATH => "Use content-root-relative non-dotfile segments [A-Za-z0-9._-]; no .., absolute, or backslash",
        .EIO => "Check filesystem permissions and path spelling",
        else => "Fix the include directive",
    };
}

fn messageFor(retain: std.mem.Allocator, err: IncludeError, fail: *const FailInfo) ![]const u8 {
    const det = fail.detail();
    return switch (err) {
        error.IncludeSyntax => try retain.dupe(u8, "malformed {{include …}} directive"),
        error.IncludeMissing => if (det.len > 0)
            try std.fmt.allocPrint(retain, "include target \"{s}\" not found or unreadable", .{det})
        else
            try retain.dupe(u8, "include target not found or unreadable"),
        error.IncludeCycle => if (det.len > 0)
            try std.fmt.allocPrint(retain, "include cycle involving \"{s}\"", .{det})
        else
            try retain.dupe(u8, "include cycle among nested fragments"),
        error.InvalidPath => if (det.len > 0)
            try std.fmt.allocPrint(retain, "illegal include path \"{s}\"", .{det})
        else
            try retain.dupe(u8, "illegal include path"),
        error.DepthExceeded => try retain.dupe(u8, "include nesting depth exceeded"),
        error.ExpansionBudgetExceeded => try retain.dupe(u8, "include expansion budget exceeded"),
        error.OutOfMemory => try retain.dupe(u8, "out of memory while resolving includes"),
        error.ReadFailed => if (det.len > 0)
            try std.fmt.allocPrint(retain, "failed to read include \"{s}\"", .{det})
        else
            try retain.dupe(u8, "failed to read include file"),
    };
}

/// Build a retain-owned diagnostic for an include failure (no UAF from temp buffers).
/// When `fail.locus()` is non-empty (nested fragment), it is used as `source_path`.
pub fn makeDiagnostic(
    retain: std.mem.Allocator,
    err: IncludeError,
    source_path: []const u8,
    fail: FailInfo,
) !diag.Diagnostic {
    const code = errorCode(err);
    const path = if (fail.locus().len > 0) fail.locus() else source_path;
    const det = fail.detail();
    return .{
        .severity = .error_,
        .code = code,
        .message = try messageFor(retain, err, &fail),
        .remediation = try retain.dupe(u8, remediationFor(code)),
        .source_path = try retain.dupe(u8, path),
        .line = fail.line,
        .column = fail.column,
        .id = if (det.len > 0) try retain.dupe(u8, det) else "",
    };
}

/// Print one structured include diagnostic to stderr via `diag.formatText`.
pub fn printDiagnostic(
    gpa: std.mem.Allocator,
    err: IncludeError,
    source_path: []const u8,
    fail: FailInfo,
) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const d = makeDiagnostic(arena.allocator(), err, source_path, fail) catch return;
    const line = diag.formatText(d, gpa) catch return;
    defer gpa.free(line);
    std.debug.print("{s}\n", .{line});
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
    try std.testing.expect(!validateIncludePath(".secret.md"));
    try std.testing.expect(!validateIncludePath("includes/.secret.md"));
    try std.testing.expect(!validateIncludePath(".hidden/fragment.md"));
}

test "scanIncludeDirectives finds one and skips backtick fences" {
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
    try scanIncludeDirectives(body, std.testing.allocator, &list, null, "");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("includes/a.md", list.items[0].path);
    try std.testing.expectEqualStrings("includes/b.md", list.items[1].path);
}

test "scanIncludeDirectives skips tilde fences" {
    const body =
        \\{{include includes/a.md}}
        \\~~~
        \\{{include includes/skipped.md}}
        \\~~~
        \\{{include includes/b.md}}
        \\
    ;
    var list: std.ArrayList(ScanHit) = .empty;
    defer list.deinit(std.testing.allocator);
    try scanIncludeDirectives(body, std.testing.allocator, &list, null, "");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("includes/a.md", list.items[0].path);
    try std.testing.expectEqualStrings("includes/b.md", list.items[1].path);
}

test "scanIncludeDirectives rejects empty path with FailInfo" {
    const body = "{{include   }}";
    var list: std.ArrayList(ScanHit) = .empty;
    defer list.deinit(std.testing.allocator);
    var fail: FailInfo = .{};
    try std.testing.expectError(error.InvalidPath, scanIncludeDirectives(body, std.testing.allocator, &list, &fail, "page.md"));
    try std.testing.expectEqual(@as(u32, 1), fail.line);
    try std.testing.expectEqual(@as(u32, 1), fail.column);
    try std.testing.expectEqualStrings("page.md", fail.locus());
}

test "makeDiagnostic is retain-owned and maps codes" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var fail: FailInfo = .{};
    fail.set(3, 5, "includes/missing.md", "");
    const d = try makeDiagnostic(arena.allocator(), error.IncludeMissing, "guides/a.md", fail);
    try std.testing.expect(d.code == .EINCLUDEMISSING);
    try std.testing.expectEqualStrings("guides/a.md", d.source_path);
    try std.testing.expect(d.line.? == 3);
    try std.testing.expect(d.column.? == 5);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "includes/missing.md") != null);
    try std.testing.expect(d.remediation.len > 0);

    const line = try diag.formatText(d, gpa);
    defer gpa.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "EINCLUDEMISSING") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "guides/a.md:3:5") != null);
}

test "makeDiagnostic prefers nested locus path" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var fail: FailInfo = .{};
    fail.set(1, 1, "includes/deep.md", "includes/mid.md");
    const d = try makeDiagnostic(arena.allocator(), error.IncludeMissing, "page.md", fail);
    try std.testing.expectEqualStrings("includes/mid.md", d.source_path);
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
    const out = try expandIncludes(io, content_dir, gpa, a, body, "page.md", null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FROM_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FROM_B") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "End") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "{{include") == null);

    var cycle_fail: FailInfo = .{};
    try std.testing.expectError(
        error.IncludeCycle,
        expandIncludes(io, content_dir, gpa, a, "{{include includes/c.md}}", "page.md", &cycle_fail),
    );
    try std.testing.expect(cycle_fail.detail().len > 0);

    var miss_fail: FailInfo = .{};
    try std.testing.expectError(
        error.IncludeMissing,
        expandIncludes(io, content_dir, gpa, a, "{{include includes/nope.md}}", "page.md", &miss_fail),
    );
    try std.testing.expectEqualStrings("includes/nope.md", miss_fail.detail());
    try std.testing.expectEqual(@as(u32, 1), miss_fail.line);

    // Nested missing: locus is the include fragment that holds the bad directive.
    try cwd.writeFile(io, .{ .sub_path = work ++ "/content/includes/outer.md", .data = "x\n{{include includes/nope.md}}\n" });
    var nested_miss: FailInfo = .{};
    try std.testing.expectError(
        error.IncludeMissing,
        expandIncludes(io, content_dir, gpa, a, "{{include includes/outer.md}}", "page.md", &nested_miss),
    );
    try std.testing.expectEqualStrings("includes/nope.md", nested_miss.detail());
    try std.testing.expectEqualStrings("includes/outer.md", nested_miss.locus());
    try std.testing.expectEqual(@as(u32, 2), nested_miss.line);
}

test "expandIncludes bounds exponential fan-out" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-include-budget";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try cwd.createDirPath(io, work ++ "/content/includes");
    try cwd.writeFile(io, .{ .sub_path = work ++ "/content/includes/level-00.md", .data = "x" });

    var level: usize = 1;
    while (level <= 12) : (level += 1) {
        var name_buf: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, work ++ "/content/includes/level-{d:0>2}.md", .{level});
        var body_buf: [128]u8 = undefined;
        const body_text = try std.fmt.bufPrint(
            &body_buf,
            "{{{{include includes/level-{d:0>2}.md}}}}{{{{include includes/level-{d:0>2}.md}}}}",
            .{ level - 1, level - 1 },
        );
        try cwd.writeFile(io, .{ .sub_path = name, .data = body_text });
    }

    var content_dir = try cwd.openDir(io, work ++ "/content", .{});
    defer content_dir.close(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var budget: ExpansionBudget = .{
        .byte_limit = 1024,
        .expansion_limit = 10_000,
    };
    var fail: FailInfo = .{};

    try std.testing.expectError(
        error.ExpansionBudgetExceeded,
        expandIncludesWithBudget(
            io,
            content_dir,
            gpa,
            arena.allocator(),
            "{{include includes/level-12.md}}",
            "page.md",
            &fail,
            &budget,
        ),
    );
    try std.testing.expect(errorCode(error.ExpansionBudgetExceeded) == .EINCLUDECYCLE);
    try std.testing.expect(fail.detail().len > 0);
    try std.testing.expect(budget.bytes <= budget.byte_limit);
}

test "expandIncludes rejects symlink targets and symlink path components" {
    if (builtin.os.tag == .windows) return;

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = Io.Dir.cwd();
    const work = "zig-cache/boris-include-symlink";
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    try cwd.createDirPath(io, work ++ "/content/includes");
    try cwd.createDirPath(io, work ++ "/content/real");
    try cwd.writeFile(io, .{ .sub_path = work ++ "/content/includes/real.md", .data = "secret\n" });
    try cwd.writeFile(io, .{ .sub_path = work ++ "/content/real/secret.md", .data = "secret\n" });

    var includes_dir = try cwd.openDir(io, work ++ "/content/includes", .{});
    defer includes_dir.close(io);
    includes_dir.symLink(io, "real.md", "alias.md", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };

    var content_dir = try cwd.openDir(io, work ++ "/content", .{});
    defer content_dir.close(io);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var file_fail: FailInfo = .{};
    try std.testing.expectError(
        error.IncludeMissing,
        expandIncludes(io, content_dir, gpa, arena.allocator(), "{{include includes/alias.md}}", "page.md", &file_fail),
    );
    try std.testing.expectEqualStrings("includes/alias.md", file_fail.detail());

    content_dir.symLink(io, "real", "linked", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };
    var dir_fail: FailInfo = .{};
    try std.testing.expectError(
        error.IncludeMissing,
        expandIncludes(io, content_dir, gpa, arena.allocator(), "{{include linked/secret.md}}", "page.md", &dir_fail),
    );
    try std.testing.expectEqualStrings("linked/secret.md", dir_fail.detail());
}
