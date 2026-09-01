//! Shared front matter pre-pass: sniff, strip, and parse YAML (`---`) or
//! TOML (`+++`) front matter at the very start of the input, before any
//! frontend sees the bytes (docs/FRONTMATTER.md).
//!
//! The parsing is a documented, bounded Oliver-chosen subset — not a
//! reference YAML/TOML implementation. Anything outside the subset keeps
//! the entire payload raw with one `frontmatter-parse-unsupported`
//! diagnostic; Oliver never guesses. The body strip happens regardless:
//! front matter is never content, parsed or not.
//!
//! Clean-room rule: no YAML or TOML parser implementation source was
//! consulted; the subset grammar is Oliver's own (docs/CLEANROOM.md).

const std = @import("std");
const source = @import("source.zig");
const diagnostic = @import("diagnostic.zig");

/// The user-facing option: no front matter handling, or which fence
/// dialect to recognize. Shared by all three frontends
/// (`oliver.ParseOptions.frontmatter`, `cooklang.ParseOptions.frontmatter`).
pub const Option = enum {
    none,
    yaml,
    toml,
};

/// A parsed metadata tree (docs/FRONTMATTER.md §7). All memory is
/// arena-owned (the document's or recipe's arena); `deinit` releases it
/// with everything else.
pub const Metadata = struct {
    entries: []Entry,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    /// Raw lexical bytes — no type coercion (`"42"` stays `42`, `true`
    /// stays `true`). Double-quoted strings are decoded (`\"` → `"`,
    /// `\\` → `\`); every other form is a source slice.
    scalar: []const u8,
    list: []Value,
    map: Metadata,
};

/// An extracted front matter block.
pub const Extracted = struct {
    /// The whole block, both fences included (span into the original
    /// input).
    span: source.Span,
    /// The raw payload bytes between the fences, including the trailing
    /// newline of the last content line (a borrowed source slice; empty
    /// for `---\n---`).
    raw: []const u8,
    /// Parsed metadata when parsing was requested and the payload is in
    /// subset; null when parsing was not requested or the payload is out
    /// of subset (the whole payload stays raw).
    metadata: ?Metadata,
};

/// The outcome of the pre-pass: the block (if any) and the clean body —
/// `input` with the block stripped, ready for the chosen frontend.
pub const Result = struct {
    block: ?Extracted,
    body: []const u8,
};

pub const ParseError = error{OutOfMemory};

/// Sniffs a front matter block at the very start of `input` and strips it
/// from the body passed to the frontend.
///
/// - `mode == .none`: nothing is sniffed; `body == input`.
/// - The opening fence must be the first line (exactly `---` / `+++` at
///   offset 0, no leading whitespace), and a later line must close it
///   (the same marker, trailing whitespace allowed).
/// - An unclosed opener is not front matter: the bytes reach the frontend
///   unchanged and the `unclosed-frontmatter` diagnostic fires.
/// - When `parse` is true, the payload is parsed into `metadata` under
///   the bounded subset; an out-of-subset payload stays raw with one
///   `frontmatter-parse-unsupported` diagnostic (span at the first
///   offending line), and the strip still happens.
pub fn preprocess(
    a: std.mem.Allocator,
    input: []const u8,
    mode: Option,
    parse: bool,
    diags: *std.ArrayList(diagnostic.Diagnostic),
) ParseError!Result {
    if (mode == .none) return .{ .block = null, .body = input };
    const fence = fenceFor(mode);

    var lines = source.Lines.init(input);
    const first = lines.next() orelse return .{ .block = null, .body = input };
    if (!isFence(first.text, fence)) return .{ .block = null, .body = input };

    var raw_start: ?u32 = null;
    while (lines.next()) |line| {
        if (isFence(line.text, fence)) {
            const payload_start: u32 = raw_start orelse @intCast(line.start);
            const payload = source.Span{ .start = payload_start, .end = @intCast(line.start) };
            var metadata: ?Metadata = null;
            if (parse) {
                switch (try parsePayload(a, input, payload, mode)) {
                    .ok => |m| metadata = m,
                    .unsupported => |off| try emitUnsupported(a, diags, input, off),
                }
            }
            return .{
                .block = .{
                    .span = .{ .start = @intCast(first.start), .end = @intCast(line.end) },
                    .raw = input[payload.start..payload.end],
                    .metadata = metadata,
                },
                .body = input[line.end..],
            };
        }
        if (raw_start == null) raw_start = @intCast(line.start);
    }

    // No closing fence: the opener is ordinary content (degradation is
    // the documented behavior), with a structured warning so consumers
    // can spot the dangling fence.
    try emitUnclosed(a, diags, input, first, fence);
    return .{ .block = null, .body = input };
}

fn fenceFor(mode: Option) [3]u8 {
    return switch (mode) {
        .yaml => .{ '-', '-', '-' },
        .toml => .{ '+', '+', '+' },
        .none => unreachable,
    };
}

/// A line whose first three bytes are the fence, followed only by spaces
/// or tabs (matching Cooklang's existing boundary rule).
fn isFence(text: []const u8, fence: [3]u8) bool {
    if (text.len < 3) return false;
    if (!std.mem.eql(u8, text[0..3], &fence)) return false;
    var i: usize = 3;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i == text.len;
}

// ---------------------------------------------------------------------------
// Diagnostics.
// ---------------------------------------------------------------------------

fn emitUnclosed(
    a: std.mem.Allocator,
    diags: *std.ArrayList(diagnostic.Diagnostic),
    input: []const u8,
    first: source.Line,
    fence: [3]u8,
) ParseError!void {
    const span = source.Span{ .start = @intCast(first.start), .end = @intCast(first.end) };
    const lc = (source.Source{ .bytes = input }).lineCol(span.start);
    try diags.append(a, .{
        .severity = .warning,
        .code = "unclosed-frontmatter",
        .offset = span.start + 1,
        .line = lc.line,
        .column = lc.column,
        .span = span,
        .message = if (fence[0] == '-')
            "front matter fence `---` never closed"
        else
            "front matter fence `+++` never closed",
    });
}

fn emitUnsupported(
    a: std.mem.Allocator,
    diags: *std.ArrayList(diagnostic.Diagnostic),
    input: []const u8,
    off: u32,
) ParseError!void {
    const span = source.Span{ .start = off, .end = off };
    const lc = (source.Source{ .bytes = input }).lineCol(off);
    try diags.append(a, .{
        .severity = .warning,
        .code = "frontmatter-parse-unsupported",
        .offset = off + 1,
        .line = lc.line,
        .column = lc.column,
        .span = span,
        .message = "front matter payload is outside the supported subset; kept raw",
    });
}

// ---------------------------------------------------------------------------
// Payload parsing (bounded YAML/TOML subsets).
// ---------------------------------------------------------------------------

/// A payload line: its text and its absolute byte offset into the input.
const Pl = struct {
    text: []const u8,
    start: u32,
};

const Outcome = union(enum) {
    ok: Metadata,
    /// Byte offset (into the input) of the first offending line.
    unsupported: u32,
};

fn parsePayload(
    a: std.mem.Allocator,
    input: []const u8,
    payload: source.Span,
    mode: Option,
) ParseError!Outcome {
    var plines = std.ArrayList(Pl).empty;
    defer plines.deinit(a);
    var lines = source.Lines.init(input[payload.start..payload.end]);
    while (lines.next()) |line| {
        try plines.append(a, .{
            .text = line.text,
            .start = @intCast(payload.start + line.start),
        });
    }
    return switch (mode) {
        .yaml => parseYaml(a, &plines),
        .toml => parseToml(a, &plines),
        .none => unreachable,
    };
}

fn isBlankOrComment(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return i == text.len or text[i] == '#';
}

/// Count of leading ASCII spaces (indentation; tabs in the leading run are
/// not indentation and make the line fail key/value splitting).
fn leadingSpaces(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    return i;
}

/// Appends `key: value` to `entries`; a duplicate key replaces the
/// earlier value in place (last wins — the YAML convention, pinned).
fn putEntry(a: std.mem.Allocator, entries: *std.ArrayList(Entry), key: []const u8, value: Value) ParseError!void {
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) {
            e.value = value;
            return;
        }
    }
    try entries.append(a, .{ .key = key, .value = value });
}

// ---------------------------------------------------------------------------
// YAML subset (docs/FRONTMATTER.md §4).
// ---------------------------------------------------------------------------

/// Top-level mappings only: `key: value` lines at the base indentation,
/// with nested maps and scalar lists as values by indentation. Returns
/// `Outcome.unsupported` with the first offending line when any line fails
/// the subset — the whole payload then stays raw.
fn parseYaml(a: std.mem.Allocator, plines: *const std.ArrayList(Pl)) ParseError!Outcome {
    var i: usize = 0;
    return yamlBlock(a, plines, &i, 0);
}

const KeyValue = struct {
    key: []const u8,
    /// The trimmed inline value; null when the value is empty or nested.
    rest: ?[]const u8,
};

/// Splits `key:` / `key: value` at the first `:` followed by space, tab,
/// or end of line. The key must be non-empty and contain no whitespace or
/// `:` (bounded subset: bare keys only).
fn splitYamlKey(text: []const u8) ?KeyValue {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ':') continue;
        if (i + 1 < text.len and text[i + 1] != ' ' and text[i + 1] != '\t') continue;
        const key = text[0..i];
        if (key.len == 0) return null;
        for (key) |c| {
            if (c == ' ' or c == '\t' or c == ':') return null;
        }
        const trimmed = std.mem.trim(u8, text[i + 1 ..], " \t");
        return .{ .key = key, .rest = if (trimmed.len == 0) null else trimmed };
    }
    return null;
}

fn isListItem(text: []const u8) bool {
    return text.len >= 2 and text[0] == '-' and text[1] == ' ';
}

/// The item text after `- `, trimmed.
fn splitListItem(text: []const u8) ?[]const u8 {
    if (!isListItem(text)) return null;
    return std.mem.trim(u8, text[2..], " \t");
}

/// A mapping block: lines at exactly `indent` (relative to the start of
/// the payload). Returns when a line dedents below `indent`; a line
/// deeper than `indent` is out of subset (nested values are opened only
/// at a key's value site).
fn yamlBlock(
    a: std.mem.Allocator,
    plines: *const std.ArrayList(Pl),
    i: *usize,
    indent: usize,
) ParseError!Outcome {
    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(a);
    while (i.* < plines.items.len) {
        const line = plines.items[i.*];
        if (isBlankOrComment(line.text)) {
            i.* += 1;
            continue;
        }
        const li = leadingSpaces(line.text);
        if (li < indent) break;
        if (li > indent) return .{ .unsupported = line.start };
        const kv = splitYamlKey(line.text[indent..]) orelse return .{ .unsupported = line.start };
        i.* += 1;
        var value: Value = undefined;
        if (kv.rest) |rest| {
            const s = parseScalar(a, rest) orelse return .{ .unsupported = line.start };
            value = .{ .scalar = s };
        } else {
            switch (try yamlValue(a, plines, i, indent)) {
                .unsupported => |off| return .{ .unsupported = off },
                .ok => |v| value = v,
            }
        }
        try putEntry(a, &entries, kv.key, value);
    }
    return .{ .ok = .{ .entries = try entries.toOwnedSlice(a) } };
}

/// The value of a `key:` with no inline content: an empty scalar, a
/// scalar list (`- item` lines, one consistent deeper indent), or a
/// nested map (key lines at the first key's deeper indent).
fn yamlValue(
    a: std.mem.Allocator,
    plines: *const std.ArrayList(Pl),
    i: *usize,
    parent_indent: usize,
) ParseError!union(enum) {
    ok: Value,
    unsupported: u32,
} {
    var j = i.*;
    while (j < plines.items.len and isBlankOrComment(plines.items[j].text)) : (j += 1) {}
    if (j >= plines.items.len) {
        i.* = j;
        return .{ .ok = .{ .scalar = "" } };
    }
    const line = plines.items[j];
    const li = leadingSpaces(line.text);
    // A nested value must be indented deeper than its key; otherwise the
    // value is empty and the line belongs to an outer frame.
    if (li <= parent_indent) {
        i.* = j;
        return .{ .ok = .{ .scalar = "" } };
    }
    const rest = line.text[li..];
    if (isListItem(rest)) {
        const list = try yamlList(a, plines, &j, li);
        i.* = j;
        return switch (list) {
            .unsupported => |off| .{ .unsupported = off },
            .ok => |v| .{ .ok = .{ .list = v } },
        };
    }
    // Nested map at the first key's indent (consistent deeper
    // indentation, pinned by fixture).
    const block = try yamlBlock(a, plines, &j, li);
    i.* = j;
    return switch (block) {
        .unsupported => |off| .{ .unsupported = off },
        .ok => |m| .{ .ok = .{ .map = m } },
    };
}

fn yamlList(
    a: std.mem.Allocator,
    plines: *const std.ArrayList(Pl),
    i: *usize,
    indent: usize,
) ParseError!union(enum) {
    ok: []Value,
    unsupported: u32,
} {
    var values = std.ArrayList(Value).empty;
    defer values.deinit(a);
    while (i.* < plines.items.len) {
        const line = plines.items[i.*];
        if (isBlankOrComment(line.text)) {
            i.* += 1;
            continue;
        }
        if (leadingSpaces(line.text) != indent) break;
        const item = splitListItem(line.text[indent..]) orelse return .{ .unsupported = line.start };
        i.* += 1;
        const s = parseScalar(a, item) orelse return .{ .unsupported = line.start };
        try values.append(a, .{ .scalar = s });
    }
    return .{ .ok = try values.toOwnedSlice(a) };
}

/// A scalar value: a double-quoted string (with `\"` / `\\` escapes), a
/// single-quoted literal, or a bare form (bare strings, integers, floats,
/// booleans, null — all kept as raw lexical bytes). Returns null when the
/// text is outside the subset. Shared by the YAML and TOML value
/// positions ("the same scalar vocabulary").
fn parseScalar(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (text.len == 0) return "";
    if (text[0] == '"') return doubleQuoted(a, text);
    if (text[0] == '\'') return singleQuoted(text);
    // Leading YAML indicators / flow markers reject a bare form.
    if (std.mem.indexOfScalar(u8, "&*!|>[]{}#,?%@`", text[0]) != null) return null;
    if (text.len >= 2 and ((text[0] == '-' and text[1] == ' ') or (text[0] == '?' and text[1] == ' '))) return null;
    // An inline comment (`value # comment`) or an embedded mapping
    // indicator (`a: b`) is outside the subset, not part of a bare value.
    if (std.mem.indexOf(u8, text, " #") != null) return null;
    if (std.mem.indexOf(u8, text, ": ") != null) return null;
    return text;
}

fn doubleQuoted(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != '"') return null;
    const inner = text[1 .. text.len - 1];
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    out.ensureTotalCapacity(a, inner.len) catch return null;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '\\') {
            if (i + 1 >= inner.len) return null;
            switch (inner[i + 1]) {
                '"' => {
                    out.appendAssumeCapacity('"');
                    i += 2;
                },
                '\\' => {
                    out.appendAssumeCapacity('\\');
                    i += 2;
                },
                else => return null,
            }
        } else {
            if (inner[i] == '"') return null; // unescaped quote inside
            out.appendAssumeCapacity(inner[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a) catch null;
}

fn singleQuoted(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != '\'') return null;
    const inner = text[1 .. text.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\'') != null) return null;
    return inner;
}

// ---------------------------------------------------------------------------
// TOML subset (docs/FRONTMATTER.md §5).
// ---------------------------------------------------------------------------

/// Build-time representation: `[name]` tables and `[[name]]` array
/// elements are mutated in place after creation, so the build uses
/// ArrayLists throughout and freezes them into the public model at the
/// end.
const BValue = union(enum) {
    scalar: []const u8,
    list: std.ArrayList(BValue),
    map: std.ArrayList(BEntry),
};

const BEntry = struct {
    key: []const u8,
    value: BValue,
};

/// Identifies the table that `key = value` lines go into. Headers are
/// absolute (TOML semantics), so a table is always a direct child of the
/// root — re-derived by key lookup on every line, never held across a
/// root mutation.
const TomlKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

const TomlCurrent = union(enum) {
    root,
    table: []const u8,
    array_elem: struct { key: []const u8, idx: usize },
};

fn tomlCurrentMap(root: *std.ArrayList(BEntry), current: TomlCurrent) ?*std.ArrayList(BEntry) {
    switch (current) {
        .root => return root,
        .table => |key| {
            for (root.items) |*e| {
                if (std.mem.eql(u8, e.key, key) and e.value == .map) return &e.value.map;
            }
            return null;
        },
        .array_elem => |ae| {
            for (root.items) |*e| {
                if (std.mem.eql(u8, e.key, ae.key) and e.value == .list) {
                    const list = &e.value.list;
                    if (ae.idx < list.items.len) return &list.items[ae.idx].map;
                }
            }
            return null;
        },
    }
}

/// `key = value` lines at the current table, `[name]` headers that open a
/// nested map, `[[name]]` headers that append a map to a list of maps.
/// Dotted keys, multi-line strings, dates, arrays, and inline tables are
/// outside the subset.
fn parseToml(a: std.mem.Allocator, plines: *const std.ArrayList(Pl)) ParseError!Outcome {
    var root = std.ArrayList(BEntry).empty;
    defer root.deinit(a);
    var current: TomlCurrent = .root;

    var i: usize = 0;
    while (i < plines.items.len) : (i += 1) {
        const line = plines.items[i];
        if (isBlankOrComment(line.text)) continue;
        const trimmed = std.mem.trim(u8, line.text, " \t");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '[') {
            if (try tomlHeader(a, &root, &current, line.start, trimmed)) |off| return .{ .unsupported = off };
            continue;
        }

        const kv = splitTomlKeyValue(a, trimmed) orelse return .{ .unsupported = line.start };
        const s = parseScalar(a, kv.value) orelse return .{ .unsupported = line.start };
        const map = tomlCurrentMap(&root, current) orelse return .{ .unsupported = line.start };
        try putBEntry(a, map, kv.key, .{ .scalar = s });
    }
    return .{ .ok = .{ .entries = try toPublicEntries(a, root.items) } };
}

/// Handles a `[table]` or `[[array-of-tables]]` header. Returns the byte
/// offset of the offending line on out-of-subset, null on success.
fn tomlHeader(
    a: std.mem.Allocator,
    root: *std.ArrayList(BEntry),
    current: *TomlCurrent,
    line_start: u32,
    trimmed: []const u8,
) ParseError!?u32 {
    if (std.mem.startsWith(u8, trimmed, "[[")) {
        if (trimmed.len < 4 or !std.mem.endsWith(u8, trimmed, "]]")) return line_start;
        const name = tomlKey(a, trimmed[2 .. trimmed.len - 2]) orelse return line_start;
        var found = false;
        for (root.items) |*e| {
            if (std.mem.eql(u8, e.key, name)) {
                if (e.value != .list) return line_start;
                found = true;
                break;
            }
        }
        if (!found) try root.append(a, .{ .key = name, .value = .{ .list = .empty } });
        const list = &root.items[root.items.len - 1].value.list;
        try list.append(a, .{ .map = .empty });
        current.* = .{ .array_elem = .{ .key = name, .idx = list.items.len - 1 } };
        return null;
    }

    if (trimmed.len < 2 or !std.mem.endsWith(u8, trimmed, "]")) return line_start;
    const name = tomlKey(a, trimmed[1 .. trimmed.len - 1]) orelse return line_start;
    for (root.items) |*e| {
        if (std.mem.eql(u8, e.key, name)) {
            if (e.value != .map) return line_start;
            current.* = .{ .table = name };
            return null;
        }
    }
    try root.append(a, .{ .key = name, .value = .{ .map = .empty } });
    current.* = .{ .table = name };
    return null;
}

fn putBEntry(a: std.mem.Allocator, entries: *std.ArrayList(BEntry), key: []const u8, value: BValue) ParseError!void {
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key)) {
            e.value = value;
            return;
        }
    }
    try entries.append(a, .{ .key = key, .value = value });
}

fn toPublicEntries(a: std.mem.Allocator, entries: []const BEntry) ParseError![]Entry {
    const out = try a.alloc(Entry, entries.len);
    for (entries, 0..) |be, i| {
        out[i] = .{
            .key = be.key,
            .value = switch (be.value) {
                .scalar => |s| .{ .scalar = s },
                .list => |*l| .{ .list = try toPublicValues(a, l.items) },
                .map => |*m| .{ .map = .{ .entries = try toPublicEntries(a, m.items) } },
            },
        };
    }
    return out;
}

fn toPublicValues(a: std.mem.Allocator, values: []const BValue) ParseError![]Value {
    const out = try a.alloc(Value, values.len);
    for (values, 0..) |bv, i| {
        out[i] = switch (bv) {
            .scalar => |s| .{ .scalar = s },
            .list => |*l| .{ .list = try toPublicValues(a, l.items) },
            .map => |*m| .{ .map = .{ .entries = try toPublicEntries(a, m.items) } },
        };
    }
    return out;
}

/// A TOML key: bare (`key`) or quoted (`"key"` / `'key'`). Dotted keys
/// and whitespace inside bare keys are outside the subset.
fn tomlKey(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    if (t[0] == '"' or t[0] == '\'') return parseScalar(a, t);
    for (t) |c| {
        if (c == ' ' or c == '\t' or c == '.' or c == '=' or c == '[' or c == ']') return null;
    }
    return t;
}

fn splitTomlKeyValue(a: std.mem.Allocator, text: []const u8) ?TomlKeyValue {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    const key = tomlKey(a, text[0..eq]) orelse return null;
    const value = std.mem.trim(u8, text[eq + 1 ..], " \t");
    if (value.len == 0) return null;
    return .{ .key = key, .value = value };
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Runs the pre-pass the way production callers do — arena-backed, so the
/// metadata and diagnostics own their memory without per-slice frees.
fn preprocessT(a: std.mem.Allocator, input: []const u8, mode: Option, parse: bool) !struct {
    arena: std.heap.ArenaAllocator,
    result: Result,
    diags: std.ArrayList(diagnostic.Diagnostic),
} {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const arena_a = arena.allocator();
    var diags = std.ArrayList(diagnostic.Diagnostic).empty;
    const result = try preprocess(arena_a, input, mode, parse, &diags);
    return .{ .arena = arena, .result = result, .diags = diags };
}

fn entry(meta: Metadata, key: []const u8) ?Value {
    for (meta.entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

test "frontmatter: none mode sniffs nothing" {
    var out = try preprocessT(testing.allocator, "---\ntitle: x\n---\nbody", .none, true);
    defer out.arena.deinit();
    try testing.expect(out.result.block == null);
    try testing.expectEqualStrings("---\ntitle: x\n---\nbody", out.result.body);
    try testing.expectEqual(@as(usize, 0), out.diags.items.len);
}

test "frontmatter: sniff, strip, and raw payload" {
    var out = try preprocessT(testing.allocator, "---\nsourced: babooshka\n---\n\nAdd @salt.", .yaml, false);
    defer out.arena.deinit();
    const b = out.result.block.?;
    try testing.expectEqualStrings("sourced: babooshka\n", b.raw);
    try testing.expectEqual(@as(u32, 0), b.span.start);
    try testing.expectEqual(@as(u32, 27), b.span.end);
    try testing.expectEqualStrings("\nAdd @salt.", out.result.body);
    try testing.expect(b.metadata == null); // parse = false
}

test "frontmatter: toml fence and body slice" {
    var out = try preprocessT(testing.allocator, "+++\ntitle = \"Hi\"\n+++\nBody", .toml, false);
    defer out.arena.deinit();
    const b = out.result.block.?;
    try testing.expectEqualStrings("title = \"Hi\"\n", b.raw);
    try testing.expectEqualStrings("Body", out.result.body);
}

test "frontmatter: unclosed opener passes through with a diagnostic" {
    var out = try preprocessT(testing.allocator, "---\ntitle: x", .yaml, true);
    defer out.arena.deinit();
    try testing.expect(out.result.block == null);
    try testing.expectEqualStrings("---\ntitle: x", out.result.body);
    try testing.expectEqual(@as(usize, 1), out.diags.items.len);
    try testing.expectEqualStrings("unclosed-frontmatter", out.diags.items[0].code);
    try testing.expectEqual(@as(u32, 0), out.diags.items[0].span.start);
}

test "frontmatter: empty payload parses to empty metadata" {
    var out = try preprocessT(testing.allocator, "---\n---", .yaml, true);
    defer out.arena.deinit();
    const b = out.result.block.?;
    try testing.expectEqualStrings("", b.raw);
    try testing.expectEqualStrings("", out.result.body);
    const m = b.metadata.?;
    try testing.expectEqual(@as(usize, 0), m.entries.len);
}

test "frontmatter: no fence at index 0 is ordinary input" {
    var out = try preprocessT(testing.allocator, "hello ---\n---", .yaml, true);
    defer out.arena.deinit();
    try testing.expect(out.result.block == null);
    try testing.expectEqualStrings("hello ---\n---", out.result.body);
}

test "frontmatter yaml: scalars keep raw lexical bytes" {
    var out = try preprocessT(testing.allocator, "---\ntitle: Hello\ncount: 42\npi: 3.14\nflag: true\nnull: NULL\nneg: -7\nquote: \"hi\"\nsingle: 'lit'\n---\n", .yaml, true);
    defer out.arena.deinit();
    const m = out.result.block.?.metadata.?;
    try testing.expectEqualStrings("Hello", entry(m, "title").?.scalar);
    try testing.expectEqualStrings("42", entry(m, "count").?.scalar);
    try testing.expectEqualStrings("3.14", entry(m, "pi").?.scalar);
    try testing.expectEqualStrings("true", entry(m, "flag").?.scalar);
    try testing.expectEqualStrings("NULL", entry(m, "null").?.scalar);
    try testing.expectEqualStrings("-7", entry(m, "neg").?.scalar);
    // Quoted forms decode; the value bytes stay raw otherwise.
    try testing.expectEqualStrings("hi", entry(m, "quote").?.scalar);
    try testing.expectEqualStrings("lit", entry(m, "single").?.scalar);
}

test "frontmatter: double-quoted escapes decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = doubleQuoted(arena.allocator(), "\"a\\\"b\\\\c\"") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a\"b\\c", v);
}

test "frontmatter yaml: lists, nested maps, comments, last wins" {
    var out = try preprocessT(
        testing.allocator,
        "---\n# a comment\nlist:\n  - a\n  - b\n\nnested:\n  key: value\n  deep:\n    x: 1\ndup: first\ndup: second\nempty:\n---\n",
        .yaml,
        true,
    );
    defer out.arena.deinit();
    const m = out.result.block.?.metadata.?;
    const list = entry(m, "list").?.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("a", list[0].scalar);
    try testing.expectEqualStrings("b", list[1].scalar);
    const nested = entry(m, "nested").?.map;
    try testing.expectEqualStrings("value", entry(nested, "key").?.scalar);
    const deep = entry(nested, "deep").?.map;
    try testing.expectEqualStrings("1", entry(deep, "x").?.scalar);
    // Last wins: the first position keeps the last value.
    const dup = entry(m, "dup").?;
    try testing.expectEqualStrings("second", dup.scalar);
    // `list`, `nested`, `dup`, `empty` — the duplicate keeps one slot.
    try testing.expectEqual(@as(usize, 4), m.entries.len);
    // `empty:` with no nested lines is an empty scalar.
    try testing.expectEqualStrings("", entry(m, "empty").?.scalar);
}

test "frontmatter yaml: out-of-subset keeps the whole payload raw" {
    // Flow collection on the first offending line; the body strip still
    // happens and one `frontmatter-parse-unsupported` diagnostic fires.
    var out = try preprocessT(testing.allocator, "---\nlist: [1, 2]\n---\nbody", .yaml, true);
    defer out.arena.deinit();
    const b = out.result.block.?;
    try testing.expect(b.metadata == null);
    try testing.expectEqualStrings("body", out.result.body);
    try testing.expectEqual(@as(usize, 1), out.diags.items.len);
    try testing.expectEqualStrings("frontmatter-parse-unsupported", out.diags.items[0].code);
    try testing.expectEqual(@as(u32, 4), out.diags.items[0].span.start);

    // A later offending line: span at that line.
    var out2 = try preprocessT(testing.allocator, "---\ntitle: ok\ninline: x # comment\n---\n", .yaml, true);
    defer out2.arena.deinit();
    try testing.expect(out2.result.block.?.metadata == null);
    try testing.expectEqual(@as(u32, 14), out2.diags.items[0].span.start);

    // Malformed shapes: tab indentation, empty key, `a:b`, flow scalar.
    var out3 = try preprocessT(testing.allocator, "---\n\tkey: v\n---\n", .yaml, true);
    defer out3.arena.deinit();
    try testing.expect(out3.result.block.?.metadata == null);
    var out4 = try preprocessT(testing.allocator, "---\n: v\n---\n", .yaml, true);
    defer out4.arena.deinit();
    try testing.expect(out4.result.block.?.metadata == null);
    var out5 = try preprocessT(testing.allocator, "---\na:b\n---\n", .yaml, true);
    defer out5.arena.deinit();
    try testing.expect(out5.result.block.?.metadata == null);
}

test "frontmatter yaml: inconsistent deeper indentation is out of subset" {
    var out = try preprocessT(testing.allocator, "---\nnested:\n  a: 1\n    b: 2\n---\n", .yaml, true);
    defer out.arena.deinit();
    try testing.expect(out.result.block.?.metadata == null);
    try testing.expectEqualStrings("frontmatter-parse-unsupported", out.diags.items[0].code);
    // The first offending line is `    b: 2` (offset 19): the nested map
    // at indent 2 is fine, but `b` is deeper than its sibling's level.
    try testing.expectEqual(@as(u32, 19), out.diags.items[0].span.start);
}

test "frontmatter toml: scalars, tables, and arrays of tables" {
    var out = try preprocessT(
        testing.allocator,
        "+++\ntitle = \"Hello\"\ncount = 42\n\n[server]\nhost = \"localhost\"\nport = 8080\n\n[[items]]\nname = \"a\"\n[[items]]\nname = \"b\"\n+++\n",
        .toml,
        true,
    );
    defer out.arena.deinit();
    const m = out.result.block.?.metadata.?;
    try testing.expectEqualStrings("Hello", entry(m, "title").?.scalar);
    try testing.expectEqualStrings("42", entry(m, "count").?.scalar);
    const server = entry(m, "server").?.map;
    try testing.expectEqualStrings("localhost", entry(server, "host").?.scalar);
    try testing.expectEqualStrings("8080", entry(server, "port").?.scalar);
    const items = entry(m, "items").?.list;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("a", entry(items[0].map, "name").?.scalar);
    try testing.expectEqualStrings("b", entry(items[1].map, "name").?.scalar);
}

test "frontmatter toml: out-of-subset shapes" {
    // Dotted key, inline table, and array are all outside the subset.
    var out = try preprocessT(testing.allocator, "+++\na.b = 1\n+++\n", .toml, true);
    defer out.arena.deinit();
    try testing.expect(out.result.block.?.metadata == null);
    var out2 = try preprocessT(testing.allocator, "+++\na = { x = 1 }\n+++\n", .toml, true);
    defer out2.arena.deinit();
    try testing.expect(out2.result.block.?.metadata == null);
    var out3 = try preprocessT(testing.allocator, "+++\na = [1, 2]\n+++\n", .toml, true);
    defer out3.arena.deinit();
    try testing.expect(out3.result.block.?.metadata == null);
    try testing.expectEqualStrings("frontmatter-parse-unsupported", out3.diags.items[0].code);
}

test "frontmatter toml: quoted keys and table re-open" {
    var out = try preprocessT(
        testing.allocator,
        "+++\n\"a key\" = 1\n[server]\nx = 1\n[server]\ny = 2\n+++\n",
        .toml,
        true,
    );
    defer out.arena.deinit();
    const m = out.result.block.?.metadata.?;
    try testing.expectEqualStrings("1", entry(m, "a key").?.scalar);
    const server = entry(m, "server").?.map;
    try testing.expectEqualStrings("1", entry(server, "x").?.scalar);
    try testing.expectEqualStrings("2", entry(server, "y").?.scalar);
}

test "frontmatter: CRLF payload and fences" {
    var out = try preprocessT(testing.allocator, "---\r\ntitle: Hello\r\n---\r\n\r\nBody", .yaml, true);
    defer out.arena.deinit();
    const b = out.result.block.?;
    try testing.expectEqualStrings("title: Hello\r\n", b.raw);
    try testing.expectEqualStrings("\r\nBody", out.result.body);
    try testing.expectEqualStrings("Hello", entry(b.metadata.?, "title").?.scalar);
}
