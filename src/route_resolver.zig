//! Shared, allocation-explicit resolution for rendered local URL references.
//!
//! Both the compiler publication gate and Doctor use this kernel. The compiler
//! keeps its historical lenient handling of malformed percent escapes; Doctor
//! selects the checked entry point so malformed rendered URLs become evidence
//! instead of being mistaken for literal paths.

const std = @import("std");

/// Maximum percent-decoding passes. Decoding to stability defeats multiply
/// encoded traversal such as `%252e%252e`; the bound stops a decoding loop.
const max_decode_passes = 4;

pub const Error = std.mem.Allocator.Error || error{MalformedPercentEscape};

pub const Resolution = union(enum) {
    /// Output-root-relative path the browser would request.
    path: []u8,
    /// Target climbs above the output root and can never be served.
    escapes_root,
};

pub fn stripFragment(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '#')) |i| return target[0..i];
    return target;
}

pub fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

pub fn fragment(target: []const u8) ?[]const u8 {
    const hash = std.mem.indexOfScalar(u8, target, '#') orelse return null;
    return target[hash + 1 ..];
}

/// True when a rendered target is empty, protocol-relative, or carries any URI
/// scheme. A generic scheme test is used so future schemes never become local
/// filesystem candidates. Same-document fragments are local and are therefore
/// not ignored here.
pub fn isExternalOrEmpty(target: []const u8) bool {
    if (target.len == 0) return true;
    if (std.mem.startsWith(u8, target, "//")) return true;
    if (!std.ascii.isAlphabetic(target[0])) return false;
    for (target, 0..) |c, i| {
        if (c == ':') return i > 0;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return false;
}

pub fn validatePercentEscapes(raw: []const u8) error{MalformedPercentEscape}!void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '%') {
            i += 1;
            continue;
        }
        if (i + 2 >= raw.len) return error.MalformedPercentEscape;
        _ = std.fmt.charToDigit(raw[i + 1], 16) catch return error.MalformedPercentEscape;
        _ = std.fmt.charToDigit(raw[i + 2], 16) catch return error.MalformedPercentEscape;
        i += 3;
    }
}

const DecodePolicy = enum { lenient, checked };

fn decode(
    gpa: std.mem.Allocator,
    raw: []const u8,
    passes: usize,
    normalize_separators: bool,
    policy: DecodePolicy,
) Error![]u8 {
    var current = try gpa.dupe(u8, raw);
    errdefer gpa.free(current);

    var pass: usize = 0;
    while (pass < passes) : (pass += 1) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        var changed = false;
        while (i < current.len) {
            if (current[i] == '%') {
                if (i + 2 >= current.len) {
                    if (policy == .checked) return error.MalformedPercentEscape;
                    try out.append(gpa, current[i]);
                    i += 1;
                    continue;
                }
                const hi = std.fmt.charToDigit(current[i + 1], 16) catch {
                    if (policy == .checked) return error.MalformedPercentEscape;
                    try out.append(gpa, current[i]);
                    i += 1;
                    continue;
                };
                const lo = std.fmt.charToDigit(current[i + 2], 16) catch {
                    if (policy == .checked) return error.MalformedPercentEscape;
                    try out.append(gpa, current[i]);
                    i += 1;
                    continue;
                };
                const byte = @as(u8, hi) * 16 + @as(u8, lo);
                try out.append(gpa, if (normalize_separators and byte == '\\') '/' else byte);
                i += 3;
                changed = true;
                continue;
            }
            try out.append(gpa, if (normalize_separators and current[i] == '\\') '/' else current[i]);
            i += 1;
        }
        const next = try out.toOwnedSlice(gpa);
        gpa.free(current);
        current = next;
        if (!changed) break;
    }
    return current;
}

fn resolve(
    gpa: std.mem.Allocator,
    source: []const u8,
    target: []const u8,
    policy: DecodePolicy,
) Error!Resolution {
    // A query-only or fragment-only reference addresses the source document.
    const no_fragment = stripFragment(target);
    if (no_fragment.len == 0 or no_fragment[0] == '?') {
        return .{ .path = try gpa.dupe(u8, source) };
    }

    const decoded = try decode(
        gpa,
        stripQuery(no_fragment),
        max_decode_passes,
        true,
        policy,
    );
    defer gpa.free(decoded);

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(gpa);

    if (!std.mem.startsWith(u8, decoded, "/")) {
        if (std.fs.path.dirnamePosix(source)) |dir| {
            var source_segments = std.mem.splitScalar(u8, dir, '/');
            while (source_segments.next()) |segment| {
                if (segment.len != 0 and !std.mem.eql(u8, segment, ".")) {
                    try segments.append(gpa, segment);
                }
            }
        }
    }

    const trailing_slash = std.mem.endsWith(u8, decoded, "/");
    var ended_on_dot_segment = false;
    var target_segments = std.mem.splitScalar(u8, decoded, '/');
    while (target_segments.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".")) {
            ended_on_dot_segment = true;
            continue;
        }
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len == 0) return .escapes_root;
            _ = segments.pop();
            ended_on_dot_segment = true;
            continue;
        }
        ended_on_dot_segment = false;
        try segments.append(gpa, segment);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (segments.items, 0..) |segment, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, segment);
    }
    if (trailing_slash or ended_on_dot_segment or out.items.len == 0) {
        if (out.items.len > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, "index.html");
    }
    return .{ .path = try out.toOwnedSlice(gpa) };
}

/// Historical compiler behavior. Malformed `%` sequences remain literal.
pub fn resolveWithinRoot(
    gpa: std.mem.Allocator,
    source: []const u8,
    target: []const u8,
) std.mem.Allocator.Error!Resolution {
    return resolve(gpa, source, target, .lenient) catch |err| switch (err) {
        error.MalformedPercentEscape => unreachable,
        else => |e| return e,
    };
}

/// Doctor behavior. The route algorithm is identical, but malformed percent
/// escapes fail closed as inspectable URL evidence.
pub fn resolveWithinRootChecked(
    gpa: std.mem.Allocator,
    source: []const u8,
    target: []const u8,
) Error!Resolution {
    return resolve(gpa, source, target, .checked);
}

/// Decode a URL fragment exactly once for comparison with browser-decoded HTML
/// `id` values. `+` remains `+`; fragment decoding is not form decoding.
pub fn decodeFragment(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    return decode(gpa, raw, 1, false, .checked);
}

test "compiler and checked resolution share route semantics" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        target: []const u8,
    }{
        .{ .source = "index.html", .target = "guide.html" },
        .{ .source = "guides/start.html", .target = "../index.html?q=1#top" },
        .{ .source = "index.html", .target = "%2e%2e/outside" },
        .{ .source = "guides/start.html", .target = "%252e%252e/index.html" },
        .{ .source = "index.html", .target = "nested%2fpage.html" },
    };
    for (cases) |case| {
        const historical = try resolveWithinRoot(gpa, case.source, case.target);
        const checked = try resolveWithinRootChecked(gpa, case.source, case.target);
        try std.testing.expectEqual(std.meta.activeTag(historical), std.meta.activeTag(checked));
        if (historical == .path) {
            defer gpa.free(historical.path);
            defer gpa.free(checked.path);
            try std.testing.expectEqualStrings(historical.path, checked.path);
        }
    }
}

test "checked decoding rejects malformed percent escapes without changing compiler behavior" {
    const gpa = std.testing.allocator;
    const historical = try resolveWithinRoot(gpa, "index.html", "bad%2.html");
    defer gpa.free(historical.path);
    try std.testing.expectEqualStrings("bad%2.html", historical.path);
    try std.testing.expectError(
        error.MalformedPercentEscape,
        resolveWithinRootChecked(gpa, "index.html", "bad%2.html"),
    );
    try std.testing.expectError(error.MalformedPercentEscape, decodeFragment(gpa, "bad%zz"));
}
