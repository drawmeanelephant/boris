const std = @import("std");

/// Standalone build for the boris#420 repro. The executable's root module is
/// boris's own `src/publication_touches.zig` (same wiring the root build.zig
/// uses: module root + "oliver_cooklang" import), so the harness drives the
/// real `parseChecksStream` — not a copy.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const oliver_cooklang_dep = b.dependency("oliver_cooklang", .{
        .target = target,
        .optimize = optimize,
    });
    const oliver_cooklang_mod = b.createModule(.{
        .root_source_file = oliver_cooklang_dep.path("src/oliver.zig"),
        .target = target,
        .optimize = optimize,
    });

    const touches_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_touches.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "oliver_cooklang", .module = oliver_cooklang_mod }},
    });

    const main_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("publication_touches", touches_mod);

    const exe = b.addExecutable(.{
        .name = "repro-420",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the boris#420 streaming-checks-parse repro");
    run_step.dependOn(&run_cmd.step);
}
