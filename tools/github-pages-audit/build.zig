const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const github_pages = b.createModule(.{
        .root_source_file = b.path("../../src/github_pages.zig"),
        .target = target,
        .optimize = optimize,
    });
    const artifact_inventory = b.createModule(.{
        .root_source_file = b.path("../../src/artifact_inventory.zig"),
        .target = target,
        .optimize = optimize,
    });
    const location_policy = b.createModule(.{
        .root_source_file = b.path("src/location_policy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "github_pages", .module = github_pages }},
    });

    const audit = b.createModule(.{
        .root_source_file = b.path("src/audit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "artifact_inventory", .module = artifact_inventory },
            .{ .name = "github_pages", .module = github_pages },
            .{ .name = "location_policy", .module = location_policy },
        },
    });
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "audit", .module = audit }},
    });

    const exe = b.addExecutable(.{
        .name = "boris-github-pages-audit",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Audit one deployed Boris GitHub Pages publication");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = audit });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run deterministic GitHub Pages audit fixture tests");
    test_step.dependOn(&run_tests.step);
}
