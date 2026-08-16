const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const editor_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_mod.addAnonymousImport("frontmatter_schema", .{
        .root_source_file = b.path("../docs/contracts/schemas/boris-frontmatter-1.schema.json"),
    });
    editor_mod.addAnonymousImport("completion_fixture", .{
        .root_source_file = b.path("../docs/contracts/fixtures/valid/expected/completion.json"),
    });
    editor_mod.addAnonymousImport("graph_fixture", .{
        .root_source_file = b.path("../docs/contracts/fixtures/valid/expected/graph.json"),
    });
    const editor = b.addExecutable(.{
        .name = "boris-editor",
        .root_module = editor_mod,
    });
    b.installArtifact(editor);

    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/contract_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    const probe = b.addExecutable(.{
        .name = "boris-editor-contract-probe",
        .root_module = probe_mod,
    });
    b.installArtifact(probe);

    const run_editor = b.addRunArtifact(editor);
    run_editor.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_editor.addArgs(args);
    const run_step = b.step("run", "Run the Boris Editor loopback host");
    run_step.dependOn(&run_editor.step);

    const tests = b.addTest(.{ .root_module = editor_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path(".."));
    const test_step = b.step("test", "Run Boris Editor host unit tests");
    test_step.dependOn(&run_tests.step);
}
