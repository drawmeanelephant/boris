const std = @import("std");
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

/// Validate all target specifications, canonicalize paths, perform safety and overlap checks,
/// and return a sorted array of TargetPlans.
///
/// Pre-conditions:
/// - CLI-only grammatical parsing is complete.
/// - Does not write or mutate any directories (validate-only).
pub fn validateTargets(io: Io, gpa: Allocator, targets: []const TargetSpec) ![]const TargetPlan {
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

    const cwd_path = try std.process.getCwdAlloc(gpa);
    defer gpa.free(cwd_path);

    var plans = try std.ArrayList(TargetPlan).initCapacity(gpa, targets.len);
    errdefer {
        for (plans.items) |plan| {
            gpa.free(plan.resolved_output_dir);
        }
        plans.deinit();
    }

    // Normalize CWD path separators to forward slashes
    const normalized_workspace = try gpa.dupe(u8, cwd_path);
    defer gpa.free(normalized_workspace);
    for (normalized_workspace) |*c| {
        if (c.* == '\\') {
            c.* = '/';
        }
    }

    const cwd_dir = Io.Dir.cwd();

    // 2. Resolve absolute paths, normalize separators, check escaping
    for (targets) |target| {
        if (target.output_dir.len == 0) {
            return error.EmptyTargetDirectory;
        }

        const abs_path = try std.fs.path.resolve(gpa, &[_][]const u8{ cwd_path, target.output_dir });
        errdefer gpa.free(abs_path);

        // Normalize separators to forward slashes for cross-platform equivalence
        const normalized = try gpa.dupe(u8, abs_path);
        gpa.free(abs_path);
        errdefer gpa.free(normalized);

        for (normalized) |*c| {
            if (c.* == '\\') {
                c.* = '/';
            }
        }

        // Check workspace escape
        const is_windows = @import("builtin").os.tag == .windows;
        const is_macos = @import("builtin").os.tag == .macos;
        const case_insensitive = is_windows or is_macos;

        const is_inside_workspace = if (case_insensitive)
            std.ascii.startsWithIgnoreCase(normalized, normalized_workspace)
        else
            std.mem.startsWith(u8, normalized, normalized_workspace);

        if (!is_inside_workspace) {
            return error.WorkspaceEscape;
        }

        // Prevent targeting the workspace root itself to protect project files
        const match_root = if (case_insensitive)
            std.ascii.eqlIgnoreCase(normalized, normalized_workspace)
        else
            std.mem.eql(u8, normalized, normalized_workspace);

        if (match_root) {
            return error.TargetOutputCollision;
        }

        try plans.append(.{
            .name = target.name,
            .output_dir = target.output_dir,
            .resolved_output_dir = normalized,
        });
    }

    // 3. Overlap, parent/child nesting, and symlink detection
    for (plans.items, 0..) |plan, i| {
        const path_a = plan.resolved_output_dir;

        // Check if output path exists and is a symlink
        if (cwd_dir.statFile(io, plan.output_dir, .{ .follow_symlinks = false })) |st| {
            if (st.kind == .sym_link) {
                return error.TargetOutputSymlink;
            }
        } else |_| {}

        for (plans.items, 0..) |other, j| {
            if (i == j) continue;
            const path_b = other.resolved_output_dir;

            const is_windows = @import("builtin").os.tag == .windows;
            const is_macos = @import("builtin").os.tag == .macos;
            const case_insensitive = is_windows or is_macos;

            // Absolute path equality
            const match = if (case_insensitive)
                std.ascii.eqlIgnoreCase(path_a, path_b)
            else
                std.mem.eql(u8, path_a, path_b);

            if (match) {
                return error.TargetOutputCollision;
            }

            // Parent/child nesting (path_b resides inside path_a)
            const is_parent = if (case_insensitive)
                std.ascii.startsWithIgnoreCase(path_b, path_a)
            else
                std.mem.startsWith(u8, path_b, path_a);

            if (is_parent) {
                if (path_b.len > path_a.len and path_b[path_a.len] == '/') {
                    return error.TargetOutputCollision;
                }
            }
        }
    }

    // 4. Stable sort by target name
    std.mem.sort(TargetPlan, plans.items, {}, struct {
        fn less(_: void, a: TargetPlan, b: TargetPlan) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    return try plans.toOwnedSlice();
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

test "validateTargets overlap, nesting, sort, and escape checks" {
    const io = Io.init();
    const gpa = std.testing.allocator;

    // Normal successful case with sorting
    {
        const specs = [_]TargetSpec{
            .{ .name = "staging", .output_dir = "dist/stage" },
            .{ .name = "prod", .output_dir = "dist/prod" },
        };
        const plans = try validateTargets(io, gpa, &specs);
        defer {
            for (plans) |plan| gpa.free(plan.resolved_output_dir);
            gpa.free(plans);
        }

        try std.testing.expectEqual(@as(usize, 2), plans.len);
        // "prod" sorted before "staging" alphabetically
        try std.testing.expectEqualSlices(u8, "prod", plans[0].name);
        try std.testing.expectEqualSlices(u8, "staging", plans[1].name);
    }

    // Duplicate target name error
    {
        const specs = [_]TargetSpec{
            .{ .name = "prod", .output_dir = "dist/prod1" },
            .{ .name = "prod", .output_dir = "dist/prod2" },
        };
        try std.testing.expectError(error.DuplicateTargetName, validateTargets(io, gpa, &specs));
    }

    // Invalid target name
    {
        const specs = [_]TargetSpec{
            .{ .name = "prod/site", .output_dir = "dist/prod" },
        };
        try std.testing.expectError(error.InvalidTargetName, validateTargets(io, gpa, &specs));
    }

    // Overlapping directory (equality)
    {
        const specs = [_]TargetSpec{
            .{ .name = "prod", .output_dir = "dist/prod" },
            .{ .name = "staging", .output_dir = "dist/prod" },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs));
    }

    // Parent/child nesting collision
    {
        const specs = [_]TargetSpec{
            .{ .name = "prod", .output_dir = "dist/prod" },
            .{ .name = "staging", .output_dir = "dist/prod/stage" },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs));
    }

    // Workspace escape
    {
        const specs = [_]TargetSpec{
            .{ .name = "escaped", .output_dir = "../outside" },
        };
        try std.testing.expectError(error.WorkspaceEscape, validateTargets(io, gpa, &specs));
    }

    // Workspace root collision
    {
        const specs = [_]TargetSpec{
            .{ .name = "workspace", .output_dir = "." },
        };
        try std.testing.expectError(error.TargetOutputCollision, validateTargets(io, gpa, &specs));
    }
}
