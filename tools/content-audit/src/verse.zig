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
//! Unsupported shapes (types not registered in the shape table) are never
//! analyzed as paragraph units: `analyze` returns a zero result and the audit
//! reports them via an `unregistered_poetry_shape` structural exception.
//!
//! Ignored: frontmatter (caller passes the body), fenced code blocks, ATX
//! headings (which only label a page or collection), and blank lines. Fences
//! follow Markdown semantics: the opening fence character (backtick or tilde)
//! is remembered, the closing fence must use the same character with a length
//! at least the opening length, info strings are allowed on opening fences,
//! and unclosed fences are handled deterministically (their lines are never
//! counted). Lines are preserved byte-for-byte (Unicode exactly); only
//! trailing `\r` line-ending artifacts are removed for counting. Nothing is
//! executed.

const std = @import("std");
const util = @import("util.zig");
const policy_mod = @import("policy.zig");

pub const Shape = struct {
    /// Poetry type name this shape implements ("haiku", "limerick", "aphorism").
    name: []const u8,
    /// Canonical line count for lined shapes; null means paragraph mode.
    line_count: ?usize,
    /// True only for registered shapes; unsupported shapes are never counted.
    supported: bool,
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
/// other types; they are **not** analyzed as paragraph units: the audit emits
/// an `unregistered_poetry_shape` structural exception and `analyze` returns
/// a zero result for them.
pub fn shapeForType(name: []const u8) Shape {
    if (util.eql(name, "haiku")) return .{ .name = name, .line_count = 3, .supported = true };
    if (util.eql(name, "limerick")) return .{ .name = name, .line_count = 5, .supported = true };
    if (util.eql(name, "aphorism")) return .{ .name = name, .line_count = null, .supported = true };
    return .{ .name = name, .line_count = null, .supported = false };
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

const Fence = struct {
    char: u8,
    len: usize,
};

/// Detect a fence line: at least three consecutive backticks or tildes after
/// optional leading spaces, with an allowed info string after the run.
fn fenceOf(line: []const u8) ?Fence {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return null;
    const c = line[i];
    if (c != '`' and c != '~') return null;
    var len: usize = 0;
    while (i + len < line.len and line[i + len] == c) : (len += 1) {}
    if (len < 3) return null;
    return .{ .char = c, .len = len };
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
/// Unsupported shapes return a zero result: their verse is never counted as
/// paragraph units.
pub fn analyze(gpa: std.mem.Allocator, body: []const u8, shape: Shape, policy_placeholder: policy_mod.PlaceholderPolicy, title: ?[]const u8) !Result {
    if (!shape.supported) {
        return .{
            .units = &.{},
            .malformed_units = &.{},
            .complete_count = 0,
            .placeholder_count = 0,
            .substantive_count = 0,
            .malformed_count = 0,
        };
    }
    var units: std.ArrayList(Unit) = .empty;
    errdefer units.deinit(gpa);
    var malformed: std.ArrayList(MalformedUnit) = .empty;
    errdefer malformed.deinit(gpa);

    const title_stub = titleIsPlaceholder(policy_placeholder, title);

    var block: std.ArrayList([]const u8) = .empty;
    defer block.deinit(gpa);
    var in_fence = false;
    var fence_char: u8 = 0;
    var fence_len: usize = 0;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = stripCr(raw_line);
        if (!in_fence) {
            if (fenceOf(line)) |f| {
                // Opening fence: remember the character and length; an info
                // string may follow the run. A fence immediately ends any
                // open block (a block cannot contain fences).
                in_fence = true;
                fence_char = f.char;
                fence_len = f.len;
                if (block.items.len > 0) try flushBlock(gpa, &block, &units, &malformed, shape, title_stub, policy_placeholder);
                continue;
            }
        } else {
            // Closing fence: same character, length at least the opening
            // length; info strings are tolerated. Unclosed fences simply
            // consume the rest of the body deterministically (never counted).
            if (fenceOf(line)) |f| {
                if (f.char == fence_char and f.len >= fence_len) {
                    in_fence = false;
                }
            }
            continue;
        }
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
        // A unit is placeholder only when every non-empty line matches one of
        // the configured exact signatures; a single matching line inside an
        // otherwise substantive unit must not mark the whole unit placeholder.
        placeholder = true;
        for (lines) |l| {
            if (isBlank(l)) continue;
            if (!lineIsExactPlaceholder(policy_placeholder, l)) {
                placeholder = false;
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

test "one placeholder line inside substantive verse is not placeholder" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    // Only the first line matches the exact signature; the unit is substantive.
    const body = "Awaiting context\nreal line two\nreal line three\n";
    const r = try analyze(a, body, shapeForType("haiku"), ph_awaiting, "T");
    try std.testing.expectEqual(r.complete_count, 1);
    try std.testing.expectEqual(r.placeholder_count, 0);
    try std.testing.expectEqual(r.substantive_count, 1);
}

test "all lines must match for placeholder" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body = "Awaiting context\nAwaiting context\nAwaiting context\n";
    const r = try analyze(a, body, shapeForType("haiku"), ph_awaiting, "T");
    try std.testing.expectEqual(r.placeholder_count, 1);
    try std.testing.expectEqual(r.substantive_count, 0);
}

test "tilde fenced code is not counted" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\~~~
        \\line one
        \\line two
        \\line three
        \\~~~
        \\real one
        \\real two
        \\real three
        \\
    ;
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 1);
    try std.testing.expectEqualStrings("real one", r.units[0].lines[0]);
}

test "longer backtick close closes a short opening fence" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\```
        \\line one
        \\line two
        \\line three
        \\````
        \\real one
        \\real two
        \\real three
        \\
    ;
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 1);
}

test "shorter backtick close does not close" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\````
        \\line one
        \\line two
        \\line three
        \\```
        \\still fenced
        \\still fenced
        \\still fenced
        \\
    ;
    // The 3-tick line cannot close a 4-tick fence: everything stays fenced.
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 0);
}

test "mismatched fence character does not close" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\```
        \\line one
        \\line two
        \\line three
        \\~~~
        \\line four
        \\line five
        \\line six
        \\
    ;
    // A tilde fence cannot close a backtick fence: everything stays fenced.
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 0);
}

test "unclosed fence is deterministic and uncounted" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\real one
        \\real two
        \\real three
        \\
        \\```
        \\line one
        \\line two
        \\line three
        \\never closed
        \\
    ;
    const r = try analyze(a, body, shapeForType("haiku"), ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 1);
    try std.testing.expectEqualStrings("real one", r.units[0].lines[0]);
}

test "info strings allowed on opening fences" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\```poetry
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

test "unsupported poetry shape is not counted as paragraph units" {
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    const shape = shapeForType("sonnet");
    try std.testing.expect(!shape.supported);
    const body = "one\ntwo\nthree\n";
    const r = try analyze(a, body, shape, ph_default, "T");
    try std.testing.expectEqual(r.complete_count, 0);
    try std.testing.expectEqual(r.substantive_count, 0);
    try std.testing.expectEqual(r.units.len, 0);
}
