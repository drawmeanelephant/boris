const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// User-configured target specification from the CLI.
pub const TargetSpec = struct {
    name: []const u8,
    output_dir: []const u8,
};

/// Fully resolved and validated execution target plan.
pub const TargetPlan = struct {
    name: []const u8,
    output_dir: []const u8,
    resolved_output_dir: []const u8,
};

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
    /// Global layout file path. Targets must not equal or nest with its parent directory
    /// (when that parent is not the workspace root).
    layout_path: []const u8 = "layouts/main.html",
};

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

        try plans.append(gpa, .{
            .name = target.name,
            .output_dir = target.output_dir,
            .resolved_output_dir = normalized,
        });
    }

    // 3. Protected roots: content tree and layout directory
    const content_abs = try resolveNormalized(gpa, cwd_path, options.content_root);
    defer gpa.free(content_abs);

    var layout_dir_abs: ?[]u8 = null;
    defer if (layout_dir_abs) |p| gpa.free(p);

    if (std.fs.path.dirname(options.layout_path)) |layout_parent| {
        if (layout_parent.len > 0 and !std.mem.eql(u8, layout_parent, ".")) {
            layout_dir_abs = try resolveNormalized(gpa, cwd_path, layout_parent);
        }
    }

    // Also protect the layout file path itself (target must not land on the file path)
    const layout_file_abs = try resolveNormalized(gpa, cwd_path, options.layout_path);
    defer gpa.free(layout_file_abs);

    // 4. Overlap, parent/child nesting, protected roots, symlink detection
    for (plans.items, 0..) |plan, i| {
        const path_a = plan.resolved_output_dir;

        if (pathsNestOrEqual(path_a, content_abs, case_insensitive)) {
            return error.TargetOutputCollision;
        }
        if (layout_dir_abs) |ld| {
            if (pathsNestOrEqual(path_a, ld, case_insensitive)) {
                return error.TargetOutputCollision;
            }
        }
        if (pathsNestOrEqual(path_a, layout_file_abs, case_insensitive)) {
            return error.TargetOutputCollision;
        }

        // Check if output path exists and is a symlink
        if (cwd_dir.statFile(io, plan.output_dir, .{ .follow_symlinks = false })) |st| {
            if (st.kind == .sym_link) {
                return error.TargetOutputSymlink;
            }
        } else |_| {}

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
}
