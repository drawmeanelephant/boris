const std = @import("std");

/// Boris build graph.
/// Product CLI: typed options + IR pipeline (m6) + RAG export (m7) +
/// scanner/parser (m4–m5). Milestone 9: HTML assemble/compile tests (not
/// default CLI). Milestone 10: Aside tokenizer + hardening. Fixture
/// inventory (m2). Separate tools: `boris-source-rag`, `boris-package`.
/// Markdown → HTML rendering is delegated to the Oliver library (pinned in
/// build.zig.zon; see docs/contracts/oliver-renderer.md).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Portable AT Protocol OAuth primitives. This module has no host I/O,
    // clock, filesystem, or ambient-randomness dependency; consumers provide
    // those capabilities at their platform boundary.
    const atproto_oauth_mod = b.addModule("atproto_oauth", .{
        .root_source_file = b.path("src/atproto_oauth.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_oauth_tests = b.addTest(.{ .root_module = atproto_oauth_mod });
    const run_atproto_oauth_tests = b.addRunArtifact(atproto_oauth_tests);
    run_atproto_oauth_tests.setCwd(b.path("."));

    // A compile-only portability gate: the core must stay usable without an
    // operating system. Host adapters are intentionally tested elsewhere.
    const freestanding_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const atproto_oauth_freestanding_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_oauth.zig"),
        .target = freestanding_target,
        .optimize = .ReleaseSafe,
    });
    const atproto_oauth_freestanding = b.addObject(.{
        .name = "atproto-oauth-freestanding",
        .root_module = atproto_oauth_freestanding_mod,
    });
    const check_atproto_oauth_freestanding = b.step(
        "check-atproto-oauth-freestanding",
        "Compile the ATProto OAuth core for wasm32-freestanding",
    );
    check_atproto_oauth_freestanding.dependOn(&atproto_oauth_freestanding.step);
    const test_atproto_oauth = b.step(
        "test-atproto-oauth",
        "Run ATProto OAuth core tests and its freestanding compile gate",
    );
    test_atproto_oauth.dependOn(&run_atproto_oauth_tests.step);
    test_atproto_oauth.dependOn(check_atproto_oauth_freestanding);

    // Portable DID and OAuth authority discovery over an injected transport.
    const atproto_identity_mod = b.addModule("atproto_identity", .{
        .root_source_file = b.path("src/atproto_identity.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_identity_tests = b.addTest(.{ .root_module = atproto_identity_mod });
    const run_atproto_identity_tests = b.addRunArtifact(atproto_identity_tests);
    run_atproto_identity_tests.setCwd(b.path("."));

    // Native std HTTP adapter. Host-only by design; portable discovery never
    // imports it and the freestanding gate below proves that boundary.
    const atproto_transport_std_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_transport_std.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_transport_std_tests = b.addTest(.{ .root_module = atproto_transport_std_mod });
    const run_atproto_transport_std_tests = b.addRunArtifact(atproto_transport_std_tests);
    run_atproto_transport_std_tests.setCwd(b.path("."));

    const atproto_identity_freestanding_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_identity.zig"),
        .target = freestanding_target,
        .optimize = .ReleaseSafe,
    });
    const atproto_identity_freestanding = b.addObject(.{
        .name = "atproto-identity-freestanding",
        .root_module = atproto_identity_freestanding_mod,
    });
    check_atproto_oauth_freestanding.dependOn(&atproto_identity_freestanding.step);

    const test_atproto_discovery = b.step(
        "test-atproto-discovery",
        "Run ATProto DID/discovery, native transport, and freestanding gates",
    );
    test_atproto_discovery.dependOn(&run_atproto_identity_tests.step);
    test_atproto_discovery.dependOn(&run_atproto_transport_std_tests.step);
    test_atproto_discovery.dependOn(check_atproto_oauth_freestanding);

    // Portable handle resolution composes an injected DNS TXT capability with
    // the existing HTTPS and DID authority chain. The native DNS wire adapter
    // remains host-only and is tested independently.
    const atproto_handle_mod = b.addModule("atproto_handle", .{
        .root_source_file = b.path("src/atproto_handle.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_handle_tests = b.addTest(.{ .root_module = atproto_handle_mod });
    const run_atproto_handle_tests = b.addRunArtifact(atproto_handle_tests);
    run_atproto_handle_tests.setCwd(b.path("."));

    const atproto_dns_std_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_dns_std.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_dns_std_tests = b.addTest(.{ .root_module = atproto_dns_std_mod });
    const run_atproto_dns_std_tests = b.addRunArtifact(atproto_dns_std_tests);
    run_atproto_dns_std_tests.setCwd(b.path("."));

    const atproto_handle_freestanding_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_handle.zig"),
        .target = freestanding_target,
        .optimize = .ReleaseSafe,
    });
    const atproto_handle_freestanding = b.addObject(.{
        .name = "atproto-handle-freestanding",
        .root_module = atproto_handle_freestanding_mod,
    });
    check_atproto_oauth_freestanding.dependOn(&atproto_handle_freestanding.step);

    const test_atproto_handles = b.step(
        "test-atproto-handles",
        "Run ATProto handle, DNS, bidirectional-verification, and freestanding gates",
    );
    test_atproto_handles.dependOn(&run_atproto_handle_tests.step);
    test_atproto_handles.dependOn(&run_atproto_dns_std_tests.step);
    test_atproto_handles.dependOn(check_atproto_oauth_freestanding);

    // Portable PAR/callback/token state machine plus the narrow native
    // loopback/browser composition. Only the portable module joins the
    // wasm32-freestanding gate.
    const atproto_authorization_mod = b.addModule("atproto_authorization", .{
        .root_source_file = b.path("src/atproto_authorization.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_authorization_tests = b.addTest(.{ .root_module = atproto_authorization_mod });
    const run_atproto_authorization_tests = b.addRunArtifact(atproto_authorization_tests);
    run_atproto_authorization_tests.setCwd(b.path("."));

    const atproto_interactive_std_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_interactive_std.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_interactive_std_tests = b.addTest(.{ .root_module = atproto_interactive_std_mod });
    const run_atproto_interactive_std_tests = b.addRunArtifact(atproto_interactive_std_tests);
    run_atproto_interactive_std_tests.setCwd(b.path("."));
    const atproto_loopback_std_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/atproto_loopback_std.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_atproto_loopback_std_tests = b.addRunArtifact(atproto_loopback_std_tests);
    run_atproto_loopback_std_tests.setCwd(b.path("."));
    const atproto_browser_std_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/atproto_browser_std.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_atproto_browser_std_tests = b.addRunArtifact(atproto_browser_std_tests);
    run_atproto_browser_std_tests.setCwd(b.path("."));

    const atproto_authorization_freestanding_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_authorization.zig"),
        .target = freestanding_target,
        .optimize = .ReleaseSafe,
    });
    const atproto_authorization_freestanding = b.addObject(.{
        .name = "atproto-authorization-freestanding",
        .root_module = atproto_authorization_freestanding_mod,
    });
    check_atproto_oauth_freestanding.dependOn(&atproto_authorization_freestanding.step);

    const test_atproto_authorization = b.step(
        "test-atproto-authorization",
        "Run ATProto PAR/callback/token, native loopback/browser, and freestanding gates",
    );
    test_atproto_authorization.dependOn(&run_atproto_authorization_tests.step);
    test_atproto_authorization.dependOn(&run_atproto_interactive_std_tests.step);
    test_atproto_authorization.dependOn(&run_atproto_loopback_std_tests.step);
    test_atproto_authorization.dependOn(&run_atproto_browser_std_tests.step);
    test_atproto_authorization.dependOn(check_atproto_oauth_freestanding);

    // Typed DPoP-authenticated XRPC record client (get/put/deleteRecord).
    // Protocol infrastructure for Standard.site publication, not a generic
    // ATProto SDK. The portable module joins the freestanding gate; native
    // networking stays behind the existing host transport adapter.
    const atproto_xrpc_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_xrpc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_xrpc_tests = b.addTest(.{ .root_module = atproto_xrpc_mod });
    const run_atproto_xrpc_tests = b.addRunArtifact(atproto_xrpc_tests);
    run_atproto_xrpc_tests.setCwd(b.path("."));

    const atproto_xrpc_freestanding_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_xrpc.zig"),
        .target = freestanding_target,
        .optimize = .ReleaseSafe,
    });
    const atproto_xrpc_freestanding = b.addObject(.{
        .name = "atproto-xrpc-freestanding",
        .root_module = atproto_xrpc_freestanding_mod,
    });
    check_atproto_oauth_freestanding.dependOn(&atproto_xrpc_freestanding.step);

    const test_atproto_xrpc = b.step(
        "test-atproto-xrpc",
        "Run ATProto XRPC record client, nonce, identity, and freestanding gates",
    );
    test_atproto_xrpc.dependOn(&run_atproto_xrpc_tests.step);
    test_atproto_xrpc.dependOn(check_atproto_oauth_freestanding);

    // Portable app-password (createSession/refreshSession) authentication:
    // the explicit, opt-in Bearer credential path for command-line publishers.
    // Like the XRPC client it composes an injected transport and no host
    // capabilities, so it joins the freestanding gate.
    const atproto_password_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_password.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_password_tests = b.addTest(.{ .root_module = atproto_password_mod });
    const run_atproto_password_tests = b.addRunArtifact(atproto_password_tests);
    run_atproto_password_tests.setCwd(b.path("."));

    const atproto_password_freestanding_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_password.zig"),
        .target = freestanding_target,
        .optimize = .ReleaseSafe,
    });
    const atproto_password_freestanding = b.addObject(.{
        .name = "atproto-password-freestanding",
        .root_module = atproto_password_freestanding_mod,
    });
    check_atproto_oauth_freestanding.dependOn(&atproto_password_freestanding.step);

    const test_atproto_password_step = b.step(
        "test-atproto-password",
        "Run ATProto app-password createSession/refreshSession and freestanding gates",
    );
    test_atproto_password_step.dependOn(&run_atproto_password_tests.step);
    test_atproto_password_step.dependOn(check_atproto_oauth_freestanding);
    // Deterministic Standard.site offline record projection and plan.
    // Credential-free; consumes declared page metadata and profile facts.
    const standard_site_mod = b.createModule(.{
        .root_source_file = b.path("src/standard_site.zig"),
        .target = target,
        .optimize = optimize,
    });
    const standard_site_tests = b.addTest(.{ .root_module = standard_site_mod });
    const run_standard_site_tests = b.addRunArtifact(standard_site_tests);
    run_standard_site_tests.setCwd(b.path("."));
    const test_standard_site_step = b.step(
        "test-standard-site",
        "Run Standard.site projection, rkey, eligibility, and plan tests",
    );
    test_standard_site_step.dependOn(&run_standard_site_tests.step);

    // Standard.site web-facing verification emission: head links, well-known
    // overlay, sideband artifact, ownership, and the emitted/limited/not
    // verified report. Credential-free like the projection it consumes.
    const standard_site_emit_mod = b.createModule(.{
        .root_source_file = b.path("src/standard_site_emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const standard_site_emit_tests = b.addTest(.{ .root_module = standard_site_emit_mod });
    const run_standard_site_emit_tests = b.addRunArtifact(standard_site_emit_tests);
    run_standard_site_emit_tests.setCwd(b.path("."));
    const test_standard_site_emit_step = b.step(
        "test-standard-site-emit",
        "Run Standard.site verification emission, well-known, and report tests",
    );
    test_standard_site_emit_step.dependOn(&run_standard_site_emit_tests.step);

    // Standard.site publish reconciliation: consume a committed plan, verify
    // the authorized session DID/PDS/collections/rkeys/digest, reconcile each
    // record against the PDS with zero writes for unchanged state, and emit
    // intended-vs-observed evidence. Offline mock PDS only; no network.
    const standard_site_reconcile_mod = b.createModule(.{
        .root_source_file = b.path("src/standard_site_reconcile.zig"),
        .target = target,
        .optimize = optimize,
    });
    const standard_site_reconcile_tests = b.addTest(.{ .root_module = standard_site_reconcile_mod });
    const run_standard_site_reconcile_tests = b.addRunArtifact(standard_site_reconcile_tests);
    run_standard_site_reconcile_tests.setCwd(b.path("."));
    const test_standard_site_reconcile_step = b.step(
        "test-standard-site-reconcile",
        "Run Standard.site reconciliation, evidence, and offline mock PDS tests",
    );
    test_standard_site_reconcile_step.dependOn(&run_standard_site_reconcile_tests.step);

    // Standard.site one-shot publish orchestration: identity discovery, the
    // profile-PDS binding gate, interactive OAuth authorization, and the
    // reconciliation pass. Offline scripted mock only; no network.
    const standard_site_publish_mod = b.createModule(.{
        .root_source_file = b.path("src/standard_site_publish.zig"),
        .target = target,
        .optimize = optimize,
    });
    const standard_site_publish_tests = b.addTest(.{ .root_module = standard_site_publish_mod });
    const run_standard_site_publish_tests = b.addRunArtifact(standard_site_publish_tests);
    run_standard_site_publish_tests.setCwd(b.path("."));
    const test_standard_site_publish_step = b.step(
        "test-standard-site-publish",
        "Run Standard.site publish orchestration, gates, and redaction tests",
    );
    test_standard_site_publish_step.dependOn(&run_standard_site_publish_tests.step);

    // Standard.site live interoperability smoke: the manual, opt-in gate that
    // proves discovery, OAuth, XRPC writes, readback, and cleanup against a
    // real PDS. The live path is CLI-only; these tests drive an offline
    // scripted discovery + OAuth + PDS double.
    const standard_site_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/standard_site_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    const standard_site_smoke_tests = b.addTest(.{ .root_module = standard_site_smoke_mod });
    const run_standard_site_smoke_tests = b.addRunArtifact(standard_site_smoke_tests);
    run_standard_site_smoke_tests.setCwd(b.path("."));
    const test_standard_site_smoke_step = b.step(
        "test-standard-site-smoke",
        "Run Standard.site live-smoke orchestration tests (offline mock only)",
    );
    test_standard_site_smoke_step.dependOn(&run_standard_site_smoke_tests.step);

    // Host session store: user-scoped, 0600, atomic-replace session documents
    // plus a process-safe advisory lock. No secrets ever leave the 0600 files.
    const atproto_session_store_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_session_store.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_session_store_tests = b.addTest(.{ .root_module = atproto_session_store_mod });
    const run_atproto_session_store_tests = b.addRunArtifact(atproto_session_store_tests);
    run_atproto_session_store_tests.setCwd(b.path("."));
    const test_atproto_session_store_step = b.step(
        "test-atproto-session-store",
        "Run host session store atomic-write, lock, and fail-closed tests",
    );
    test_atproto_session_store_step.dependOn(&run_atproto_session_store_tests.step);

    // Host session lifecycle: acquire (load + refresh + rotate-or-die persist),
    // storeNew, list, remove, and user-scoped root resolution.
    const atproto_session_std_mod = b.createModule(.{
        .root_source_file = b.path("src/atproto_session_std.zig"),
        .target = target,
        .optimize = optimize,
    });
    const atproto_session_std_tests = b.addTest(.{ .root_module = atproto_session_std_mod });
    const run_atproto_session_std_tests = b.addRunArtifact(atproto_session_std_tests);
    run_atproto_session_std_tests.setCwd(b.path("."));
    const test_atproto_session_std_step = b.step(
        "test-atproto-session-std",
        "Run session lifecycle acquire/refresh/rotate-or-die tests",
    );
    test_atproto_session_std_step.dependOn(&run_atproto_session_std_tests.step);

    // Oliver: freestanding Zig markup library (source bytes → typed document
    // → deterministic HTML). Pinned by content hash in build.zig.zon; see
    // docs/contracts/oliver-renderer.md for the exact revision and the
    // upgrade procedure. No libc, no host tools, no global state.
    const oliver_dep = b.dependency("oliver", .{
        .target = target,
        .optimize = optimize,
    });
    const oliver_mod = oliver_dep.module("oliver");

    // Boris's single Markdown → HTML rendering seam. Modules that transitively
    // import it also import "oliver" (linkOliver below): a relative
    // @import("render.zig") resolves in the importing module's context.
    const render_mod = b.createModule(.{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "oliver", .module = oliver_mod }},
    });

    // --- Product CLI (milestone 6 IR surface + m10 Oliver render seam) -----
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(root_mod, oliver_mod);

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
    linkOliver(scanner_mod, oliver_mod);
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
    linkOliver(parser_mod, oliver_mod);
    const parser_tests = b.addTest(.{
        .root_module = parser_mod,
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);
    run_parser_tests.setCwd(b.path("."));

    // --- Explicit bounded Textile-to-Markdown adapter ---------------------
    const textile_mod = b.createModule(.{
        .root_source_file = b.path("src/textile.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(textile_mod, oliver_mod);
    const textile_tests = b.addTest(.{
        .root_module = textile_mod,
    });
    const run_textile_tests = b.addRunArtifact(textile_tests);
    run_textile_tests.setCwd(b.path("."));

    // --- Explicit Cooklang seam (parse via Oliver, render/validate here) ---
    // Oliver's Cooklang stack shares the single `.oliver` pin; the seam module
    // imports the shared module as `oliver` and owns Markdown rendering, the IR
    // recipe facet, and output-safety validation (docs/contracts/oliver-renderer.md).
    const cooklang_mod = b.createModule(.{
        .root_source_file = b.path("src/cooklang_seam.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "oliver", .module = oliver_mod },
        },
    });
    const cooklang_tests = b.addTest(.{
        .root_module = cooklang_mod,
    });
    const run_cooklang_tests = b.addRunArtifact(cooklang_tests);
    run_cooklang_tests.setCwd(b.path("."));

    // Black-box regression for seam warning printing: the load-time
    // validation pass is the only printer, so plain and incremental HTML
    // builds (and the IR path) each emit every structural warning exactly
    // once — including cache-reused pages that skip render.
    const cooklang_incremental_run = b.addSystemCommand(&.{
        "bash",
        "scripts/test-cooklang-incremental-warnings.sh",
    });
    cooklang_incremental_run.setCwd(b.path("."));
    cooklang_incremental_run.has_side_effects = true;
    cooklang_incremental_run.step.dependOn(b.getInstallStep());
    const test_cooklang_incremental_step = b.step(
        "test-cooklang-incremental-warnings",
        "Run Cooklang warning-printing regression on plain/incremental HTML and IR paths",
    );
    test_cooklang_incremental_step.dependOn(&cooklang_incremental_run.step);

    // `boris init` black-box: the generated starter must build/validate/plan
    // out of the box, refuse to clobber an existing project, and be
    // byte-deterministic.
    const init_run = b.addSystemCommand(&.{
        "bash",
        "scripts/test-boris-init.sh",
    });
    init_run.setCwd(b.path("."));
    init_run.has_side_effects = true;
    init_run.step.dependOn(b.getInstallStep());
    const test_boris_init_step = b.step(
        "test-boris-init",
        "Run boris init starter-tree black-box test",
    );
    test_boris_init_step.dependOn(&init_run.step);

    // Layout-rule precedence guard (#400): the reference-theme example must
    // select identical layouts under both rule declaration orders (fixed
    // precedence: id > glob specificity > role > fallback) and publish the
    // documented assets.
    // XHTML output profile evidence (#448, acceptance criterion 5): Boris
    // content must publish a page under the XHTML profile that an independent
    // XML parser (xmllint/libxml2, else python3 ElementTree) accepts, and the
    // layout-owned document wrapper must carry the XML declaration +
    // xhtml namespace exactly once. Pins the profile seam so it cannot rot.
    const xhtml_evidence_run = b.addSystemCommand(&.{
        "bash",
        "scripts/test-xhtml-evidence.sh",
    });
    xhtml_evidence_run.setCwd(b.path("."));
    xhtml_evidence_run.has_side_effects = true;
    xhtml_evidence_run.step.dependOn(b.getInstallStep());
    const test_xhtml_evidence_step = b.step(
        "test-xhtml-evidence",
        "Run the XHTML output-profile well-formedness evidence guard",
    );
    test_xhtml_evidence_step.dependOn(&xhtml_evidence_run.step);

    const reference_theme_run = b.addSystemCommand(&.{
        "bash",
        "scripts/test-reference-theme-layout.sh",
    });
    reference_theme_run.setCwd(b.path("."));
    reference_theme_run.has_side_effects = true;
    reference_theme_run.step.dependOn(b.getInstallStep());
    const test_reference_theme_step = b.step(
        "test-reference-theme-layout",
        "Run reference-theme layout-rule precedence black-box test",
    );
    test_reference_theme_step.dependOn(&reference_theme_run.step);

    // Version query + artifact provenance guard (#410/#419): the binary's
    // `--version` / `-V` must print exactly the base compiler id from
    // src/pipeline.zig, and real artifact sets (plain, Cooklang, and
    // semantic-relations corpora) must record the base or a `+`-suffixed
    // variant id, per the pin + provenance recipe in docs/contracts/cli.md.
    // Also proves a tampered recorded id is rejected, so the documented
    // recipe cannot drift silently from the executable behavior.
    const version_pin_run = b.addSystemCommand(&.{
        "bash",
        "scripts/test-version-pin.sh",
    });
    version_pin_run.setCwd(b.path("."));
    version_pin_run.has_side_effects = true;
    version_pin_run.step.dependOn(b.getInstallStep());
    const test_version_pin_step = b.step(
        "test-version-pin",
        "Run the version query + artifact provenance pin guard",
    );
    test_version_pin_step.dependOn(&version_pin_run.step);

    // Teaching-layer link guard (#394): every relative markdown link in
    // README.md and docs/authoring-spine.md must resolve to a real file or
    // directory, and heading anchors must match GitHub-style slugs, so the
    // teaching layer cannot rot silently. Docs-only: no binary dependency.
    const doc_links_run = b.addSystemCommand(&.{ "bash", "scripts/test-doc-links.sh" });
    doc_links_run.setCwd(b.path("."));
    doc_links_run.has_side_effects = true;
    const test_doc_links_step = b.step(
        "test-doc-links",
        "Run the README + authoring-spine internal link guard",
    );
    test_doc_links_step.dependOn(&doc_links_run.step);

    // --- Pipeline + graph tests (milestone 6) ------------------------------
    // Pipeline imports aside (component validation) → needs the Oliver render seam.
    const pipeline_mod = b.createModule(.{
        .root_source_file = b.path("src/pipeline.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(pipeline_mod, oliver_mod);
    const pipeline_tests = b.addTest(.{
        .root_module = pipeline_mod,
    });
    const run_pipeline_tests = b.addRunArtifact(pipeline_tests);
    run_pipeline_tests.setCwd(b.path("."));

    // --- Publication profile parser + static planner (Slice 1) -----------
    const publication_profile_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_profile.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(publication_profile_mod, oliver_mod);
    const publication_profile_tests = b.addTest(.{ .root_module = publication_profile_mod });
    const run_publication_profile_tests = b.addRunArtifact(publication_profile_tests);
    run_publication_profile_tests.setCwd(b.path("."));
    const test_publication_profile_step = b.step("test-publication-profile", "Run publication profile parser and planner tests");
    test_publication_profile_step.dependOn(&run_publication_profile_tests.step);

    // --- GitHub Pages publication-location contract -----------------------
    const github_pages_mod = b.createModule(.{
        .root_source_file = b.path("src/github_pages.zig"),
        .target = target,
        .optimize = optimize,
    });
    const github_pages_tests = b.addTest(.{ .root_module = github_pages_mod });
    const run_github_pages_tests = b.addRunArtifact(github_pages_tests);
    run_github_pages_tests.setCwd(b.path("."));
    const test_github_pages_step = b.step(
        "test-github-pages",
        "Run GitHub Pages publication-location normalization tests",
    );
    test_github_pages_step.dependOn(&run_github_pages_tests.step);

    // --- Publication plan declaration renderer -----------------------------
    const publication_plan_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_plan.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(publication_plan_mod, oliver_mod);
    const publication_plan_tests = b.addTest(.{ .root_module = publication_plan_mod });
    const run_publication_plan_tests = b.addRunArtifact(publication_plan_tests);
    run_publication_plan_tests.setCwd(b.path("."));
    const test_publication_plan_step = b.step("test-publication-plan", "Run publication plan renderer and schema tests");
    test_publication_plan_step.dependOn(&run_publication_plan_tests.step);

    // --- Nostr NIP-23 long-form publication (offline plan slice) ----------
    const nostr_mod = b.createModule(.{
        .root_source_file = b.path("src/nostr.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(nostr_mod, oliver_mod);
    const nostr_tests = b.addTest(.{ .root_module = nostr_mod });
    const run_nostr_tests = b.addRunArtifact(nostr_tests);
    run_nostr_tests.setCwd(b.path("."));
    const test_nostr_step = b.step("test-nostr", "Run Nostr NIP-23 mapping, eligibility, and plan tests");
    test_nostr_step.dependOn(&run_nostr_tests.step);

    const nostr_plan_mod = b.createModule(.{
        .root_source_file = b.path("src/nostr_plan.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(nostr_plan_mod, oliver_mod);
    const nostr_plan_tests = b.addTest(.{ .root_module = nostr_plan_mod });
    const run_nostr_plan_tests = b.addRunArtifact(nostr_plan_tests);
    run_nostr_plan_tests.setCwd(b.path("."));
    test_nostr_step.dependOn(&run_nostr_plan_tests.step);

    // --- Runtime publication artifact inventory ---------------------------
    const artifact_inventory_mod = b.createModule(.{
        .root_source_file = b.path("src/artifact_inventory.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(artifact_inventory_mod, oliver_mod);
    const artifact_inventory_tests = b.addTest(.{ .root_module = artifact_inventory_mod });
    const run_artifact_inventory_tests = b.addRunArtifact(artifact_inventory_tests);
    run_artifact_inventory_tests.setCwd(b.path("."));
    const test_artifact_inventory_step = b.step(
        "test-publication-artifacts",
        "Run publication artifact inventory and schema-shape tests",
    );
    test_artifact_inventory_step.dependOn(&run_artifact_inventory_tests.step);

    // --- Internal Boris Doctor rendered snapshot analyzer -----------------
    const doctor_mod = b.createModule(.{
        .root_source_file = b.path("src/doctor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const doctor_tests = b.addTest(.{ .root_module = doctor_mod });
    const run_doctor_tests = b.addRunArtifact(doctor_tests);
    run_doctor_tests.setCwd(b.path("."));
    const test_doctor_step = b.step(
        "test-doctor",
        "Run internal Doctor rendered HTML and search snapshot tests",
    );
    test_doctor_step.dependOn(&run_doctor_tests.step);

    // --- Target-local publication checks evidence --------------------------
    const publication_checks_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_checks.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(publication_checks_mod, oliver_mod);
    const publication_checks_tests = b.addTest(.{ .root_module = publication_checks_mod });
    const run_publication_checks_tests = b.addRunArtifact(publication_checks_tests);
    run_publication_checks_tests.setCwd(b.path("."));
    const test_publication_checks_step = b.step(
        "test-publication-checks",
        "Run deterministic target-local publication checks evidence tests",
    );
    test_publication_checks_step.dependOn(&run_publication_checks_tests.step);

    // --- Claims-and-limitations evidence derived from checks -----------------
    const publication_claims_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_claims.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(publication_claims_mod, oliver_mod);
    const publication_claims_tests = b.addTest(.{ .root_module = publication_claims_mod });
    const run_publication_claims_tests = b.addRunArtifact(publication_claims_tests);
    run_publication_claims_tests.setCwd(b.path("."));
    const test_publication_claims_step = b.step(
        "test-publication-claims",
        "Run deterministic claims-and-limitations evidence derivation tests",
    );
    test_publication_claims_step.dependOn(&run_publication_claims_tests.step);

    // --- Touch Atlas evidence derived from committed artifacts, checks, and claims ---
    const publication_touches_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_touches.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(publication_touches_mod, oliver_mod);
    const publication_touches_tests = b.addTest(.{ .root_module = publication_touches_mod });
    const run_publication_touches_tests = b.addRunArtifact(publication_touches_tests);
    run_publication_touches_tests.setCwd(b.path("."));
    const test_publication_touches_step = b.step(
        "test-publication-touches",
        "Run deterministic target-local Touch Atlas evidence derivation tests",
    );
    test_publication_touches_step.dependOn(&run_publication_touches_tests.step);

    // --- Proof Pack presentation derived from the committed evidence chain ---
    const publication_proof_pack_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_proof_pack.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(publication_proof_pack_mod, oliver_mod);
    const publication_proof_pack_tests = b.addTest(.{ .root_module = publication_proof_pack_mod });
    const run_publication_proof_pack_tests = b.addRunArtifact(publication_proof_pack_tests);
    run_publication_proof_pack_tests.setCwd(b.path("."));
    const test_publication_proof_pack_step = b.step(
        "test-publication-proof-pack",
        "Run deterministic Proof Pack parser, renderer, and transaction tests",
    );
    test_publication_proof_pack_step.dependOn(&run_publication_proof_pack_tests.step);

    // Private seeded generator harness. It is opt-in because it launches the
    // installed Boris binary against a deterministic poisoned fixture.
    const testdata_generator_mod = b.createModule(.{
        .root_source_file = b.path("tools/testdata-generator/src/generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const publication_fixture_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_checks_fixture_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fixture_generator", .module = testdata_generator_mod }},
    });
    linkOliver(publication_fixture_mod, oliver_mod);
    const publication_fixture_tests = b.addTest(.{ .root_module = publication_fixture_mod });
    const run_publication_fixture_tests = b.addRunArtifact(publication_fixture_tests);
    run_publication_fixture_tests.setCwd(b.path("."));
    run_publication_fixture_tests.step.dependOn(b.getInstallStep());
    const test_publication_fixture_step = b.step(
        "test-publication-fixture",
        "Run the private mild-poison publication-checks evidence harness",
    );
    test_publication_fixture_step.dependOn(&run_publication_fixture_tests.step);

    // Claims evidence harness. Same seeded poisoned fixture, one stage deeper:
    // checks.json is derived first, then claims.json must track it.
    const publication_claims_fixture_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_claims_fixture_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fixture_generator", .module = testdata_generator_mod }},
    });
    linkOliver(publication_claims_fixture_mod, oliver_mod);
    const publication_claims_fixture_tests = b.addTest(.{ .root_module = publication_claims_fixture_mod });
    const run_publication_claims_fixture_tests = b.addRunArtifact(publication_claims_fixture_tests);
    run_publication_claims_fixture_tests.setCwd(b.path("."));
    run_publication_claims_fixture_tests.step.dependOn(b.getInstallStep());
    const test_publication_claims_fixture_step = b.step(
        "test-publication-claims-fixture",
        "Run the private mild-poison publication-claims evidence harness",
    );
    test_publication_claims_fixture_step.dependOn(&run_publication_claims_fixture_tests.step);

    // Touch Atlas evidence harness. Same seeded poisoned fixture, one stage
    // deeper: checks and claims are derived first, then touches.json must
    // track both without rereading any payload.
    const publication_touches_fixture_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_touches_fixture_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fixture_generator", .module = testdata_generator_mod }},
    });
    linkOliver(publication_touches_fixture_mod, oliver_mod);
    const publication_touches_fixture_tests = b.addTest(.{ .root_module = publication_touches_fixture_mod });
    const run_publication_touches_fixture_tests = b.addRunArtifact(publication_touches_fixture_tests);
    run_publication_touches_fixture_tests.setCwd(b.path("."));
    run_publication_touches_fixture_tests.step.dependOn(b.getInstallStep());
    const test_publication_touches_fixture_step = b.step(
        "test-publication-touches-fixture",
        "Run the private mild-poison publication Touch Atlas evidence harness",
    );
    test_publication_touches_fixture_step.dependOn(&run_publication_touches_fixture_tests.step);

    // Proof Pack presentation harness. Same seeded poisoned fixture, one
    // stage deeper: checks, claims, and touches are derived first, then the
    // Proof Pack pair must track all four evidence reports without rereading
    // any payload.
    const publication_proof_pack_fixture_mod = b.createModule(.{
        .root_source_file = b.path("src/publication_proof_pack_fixture_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fixture_generator", .module = testdata_generator_mod }},
    });
    linkOliver(publication_proof_pack_fixture_mod, oliver_mod);
    const publication_proof_pack_fixture_tests = b.addTest(.{ .root_module = publication_proof_pack_fixture_mod });
    const run_publication_proof_pack_fixture_tests = b.addRunArtifact(publication_proof_pack_fixture_tests);
    run_publication_proof_pack_fixture_tests.setCwd(b.path("."));
    run_publication_proof_pack_fixture_tests.step.dependOn(b.getInstallStep());
    const test_publication_proof_pack_fixture_step = b.step(
        "test-publication-proof-pack-fixture",
        "Run the private mild-poison publication Proof Pack presentation harness",
    );
    test_publication_proof_pack_fixture_step.dependOn(&run_publication_proof_pack_fixture_tests.step);

    const graph_mod = b.createModule(.{
        .root_source_file = b.path("src/graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(graph_mod, oliver_mod);
    const graph_tests = b.addTest(.{
        .root_module = graph_mod,
    });
    const run_graph_tests = b.addRunArtifact(graph_tests);
    run_graph_tests.setCwd(b.path("."));

    // --- Aside component tokenizer + HTML render (milestone 10) ------------
    // aside now imports include.zig for inline-code-span awareness, which
    // reaches the Oliver Cooklang seam via parser → page → cooklang_seam.
    const aside_mod = b.createModule(.{
        .root_source_file = b.path("src/aside.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(aside_mod, oliver_mod);
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
    linkOliver(rag_mod, oliver_mod);
    const rag_tests = b.addTest(.{
        .root_module = rag_mod,
    });
    const run_rag_tests = b.addRunArtifact(rag_tests);
    run_rag_tests.setCwd(b.path("."));

    // --- Oliver rendering seam tests -------------------------------------
    const render_tests = b.addTest(.{
        .root_module = render_mod,
    });
    const run_render_tests = b.addRunArtifact(render_tests);
    run_render_tests.setCwd(b.path("."));
    const test_render_step = b.step(
        "test-render",
        "Run Oliver-backed Markdown rendering seam tests",
    );
    test_render_step.dependOn(&run_render_tests.step);

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

    const theme_mod = b.createModule(.{
        .root_source_file = b.path("src/theme.zig"),
        .target = target,
        .optimize = optimize,
    });
    const theme_tests = b.addTest(.{
        .root_module = theme_mod,
    });
    const run_theme_tests = b.addRunArtifact(theme_tests);
    run_theme_tests.setCwd(b.path("."));

    const content_asset_mod = b.createModule(.{
        .root_source_file = b.path("src/content_asset.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(content_asset_mod, oliver_mod);
    const content_asset_tests = b.addTest(.{
        .root_module = content_asset_mod,
    });
    const run_content_asset_tests = b.addRunArtifact(content_asset_tests);
    run_content_asset_tests.setCwd(b.path("."));

    const svg_policy_mod = b.createModule(.{
        .root_source_file = b.path("src/svg_policy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const svg_policy_tests = b.addTest(.{ .root_module = svg_policy_mod });
    const run_svg_policy_tests = b.addRunArtifact(svg_policy_tests);
    run_svg_policy_tests.setCwd(b.path("."));

    const layout_select_mod = b.createModule(.{
        .root_source_file = b.path("src/layout_select.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(layout_select_mod, oliver_mod);
    const layout_select_tests = b.addTest(.{
        .root_module = layout_select_mod,
    });
    const run_layout_select_tests = b.addRunArtifact(layout_select_tests);
    run_layout_select_tests.setCwd(b.path("."));

    const compile_mod = b.createModule(.{
        .root_source_file = b.path("src/compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(compile_mod, oliver_mod);
    const compile_tests = b.addTest(.{
        .root_module = compile_mod,
    });
    const run_compile_tests = b.addRunArtifact(compile_tests);
    run_compile_tests.setCwd(b.path("."));
    const test_compile_step = b.step(
        "test-compile",
        "Run HTML compiler and publication integration tests",
    );
    test_compile_step.dependOn(&run_compile_tests.step);

    // Opt-in 200-page incremental HTML smoke. Kept out of `zig build test`
    // because it exercises a bounded large-site fixture rather than unit scope.
    const scale_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/incremental_scale_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(scale_smoke_mod, oliver_mod);
    const scale_smoke_tests = b.addTest(.{
        .root_module = scale_smoke_mod,
    });
    const run_scale_smoke_tests = b.addRunArtifact(scale_smoke_tests);
    run_scale_smoke_tests.setCwd(b.path("."));
    const test_scale_smoke_step = b.step(
        "test-scale-smoke",
        "Run opt-in 200-page incremental HTML scale smoke",
    );
    test_scale_smoke_step.dependOn(&run_scale_smoke_tests.step);

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
    linkOliver(hardening_mod, oliver_mod);
    const hardening_tests = b.addTest(.{
        .root_module = hardening_mod,
    });
    const run_hardening_tests = b.addRunArtifact(hardening_tests);
    run_hardening_tests.setCwd(b.path("."));

    // --- IR ↔ published JSON Schema conformance --------------------------
    const ir_schema_mod = b.createModule(.{
        .root_source_file = b.path("src/ir_schema_conformance_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(ir_schema_mod, oliver_mod);
    const ir_schema_tests = b.addTest(.{
        .root_module = ir_schema_mod,
    });
    const run_ir_schema_tests = b.addRunArtifact(ir_schema_tests);
    run_ir_schema_tests.setCwd(b.path("."));
    const test_ir_schema_step = b.step(
        "test-ir-schema",
        "Validate emitted IR against the published JSON Schemas",
    );
    test_ir_schema_step.dependOn(&run_ir_schema_tests.step);

    // Layout-selection hostile integration (PR #50 audit harness; no product patches).
    const layout_hostile_mod = b.createModule(.{
        .root_source_file = b.path("src/layout_select_hostile_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(layout_hostile_mod, oliver_mod);
    const layout_hostile_tests = b.addTest(.{
        .root_module = layout_hostile_mod,
    });
    const run_layout_hostile_tests = b.addRunArtifact(layout_hostile_tests);
    run_layout_hostile_tests.setCwd(b.path("."));
    const test_layout_hostile_step = b.step(
        "test-layout-hostile",
        "Hostile integration coverage for --layout-rule selection",
    );
    test_layout_hostile_step.dependOn(&run_layout_hostile_tests.step);

    // Fuzz suite (frontmatter / component / renderer / graph) — deterministic seeds.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(fuzz_mod, oliver_mod);
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
    linkOliver(package_mod, oliver_mod);

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

    // --- Dependency & Cache tests (Milestone P2.1 & P2.3) ------------------
    const include_mod = b.createModule(.{
        .root_source_file = b.path("src/include.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(include_mod, oliver_mod);
    const include_tests = b.addTest(.{
        .root_module = include_mod,
    });
    const run_include_tests = b.addRunArtifact(include_tests);
    run_include_tests.setCwd(b.path("."));

    const wikilink_mod = b.createModule(.{
        .root_source_file = b.path("src/wikilink.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(wikilink_mod, oliver_mod);
    const wikilink_tests = b.addTest(.{
        .root_module = wikilink_mod,
    });
    const run_wikilink_tests = b.addRunArtifact(wikilink_tests);
    run_wikilink_tests.setCwd(b.path("."));

    const dependency_mod = b.createModule(.{
        .root_source_file = b.path("src/dependency.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dependency_tests = b.addTest(.{
        .root_module = dependency_mod,
    });
    const run_dependency_tests = b.addRunArtifact(dependency_tests);
    run_dependency_tests.setCwd(b.path("."));

    // --- Documentation Intelligence analysis core ------------------------
    // Pure graph analysis; CLI wiring remains a separate product slice.
    const intelligence_mod = b.createModule(.{
        .root_source_file = b.path("src/intelligence.zig"),
        .target = target,
        .optimize = optimize,
    });
    const intelligence_tests = b.addTest(.{
        .root_module = intelligence_mod,
    });
    const run_intelligence_tests = b.addRunArtifact(intelligence_tests);
    run_intelligence_tests.setCwd(b.path("."));

    const cache_mod = b.createModule(.{
        .root_source_file = b.path("src/cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(cache_mod, oliver_mod);
    const cache_tests = b.addTest(.{
        .root_module = cache_mod,
    });
    const run_cache_tests = b.addRunArtifact(cache_tests);
    run_cache_tests.setCwd(b.path("."));

    // --- Ingest-time Unicode policy ---------------------------------------
    const unicode_policy_mod = b.createModule(.{
        .root_source_file = b.path("src/unicode_policy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unicode_policy_tests = b.addTest(.{ .root_module = unicode_policy_mod });
    const run_unicode_policy_tests = b.addRunArtifact(unicode_policy_tests);
    run_unicode_policy_tests.setCwd(b.path("."));

    // --- Output-encoding layer + its regression gate ----------------------
    // encode/structured_out are pure; artifact_invariants reads published
    // bytes; emitter_hostile compiles hostile trees through the real emitters.
    const encode_mod = b.createModule(.{
        .root_source_file = b.path("src/encode.zig"),
        .target = target,
        .optimize = optimize,
    });
    const encode_tests = b.addTest(.{ .root_module = encode_mod });
    const run_encode_tests = b.addRunArtifact(encode_tests);
    run_encode_tests.setCwd(b.path("."));

    const structured_out_mod = b.createModule(.{
        .root_source_file = b.path("src/structured_out.zig"),
        .target = target,
        .optimize = optimize,
    });
    const structured_out_tests = b.addTest(.{ .root_module = structured_out_mod });
    const run_structured_out_tests = b.addRunArtifact(structured_out_tests);
    run_structured_out_tests.setCwd(b.path("."));

    const site_url_mod = b.createModule(.{
        .root_source_file = b.path("src/site_url.zig"),
        .target = target,
        .optimize = optimize,
    });
    const site_url_tests = b.addTest(.{ .root_module = site_url_mod });
    const run_site_url_tests = b.addRunArtifact(site_url_tests);
    run_site_url_tests.setCwd(b.path("."));

    const sitemap_mod = b.createModule(.{
        .root_source_file = b.path("src/sitemap.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sitemap_tests = b.addTest(.{ .root_module = sitemap_mod });
    const run_sitemap_tests = b.addRunArtifact(sitemap_tests);
    run_sitemap_tests.setCwd(b.path("."));

    const test_sitemap_step = b.step(
        "test-sitemap",
        "Run shared site URL and deterministic XML sitemap tests",
    );
    test_sitemap_step.dependOn(&run_site_url_tests.step);
    test_sitemap_step.dependOn(&run_sitemap_tests.step);

    // Authoritative no-publication validation CLI contract.
    const validation_contract_run = b.addSystemCommand(&.{
        "bash",
        "test/validate-contract.sh",
    });
    validation_contract_run.setCwd(b.path("."));
    validation_contract_run.has_side_effects = true;
    validation_contract_run.step.dependOn(b.getInstallStep());
    const test_validation_step = b.step(
        "test-validation",
        "Run authoritative no-publication validation contract tests",
    );
    test_validation_step.dependOn(&validation_contract_run.step);

    // Retained publication evidence: generate only the bounded depth chains
    // under the ignored verifier tree, then exercise the real installed CLI.
    const publication_conformance_run = b.addSystemCommand(&.{
        "bash",
        "scripts/verify-publication-conformance.sh",
    });
    publication_conformance_run.setCwd(b.path("."));
    publication_conformance_run.has_side_effects = true;
    publication_conformance_run.step.dependOn(b.getInstallStep());
    const test_publication_conformance_step = b.step(
        "test-publication-conformance",
        "Run retained C02/C03/C04/C08 black-box publication conformance",
    );
    test_publication_conformance_step.dependOn(&publication_conformance_run.step);

    // Release-mode HTML publication smoke. `zig build test` is a Debug build
    // and every unit test allocates through std.testing.allocator (a
    // DebugAllocator), so an invalid free is silently tolerated there. CI
    // publishes a ReleaseSafe binary (.github/workflows/github-pages.yml), and
    // a ReleaseSafe allocator abort is a fatal signal: the process dies after
    // the pages are rendered but before the staging tree is committed, leaving
    // an empty output directory and no diagnostic. That is exactly how a
    // SIGTRAP in the search indexer shipped undetected. This step runs the real
    // release binary over a small site whose search root opens with a heading,
    // under the documented `<main data-boris-search-root>{{content}}</main>`
    // layout, and asserts both a zero exit and that pages were actually
    // published.
    const release_html_smoke_run = b.addSystemCommand(&.{
        "bash",
        "-c",
        \\set -euo pipefail
        \\
        \\mode="${1:-}"
        \\case "$mode" in
        \\  ReleaseSafe | ReleaseFast | ReleaseSmall) ;;
        \\  *)
        \\    echo "test-release-html-smoke: refusing to run against a ${mode:-Debug} build."
        \\    echo "This guard only has value against a release binary: Debug tolerates the"
        \\    echo "invalid free that shipped as a fatal allocator abort out of ReleaseSafe."
        \\    echo "Run: zig build -Doptimize=ReleaseSafe test-release-html-smoke"
        \\    exit 1
        \\    ;;
        \\esac
        \\
        \\BIN="$PWD/zig-out/bin/boris"
        \\test -x "$BIN" || { echo "test-release-html-smoke: $BIN is missing"; exit 1; }
        \\
        \\WORK="$(mktemp -d "${TMPDIR:-/tmp}/boris-release-html-smoke.XXXXXX")"
        \\trap 'rm -rf "$WORK"' EXIT
        \\mkdir -p "$WORK/content/guides" "$WORK/theme/layouts"
        \\
        \\# The documented layout form: exactly one search root, with {{content}}
        \\# not alone on its line.
        \\cat >"$WORK/theme/layouts/main.html" <<'LAYOUT'
        \\<!doctype html>
        \\<html lang="en">
        \\<head><meta charset="utf-8"><title>{{title}}</title></head>
        \\<body>
        \\  <nav>{{nav}}</nav>
        \\  <main data-boris-search-root>{{content}}</main>
        \\</body>
        \\</html>
        \\LAYOUT
        \\
        \\# Every page's search root opens with a heading, so the indexer takes
        \\# the drop-the-empty-leading-section path.
        \\cat >"$WORK/content/index.md" <<'PAGE'
        \\---
        \\title: Home
        \\status: published
        \\---
        \\
        \\# Home
        \\
        \\Root prose for the release smoke.
        \\
        \\## Quick start
        \\
        \\Run `boris`.
        \\PAGE
        \\
        \\cat >"$WORK/content/guides/install.md" <<'PAGE'
        \\---
        \\title: Install Boris
        \\parent: index
        \\status: published
        \\---
        \\
        \\# Install Boris
        \\
        \\Install prose for the release smoke.
        \\PAGE
        \\
        \\cat >"$WORK/content/guides/paths.md" <<'PAGE'
        \\---
        \\title: Paths
        \\parent: index
        \\status: published
        \\---
        \\
        \\# Paths
        \\
        \\Output-relative paths stay stable.
        \\PAGE
        \\
        \\cd "$WORK"
        \\set +e
        \\"$BIN" build --input content --html-dir dist --html-layout theme/layouts/main.html
        \\rc=$?
        \\set -e
        \\if [ "$rc" -ne 0 ]; then
        \\  echo "test-release-html-smoke: FAIL - $mode boris build exited $rc, expected 0."
        \\  echo "  An exit above 128 is a fatal signal (133 SIGTRAP / 134 SIGABRT):"
        \\  echo "  an allocator abort after the pages were rendered. The staging tree"
        \\  echo "  is then never committed, so the output directory is left empty."
        \\  exit 1
        \\fi
        \\
        \\count="$(find dist -name '*.html' -not -path 'dist/_boris/*' | wc -l | tr -d ' ')"
        \\if [ "$count" -ne 3 ]; then
        \\  echo "test-release-html-smoke: FAIL - expected 3 published HTML pages, found $count:"
        \\  find dist -name '*.html' | sort
        \\  exit 1
        \\fi
        \\for page in dist/index.html dist/guides/install.html dist/guides/paths.html; do
        \\  test -s "$page" || { echo "test-release-html-smoke: FAIL - $page missing or empty"; exit 1; }
        \\done
        \\grep -q '<main data-boris-search-root>' dist/index.html ||
        \\  { echo "test-release-html-smoke: FAIL - no search root in dist/index.html"; exit 1; }
        \\
        \\index="dist/_boris/search/search-index.json"
        \\test -s "$index" || { echo "test-release-html-smoke: FAIL - $index missing or empty"; exit 1; }
        \\grep -q '"fragment": "home"' "$index" ||
        \\  { echo "test-release-html-smoke: FAIL - h1 section absent from $index"; exit 1; }
        \\grep -q '"heading": "Quick start"' "$index" ||
        \\  { echo "test-release-html-smoke: FAIL - h2 section absent from $index"; exit 1; }
        \\if grep -q '"heading": ""' "$index"; then
        \\  echo "test-release-html-smoke: FAIL - empty leading section survived into $index"
        \\  exit 1
        \\fi
        \\
        \\echo "test-release-html-smoke: ok - $mode, $count pages, search index intact."
        ,
        "test-release-html-smoke",
        @tagName(optimize),
    });
    release_html_smoke_run.setCwd(b.path("."));
    release_html_smoke_run.has_side_effects = true;
    release_html_smoke_run.step.dependOn(b.getInstallStep());
    const test_release_html_smoke_step = b.step(
        "test-release-html-smoke",
        "Publish a small site with the release binary (needs -Doptimize=ReleaseSafe)",
    );
    test_release_html_smoke_step.dependOn(&release_html_smoke_run.step);

    // GitHub Pages public/evidence artifact boundary: the public tree is
    // copied only from the exact committed Boris inventory records.
    const github_pages_artifact_run = b.addSystemCommand(&.{
        "bash",
        "scripts/test-github-pages-artifact.sh",
    });
    github_pages_artifact_run.setCwd(b.path("."));
    github_pages_artifact_run.has_side_effects = true;
    const test_github_pages_artifact_step = b.step(
        "test-github-pages-artifact",
        "Run the GitHub Pages public/evidence artifact boundary test",
    );
    test_github_pages_artifact_step.dependOn(&github_pages_artifact_run.step);

    const invariants_mod = b.createModule(.{
        .root_source_file = b.path("src/artifact_invariants.zig"),
        .target = target,
        .optimize = optimize,
    });
    const invariants_tests = b.addTest(.{ .root_module = invariants_mod });
    const run_invariants_tests = b.addRunArtifact(invariants_tests);
    run_invariants_tests.setCwd(b.path("."));

    const emitter_discipline_mod = b.createModule(.{
        .root_source_file = b.path("src/emitter_discipline_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const emitter_discipline_tests = b.addTest(.{ .root_module = emitter_discipline_mod });
    const run_emitter_discipline_tests = b.addRunArtifact(emitter_discipline_tests);
    run_emitter_discipline_tests.setCwd(b.path("."));

    const emitter_hostile_mod = b.createModule(.{
        .root_source_file = b.path("src/emitter_hostile_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkOliver(emitter_hostile_mod, oliver_mod);
    const emitter_hostile_tests = b.addTest(.{ .root_module = emitter_hostile_mod });
    const run_emitter_hostile_tests = b.addRunArtifact(emitter_hostile_tests);
    run_emitter_hostile_tests.setCwd(b.path("."));

    const emitter_registry = b.addSystemCommand(&.{ "bash", "scripts/emitter-discipline.sh" });
    emitter_registry.setCwd(b.path("."));
    emitter_registry.has_side_effects = true;

    const test_emitter_step = b.step(
        "test-emitter-discipline",
        "Prove machine-facing emitters cannot bypass the output encoder",
    );
    test_emitter_step.dependOn(&run_encode_tests.step);
    test_emitter_step.dependOn(&run_structured_out_tests.step);
    test_emitter_step.dependOn(&run_sitemap_tests.step);
    test_emitter_step.dependOn(&run_invariants_tests.step);
    test_emitter_step.dependOn(&run_emitter_discipline_tests.step);
    test_emitter_step.dependOn(&run_emitter_hostile_tests.step);
    test_emitter_step.dependOn(&emitter_registry.step);

    // --- Standalone content audit tool (not product pipeline) -------------
    // `boris-content-audit` is a separate binary under its own build.zig.
    // It is deliberately NOT part of `zig build test`; these are the explicit
    // root-level aggregate commands for building and testing it.
    const content_audit_build = b.addSystemCommand(&.{
        "zig",
        "build",
        "--build-file",
        "tools/content-audit/build.zig",
    });
    content_audit_build.setCwd(b.path("."));
    content_audit_build.has_side_effects = true;
    const content_audit_step = b.step(
        "content-audit",
        "Build the standalone boris-content-audit tool",
    );
    content_audit_step.dependOn(&content_audit_build.step);

    const content_audit_test = b.addSystemCommand(&.{
        "zig",
        "build",
        "--build-file",
        "tools/content-audit/build.zig",
        "test",
    });
    content_audit_test.setCwd(b.path("."));
    content_audit_test.has_side_effects = true;
    const test_content_audit_step = b.step(
        "test-content-audit",
        "Run boris-content-audit unit + fixture tests",
    );
    test_content_audit_step.dependOn(&content_audit_test.step);

    // --- Standalone GitHub Pages deployment observer -----------------------
    // The observer is intentionally outside the product CLI. Its tests are
    // included in the root aggregate so the workflow-facing safety boundary
    // cannot silently drift from the ordinary baseline gate.
    const github_pages_audit_test = b.addSystemCommand(&.{
        "zig",
        "build",
        "--build-file",
        "tools/github-pages-audit/build.zig",
        "test",
    });
    github_pages_audit_test.setCwd(b.path("."));
    github_pages_audit_test.has_side_effects = true;
    const test_github_pages_audit_step = b.step(
        "test-github-pages-audit",
        "Run bounded GitHub Pages deployment observer fixture tests",
    );
    test_github_pages_audit_step.dependOn(&github_pages_audit_test.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(test_atproto_oauth);
    test_step.dependOn(test_atproto_discovery);
    test_step.dependOn(test_atproto_handles);
    test_step.dependOn(test_atproto_authorization);
    test_step.dependOn(test_atproto_xrpc);
    test_step.dependOn(test_atproto_password_step);
    test_step.dependOn(&run_standard_site_tests.step);
    test_step.dependOn(&run_standard_site_emit_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_fixtures_tests.step);
    test_step.dependOn(&run_scanner_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_textile_tests.step);
    test_step.dependOn(&run_cooklang_tests.step);
    test_step.dependOn(&cooklang_incremental_run.step);
    test_step.dependOn(&init_run.step);
    test_step.dependOn(&reference_theme_run.step);
    test_step.dependOn(&version_pin_run.step);
    test_step.dependOn(&run_pipeline_tests.step);
    test_step.dependOn(&run_publication_profile_tests.step);
    test_step.dependOn(&run_github_pages_tests.step);
    test_step.dependOn(&github_pages_artifact_run.step);
    test_step.dependOn(&run_publication_plan_tests.step);
    test_step.dependOn(&run_nostr_tests.step);
    test_step.dependOn(&run_nostr_plan_tests.step);
    test_step.dependOn(&run_doctor_tests.step);
    test_step.dependOn(&run_publication_checks_tests.step);
    test_step.dependOn(&run_publication_claims_tests.step);
    test_step.dependOn(&run_publication_touches_tests.step);
    // Both roots already ran incidentally, because several aggregate members
    // import them and `zig test` runs every test in the root module's import
    // graph. Incidental coverage is not attributable coverage: a failure was
    // reported against an unrelated suite, and it disappears the moment an
    // importer drops the import. Depend on the named steps directly.
    test_step.dependOn(&run_publication_proof_pack_tests.step);
    test_step.dependOn(&run_artifact_inventory_tests.step);
    // Seeded-fixture publication harnesses: they launch the installed binary
    // against a deterministic poisoned fixture, covering the evidence chain end
    // to end rather than at unit scope.
    test_step.dependOn(&run_publication_fixture_tests.step);
    test_step.dependOn(&run_publication_claims_fixture_tests.step);
    test_step.dependOn(&run_publication_touches_fixture_tests.step);
    test_step.dependOn(&run_publication_proof_pack_fixture_tests.step);
    test_step.dependOn(&run_graph_tests.step);
    test_step.dependOn(&run_aside_tests.step);
    test_step.dependOn(&run_rag_tests.step);
    test_step.dependOn(&run_render_tests.step);
    test_step.dependOn(&run_assemble_tests.step);
    test_step.dependOn(&run_theme_tests.step);
    test_step.dependOn(&run_content_asset_tests.step);
    test_step.dependOn(&run_svg_policy_tests.step);
    test_step.dependOn(&run_layout_select_tests.step);
    test_step.dependOn(&run_compile_tests.step);
    test_step.dependOn(&run_hardening_tests.step);
    test_step.dependOn(&run_ir_schema_tests.step);
    test_step.dependOn(&run_layout_hostile_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
    test_step.dependOn(&run_source_rag_tests.step);
    test_step.dependOn(&run_package_tests.step);
    test_step.dependOn(&run_dependency_tests.step);
    test_step.dependOn(&run_intelligence_tests.step);
    test_step.dependOn(&run_cache_tests.step);
    test_step.dependOn(&run_include_tests.step);
    test_step.dependOn(&run_wikilink_tests.step);
    test_step.dependOn(&run_unicode_policy_tests.step);
    test_step.dependOn(&run_site_url_tests.step);
    test_step.dependOn(&run_sitemap_tests.step);
    test_step.dependOn(&run_encode_tests.step);
    test_step.dependOn(&run_structured_out_tests.step);
    test_step.dependOn(&run_invariants_tests.step);
    test_step.dependOn(&run_emitter_discipline_tests.step);
    test_step.dependOn(&run_emitter_hostile_tests.step);
    test_step.dependOn(&emitter_registry.step);
    test_step.dependOn(&doc_links_run.step);
    test_step.dependOn(&github_pages_audit_test.step);
    test_step.dependOn(&xhtml_evidence_run.step);

    const test_harness_step = b.step(
        "test-harness",
        "Run hardening integration tests (alias subset of zig build test)",
    );
    test_harness_step.dependOn(&run_hardening_tests.step);
}

/// Give a module access to the Oliver library import. Every module that
/// transitively imports `src/render.zig` needs "oliver" in its import table,
/// because a relative `@import("render.zig")` resolves in the importing
/// module's context. Oliver is a pure Zig library: no libc, no host tools, no
/// global state, nothing to pre-build.
fn linkOliver(mod: *std.Build.Module, oliver: *std.Build.Module) void {
    mod.addImport("oliver", oliver);
}
