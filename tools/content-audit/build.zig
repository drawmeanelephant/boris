const std = @import("std");

/// Standalone deterministic source-content audit tool (`boris-content-audit`).
///
/// Not part of the Boris product compiler, not wired into the root
/// `zig build test` gate, and never imports product `src/` modules.
/// The tool parses a small bounded frontmatter grammar of its own
/// (documented in `docs/poetry-shapes.md` and the tool README).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "boris-content-audit",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run boris-content-audit");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    // Tests open fixtures/ relative to this package directory.
    run_unit_tests.setCwd(b.path("."));
    run_unit_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run boris-content-audit unit + fixture tests");
    test_step.dependOn(&run_unit_tests.step);
}
