const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const layout_select = @import("layout_select.zig");
const theme_mod = @import("theme.zig");

/// User-configured target specification from the CLI.
pub const TargetSpec = struct {
    name: []const u8,
    output_dir: []const u8,
    /// Optional per-target layout override. When null, use global `--html-layout`.
    layout_path: ?[]const u8 = null,
    /// Canonical `--layout-rule` table for this target (GPA-owned slice of rules;
    /// rule string fields are typically argv views). Empty when no rules.
    layout_rules: []const layout_select.LayoutRule = &.{},
};

/// Fully resolved and validated execution target plan.
pub const TargetPlan = struct {
    name: []const u8,
    output_dir: []const u8,
    resolved_output_dir: []const u8,
    /// Fallback layout path (global default or per-target override). Not owned.
    layout_path: []const u8,
    /// Rule table view (not owned; points into TargetSpec).
    layout_rules: []const layout_select.LayoutRule = &.{},
};

/// Effective layout for a target given the global default.
pub fn effectiveLayout(target: TargetSpec, default_layout: []const u8) []const u8 {
    return target.layout_path orelse default_layout;
}

/// Lexicographic order on target names (byte order). Used for canonical CLI
/// configuration and execution order.
pub fn targetNameLess(_: void, a: TargetSpec, b: TargetSpec) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Sort target specs in place by canonical target name (ascending).
/// Equivalent argv permutations must produce the same ordered slice after parse.
pub fn sortTargetSpecsByName(specs: []TargetSpec) void {
    std.mem.sort(TargetSpec, specs, {}, targetNameLess);
}

/// Print one line per target in slice order (caller supplies canonical order).
/// Format: `  target <name>: out=<output_dir> layout=<effective_layout> rules=N`
/// Uses `std.debug.print` (same channel as other CLI diagnostics).
pub fn printTargetConfigLines(specs: []const TargetSpec, default_layout: []const u8) void {
    for (specs) |spec| {
        const layout = effectiveLayout(spec, default_layout);
        std.debug.print("  target {s}: out={s} layout={s} rules={d}\n", .{
            spec.name,
            spec.output_dir,
            layout,
            spec.layout_rules.len,
        });
    }
}

/// All layout paths a target may load (fallback + rule paths), unique, first-seen order.
/// Caller frees the slice (path strings are views).
pub fn declaredLayoutPaths(
    gpa: Allocator,
    spec: TargetSpec,
    default_layout: []const u8,
) ![]const []const u8 {
    return layout_select.collectDeclaredLayouts(gpa, effectiveLayout(spec, default_layout), spec.layout_rules);
}

/// True when `path` equals `prefix` or is `prefix/` + more.
/// Both paths must already use `/` separators and must not end with `/`
/// (except a bare root, which we do not produce here).
pub fn hasAbsPathPrefix(path: []const u8, prefix: []const u8, case_insensitive: bool) bool {
    if (prefix.len == 0) return false;
    if (path.len < prefix.len) return false;
    const head = path[0..prefix.len];
    const eq = if (case_insensitive)
        std.ascii.eqlIgnoreCase(head, prefix)
    else
        std.mem.eql(u8, head, prefix);
    if (!eq) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// True when either path equals the other or one is a proper nested child of the other.
pub fn pathsNestOrEqual(a: []const u8, b: []const u8, case_insensitive: bool) bool {
    return hasAbsPathPrefix(a, b, case_insensitive) or hasAbsPathPrefix(b, a, case_insensitive);
}

fn caseInsensitiveFs() bool {
    return builtin.os.tag == .windows or builtin.os.tag == .macos;
}

fn normalizeSlashesInPlace(path: []u8) void {
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
}

/// Strip a single trailing `/` when the path is longer than 1 (keep POSIX root `/`).
fn stripTrailingSlash(path: []u8) []u8 {
    if (path.len > 1 and path[path.len - 1] == '/') {
        return path[0 .. path.len - 1];
    }
    return path;
}

/// Resolve `rel` against `cwd_path`, normalize to `/` separators, strip trailing slash.
/// Caller owns the returned buffer.
fn resolveNormalized(gpa: Allocator, cwd_path: []const u8, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.resolve(gpa, &.{ cwd_path, rel });
    normalizeSlashesInPlace(abs);
    const trimmed = stripTrailingSlash(abs);
    if (trimmed.len != abs.len) {
        const owned = try gpa.dupe(u8, trimmed);
        gpa.free(abs);
        return owned;
    }
    return abs;
}

/// Walk progressive components of a relative path and reject any existing symlink.
/// Best-effort: missing path components are ignored; absolute-path edge cases on
/// Windows that cannot be stated relative to cwd are skipped (workspace resolve
/// still applies).
/// Reject any existing symlink component on a relative output/layout path.
/// Call at validate time and again immediately before opening output dirs
/// to shrink the TOCTOU window after validateTargets.
pub fn rejectSymlinkAlongPath(io: Io, cwd: Io.Dir, gpa: Allocator, rel_path: []const u8) !void {
    if (rel_path.len == 0) return;

    var norm = try gpa.dupe(u8, rel_path);
    defer gpa.free(norm);
    normalizeSlashesInPlace(norm);
    norm = stripTrailingSlash(norm);

    // Skip drive-absolute prefixes like `C:/...` — only walk relative trees.
    if (norm.len >= 2 and norm[1] == ':') return;
    if (norm.len > 0 and norm[0] == '/') return;

    var start: usize = 0;
    while (start < norm.len) {
        // Skip empty segments from double slashes
        if (norm[start] == '/') {
            start += 1;
            continue;
        }
        const slash = std.mem.indexOfScalarPos(u8, norm, start, '/') orelse norm.len;
        const progressive = norm[0..slash];
        if (progressive.len > 0 and !std.mem.eql(u8, progressive, ".") and !std.mem.eql(u8, progressive, "..")) {
            if (cwd.statFile(io, progressive, .{ .follow_symlinks = false })) |st| {
                if (st.kind == .sym_link) {
                    return error.TargetOutputSymlink;
                }
            } else |_| {}
        }
        if (slash >= norm.len) break;
        start = slash + 1;
    }
}

/// Validate target name grammar. Must be non-empty alphanumeric plus '-', '_', '.'.
/// Must not be "." or "..".
pub fn isValidTargetName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return false,
        }
    }
    return true;
}

/// Options for protected path checks during target validation.
pub const ValidateTargetsOptions = struct {
    /// Content root (e.g. `--input`). Targets must not equal or nest with this directory.
    content_root: []const u8 = "content",
    /// Global default layout path (`--html-layout`). Used when a target has no override.
    layout_path: []const u8 = "layouts/main.html",
};

/// Reject mixing managed theme roots or managed+legacy layouts within one target.
pub fn rejectMixedThemeRoots(fallback: []const u8, rules: []const layout_select.LayoutRule) !void {
    const fallback_root = theme_mod.themeRootFromLayoutPath(fallback);
    for (rules) |r| {
        const root = theme_mod.themeRootFromLayoutPath(r.layout_path);
        const same = switch (fallback_root == null) {
            true => root == null,
            false => root != null and std.mem.eql(u8, fallback_root.?, root.?),
        };
        if (!same) return error.MixedThemeRoots;
    }
    if (rules.len > 1) {
        const first = theme_mod.themeRootFromLayoutPath(rules[0].layout_path);
        for (rules[1..]) |r| {
            const root = theme_mod.themeRootFromLayoutPath(r.layout_path);
            const same = switch (first == null) {
                true => root == null,
                false => root != null and std.mem.eql(u8, first.?, root.?),
            };
            if (!same) return error.MixedThemeRoots;
        }
    }
}

/// Validate all target specifications, canonicalize paths, perform safety and overlap checks,
/// and return a sorted array of TargetPlans.
///
/// Pre-conditions:
/// - CLI-only grammatical parsing is complete.
/// - Does not write or mutate any directories (validate-only).
pub fn validateTargets(
    io: Io,
    gpa: Allocator,
    targets: []const TargetSpec,
    options: ValidateTargetsOptions,
) ![]const TargetPlan {
    if (targets.len == 0) {
        return error.NoTargetsSpecified;
    }

    // 1. Validate target name grammar and duplicate names
    for (targets, 0..) |target, i| {
        if (!isValidTargetName(target.name)) {
            return error.InvalidTargetName;
        }
        for (targets[i + 1 ..]) |other| {
            if (std.mem.eql(u8, target.name, other.name)) {
                return error.DuplicateTargetName;
            }
        }
    }

    const cwd_owned = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_owned);
    normalizeSlashesInPlace(cwd_owned);
    const cwd_path = stripTrailingSlash(cwd_owned);

    const case_insensitive = caseInsensitiveFs();
    const cwd_dir = Io.Dir.cwd();

    var plans = try std.ArrayList(TargetPlan).initCapacity(gpa, targets.len);
    errdefer {
        for (plans.items) |plan| {
            gpa.free(plan.resolved_output_dir);
        }
        plans.deinit(gpa);
    }

    // 2. Resolve absolute paths, normalize separators, check workspace membership
    for (targets) |target| {
        if (target.output_dir.len == 0) {
            return error.EmptyTargetDirectory;
        }

        const normalized = try resolveNormalized(gpa, cwd_path, target.output_dir);
        errdefer gpa.free(normalized);

        // Path-boundary workspace membership (rejects sibling prefixes like /ws vs /ws-evil)
        if (!hasAbsPathPrefix(normalized, cwd_path, case_insensitive)) {
            return error.WorkspaceEscape;
        }

        // Prevent targeting the workspace root itself
        if (normalized.len == cwd_path.len) {
            return error.TargetOutputCollision;
        }

        const layout = effectiveLayout(target, options.layout_path);
        if (layout.len == 0) return error.EmptyTargetDirectory;

        // One managed theme root (or all-legacy) for fallback + every rule layout.
        try rejectMixedThemeRoots(layout, target.layout_rules);

        try plans.append(gpa, .{
            .name = target.name,
            .output_dir = target.output_dir,
            .resolved_output_dir = normalized,
            .layout_path = layout,
            .layout_rules = target.layout_rules,
        });
    }

    // 3. Protected roots: content tree and every declared layout path/dir
    const content_abs = try resolveNormalized(gpa, cwd_path, options.content_root);
    defer gpa.free(content_abs);

    var protected_layouts: std.ArrayList([]u8) = .empty;
    defer {
        for (protected_layouts.items) |p| gpa.free(p);
        protected_layouts.deinit(gpa);
    }

    for (plans.items) |plan| {
        const declared = try layout_select.collectDeclaredLayouts(gpa, plan.layout_path, plan.layout_rules);
        defer gpa.free(declared);
        for (declared) |lp| {
            const layout_file_abs = try resolveNormalized(gpa, cwd_path, lp);
            try protected_layouts.append(gpa, layout_file_abs);

            if (std.fs.path.dirname(lp)) |layout_parent| {
                if (layout_parent.len > 0 and !std.mem.eql(u8, layout_parent, ".")) {
                    const ld = try resolveNormalized(gpa, cwd_path, layout_parent);
                    try protected_layouts.append(gpa, ld);
                }
            }
            try rejectSymlinkAlongPath(io, cwd_dir, gpa, lp);
        }
    }

    // 4. Overlap, parent/child nesting, protected roots, symlink detection
    for (plans.items, 0..) |plan, i| {
        const path_a = plan.resolved_output_dir;

        if (pathsNestOrEqual(path_a, content_abs, case_insensitive)) {
            return error.TargetOutputCollision;
        }
        for (protected_layouts.items) |prot| {
            if (pathsNestOrEqual(path_a, prot, case_insensitive)) {
                return error.TargetOutputCollision;
            }
        }

        // Reject symlink at the target root or any intermediate component.
        try rejectSymlinkAlongPath(io, cwd_dir, gpa, plan.output_dir);

        for (plans.items, 0..) |other, j| {
            if (i == j) continue;
            const path_b = other.resolved_output_dir;

            if (pathsNestOrEqual(path_a, path_b, case_insensitive)) {
                return error.TargetOutputCollision;
            }
        }
    }

    // 5. Stable sort by target name
    std.mem.sort(TargetPlan, plans.items, {}, struct {
        fn less(_: void, a: TargetPlan, b: TargetPlan) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    return try plans.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isValidTargetName validation rules" {
    try std.testing.expect(isValidTargetName("prod"));
    try std.testing.expect(isValidTargetName("staging-2"));
    try std.testing.expect(isValidTargetName("dev_test.site"));
    try std.testing.expect(!isValidTargetName(""));
    try std.testing.expect(!isValidTargetName("."));
    try std.testing.expect(!isValidTargetName(".."));
    try std.testing.expect(!isValidTargetName("prod/staging"));
    try std.testing.expect(!isValidTargetName("prod\\staging"));
    try std.testing.expect(!isValidTargetName("prod?"));
}

test "sortTargetSpecsByName is deterministic" {
    var specs = [_]TargetSpec{
        .{ .name = "staging", .output_dir = "dist/stage", .layout_path = "layouts/stage.html" },
        .{ .name = "prod", .output_dir = "dist/prod", .layout_path = null },
        .{ .name = "alpha", .output_dir = "dist/alpha", .layout_path = "layouts/a.html" },
    };
    sortTargetSpecsByName(&specs);
    try std.testing.expectEqualSlices(u8, "alpha", specs[0].name);
    try std.testing.expectEqualSlices(u8, "prod", specs[1].name);
    try std.testing.expectEqualSlices(u8, "staging", specs[2].name);
    try std.testing.expectEqualSlices(u8, "layouts/a.html", specs[0].layout_path.?);
    try std.testing.expect(specs[1].layout_path == null);
}

test "hasAbsPathPrefix boundary" {
    try std.testing.expect(hasAbsPathPrefix("/tmp/ws/dist", "/tmp/ws", false));
    try std.testing.expect(hasAbsPathPrefix("/tmp/ws", "/tmp/ws", false));
    try std.testing.expect(!hasAbsPathPrefix("/tmp/ws-evil/dist", "/tmp/ws", false));
    try std.testing.expect(!hasAbsPathPrefix("/tmp/ws2/out", "/tmp/ws", false));
    try std.testing.expect(hasAbsPathPrefix("/tmp/ws/dist/prod", "/tmp/ws/dist", false));
    try std.testing.expect(!hasAbsPathPrefix("/tmp/ws/dist-prod", "/tmp/ws/dist", false));
}

test "validateTargets overlap, nesting, sort, and escape checks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const opts = ValidateTargetsOptions{};

    // Normal successful case with sorting
    {
        const specs = [_]TargetSpec{
            .{ .name = "staging", .output_dir = "dist/stage" },
            .{ .name = "prod", .output_dir = "dist/prod" },
        };
        const plans = try validateTargets(io, gpa, &specs, opts);
        defer {
            for (plans) |plan| gpa.free(plan.resolved_output_dir);
            gpa.free(plans);
        }

        try std.testing.expectEqual(@as(usize, 2), plans.len);
        // "prod" sorted before "staging" alphabetically
        try std.testing.expectEqualSlices(u8, "prod", plans[0].name);
        try std.testing.expectEqualSlices(u8, "staging", plans[1].name);
    }

    // Sibling output dirs must not collide (dist vs dist-prod style)
    {
        const specs = [_]TargetSpec{
            .{ .name = "a", .output_dir = "dist" },
            .{ .name = "b", .output_dir = "dist-prod" },
        };
        const plans = try validateTargets(io, gpa, &specs, opts);
        defer {
            for (plans) |plan| gpa.free(plan.resolved_output_dir);
            gpa.free(plans);
        }
        try std.testing.expectEqual(@as(usize, 2), plans.len);
    }

    // Duplicate target name error
    {
        const specs = [_]TargetSpec{
            .{ .name = "prod", .output_dir = "dist/prod1" },
            .{ .name = "prod", .output_dir = "dist/prod2" },
        };
        try std.testing.expectError(error.DuplicateTargetName, validateTargets(io, gpa, &specs, opts));
    }

    // Invalid target name
    {
        const specs = [_]TargetSpec{
            .{ .name = "prod/site", .output_dir = "dist/prod" },
        };
        try std.testing.expectError(error.InvalidTargetName, validateTargets(io, gpa, &specs, opts));
    }

    // Overlapping directory (equality)
    {
        const specs = [_]TargetSpec{
            .{ .name = "prod", .output_dir = "dist/prod" },
            .{ .name = "staging", .output_dir = "dist/prod" },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs, opts));
    }

    // Parent/child nesting collision
    {
        const specs = [_]TargetSpec{
            .{ .name = "prod", .output_dir = "dist/prod" },
            .{ .name = "staging", .output_dir = "dist/prod/stage" },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs, opts));
    }

    // Workspace escape
    {
        const specs = [_]TargetSpec{
            .{ .name = "escaped", .output_dir = "../outside" },
        };
        try std.testing.expectError(error.WorkspaceEscape, validateTargets(io, gpa, &specs, opts));
    }

    // Workspace root collision
    {
        const specs = [_]TargetSpec{
            .{ .name = "workspace", .output_dir = "." },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs, opts));
    }

    // Target output must not overlap content root
    {
        const specs = [_]TargetSpec{
            .{ .name = "bad", .output_dir = "content" },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs, opts));
    }

    // Target nested under content root
    {
        const specs = [_]TargetSpec{
            .{ .name = "bad", .output_dir = "content/out" },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs, opts));
    }

    // Target must not land on layout directory
    {
        const specs = [_]TargetSpec{
            .{ .name = "bad", .output_dir = "layouts" },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs, opts));
    }

    // Custom content_root in options
    {
        const specs = [_]TargetSpec{
            .{ .name = "ok", .output_dir = "content" }, // default content name is fine when input is elsewhere
        };
        const custom = ValidateTargetsOptions{ .content_root = "docs/src", .layout_path = "tmpl/main.html" };
        const plans = try validateTargets(io, gpa, &specs, custom);
        defer {
            for (plans) |plan| gpa.free(plan.resolved_output_dir);
            gpa.free(plans);
        }
        try std.testing.expectEqual(@as(usize, 1), plans.len);
    }

    // Input order of specs must not change canonical plan order or effective layouts
    {
        const a = [_]TargetSpec{
            .{ .name = "z", .output_dir = "dist/z", .layout_path = "layouts/z.html" },
            .{ .name = "a", .output_dir = "dist/a", .layout_path = null },
        };
        const b = [_]TargetSpec{
            .{ .name = "a", .output_dir = "dist/a", .layout_path = null },
            .{ .name = "z", .output_dir = "dist/z", .layout_path = "layouts/z.html" },
        };
        const plans_a = try validateTargets(io, gpa, &a, opts);
        defer {
            for (plans_a) |plan| gpa.free(plan.resolved_output_dir);
            gpa.free(plans_a);
        }
        const plans_b = try validateTargets(io, gpa, &b, opts);
        defer {
            for (plans_b) |plan| gpa.free(plan.resolved_output_dir);
            gpa.free(plans_b);
        }
        try std.testing.expectEqual(@as(usize, 2), plans_a.len);
        try std.testing.expectEqualSlices(u8, plans_a[0].name, plans_b[0].name);
        try std.testing.expectEqualSlices(u8, plans_a[1].name, plans_b[1].name);
        try std.testing.expectEqualSlices(u8, plans_a[0].layout_path, plans_b[0].layout_path);
        try std.testing.expectEqualSlices(u8, plans_a[1].layout_path, plans_b[1].layout_path);
        try std.testing.expectEqualSlices(u8, "a", plans_a[0].name);
        try std.testing.expectEqualSlices(u8, "layouts/main.html", plans_a[0].layout_path);
        try std.testing.expectEqualSlices(u8, "layouts/z.html", plans_a[1].layout_path);
    }
}
