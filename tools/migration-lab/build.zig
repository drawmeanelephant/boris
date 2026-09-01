const std = @import("std");

/// Standalone Astro / WordPress / Instagram / Obsidian → Boris migration laboratory.
/// Not part of the product compiler or root `zig build test` gate.
///
/// Boundary: the laboratory consumes the Boris parser through the pinned
/// `boris` package dependency declared in build.zig.zon (the astro-import-apply
/// final gate), never by a relative `../../src` path, so this tree stays
/// forkable (docs/plans/migration-lab-standalone-repo.md, 3.1a). The product
/// `boris` binary is an explicit pinned prerequisite for black-box compile
/// tests, resolved from `BORIS_BIN` / PATH, not a build step here.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Zig 0.16 exposes the process environment only through `main`'s `Init`,
    // not to library code at runtime, so the black-box binary resolver reads
    // `BORIS_BIN` / `PATH` as configure-time snapshots from the build graph.
    const options = b.addOptions();
    options.addOption([]const u8, "boris_bin", b.graph.environ_map.get("BORIS_BIN") orelse "");
    options.addOption([]const u8, "path", b.graph.environ_map.get("PATH") orelse "");
    root_mod.addOptions("options", options);
    // Initial-create apply validates every generated file through Boris's
    // native parser before it can be published. Keeping this as a package
    // dependency (not a subprocess) preserves the migration lab's
    // no-runtime-dependency boundary.
    const boris_dep = b.dependency("boris", .{
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("boris_parser", boris_dep.module("parser"));

    const exe = b.addExecutable(.{
        .name = "boris-migration-lab",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    // The black-box apply test runs the installed `zig-out/bin` artifact. Its
    // explicit install dependency below means a missing executable is a build
    // failure, never a skip.

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
    run_unit_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run migration-lab unit + fixture tests");
    test_step.dependOn(&run_unit_tests.step);

    const schema_test_cmd = b.addSystemCommand(&.{
        "npm",
        "--prefix",
        "schema-validation",
        "test",
    });
    schema_test_cmd.setCwd(b.path("."));
    const schema_test_step = b.step("schema-test", "Run the real Draft 2020-12 Astro import schema matrix (requires npm ci in schema-validation)");
    schema_test_step.dependOn(&schema_test_cmd.step);
}
