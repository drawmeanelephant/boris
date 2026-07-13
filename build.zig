const std = @import("std");

/// Boris build graph.
/// Product CLI: typed options + exit codes (m3); pipeline still stubbed.
/// Milestone 4: deterministic scanner + identity.
/// Milestone 5: bounded frontmatter parser + body splitter.
/// Fixture inventory (m2). Separate tool: `boris-source-rag`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Product CLI (milestone 3 typed surface) ---------------------------
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "boris",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Boris");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // --- Fixture inventory tests (milestone 2) -----------------------------
    const fixtures_mod = b.createModule(.{
        .root_source_file = b.path("src/fixtures_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixtures_tests = b.addTest(.{
        .root_module = fixtures_mod,
    });
    const run_fixtures_tests = b.addRunArtifact(fixtures_tests);
    // Resolve fixtures/ relative to the package root, not the zig-cache cwd.
    run_fixtures_tests.setCwd(b.path("."));

    // --- Scanner + identity tests (milestone 4) ----------------------------
    // Root is scanner.zig so its @import("identity.zig") / page.zig pull in
    // the full discovery unit graph (and their embedded tests).
    const scanner_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scanner_tests = b.addTest(.{
        .root_module = scanner_mod,
    });
    const run_scanner_tests = b.addRunArtifact(scanner_tests);
    run_scanner_tests.setCwd(b.path("."));

    // --- Frontmatter parser tests (milestone 5) ----------------------------
    // Root is parser.zig → page.zig + identity.zig. Cwd is package root so
    // fixture-driven tests can open fixtures/content/**.
    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_tests = b.addTest(.{
        .root_module = parser_mod,
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);
    run_parser_tests.setCwd(b.path("."));

    // --- Standalone source RAG tool (not product pipeline) -----------------
    const source_rag_mod = b.createModule(.{
        .root_source_file = b.path("tools/source-rag/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const source_rag_exe = b.addExecutable(.{
        .name = "boris-source-rag",
        .root_module = source_rag_mod,
    });
    b.installArtifact(source_rag_exe);

    const source_rag_run = b.addRunArtifact(source_rag_exe);
    // Run from package root so default paths (src/, docs/, …) resolve.
    source_rag_run.setCwd(b.path("."));
    if (b.args) |args| {
        source_rag_run.addArgs(args);
    }

    const source_rag_step = b.step(
        "source-rag",
        "Generate source-code RAG corpus for LLM upload (boris-source-rag)",
    );
    source_rag_step.dependOn(&source_rag_run.step);

    const source_rag_tests = b.addTest(.{
        .root_module = source_rag_mod,
    });
    const run_source_rag_tests = b.addRunArtifact(source_rag_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_fixtures_tests.step);
    test_step.dependOn(&run_scanner_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_source_rag_tests.step);
}
