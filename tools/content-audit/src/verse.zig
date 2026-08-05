//! Verse-unit counting for boris-content-audit (poetry mode).
//!
//! Counts semantic verse units in the Markdown body, never raw occurrences of
//! obsolete MDX component names. Supported shapes (see docs/poetry-shapes.md):
//!   - lined block shapes (haiku = 3 lines, limerick = 5 lines): a unit is a
//!     blank-line-separated block of exactly the canonical line count;
//!     anything else is a malformed/partial unit, reported separately.
//!   - paragraph shape (aphorism): a unit is a blank-line-separated paragraph
//!     of one or more lines.
//!
//! Ignored: frontmatter (caller passes the body), fenced code blocks,
//! ATX headings (which only label a page or collection), and blank lines.
//! Lines are preserved byte-for-byte (Unicode exactly); only trailing `\r`
//! line-ending artifacts are removed for counting. Nothing is executed.

const std = @import("std");
const util = @import("util.zig");
const policy_mod = @import("policy.zig");

pub const Shape = struct {
    /// Poetry type name this shape implements ("haiku", "limerick", "aphorism").
    name: []const u8,
    /// Canonical line count for lined shapes; null means paragraph mode.
    line_count: ?usize,
};

pub const Unit = struct {
    lines: [][]const u8,
    placeholder: bool,
};

pub const MalformedUnit = struct {
    expected_lines: usize,
    actual_lines: usize,
    first_line: []const u8,
};

pub const Result = struct {
    units: []Unit,
    malformed_units: []MalformedUnit,
    complete_count: usize,
    placeholder_count: usize,
    substantive_count: usize,
    malformed_count: usize,
};

/// Built-in shape table for the documented poetry types. A policy may name
/// other types; they fall back to paragraph mode with an informational
/// exception emitted by the audit (never silently treated as a known shape).
pub fn shapeForType(name: []const u8) Shape {
    if (util.eql(name, "haiku")) return .{ .name = name, .line_count = 3 };
    if (util.eql(name, "limerick")) return .{ .name = name, .line_count = 5 };
    if (util.eql(name, "aphorism")) return .{ .name = name, .line_count = null };
    return .{ .name = name, .line_count = null };
}

pub fn isRegisteredShape(name: []const u8) bool {
    return util.eql(name, "haiku") or util.eql(name, "limerick") or util.eql(name, "aphorism");
}

fn stripCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn isBlank(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

fn isHeading(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i < line.len and line[i] == '#';
}

fn isFenceLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line.len >= i + 3 and util.eql(line[i .. i + 3], "```");
}

fn titleIsPlaceholder(policy_placeholder: policy_mod.PlaceholderPolicy, title: ?[]const u8) bool {
    const t = title orelse return false;
    if (policy_placeholder.title_prefixes.len == 0) return false;
    for (policy_placeholder.title_prefixes) |prefix| {
        if (policy_placeholder.case_sensitive) {
            if (std.mem.startsWith(u8, t, prefix)) return true;
        } else {
            if (t.len >= prefix.len and util.asciiCaseEqual(t[0..prefix.len], prefix)) return true;
        }
    }
    return false;
}

fn lineIsExactPlaceholder(policy_placeholder: policy_mod.PlaceholderPolicy, line: []const u8) bool {
    if (policy_placeholder.exact_lines.len == 0) return false;
    for (policy_placeholder.exact_lines) |sig| {
        if (policy_placeholder.case_sensitive) {
            if (util.eql(util.trim(line), sig)) return true;
        } else {
            if (util.asciiCaseEqual(util.trim(line), sig)) return true;
        }
    }
    return false;
}

/// Analyze a record body. `title` is used only for placeholder title prefixes.
pub fn analyze(gpa: std.mem.Allocator, body: []const u8, shape: Shape, policy_placeholder: policy_mod.PlaceholderPolicy, title: ?[]const u8) !Result {
    var units: std.ArrayList(Unit) = .empty;
    errdefer units.deinit(gpa);
    var malformed: std.ArrayList(MalformedUnit) = .empty;
    errdefer malformed.deinit(gpa);

    const title_stub = titleIsPlaceholder(policy_placeholder, title);

    var block: std.ArrayList([]const u8) = .empty;
    defer block.deinit(gpa);
    var in_fence = false;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = stripCr(raw_line);
        if (isFenceLine(line)) {
            in_fence = !in_fence;
            // A fence immediately ends any open block (a block cannot contain fences).
            if (block.items.len > 0) try flushBlock(gpa, &block, &units, &malformed, shape, title_stub, policy_placeholder);
            continue;
        }
        if (in_fence) continue;
        if (isHeading(line)) {
            if (block.items.len > 0) try flushBlock(gpa, &block, &units, &malformed, shape, title_stub, policy_placeholder);
            continue;
        }
        if (isBlank(line)) {
            if (block.items.len > 0) try flushBlock(gpa, &block, &units, &malformed, shape, title_stub, policy_placeholder);
            continue;
        }
        try block.append(gpa, line);
    }
    if (block.items.len > 0) try flushBlock(gpa, &block, &units, &malformed, shape, title_stub, policy_placeholder);

    var placeholder_count: usize = 0;
    for (units.items) |u| {
        if (u.placeholder) placeholder_count += 1;
    }
    const complete_count = units.items.len;
    const malformed_count = malformed.items.len;

    return .{
        .units = try units.toOwnedSlice(gpa),
        .malformed_units = try malformed.toOwnedSlice(gpa),
        .complete_count = complete_count,
        .placeholder_count = placeholder_count,
        .substantive_count = complete_count - placeholder_count,
        .malformed_count = malformed_count,
    };
}

fn flushBlock(
    gpa: std.mem.Allocator,
    block: *std.ArrayList([]const u8),
    units: *std.ArrayList(Unit),
    malformed: *std.ArrayList(MalformedUnit),
    shape: Shape,
    title_stub: bool,
    policy_placeholder: policy_mod.PlaceholderPolicy,
) !void {
    const count = block.items.len;
    const lines = block.items[0..count];
    if (shape.line_count) |expected| {
        if (count != expected) {
            try malformed.append(gpa, .{
                .expected_lines = expected,
                .actual_lines = count,
                .first_line = lines[0],
            });
            block.clearRetainingCapacity();
            return;
        }
    }
    var placeholder = title_stub;
    if (!placeholder) {
        for (lines) |l| {
            if (lineIsExactPlaceholder(policy_placeholder, l)) {
                placeholder = true;
                break;
            }
        }
    }
    // Copy the line pointers: the block buffer is reused for the next block.
    const owned_lines = try gpa.alloc([]const u8, count);
    @memcpy(owned_lines, lines);
    try units.append(gpa, .{ .lines = owned_lines, .placeholder = placeholder });
    block.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const ph_default: policy_mod.PlaceholderPolicy = .{};
const ph_awaiting: policy_mod.PlaceholderPolicy = .{ .exact_lines = &.{"Awaiting context"} };
const ph_stub: policy_mod.PlaceholderPolicy = .{ .title_prefixes = &.{"Stub:"} };
const ph_awaiting_cs: policy_mod.PlaceholderPolicy = .{ .exact_lines = &.{"Awaiting context"}, .case_sensitive = true };

fn ta() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "haiku three line blocks" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\# Title
        \\
        \\## Haikus
        \\
        \\first line here
        \\second line here
        \\third line here
        \\
        \\one two three
        \\four five six
        \\seven eight nine
        \\
    ;
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 2);
    try std.testing.expectEqual(r.malformed_count, 0);
}

test "haiku malformed block is reported separately" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body = "a\nb\nc\nd\n\nx\ny\nz\n";
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 1);
    try std.testing.expectEqual(r.malformed_count, 1);
    try std.testing.expectEqual(r.malformed_units[0].actual_lines, 4);
    try std.testing.expectEqual(r.malformed_units[0].expected_lines, 3);
}

test "limerick five line blocks" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\A feeling arrived with a face,
        \\Too particular yet for the case.
        \\The taxonomy smiled,
        \\Called it raw, unreconciled,
        \\And prepared it for governable space.
        \\
    ;
    const r = try analyze(a, body, shapeForType("limerick"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 1);
}

test "aphorism paragraph units" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\Root cause reassigned. Verification external.
        \\
        \\Evidence reviewed. Nothing was resolved.
        \\Second line of the same aphorism.
        \\
    ;
    const r = try analyze(a, body, shapeForType("aphorism"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 2);
    try std.testing.expectEqual(r.units[0].lines.len, 1);
    try std.testing.expectEqual(r.units[1].lines.len, 2);
}

test "fenced code is not counted" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\```
        \\line one
        \\line two
        \\line three
        \\```
        \\real one
        \\real two
        \\real three
        \\
    ;
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 1);
}

test "unicode preserved exactly" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body = "雪の朝\n二の字二の字の\n下駄のあと\n";
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 1);
    try std.testing.expectEqualStrings("雪の朝", r.units[0].lines[0]);
    try std.testing.expectEqualStrings("二の字二の字の", r.units[0].lines[1]);
}

test "placeholder detection exact line" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body = "Awaiting context\nAwaiting context\nAwaiting context\n";
    const r = try analyze(a, body, shapeForType("haiku"), ph_awaiting, "T");
    try std.testing.expectEqual(r.complete_count, 1);
    try std.testing.expectEqual(r.placeholder_count, 1);
    try std.testing.expectEqual(r.substantive_count, 0);
}

test "placeholder detection case insensitive" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body = "awaiting context\nawaiting context\nawaiting context\n";
    const r = try analyze(a, body, shapeForType("haiku"), ph_awaiting, "T");
    try std.testing.expectEqual(r.placeholder_count, 1);
    const r2 = try analyze(a, body, shapeForType("haiku"), ph_awaiting_cs, "T");
    try std.testing.expectEqual(r2.placeholder_count, 0);
}

test "title prefix marks all units placeholder" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body = "some real line\nsome real line\nsome real line\n";
    const r = try analyze(a, body, shapeForType("haiku"), ph_stub, "Stub: Draft Poem");
    try std.testing.expectEqual(r.placeholder_count, 1);
}
