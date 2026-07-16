//! Deterministic page layout selection (layout-rule CLI surface).
//!
//! Pure selector logic over canonical entity id + resolved graph role.
//! No filesystem, no frontmatter dialect, no declaration-order precedence.
//! See docs/designs/page-layout-selection-rfc.md and
//! docs/contracts/templating-and-themes.md §4.

const std = @import("std");
const identity = @import("identity.zig");
const page_mod = @import("page.zig");

/// Maximum `--layout-rule` declarations per target (usage error beyond).
pub const max_rules_per_target: usize = 256;

pub const SelectorKind = enum {
    id,
    glob,
    role,

    /// Match precedence rank (lower wins earlier).
    pub fn rank(self: SelectorKind) u8 {
        return switch (self) {
            .id => 1,
            .glob => 2,
            .role => 3,
        };
    }

    pub fn name(self: SelectorKind) []const u8 {
        return @tagName(self);
    }
};

/// One closed layout rule. Strings are caller-owned (typically argv views).
pub const LayoutRule = struct {
    kind: SelectorKind,
    /// Exact entity id, glob pattern (no `glob:` prefix), or `trunk`/`satellite`.
    value: []const u8,
    layout_path: []const u8,

    /// Canonical selector text: `id:…`, `glob:…`, or `role:…`.
    pub fn writeSelector(self: LayoutRule, buf: []u8) ![]const u8 {
        return switch (self.kind) {
            .id => try std.fmt.bufPrint(buf, "id:{s}", .{self.value}),
            .glob => try std.fmt.bufPrint(buf, "glob:{s}", .{self.value}),
            .role => try std.fmt.bufPrint(buf, "role:{s}", .{self.value}),
        };
    }

    pub fn selectorBytesEqual(self: LayoutRule, other: LayoutRule) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.value, other.value);
    }
};

pub const ParseSelectorError = error{
    UnknownSelectorKind,
    InvalidSelector,
    EmptySelector,
};

pub const SelectError = error{
    AmbiguousGlob,
    DuplicateSelector,
    RuleLimitExceeded,
    MixedThemeRoots,
    InvalidLayoutPath,
    InvalidSelector,
    UnknownSelectorKind,
    EmptySelector,
    OutOfMemory,
};

/// Lexical layout-path grammar for build-owner layout configuration.
///
/// Accepts workspace-relative paths with `/` separators only. Rejects empty
/// paths, absolute forms, Windows drive letters, backslashes, empty segments,
/// and `.` / `..` segments. Does not touch the filesystem.
///
/// Applies to `--html-layout`, `--target-layout` paths, `--layout-rule` paths,
/// and product/library fallback layout strings (e.g. `layouts/main.html`).
pub fn validateLayoutPath(path: []const u8) error{InvalidLayoutPath}!void {
    if (path.len == 0) return error.InvalidLayoutPath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidLayoutPath;
    if (path.len >= 2 and path[1] == ':') return error.InvalidLayoutPath;
    if (path[path.len - 1] == '/' or path[path.len - 1] == '\\') return error.InvalidLayoutPath;

    var i: usize = 0;
    var seg_count: usize = 0;
    while (i < path.len) {
        const start = i;
        while (i < path.len and path[i] != '/' and path[i] != '\\') : (i += 1) {}
        if (i < path.len and path[i] == '\\') return error.InvalidLayoutPath;
        const seg = path[start..i];
        if (seg.len == 0) return error.InvalidLayoutPath;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidLayoutPath;
        seg_count += 1;
        if (i < path.len) i += 1; // skip '/'
    }
    if (seg_count == 0) return error.InvalidLayoutPath;
}

/// Parse a raw selector token (`id:…`, `glob:…`, `role:trunk|satellite`).
pub fn parseSelector(raw: []const u8) ParseSelectorError!struct { kind: SelectorKind, value: []const u8 } {
    if (raw.len == 0) return error.EmptySelector;
    if (std.mem.startsWith(u8, raw, "id:")) {
        const v = raw["id:".len..];
        if (v.len == 0) return error.InvalidSelector;
        if (!identity.validateEntityId(v)) return error.InvalidSelector;
        return .{ .kind = .id, .value = v };
    }
    if (std.mem.startsWith(u8, raw, "glob:")) {
        const v = raw["glob:".len..];
        if (v.len == 0) return error.InvalidSelector;
        try validateGlobPattern(v);
        return .{ .kind = .glob, .value = v };
    }
    if (std.mem.startsWith(u8, raw, "role:")) {
        const v = raw["role:".len..];
        if (std.mem.eql(u8, v, "trunk") or std.mem.eql(u8, v, "satellite")) {
            return .{ .kind = .role, .value = v };
        }
        return error.InvalidSelector;
    }
    return error.UnknownSelectorKind;
}

/// Glob pattern grammar: entity-id path shape; `*` only as a complete segment.
/// Rejects `**`, partial wildcards (`ref*`), absolute, empty, `.`, `..`, `\`.
pub fn validateGlobPattern(pattern: []const u8) ParseSelectorError!void {
    if (pattern.len == 0) return error.InvalidSelector;
    if (pattern[0] == '/' or pattern[0] == '\\') return error.InvalidSelector;
    if (pattern[pattern.len - 1] == '/' or pattern[pattern.len - 1] == '\\') return error.InvalidSelector;
    if (pattern.len > identity.max_entity_id_bytes) return error.InvalidSelector;

    var i: usize = 0;
    var seg_count: usize = 0;
    while (i < pattern.len) {
        const start = i;
        while (i < pattern.len and pattern[i] != '/' and pattern[i] != '\\') : (i += 1) {}
        if (i < pattern.len and pattern[i] == '\\') return error.InvalidSelector;
        const seg = pattern[start..i];
        if (seg.len == 0) return error.InvalidSelector;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidSelector;
        if (std.mem.eql(u8, seg, "**")) return error.InvalidSelector;
        if (std.mem.eql(u8, seg, "*")) {
            // Whole-segment wildcard — ok.
        } else {
            // Literal segment: no `*`, same char constraints as entity ids.
            for (seg) |c| {
                if (c == '*') return error.InvalidSelector;
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return error.InvalidSelector;
            }
        }
        seg_count += 1;
        if (i < pattern.len) i += 1;
    }
    if (seg_count == 0) return error.InvalidSelector;
}

/// Count literal (non-`*`) segments in a validated glob pattern.
pub fn globLiteralCount(pattern: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) {
        const start = i;
        while (i < pattern.len and pattern[i] != '/') : (i += 1) {}
        const seg = pattern[start..i];
        if (!std.mem.eql(u8, seg, "*")) count += 1;
        if (i < pattern.len) i += 1;
    }
    return count;
}

/// Byte-exact, case-sensitive segment match. `*` matches one non-empty segment.
pub fn globMatches(pattern: []const u8, entity_id: []const u8) bool {
    var pi: usize = 0;
    var ei: usize = 0;
    while (pi < pattern.len or ei < entity_id.len) {
        if (pi >= pattern.len or ei >= entity_id.len) {
            // One side exhausted: only ok if both finished together.
            return pi >= pattern.len and ei >= entity_id.len;
        }
        const p_start = pi;
        while (pi < pattern.len and pattern[pi] != '/') : (pi += 1) {}
        const p_seg = pattern[p_start..pi];

        const e_start = ei;
        while (ei < entity_id.len and entity_id[ei] != '/') : (ei += 1) {}
        const e_seg = entity_id[e_start..ei];
        if (e_seg.len == 0) return false;

        if (std.mem.eql(u8, p_seg, "*")) {
            // Match any non-empty segment.
        } else if (!std.mem.eql(u8, p_seg, e_seg)) {
            return false;
        }

        if (pi < pattern.len) pi += 1;
        if (ei < entity_id.len) ei += 1;
        // Trailing separators already rejected by validation; leftover empty ends fail above.
    }
    return true;
}

/// Reject duplicate selectors within one target (even if layout paths equal).
pub fn rejectDuplicateSelectors(rules: []const LayoutRule) SelectError!void {
    if (rules.len > max_rules_per_target) return error.RuleLimitExceeded;
    for (rules, 0..) |r, i| {
        for (rules[i + 1 ..]) |o| {
            if (r.selectorBytesEqual(o)) return error.DuplicateSelector;
        }
    }
}

/// Sort rules into canonical order: (kind rank, selector value bytes, layout path).
/// Used for digests/diagnostics only — never as match precedence.
pub fn sortRulesCanonical(rules: []LayoutRule) void {
    std.mem.sort(LayoutRule, rules, {}, struct {
        fn less(_: void, a: LayoutRule, b: LayoutRule) bool {
            const ra = a.kind.rank();
            const rb = b.kind.rank();
            if (ra != rb) return ra < rb;
            const vo = std.mem.order(u8, a.value, b.value);
            if (vo != .eq) return vo == .lt;
            return std.mem.order(u8, a.layout_path, b.layout_path) == .lt;
        }
    }.less);
}

pub const Selection = struct {
    layout_path: []const u8,
    /// Winning rule index into the rule table, or null for fallback.
    rule_index: ?usize = null,
    kind: enum { exact, glob, role, fallback } = .fallback,
};

/// Select the effective layout for one (entity_id, role) against a rule table.
///
/// Precedence: exact id > most-specific matching glob > role > fallback.
/// Equal-specificity matching globs → `error.AmbiguousGlob`.
/// Callers must have already rejected duplicate selectors.
pub fn selectLayout(
    entity_id: []const u8,
    role: page_mod.Role,
    rules: []const LayoutRule,
    fallback_layout: []const u8,
) SelectError!Selection {
    // 1. Exact id
    var exact_idx: ?usize = null;
    for (rules, 0..) |r, i| {
        if (r.kind == .id and std.mem.eql(u8, r.value, entity_id)) {
            if (exact_idx != null) return error.DuplicateSelector;
            exact_idx = i;
        }
    }
    if (exact_idx) |i| {
        return .{ .layout_path = rules[i].layout_path, .rule_index = i, .kind = .exact };
    }

    // 2. Globs — uniquely most-specific (greatest literal segment count)
    var best_lit: i32 = -1;
    var best_idx: ?usize = null;
    var tie = false;
    for (rules, 0..) |r, i| {
        if (r.kind != .glob) continue;
        if (!globMatches(r.value, entity_id)) continue;
        const lit: i32 = @intCast(globLiteralCount(r.value));
        if (lit > best_lit) {
            best_lit = lit;
            best_idx = i;
            tie = false;
        } else if (lit == best_lit) {
            tie = true;
        }
    }
    if (tie) return error.AmbiguousGlob;
    if (best_idx) |i| {
        return .{ .layout_path = rules[i].layout_path, .rule_index = i, .kind = .glob };
    }

    // 3. Role
    const role_name = role.name();
    var role_idx: ?usize = null;
    for (rules, 0..) |r, i| {
        if (r.kind == .role and std.mem.eql(u8, r.value, role_name)) {
            if (role_idx != null) return error.DuplicateSelector;
            role_idx = i;
        }
    }
    if (role_idx) |i| {
        return .{ .layout_path = rules[i].layout_path, .rule_index = i, .kind = .role };
    }

    // 4–6. Fallback (target / global / product default resolved by caller)
    return .{ .layout_path = fallback_layout, .rule_index = null, .kind = .fallback };
}

/// Collect unique layout paths (fallback + rules) in stable first-seen order.
/// Caller owns the returned slice of path views (not path bytes).
pub fn collectDeclaredLayouts(
    gpa: std.mem.Allocator,
    fallback: []const u8,
    rules: []const LayoutRule,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    try list.append(gpa, fallback);
    for (rules) |r| {
        var found = false;
        for (list.items) |p| {
            if (std.mem.eql(u8, p, r.layout_path)) {
                found = true;
                break;
            }
        }
        if (!found) try list.append(gpa, r.layout_path);
    }
    return try list.toOwnedSlice(gpa);
}

/// Canonical plan digest material for a target rule table (length-delimited).
/// Paths are used as given (workspace-relative). No absolute paths/timestamps.
pub fn ruleTableDigestMaterial(
    gpa: std.mem.Allocator,
    target_name: []const u8,
    rules: []const LayoutRule,
    fallback_layout: []const u8,
) ![]u8 {
    // Work on a sorted copy so argv order never affects the digest.
    const sorted = try gpa.alloc(LayoutRule, rules.len);
    defer gpa.free(sorted);
    @memcpy(sorted, rules);
    sortRulesCanonical(sorted);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "target:");
    try buf.appendSlice(gpa, target_name);
    try buf.append(gpa, '\n');
    try buf.appendSlice(gpa, "fallback:");
    try buf.appendSlice(gpa, fallback_layout);
    try buf.append(gpa, '\n');
    for (sorted) |r| {
        var sel_buf: [identity.max_entity_id_bytes + 16]u8 = undefined;
        const sel = try r.writeSelector(&sel_buf);
        try buf.appendSlice(gpa, "rule:");
        try buf.appendSlice(gpa, sel);
        try buf.append(gpa, '|');
        try buf.appendSlice(gpa, r.layout_path);
        try buf.append(gpa, '\n');
    }
    return try buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "validateLayoutPath rejects escapes and absolute forms" {
    try validateLayoutPath("layouts/main.html");
    try validateLayoutPath("themes/docs/layouts/home.html");
    try validateLayoutPath("main.html");
    try expectError(error.InvalidLayoutPath, validateLayoutPath(""));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("/abs/main.html"));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("\\abs\\main.html"));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("C:/layouts/main.html"));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("../layouts/main.html"));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("theme/layouts/../layouts/main.html"));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("theme/./layouts/main.html"));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("a//b.html"));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("layouts/main.html/"));
    try expectError(error.InvalidLayoutPath, validateLayoutPath("layouts\\main.html"));
}

test "parseSelector closed grammar" {
    {
        const s = try parseSelector("id:index");
        try expectEqual(SelectorKind.id, s.kind);
        try expectEqualStrings("index", s.value);
    }
    {
        const s = try parseSelector("glob:reference/*");
        try expectEqual(SelectorKind.glob, s.kind);
        try expectEqualStrings("reference/*", s.value);
    }
    {
        const s = try parseSelector("role:trunk");
        try expectEqual(SelectorKind.role, s.kind);
        try expectEqualStrings("trunk", s.value);
    }
    try expectError(error.UnknownSelectorKind, parseSelector("layout:home"));
    try expectError(error.UnknownSelectorKind, parseSelector("index"));
    try expectError(error.InvalidSelector, parseSelector("role:branch"));
    try expectError(error.InvalidSelector, parseSelector("id:"));
    try expectError(error.InvalidSelector, parseSelector("glob:ref*"));
    try expectError(error.InvalidSelector, parseSelector("glob:**"));
    try expectError(error.InvalidSelector, parseSelector("glob:/abs"));
    try expectError(error.InvalidSelector, parseSelector("glob:a//b"));
    try expectError(error.InvalidSelector, parseSelector("id:bad id"));
}

test "globMatches segment rules" {
    try expect(globMatches("reference/*", "reference/configuration"));
    try expect(!globMatches("reference/*", "reference/configuration/extra"));
    try expect(!globMatches("reference/*", "guides/getting-started"));
    try expect(globMatches("*", "index"));
    try expect(!globMatches("*", "a/b"));
    try expect(globMatches("*/configuration", "reference/configuration"));
    try expect(globMatches("a/*/c", "a/b/c"));
    try expect(!globMatches("a/*/c", "a/b/d"));
    // Case-sensitive
    try expect(!globMatches("Reference/*", "reference/configuration"));
}

test "selectLayout precedence exact > glob > role > fallback" {
    const rules = [_]LayoutRule{
        .{ .kind = .role, .value = "satellite", .layout_path = "layouts/role.html" },
        .{ .kind = .glob, .value = "reference/*", .layout_path = "layouts/glob.html" },
        .{ .kind = .id, .value = "reference/configuration", .layout_path = "layouts/exact.html" },
        .{ .kind = .glob, .value = "reference/*/*", .layout_path = "layouts/deeper.html" },
    };
    {
        const s = try selectLayout("reference/configuration", .satellite, &rules, "layouts/main.html");
        try expectEqualStrings("layouts/exact.html", s.layout_path);
        try expectEqual(.exact, s.kind);
    }
    {
        const s = try selectLayout("reference/other", .satellite, &rules, "layouts/main.html");
        try expectEqualStrings("layouts/glob.html", s.layout_path);
        try expectEqual(.glob, s.kind);
    }
    {
        const s = try selectLayout("guides/x", .satellite, &rules, "layouts/main.html");
        try expectEqualStrings("layouts/role.html", s.layout_path);
        try expectEqual(.role, s.kind);
    }
    {
        const s = try selectLayout("index", .trunk, &rules, "layouts/main.html");
        try expectEqualStrings("layouts/main.html", s.layout_path);
        try expectEqual(.fallback, s.kind);
    }
}

test "selectLayout more literal segments wins among globs" {
    const rules = [_]LayoutRule{
        .{ .kind = .glob, .value = "*/*", .layout_path = "layouts/wide.html" },
        .{ .kind = .glob, .value = "reference/*", .layout_path = "layouts/ref.html" },
    };
    const s = try selectLayout("reference/configuration", .satellite, &rules, "layouts/main.html");
    try expectEqualStrings("layouts/ref.html", s.layout_path);
}

test "selectLayout equal-specificity globs are ambiguous" {
    const rules = [_]LayoutRule{
        .{ .kind = .glob, .value = "reference/*", .layout_path = "layouts/a.html" },
        .{ .kind = .glob, .value = "*/configuration", .layout_path = "layouts/b.html" },
    };
    try expectError(error.AmbiguousGlob, selectLayout("reference/configuration", .satellite, &rules, "layouts/main.html"));
    // Same layout path still ambiguous
    const same = [_]LayoutRule{
        .{ .kind = .glob, .value = "reference/*", .layout_path = "layouts/a.html" },
        .{ .kind = .glob, .value = "*/configuration", .layout_path = "layouts/a.html" },
    };
    try expectError(error.AmbiguousGlob, selectLayout("reference/configuration", .satellite, &same, "layouts/main.html"));
}

test "rejectDuplicateSelectors independent of path equality" {
    const dups = [_]LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = "a.html" },
        .{ .kind = .id, .value = "index", .layout_path = "a.html" },
    };
    try expectError(error.DuplicateSelector, rejectDuplicateSelectors(&dups));
    const ok = [_]LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = "a.html" },
        .{ .kind = .role, .value = "trunk", .layout_path = "a.html" },
    };
    try rejectDuplicateSelectors(&ok);
}

test "rule order does not affect selection" {
    const a = [_]LayoutRule{
        .{ .kind = .role, .value = "trunk", .layout_path = "role.html" },
        .{ .kind = .id, .value = "index", .layout_path = "exact.html" },
    };
    const b = [_]LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = "exact.html" },
        .{ .kind = .role, .value = "trunk", .layout_path = "role.html" },
    };
    const sa = try selectLayout("index", .trunk, &a, "main.html");
    const sb = try selectLayout("index", .trunk, &b, "main.html");
    try expectEqualStrings(sa.layout_path, sb.layout_path);
    try expectEqual(sa.kind, sb.kind);
}

test "ruleTableDigestMaterial ignores declaration order" {
    const gpa = std.testing.allocator;
    const a = [_]LayoutRule{
        .{ .kind = .role, .value = "trunk", .layout_path = "role.html" },
        .{ .kind = .id, .value = "index", .layout_path = "exact.html" },
    };
    const b = [_]LayoutRule{
        .{ .kind = .id, .value = "index", .layout_path = "exact.html" },
        .{ .kind = .role, .value = "trunk", .layout_path = "role.html" },
    };
    const da = try ruleTableDigestMaterial(gpa, "default", &a, "main.html");
    defer gpa.free(da);
    const db = try ruleTableDigestMaterial(gpa, "default", &b, "main.html");
    defer gpa.free(db);
    try expectEqualStrings(da, db);
}

test "id override is exact match key not path" {
    // Entity id may differ from source path stem when frontmatter id: is set.
    const rules = [_]LayoutRule{
        .{ .kind = .id, .value = "custom/home", .layout_path = "home.html" },
        .{ .kind = .glob, .value = "index", .layout_path = "idx.html" },
    };
    const s = try selectLayout("custom/home", .trunk, &rules, "main.html");
    try expectEqualStrings("home.html", s.layout_path);
}
