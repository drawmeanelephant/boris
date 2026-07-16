const std = @import("std");

/// Standalone Astro / WordPress / Instagram → Boris migration laboratory.
/// Not part of the product compiler or root `zig build test` gate.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "boris-migration-lab",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run boris-migration-lab");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    // Tests open fixtures/ relative to this package directory.
    run_unit_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run migration-lab unit + fixture tests");
    test_step.dependOn(&run_unit_tests.step);
}
