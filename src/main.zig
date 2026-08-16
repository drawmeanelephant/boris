//! Boris — product CLI entry (HTML default + IR + optional RAG).
//!
//! Typed flag parsing + exit-code model. Default mode builds an HTML site
//! under `dist/` (Oliver + Whiteboard + layout splice). IR mode (`--out` /
//! `--no-rag`) runs the content compiler pipeline (scan → parse → PageDb →
//! graph validate → deterministic JSON IR). RAG mode reuses `pipeline.compile`
//! + exports a deterministic corpus.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cli = @import("cli.zig");
const diagnostic = @import("diagnostic.zig");
const diag = @import("diag.zig");
const html_report = @import("html_report.zig");
const pipeline = @import("pipeline.zig");
const rag = @import("rag.zig");
const context = @import("context.zig");
const llms = @import("llms.zig");
const rss = @import("rss.zig");
const compile = @import("compile.zig");
const target = @import("target.zig");
const theme_mod = @import("theme.zig");
const intelligence = @import("intelligence.zig");
const json_out = @import("json_out.zig");
const publication_profile = @import("publication_profile.zig");
const publication_plan = @import("publication_plan.zig");
const nostr_plan = @import("nostr_plan.zig");
const nostr_sign = @import("nostr_sign.zig");
const nostr_publish = @import("nostr_publish.zig");
const init_mod = @import("init.zig");
const timings = @import("timings.zig");
const identity = @import("identity.zig");
const standard_site = @import("standard_site.zig");
const standard_site_emit = @import("standard_site_emit.zig");
const nostr_emit = @import("nostr_emit.zig");
const standard_site_reconcile = @import("standard_site_reconcile.zig");
const standard_site_publish = @import("standard_site_publish.zig");
const html_body = @import("html_body.zig");
const source_io = @import("source_io.zig");
const atproto_authorization = @import("atproto_authorization.zig");
const atproto_dns_std = @import("atproto_dns_std.zig");
const atproto_handle = @import("atproto_handle.zig");
const atproto_identity = @import("atproto_identity.zig");
const atproto_password = @import("atproto_password.zig");
const atproto_transport = @import("atproto_transport.zig");
const atproto_transport_std = @import("atproto_transport_std.zig");
const atproto_interactive_std = @import("atproto_interactive_std.zig");
const atproto_session_std = @import("atproto_session_std.zig");
const standard_site_smoke = @import("standard_site_smoke.zig");
const recipe_scale = @import("recipe_scale.zig");
const recipe_scale_view = @import("recipe_scale_view.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const Options = cli.Options;
pub const Mode = cli.Mode;
pub const parseOptions = cli.parseOptions;

const default_out = ".boris";
const default_rag = "rag";
const default_html = "dist";
const default_layout = "themes/boris/layouts/main.html";

/// Production runner: help text + IR / RAG / HTML pipelines.
const ProdRunner = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Process environment map (for HOME-based session roots).
    environ: *std.process.Environ.Map,

    pub fn printHelp(_: *const @This()) void {
        cli.printUsage();
    }

    /// Print the compiler version to stdout. Errors are swallowed: the
    /// version is informational and must never change the exit code.
    pub fn printVersion(self: *const @This()) void {
        const bytes = pipeline.compiler_id ++ "\n";
        var stdout_buffer: [128]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
        stdout_writer.interface.writeAll(bytes) catch return;
        stdout_writer.interface.flush() catch {};
    }

    pub fn reportUsage(_: *const @This(), err: cli.ParseError, bad_arg: ?[]const u8) void {
        cli.printParseError(err, bad_arg);
        switch (err) {
            error.MissingStandardSiteSubcommand,
            error.UnknownStandardSiteSubcommand,
            error.MissingStandardSiteProfile,
            error.MissingStandardSiteIdentity,
            error.ConflictingStandardSiteFlags,
            => cli.printStandardSiteUsage(),
            else => cli.printUsage(),
        }
    }

    pub fn run(self: *const @This(), opts: Options) ExitCode {
        return runPipelineWithReport(self.io, self.gpa, opts, self.environ);
    }
};

/// Map path validation errors (collisions, escapes, symlinks, empty dirs) to usage (exit code 2).
/// The diagnostic prints unconditionally: `--quiet` silences progress and
/// success output, never the reason for a nonzero exit.
fn mapPathError(err: anyerror) ?ExitCode {
    switch (err) {
        error.EmptyTargetDirectory,
        error.TargetOutputCollision,
        error.TargetOutputSymlink,
        error.WorkspaceEscape,
        => {
            std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
            return .usage;
        },
        else => return null,
    }
}

/// Map pipeline result to process exit code.
///
/// - validation / content errors → 1
/// - usage errors are handled before this (exit 2)
/// - I/O / system errors → 3
///
/// Runs without printing the `--timings` report: tests call this so the
/// machine-readable JSON never touches the process stdout (which is the test
/// runner's protocol channel under `zig build test`). The CLI entry point
/// uses `runPipelineWithReport` for the identical behavior plus the report.
pub fn runPipeline(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    return runPipelineTimed(io, gpa, opts, false, null).code;
}

/// CLI entry point: like `runPipeline`, but also emits the `--timings` JSON
/// report to stdout after the run finishes.
pub fn runPipelineWithReport(io: Io, gpa: std.mem.Allocator, opts: Options, environ: *std.process.Environ.Map) ExitCode {
    return runPipelineTimed(io, gpa, opts, true, environ).code;
}

fn runPipelineTimed(io: Io, gpa: std.mem.Allocator, opts: Options, print_report: bool, environ: ?*std.process.Environ.Map) struct { code: ExitCode } {
    var recorder: ?timings.Recorder = null;
    if (opts.timings) recorder = timings.Recorder.init(io);
    const recorder_ptr: ?*timings.Recorder = if (recorder) |*r| r else null;
    defer {
        if (recorder) |*r| {
            r.stopAll();
            if (print_report) {
                const label: []const u8 = switch (opts.command) {
                    .validate, .check, .impact, .plan, .nostr_plan => @tagName(opts.command),
                    else => @tagName(opts.mode),
                };
                printTimingsReport(io, gpa, r, label) catch {};
            }
        }
    }

    const code: ExitCode = if (opts.command == .plan)
        runPublicationPlan(io, gpa, opts, recorder_ptr)
    else if (opts.command == .standard_site)
        switch (opts.standard_site_command) {
            .publish => runStandardSitePublish(io, gpa, opts, environ orelse return .{ .code = .session }),
            .plan => runStandardSitePlan(io, gpa, opts),
            .records => runStandardSiteRecords(io, gpa, opts),
            .verify => runStandardSiteVerify(io, gpa, opts),
            .login => runStandardSiteLogin(io, gpa, opts, environ orelse return .{ .code = .session }),
            .sessions => runStandardSiteSessions(io, gpa, opts, environ orelse return .{ .code = .session }),
            .logout => runStandardSiteLogout(io, gpa, opts, environ orelse return .{ .code = .session }),
            .smoke => runStandardSiteSmoke(io, gpa, opts, environ orelse return .{ .code = .session }),
        }
    else if (opts.command == .nostr_plan)
        runNostrPlan(io, gpa, opts, recorder_ptr)
    else if (opts.command == .nostr_sign)
        runNostrSign(io, gpa, opts)
    else if (opts.command == .nostr_publish)
        runNostrPublish(io, gpa, opts)
    else if (opts.command == .init)
        runInit(io, gpa, opts)
    else if (opts.command == .recipe_scale)
        runRecipeScale(io, gpa, opts)
    else if (opts.command == .validate)
        runValidate(io, gpa, opts, recorder_ptr)
    else if (opts.command == .check or opts.command == .impact)
        runIntelligence(io, gpa, opts, recorder_ptr)
    else switch (opts.mode) {
        .rag => runRag(io, gpa, opts, recorder_ptr),
        .context => runContext(io, gpa, opts, recorder_ptr),
        .llms => runLlms(io, gpa, opts, recorder_ptr),
        .rss => runRss(io, gpa, opts, recorder_ptr),
        .html => runHtml(io, gpa, opts, recorder_ptr),
        .ir => s: {
            break :s runPipelineIr(io, gpa, opts, recorder_ptr);
        },
    };

    return .{ .code = code };
}

fn runPipelineIr(io: Io, gpa: std.mem.Allocator, opts: Options, recorder_ptr: ?*timings.Recorder) ExitCode {
    const out_dir = opts.out_dir orelse default_out;

    var result = pipeline.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = out_dir,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .timings = recorder_ptr,
    }) catch |err| {
        if (mapPathError(err)) |code| return code;
        std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (result.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items, opts.quiet) catch {
            return .io_error;
        };
    }

    if (result.ok) {
        if (!opts.quiet) {
            std.debug.print("ok: wrote IR under {s} ({d} page(s))\n", .{ out_dir, result.pages.items.len });
        }
        return .success;
    }

    return switch (result.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Write the `--timings` JSON report to stdout. Errors are swallowed: the
/// report is observational and must never change the exit code or artifacts.
fn printTimingsReport(io: Io, gpa: std.mem.Allocator, recorder: *const timings.Recorder, label: []const u8) !void {
    const bytes = try recorder.renderJson(gpa, label);
    defer gpa.free(bytes);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(bytes);
    try stdout_writer.interface.flush();
}

/// Read, normalize, validate, and declare one explicitly selected profile.
/// This path intentionally stops before content discovery or any publisher.
/// Materialize a deterministic starter site into `opts.init_dir` (default ".").
fn findRecipeScalePage(result: *const pipeline.Result, page_id: []const u8) ?*const pipeline.PageEntry {
    for (result.pages.items) |*page| {
        if (std.mem.eql(u8, page.id, page_id)) return page;
    }
    return null;
}

/// Derived Cooklang scale view. Compiles the selected tree, scales one page,
/// and writes JSON to stdout (and `--out` when given). Never rewrites `.cook`
/// or `graph.json`.
pub fn runRecipeScale(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const page_id = opts.recipe_scale_id orelse return .usage;

    var result = pipeline.compile(io, gpa, .{
        .content_root = opts.input_dir,
        .quiet = true,
        .input_format = opts.input_format,
    }) catch |err| {
        std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (!result.ok) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items, opts.quiet) catch return .io_error;
        return switch (result.failure) {
            .io => .io_error,
            .content, .none => .content_error,
        };
    }

    const page = findRecipeScalePage(&result, page_id) orelse {
        std.debug.print("error: recipe page not found: {s}\n", .{page_id});
        return .content_error;
    };

    var servings_view: ?recipe_scale_view.ServingsScale = null;
    const factor = if (opts.recipe_scale_factor) |factor_text|
        recipe_scale.parseFactor(factor_text) catch return .usage
    else blk: {
        const target_count = recipe_scale.parseServingsTarget(opts.recipe_scale_servings orelse return .usage) catch return .usage;
        const current = if (page.servings) |s| s.count else 1;
        const authored = if (page.servings) |s| s.authored else null;
        servings_view = .{ .current = current, .target = target_count, .authored = authored };
        break :blk recipe_scale.factorFromServings(current, target_count) catch return .usage;
    };

    const bytes = recipe_scale_view.renderFromCompile(gpa, &result, page_id, factor, servings_view) catch |err| switch (err) {
        error.PageNotFound => {
            std.debug.print("error: recipe page not found: {s}\n", .{page_id});
            return .content_error;
        },
        error.AmountOverflow => {
            std.debug.print("error: scaled amount overflow for {s}\n", .{page_id});
            return .content_error;
        },
        else => {
            std.debug.print("error: unable to render scaled view: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(bytes);

    if (opts.recipe_scale_out) |path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
            std.debug.print("error: failed to write scaled view {s}: {s}\n", .{ path, @errorName(err) });
            return .io_error;
        };
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout_writer.interface.writeAll(bytes) catch |err| {
        std.debug.print("error: unable to write scaled view: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    stdout_writer.interface.flush() catch |err| {
        std.debug.print("error: unable to flush scaled view: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    return .success;
}

pub fn runInit(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const target_dir = opts.init_dir orelse ".";
    return @enumFromInt(init_mod.run(io, gpa, target_dir, opts.quiet));
}

pub fn runPublicationPlan(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    _ = recorder;
    const profile_path = opts.profile_path orelse return .usage;
    const profile_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        profile_path,
        gpa,
        .limited(publication_profile.max_profile_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return reportPublicationPlanConfigError(error.ProfileTooLarge),
        else => {
            std.debug.print("error: unable to read publication profile: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(profile_bytes);

    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| {
        std.debug.print("error: unable to resolve publication profile workspace: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(cwd_path);

    const workspace = publication_profile.profileWorkspace(gpa, cwd_path, profile_path) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    const profile_input_format: ?publication_profile.InputFormat = if (opts.profile_input_format_override) |format| switch (format) {
        .markdown => .markdown,
        .textile => .textile,
        .cook => .cook,
    } else null;

    var request = publication_profile.parseBytes(gpa, workspace, profile_bytes, .{
        .input = opts.profile_input_override,
        .input_format = profile_input_format,
        .html_output = opts.profile_html_output_override,
        .jobs = opts.jobs,
        .incremental = opts.incremental,
        .quiet = opts.quiet,
    }) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    defer request.deinit(gpa);

    const bytes = publication_plan.render(gpa, &request.plan) catch |err| {
        std.debug.print("error: unable to render publication plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(bytes);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout_writer.interface.writeAll(bytes) catch |err| {
        std.debug.print("error: unable to write publication plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    stdout_writer.interface.flush() catch |err| {
        std.debug.print("error: unable to flush publication plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    return .success;
}

/// Offline Nostr NIP-23 publication plan.
///
/// Shares the profile-reading boundary with `runPublicationPlan`, then compiles
/// the corpus — the one difference that matters, and the reason this is its own
/// command: `plan` declares configuration, while `nostr plan` must know what
/// the content actually says. It still opens no socket and reads no key.
pub fn runNostrPlan(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const profile_path = opts.profile_path orelse return .usage;
    const profile_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        profile_path,
        gpa,
        .limited(publication_profile.max_profile_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return reportPublicationPlanConfigError(error.ProfileTooLarge),
        else => {
            std.debug.print("error: unable to read publication profile: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(profile_bytes);

    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| {
        std.debug.print("error: unable to resolve publication profile workspace: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(cwd_path);

    const workspace = publication_profile.profileWorkspace(gpa, cwd_path, profile_path) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    const profile_input_format: ?publication_profile.InputFormat = if (opts.profile_input_format_override) |format| switch (format) {
        .markdown => .markdown,
        .textile => .textile,
        .cook => .cook,
    } else null;

    var request = publication_profile.parseBytes(gpa, workspace, profile_bytes, .{
        .input = opts.profile_input_override,
        .input_format = profile_input_format,
        .quiet = opts.quiet,
    }) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    defer request.deinit(gpa);

    const config = request.plan.nostr orelse {
        std.debug.print("error: profile declares no nostr section\n", .{});
        return .usage;
    };
    if (!config.enabled) {
        std.debug.print("error: nostr publication is disabled in this profile (set nostr.enabled)\n", .{});
        return .usage;
    }
    const publication = request.plan.publication orelse {
        // validatePlan already refuses this pairing; keep the runner honest
        // rather than unwrapping a null on a future profile path.
        std.debug.print("error: nostr publication requires a publication location\n", .{});
        return .usage;
    };

    var result = nostr_plan.run(io, gpa, .{
        .content_root = request.plan.input,
        .input_format = switch (request.plan.input_format) {
            .markdown => .markdown,
            .textile => .textile,
            .cook => .cook,
        },
        .quiet = opts.quiet,
        .location = &publication.github_pages,
        .pubkey = config.pubkey,
        .articles = config.articles,
        .relays = config.relays,
        .timeout_ms = config.timeout_ms,
        .retries = config.retries,
        .timings = recorder,
    }) catch |err| switch (err) {
        error.InvalidPubkey, error.InvalidNostrConfig, error.AbsolutePath => {
            std.debug.print("error: invalid nostr configuration: {s}\n", .{@errorName(err)});
            return .usage;
        },
        else => {
            if (mapPathError(err)) |code| return code;
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer result.deinit();

    if (result.compile.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.compile.diagnostics.items, opts.quiet) catch return .io_error;
    }
    const bytes = result.plan orelse return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout_writer.interface.writeAll(bytes) catch |err| {
        std.debug.print("error: unable to write nostr publication plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    stdout_writer.interface.flush() catch |err| {
        std.debug.print("error: unable to flush nostr publication plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    return .success;
}

fn reportPublicationPlanConfigError(err: anyerror) ExitCode {
    std.debug.print("error: invalid publication profile: {s}\n", .{@errorName(err)});
    return switch (err) {
        error.OutOfMemory => .io_error,
        else => .usage,
    };
}

/// Maximum committed Standard.site plan artifact bytes (the plan embeds
/// metadata, never payloads; 16 MiB is far beyond any projected site).
const max_standard_site_plan_bytes: usize = 16 * 1024 * 1024;

/// Deterministic exit classification for the one-shot publish command:
/// usage (2), content (1), network/system (3), denial (4), timeout (5),
/// compatibility (6), partial publication (7), verification (8).
fn classifyPublishError(err: anyerror) ExitCode {
    return switch (err) {
        // Binding / security failures: zero writes, evidence never emitted.
        error.PlanDrift,
        error.PlanDigestMismatch,
        error.SessionDidMismatch,
        error.SessionPdsMismatch,
        error.PdsOriginMismatch,
        error.CollectionMismatch,
        error.RkeyMismatch,
        error.PruneWithoutAuthority,
        error.CallbackMalformed,
        error.StateMismatch,
        error.InvalidIssuer,
        => .verification,
        error.AuthorizationDenied => .denial,
        error.Timeout => .timeout,
        // Persistent-session layer: nothing was published; the operator
        // re-authorizes with `standard-site login`.
        error.NoSession,
        error.SessionRevoked,
        error.RefreshAmbiguous,
        error.SessionAuthorityChanged,
        error.HomeUnavailable,
        error.InvalidSessionWire,
        error.InvalidKeySeed,
        error.StoreCorrupt,
        error.WrongDocumentType,
        error.StoreExists,
        error.StoreFull,
        error.StoreIo,
        error.StoreLocked,
        error.StoreNotFound,
        error.StorePermissionDenied,
        error.StoreUnexpected,
        => .session,
        // Localhost-client / grant compatibility.
        error.InvalidClientId,
        error.InvalidLoopbackRedirect,
        error.InvalidGrant,
        error.InvalidScope,
        error.InvalidTokenResponse,
        error.InvalidParResponse,
        error.OAuthRequestFailed,
        error.DpopNonceMissing,
        error.DpopNonceRepeated,
        error.InvalidContentType,
        => .compatibility,
        // Everything else is a network, system, or host failure.
        else => .io_error,
    };
}

fn reportPublishError(err: anyerror) ExitCode {
    const code = classifyPublishError(err);
    const message: []const u8 = switch (err) {
        error.PdsOriginMismatch => "profile pds does not match the discovered PDS — copy the origin login printed, not https://bsky.social; nothing was published",
        else => switch (code) {
            .verification => "verification failed; nothing was published (binding or plan mismatch)",
            .denial => "authorization was denied in the browser; nothing was published",
            .timeout => "timed out waiting for the authorization callback",
            .compatibility => "authorization server rejected the localhost client or grant",
            .partial_publication => "some records failed; the evidence records exactly what landed",
            .session => "session layer failure: no stored session, revoked/ambiguous refresh, or authority change — run `boris standard-site login --did <DID>`",
            else => @errorName(err),
        },
    };
    std.debug.print("error: standard-site publish: {s}\n", .{message});
    return code;
}

/// Report a persistent-session failure (login/sessions/logout/publish session
/// acquisition) with a human explanation and exit code 9. Secrets are never
/// part of the message.
fn reportSessionError(err: anyerror) ExitCode {
    const message: []const u8 = switch (err) {
        error.HomeUnavailable => "unable to locate a session root: set HOME or pass --session-root",
        error.NoSession => "no session is stored for this DID",
        error.SessionRevoked => "the stored session was revoked; run `boris standard-site login --did <DID>`",
        error.RefreshAmbiguous => "session refresh was interrupted and may have rotated; the stored session was removed — run `boris standard-site login --did <DID>`",
        error.SessionAuthorityChanged => "the stored session's authority no longer matches fresh discovery; run `boris standard-site login --did <DID>`",
        error.InvalidSessionWire, error.InvalidKeySeed, error.StoreCorrupt => "the stored session document is corrupt; run `boris standard-site logout --did <DID>` then log in again",
        error.WrongDocumentType => "the stored session document is the other credential type; run `boris standard-site logout --did <DID>` then log in again",
        error.StorePermissionDenied => "the session store is not readable/writable; check permissions on the session root",
        error.StoreLocked => "the session store is locked by another process",
        else => @errorName(err),
    };
    std.debug.print("error: standard-site session: {s}\n", .{message});
    return .session;
}

/// Resolve the persistent session root from `--session-root` or HOME.
fn resolveSessionRoot(gpa: std.mem.Allocator, environ: *std.process.Environ.Map, opts: Options) atproto_session_std.Error![]u8 {
    return atproto_session_std.Sessions.userRoot(gpa, environ.*, opts.session_root);
}

/// Provides the session for a publish/smoke run. The persistent store wins:
/// a stored session — OAuth first (the primary path), then app-password — is
/// loaded and refreshed without the browser. Only when no session exists does
/// the provider run the interactive one-shot OAuth flow, and it immediately
/// persists the result so future publishes skip the browser.
const SessionProvider = struct {
    sessions: *atproto_session_std.Sessions,
    proof_source: atproto_interactive_std.NativeProofSource,
    quiet: bool,

    fn provide(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        client: atproto_transport.Client,
        account: atproto_identity.DiscoveredAccount,
    ) standard_site_publish.Error!standard_site_publish.AcquiredSession {
        const self: *SessionProvider = @ptrCast(@alignCast(ctx));
        const now_seconds = standard_site_publish.wallClockSeconds(io);
        if (now_seconds < 0) return error.InvalidWallClock;
        const now: u64 = @intCast(now_seconds);

        // OAuth is the default and primary path.
        if (self.sessions.acquire(account.did.slice(), client, self.proof_source.source(), now)) |session| {
            return .{ .oauth = session };
        } else |err| switch (err) {
            // Nothing stored, or the stored document is the app-password
            // sibling. Genuine corruption fails closed and must not open
            // the browser or overwrite the file.
            error.NoSession, error.WrongDocumentType => {},
            else => return err,
        }

        // A stored app-password session (never a fallback inside the OAuth
        // flow; a distinct, separately-stored credential).
        if (self.sessions.acquirePassword(account.did.slice(), client, now)) |session| {
            return .{ .app_password = session };
        } else |err| switch (err) {
            error.NoSession => {}, // fall through to the interactive flow
            else => return err,
        }

        var session = try atproto_interactive_std.authorize(allocator, io, client, account);
        session.markObtained(now);
        errdefer session.deinit();
        try self.sessions.storeNew(account.did.slice(), &session);
        if (!self.quiet) {
            std.debug.print("standard-site: saved a persistent session for {s}; future publishes will not open the browser\n", .{account.did.slice()});
        }
        return .{ .oauth = session };
    }
};

/// `boris standard-site login --did DID [--session-root PATH]`
///
/// Resolve the DID, run the interactive one-shot OAuth flow in the browser,
/// and persist the DPoP-bound session (tokens and key seed, 0600, atomic
/// replace) under the user-scoped session root. Never prints token material.
pub fn runStandardSiteLogin(io: Io, gpa: std.mem.Allocator, opts: Options, environ: *std.process.Environ.Map) ExitCode {
    if (opts.app_password) return runStandardSiteLoginAppPassword(io, gpa, opts, environ);
    const did_text = opts.session_did orelse return .usage;
    const root = resolveSessionRoot(gpa, environ, opts) catch |err| return reportSessionError(err);
    defer gpa.free(root);
    const transport_std = atproto_transport_std.StdTransport.create(gpa, io) catch |err| {
        std.debug.print("error: unable to start the ATProto transport: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer transport_std.destroy();

    const account = atproto_identity.discover(gpa, transport_std.client(), did_text) catch |err| {
        std.debug.print("error: unable to resolve identity {s}: {s}\n", .{ did_text, @errorName(err) });
        return .io_error;
    };
    var session = atproto_interactive_std.authorize(gpa, io, transport_std.client(), account) catch |err| {
        return reportPublishError(err);
    };
    defer session.deinit();
    const now_seconds = standard_site_publish.wallClockSeconds(io);
    if (now_seconds < 0) return reportSessionError(error.InvalidWallClock);
    session.markObtained(@intCast(now_seconds));

    var sessions = atproto_session_std.Sessions.open(gpa, io, root) catch |err| return reportSessionError(err);
    defer sessions.deinit();
    sessions.storeNew(account.did.slice(), &session) catch |err| return reportSessionError(err);
    if (!opts.quiet) {
        std.debug.print("standard-site: signed in {s} (PDS {s}); session stored securely\n", .{ account.did.slice(), account.pds_origin.slice() });
    }
    return .success;
}

/// Upper bound on an app password read from stdin. ATProto app passwords are
/// short (`xxxx-xxxx-xxxx-xxxx`); the bound exists only to fail closed on a
/// hostile or accidental oversized input.
const max_app_password_bytes = 1024;

/// `boris standard-site login --app-password (--did DID | --handle HANDLE)`
///
/// Resolve the identity to a DID + PDS origin, disclose the broad write access
/// this path grants, read the app password from stdin (never argv/env/profile),
/// authenticate with `com.atproto.server.createSession`, and persist the
/// Bearer session under the shared store root. The credential and both JWTs
/// never appear in diagnostics, logs, evidence, or the human summary.
pub fn runStandardSiteLoginAppPassword(io: Io, gpa: std.mem.Allocator, opts: Options, environ: *std.process.Environ.Map) ExitCode {
    const transport_std = atproto_transport_std.StdTransport.create(gpa, io) catch |err| {
        std.debug.print("error: unable to start the ATProto transport: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer transport_std.destroy();

    var did: atproto_identity.Did = undefined;
    var pds_origin: atproto_identity.Origin = undefined;
    resolveAppPasswordIdentity(gpa, io, opts, transport_std.client(), &did, &pds_origin) catch |err| {
        return reportAppPasswordLoginError(err);
    };

    // Disclosed before prompting, and never suppressed: this is the security
    // boundary the operator opts into, not progress chatter.
    std.debug.print("standard-site: --app-password grants broad account write access to {s} on {s} (not just the Standard.site scope). Revoke it under App Passwords in your provider's account settings.\n", .{ did.slice(), pds_origin.slice() });

    const app_password = readAppPasswordFromStdin(gpa, io) catch |err| {
        return reportAppPasswordLoginError(err);
    };
    defer {
        std.crypto.secureZero(u8, app_password);
        gpa.free(app_password);
    }

    var session = atproto_password.createSession(gpa, transport_std.client(), pds_origin, did, app_password) catch |err| {
        return reportAppPasswordLoginError(err);
    };
    defer session.deinit();
    const now_seconds = standard_site_publish.wallClockSeconds(io);
    if (now_seconds < 0) return reportSessionError(error.InvalidWallClock);
    session.markObtained(@intCast(now_seconds));

    const root = resolveSessionRoot(gpa, environ, opts) catch |err| return reportSessionError(err);
    defer gpa.free(root);
    var sessions = atproto_session_std.Sessions.open(gpa, io, root) catch |err| return reportSessionError(err);
    defer sessions.deinit();
    sessions.storeNewPassword(did.slice(), &session) catch |err| return reportSessionError(err);
    if (!opts.quiet) {
        std.debug.print("standard-site: signed in {s} (PDS {s}) with an app password; session stored securely\n", .{ did.slice(), pds_origin.slice() });
    }
    return .success;
}

/// Resolve a user-supplied handle through DNS/HTTPS and require the DID
/// document's `alsoKnownAs` backlink. Stops at the DID document so the
/// app-password path never depends on OAuth authorization-server metadata.
fn resolveVerifiedHandleDocument(
    gpa: std.mem.Allocator,
    io: Io,
    client: atproto_transport.Client,
    handle_text: []const u8,
) !atproto_identity.DidDocument {
    var dns = atproto_dns_std.StdDns.init(io) catch |err| return err;
    const resolved = try atproto_handle.resolve(gpa, dns.client(), client, handle_text);
    const document = try atproto_identity.resolveDidDocument(gpa, client, resolved.did);
    try atproto_identity.requireHandleBacklink(document, resolved.handle);
    return document;
}

/// Resolve the login identity (`--did` or `--handle`) to a DID + PDS origin.
/// The app-password path deliberately stops at the DID document — it never
/// requires the OAuth authorization-server metadata that the interactive flow
/// needs. A handle still requires the bidirectional `alsoKnownAs` backlink.
fn resolveAppPasswordIdentity(
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    client: atproto_transport.Client,
    did: *atproto_identity.Did,
    pds_origin: *atproto_identity.Origin,
) !void {
    if (opts.session_did) |text| {
        did.* = try atproto_identity.Did.parse(text);
        const document = try atproto_identity.resolveDidDocument(gpa, client, did.*);
        pds_origin.* = document.pds_origin;
        return;
    }
    const handle_text = opts.session_handle orelse return error.InvalidDid;
    const document = try resolveVerifiedHandleDocument(gpa, io, client, handle_text);
    did.* = document.did;
    pds_origin.* = document.pds_origin;
}

/// Resolve `--did` or `--handle` to an owned DID string for smoke (and any
/// other command that accepts either identity form). Handle resolution
/// requires the same `alsoKnownAs` backlink as app-password login.
fn resolveConfiguredDid(
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    client: atproto_transport.Client,
) ![]u8 {
    if (opts.session_did) |text| {
        const did = try atproto_identity.Did.parse(text);
        return gpa.dupe(u8, did.slice());
    }
    const handle_text = opts.session_handle orelse return error.InvalidDid;
    const document = try resolveVerifiedHandleDocument(gpa, io, client, handle_text);
    return gpa.dupe(u8, document.did.slice());
}

/// Disable terminal echo on the controlling stdin while a secret is typed,
/// restoring the original attributes afterwards (including on error paths).
/// Best-effort and strictly scoped to interactive terminals: when stdin is
/// not a TTY (e.g. a piped secret file) or the platform has no termios
/// support, the guard is inactive and reading proceeds unchanged. A hard
/// SIGINT mid-prompt is left to the shell's job-control reset, as with most
/// CLI tools.
const EchoGuard = struct {
    active: bool = false,
    original: std.posix.termios = undefined,

    fn init() EchoGuard {
        // The ATProto transport already restricts this command to macOS and
        // Linux; those are also the targets with usable termios here.
        if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return .{};
        const original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return .{};
        var muted = original;
        muted.lflag.ECHO = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, muted) catch return .{};
        return .{ .active = true, .original = original };
    }

    fn deinit(self: *EchoGuard) void {
        if (!self.active) return;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, self.original) catch {};
        self.active = false;
    }
};

/// Read the app password from stdin: one line on an interactive terminal
/// (echo suppressed), or up to EOF on a pipe/file. The first newline (or end
/// of stream) ends the credential, and empty input is rejected. The caller
/// zeroes and frees the returned slice.
fn readAppPasswordFromStdin(gpa: std.mem.Allocator, io: Io) ![]u8 {
    var echo = EchoGuard.init();
    defer echo.deinit();
    if (echo.active) std.debug.print("Password: ", .{});

    var buffer: [max_app_password_bytes]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    defer std.crypto.secureZero(u8, &buffer);
    return readAppPasswordLine(gpa, &reader.interface);
}

/// Extract one credential from `reader`, up to (but excluding) the first
/// newline or end of stream, rejecting empty input. A trailing carriage
/// return is trimmed so both Unix and legacy CRLF terminals work. The
/// returned slice is owned; the caller zeroes and frees it.
fn readAppPasswordLine(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const raw = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.EmptyPassword,
        error.StreamTooLong => return error.ResponseTooLarge,
        else => return err,
    };
    var end = raw.len;
    if (end > 0 and raw[end - 1] == '\r') end -= 1;
    if (end == 0) return error.EmptyPassword;
    return gpa.dupe(u8, raw[0..end]);
}

/// Map an app-password login failure to a coarse exit code and a human,
/// secret-free message.
fn reportAppPasswordLoginError(err: anyerror) ExitCode {
    const code: ExitCode = switch (err) {
        error.EmptyPassword => .usage,
        error.AuthenticationFailed => .denial,
        error.Timeout => .timeout,
        error.InvalidDid, error.InvalidHandle, error.HandleMismatch, error.UnsupportedDidMethod => .usage,
        error.InvalidJwt, error.InvalidResponse, error.InvalidStatus, error.InvalidContentType, error.SubjectDidMismatch => .compatibility,
        error.SessionRevoked, error.InvalidSessionWire, error.StoreCorrupt, error.WrongDocumentType, error.StoreExists, error.StoreFull, error.StoreIo, error.StoreLocked, error.StoreNotFound, error.StorePermissionDenied, error.StoreUnexpected, error.HomeUnavailable => .session,
        else => .io_error,
    };
    const message: []const u8 = switch (err) {
        error.EmptyPassword => "password cannot be empty; nothing was stored",
        error.HandleMismatch => "the DID document does not name this handle in alsoKnownAs; nothing was stored",
        else => switch (code) {
            .denial => "the PDS rejected the app password or identifier; nothing was stored",
            .compatibility => "the PDS returned an unexpected response; nothing was stored",
            .session => "unable to persist the app-password session; check the session root",
            .usage => "invalid AT Protocol identity for --app-password login",
            else => @errorName(err),
        },
    };
    std.debug.print("error: standard-site login --app-password: {s}\n", .{message});
    return code;
}

/// `boris standard-site sessions [--session-root PATH]`
///
/// List stored sessions as `did flavor pds` (one line per DID). Flavor is
/// the closed token `oauth` or `app-password`. No secret material is
/// ever rendered.
pub fn runStandardSiteSessions(io: Io, gpa: std.mem.Allocator, opts: Options, environ: *std.process.Environ.Map) ExitCode {
    const root = resolveSessionRoot(gpa, environ, opts) catch |err| return reportSessionError(err);
    defer gpa.free(root);
    var sessions = atproto_session_std.Sessions.open(gpa, io, root) catch |err| return reportSessionError(err);
    defer sessions.deinit();
    const listed = sessions.listEntries() catch |err| return reportSessionError(err);
    defer sessions.deinitListEntries(listed);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    for (listed) |entry| {
        stdout_writer.interface.print("{s} {s} {s}\n", .{ entry.did, entry.flavor.label(), entry.pds_origin }) catch return .io_error;
    }
    stdout_writer.interface.flush() catch {};
    if (!opts.quiet) {
        std.debug.print("standard-site: {d} stored session{s}\n", .{ listed.len, if (listed.len == 1) "" else "s" });
    }
    return .success;
}

/// `boris standard-site logout (--did DID | --handle HANDLE) [--session-root PATH]`
///
/// Securely erase the stored session for the DID. This only removes the local
/// credential; it never revokes the authorization server session. `--handle`
/// is resolved the same way login resolves it; an unresolvable handle fails
/// closed.
pub fn runStandardSiteLogout(io: Io, gpa: std.mem.Allocator, opts: Options, environ: *std.process.Environ.Map) ExitCode {
    const root = resolveSessionRoot(gpa, environ, opts) catch |err| return reportSessionError(err);
    defer gpa.free(root);

    var owned_did: ?[]u8 = null;
    defer if (owned_did) |bytes| gpa.free(bytes);
    const did_text = if (opts.session_did) |text| text else blk: {
        const transport_std = atproto_transport_std.StdTransport.create(gpa, io) catch |err| {
            std.debug.print("error: unable to start the ATProto transport: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        defer transport_std.destroy();
        const resolved = resolveConfiguredDid(gpa, io, opts, transport_std.client()) catch |err| {
            std.debug.print("error: standard-site logout: unable to resolve handle: {s}\n", .{@errorName(err)});
            return .usage;
        };
        owned_did = resolved;
        break :blk resolved;
    };

    var sessions = atproto_session_std.Sessions.open(gpa, io, root) catch |err| return reportSessionError(err);
    defer sessions.deinit();
    const removed = sessions.remove(did_text) catch |err| return reportSessionError(err);
    if (!opts.quiet) {
        if (removed) {
            std.debug.print("standard-site: removed the stored session for {s}\n", .{did_text});
        } else {
            std.debug.print("standard-site: no stored session for {s}\n", .{did_text});
        }
    }
    return .success;
}

/// Map a smoke command's thrown error to an exit code. The session and OAuth
/// surfaces reuse the publish classifier; the smoke-specific precondition and
/// configuration failures map to verification or usage.
fn classifySmokeError(err: anyerror) ExitCode {
    return switch (err) {
        error.NamespaceCollision => .verification,
        error.InvalidNamespace, error.InvalidSiteUrl, error.InvalidIndexerOrigin => .usage,
        else => classifyPublishError(err),
    };
}

/// Map a completed smoke result to an exit code. The result JSON carries the
/// per-phase detail; the exit code is a coarse signal for scripts.
fn smokeResultExitCode(result: *const standard_site_smoke.SmokeResult) ExitCode {
    if (result.overall_passed) return .success;
    if (result.cleanup_status == .failed) return .partial_publication;
    if (result.publication.status == .failed or result.document.status == .failed) return .partial_publication;
    return .verification;
}

/// `boris standard-site smoke --did DID [--namespace NAME] [--surface-url URL]
/// [--indexer URL] [--out PATH] [--session-root PATH]`
///
/// Manual, opt-in live interoperability gate: resolve the test identity,
/// obtain a session (stored then interactive), create a uniquely namespaced
/// publication + document pair, read both back and verify identity, value, and
/// CID, optionally check the served verification surface and observe an
/// indexer (non-normative), then delete exactly the two created rkeys. The
/// result is machine-readable (`boris-live-smoke-result`). The live path is
/// reachable only through this explicit command; no test or CI step invokes
/// it, and the ordinary offline matrix stays authoritative.
pub fn runStandardSiteSmoke(io: Io, gpa: std.mem.Allocator, opts: Options, environ: *std.process.Environ.Map) ExitCode {
    const session_root = resolveSessionRoot(gpa, environ, opts) catch |err| return reportSessionError(err);
    defer gpa.free(session_root);
    const transport_std = atproto_transport_std.StdTransport.create(gpa, io) catch |err| {
        std.debug.print("error: unable to start the ATProto transport: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer transport_std.destroy();
    const did_owned = resolveConfiguredDid(gpa, io, opts, transport_std.client()) catch |err| {
        std.debug.print("error: standard-site smoke: unable to resolve identity: {s}\n", .{@errorName(err)});
        return .usage;
    };
    defer gpa.free(did_owned);
    const did_text = did_owned;
    var sessions = atproto_session_std.Sessions.open(gpa, io, session_root) catch |err| return reportSessionError(err);
    defer sessions.deinit();
    const stored = sessions.hasDocument(did_text) catch |err| return reportSessionError(err);
    if (!stored) {
        if (opts.session_handle) |handle| {
            std.debug.print("error: standard-site smoke: no stored session — run `boris standard-site login --app-password --handle {s}` first\n", .{handle});
        } else {
            std.debug.print("error: standard-site smoke: no stored session — run `boris standard-site login --app-password --did {s}` first\n", .{did_text});
        }
        return .session;
    }
    var session_provider = SessionProvider{
        .sessions = &sessions,
        .proof_source = .{ .io = io },
        .quiet = opts.quiet,
    };
    const runtime: standard_site_smoke.Runtime = .{
        .io = io,
        .client = transport_std.client(),
        .proofs = session_provider.proof_source.source(),
        .session_ctx = &session_provider,
        .session_fn = SessionProvider.provide,
        .now_fn = standard_site_publish.wallClockSeconds,
    };
    const config: standard_site_smoke.Config = .{
        .did = did_text,
        .namespace = opts.smoke_namespace,
        .site_url = opts.smoke_surface_url,
        .indexer_origin = opts.smoke_indexer_origin,
        .boris_pin = pipeline.compiler_id,
        .oliver_pin = standard_site_publish.oliver_pin,
    };

    var result = standard_site_smoke.smoke(gpa, &runtime, &config) catch |err| {
        const code = classifySmokeError(err);
        std.debug.print("error: standard-site smoke: {s}\n", .{@errorName(err)});
        return code;
    };
    defer result.deinit(gpa);

    const rendered = standard_site_smoke.renderResult(gpa, &result) catch |err| {
        std.debug.print("error: unable to render the smoke result: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(rendered);

    if (opts.smoke_out) |out_path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = rendered }) catch |err| {
            std.debug.print("error: unable to write the smoke result: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    } else {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        stdout_writer.interface.writeAll(rendered) catch |err| {
            std.debug.print("error: unable to write the smoke result: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        stdout_writer.interface.flush() catch |err| {
            std.debug.print("error: unable to flush the smoke result: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    }

    if (!opts.quiet) {
        const summary = standard_site_smoke.renderHumanSummary(gpa, &result) catch |err| {
            std.debug.print("error: unable to render the smoke summary: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        defer gpa.free(summary);
        std.debug.print("{s}", .{summary});
    }

    return smokeResultExitCode(&result);
}

/// Owned result of the shared offline projection: the parsed profile (which
/// owns the Standard.site target config) plus the deterministic record
/// projection. `targetConfig()` re-derives the pointer into the owned request.
const StandardSiteProjection = struct {
    request: publication_profile.PublicationRequest,
    projection: standard_site.Projection,

    fn targetConfig(self: *StandardSiteProjection) *standard_site.TargetConfig {
        return &self.request.plan.publication.?.standard_site;
    }

    fn deinit(self: *StandardSiteProjection, gpa: std.mem.Allocator) void {
        self.projection.deinit(gpa);
        self.request.deinit(gpa);
    }
};

/// Shared post-projection step: compute the verification surfaces and take
/// ownership; the caller frees them with `deinitVerificationSurfaces`.
fn buildStandardSiteSurfaces(
    gpa: std.mem.Allocator,
    target_config: *standard_site.TargetConfig,
    projection: *const standard_site.Projection,
    out: *standard_site.VerificationSurfaces,
) ExitCode {
    out.* = standard_site.verificationSurfaces(gpa, target_config, projection) catch |err| {
        std.debug.print("error: unable to compute verification surfaces: {s}\n", .{@errorName(err)});
        return .content_error;
    };
    return .success;
}

/// HTML-build verification bundle. Pointers in `vctx` alias `proj`/`surfaces`
/// and are valid only while this struct lives.
const HtmlVerification = struct {
    proj: StandardSiteProjection,
    surfaces: standard_site.VerificationSurfaces,
    vctx: standard_site_emit.VerificationContext,

    fn deinit(self: *HtmlVerification, gpa: std.mem.Allocator) void {
        deinitVerificationSurfaces(gpa, &self.surfaces);
        self.proj.deinit(gpa);
    }
};

/// Owns the publication profile so the Nostr head config's slices stay alive
/// for the HTML compile.
const HtmlNostr = struct {
    request: publication_profile.PublicationRequest,
    config: nostr_emit.HeadConfig,

    fn deinit(self: *HtmlNostr, gpa: std.mem.Allocator) void {
        self.request.deinit(gpa);
    }
};

/// When `--profile` names a Standard.site target, build the offline
/// projection and surfaces so the HTML compile can emit verification
/// artifacts. A missing profile, or a GitHub Pages profile, is a no-op.
fn loadHtmlVerification(
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    out: *?HtmlVerification,
) ExitCode {
    const profile_path = opts.profile_path orelse return .success;
    const profile_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        profile_path,
        gpa,
        .limited(publication_profile.max_profile_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return reportPublicationPlanConfigError(error.ProfileTooLarge),
        else => {
            std.debug.print("error: unable to read publication profile: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(profile_bytes);

    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| {
        std.debug.print("error: unable to resolve publication profile workspace: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(cwd_path);
    const workspace = publication_profile.profileWorkspace(gpa, cwd_path, profile_path) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    var request = publication_profile.parseBytes(gpa, workspace, profile_bytes, .{
        .jobs = opts.jobs,
        .incremental = opts.incremental,
        .quiet = opts.quiet,
    }) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    defer request.deinit(gpa);

    const publication = request.plan.publication orelse return .success;
    switch (publication) {
        .standard_site => {},
        .github_pages => return .success,
    }

    var proj: StandardSiteProjection = undefined;
    const code = buildStandardSiteProjection(io, gpa, opts, &proj);
    if (code != .success) return code;
    var surfaces: standard_site.VerificationSurfaces = undefined;
    const surf_code = buildStandardSiteSurfaces(gpa, proj.targetConfig(), &proj.projection, &surfaces);
    if (surf_code != .success) {
        proj.deinit(gpa);
        return surf_code;
    }
    out.* = .{
        .proj = proj,
        .surfaces = surfaces,
        .vctx = undefined,
    };
    if (out.*) |*bundle| {
        bundle.vctx = .{
            .surfaces = &bundle.surfaces,
            .projection = &bundle.proj.projection,
        };
    }
    return .success;
}

/// When `--profile` names an enabled `nostr` section, keep the parsed
/// profile so HTML compile can emit `nostr:naddr` alternate links. A
/// missing profile, or a disabled/absent section, is a no-op.
fn loadHtmlNostr(
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    out: *?HtmlNostr,
) ExitCode {
    const profile_path = opts.profile_path orelse return .success;
    const profile_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        profile_path,
        gpa,
        .limited(publication_profile.max_profile_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return reportPublicationPlanConfigError(error.ProfileTooLarge),
        else => {
            std.debug.print("error: unable to read publication profile: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(profile_bytes);

    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| {
        std.debug.print("error: unable to resolve publication profile workspace: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(cwd_path);
    const workspace = publication_profile.profileWorkspace(gpa, cwd_path, profile_path) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    var request = publication_profile.parseBytes(gpa, workspace, profile_bytes, .{
        .jobs = opts.jobs,
        .incremental = opts.incremental,
        .quiet = opts.quiet,
    }) catch |err| {
        return reportPublicationPlanConfigError(err);
    };

    const nostr_cfg = request.plan.nostr orelse {
        request.deinit(gpa);
        return .success;
    };
    if (!nostr_cfg.enabled) {
        request.deinit(gpa);
        return .success;
    }

    out.* = .{
        .request = request,
        .config = .{
            .pubkey = nostr_cfg.pubkey,
            .articles = nostr_cfg.articles,
            .relays = nostr_cfg.relays,
        },
    };
    return .success;
}

fn deinitVerificationSurfaces(gpa: std.mem.Allocator, surfaces: *standard_site.VerificationSurfaces) void {
    gpa.free(surfaces.well_known.content);
    if (surfaces.well_known.project_path) |path| gpa.free(path);
    gpa.free(surfaces.well_known.required_public_url);
    for (surfaces.document_links) |link| {
        gpa.free(link.page);
        gpa.free(link.href);
    }
    gpa.free(surfaces.document_links);
}

/// Shared offline prefix for the `standard-site` plan/records/publish commands:
/// read and validate the profile, compile the content tree, and build the
/// deterministic record projection (including the per-page plain-text
/// `textContent` projection). Ownership of `request` and `projection` transfers
/// to `out` on success; every failure prints its diagnostic and returns the
/// matching exit code.
fn buildStandardSiteProjection(io: Io, gpa: std.mem.Allocator, opts: Options, out: *StandardSiteProjection) ExitCode {
    const profile_path = opts.profile_path orelse return .usage;
    const profile_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        profile_path,
        gpa,
        .limited(publication_profile.max_profile_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return reportPublicationPlanConfigError(error.ProfileTooLarge),
        else => {
            std.debug.print("error: unable to read publication profile: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(profile_bytes);

    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| {
        std.debug.print("error: unable to resolve publication profile workspace: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(cwd_path);

    const workspace = publication_profile.profileWorkspace(gpa, cwd_path, profile_path) catch |err| {
        return reportPublicationPlanConfigError(err);
    };

    var request = publication_profile.parseBytes(gpa, workspace, profile_bytes, .{
        .jobs = opts.jobs,
        .incremental = opts.incremental,
        .quiet = opts.quiet,
    }) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    var transferred = false;
    defer if (!transferred) request.deinit(gpa);

    const target_config = switch (request.plan.publication orelse return reportPublicationPlanConfigError(error.InvalidPublication)) {
        .standard_site => |*config| config,
        .github_pages => {
            std.debug.print("error: profile targets github-pages; standard-site commands require a standard-site profile\n", .{});
            return .usage;
        },
    };

    // Resolve the profile-relative content root and compile the page set with
    // full validation (duplicate ids, topology, encoding) before any output.
    const content_root = std.fs.path.resolve(gpa, &.{ request.workspace.root, request.plan.input }) catch |err| {
        std.debug.print("error: unable to resolve content root: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(content_root);

    const input_format: identity.InputFormat = switch (request.plan.input_format) {
        .markdown => identity.InputFormat.markdown,
        .textile => identity.InputFormat.textile,
        .cook => identity.InputFormat.cook,
    };
    var result = pipeline.compile(io, gpa, .{
        .content_root = content_root,
        .quiet = opts.quiet,
        .input_format = input_format,
    }) catch |err| {
        std.debug.print("error: unable to compile content: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (!result.ok) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items, opts.quiet) catch {
            return .io_error;
        };
        return switch (result.failure) {
            .io => .io_error,
            .content, .none => .content_error,
        };
    }

    // Map the compiled page set onto the projection input shape. Output paths
    // are derived from the final entity ids exactly as the scanner does, so
    // the plan's `path` claims match the committed site.
    var input_arena = std.heap.ArenaAllocator.init(gpa);
    defer input_arena.deinit();
    const arena = input_arena.allocator();
    var content_dir = Io.Dir.cwd().openDir(io, content_root, .{}) catch |err| {
        std.debug.print("error: unable to open the content root for the plain-text projection: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer content_dir.close(io);
    var page_inputs: std.ArrayList(standard_site.PageInput) = .empty;
    defer page_inputs.deinit(gpa);
    for (result.pages.items) |node| {
        const output_path = identity.safeOutputRelativePath(arena, node.id) catch |err| {
            std.debug.print("error: unable to derive page output path: {s}\n", .{@errorName(err)});
            return .content_error;
        };
        // Deterministic semantic plain-text projection (#480). Populate the
        // record's `textContent` only when it renders cleanly and stays within
        // the record bound; otherwise omit it — never substitute raw source or
        // rendered HTML for the projection.
        const text_content: ?[]const u8 = blk: {
            const source = source_io.readPageAlloc(io, content_dir, node.source_path, gpa) catch break :blk null;
            defer gpa.free(source);
            const text = html_body.renderSourcePlainText(io, gpa, content_dir, &input_arena, source, node.source_path, output_path, .{
                .input_format = input_format,
                .nodes = result.pages.items,
            }) catch break :blk null;
            if (text.len == 0 or text.len > standard_site.max_text_content_bytes) break :blk null;
            break :blk text;
        };
        page_inputs.append(gpa, .{
            .entity_id = node.id,
            .output_path = output_path,
            .title = node.title,
            .status = standardSiteStatus(node.status),
            .published_at = node.published_at,
            .summary = node.summary,
            .tags = node.tags,
            .text_content = text_content,
        }) catch |err| {
            std.debug.print("error: unable to build page projection: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    }

    var projection = standard_site.project(gpa, .{
        .config = target_config,
        .site_title = if (request.plan.site) |site| site.title else null,
        .pages = page_inputs.items,
    }) catch |err| {
        std.debug.print("error: unable to project the Standard.site plan: {s}\n", .{@errorName(err)});
        return .content_error;
    };
    defer if (!transferred) projection.deinit(gpa);

    out.* = .{ .request = request, .projection = projection };
    transferred = true;
    return .success;
}

/// `boris standard-site plan --profile PATH [--out PATH]`
///
/// Pure-offline projection: read and validate the profile, compile the content
/// tree, render the deterministic Standard.site plan (publication + document
/// records, `textContent`, exclusions, and verification surfaces), and write it
/// to `--out` or stdout. No discovery, OAuth, transport, or mutation — this is
/// the "inspect exactly what publish will do" surface, and it never reaches the
/// network code path shared with `publish`.
pub fn runStandardSitePlan(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    var proj: StandardSiteProjection = undefined;
    const code = buildStandardSiteProjection(io, gpa, opts, &proj);
    if (code != .success) return code;
    defer proj.deinit(gpa);
    const target_config = proj.targetConfig();
    const projection = &proj.projection;

    var surfaces: standard_site.VerificationSurfaces = undefined;
    const surf_code = buildStandardSiteSurfaces(gpa, target_config, projection, &surfaces);
    if (surf_code != .success) return surf_code;
    defer deinitVerificationSurfaces(gpa, &surfaces);

    const plan = standard_site.renderPlan(gpa, target_config, projection, &surfaces) catch |err| {
        std.debug.print("error: unable to render the Standard.site plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(plan);

    if (opts.plan_out) |out_path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = plan }) catch |err| {
            std.debug.print("error: unable to write the Standard.site plan: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    } else {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        stdout_writer.interface.writeAll(plan) catch |err| {
            std.debug.print("error: unable to write the Standard.site plan: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        stdout_writer.interface.flush() catch |err| {
            std.debug.print("error: unable to flush the Standard.site plan: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    }
    return .success;
}

/// `boris standard-site records --profile PATH [--out PATH]`
///
/// Pure-offline record dump: run the same compile + projection pipeline as
/// `plan`/`publish`, then render the full canonical record payloads (the
/// publication plus every eligible document, including each document's complete
/// `textContent`) for byte-level review. No discovery, OAuth, transport, or
/// mutation — the bytes are exactly what `publish` would PUT.
pub fn runStandardSiteRecords(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    var proj: StandardSiteProjection = undefined;
    const code = buildStandardSiteProjection(io, gpa, opts, &proj);
    if (code != .success) return code;
    defer proj.deinit(gpa);
    const projection = &proj.projection;

    const records = standard_site.renderRecords(gpa, projection) catch |err| {
        std.debug.print("error: unable to render the Standard.site records: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(records);

    if (opts.records_out) |out_path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = records }) catch |err| {
            std.debug.print("error: unable to write the Standard.site records: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    } else {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        stdout_writer.interface.writeAll(records) catch |err| {
            std.debug.print("error: unable to write the Standard.site records: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        stdout_writer.interface.flush() catch |err| {
            std.debug.print("error: unable to flush the Standard.site records: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    }
    return .success;
}

/// `boris standard-site verify --profile PATH [--dist DIR] [--out PATH]`
///
/// Pure-offline post-build cross-check: render the projection + verification
/// surfaces, then compare the already-emitted artifacts in the built output
/// directory — each eligible page's document head link and the well-known file
/// (or its base-path sideband) — against them byte-for-byte. Any missing or
/// mismatched surface is a verification failure (exit 8) with zero writes and
/// zero network.
pub fn runStandardSiteVerify(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    var proj: StandardSiteProjection = undefined;
    const code = buildStandardSiteProjection(io, gpa, opts, &proj);
    if (code != .success) return code;
    defer proj.deinit(gpa);
    const target_config = proj.targetConfig();
    const projection = &proj.projection;

    var surfaces: standard_site.VerificationSurfaces = undefined;
    const surf_code = buildStandardSiteSurfaces(gpa, target_config, projection, &surfaces);
    if (surf_code != .success) return surf_code;
    defer deinitVerificationSurfaces(gpa, &surfaces);

    var dist_dir = Io.Dir.cwd().openDir(io, opts.verify_dist, .{}) catch |err| {
        std.debug.print("error: unable to open the built output directory `{s}` for verification: {s}\n", .{ opts.verify_dist, @errorName(err) });
        return .io_error;
    };
    defer dist_dir.close(io);

    // Well-known (root site) or sideband (base-path) byte cross-check.
    const w = &surfaces.well_known;
    const checked_path: []const u8 = if (w.emittable) w.project_path.? else standard_site_emit.sideband_output_path;
    var well_known_status: standard_site_emit.VerifyWellKnownStatus = .missing;
    {
        const actual = dist_dir.readFileAlloc(io, checked_path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                std.debug.print("error: unable to read the well-known surface for verification: {s}\n", .{@errorName(err)});
                return .io_error;
            },
        };
        defer if (actual) |bytes| gpa.free(bytes);
        well_known_status = standard_site_emit.checkWellKnown(w.content, actual);
    }
    var overall_passed = well_known_status == .match;

    // Per-document head-link cross-check against the emitted HTML.
    var doc_results: std.ArrayList(standard_site_emit.VerifyDocumentResult) = .empty;
    defer doc_results.deinit(gpa);
    for (projection.documents) |document| {
        const output_path = document.path[1..]; // strip the leading '/'
        var status: standard_site_emit.VerifyDocumentStatus = .missing;
        {
            const html = dist_dir.readFileAlloc(io, output_path, gpa, .unlimited) catch |err| switch (err) {
                error.FileNotFound => null,
                else => {
                    std.debug.print("error: unable to read the built page `{s}` for verification: {s}\n", .{ output_path, @errorName(err) });
                    return .io_error;
                },
            };
            defer if (html) |bytes| gpa.free(bytes);
            if (html) |bytes| status = standard_site_emit.checkDocument(document.at_uri, bytes);
        }
        if (status != .verified) overall_passed = false;
        doc_results.append(gpa, .{
            .entity_id = document.entity_id,
            .at_uri = document.at_uri,
            .status = status,
        }) catch |err| {
            std.debug.print("error: unable to build the verification result: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    }

    const result_bytes = standard_site_emit.renderVerify(gpa, .{
        .status = well_known_status,
        .checked_path = checked_path,
        .required_public_url = w.required_public_url,
    }, doc_results.items) catch |err| {
        std.debug.print("error: unable to render the verification result: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(result_bytes);

    if (opts.verify_out) |out_path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = result_bytes }) catch |err| {
            std.debug.print("error: unable to write the verification result: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    } else {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        stdout_writer.interface.writeAll(result_bytes) catch |err| {
            std.debug.print("error: unable to write the verification result: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        stdout_writer.interface.flush() catch |err| {
            std.debug.print("error: unable to flush the verification result: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    }

    if (!overall_passed) {
        std.debug.print("error: standard-site verify: the built output does not match the projection (see the result artifact)\n", .{});
        return .verification;
    }
    return .success;
}

/// `boris standard-site publish --profile PATH [--plan PATH] [--out PATH] [--prune]`
///
/// One-shot publish: read and validate the profile, compile the content tree,
/// render the deterministic Standard.site plan, verify the committed plan
/// (when given) byte-for-byte, then discover → authorize → reconcile with the
/// in-memory session. Evidence goes to `--out` or stdout; the human summary
/// goes to stderr; the exit code classifies usage, content, network/system,
/// denial, timeout, compatibility, partial-publication, and verification
/// failures. No build/validate/watch/plan path ever reaches this network code.
pub fn runStandardSitePublish(io: Io, gpa: std.mem.Allocator, opts: Options, environ: *std.process.Environ.Map) ExitCode {
    var proj: StandardSiteProjection = undefined;
    const code = buildStandardSiteProjection(io, gpa, opts, &proj);
    if (code != .success) return code;
    defer proj.deinit(gpa);
    const target_config = proj.targetConfig();
    const projection = &proj.projection;

    var surfaces: standard_site.VerificationSurfaces = undefined;
    const surf_code = buildStandardSiteSurfaces(gpa, target_config, projection, &surfaces);
    if (surf_code != .success) return surf_code;
    defer deinitVerificationSurfaces(gpa, &surfaces);

    const rendered_plan = standard_site.renderPlan(gpa, target_config, projection, &surfaces) catch |err| {
        std.debug.print("error: unable to render the Standard.site plan: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(rendered_plan);

    // Committed-plan gate: when `--plan` is given, the committed artifact must
    // match the freshly rendered plan byte-for-byte before any network.
    var plan_bytes: []const u8 = rendered_plan;
    var plan_digest: [64]u8 = standard_site_reconcile.sha256HexLower(rendered_plan);
    if (opts.plan_path) |plan_path| {
        const committed = Io.Dir.cwd().readFileAlloc(io, plan_path, gpa, .limited(max_standard_site_plan_bytes + 1)) catch |err| {
            std.debug.print("error: unable to read the committed Standard.site plan: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        defer gpa.free(committed);
        standard_site_publish.validatePlanMatches(rendered_plan, committed) catch {
            std.debug.print("error: standard-site publish: committed plan does not match the freshly rendered plan (PlanDrift); re-render and review before publishing\n", .{});
            return .verification;
        };
        plan_bytes = committed;
        plan_digest = standard_site_reconcile.sha256HexLower(committed);
    }

    // Host capabilities: bounded HTTPS transport, native DPoP proofs, the
    // persistent session store, and the wall clock. The session provider
    // reuses a stored session (refreshing when needed) and only opens the
    // browser when no stored session exists.
    const transport_std = atproto_transport_std.StdTransport.create(gpa, io) catch |err| {
        std.debug.print("error: unable to start the ATProto transport: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer transport_std.destroy();
    const session_root = resolveSessionRoot(gpa, environ, opts) catch |err| return reportSessionError(err);
    defer gpa.free(session_root);
    var sessions = atproto_session_std.Sessions.open(gpa, io, session_root) catch |err| return reportSessionError(err);
    defer sessions.deinit();
    var session_provider = SessionProvider{
        .sessions = &sessions,
        .proof_source = .{ .io = io },
        .quiet = opts.quiet,
    };
    const runtime: standard_site_publish.Runtime = .{
        .io = io,
        .client = transport_std.client(),
        .proofs = session_provider.proof_source.source(),
        .session_ctx = &session_provider,
        .session_fn = SessionProvider.provide,
        .now_fn = standard_site_publish.wallClockSeconds,
    };

    const prune = opts.publish_prune and target_config.prune;
    const bindings = standard_site_reconcile.Bindings{
        .source_commit = opts.source_commit orelse "unknown",
        .boris_pin = pipeline.compiler_id,
        .oliver_pin = standard_site_publish.oliver_pin,
    };

    var evidence = standard_site_publish.publish(
        gpa,
        &runtime,
        target_config,
        projection,
        plan_bytes,
        plan_digest,
        prune,
        bindings,
    ) catch |err| {
        return reportPublishError(err);
    };
    defer evidence.deinit(gpa);

    const evidence_bytes = standard_site_reconcile.renderEvidence(gpa, &evidence) catch |err| {
        std.debug.print("error: unable to render publish evidence: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(evidence_bytes);

    if (opts.publish_out) |out_path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = evidence_bytes }) catch |err| {
            std.debug.print("error: unable to write publish evidence: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    } else {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        stdout_writer.interface.writeAll(evidence_bytes) catch |err| {
            std.debug.print("error: unable to write publish evidence: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        stdout_writer.interface.flush() catch |err| {
            std.debug.print("error: unable to flush publish evidence: {s}\n", .{@errorName(err)});
            return .io_error;
        };
    }

    if (!opts.quiet) {
        const summary = standard_site_publish.renderHumanSummary(gpa, &evidence) catch |err| {
            std.debug.print("error: unable to render the publish summary: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        defer gpa.free(summary);
        std.debug.print("{s}", .{summary});
    }

    if (!evidence.overall_passed) {
        std.debug.print("error: standard-site publish: some records failed; the evidence records exactly what landed\n", .{});
        return .partial_publication;
    }
    return .success;
}

fn standardSiteStatus(text: ?[]const u8) standard_site.Status {
    if (text) |value| {
        if (std.mem.eql(u8, value, "published")) return .published;
        if (std.mem.eql(u8, value, "archived")) return .archived;
        if (std.mem.eql(u8, value, "draft")) return .draft;
    }
    return .none;
}

/// Offline Nostr NIP-23 signing: `boris nostr sign`.
///
/// Reads the plan artifact, reads the secret key exactly once from stdin
/// (64 hex digits or a NIP-19 `nsec`), signs every article, and writes the
/// signed-event bundle to `--out` or stdout. It opens no socket, contacts no
/// relay, and never publishes. The secret never enters argv, the profile, the
/// environment, diagnostics, or any artifact.
pub fn runNostrSign(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const plan_path = opts.nostr_plan_path orelse return .usage;
    const plan_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        plan_path,
        gpa,
        .limited(nostr_sign.max_plan_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => {
            std.debug.print("error: plan artifact exceeds the {d}-byte bound\n", .{nostr_sign.max_plan_bytes});
            return .usage;
        },
        else => {
            std.debug.print("error: unable to read the plan artifact: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(plan_bytes);

    var prior_owned: ?[]u8 = null;
    defer if (prior_owned) |prior| gpa.free(prior);
    if (opts.nostr_prior_path) |prior_path| {
        prior_owned = Io.Dir.cwd().readFileAlloc(
            io,
            prior_path,
            gpa,
            .limited(nostr_sign.max_plan_bytes + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                std.debug.print("error: prior signed bundle exceeds the {d}-byte bound\n", .{nostr_sign.max_plan_bytes});
                return .usage;
            },
            else => {
                std.debug.print("error: unable to read the prior signed bundle: {s}\n", .{@errorName(err)});
                return .io_error;
            },
        };
    }

    // The secret key is read once from stdin, bounded, and zeroed best-effort
    // after use. The trim accepts surrounding whitespace; an empty line is a
    // refusal, never a silent empty key.
    var stdin_buffer: [nostr_sign.max_secret_bytes + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &stdin_buffer);
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const raw_key = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            std.debug.print("error: secret key on stdin exceeds the {d}-byte bound\n", .{nostr_sign.max_secret_bytes});
            return .usage;
        },
        error.ReadFailed => {
            std.debug.print("error: unable to read the secret key from stdin\n", .{});
            return .io_error;
        },
    };
    const key = std.mem.trim(u8, raw_key orelse "", " \t\r\n");
    if (key.len == 0) {
        std.debug.print("error: empty secret key on stdin (pipe hex or nsec; never argv, profile, or environment)\n", .{});
        return .usage;
    }

    var result = nostr_sign.run(io, gpa, .{
        .plan = plan_bytes,
        .key = key,
        .created_at = opts.nostr_created_at,
        .prior = prior_owned,
    }) catch |err| {
        std.debug.print("error: signing failed: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (result.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items, opts.quiet) catch return .io_error;
    }

    const bundle = result.bundle orelse return .content_error;

    if (opts.nostr_out_path) |out_path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = bundle }) catch |err| {
            std.debug.print("error: unable to write the signed-event bundle: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        if (!opts.quiet) {
            std.debug.print("ok: wrote signed-event bundle to {s}\n", .{out_path});
        }
        return .success;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout_writer.interface.writeAll(bundle) catch |err| {
        std.debug.print("error: unable to write the signed-event bundle: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    stdout_writer.interface.flush() catch |err| {
        std.debug.print("error: unable to flush the signed-event bundle: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    if (!opts.quiet) {
        std.debug.print("ok: wrote signed-event bundle to stdout\n", .{});
    }
    return .success;
}

/// Online Nostr publication: `boris nostr publish --plan PLAN --bundle BUNDLE`.
///
/// Reads the plan artifact and its signed-event bundle, verifies the bundle
/// against the plan (digest, expected pubkey, event ids, signatures — nothing
/// is sent before verification), then sends the exact signed events to each
/// configured relay over RFC-6455 WebSocket. Every relay interaction is
/// bounded and produces per-relay evidence; the run always reaches a
/// complete/partial/failed/incomplete verdict, and the canonical report is
/// written to `--out` or stdout. The secret never enters this command.
pub fn runNostrPublish(io: Io, gpa: std.mem.Allocator, opts: Options) ExitCode {
    const plan_path = opts.nostr_plan_path orelse return .usage;
    const bundle_path = opts.nostr_bundle_path orelse return .usage;

    const plan_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        plan_path,
        gpa,
        .limited(nostr_sign.max_plan_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => {
            std.debug.print("error: plan artifact exceeds the {d}-byte bound\n", .{nostr_sign.max_plan_bytes});
            return .usage;
        },
        else => {
            std.debug.print("error: unable to read the plan artifact: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(plan_bytes);

    const bundle_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        bundle_path,
        gpa,
        .limited(nostr_sign.max_plan_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => {
            std.debug.print("error: signed bundle exceeds the {d}-byte bound\n", .{nostr_sign.max_plan_bytes});
            return .usage;
        },
        else => {
            std.debug.print("error: unable to read the signed bundle: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(bundle_bytes);

    var result = nostr_publish.run(io, gpa, .{
        .plan = plan_bytes,
        .bundle = bundle_bytes,
    }) catch |err| {
        std.debug.print("error: publishing failed: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (result.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items, opts.quiet) catch return .io_error;
    }

    const report = result.report orelse return .content_error;

    if (opts.nostr_out_path) |out_path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = report }) catch |err| {
            std.debug.print("error: unable to write the publish report: {s}\n", .{@errorName(err)});
            return .io_error;
        };
        if (!opts.quiet) {
            const label: []const u8 = if (result.classification) |c| c.jsonName() else "?";
            std.debug.print("ok: wrote publish report ({s}) to {s}\n", .{ label, out_path });
        }
        return .success;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout_writer.interface.writeAll(report) catch |err| {
        std.debug.print("error: unable to write the publish report: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    stdout_writer.interface.flush() catch |err| {
        std.debug.print("error: unable to flush the publish report: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    if (!opts.quiet) {
        const label: []const u8 = if (result.classification) |c| c.jsonName() else "?";
        std.debug.print("ok: wrote publish report ({s}) to stdout\n", .{label});
    }
    return .success;
}
/// Deterministic provenance-rich AI context export (same compile + graph validation as IR/RAG).
pub fn runContext(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const context_dir = opts.context_dir orelse "context";

    var result = context.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = context_dir,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .scope = opts.scope,
        .split_size = opts.split_size,
        .timings = recorder,
    }) catch |err| switch (err) {
        error.EmptyTargetDirectory,
        error.TargetOutputCollision,
        error.TargetOutputSymlink,
        error.WorkspaceEscape,
        => {
            std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
            return .usage;
        },
        error.InvalidScope, error.OversizedBlock => {
            std.debug.print("error: export projection failed: {s}\n", .{@errorName(err)});
            return .content_error;
        },
        else => {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer result.deinit();

    if (result.compile.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.compile.diagnostics.items, opts.quiet) catch {
            return .io_error;
        };
    }

    if (result.ok()) {
        if (!opts.quiet) {
            // The full validated graph count (may exceed the selected page
            // set under `--scope`); the bundle log labels the selected count
            // (#406).
            std.debug.print("ok: wrote context bundle under {s} ({d} graph page(s))\n", .{ context_dir, result.compile.pages.items.len });
        }
        return .success;
    }

    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Deterministic community `llms.txt` export using the shared validated graph.
pub fn runLlms(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const out_path = opts.llms_path orelse "llms.txt";
    var result = llms.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_path = out_path,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .publication_location = if (opts.publication_location) |*location| location else null,
        .timings = recorder,
    }) catch |err| {
        if (mapPathError(err)) |code| return code;
        std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();
    if (result.compile.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.compile.diagnostics.items, opts.quiet) catch return .io_error;
    }
    if (result.ok()) {
        if (!opts.quiet) std.debug.print("ok: wrote llms.txt under {s} ({d} page(s))\n", .{ out_path, result.compile.pages.items.len });
        return .success;
    }
    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Deterministic RSS 2.0 export using the shared validated graph.
pub fn runRss(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const out_path = opts.rss_path orelse "rss.xml";
    var result = rss.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_path = out_path,
        .site_url = opts.site_url orelse return .usage,
        .title = opts.rss_title orelse return .usage,
        .description = opts.rss_description orelse return .usage,
        .limit = opts.rss_limit,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .publication_location = if (opts.publication_location) |*location| location else null,
        .timings = recorder,
    }) catch |err| {
        if (mapPathError(err)) |code| return code;
        switch (err) {
            error.InvalidSiteUrl, error.InvalidLimit, error.AbsolutePath => {
                std.debug.print("error: invalid RSS configuration: {s}\n", .{@errorName(err)});
                return .usage;
            },
            error.PublicationLocationMismatch => {
                std.debug.print("error: RSS publication URL does not match the declared Pages location\n", .{});
                return .content_error;
            },
            error.InvalidXml => {
                std.debug.print("error: RSS projection validation failed: {s}\n", .{@errorName(err)});
                return .content_error;
            },
            else => {
                std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
                return .io_error;
            },
        }
    };
    defer result.deinit();
    if (result.compile.diagnostics.items.len > 0) {
        pipeline.printDiagnostics(gpa, result.compile.diagnostics.items, opts.quiet) catch return .io_error;
    }
    if (result.ok()) {
        if (!opts.quiet) std.debug.print("ok: wrote RSS 2.0 feed to {s} ({d} page(s))\n", .{ out_path, result.compile.pages.items.len });
        return .success;
    }
    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// Read-only graph analysis. This intentionally calls pipeline.compile rather
/// than pipeline.run, so no IR/RAG/HTML artifacts or cache manifests publish.
pub fn runIntelligence(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    var result = pipeline.compile(io, gpa, .{
        .content_root = opts.input_dir,
        .quiet = true,
        .input_format = opts.input_format,
        .timings = recorder,
    }) catch |err| {
        std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer result.deinit();

    if (!result.ok) {
        pipeline.printDiagnostics(gpa, result.diagnostics.items, opts.quiet) catch return .io_error;
        return switch (result.failure) {
            .io => .io_error,
            .content, .none => .content_error,
        };
    }

    var pages: std.ArrayListUnmanaged(intelligence.Page) = .empty;
    defer pages.deinit(gpa);
    pages.ensureTotalCapacity(gpa, result.pages.items.len) catch return .io_error;
    for (result.pages.items) |page| {
        pages.appendAssumeCapacity(.{ .id = page.id, .parent = page.parent });
    }

    var edges: std.ArrayListUnmanaged(intelligence.Edge) = .empty;
    defer edges.deinit(gpa);
    edges.ensureTotalCapacity(gpa, result.edges.items.len) catch return .io_error;
    for (result.edges.items) |edge| {
        edges.appendAssumeCapacity(.{
            .from = .{ .type = @enumFromInt(@intFromEnum(edge.from.type)), .value = edge.from.value },
            .to = .{ .type = @enumFromInt(@intFromEnum(edge.to.type)), .value = edge.to.value },
            .kind = edge.kind,
        });
    }

    var requested: ?intelligence.Endpoint = null;
    if (opts.command == .impact) {
        const id = opts.impact_id orelse return .usage;
        var found = false;
        for (pages.items) |page| {
            if (std.mem.eql(u8, page.id, id)) {
                found = true;
                break;
            }
        }
        if (found) {
            requested = .{ .type = .page, .value = id };
        } else {
            // Source endpoints are not page records, but they are part of
            // the frozen dependency graph and are valid impact roots.
            for (result.edges.items) |edge| {
                const matches_source =
                    (edge.from.type == .source and std.mem.eql(u8, edge.from.value, id)) or
                    (edge.to.type == .source and std.mem.eql(u8, edge.to.value, id));
                if (matches_source) {
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            std.debug.print("error: impact target not found: {s}\n", .{id});
            return .usage;
        }
        if (requested == null) requested = .{ .type = .source, .value = id };
    }

    var report = intelligence.analyze(gpa, pages.items, edges.items, .{ .impact = requested }) catch |err| {
        std.debug.print("error: analysis failed: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer report.deinit();

    const rendered = if (opts.analysis_format == .json)
        renderAnalysisJson(gpa, opts, result.pages.items, result.edges.items, &report) catch return .io_error
    else
        renderAnalysisHuman(gpa, opts, result.pages.items, &report) catch return .io_error;
    defer gpa.free(rendered);

    if (opts.analysis_report) |path| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rendered }) catch |err| {
            std.debug.print("error: failed to write report {s}: {s}\n", .{ path, @errorName(err) });
            return .io_error;
        };
    } else {
        std.debug.print("{s}", .{rendered});
    }

    // `check` is CI-useful by default: unreferenced pages are findings.
    // Unreferenced pages are ordinary findings by default; the check-only flag
    // opts into treating them as a content failure.
    if (opts.command == .check and opts.fail_on_unreferenced and report.summary.unreferenced_pages > 0) {
        return .content_error;
    }
    return .success;
}

/// Authoritative no-publication HTML source/target validation.
///
/// This enters the same in-process compiler coordinator as a normal HTML build
/// and returns at its explicit prepublication boundary. It never invokes a
/// build in a temporary directory and never emits an authority/report file.
pub fn runValidate(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const layout_path = opts.html_layout;
    const out_dir = opts.html_dir orelse default_html;

    var report_collector: ?diag.Collector = null;
    if (opts.report_path != null) report_collector = diag.Collector.init(gpa, io);
    defer if (report_collector) |*c| c.deinit();
    const collector_ptr: ?*diag.Collector = if (report_collector) |*c| c else null;

    compile.validateHtmlSiteMulti(io, gpa, opts.targets.items, .{
        .content_root = opts.input_dir,
        .layout_path = layout_path,
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .sitemap_path = opts.sitemap_path,
        .site_url = opts.site_url,
        .publication_location = if (opts.publication_location) |*location| location else null,
        .allow_markdown_literals = opts.allow_markdown_links,
        .timings = recorder,
        .diagnostics = collector_ptr,
    }) catch |err| {
        const code = mapHtmlError(err, opts.targets.items, layout_path);
        appendEscapedDiagnostic(collector_ptr, err, code);
        writeHtmlReport(io, gpa, opts, collector_ptr, false, out_dir);
        return code;
    };

    if (!opts.quiet) {
        std.debug.print("ok: validation passed for {d} target(s)\n", .{opts.targets.items.len});
    }
    writeHtmlReport(io, gpa, opts, collector_ptr, true, out_dir);
    return .success;
}

/// Append one diagnostic for a compile error that escaped as a bare exit-code
/// mapping (usage / I/O classes), so the machine-readable report still
/// explains the nonzero exit even when the failing phase had no structured
/// diagnostic of its own.
fn appendEscapedDiagnostic(collector: ?*diag.Collector, err: anyerror, code: ExitCode) void {
    if (collector) |c| c.append(.{
        .severity = .error_,
        .code = if (code == .usage) .EUSAGE else .EIO,
        .message = @errorName(err),
        .remediation = "See the stderr diagnostic for the full explanation",
    });
}

/// Write the HTML-path diagnostics report (`--report PATH`) deterministically
/// on success and failure. Never changes the exit code or stderr text.
fn writeHtmlReport(
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    collector: ?*diag.Collector,
    ok: bool,
    out_dir: []const u8,
) void {
    const path = opts.report_path orelse return;
    const c = collector orelse return;
    diag.sortDiagnostics(c.list.items);
    const rendered = html_report.renderHtmlReport(gpa, pipeline.compiler_id, .{
        .ok = ok,
        .content_root = opts.input_dir,
        .out_dir = out_dir,
        .diagnostics = c.list.items,
    }) catch return;
    defer gpa.free(rendered);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rendered }) catch |err| {
        std.debug.print("error: failed to write report {s}: {s}\n", .{ path, @errorName(err) });
    };
}

fn renderAnalysisHuman(
    gpa: std.mem.Allocator,
    opts: Options,
    pages: []const pipeline.PageEntry,
    report: *const intelligence.Report,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendFmt(&out, gpa, "Documentation Intelligence ({s})\n", .{@tagName(opts.command)});
    try appendFmt(&out, gpa, "pages: {d} (roots {d}, satellites {d})\n", .{ report.summary.pages, report.summary.roots, report.summary.satellites });
    try appendFmt(&out, gpa, "source endpoints: {d}\nunreferenced pages: {d}\nhotspots: {d}\n", .{ report.summary.source_endpoints, report.summary.unreferenced_pages, report.summary.hotspots });
    if (opts.command == .impact) {
        try appendFmt(&out, gpa, "impact ({s}):\n", .{opts.impact_id.?});
        for (report.impact.items) |endpoint| try appendFmt(&out, gpa, "  {s}: {s}\n", .{ @tagName(endpoint.type), endpoint.value });
    }
    if (report.findings.items.len > 0) {
        try out.appendSlice(gpa, "findings:\n");
        for (report.findings.items) |finding| {
            try appendFmt(&out, gpa, "  {s}: {s}", .{ @tagName(finding.code), finding.endpoint.value });
            if (finding.count > 0) try appendFmt(&out, gpa, " ({d})", .{finding.count});
            try out.append(gpa, '\n');
        }
    }
    _ = pages;
    return out.toOwnedSlice(gpa);
}

fn appendFmt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const rendered = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(rendered);
    try buf.appendSlice(gpa, rendered);
}

const BufferWriter = struct {
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    pub fn writeAll(self: *@This(), bytes: []const u8) !void {
        try self.buf.appendSlice(self.gpa, bytes);
    }
};

fn renderAnalysisJson(
    gpa: std.mem.Allocator,
    opts: Options,
    pages: []const pipeline.PageEntry,
    edges: []const pipeline.DependencyEdge,
    report: *const intelligence.Report,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var w = BufferWriter{ .buf = &out, .gpa = gpa };
    try w.writeAll("{\n  \"format\": \"boris-documentation-intelligence\",\n  \"schemaVersion\": \"0.2.0\",\n  \"compiler\": ");
    try json_out.writeString(&out, gpa, pipeline.compiler_id);
    try w.writeAll(",\n  \"input\": ");
    try json_out.writeString(&out, gpa, opts.input_dir);
    try w.writeAll(",\n  \"summary\": {\n    \"pages\": ");
    try json_out.writeUsize(&out, gpa, report.summary.pages);
    try w.writeAll(",\n    \"roots\": ");
    try json_out.writeUsize(&out, gpa, report.summary.roots);
    try w.writeAll(",\n    \"satellites\": ");
    try json_out.writeUsize(&out, gpa, report.summary.satellites);
    try w.writeAll(",\n    \"sourceEndpoints\": ");
    try json_out.writeUsize(&out, gpa, report.summary.source_endpoints);
    try w.writeAll(",\n    \"unreferencedPages\": ");
    try json_out.writeUsize(&out, gpa, report.summary.unreferenced_pages);
    try w.writeAll(",\n    \"hotspots\": ");
    try json_out.writeUsize(&out, gpa, report.summary.hotspots);
    try w.writeAll("\n  },\n  \"nodes\": [");
    for (pages, 0..) |page, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"page\",\"id\":");
        try json_out.writeString(&out, gpa, page.id);
        try w.writeAll(",\"sourcePath\":");
        try json_out.writeString(&out, gpa, page.source_path);
        try w.writeAll(",\"parent\":");
        if (page.parent) |parent| try json_out.writeString(&out, gpa, parent) else try json_out.writeNull(&out, gpa);
        try w.writeAll("}");
    }
    try w.writeAll("],\n  \"edges\": [");
    for (edges, 0..) |edge, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"from\":{\"type\":");
        try json_out.writeString(&out, gpa, @tagName(edge.from.type));
        try w.writeAll(",\"value\":");
        try json_out.writeString(&out, gpa, edge.from.value);
        try w.writeAll("},\"to\":{\"type\":");
        try json_out.writeString(&out, gpa, @tagName(edge.to.type));
        try w.writeAll(",\"value\":");
        try json_out.writeString(&out, gpa, edge.to.value);
        try w.writeAll("},\"kind\":");
        try json_out.writeString(&out, gpa, edge.kind);
        try w.writeAll("}");
    }
    try w.writeAll("],\n  \"sourceLocations\": [");
    for (pages, 0..) |page, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"type\":\"page\",\"value\":");
        try json_out.writeString(&out, gpa, page.id);
        try w.writeAll(",\"sourcePath\":");
        try json_out.writeString(&out, gpa, page.source_path);
        try w.writeAll(",\"line\":1,\"column\":1}");
    }
    try w.writeAll("],\n  \"pages\": [");
    for (pages, 0..) |page, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try json_out.writeString(&out, gpa, page.id);
        try w.writeAll(",\"parent\":");
        if (page.parent) |parent| try json_out.writeString(&out, gpa, parent) else try json_out.writeNull(&out, gpa);
        try w.writeAll("}");
    }
    try w.writeAll("],\n  \"sources\": [");
    var source_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer source_names.deinit(gpa);
    for (edges) |edge| {
        if (edge.to.type != .source) continue;
        var exists = false;
        for (source_names.items) |name| {
            if (std.mem.eql(u8, name, edge.to.value)) {
                exists = true;
                break;
            }
        }
        if (!exists) try source_names.append(gpa, edge.to.value);
    }
    std.mem.sort([]const u8, source_names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    for (source_names.items, 0..) |source, i| {
        if (i > 0) try w.writeAll(",");
        try json_out.writeString(&out, gpa, source);
    }
    try w.writeAll("],\n  \"findings\": [");
    for (report.findings.items, 0..) |finding, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"code\":");
        try json_out.writeString(&out, gpa, @tagName(finding.code));
        try w.writeAll(",\"type\":");
        try json_out.writeString(&out, gpa, @tagName(finding.endpoint.type));
        try w.writeAll(",\"value\":");
        try json_out.writeString(&out, gpa, finding.endpoint.value);
        try w.writeAll(",\"count\":");
        try json_out.writeUsize(&out, gpa, finding.count);
        try w.writeAll(",\"sourcePath\":");
        var finding_source: ?[]const u8 = null;
        if (finding.endpoint.type == .page) {
            for (pages) |page| {
                if (std.mem.eql(u8, page.id, finding.endpoint.value)) {
                    finding_source = page.source_path;
                    break;
                }
            }
        }
        if (finding_source) |source| try json_out.writeString(&out, gpa, source) else try json_out.writeNull(&out, gpa);
        try w.writeAll(",\"line\":");
        if (finding_source != null) try json_out.writeUsize(&out, gpa, 1) else try json_out.writeNull(&out, gpa);
        try w.writeAll(",\"column\":");
        if (finding_source != null) try json_out.writeUsize(&out, gpa, 1) else try json_out.writeNull(&out, gpa);
        try w.writeAll("}");
    }
    try w.writeAll("],\n  \"impact\": ");
    if (opts.command == .impact) {
        try w.writeAll("[");
        for (report.impact.items, 0..) |endpoint, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"type\":");
            try json_out.writeString(&out, gpa, @tagName(endpoint.type));
            try w.writeAll(",\"value\":");
            try json_out.writeString(&out, gpa, endpoint.value);
            try w.writeAll("}");
        }
        try w.writeAll("]");
    } else try json_out.writeNull(&out, gpa);
    try w.writeAll(",\n  \"diagnostics\": []\n}\n");
    return out.toOwnedSlice(gpa);
}

/// Optional deterministic RAG export (same compile + graph.validate as IR).
pub fn runRag(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const rag_dir = opts.rag_dir orelse default_rag;

    var result = rag.run(io, gpa, .{
        .content_root = opts.input_dir,
        .out_dir = rag_dir,
        .system_docs_dir = "docs/rag/system",
        .quiet = opts.quiet,
        .input_format = opts.input_format,
        .scope = opts.scope,
        .split_size = opts.split_size,
        .bundles_only = opts.bundles_only,
        .complete = opts.complete,
        .timings = recorder,
    }) catch |err| switch (err) {
        error.EmptyTargetDirectory,
        error.TargetOutputCollision,
        error.TargetOutputSymlink,
        error.WorkspaceEscape,
        => {
            std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
            return .usage;
        },
        error.InvalidScope, error.OversizedBlock, error.SeparatorCollision => {
            std.debug.print("error: export projection failed: {s}\n", .{@errorName(err)});
            return .content_error;
        },
        else => {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer result.deinit();

    if (result.diagnostics().len > 0) {
        pipeline.printDiagnostics(gpa, result.diagnostics(), opts.quiet) catch {
            return .io_error;
        };
    }

    if (result.ok()) {
        if (!opts.quiet) {
            if (result.stats.complete) {
                std.debug.print("ok: wrote complete RAG corpus under {s} ({d} page(s), {d} catalog entries)\n", .{ rag_dir, result.stats.content_pages, result.stats.catalog_entries });
            } else {
                std.debug.print(
                    \\ok: wrote RAG working context under {s}
                    \\  Selected pages: {d} / {d}
                    \\  Structural context: {d} parent page(s), {d} semantic neighbor(s)
                    \\  System context: {d} seed(s)
                    \\  Upload files ({d}):
                    \\
                , .{
                    rag_dir,
                    result.stats.selected_pages,
                    result.stats.graph_pages,
                    result.stats.structural_parent_count,
                    result.stats.semantic_neighbor_count,
                    result.stats.system_docs,
                    result.stats.pack_count,
                });
                for (result.stats.pack_paths) |pack_path| {
                    std.debug.print("    {s}\n", .{pack_path});
                }
                std.debug.print(
                    \\  Approximate upload bytes: {d}
                    \\  Approximate tokens: {d}
                    \\  Non-upload sidecar: manifest.json ({d} file)
                    \\
                    \\
                , .{
                    result.stats.approximate_bytes,
                    result.stats.approximate_tokens,
                    result.stats.sidecar_count,
                });
            }
        }
        return .success;
    }

    return switch (result.compile.failure) {
        .io => .io_error,
        .content, .none => .content_error,
    };
}

/// HTML site render via the Oliver-backed seam + whiteboard arena (default CLI path).
pub fn runHtml(io: Io, gpa: std.mem.Allocator, opts: Options, recorder: ?*timings.Recorder) ExitCode {
    const html_dir = opts.html_dir orelse default_html;

    const layout_path = opts.html_layout;

    if (opts.watch) {
        const watch = @import("watch.zig");
        var watcher = watch.PollingWatcher.init(gpa, io);
        defer watcher.deinit();

        watcher.addRoot(opts.input_dir) catch |err| {
            return mapHtmlError(err, opts.targets.items, layout_path);
        };

        // Watch unique layout parent directories (global + per-target overrides).
        var layout_roots: std.StringHashMapUnmanaged(void) = .{};
        defer layout_roots.deinit(gpa);
        const add_layout_root = struct {
            fn go(w: *watch.PollingWatcher, map: *std.StringHashMapUnmanaged(void), gpa_: std.mem.Allocator, lp: []const u8, input_dir: []const u8) !void {
                // A managed theme root owns `layouts/`, optional `footer.html` and
                // `assets/`. Watch the whole root, not just the layout's parent:
                // footer and referenced asset bytes are page-fingerprint inputs
                // (F9.1), so edits under `<theme>/assets/` must produce events or
                // `--watch` serves stale output (#59). scanFiles is recursive, so
                // this also covers `layouts/`; a missing dir scans to nothing.
                if (theme_mod.themeRootFromLayoutPath(lp)) |theme_root| {
                    if (std.mem.eql(u8, theme_root, input_dir)) return; // content root covers it
                    const t_gop = try map.getOrPut(gpa_, theme_root);
                    if (!t_gop.found_existing) {
                        try w.addRoot(theme_root);
                    }
                    return;
                }
                // Bare filename (no dirname) — watch the file via its parent only when
                // that parent is not the whole cwd (which would scan .git/dist every poll).
                // Prefer not adding "." when content is already watched under input_dir.
                const dir = std.fs.path.dirname(lp) orelse {
                    // Layout sits at repo root as a bare name: do not addRoot(".") —
                    // the layout file is still picked up if it lives under a watched root;
                    // otherwise watch only that single path's parent when it equals input_dir.
                    if (std.mem.eql(u8, input_dir, ".") or std.mem.eql(u8, input_dir, "./")) {
                        return; // content root already covers cwd
                    }
                    return; // skip cwd-wide layout root (issue #18)
                };
                // Skip layout parent if it is already covered by content root.
                if (std.mem.eql(u8, dir, input_dir)) return;
                const gop = try map.getOrPut(gpa_, dir);
                if (!gop.found_existing) {
                    try w.addRoot(dir);
                }
            }
        }.go;
        add_layout_root(&watcher, &layout_roots, gpa, layout_path, opts.input_dir) catch |err| {
            return mapHtmlError(err, opts.targets.items, layout_path);
        };
        for (opts.targets.items) |t| {
            if (t.layout_path) |lp| {
                add_layout_root(&watcher, &layout_roots, gpa, lp, opts.input_dir) catch |err| {
                    return mapHtmlError(err, opts.targets.items, layout_path);
                };
            }
            for (t.layout_rules) |rule| {
                add_layout_root(&watcher, &layout_roots, gpa, rule.layout_path, opts.input_dir) catch |err| {
                    return mapHtmlError(err, opts.targets.items, layout_path);
                };
            }
        }

        var coord = watch.WatchCoordinator.init(gpa, io, opts, watcher.watcher()) catch |err| {
            return mapHtmlError(err, opts.targets.items, layout_path);
        };
        defer coord.deinit();

        coord.run() catch |err| {
            return mapHtmlError(err, opts.targets.items, layout_path);
        };

        return .success;
    }

    var report_collector: ?diag.Collector = null;
    if (opts.report_path != null) report_collector = diag.Collector.init(gpa, io);
    defer if (report_collector) |*c| c.deinit();
    const collector_ptr: ?*diag.Collector = if (report_collector) |*c| c else null;

    var html_verification: ?HtmlVerification = null;
    defer if (html_verification) |*bundle| bundle.deinit(gpa);
    const verify_code = loadHtmlVerification(io, gpa, opts, &html_verification);
    if (verify_code != .success) return verify_code;
    const verification: ?*const standard_site_emit.VerificationContext = if (html_verification) |*bundle| &bundle.vctx else null;

    var html_nostr: ?HtmlNostr = null;
    defer if (html_nostr) |*bundle| bundle.deinit(gpa);
    const nostr_code = loadHtmlNostr(io, gpa, opts, &html_nostr);
    if (nostr_code != .success) return nostr_code;
    const nostr_head: ?*const nostr_emit.HeadConfig = if (html_nostr) |*bundle| &bundle.config else null;

    if (opts.targets.items.len > 0) {
        compile.compileHtmlSiteMulti(io, gpa, opts.targets.items, .{
            .content_root = opts.input_dir,
            .layout_path = layout_path,
            .incremental = opts.incremental,
            .quiet = opts.quiet,
            .jobs = opts.jobs,
            .input_format = opts.input_format,
            .sitemap_path = opts.sitemap_path,
            .site_url = opts.site_url,
            .publication_location = if (opts.publication_location) |*location| location else null,
            .allow_markdown_literals = opts.allow_markdown_links,
            .timings = recorder,
            .diagnostics = collector_ptr,
            .standard_site_verification = verification,
            .nostr_head = nostr_head,
        }) catch |err| {
            const code = mapHtmlError(err, opts.targets.items, layout_path);
            appendEscapedDiagnostic(collector_ptr, err, code);
            writeHtmlReport(io, gpa, opts, collector_ptr, false, html_dir);
            return code;
        };

        if (!opts.quiet) {
            // Canonical order + effective paths (parse already sorts by name).
            std.debug.print("ok: wrote HTML for {d} target(s):\n", .{opts.targets.items.len});
            target.printTargetConfigLines(opts.targets.items, layout_path);
        }
    } else {
        const stats = compile.compileHtmlSite(io, gpa, .{
            .content_root = opts.input_dir,
            .dist_dir = html_dir,
            .layout_path = layout_path,
            .incremental = opts.incremental,
            .quiet = opts.quiet,
            .jobs = opts.jobs,
            .input_format = opts.input_format,
            .sitemap_path = opts.sitemap_path,
            .site_url = opts.site_url,
            .publication_location = if (opts.publication_location) |*location| location else null,
            .allow_markdown_literals = opts.allow_markdown_links,
            .timings = recorder,
            .diagnostics = collector_ptr,
            .standard_site_verification = verification,
            .nostr_head = nostr_head,
        }) catch |err| {
            const code = mapHtmlError(err, &.{}, layout_path);
            appendEscapedDiagnostic(collector_ptr, err, code);
            writeHtmlReport(io, gpa, opts, collector_ptr, false, html_dir);
            return code;
        };

        if (!opts.quiet) {
            std.debug.print("ok: wrote HTML under {s} ({d} page(s))\n", .{ html_dir, stats.pages_written });
        }
    }
    writeHtmlReport(io, gpa, opts, collector_ptr, true, html_dir);
    return .success;
}

/// Map HTML compile failures to process exit codes.
/// Target configuration / path isolation → 2; content/layout/component → 1;
/// missing content root and I/O → 3.
///
/// Every branch that explains a failure prints unconditionally. `--quiet`
/// suppresses progress and success output, never the reason for a nonzero
/// exit; branches that print nothing here do so because the compiler already
/// emitted a structured diagnostic, not because the caller asked for silence.
fn mapHtmlError(
    err: anyerror,
    targets: []const target.TargetSpec,
    global_layout: []const u8,
) ExitCode {
    switch (err) {
        // Target configuration / path isolation — usage (exit 2), not I/O.
        error.NoTargetsSpecified,
        error.InvalidTargetName,
        error.DuplicateTargetName,
        error.EmptyTargetDirectory,
        error.TargetOutputCollision,
        error.TargetOutputSymlink,
        error.WorkspaceEscape,
        error.MixedThemeRoots,
        error.AmbiguousGlob,
        error.DuplicateSelector,
        error.InvalidLayoutPath,
        error.LayoutSelectionFailed,
        error.InvalidSiteUrl,
        error.InvalidSitemapPath,
        error.SitemapOutputCollision,
        error.SitemapSiteUrlRequired,
        error.SitemapSiteUrlWithoutOutput,
        error.AmbiguousSitemapTargets,
        => {
            std.debug.print("error: invalid target configuration: {s}\n", .{@errorName(err)});
            if (targets.len > 0) {
                std.debug.print("configured targets (canonical order):\n", .{});
                target.printTargetConfigLines(targets, global_layout);
            }
            return .usage;
        },
        // Graph/include/wiki/component failures (and multi-target wrap) already print
        // structured diagnostics on the HTML path; re-printing @errorName only doubles noise.
        error.GraphValidationFailed,
        error.IncludeFailed,
        error.ReferenceFailed,
        error.ComponentFailed,
        error.SitemapDuplicateUrl,
        error.SitemapUrlLimitExceeded,
        error.SitemapSizeLimitExceeded,
        error.PublicationLocationMismatch,
        // The content-asset path already emitted the structured EASSET diagnostic
        // for rejected active SVGs; re-printing only doubles noise.
        error.AssetUnsafeSvg,
        // The output link audit already emitted structured route diagnostics;
        // classify the invalid publication as a content failure.
        error.LinkAuditFailed,
        // Multi-target wrap can mix content and I/O; prefer content for graph/include
        // failures already printed, but treat pure layout load I/O as exit 3 via FileNotFound etc.
        error.MultiTargetCompilationFailed,
        => return .content_error,
        // The HTML loader already emitted the structured ETEXTILE diagnostic.
        error.TextileFailed,
        error.InputFormatMismatch,
        => return .content_error,
        error.MultiTargetIoFailed => {
            std.debug.print("error: one or more HTML targets failed due to I/O or a system error\n", .{});
            return .io_error;
        },
        // The target commit is already visible when publication checks fail;
        // compile.zig emits the explicit "publication committed" diagnostic.
        error.PublicationChecksFailed => return .io_error,
        // The target, inventory, and checks report are already committed when
        // claims derivation fails; compile.zig emits the explicit "publication
        // committed" diagnostic for this evidence layer as well.
        error.PublicationClaimsFailed => return .io_error,
        error.PublicationTouchesFailed => return .io_error,
        // The target and all four evidence reports are already committed when
        // Proof Pack generation fails; compile.zig emits the explicit
        // "publication committed" diagnostic for this presentation layer.
        error.PublicationProofPackFailed => return .io_error,
        error.ParseFailed,
        error.LayoutMissingMarker,
        error.LayoutDuplicateMarker,
        error.LayoutUnknownMarker,
        error.LayoutTooManySegments,
        error.LayoutInvalidAssetUrl,
        error.LayoutTooManyAssetUrls,
        error.LayoutInvalidUtf8,
        error.AssetNotFound,
        error.AssetCollision,
        error.AssetSymlink,
        error.AssetPathEscape,
        error.AssetFailed,
        error.AssetPath,
        error.AssetMissing,
        error.AssetNotFile,
        error.ThemeRootMissing,
        error.InvalidThemePath,
        error.ThemeSymlink,
        error.FooterSymlink,
        error.FooterInvalidUtf8,
        => {
            std.debug.print("error: content or layout failure: {s}\n", .{@errorName(err)});
            return .content_error;
        },
        else => {
            std.debug.print("error: I/O or system failure: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    }
}

/// Pure dispatch used by tests (injectable runner; no process.Init required).
pub fn runArgs(args: []const []const u8) u8 {
    var runner: SilentRunner = .{};
    return cli.runArgs(args, &runner);
}

/// Zig 0.16 entry: main receives `std.process.Init` (gpa, arena, io, …).
pub fn main(init: std.process.Init) u8 {
    const cold = init.arena.allocator();

    const args_z = init.minimal.args.toSlice(cold) catch {
        std.debug.print("error: failed to read process arguments\n", .{});
        return ExitCode.io_error.int();
    };

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(cold);
    args_list.ensureTotalCapacity(cold, args_z.len) catch {
        std.debug.print("error: out of memory parsing arguments\n", .{});
        return ExitCode.io_error.int();
    };
    for (args_z) |a| {
        args_list.appendAssumeCapacity(a);
    }

    const runner: ProdRunner = .{
        .gpa = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
    };
    return cli.runArgs(args_list.items, &runner);
}

// --- main-level exit-code mapping tests ------------------------------------

/// Silent runner for CLI-only tests: no help/version/usage/pipeline I/O.
const SilentRunner = struct {
    pipeline_calls: usize = 0,

    pub fn printVersion(self: *@This()) void {
        _ = self;
    }

    pub fn printHelp(self: *@This()) void {
        _ = self;
    }

    pub fn reportUsage(self: *@This(), err: cli.ParseError, bad_arg: ?[]const u8) void {
        _ = self;
        _ = @errorName(err);
        _ = bad_arg;
    }

    pub fn run(self: *@This(), opts: Options) ExitCode {
        _ = opts;
        self.pipeline_calls += 1;
        return .success;
    }
};

test "runArgs: documented exit code mapping" {
    var runner: SilentRunner = .{};

    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--help" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "-h" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--version" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "-V" }, &runner));
    try std.testing.expectEqual(@as(usize, 0), runner.pipeline_calls);

    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{"boris"}, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--quiet" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--no-rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--rag-dir", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--html" }, &runner));
    try std.testing.expectEqual(@as(u8, 0), cli.runArgs(&.{ "boris", "--html-dir", "x" }, &runner));
    try std.testing.expect(runner.pipeline_calls >= 7);

    const before = runner.pipeline_calls;
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--rag", "--no-rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--rag", "--out", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--no-rag", "--rag-dir", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--html", "--rag" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--html", "--out", "x" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--html-dir", "d", "--rag-dir", "r" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--unknown" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "--input" }, &runner));
    try std.testing.expectEqual(@as(u8, 2), cli.runArgs(&.{ "boris", "positional" }, &runner));
    try std.testing.expectEqual(before, runner.pipeline_calls);
}

test "ExitCode contract surface" {
    try std.testing.expectEqual(@as(u8, 0), ExitCode.success.int());
    try std.testing.expectEqual(@as(u8, 1), ExitCode.content_error.int());
    try std.testing.expectEqual(@as(u8, 2), ExitCode.usage.int());
    try std.testing.expectEqual(@as(u8, 3), ExitCode.io_error.int());
    try std.testing.expectEqual(@as(u8, 4), ExitCode.denial.int());
    try std.testing.expectEqual(@as(u8, 5), ExitCode.timeout.int());
    try std.testing.expectEqual(@as(u8, 6), ExitCode.compatibility.int());
    try std.testing.expectEqual(@as(u8, 7), ExitCode.partial_publication.int());
    try std.testing.expectEqual(@as(u8, 8), ExitCode.verification.int());
}

test "classifyPublishError: verification bindings fail closed with exit 8" {
    inline for (.{
        error.PlanDrift,
        error.PlanDigestMismatch,
        error.SessionDidMismatch,
        error.SessionPdsMismatch,
        error.PdsOriginMismatch,
        error.CollectionMismatch,
        error.RkeyMismatch,
        error.CallbackMalformed,
        error.StateMismatch,
        error.InvalidIssuer,
    }) |err| try std.testing.expectEqual(ExitCode.verification, classifyPublishError(err));
}

test "classifyPublishError: denial, timeout, and compatibility are explicit" {
    try std.testing.expectEqual(ExitCode.denial, classifyPublishError(error.AuthorizationDenied));
    try std.testing.expectEqual(ExitCode.timeout, classifyPublishError(error.Timeout));
    inline for (.{
        error.InvalidClientId,
        error.InvalidLoopbackRedirect,
        error.InvalidGrant,
        error.InvalidScope,
        error.InvalidTokenResponse,
        error.InvalidParResponse,
        error.OAuthRequestFailed,
        error.DpopNonceMissing,
        error.DpopNonceRepeated,
        error.InvalidContentType,
    }) |err| try std.testing.expectEqual(ExitCode.compatibility, classifyPublishError(err));
}

test "classifyPublishError: network and host failures exit 3" {
    inline for (.{
        error.ConnectFailed,
        error.DnsFailed,
        error.TlsFailed,
        error.RedirectRejected,
        error.ResponseTooLarge,
        error.UnsafeTarget,
        error.BrowserUnavailable,
        error.BindFailed,
        error.ProofUnavailable,
        error.OutOfMemory,
    }) |err| try std.testing.expectEqual(ExitCode.io_error, classifyPublishError(err));
}

test "standardSiteStatus maps the closed vocabulary" {
    try std.testing.expectEqual(standard_site.Status.published, standardSiteStatus("published"));
    try std.testing.expectEqual(standard_site.Status.archived, standardSiteStatus("archived"));
    try std.testing.expectEqual(standard_site.Status.draft, standardSiteStatus("draft"));
    try std.testing.expectEqual(standard_site.Status.none, standardSiteStatus("future-status"));
    try std.testing.expectEqual(standard_site.Status.none, standardSiteStatus(null));
}

test "mapHtmlError: multi-target I/O failure exits 3" {
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.MultiTargetIoFailed, &.{}, default_layout));
}

test "mapHtmlError: unsafe SVG content failure exits 1 without a generic wrapper" {
    // AssetUnsafeSvg already emitted the structured EASSET diagnostic from the
    // content-asset path; mapHtmlError must classify it as a content error
    // (exit 1) and must not print either generic wrapper line.
    try std.testing.expectEqual(ExitCode.content_error, mapHtmlError(error.AssetUnsafeSvg, &.{}, default_layout));
}

test "mapHtmlError: link-audit content failure exits 1" {
    try std.testing.expectEqual(ExitCode.content_error, mapHtmlError(error.LinkAuditFailed, &.{}, default_layout));
}

test "mapHtmlError: committed publication with stale checks evidence exits 3" {
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.PublicationChecksFailed, &.{}, default_layout));
}

test "mapHtmlError: committed publication with stale claims evidence exits 3" {
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.PublicationClaimsFailed, &.{}, default_layout));
}

test "mapHtmlError: committed publication with unrefreshed Touch Atlas exits 3" {
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.PublicationTouchesFailed, &.{}, default_layout));
    try std.testing.expectEqual(ExitCode.io_error, mapHtmlError(error.PublicationProofPackFailed, &.{}, default_layout));
}

test "mapHtmlError: target configuration failures exit 2" {
    const specs = [_]target.TargetSpec{
        .{ .name = "prod", .output_dir = "dist/prod" },
    };
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.TargetOutputCollision, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.WorkspaceEscape, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.DuplicateTargetName, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.InvalidTargetName, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.TargetOutputSymlink, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.EmptyTargetDirectory, &specs, default_layout));
    try std.testing.expectEqual(ExitCode.usage, mapHtmlError(error.NoTargetsSpecified, &.{}, default_layout));
}

test "runPipeline: valid fixture exits 0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-valid", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .ir,
        .input_dir = "docs/contracts/fixtures/valid/content",
        .out_dir = out,
        .rag_dir = null,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.success, code);
}

test "runPipeline: unreferenced check findings are report-only unless opted in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const default_report = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/di-default.json", .{tmp.sub_path});
    defer gpa.free(default_report);
    const strict_report = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/di-strict.json", .{tmp.sub_path});
    defer gpa.free(strict_report);

    const base = Options{
        .command = .check,
        .input_dir = "docs/contracts/fixtures/documentation-intelligence/content",
        .analysis_format = .json,
        .analysis_report = default_report,
        .quiet = true,
    };
    try std.testing.expectEqual(ExitCode.success, runPipeline(io, gpa, base));

    var strict = base;
    strict.analysis_report = strict_report;
    strict.fail_on_unreferenced = true;
    try std.testing.expectEqual(ExitCode.content_error, runPipeline(io, gpa, strict));

    const cwd = Io.Dir.cwd();
    const default_bytes = try cwd.readFileAlloc(io, default_report, gpa, .unlimited);
    defer gpa.free(default_bytes);
    const strict_bytes = try cwd.readFileAlloc(io, strict_report, gpa, .unlimited);
    defer gpa.free(strict_bytes);
    try std.testing.expectEqualStrings(default_bytes, strict_bytes);
}

test "runPipeline: duplicate-id exits 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-dup", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .ir,
        .input_dir = "docs/contracts/fixtures/duplicate-ids/content",
        .out_dir = out,
        .rag_dir = null,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.content_error, code);
}

test "runPipeline: missing content root exits 3" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-noroot", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .ir,
        .input_dir = "docs/contracts/fixtures/__no_such_root__",
        .out_dir = out,
        .rag_dir = null,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.io_error, code);
}

test "runPipeline: valid RAG fixture exits 0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-rag", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .rag,
        .input_dir = "fixtures/content/valid",
        .out_dir = null,
        .rag_dir = out,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.success, code);
}

test "runPipeline: RAG invalid graph exits 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-rag-bad", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .rag,
        .input_dir = "docs/contracts/fixtures/duplicate-ids/content",
        .out_dir = null,
        .rag_dir = out,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.content_error, code);
}

test "runPipeline: HTML fixture exits 0" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-html", .{tmp.sub_path});
    defer gpa.free(out);

    // Uses the repo's managed Boris theme (default_layout) + HTML content fixture.
    const code = runPipeline(io, gpa, .{
        .mode = .html,
        .input_dir = "test/fixtures/html/content",
        .out_dir = null,
        .rag_dir = null,
        .html_dir = out,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.success, code);

    // Smoke-check that a page landed under the HTML output root.
    const cwd = Io.Dir.cwd();
    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out});
    defer gpa.free(index_path);
    var file = try cwd.openFile(io, index_path, .{});
    defer file.close(io);
}

test "runPipeline: --timings leaves exit codes and artifacts unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-timings", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .ir,
        .input_dir = "docs/contracts/fixtures/valid/content",
        .out_dir = out,
        .quiet = true,
        .timings = true,
    });
    // Same exit code as the non-timings run of the same fixture.
    try std.testing.expectEqual(ExitCode.success, code);

    // Published artifacts match the non-timings expectation.
    const cwd = Io.Dir.cwd();
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.json", .{out});
    defer gpa.free(manifest_path);
    const manifest_bytes = try cwd.readFileAlloc(io, manifest_path, gpa, .unlimited);
    defer gpa.free(manifest_bytes);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"pageCount\": 3") != null);
}

test "runPipeline: HTML missing content root exits 3" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-html-noroot", .{tmp.sub_path});
    defer gpa.free(out);

    const code = runPipeline(io, gpa, .{
        .mode = .html,
        .input_dir = "docs/contracts/fixtures/__no_such_html_root__",
        .out_dir = null,
        .rag_dir = null,
        .html_dir = out,
        .quiet = true,
    });
    try std.testing.expectEqual(ExitCode.io_error, code);
}

test "runPipeline: multi-target HTML build success and validation exits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-multi-a", .{tmp.sub_path});
    defer gpa.free(out_a);
    const out_b = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-multi-b", .{tmp.sub_path});
    defer gpa.free(out_b);

    var opts = Options{
        .mode = .html,
        .input_dir = "test/fixtures/html/content",
        .quiet = true,
    };
    try opts.targets.append(gpa, .{ .name = "t_b", .output_dir = out_b });
    try opts.targets.append(gpa, .{ .name = "t_a", .output_dir = out_a });
    defer opts.targets.deinit(gpa);

    const code = runPipeline(io, gpa, opts);
    try std.testing.expectEqual(ExitCode.success, code);

    // Verify index.html in both
    const cwd = Io.Dir.cwd();
    const path_a = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out_a});
    defer gpa.free(path_a);
    const path_b = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out_b});
    defer gpa.free(path_b);

    var file_a = try cwd.openFile(io, path_a, .{});
    file_a.close(io);
    var file_b = try cwd.openFile(io, path_b, .{});
    file_b.close(io);
}

test "runPipeline: multi-target path collision and content overlap exit 2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const shared = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cli-collide", .{tmp.sub_path});
    defer gpa.free(shared);

    // Equal output roots
    {
        var opts = Options{
            .mode = .html,
            .input_dir = "test/fixtures/html/content",
            .quiet = true,
        };
        try opts.targets.append(gpa, .{ .name = "a", .output_dir = shared });
        try opts.targets.append(gpa, .{ .name = "b", .output_dir = shared });
        defer opts.targets.deinit(gpa);
        try std.testing.expectEqual(ExitCode.usage, runPipeline(io, gpa, opts));
    }

    // Workspace escape
    {
        var opts = Options{
            .mode = .html,
            .input_dir = "test/fixtures/html/content",
            .quiet = true,
        };
        try opts.targets.append(gpa, .{ .name = "escaped", .output_dir = "../outside-boris-target" });
        defer opts.targets.deinit(gpa);
        try std.testing.expectEqual(ExitCode.usage, runPipeline(io, gpa, opts));
    }

    // Content root overlap
    {
        var opts = Options{
            .mode = .html,
            .input_dir = "test/fixtures/html/content",
            .quiet = true,
        };
        try opts.targets.append(gpa, .{ .name = "bad", .output_dir = "test/fixtures/html/content" });
        defer opts.targets.deinit(gpa);
        try std.testing.expectEqual(ExitCode.usage, runPipeline(io, gpa, opts));
    }
}

test "parseOptions: HTML mode defaults and exclusive dirs" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--html" });
    defer o.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.html, o.mode);
    try std.testing.expectEqualStrings("dist", o.html_dir.?);
    try std.testing.expect(o.out_dir == null);
    try std.testing.expect(o.rag_dir == null);

    // Bare argv defaults to HTML (Feature 2).
    var bare = try parseOptions(std.testing.allocator, &.{"boris"});
    defer bare.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.html, bare.mode);
    try std.testing.expectEqualStrings("dist", bare.html_dir.?);

    // Explicit --out selects IR (not HTML).
    var ir = try parseOptions(std.testing.allocator, &.{ "boris", "--out", ".boris" });
    defer ir.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.ir, ir.mode);
    try std.testing.expectEqualStrings(".boris", ir.out_dir.?);
    try std.testing.expect(ir.html_dir == null);

    try std.testing.expectError(
        error.ConflictingFlags,
        parseOptions(std.testing.allocator, &.{ "boris", "--html", "--out", ".boris" }),
    );
    try std.testing.expectError(
        error.ConflictingFlags,
        parseOptions(std.testing.allocator, &.{ "boris", "--html-dir", "d", "--rag" }),
    );
}

test "readAppPasswordLine trims one trailing newline and returns an owned slice" {
    var reader = std.Io.Reader.fixed("hunter2-1234\n");
    const pw = try readAppPasswordLine(std.testing.allocator, &reader);
    defer std.testing.allocator.free(pw);
    defer std.crypto.secureZero(u8, pw);
    try std.testing.expectEqualStrings("hunter2-1234", pw);
}

test "readAppPasswordLine trims a trailing carriage return for CRLF terminals" {
    var reader = std.Io.Reader.fixed("hunter2\r\n");
    const pw = try readAppPasswordLine(std.testing.allocator, &reader);
    defer std.testing.allocator.free(pw);
    try std.testing.expectEqualStrings("hunter2", pw);
}

test "readAppPasswordLine treats end of stream as the end of the credential" {
    var reader = std.Io.Reader.fixed("hunter2");
    const pw = try readAppPasswordLine(std.testing.allocator, &reader);
    defer std.testing.allocator.free(pw);
    try std.testing.expectEqualStrings("hunter2", pw);
}

test "readAppPasswordLine rejects empty input whether blank or at end of stream" {
    var blank = std.Io.Reader.fixed("\n");
    try std.testing.expectError(error.EmptyPassword, readAppPasswordLine(std.testing.allocator, &blank));
    var empty = std.Io.Reader.fixed("");
    try std.testing.expectError(error.EmptyPassword, readAppPasswordLine(std.testing.allocator, &empty));
}

test {
    _ = @import("watch.zig");
}
