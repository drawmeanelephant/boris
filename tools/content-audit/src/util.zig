//! Shared deterministic helpers for boris-content-audit.
//!
//! Everything here is byte-stable: fixed escaping rules, sorted iteration,
//! and content hashing. No host clock, no random values, no absolute paths.

const std = @import("std");

pub const tool_version = "0.1.0";
pub const format_id = "boris-content-audit";
pub const report_schema_version: u32 = 1;
pub const output_owner_marker = ".boris-content-audit-output";
pub const stage_suffix = ".boris-content-audit-stage";
pub const backup_suffix = ".boris-content-audit-backup";

/// Exact ownership marker content. A directory is only treated as tool-owned
/// when this file exists **and** its bytes match this string exactly; a marker
/// with the right name but the wrong content is refused.
pub const output_owner_marker_content = "format=boris-content-audit\nschema_version=1\n";

/// Hard bound on the marker file we are willing to read during ownership
/// validation (markers are tiny; anything larger is not ours).
pub const max_marker_bytes: usize = 1024;

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[start..end];
}

/// Case-insensitive ASCII equality (used only for documented policy flags,
/// never for identity resolution).
pub fn asciiCaseEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + ('a' - 'A') else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + ('a' - 'A') else bc;
        if (al != bl) return false;
    }
    return true;
}

/// Append a JSON string (UTF-8 preserved byte-for-byte, control bytes escaped).
pub fn appendJsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(gpa, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

pub fn appendJsonBool(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: bool) !void {
    try buf.appendSlice(gpa, if (v) "true" else "false");
}

pub fn appendJsonNumber(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, n: usize) !void {
    try buf.print(gpa, "{d}", .{n});
}

/// Append `s` as exactly one argument of a POSIX-shell command line.
///
/// This is the single documented escaping path for every caller-controlled
/// value that survives into the emitted reproduction command (`--content-root`,
/// `--revision`, `--collection`, and the format/fail-on names). Values made
/// only of "plain" characters (ASCII alphanumerics plus `._-/`) are emitted
/// raw so stable values such as `rev-abc` stay byte-identical; anything else
/// is wrapped in single quotes with the standard `'\''` idiom, which keeps the
/// exact argument boundary under any POSIX shell (spaces, single quotes,
/// dollar signs, backticks, and shell metacharacters all survive literally).
pub fn appendShellQuoted(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    if (isPlainShellWord(s)) {
        try buf.appendSlice(gpa, s);
        return;
    }
    try buf.append(gpa, '\'');
    for (s) |c| {
        if (c == '\'') {
            // Close the quote, emit an escaped quote, reopen the quote.
            try buf.appendSlice(gpa, "'\\''");
        } else {
            try buf.append(gpa, c);
        }
    }
    try buf.append(gpa, '\'');
}

/// True when `s` is non-empty and needs no quoting under a POSIX shell.
/// Anything outside the plain set (whitespace, quotes, `$`, backticks,
/// glob/metacharacters, control bytes, ...) forces single-quote wrapping.
fn isPlainShellWord(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const plain = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-' or c == '/';
        if (!plain) return false;
    }
    return true;
}

/// HTML-escape untrusted text for static report pages.
pub fn appendHtmlEscaped(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try buf.appendSlice(gpa, "&amp;"),
        '<' => try buf.appendSlice(gpa, "&lt;"),
        '>' => try buf.appendSlice(gpa, "&gt;"),
        '"' => try buf.appendSlice(gpa, "&quot;"),
        '\'' => try buf.appendSlice(gpa, "&#39;"),
        else => try buf.append(gpa, c),
    };
}

/// Escape untrusted text for Markdown table cells and plain prose.
/// Neutralizes `|` (column breakout), `` ` `` (code-span breakout),
/// `\` (escape prefix), line breaks (row breakout), and HTML (`<`, `>`,
/// `&`) which GitHub renders inside Markdown (including tables).
pub fn appendMarkdownEscaped(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '|' => try buf.appendSlice(gpa, "\\|"),
        '`' => try buf.appendSlice(gpa, "\\`"),
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '&' => try buf.appendSlice(gpa, "&amp;"),
        '<' => try buf.appendSlice(gpa, "&lt;"),
        '>' => try buf.appendSlice(gpa, "&gt;"),
        '\n', '\r' => try buf.append(gpa, ' '),
        else => try buf.append(gpa, c),
    };
}

/// Append `s` as a Markdown inline-code span with a fence that cannot be
/// broken by backticks inside `s`. Uses the shortest fence longer than any
/// backtick run in `s`, exactly as CommonMark specifies for code spans.
pub fn appendMarkdownInlineCode(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    var max_run: usize = 0;
    var cur: usize = 0;
    for (s) |c| {
        if (c == '`') {
            cur += 1;
            if (cur > max_run) max_run = cur;
        } else {
            cur = 0;
        }
    }
    const fence_len = max_run + 1;
    for (0..fence_len) |_| try buf.append(gpa, '`');
    // CommonMark: pad with a single space when content starts/ends with
    // space or backtick so the fence is unambiguous.
    const needs_pad = s.len > 0 and (s[0] == ' ' or s[0] == '`' or s[s.len - 1] == ' ' or s[s.len - 1] == '`');
    if (needs_pad) try buf.append(gpa, ' ');
    for (s) |c| {
        if (c == '\n' or c == '\r') {
            try buf.append(gpa, ' ');
        } else {
            try buf.append(gpa, c);
        }
    }
    if (needs_pad) try buf.append(gpa, ' ');
    for (0..fence_len) |_| try buf.append(gpa, '`');
}

pub fn sortStrings(gpa: std.mem.Allocator, items: [][]const u8) void {
    _ = gpa;
    std.mem.sort([]const u8, items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

/// Hex SHA-256 over a byte slice — deterministic policy/report identity.
pub fn sha256Hex(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (digest) |b| try out.print(gpa, "{x:0>2}", .{b});
    return try out.toOwnedSlice(gpa);
}

/// FNV-1a 64-bit hex — cheap deterministic string fingerprint.
pub fn fnv1a64Hex(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var h: u64 = 14695981039346656037;
    for (data) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return try std.fmt.allocPrint(gpa, "{x:0>16}", .{h});
}

pub fn isSkippedDirName(name: []const u8) bool {
    const skip = [_][]const u8{
        ".git",
        ".DS_Store",
        "node_modules",
        "dist",
        ".cache",
        ".zig-cache",
        "zig-cache",
        "__pycache__",
    };
    for (skip) |s| {
        if (eql(name, s)) return true;
    }
    return false;
}

pub fn hasSymlinkComponent(io: std.Io, root: std.Io.Dir, rel: []const u8) bool {
    var checked: std.ArrayList(u8) = .empty;
    defer checked.deinit(std.heap.page_allocator);
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or eql(part, ".")) continue;
        if (eql(part, "..")) return true;
        if (checked.items.len > 0) checked.append(std.heap.page_allocator, '/') catch return true;
        checked.appendSlice(std.heap.page_allocator, part) catch return true;
        var target: [std.fs.max_path_bytes]u8 = undefined;
        _ = root.readLink(io, checked.items, &target) catch continue;
        return true;
    }
    return false;
}

/// Refuse any existing path component of an **absolute** path that is a
/// symlink. Walks from the filesystem root so relative and absolute caller
/// values are inspected identically: the caller canonicalizes the value to a
/// lexical absolute path first, and this walker checks every component of
/// that path as it exists on disk. Components that do not exist yet cannot
/// be symlinks, so the walk stops at the first missing component.
pub fn hasSymlinkComponentAbs(io: std.Io, abs: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, "/", .{}) catch return true;
    var parts = std.mem.splitScalar(u8, abs, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or eql(part, ".")) continue;
        var target: [std.fs.max_path_bytes]u8 = undefined;
        // readLink succeeds only when the component is a symlink; not-a-link
        // and missing components are errors and mean "keep walking".
        if (dir.readLink(io, part, &target)) |_| {
            dir.close(io);
            return true;
        } else |_| {}
        const next = dir.openDir(io, part, .{}) catch {
            dir.close(io);
            return false; // first missing component: nothing below can be a symlink
        };
        dir.close(io);
        dir = next;
    }
    dir.close(io);
    return false;
}

/// Resolve a relative path under a root into its canonical absolute path.
/// Refuses `..` escaping and symlink components (used for overlap checks).
pub fn canonicalPath(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, rel: []const u8) ![]u8 {
    _ = io;
    const owned = try gpa.dupe(u8, rel);
    var parts = std.mem.splitScalar(u8, owned, '/');
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    while (parts.next()) |part| {
        if (part.len == 0 or eql(part, ".")) continue;
        if (eql(part, "..")) return error.PathEscapesRoot;
        try out.append(gpa, part);
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, root.path orelse "/");
    for (out.items) |part| {
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '/') try buf.append(gpa, '/');
        try buf.appendSlice(gpa, part);
    }
    return try buf.toOwnedSlice(gpa);
}
