const std = @import("std");

/// Boris build graph.
/// Product CLI: typed options + IR pipeline (m6) + RAG export (m7) +
/// scanner/parser (m4–m5). Milestone 8: in-process Apex C ABI (linked; not
/// default IR/RAG path). Milestone 9: experimental HTML assemble/compile tests
/// (not default CLI). Milestone 10: Aside tokenizer + hardening. Fixture
/// inventory (m2). Separate tools: `boris-source-rag`, `boris-package`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // build_options: hostile_apex swaps the C engine for ABI hostility tests.
    const apex_opts = b.addOptions();
    apex_opts.addOption(bool, "hostile_apex", false);

    const hostile_opts = b.addOptions();
    hostile_opts.addOption(bool, "hostile_apex", true);

    // --- Product CLI (milestone 6 IR surface + m8 Apex link) --------------
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Linked into the process for the C ABI surface; default CLI does not call Apex.
    linkApex(root_mod, b, false);
    root_mod.addOptions("build_options", apex_opts);

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

    // Main + CLI + pipeline unit tests (cwd = package root for fixtures).
    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setCwd(b.path("."));

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
    run_fixtures_tests.setCwd(b.path("."));

    // --- Scanner + identity tests (milestone 4) ----------------------------
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

    // --- Pipeline + graph tests (milestone 6) ------------------------------
    // Pipeline imports aside (component validation) → needs Apex link.
    const pipeline_mod = b.createModule(.{
        .root_source_file = b.path("src/pipeline.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(pipeline_mod, b, false);
    pipeline_mod.addOptions("build_options", apex_opts);
    const pipeline_tests = b.addTest(.{
        .root_module = pipeline_mod,
    });
    const run_pipeline_tests = b.addRunArtifact(pipeline_tests);
    run_pipeline_tests.setCwd(b.path("."));

    const graph_mod = b.createModule(.{
        .root_source_file = b.path("src/graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    const graph_tests = b.addTest(.{
        .root_module = graph_mod,
    });
    const run_graph_tests = b.addRunArtifact(graph_tests);
    run_graph_tests.setCwd(b.path("."));

    // --- Aside component tokenizer + HTML render (milestone 10) ------------
    const aside_mod = b.createModule(.{
        .root_source_file = b.path("src/aside.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(aside_mod, b, false);
    aside_mod.addOptions("build_options", apex_opts);
    const aside_tests = b.addTest(.{
        .root_module = aside_mod,
    });
    const run_aside_tests = b.addRunArtifact(aside_tests);
    run_aside_tests.setCwd(b.path("."));

    // --- RAG export tests (milestone 7 + m10 :::kind) ----------------------
    const rag_mod = b.createModule(.{
        .root_source_file = b.path("src/rag.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(rag_mod, b, false);
    rag_mod.addOptions("build_options", apex_opts);
    const rag_tests = b.addTest(.{
        .root_module = rag_mod,
    });
    const run_rag_tests = b.addRunArtifact(rag_tests);
    run_rag_tests.setCwd(b.path("."));

    // --- Apex C ABI tests (milestone 8) ------------------------------------
    // Direct @cImport binding tests against the real vendor engine.
    const apex_mod = b.createModule(.{
        .root_source_file = b.path("src/apex.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(apex_mod, b, false);
    apex_mod.addOptions("build_options", apex_opts);

    const apex_tests = b.addTest(.{
        .root_module = apex_mod,
    });
    const run_apex_tests = b.addRunArtifact(apex_tests);
    run_apex_tests.setCwd(b.path("."));

    // --- Experimental HTML assemble + whiteboard compile (milestone 9) -----
    // Not on the default IR/RAG CLI path; tests only.
    const assemble_mod = b.createModule(.{
        .root_source_file = b.path("src/assemble.zig"),
        .target = target,
        .optimize = optimize,
    });
    const assemble_tests = b.addTest(.{
        .root_module = assemble_mod,
    });
    const run_assemble_tests = b.addRunArtifact(assemble_tests);
    run_assemble_tests.setCwd(b.path("."));

    const compile_mod = b.createModule(.{
        .root_source_file = b.path("src/compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(compile_mod, b, false);
    compile_mod.addOptions("build_options", apex_opts);
    const compile_tests = b.addTest(.{
        .root_module = compile_mod,
    });
    const run_compile_tests = b.addRunArtifact(compile_tests);
    run_compile_tests.setCwd(b.path("."));

    // Hostile Apex double: Zig wrapper imports a named "apex" module that
    // links apex_hostile.c (never the product binary).
    const apex_hostile_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/apex.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(apex_hostile_lib_mod, b, true);
    apex_hostile_lib_mod.addOptions("build_options", hostile_opts);

    const apex_hostile_root = b.createModule(.{
        .root_source_file = b.path("src/apex_hostile_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "apex", .module = apex_hostile_lib_mod },
        },
    });

    const apex_hostile_tests = b.addTest(.{
        .root_module = apex_hostile_root,
    });
    const run_apex_hostile_tests = b.addRunArtifact(apex_hostile_tests);
    run_apex_hostile_tests.setCwd(b.path("."));

    const test_apex_hostile_step = b.step(
        "test-apex-hostile",
        "Run Apex Zig wrapper tests against the hostile C ABI double",
    );
    test_apex_hostile_step.dependOn(&run_apex_hostile_tests.step);

    // Optional ASan+UBSan C smoke (real engine, not the product binary).
    // Hosts without sanitizer runtime get a documented skip (exit 0), not a fake pass.
    const sanitize_step = b.step(
        "test-apex-sanitize",
        "Optional ASan+UBSan smoke for vendor/apex (skips if unavailable)",
    );
    const sanitize_run = b.addSystemCommand(&.{
        "bash",
        "-c",
        \\set -euo pipefail
        \\OUT="${TMPDIR:-/tmp}/boris-apex-sanitize-smoke-$$"
        \\LOG="${TMPDIR:-/tmp}/boris-apex-sanitize-build-$$.log"
        \\cleanup() { rm -f "$OUT" "$LOG"; }
        \\trap cleanup EXIT
        \\if ! zig cc -std=c11 -fsanitize=address,undefined -fno-omit-frame-pointer -g \
        \\    -I vendor/apex vendor/apex/apex.c vendor/apex/apex_sanitize_smoke.c \
        \\    -o "$OUT" >"$LOG" 2>&1; then
        \\  echo "test-apex-sanitize: NOT AVAILABLE on this host (sanitizer build failed)"
        \\  echo "--- zig cc log (first 40 lines) ---"
        \\  head -40 "$LOG" || true
        \\  echo "Documented skip — not counted as a green sanitizer run."
        \\  exit 0
        \\fi
        \\echo "test-apex-sanitize: running ASan+UBSan smoke..."
        \\"$OUT"
        \\echo "test-apex-sanitize: ok"
    });
    sanitize_run.setCwd(b.path("."));
    sanitize_step.dependOn(&sanitize_run.step);

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

    // --- Hardening integration tests (milestone 10) ------------------------
    const hardening_mod = b.createModule(.{
        .root_source_file = b.path("src/hardening_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(hardening_mod, b, false);
    hardening_mod.addOptions("build_options", apex_opts);
    const hardening_tests = b.addTest(.{
        .root_module = hardening_mod,
    });
    const run_hardening_tests = b.addRunArtifact(hardening_tests);
    run_hardening_tests.setCwd(b.path("."));

    // Fuzz suite (frontmatter / component / apex / graph) — deterministic seeds.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(fuzz_mod, b, false);
    fuzz_mod.addOptions("build_options", apex_opts);
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    run_fuzz_tests.setCwd(b.path("."));

    // --- Review package (IR + optional RAG tar) ----------------------------
    // Reuses pipeline.run / rag.run; does not change IR schema or HTML defaults.
    const package_mod = b.createModule(.{
        .root_source_file = b.path("src/package.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkApex(package_mod, b, false);
    package_mod.addOptions("build_options", apex_opts);

    const package_exe = b.addExecutable(.{
        .name = "boris-package",
        .root_module = package_mod,
    });
    b.installArtifact(package_exe);

    const package_run = b.addRunArtifact(package_exe);
    package_run.setCwd(b.path("."));
    package_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        package_run.addArgs(args);
    }

    const package_step = b.step(
        "package",
        "Build a deterministic IR (+ optional RAG) review tar under packages/",
    );
    package_step.dependOn(&package_run.step);

    const package_tests = b.addTest(.{
        .root_module = package_mod,
    });
    const run_package_tests = b.addRunArtifact(package_tests);
    run_package_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_fixtures_tests.step);
    test_step.dependOn(&run_scanner_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_pipeline_tests.step);
    test_step.dependOn(&run_graph_tests.step);
    test_step.dependOn(&run_aside_tests.step);
    test_step.dependOn(&run_rag_tests.step);
    test_step.dependOn(&run_apex_tests.step);
    test_step.dependOn(&run_assemble_tests.step);
    test_step.dependOn(&run_compile_tests.step);
    test_step.dependOn(&run_hardening_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_source_rag_tests.step);
    test_step.dependOn(&run_package_tests.step);

    const test_harness_step = b.step(
        "test-harness",
        "Run hardening integration tests (alias subset of zig build test)",
    );
    test_harness_step.dependOn(&run_hardening_tests.step);
}

/// Compile and link Apex C into a Zig module (in-process; never a subprocess).
/// `hostile` selects `apex_hostile.c` instead of the real stub engine.
fn linkApex(mod: *std.Build.Module, b: *std.Build, hostile: bool) void {
    mod.link_libc = true;
    mod.addIncludePath(b.path("vendor/apex"));
    const c_file = if (hostile)
        "vendor/apex/apex_hostile.c"
    else
        "vendor/apex/apex.c";
    mod.addCSourceFile(.{
        .file = b.path(c_file),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
        },
    });
}
