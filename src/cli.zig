//! Typed CLI parser for the Boris product surface (milestone 3).
//!
//! Parses argv into a single canonical `Options` value. Does not open paths,
//! read config files, or consult environment variables.

const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const target_mod = @import("target.zig");
const layout_select = @import("layout_select.zig");
const identity = @import("identity.zig");
const github_pages = @import("github_pages.zig");
const site_url_mod = @import("site_url.zig");
const sitemap = @import("sitemap.zig");
const render = @import("render.zig");
const recipe_scale = @import("recipe_scale.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const RunResult = diagnostic.RunResult;

/// Diagnostic detail threaded out of a failed `parseOptionsWithDetail` call
/// alongside the error value, so usage errors can name the option(s) actually
/// at fault instead of guessing from an argv scan (`findBadArg`). All fields
/// are argv views or static strings; nothing to free.
pub const ParseErrorDetail = struct {
    /// Option at fault for value-shaped errors (`InvalidValue`); overrides
    /// the findBadArg scan for the reported token.
    blame_flag: ?[]const u8 = null,
    /// Static explanatory suffix for `blame_flag`, set when the failure has
    /// one well-known cause worth stating inline.
    blame_hint: ?[]const u8 = null,
    /// Both sides of a `ConflictingFlags` rejection, as the user-typed tokens
    /// (commands bare, flags dashed).
    conflict_a: ?[]const u8 = null,
    conflict_b: ?[]const u8 = null,
};

/// Shared explanation for layout/theme path grammar rejections (#761): the
/// same grammar governs `--theme`, `--html-layout`, `--target-layout`, and
/// `--layout-rule` paths.
const layout_path_hint = "layout/theme paths are workspace-relative: no leading '/', drive prefix, '..' segments, or trailing separator";
const site_url_hint = "expected an http(s) deployment URL";

/// Build mode selected by flags.
pub const Mode = enum {
    /// Emit content-compiler IR under `--out` (default `.boris`).
    ir,
    /// RAG-only export under `--rag-dir` (default `rag`).
    rag,
    /// Deterministic provenance-rich AI context bundle.
    context,
    /// Deterministic community `llms.txt` export.
    llms,
    /// Deterministic RSS 2.0 export.
    rss,
    /// HTML site render under `--html-dir` (default `dist`). Default bare CLI.
    html,
};

pub const Command = enum {
    build,
    validate,
    check,
    impact,
    watch,
    plan,
    /// `boris nostr plan` — the offline NIP-23 publication plan. A family of
    /// its own rather than a mode of `plan`, because `plan` is a configuration
    /// declaration that never scans content and must not start.
    nostr_plan,
    /// `boris nostr sign` — offline BIP-340 signing of a NIP-23 publication
    /// plan into a signed-event bundle (no relay, never publishes).
    nostr_sign,
    /// `boris nostr publish` — send the exact signed events from a bundle to
    /// the plan's relays over RFC-6455 WebSocket, per-relay evidence and
    /// complete/partial/failed/incomplete classification in a report.
    nostr_publish,
    init,
    /// `standard-site publish` — the explicit one-shot publish family. The
    /// network operation lives only here; no other command publishes.
    standard_site,
    /// `boris recipe-scale` — derived Cooklang scale view. Never rewrites
    /// `.cook` or `graph.json`.
    recipe_scale,
};

/// The subcommand selected under the `standard-site` family. Every member is
/// explicit: a missing or unknown subcommand is a usage error, never a
/// silent fallback.
pub const StandardSiteCommand = enum {
    publish,
    plan,
    records,
    verify,
    login,
    sessions,
    logout,
    smoke,
};

pub const AnalysisFormat = enum {
    human,
    json,
};

/// Canonical parsed options. Strings are views into argv (or static defaults).
pub const Options = struct {
    /// When true, print help and exit successfully (no pipeline).
    help: bool = false,
    /// When true, print the compiler version and exit successfully (no pipeline).
    version: bool = false,
    /// When true, print the build-info provenance document (#776) and exit
    /// successfully (no pipeline). Additive stdout machine surface.
    build_info: bool = false,
    /// Suppress progress and success chatter on stderr (`--quiet`).
    ///
    /// This never suppresses errors or fatal diagnostics. A nonzero exit must
    /// always explain itself: the README's own examples pass `--quiet`, so a
    /// flag that silenced the explanation turned every documented command into
    /// a silent failure. Warnings and info diagnostics count as chatter and
    /// stay suppressed; anything at error severity does not.
    quiet: bool = false,
    /// When true, emit a machine-readable phase timing/counter report
    /// (`--timings`). Off unless requested; never changes artifacts or codes.
    timings: bool = false,
    command: Command = .build,
    /// Which `standard-site` subcommand was selected.
    standard_site_command: StandardSiteCommand = .publish,
    /// True when `standard-site publish` was selected (kept for callers that
    /// dispatch on the bool; prefer `standard_site_command`).
    standard_site_publish: bool = false,
    /// Committed `boris-standard-site-plan` file to validate against the
    /// freshly rendered plan before any network mutation.
    plan_path: ?[]const u8 = null,
    /// Evidence artifact output path for `standard-site publish` (default:
    /// stdout, mirroring `plan`).
    publish_out: ?[]const u8 = null,
    /// Plan artifact output path for `standard-site plan` (default: stdout).
    plan_out: ?[]const u8 = null,
    /// Records artifact output path for `standard-site records` (default:
    /// stdout).
    records_out: ?[]const u8 = null,
    /// Verify result output path for `standard-site verify` (default: stdout).
    verify_out: ?[]const u8 = null,
    /// Built output directory `standard-site verify` checks (default: `dist`).
    verify_dist: []const u8 = "dist",
    /// Explicit prune authority for `standard-site publish`; ANDs with the
    /// profile's `prune` flag.
    publish_prune: bool = false,
    /// Optional source commit recorded in the publish evidence bindings.
    source_commit: ?[]const u8 = null,
    /// DID for `standard-site login` / `standard-site logout` (required by
    /// both; forbidden elsewhere in the family).
    session_did: ?[]const u8 = null,
    /// Handle for `standard-site login --app-password` or `smoke`
    /// (alternative to `--did`; resolves to the DID via DNS/HTTPS).
    session_handle: ?[]const u8 = null,
    /// Select the opt-in app-password credential path for `standard-site
    /// login` (never a fallback inside the OAuth flow).
    app_password: bool = false,
    /// Override the persistent session root for the `standard-site` family
    /// (default: `$HOME/.local/share/boris/sessions`).
    session_root: ?[]const u8 = null,
    /// Namespace prefix for `standard-site smoke` test rkeys (default: a
    /// clock-derived unique namespace).
    smoke_namespace: ?[]const u8 = null,
    /// Served verification-surface origin checked by `standard-site smoke`
    /// (`--surface-url`): the well-known publication file is fetched and
    /// validated at `https://<origin>/.well-known/site.standard.publication`.
    smoke_surface_url: ?[]const u8 = null,
    /// Indexer/AppView origin observed non-normatively by
    /// `standard-site smoke` (`--indexer`).
    smoke_indexer_origin: ?[]const u8 = null,
    /// Result output path for `standard-site smoke` (default: stdout).
    smoke_out: ?[]const u8 = null,
    /// Explicit profile selected by `plan --profile PATH`.
    profile_path: ?[]const u8 = null,
    /// Explicit profile-mode publication overrides. These remain argv views;
    /// the profile parser owns the normalized plan values.
    profile_input_override: ?[]const u8 = null,
    profile_input_format_override: ?identity.InputFormat = null,
    profile_html_output_override: ?[]const u8 = null,
    impact_id: ?[]const u8 = null,
    /// Target directory for `boris init [DIR]` (default: ".").
    init_dir: ?[]const u8 = null,
    analysis_format: AnalysisFormat = .human,
    analysis_report: ?[]const u8 = null,
    /// HTML-path diagnostics report path (`--report` on build/validate).
    /// Written on both success and failure; see `html-build-report` schema.
    report_path: ?[]const u8 = null,
    /// Make ordinary unreferenced-page analysis findings fatal for `check`.
    fail_on_unreferenced: bool = false,
    mode: Mode = .html,
    /// Explicit whole-tree authoring format (Markdown remains the default).
    input_format: identity.InputFormat = .markdown,
    /// Content root (default `content`).
    input_dir: []const u8 = "content",
    /// IR output directory. Set for IR mode only (default `.boris`).
    out_dir: ?[]const u8 = null,
    /// RAG corpus directory. Set for RAG mode only (default `rag`).
    rag_dir: ?[]const u8 = null,
    /// Complete-corpus RAG export (working packs are the default).
    complete: bool = false,
    /// Context bundle directory. Set for context mode only (default `context`).
    context_dir: ?[]const u8 = null,
    /// Optional entity or collection-prefix projection for RAG/context.
    scope: ?[]const u8 = null,
    /// Optional byte cap for deterministic RAG/context bundle parts.
    split_size: ?usize = null,
    /// Product RAG: emit upload-ready parts without per-page files.
    bundles_only: bool = false,
    /// `llms.txt` output path (default `llms.txt`).
    llms_path: ?[]const u8 = null,
    /// RSS XML output path (default `rss.xml`).
    rss_path: ?[]const u8 = null,
    site_url: ?[]const u8 = null,
    /// Normalized GitHub Pages publication identity for URL-bearing output.
    publication_location: ?github_pages.Location = null,
    /// Accept literal `.md`/`.mdx` hrefs in the output link audit, which the
    /// pre-render rewriter deliberately leaves in place. Suppresses only
    /// EROUTEMISSING for those extensions, never EROUTEESCAPE.
    allow_markdown_links: bool = false,
    rss_title: ?[]const u8 = null,
    rss_description: ?[]const u8 = null,
    rss_limit: usize = 20,
    /// Target-root-relative sitemap path when HTML sitemap publication is enabled.
    sitemap_path: ?[]const u8 = null,
    /// Project-relative static passthrough directory (#804). When set, its
    /// contents are copied byte-identically into the selected HTML target
    /// root and declared as `static-file` inventory records.
    static_dir: ?[]const u8 = null,
    /// HTML output directory. Set for HTML mode only (default `dist`).
    html_dir: ?[]const u8 = null,
    /// Global HTML layout template (default managed Boris theme).
    html_layout: []const u8 = "themes/boris/layouts/main.html",
    /// When set, `html_layout` was allocated for `--theme` sugar and must be freed.
    owned_html_layout: bool = false,
    /// Explicit incremental HTML build mode (HTML mode only).
    incremental: bool = false,
    /// Force full publication-evidence re-derivation even when reuse applies
    /// (HTML mode only, #728).
    refresh_evidence: bool = false,
    /// Bounded parallel rendering worker count (HTML mode only).
    jobs: usize = 1,
    /// Opt-in local-development watch mode for HTML builds and, with the
    /// `validate` command, the zero-write validation daemon (`validate --watch`).
    watch: bool = false,
    /// Emit the machine-readable NDJSON event stream on stderr instead of
    /// watch prose (`watch --watch-json`). Requires watch mode; implies
    /// quiet. Contract: docs/contracts/watch-mode.md §8.
    watch_json: bool = false,
    /// Serve the built HTML tree over loopback HTTP with reload-on-rebuild
    /// (`watch --serve`). Requires watch mode.
    serve: bool = false,
    /// Loopback port for `--serve` (default `preview_server.default_port`;
    /// `0` selects an ephemeral port). Implies `serve`.
    serve_port: ?u16 = null,
    /// Effective Oliver serialization profile for the synthetic "default"
    /// target (`--target-profile default=xhtml`, #448). Per-target profiles
    /// live on `targets`; this mirrors the default target for the
    /// single-target compile path. Null → `.html`.
    html_profile: ?render.OutputProfile = null,
    /// Dynamic target list.
    targets: std.ArrayListUnmanaged(target_mod.TargetSpec) = .{ .items = &.{}, .capacity = 0 },
    /// `nostr sign` inputs: the plan artifact path, whether the secret key is
    /// read from stdin, the signed-bundle output path, an optional prior
    /// signed bundle, and an optional explicit signing-time override.
    nostr_plan_path: ?[]const u8 = null,
    nostr_bundle_path: ?[]const u8 = null,
    nostr_key_stdin: bool = false,
    nostr_out_path: ?[]const u8 = null,
    nostr_prior_path: ?[]const u8 = null,
    nostr_created_at: ?i64 = null,
    /// `recipe-scale` inputs: one page id, factor or servings target, and an
    /// optional JSON output path (stdout is always written on success).
    recipe_scale_id: ?[]const u8 = null,
    recipe_scale_factor: ?[]const u8 = null,
    recipe_scale_servings: ?[]const u8 = null,
    recipe_scale_out: ?[]const u8 = null,

    pub fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        if (self.publication_location) |*location| location.deinit(gpa);
        if (self.owned_html_layout) {
            gpa.free(self.html_layout);
            self.owned_html_layout = false;
        }
        for (self.targets.items) |t| {
            if (t.layout_rules.len > 0) gpa.free(t.layout_rules);
        }
        self.targets.deinit(gpa);
    }
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    EmptyValue,
    UnexpectedPositional,
    ConflictingFlags,
    DuplicateFlag,
    InvalidValue,
    // A mode was selected but its required companion options were never
    // supplied (e.g. RSS without channel metadata). Distinct from
    // MissingValue, which means a flag that takes a value was given without
    // one — reporting that for these cases misnames the flag.
    RSSMetadataRequired,
    SitemapSiteUrlRequired,
    PagesLocationIncomplete,
    // `--rss-limit` given a non-numeric or out-of-range value: the parse
    // loop knows the flag, so name it instead of letting findBadArg guess.
    InvalidRssLimit,
    // `boris nostr <x>` where `<x>` is not a subcommand this build implements.
    // Named separately so the message can list what does exist rather than
    // reporting a bare unknown positional.
    UnknownNostrSubcommand,
    // `boris standard-site` with no subcommand: print the family list, not
    // "unexpected argument: standard-site".
    MissingStandardSiteSubcommand,
    // `boris standard-site <x>` where `<x>` is not a family member.
    UnknownStandardSiteSubcommand,
    // Family-scoped required-flag errors so usage prints the family list
    // instead of the global compiler help.
    MissingStandardSiteProfile,
    MissingStandardSiteIdentity,
    ConflictingStandardSiteFlags,
    OutOfMemory,
};

const default_input_dir = "content";
const default_out_dir = ".boris";
const default_rag_dir = "rag";
const default_context_dir = "context";
const default_llms_path = "llms.txt";
const default_rss_path = "rss.xml";
const default_sitemap_path = sitemap.default_output_path;
const default_html_dir = "dist";
const default_html_layout = "themes/boris/layouts/main.html";

/// Parse argv into `Options`. Does not print, exit, or touch the filesystem.
///
/// `args[0]` is the program name when present (skipped).
/// `--help` / `-h` short-circuit: remaining args are not validated.
///
/// Structure: `ParseState` accumulates one run; prefix/loop parsing is split
/// into single-purpose parsers below; each non-build command finishes in its
/// own builder; build-shaped commands share the conflict matrix, mode
/// resolution, and per-mode option construction.
pub fn parseOptions(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    return parseOptionsWithDetail(gpa, args, null);
}

/// `parseOptions` plus an optional diagnostic-detail out-channel (#761,
/// #764): when parsing fails, `detail` receives whatever context the failing
/// path recorded (blamed option, conflict pair). On success it is reset to
/// the default. The error set and every parsed value are identical to
/// `parseOptions`.
pub fn parseOptionsWithDetail(
    gpa: std.mem.Allocator,
    args: []const []const u8,
    detail: ?*ParseErrorDetail,
) ParseError!Options {
    var st = ParseState{};
    errdefer freeTargetList(gpa, &st.targets);
    errdefer if (st.publication_location) |*location| location.deinit(gpa);
    // Pending --target-layout / --target-profile / --layout-rule entries hold
    // argv views only; they are joined to targets after the loop.
    defer st.target_layouts.deinit(gpa);
    defer st.target_profiles.deinit(gpa);
    defer st.pending_rules.deinit(gpa);

    const opts = parseOptionsAccumulate(gpa, args, &st) catch |err| {
        if (detail) |d| d.* = st.err_detail;
        return err;
    };
    if (detail) |d| d.* = st.err_detail;
    return opts;
}

fn parseOptionsAccumulate(gpa: std.mem.Allocator, args: []const []const u8, st: *ParseState) ParseError!Options {
    var i: usize = if (args.len > 0) 1 else 0;
    try parseCommandPrefix(args, &i, st);

    while (i < args.len) : (i += 1) {
        const a = args[i];

        if (captureCommandPositional(st, a)) continue;

        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h") or
            std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V") or
            std.mem.eql(u8, a, "--build-info"))
        {
            // Help/version/build-info short-circuits: do not validate
            // remaining args. The first of the three flags wins (they share
            // one exit path). Release any targets accumulated before the
            // flag: the returned Options carries an empty list (no
            // allocation), and the caller's deinit would never see the
            // accumulated one (errdefer only fires on error), so
            // `--target X --help`/`--version`/`--build-info` must not leak it.
            freeTargetList(gpa, &st.targets);
            const wants_help = std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
            const wants_version = !wants_help and
                (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V"));
            return .{
                .help = wants_help,
                .version = wants_version,
                .build_info = !wants_help and !wants_version,
                .quiet = st.quiet,
                .timings = st.saw_timings,
                .command = st.command,
                .mode = .ir,
                .input_dir = st.input_dir,
                .out_dir = st.out_dir,
                .rag_dir = null,
                .context_dir = null,
                .scope = null,
                .split_size = null,
                .bundles_only = false,
                .llms_path = null,
                .html_dir = null,
                .targets = .{ .items = &.{}, .capacity = 0 },
            };
        }

        if (try parseGlobalFlags(st, a)) continue;
        if (try parseProfileAndPlanFlags(st, a, args, &i)) continue;
        if (try parseNostrFlags(st, a, args, &i)) continue;
        if (try parseRecipeScaleFlags(st, a, args, &i)) continue;
        if (try parseModeFlags(st, a, args, &i)) continue;
        if (try parseAnalysisFlags(st, a, args, &i)) continue;
        if (try parseTargetSpecs(gpa, st, a, args, &i)) continue;
        if (try parseSessionFlags(st, a, args, &i)) continue;
        if (try parsePathFlags(st, a, args, &i)) continue;
        if (try parseHtmlFlags(st, a, args, &i)) continue;

        if (std.mem.startsWith(u8, a, "-")) return error.UnknownFlag;
        return error.UnexpectedPositional;
    }

    try resolveThemeSugar(gpa, st);
    errdefer if (st.owned_html_layout) gpa.free(st.html_layout);

    // `impact` requires its target; the loop capture defers the immediate-
    // after-command check so flags may precede the positional.
    if (st.command == .impact and st.impact_id == null) return error.MissingValue;

    // One explicit source family per build. Two adapters at once has no
    // meaning: each is a whole-tree mode that refuses the other's extension.
    if (st.saw_textile and st.saw_cooklang) return failConflict(st, "--textile", "--cooklang");

    switch (st.command) {
        .plan => return try buildPlanOptions(st),
        .nostr_plan => return try buildNostrPlanOptions(st),
        .nostr_sign => return try buildNostrSignOptions(st),
        .nostr_publish => return try buildNostrPublishOptions(st),
        .init => return try buildInitOptions(st),
        .recipe_scale => return try buildRecipeScaleOptions(st),
        .standard_site => return try buildStandardSiteOptions(st),
        .build, .validate, .check, .impact, .watch => {},
    }

    try validateBuildConflicts(st);
    const mode = resolveMode(st);

    // The HTML-path diagnostics report (`--report`) belongs to the HTML mode.
    // `check`/`impact` reuse the same flag name for their analysis report (see
    // `analysis_report`), so only non-HTML build/watch runs must refuse it.
    if (mode != .html and (st.command == .build or st.command == .watch) and st.saw_report) {
        return error.ConflictingFlags;
    }

    try finalizePublicationIdentity(gpa, st);
    // Snapshot before synthesizing the default target below: the HTML option
    // construction distinguishes explicit --target lists from the synthesized
    // single-target form.
    const had_explicit_targets = st.hasExplicitTargets();
    try synthesizeDefaultTarget(gpa, st, mode);
    try applyTargetLayouts(st);
    try applyTargetProfiles(st);
    const default_profile = scanDefaultProfile(st);
    if (st.pending_rules.items.len > 0) try attachLayoutRules(gpa, st);

    // Canonical target order: equivalent --target argv permutations produce the
    // same Options.targets sequence (sorted by name). Execution/diagnostics use
    // the same order via validateTargets.
    if (st.targets.items.len > 1) {
        target_mod.sortTargetSpecsByName(st.targets.items);
    }

    return buildOptionsForMode(st, mode, default_profile, had_explicit_targets);
}

// ---------------------------------------------------------------------------
// parseOptions internals
//
// The parser is decomposed around a flat accumulator (`ParseState`) plus
// single-purpose parsers and per-command option builders. Behavior parity is
// the invariant: same flag grammar, same error precedence, same duplicate and
// conflict detection, same argv views, and the same `Options` field sets per
// mode as the historical single-loop implementation.
// ---------------------------------------------------------------------------

/// One `--target-layout NAME=PATH` awaiting a matching target. Applied after
/// the target list is known, so flag order relative to `--target` is free.
const PendingTargetLayout = struct { name: []const u8, path: []const u8 };

/// One `--target-profile NAME=PROFILE` awaiting a matching target (#448).
const PendingTargetProfile = struct { name: []const u8, profile: render.OutputProfile };

/// One `--layout-rule TARGET SELECTOR LAYOUT_PATH` (three following args).
const PendingLayoutRule = struct {
    target: []const u8,
    selector: []const u8,
    path: []const u8,
};

/// Mutable accumulator for one `parseOptions` run. Field defaults are the
/// canonical pre-parse values; `saw_*` flags double as duplicate-option
/// detectors and, for boolean selectors, as the selected value.
const ParseState = struct {
    command: Command = .build,

    // Global flags.
    quiet: bool = false,
    saw_quiet: bool = false,
    saw_timings: bool = false,

    // Source tree and projection paths (argv views or static defaults).
    input_dir: []const u8 = default_input_dir,
    out_dir: []const u8 = default_out_dir,
    rag_dir: []const u8 = default_rag_dir,
    context_dir: []const u8 = default_context_dir,
    llms_path: []const u8 = default_llms_path,
    rss_path: []const u8 = default_rss_path,
    sitemap_path: []const u8 = default_sitemap_path,
    static_dir: ?[]const u8 = null,
    html_dir: []const u8 = default_html_dir,
    html_layout: []const u8 = default_html_layout,
    theme_root: ?[]const u8 = null,

    // Publication identity and RSS/sitemap channel data.
    site_url: ?[]const u8 = null,
    pages_base_url: ?[]const u8 = null,
    pages_origin: ?[]const u8 = null,
    pages_base_path: ?[]const u8 = null,
    rss_title: ?[]const u8 = null,
    rss_description: ?[]const u8 = null,
    rss_limit: usize = 20,

    // RAG/context projection controls.
    scope: ?[]const u8 = null,
    split_size: ?usize = null,
    bundles_only: bool = false,
    complete: bool = false,

    // HTML rendering controls.
    jobs: usize = 1,
    serve_port: ?u16 = null,
    owned_html_layout: bool = false,

    // Duplicate detectors for repeatable-once flags.
    saw_input: bool = false,
    saw_out: bool = false,
    saw_rag: bool = false,
    saw_no_rag: bool = false,
    saw_rag_dir: bool = false,
    saw_context: bool = false,
    saw_context_dir: bool = false,
    saw_scope: bool = false,
    saw_split_size: bool = false,
    saw_bundles_only: bool = false,
    saw_complete: bool = false,
    saw_llms: bool = false,
    saw_llms_path: bool = false,
    saw_rss: bool = false,
    saw_rss_path: bool = false,
    saw_site_url: bool = false,
    saw_pages_base_url: bool = false,
    saw_pages_origin: bool = false,
    saw_pages_base_path: bool = false,
    saw_rss_title: bool = false,
    saw_rss_description: bool = false,
    saw_rss_limit: bool = false,
    saw_sitemap: bool = false,
    saw_sitemap_path: bool = false,
    saw_static_dir: bool = false,
    saw_html: bool = false,
    saw_html_dir: bool = false,
    saw_html_layout: bool = false,
    saw_theme: bool = false,
    saw_incremental: bool = false,
    saw_refresh_evidence: bool = false,
    saw_jobs: bool = false,
    saw_watch: bool = false,
    saw_watch_json: bool = false,
    saw_serve: bool = false,
    saw_textile: bool = false,
    saw_cooklang: bool = false,
    saw_format: bool = false,
    saw_report: bool = false,
    saw_fail_on_unreferenced: bool = false,
    saw_profile: bool = false,

    // Analysis commands (`check` / `impact`) and their shared flags.
    impact_id: ?[]const u8 = null,
    analysis_format: AnalysisFormat = .human,
    analysis_report: ?[]const u8 = null,
    fail_on_unreferenced: bool = false,

    // `init [DIR]` positional.
    init_dir: ?[]const u8 = null,

    // `plan` / profile selection.
    profile_path: ?[]const u8 = null,

    // `standard-site` family state.
    standard_site_command: StandardSiteCommand = .publish,
    session_did: ?[]const u8 = null,
    saw_session_did: bool = false,
    session_handle: ?[]const u8 = null,
    saw_session_handle: bool = false,
    app_password: bool = false,
    saw_app_password: bool = false,
    session_root: ?[]const u8 = null,
    saw_session_root: bool = false,
    plan_path: ?[]const u8 = null,
    saw_plan_path: bool = false,
    publish_prune: bool = false,
    source_commit: ?[]const u8 = null,
    saw_source_commit: bool = false,
    smoke_namespace: ?[]const u8 = null,
    saw_smoke_namespace: bool = false,
    smoke_surface_url: ?[]const u8 = null,
    saw_smoke_surface_url: bool = false,
    smoke_indexer_origin: ?[]const u8 = null,
    saw_smoke_indexer_origin: bool = false,
    verify_dist: ?[]const u8 = null,
    saw_verify_dist: bool = false,

    // `nostr sign` / `nostr publish` family state.
    nostr_plan_path: ?[]const u8 = null,
    saw_nostr_plan: bool = false,
    nostr_bundle_path: ?[]const u8 = null,
    saw_nostr_bundle: bool = false,
    nostr_key_stdin: bool = false,
    saw_nostr_key_stdin: bool = false,
    nostr_out_path: ?[]const u8 = null,
    saw_nostr_out: bool = false,
    nostr_prior_path: ?[]const u8 = null,
    saw_nostr_prior: bool = false,
    nostr_created_at: ?i64 = null,
    saw_nostr_created_at: bool = false,

    // `recipe-scale` family state.
    recipe_scale_id: ?[]const u8 = null,
    saw_recipe_scale_id: bool = false,
    recipe_scale_factor: ?[]const u8 = null,
    saw_recipe_scale_factor: bool = false,
    recipe_scale_servings: ?[]const u8 = null,
    saw_recipe_scale_servings: bool = false,
    recipe_scale_out: ?[]const u8 = null,
    saw_recipe_scale_out: bool = false,

    // Heap-backed accumulators and moved-ownership results.
    targets: std.ArrayListUnmanaged(target_mod.TargetSpec) = .{ .items = &.{}, .capacity = 0 },
    publication_location: ?github_pages.Location = null,
    allow_markdown_links: bool = false,
    target_layouts: std.ArrayListUnmanaged(PendingTargetLayout) = .{ .items = &.{}, .capacity = 0 },
    target_profiles: std.ArrayListUnmanaged(PendingTargetProfile) = .{ .items = &.{}, .capacity = 0 },
    pending_rules: std.ArrayListUnmanaged(PendingLayoutRule) = .{ .items = &.{}, .capacity = 0 },

    /// Diagnostic detail recorded by failing paths that know more than the
    /// argv scan can guess (#761, #764). Copied out by
    /// `parseOptionsWithDetail` when accumulation returns an error.
    err_detail: ParseErrorDetail = .{},

    fn hasExplicitTargets(st: *const ParseState) bool {
        return st.targets.items.len > 0;
    }

    fn hasTargetLayouts(st: *const ParseState) bool {
        return st.target_layouts.items.len > 0;
    }

    fn hasTargetProfiles(st: *const ParseState) bool {
        return st.target_profiles.items.len > 0;
    }

    fn hasLayoutRules(st: *const ParseState) bool {
        return st.pending_rules.items.len > 0;
    }

    fn wantsSitemap(st: *const ParseState) bool {
        return st.saw_sitemap or st.saw_sitemap_path;
    }

    fn wantsStatic(st: *const ParseState) bool {
        return st.saw_static_dir;
    }

    /// Explicit HTML selectors (not the bare default).
    fn explicitHtml(st: *const ParseState) bool {
        return st.saw_html or st.saw_html_dir or st.hasExplicitTargets() or
            st.saw_html_layout or st.hasTargetLayouts() or st.hasTargetProfiles() or
            st.saw_theme or st.hasLayoutRules() or st.wantsSitemap() or st.wantsStatic();
    }

    fn wantsRag(st: *const ParseState) bool {
        return st.saw_rag or st.saw_rag_dir;
    }

    fn wantsContext(st: *const ParseState) bool {
        return st.saw_context or st.saw_context_dir;
    }

    fn wantsLlms(st: *const ParseState) bool {
        return st.saw_llms or st.saw_llms_path;
    }

    fn wantsRss(st: *const ParseState) bool {
        return st.saw_rss or st.saw_rss_path;
    }

    fn sawPagesLocation(st: *const ParseState) bool {
        return st.saw_pages_base_url or st.saw_pages_origin or st.saw_pages_base_path;
    }

    /// Explicit IR: --out and/or --no-rag (bare CLI is HTML, not IR).
    fn wantsIr(st: *const ParseState) bool {
        return st.saw_out or st.saw_no_rag;
    }

    /// Whole-tree authoring format. The textile/cooklang pair conflict is
    /// checked before this is consulted.
    fn inputFormat(st: *const ParseState) identity.InputFormat {
        if (st.saw_textile) return .textile;
        if (st.saw_cooklang) return .cook;
        return .markdown;
    }
};

/// Top-level commands whose parsing is a bare leading token. Order-free: the
/// names are mutually exclusive literals.
const simple_commands = [_]struct { name: []const u8, command: Command }{
    .{ .name = "build", .command = .build },
    .{ .name = "validate", .command = .validate },
    .{ .name = "watch", .command = .watch },
    .{ .name = "check", .command = .check },
    .{ .name = "impact", .command = .impact },
    .{ .name = "plan", .command = .plan },
    .{ .name = "recipe-scale", .command = .recipe_scale },
};

/// Exactly the `nostr` subcommands this build implements. An unknown one is a
/// usage error rather than a stub, so nothing can look like publishing
/// exists.
const nostr_subcommands = [_]struct { name: []const u8, command: Command }{
    .{ .name = "plan", .command = .nostr_plan },
    .{ .name = "sign", .command = .nostr_sign },
    .{ .name = "publish", .command = .nostr_publish },
};

const ModeBoolFlag = enum {
    textile,
    cooklang,
    rag,
    context,
    bundles_only,
    complete,
    llms,
    rss,
    sitemap,
    html,
    incremental,
    refresh_evidence,
    watch,
    serve,
    watch_json,
    no_rag,
};

/// Boolean mode selectors handled identically: record once (duplicates are
/// usage errors) and, for two of them, mirror into a value variable.
const mode_bool_flags = [_]struct { name: []const u8, flag: ModeBoolFlag }{
    .{ .name = "--textile", .flag = .textile },
    .{ .name = "--cooklang", .flag = .cooklang },
    .{ .name = "--rag", .flag = .rag },
    .{ .name = "--context", .flag = .context },
    .{ .name = "--bundles-only", .flag = .bundles_only },
    .{ .name = "--complete", .flag = .complete },
    .{ .name = "--llms", .flag = .llms },
    .{ .name = "--rss", .flag = .rss },
    .{ .name = "--sitemap", .flag = .sitemap },
    .{ .name = "--html", .flag = .html },
    .{ .name = "--incremental", .flag = .incremental },
    .{ .name = "--refresh-evidence", .flag = .refresh_evidence },
    .{ .name = "--watch", .flag = .watch },
    .{ .name = "--serve", .flag = .serve },
    .{ .name = "--watch-json", .flag = .watch_json },
    .{ .name = "--no-rag", .flag = .no_rag },
};

/// Duplicate-option guard shared by every repeatable-once flag: the first
/// occurrence records, a second is a usage error.
fn markSaw(saw: *bool) ParseError!void {
    if (saw.*) return error.DuplicateFlag;
    saw.* = true;
}

/// Record a conflicting-flag pair for diagnostics, then fail (#764). Both
/// tokens are displayed as the user typed them: commands bare, flags dashed.
fn failConflict(st: *ParseState, a: []const u8, b: []const u8) ParseError {
    st.err_detail = .{ .conflict_a = a, .conflict_b = b };
    return error.ConflictingFlags;
}

/// Record the option at fault for a value-shaped rejection, then fail (#761).
fn failInvalidValue(st: *ParseState, flag: []const u8, hint: ?[]const u8) ParseError {
    st.err_detail = .{ .blame_flag = flag, .blame_hint = hint };
    return error.InvalidValue;
}

/// User-typed spelling of a command for conflict diagnostics: commands bare,
/// flags dashed (mirrors the #764 "check conflicts with --theme" shape).
fn commandWord(command: Command) []const u8 {
    return switch (command) {
        .build => "build",
        .validate => "validate",
        .check => "check",
        .impact => "impact",
        .watch => "watch",
        .plan => "plan",
        .nostr_plan => "nostr plan",
        .nostr_sign => "nostr sign",
        .nostr_publish => "nostr publish",
        .init => "init",
        .standard_site => "standard-site",
        .recipe_scale => "recipe-scale",
    };
}

/// First explicit HTML-selector token present in this run, for naming
/// analyzer×selector and selector×`--out` conflicts (#764). The order is a
/// fixed list, so the named token is deterministic for any argv. Covers
/// exactly the `explicitHtml()` constituents.
fn htmlSelectorToken(st: *const ParseState) ?[]const u8 {
    // --theme precedes --html-layout because resolveThemeSugar mirrors the
    // theme root into saw_html_layout; name what the user typed (#761).
    if (st.saw_html) return "--html";
    if (st.saw_html_dir) return "--html-dir";
    if (st.saw_theme) return "--theme";
    if (st.saw_html_layout) return "--html-layout";
    if (st.hasExplicitTargets()) return "--target";
    if (st.hasTargetLayouts()) return "--target-layout";
    if (st.hasTargetProfiles()) return "--target-profile";
    if (st.hasLayoutRules()) return "--layout-rule";
    if (st.wantsSitemap()) return if (st.saw_sitemap) "--sitemap" else "--sitemap-path";
    if (st.wantsStatic()) return "--static-dir";
    return null;
}

fn applyModeBoolFlag(st: *ParseState, entry: ModeBoolFlag) ParseError!void {
    const saw: *bool = switch (entry) {
        .textile => &st.saw_textile,
        .cooklang => &st.saw_cooklang,
        .rag => &st.saw_rag,
        .context => &st.saw_context,
        .bundles_only => &st.saw_bundles_only,
        .complete => &st.saw_complete,
        .llms => &st.saw_llms,
        .rss => &st.saw_rss,
        .sitemap => &st.saw_sitemap,
        .html => &st.saw_html,
        .incremental => &st.saw_incremental,
        .refresh_evidence => &st.saw_refresh_evidence,
        .watch => &st.saw_watch,
        .serve => &st.saw_serve,
        .watch_json => &st.saw_watch_json,
        .no_rag => &st.saw_no_rag,
    };
    try markSaw(saw);
    switch (entry) {
        .bundles_only => st.bundles_only = true,
        .complete => st.complete = true,
        else => {},
    }
}

/// Free one accumulated target list, including per-target rule allocations.
fn freeTargetList(gpa: std.mem.Allocator, targets: *std.ArrayListUnmanaged(target_mod.TargetSpec)) void {
    for (targets.items) |t| {
        if (t.layout_rules.len > 0) gpa.free(t.layout_rules);
    }
    targets.deinit(gpa);
}

/// Parse the leading command token, including the `nostr` and
/// `standard-site` subcommand families. Consumes argv up to (but not
/// including) the first flag or positional handled by the main loop.
fn parseCommandPrefix(args: []const []const u8, i: *usize, st: *ParseState) ParseError!void {
    if (i.* >= args.len) return;
    for (simple_commands) |entry| {
        if (!std.mem.eql(u8, args[i.*], entry.name)) continue;
        st.command = entry.command;
        i.* += 1;
        // Bare `boris watch` is watch mode, identical to `--watch`.
        if (entry.command == .watch) st.saw_watch = true;
        return;
    }
    if (std.mem.eql(u8, args[i.*], "nostr")) {
        return parseNostrFamily(args, i, &st.command);
    }
    if (std.mem.eql(u8, args[i.*], "init")) {
        st.command = .init;
        i.* += 1;
        // `boris init [DIR]` — exactly one optional positional target
        // directory. A second positional is a usage error.
        if (i.* < args.len and !std.mem.startsWith(u8, args[i.*], "-")) {
            st.init_dir = args[i.*];
            i.* += 1;
        }
        if (i.* < args.len and !std.mem.startsWith(u8, args[i.*], "-")) return error.UnexpectedPositional;
        return;
    }
    if (std.mem.eql(u8, args[i.*], "standard-site")) {
        return parseStandardSiteFamily(args, i, st);
    }
}

fn parseNostrFamily(args: []const []const u8, i: *usize, command: *Command) ParseError!void {
    i.* += 1;
    if (i.* >= args.len) return error.UnknownNostrSubcommand;
    for (nostr_subcommands) |sub| {
        if (std.mem.eql(u8, args[i.*], sub.name)) {
            command.* = sub.command;
            i.* += 1;
            return;
        }
    }
    return error.UnknownNostrSubcommand;
}

fn parseStandardSiteFamily(args: []const []const u8, i: *usize, st: *ParseState) ParseError!void {
    st.command = .standard_site;
    i.* += 1;
    // The network family has explicit subcommands. A missing or unknown
    // subcommand is a usage error, never a silent fallback. `--help` /
    // `-h` here is family help (exit 0), not a missing subcommand.
    if (i.* >= args.len) return error.MissingStandardSiteSubcommand;
    const token = args[i.*];
    if (std.mem.eql(u8, token, "--help") or std.mem.eql(u8, token, "-h")) {
        // Leave the flag for the shared help short-circuit so exit 0
        // stays identical to every other `--help`.
    } else if (std.meta.stringToEnum(StandardSiteCommand, token)) |sub| {
        // The accepted spellings are exactly the enum's field names.
        st.standard_site_command = sub;
        i.* += 1;
    } else {
        return error.UnknownStandardSiteSubcommand;
    }
    if (i.* < args.len and !std.mem.startsWith(u8, args[i.*], "-")) return error.UnexpectedPositional;
}

/// `init [DIR]` and `impact <ID>` — the single positional may follow flags
/// (`boris init --quiet DIR`, `boris impact --quiet ID`); the prefix capture
/// handles the immediate-after-command form, this handles flags in between.
/// A second positional still falls through to UnexpectedPositional.
fn captureCommandPositional(st: *ParseState, a: []const u8) bool {
    if (st.command == .init and st.init_dir == null and !std.mem.startsWith(u8, a, "-")) {
        st.init_dir = a;
        return true;
    }
    if (st.command == .impact and st.impact_id == null and !std.mem.startsWith(u8, a, "-")) {
        st.impact_id = a;
        return true;
    }
    return false;
}

/// `--quiet` / `--timings`: global observation flags valid beside any
/// command or mode.
fn parseGlobalFlags(st: *ParseState, a: []const u8) ParseError!bool {
    if (std.mem.eql(u8, a, "--quiet")) {
        try markSaw(&st.saw_quiet);
        st.quiet = true;
        return true;
    }
    if (std.mem.eql(u8, a, "--timings")) {
        try markSaw(&st.saw_timings);
        return true;
    }
    return false;
}

/// `--profile` and the command-routed `--plan` (nostr sign/publish bundle
/// input vs standard-site publication plan; anywhere else a conflict).
fn parseProfileAndPlanFlags(
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    if (std.mem.eql(u8, a, "--profile") or std.mem.startsWith(u8, a, "--profile=")) {
        try markSaw(&st.saw_profile);
        st.profile_path = try takeValue(args, i, a, "--profile");
        return true;
    }

    if (std.mem.eql(u8, a, "--plan") or std.mem.startsWith(u8, a, "--plan=")) {
        // `--plan` is owned by the nostr sign/publish family (the
        // signed-bundle input) and the standard-site family (the
        // publication plan); anywhere else it is a conflict rather than
        // a silently accepted flag. The standard-site subcommand
        // validations below additionally reject it for smoke, login,
        // sessions, and logout.
        if (st.command == .nostr_sign or st.command == .nostr_publish) {
            try markSaw(&st.saw_nostr_plan);
            st.nostr_plan_path = try takeValue(args, i, a, "--plan");
        } else if (st.command == .standard_site) {
            try markSaw(&st.saw_plan_path);
            st.plan_path = try takeValue(args, i, a, "--plan");
        } else {
            return error.ConflictingFlags;
        }
        return true;
    }
    return false;
}

/// Nostr sign/publish family flags. Each is rejected outside its owning
/// subcommand rather than silently ignored.
fn parseNostrFlags(
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    if (std.mem.eql(u8, a, "--bundle") or std.mem.startsWith(u8, a, "--bundle=")) {
        if (st.command != .nostr_publish) return error.ConflictingFlags;
        try markSaw(&st.saw_nostr_bundle);
        st.nostr_bundle_path = try takeValue(args, i, a, "--bundle");
        return true;
    }

    if (std.mem.eql(u8, a, "--key-stdin")) {
        if (st.command != .nostr_sign) return error.ConflictingFlags;
        try markSaw(&st.saw_nostr_key_stdin);
        st.nostr_key_stdin = true;
        return true;
    }

    if (std.mem.eql(u8, a, "--prior") or std.mem.startsWith(u8, a, "--prior=")) {
        if (st.command != .nostr_sign) return error.ConflictingFlags;
        try markSaw(&st.saw_nostr_prior);
        st.nostr_prior_path = try takeValue(args, i, a, "--prior");
        return true;
    }

    if (std.mem.eql(u8, a, "--created-at") or std.mem.startsWith(u8, a, "--created-at=")) {
        if (st.command != .nostr_sign) return error.ConflictingFlags;
        try markSaw(&st.saw_nostr_created_at);
        const value = try takeValue(args, i, a, "--created-at");
        st.nostr_created_at = std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue;
        return true;
    }

    // `nostr sign` / `nostr publish` re-own `--out` as the artifact path;
    // every other command keeps the IR-directory meaning (and nostr_plan
    // rejects it).
    if ((st.command == .nostr_sign or st.command == .nostr_publish) and
        (std.mem.eql(u8, a, "--out") or std.mem.startsWith(u8, a, "--out=")))
    {
        try markSaw(&st.saw_nostr_out);
        st.nostr_out_path = try takeValue(args, i, a, "--out");
        return true;
    }
    return false;
}

/// `recipe-scale` family flags; `--out` is re-owned as a JSON file path.
fn parseRecipeScaleFlags(
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    if (st.command == .recipe_scale and
        (std.mem.eql(u8, a, "--out") or std.mem.startsWith(u8, a, "--out=")))
    {
        try markSaw(&st.saw_recipe_scale_out);
        st.recipe_scale_out = try takeValue(args, i, a, "--out");
        return true;
    }

    if (std.mem.eql(u8, a, "--id") or std.mem.startsWith(u8, a, "--id=")) {
        if (st.command != .recipe_scale) return error.ConflictingFlags;
        try markSaw(&st.saw_recipe_scale_id);
        st.recipe_scale_id = try takeValue(args, i, a, "--id");
        return true;
    }

    if (std.mem.eql(u8, a, "--factor") or std.mem.startsWith(u8, a, "--factor=")) {
        if (st.command != .recipe_scale) return error.ConflictingFlags;
        try markSaw(&st.saw_recipe_scale_factor);
        st.recipe_scale_factor = try takeValue(args, i, a, "--factor");
        return true;
    }

    if (std.mem.eql(u8, a, "--servings") or std.mem.startsWith(u8, a, "--servings=")) {
        if (st.command != .recipe_scale) return error.ConflictingFlags;
        try markSaw(&st.saw_recipe_scale_servings);
        st.recipe_scale_servings = try takeValue(args, i, a, "--servings");
        return true;
    }
    return false;
}

/// Projection/mode selectors: boolean switches from the table plus the
/// value-bearing `--port`.
fn parseModeFlags(
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    for (mode_bool_flags) |entry| {
        if (std.mem.eql(u8, a, entry.name)) {
            try applyModeBoolFlag(st, entry.flag);
            return true;
        }
    }

    if (std.mem.eql(u8, a, "--allow-markdown-links")) {
        // Idempotent by design: repeatable without a duplicate detector.
        st.allow_markdown_links = true;
        return true;
    }

    if (std.mem.eql(u8, a, "--port") or std.mem.startsWith(u8, a, "--port=")) {
        if (st.serve_port != null) return error.DuplicateFlag;
        const value = try takeValue(args, i, a, "--port");
        st.serve_port = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidValue;
        return true;
    }
    return false;
}

/// Analysis-command flags shared by `check` and `impact` (with `--report`
/// additionally meaningful on HTML build/validate).
fn parseAnalysisFlags(
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    if (std.mem.eql(u8, a, "--format") or std.mem.startsWith(u8, a, "--format=")) {
        try markSaw(&st.saw_format);
        const value = try takeValue(args, i, a, "--format");
        st.analysis_format = if (std.mem.eql(u8, value, "human"))
            .human
        else if (std.mem.eql(u8, value, "json"))
            .json
        else
            return error.InvalidValue;
        return true;
    }

    if (std.mem.eql(u8, a, "--report") or std.mem.startsWith(u8, a, "--report=")) {
        try markSaw(&st.saw_report);
        st.analysis_report = try takeValue(args, i, a, "--report");
        return true;
    }

    if (std.mem.eql(u8, a, "--fail-on-unreferenced")) {
        try markSaw(&st.saw_fail_on_unreferenced);
        st.fail_on_unreferenced = true;
        return true;
    }
    return false;
}

/// Target declarations and their deferred attachments (`--target`,
/// `--target-layout`, `--target-profile`, `--layout-rule`). Layouts,
/// profiles, and rules are collected first and joined to targets after the
/// loop, so flag order relative to `--target` does not matter.
fn parseTargetSpecs(
    gpa: std.mem.Allocator,
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    if (std.mem.eql(u8, a, "--target") or std.mem.startsWith(u8, a, "--target=")) {
        const val = try takeValue(args, i, a, "--target");
        const eq_idx = std.mem.indexOfScalar(u8, val, '=') orelse {
            return error.InvalidValue;
        };
        const name = val[0..eq_idx];
        const output_dir = val[eq_idx + 1 ..];
        if (name.len == 0 or output_dir.len == 0) {
            return error.InvalidValue;
        }
        if (!target_mod.isValidTargetName(name)) {
            return error.InvalidValue;
        }
        for (st.targets.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                return error.DuplicateFlag;
            }
        }
        try st.targets.append(gpa, .{
            .name = name,
            .output_dir = output_dir,
            .layout_path = null,
        });
        return true;
    }

    if (std.mem.eql(u8, a, "--target-layout") or std.mem.startsWith(u8, a, "--target-layout=")) {
        const val = try takeValue(args, i, a, "--target-layout");
        const eq_idx = std.mem.indexOfScalar(u8, val, '=') orelse {
            return error.InvalidValue;
        };
        const name = val[0..eq_idx];
        const path = val[eq_idx + 1 ..];
        if (name.len == 0 or path.len == 0) {
            return error.InvalidValue;
        }
        if (!target_mod.isValidTargetName(name)) {
            return error.InvalidValue;
        }
        layout_select.validateLayoutPath(path) catch return error.InvalidValue;
        for (st.target_layouts.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                return error.DuplicateFlag;
            }
        }
        try st.target_layouts.append(gpa, .{ .name = name, .path = path });
        return true;
    }

    // --target-profile NAME=PROFILE (html|xhtml), applied after targets are
    // known. Mirrors --target-layout; the profile is a serialization switch
    // (#448) and composes with layout/rule selection.
    if (std.mem.eql(u8, a, "--target-profile") or std.mem.startsWith(u8, a, "--target-profile=")) {
        const val = try takeValue(args, i, a, "--target-profile");
        const eq_idx = std.mem.indexOfScalar(u8, val, '=') orelse {
            return error.InvalidValue;
        };
        const name = val[0..eq_idx];
        const profile_raw = val[eq_idx + 1 ..];
        if (name.len == 0 or profile_raw.len == 0) return error.InvalidValue;
        if (!target_mod.isValidTargetName(name)) return error.InvalidValue;
        const profile: render.OutputProfile = if (std.mem.eql(u8, profile_raw, "html"))
            .html
        else if (std.mem.eql(u8, profile_raw, "xhtml"))
            .xhtml
        else
            return error.InvalidValue;
        for (st.target_profiles.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                return error.DuplicateFlag;
            }
        }
        try st.target_profiles.append(gpa, .{ .name = name, .profile = profile });
        return true;
    }

    // --layout-rule TARGET SELECTOR LAYOUT_PATH (exactly three following args).
    if (std.mem.eql(u8, a, "--layout-rule") or std.mem.startsWith(u8, a, "--layout-rule=")) {
        if (std.mem.startsWith(u8, a, "--layout-rule=")) return error.InvalidValue;
        if (i.* + 3 >= args.len) return error.MissingValue;
        const tname = args[i.* + 1];
        const selector = args[i.* + 2];
        const path = args[i.* + 3];
        if (tname.len == 0 or selector.len == 0 or path.len == 0) return error.EmptyValue;
        if (!target_mod.isValidTargetName(tname)) return error.InvalidValue;
        // Reject values that look like flags (prevent silent arg shift).
        if (tname[0] == '-' or selector[0] == '-' or path[0] == '-') return error.InvalidValue;
        // Validate selector grammar early (fail before discovery).
        _ = layout_select.parseSelector(selector) catch return error.InvalidValue;
        layout_select.validateLayoutPath(path) catch return error.InvalidValue;
        try st.pending_rules.append(gpa, .{ .target = tname, .selector = selector, .path = path });
        i.* += 3;
        return true;
    }
    return false;
}

/// Session and credential flags for the `standard-site` family.
/// Canonical dashed spelling of a standard-site session-family flag, if `a`
/// is one (`--flag` or `--flag=value` form). The family is rejected outside
/// `standard-site` rather than silently ignored (#872).
fn sessionFlagName(a: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, a, "--prune")) return "--prune";
    if (std.mem.eql(u8, a, "--app-password")) return "--app-password";
    const valued = [_][]const u8{
        "--source-commit",
        "--did",
        "--handle",
        "--session-root",
        "--dist",
        "--namespace",
        "--surface-url",
        "--indexer",
    };
    for (valued) |name| {
        if (std.mem.eql(u8, a, name)) return name;
        if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=') return name;
    }
    return null;
}

fn parseSessionFlags(
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    // Session-family flags belong to `standard-site` only. Reject them
    // anywhere else rather than parsing and silently ignoring them (#872).
    if (sessionFlagName(a)) |flag| {
        if (st.command != .standard_site) return failConflict(st, commandWord(st.command), flag);
    }
    if (std.mem.eql(u8, a, "--prune")) {
        if (st.publish_prune) return error.DuplicateFlag;
        st.publish_prune = true;
        return true;
    }

    if (std.mem.eql(u8, a, "--source-commit") or std.mem.startsWith(u8, a, "--source-commit=")) {
        try markSaw(&st.saw_source_commit);
        st.source_commit = try takeValue(args, i, a, "--source-commit");
        return true;
    }

    if (std.mem.eql(u8, a, "--did") or std.mem.startsWith(u8, a, "--did=")) {
        try markSaw(&st.saw_session_did);
        st.session_did = try takeValue(args, i, a, "--did");
        return true;
    }

    if (std.mem.eql(u8, a, "--handle") or std.mem.startsWith(u8, a, "--handle=")) {
        try markSaw(&st.saw_session_handle);
        st.session_handle = try takeValue(args, i, a, "--handle");
        return true;
    }

    if (std.mem.eql(u8, a, "--app-password")) {
        try markSaw(&st.saw_app_password);
        st.app_password = true;
        return true;
    }

    if (std.mem.eql(u8, a, "--session-root") or std.mem.startsWith(u8, a, "--session-root=")) {
        try markSaw(&st.saw_session_root);
        st.session_root = try takeValue(args, i, a, "--session-root");
        return true;
    }

    if (std.mem.eql(u8, a, "--dist") or std.mem.startsWith(u8, a, "--dist=")) {
        try markSaw(&st.saw_verify_dist);
        st.verify_dist = try takeValue(args, i, a, "--dist");
        return true;
    }

    if (std.mem.eql(u8, a, "--namespace") or std.mem.startsWith(u8, a, "--namespace=")) {
        try markSaw(&st.saw_smoke_namespace);
        st.smoke_namespace = try takeValue(args, i, a, "--namespace");
        return true;
    }

    if (std.mem.eql(u8, a, "--surface-url") or std.mem.startsWith(u8, a, "--surface-url=")) {
        try markSaw(&st.saw_smoke_surface_url);
        st.smoke_surface_url = try takeValue(args, i, a, "--surface-url");
        return true;
    }

    if (std.mem.eql(u8, a, "--indexer") or std.mem.startsWith(u8, a, "--indexer=")) {
        try markSaw(&st.saw_smoke_indexer_origin);
        st.smoke_indexer_origin = try takeValue(args, i, a, "--indexer");
        return true;
    }
    return false;
}

/// Source tree, projection directories, and publication identity flags.
fn parsePathFlags(
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    if (std.mem.eql(u8, a, "--input") or std.mem.startsWith(u8, a, "--input=")) {
        try markSaw(&st.saw_input);
        st.input_dir = try takeValue(args, i, a, "--input");
        return true;
    }

    if (std.mem.eql(u8, a, "--out") or std.mem.startsWith(u8, a, "--out=")) {
        try markSaw(&st.saw_out);
        st.out_dir = try takeValue(args, i, a, "--out");
        return true;
    }

    if (std.mem.eql(u8, a, "--rag-dir") or std.mem.startsWith(u8, a, "--rag-dir=")) {
        try markSaw(&st.saw_rag_dir);
        st.rag_dir = try takeValue(args, i, a, "--rag-dir");
        return true;
    }

    if (std.mem.eql(u8, a, "--context-dir") or std.mem.startsWith(u8, a, "--context-dir=")) {
        try markSaw(&st.saw_context_dir);
        st.context_dir = try takeValue(args, i, a, "--context-dir");
        return true;
    }

    if (std.mem.eql(u8, a, "--scope") or std.mem.startsWith(u8, a, "--scope=")) {
        try markSaw(&st.saw_scope);
        st.scope = try takeValue(args, i, a, "--scope");
        return true;
    }

    if (std.mem.eql(u8, a, "--split-size") or std.mem.startsWith(u8, a, "--split-size=")) {
        try markSaw(&st.saw_split_size);
        const raw = try takeValue(args, i, a, "--split-size");
        const parsed = std.fmt.parseInt(usize, raw, 10) catch return error.InvalidValue;
        if (parsed == 0) return error.InvalidValue;
        st.split_size = parsed;
        return true;
    }

    if (std.mem.eql(u8, a, "--llms-path") or std.mem.startsWith(u8, a, "--llms-path=")) {
        try markSaw(&st.saw_llms_path);
        st.llms_path = try takeValue(args, i, a, "--llms-path");
        if (std.fs.path.isAbsolute(st.llms_path)) return error.InvalidValue;
        return true;
    }

    if (std.mem.eql(u8, a, "--rss-path") or std.mem.startsWith(u8, a, "--rss-path=")) {
        try markSaw(&st.saw_rss_path);
        st.rss_path = try takeValue(args, i, a, "--rss-path");
        if (std.fs.path.isAbsolute(st.rss_path)) return error.InvalidValue;
        return true;
    }

    if (std.mem.eql(u8, a, "--sitemap-path") or std.mem.startsWith(u8, a, "--sitemap-path=")) {
        try markSaw(&st.saw_sitemap_path);
        st.sitemap_path = try takeValue(args, i, a, "--sitemap-path");
        sitemap.validateOutputPath(st.sitemap_path) catch return error.InvalidValue;
        return true;
    }

    if (std.mem.eql(u8, a, "--static-dir") or std.mem.startsWith(u8, a, "--static-dir=")) {
        try markSaw(&st.saw_static_dir);
        st.static_dir = try takeValue(args, i, a, "--static-dir");
        if (st.static_dir.?.len == 0) return failInvalidValue(st, "--static-dir", "directory path is empty");
        return true;
    }

    if (std.mem.eql(u8, a, "--site-url") or std.mem.startsWith(u8, a, "--site-url=")) {
        try markSaw(&st.saw_site_url);
        st.site_url = try takeValue(args, i, a, "--site-url");
        return true;
    }

    if (std.mem.eql(u8, a, "--pages-base-url") or std.mem.startsWith(u8, a, "--pages-base-url=")) {
        try markSaw(&st.saw_pages_base_url);
        st.pages_base_url = try takeValue(args, i, a, "--pages-base-url");
        return true;
    }

    if (std.mem.eql(u8, a, "--pages-origin") or std.mem.startsWith(u8, a, "--pages-origin=")) {
        try markSaw(&st.saw_pages_origin);
        st.pages_origin = try takeValue(args, i, a, "--pages-origin");
        return true;
    }

    if (std.mem.eql(u8, a, "--pages-base-path") or std.mem.startsWith(u8, a, "--pages-base-path=")) {
        try markSaw(&st.saw_pages_base_path);
        st.pages_base_path = try takeValueAllowEmpty(args, i, a, "--pages-base-path");
        return true;
    }

    if (std.mem.eql(u8, a, "--rss-title") or std.mem.startsWith(u8, a, "--rss-title=")) {
        try markSaw(&st.saw_rss_title);
        st.rss_title = try takeValue(args, i, a, "--rss-title");
        return true;
    }

    if (std.mem.eql(u8, a, "--rss-description") or std.mem.startsWith(u8, a, "--rss-description=")) {
        try markSaw(&st.saw_rss_description);
        st.rss_description = try takeValue(args, i, a, "--rss-description");
        return true;
    }

    if (std.mem.eql(u8, a, "--rss-limit") or std.mem.startsWith(u8, a, "--rss-limit=")) {
        try markSaw(&st.saw_rss_limit);
        st.rss_limit = std.fmt.parseInt(usize, try takeValue(args, i, a, "--rss-limit"), 10) catch return error.InvalidRssLimit;
        if (st.rss_limit < 1 or st.rss_limit > 500) return error.InvalidRssLimit;
        return true;
    }
    return false;
}

/// HTML rendering controls: worker count, output directory, layout/theme
/// selection.
fn parseHtmlFlags(
    st: *ParseState,
    a: []const u8,
    args: []const []const u8,
    i: *usize,
) ParseError!bool {
    if (std.mem.eql(u8, a, "--jobs") or std.mem.startsWith(u8, a, "--jobs=") or
        std.mem.eql(u8, a, "-j") or std.mem.startsWith(u8, a, "-j="))
    {
        try markSaw(&st.saw_jobs);
        const val_str = if (std.mem.startsWith(u8, a, "-j"))
            try takeValue(args, i, a, "-j")
        else
            try takeValue(args, i, a, "--jobs");
        const parsed_val = std.fmt.parseInt(usize, val_str, 10) catch {
            return error.InvalidValue;
        };
        if (parsed_val < 1 or parsed_val > 64) {
            return error.InvalidValue;
        }
        st.jobs = parsed_val;
        return true;
    }

    if (std.mem.eql(u8, a, "--html-dir") or std.mem.startsWith(u8, a, "--html-dir=")) {
        try markSaw(&st.saw_html_dir);
        st.html_dir = try takeValue(args, i, a, "--html-dir");
        return true;
    }

    if (std.mem.eql(u8, a, "--html-layout") or std.mem.startsWith(u8, a, "--html-layout=")) {
        try markSaw(&st.saw_html_layout);
        st.html_layout = try takeValue(args, i, a, "--html-layout");
        layout_select.validateLayoutPath(st.html_layout) catch
            return failInvalidValue(st, "--html-layout", layout_path_hint);
        return true;
    }

    // F9.1: --theme ROOT is sugar for --html-layout ROOT/layouts/main.html
    // (theme asset root is derived from the layout path at compile time).
    if (std.mem.eql(u8, a, "--theme") or std.mem.startsWith(u8, a, "--theme=")) {
        try markSaw(&st.saw_theme);
        st.theme_root = try takeValue(args, i, a, "--theme");
        // Theme root uses the same no-escape relative path grammar; the
        // synthesized layout path is validated after composition below.
        // Blame this flag, not the first value-taking flag findBadArg scans
        // (#761): an out-of-workspace theme root previously surfaced as
        // "invalid value for --input".
        layout_select.validateLayoutPath(st.theme_root.?) catch
            return failInvalidValue(st, "--theme", layout_path_hint);
        return true;
    }
    return false;
}

/// Resolve --theme sugar before mode selection (implies HTML layout path).
fn resolveThemeSugar(gpa: std.mem.Allocator, st: *ParseState) ParseError!void {
    if (st.theme_root) |tr| {
        if (tr.len == 0) return error.EmptyValue;
        if (st.saw_html_layout) return failConflict(st, "--theme", "--html-layout");
        // Joined path is owned by Options (freed in deinit).
        st.html_layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{tr});
        st.owned_html_layout = true;
        st.saw_html_layout = true;
        layout_select.validateLayoutPath(st.html_layout) catch {
            gpa.free(st.html_layout);
            st.owned_html_layout = false;
            return failInvalidValue(st, "--theme", layout_path_hint);
        };
    }
}

fn buildPlanOptions(st: *ParseState) ParseError!Options {
    if (st.profile_path == null) return error.MissingValue;
    // The plan command has one publication identity boundary: profile
    // input, input format, and the single-target HTML output override.
    // Other projection selectors would either execute or invent a second
    // configuration source, so keep them as usage errors.
    // `--timings` is rejected here too: `plan` owns stdout for its single
    // declaration JSON document, and it runs no compiler phase, so the
    // machine-readable timing report has nowhere to go without corrupting
    // the plan stream.
    if (st.saw_html or st.hasExplicitTargets() or st.saw_html_layout or st.saw_theme or st.hasTargetLayouts() or st.hasTargetProfiles() or st.hasLayoutRules() or st.wantsSitemap() or st.wantsStatic() or
        st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss() or st.saw_site_url or st.sawPagesLocation() or st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or
        st.saw_format or st.saw_report or st.saw_watch or st.saw_timings)
    {
        return error.ConflictingFlags;
    }
    return .{
        .help = false,
        .quiet = st.quiet,
        .timings = st.saw_timings,
        .command = .plan,
        .profile_path = st.profile_path,
        .profile_input_override = if (st.saw_input) st.input_dir else null,
        .profile_input_format_override = if (st.saw_textile or st.saw_cooklang) st.inputFormat() else null,
        .profile_html_output_override = if (st.saw_html_dir) st.html_dir else null,
        .mode = .html,
        .input_format = st.inputFormat(),
        .input_dir = st.input_dir,
        .html_dir = if (st.saw_html_dir) st.html_dir else null,
        .incremental = st.saw_incremental,
        .jobs = st.jobs,
        .targets = st.targets,
    };
}

fn buildNostrPlanOptions(st: *ParseState) ParseError!Options {
    if (st.profile_path == null) return error.MissingValue;
    // Same boundary as `plan`, and for the same reason: the profile is the
    // only configuration source. This command does scan content, so
    // `--input`/`--cooklang`/`--textile` overrides stay meaningful, but
    // stdout belongs to the single plan document — hence no `--timings`.
    // Name the `--out` pair explicitly: it implies IR via wantsIr(), which
    // would steal the plan's stdout (#905).
    if (st.saw_out) return failConflict(st, commandWord(st.command), "--out");
    if (st.saw_html or st.hasExplicitTargets() or st.saw_html_layout or st.saw_theme or st.hasTargetLayouts() or st.hasLayoutRules() or st.wantsSitemap() or st.wantsStatic() or
        st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss() or st.saw_site_url or st.sawPagesLocation() or st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or
        st.saw_format or st.saw_report or st.saw_watch or st.saw_timings or st.saw_html_dir or st.saw_incremental or st.saw_refresh_evidence)
    {
        return error.ConflictingFlags;
    }
    return .{
        .help = false,
        .quiet = st.quiet,
        .timings = false,
        .command = .nostr_plan,
        .profile_path = st.profile_path,
        .profile_input_override = if (st.saw_input) st.input_dir else null,
        .profile_input_format_override = if (st.saw_textile or st.saw_cooklang) st.inputFormat() else null,
        .mode = .html,
        .input_format = st.inputFormat(),
        .input_dir = st.input_dir,
        .jobs = st.jobs,
        .targets = st.targets,
    };
}

fn buildNostrSignOptions(st: *ParseState) ParseError!Options {
    // The signer consumes a plan artifact and a secret key read once from
    // stdin. The profile is configuration, not input, for signing; every
    // other selector either executes another projection or implies state
    // the signer does not have. `--timings` is rejected because stdout is
    // reserved for the signed-event bundle when --out is absent.
    if (st.nostr_plan_path == null) return error.MissingValue;
    if (!st.nostr_key_stdin) return error.MissingValue;
    if (st.saw_profile or st.saw_html or st.hasExplicitTargets() or st.saw_html_layout or st.saw_theme or st.hasTargetLayouts() or st.hasTargetProfiles() or st.hasLayoutRules() or st.wantsSitemap() or st.wantsStatic() or
        st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss() or st.saw_site_url or st.sawPagesLocation() or st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or
        st.saw_format or st.saw_report or st.saw_watch or st.saw_timings or st.saw_html_dir or st.saw_incremental or st.saw_refresh_evidence or st.saw_jobs)
    {
        return error.ConflictingFlags;
    }
    return .{
        .help = false,
        .quiet = st.quiet,
        .timings = false,
        .command = .nostr_sign,
        .nostr_plan_path = st.nostr_plan_path,
        .nostr_key_stdin = st.nostr_key_stdin,
        .nostr_out_path = st.nostr_out_path,
        .nostr_prior_path = st.nostr_prior_path,
        .nostr_created_at = st.nostr_created_at,
        .mode = .html,
        .input_format = st.inputFormat(),
        .input_dir = st.input_dir,
        .out_dir = null,
        .html_dir = null,
        .targets = st.targets,
    };
}

fn buildNostrPublishOptions(st: *ParseState) ParseError!Options {
    // The publisher consumes a plan artifact and its already-signed event
    // bundle. The secret never enters this command: the bundle was signed
    // offline by `nostr sign`, and publishing only re-transmits it. Like
    // the other nostr subcommands, no profile or projection selector is
    // meaningful here, and stdout is reserved for the report when --out is
    // absent.
    if (st.nostr_plan_path == null) return error.MissingValue;
    if (st.nostr_bundle_path == null) return error.MissingValue;
    if (st.saw_profile or st.saw_html or st.hasExplicitTargets() or st.saw_html_layout or st.saw_theme or st.hasTargetLayouts() or st.hasTargetProfiles() or st.hasLayoutRules() or st.wantsSitemap() or st.wantsStatic() or
        st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss() or st.saw_site_url or st.sawPagesLocation() or st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or
        st.saw_format or st.saw_report or st.saw_watch or st.saw_timings or st.saw_html_dir or st.saw_incremental or st.saw_refresh_evidence or st.saw_jobs)
    {
        return error.ConflictingFlags;
    }
    return .{
        .help = false,
        .quiet = st.quiet,
        .timings = false,
        .command = .nostr_publish,
        .nostr_plan_path = st.nostr_plan_path,
        .nostr_bundle_path = st.nostr_bundle_path,
        .nostr_out_path = st.nostr_out_path,
        .mode = .html,
        .input_format = st.inputFormat(),
        .input_dir = st.input_dir,
        .out_dir = null,
        .html_dir = null,
        .targets = st.targets,
    };
}

fn buildInitOptions(st: *ParseState) ParseError!Options {
    // `init` writes a deterministic starter tree into one positional
    // target directory. Compiler modes, output selectors, publication
    // inputs, analysis flags, and watch/incremental controls select work
    // init does not perform; the target directory is positional, so
    // `--input` is rejected rather than silently misread.
    if (st.saw_html or st.saw_html_dir or st.hasExplicitTargets() or st.saw_html_layout or st.saw_theme or st.hasTargetLayouts() or st.hasTargetProfiles() or st.hasLayoutRules() or
        st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss() or st.saw_site_url or st.sawPagesLocation() or
        st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or st.saw_format or st.saw_report or st.saw_watch or st.saw_timings or
        st.saw_profile or st.saw_input or st.saw_textile or st.saw_cooklang or st.saw_out or st.saw_rag_dir or st.saw_incremental or st.saw_refresh_evidence or st.saw_jobs or st.saw_static_dir)
    {
        return error.ConflictingFlags;
    }
    return .{
        .help = false,
        .quiet = st.quiet,
        .timings = false,
        .command = .init,
        .init_dir = st.init_dir,
        .mode = .html,
        .input_format = identity.InputFormat.markdown,
        .input_dir = "content",
        .out_dir = null,
        .html_dir = null,
        .targets = st.targets,
    };
}

fn buildRecipeScaleOptions(st: *ParseState) ParseError!Options {
    if (st.recipe_scale_id == null) return error.MissingValue;
    const has_factor = st.recipe_scale_factor != null;
    const has_servings = st.recipe_scale_servings != null;
    if (has_factor and has_servings) return error.ConflictingFlags;
    if (!has_factor and !has_servings) return error.MissingValue;
    if (has_factor) _ = recipe_scale.parseFactor(st.recipe_scale_factor.?) catch return error.InvalidValue;
    if (has_servings) _ = recipe_scale.parseServingsTarget(st.recipe_scale_servings.?) catch return error.InvalidValue;
    // The view owns stdout. Projection selectors, watch/HTML, analysis,
    // and `--timings` would either execute another path or corrupt the
    // JSON stream.
    if (st.saw_html or st.hasExplicitTargets() or st.saw_html_layout or st.saw_theme or st.hasTargetLayouts() or st.hasTargetProfiles() or st.hasLayoutRules() or st.wantsSitemap() or st.wantsStatic() or
        st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss() or st.saw_site_url or st.sawPagesLocation() or st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or
        st.saw_format or st.saw_report or st.saw_watch or st.saw_timings or st.saw_html_dir or st.saw_incremental or st.saw_refresh_evidence or st.saw_jobs or st.saw_profile)
    {
        return error.ConflictingFlags;
    }
    return .{
        .help = false,
        .quiet = st.quiet,
        .timings = false,
        .command = .recipe_scale,
        .recipe_scale_id = st.recipe_scale_id,
        .recipe_scale_factor = st.recipe_scale_factor,
        .recipe_scale_servings = st.recipe_scale_servings,
        .recipe_scale_out = st.recipe_scale_out,
        .mode = .html,
        .input_format = st.inputFormat(),
        .input_dir = st.input_dir,
        .out_dir = null,
        .html_dir = null,
        .targets = st.targets,
    };
}

fn buildStandardSiteOptions(st: *ParseState) ParseError!Options {
    // The `standard-site` family is the one-shot network family: publish,
    // login, sessions, and logout. Compiler modes, targets, and projection
    // selectors have no meaning here, and `--timings` must not corrupt the
    // evidence stream on stdout. `publish` requires a profile and forbids
    // `--did`; `login`/`logout`/`smoke` require `--did` or `--handle`;
    // `sessions` forbids both.
    if (st.saw_html or st.saw_html_dir or st.hasExplicitTargets() or st.saw_html_layout or st.saw_theme or st.hasTargetLayouts() or st.hasLayoutRules() or
        st.wantsStatic() or st.wantsSitemap() or st.wantsRag() or st.saw_no_rag or st.wantsContext() or st.wantsLlms() or st.wantsRss() or st.saw_site_url or st.sawPagesLocation() or
        st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or st.saw_format or st.saw_report or st.saw_watch or st.saw_timings or
        st.saw_input or st.saw_textile or st.saw_cooklang or st.saw_rag_dir or st.saw_scope or st.saw_split_size or st.saw_bundles_only or st.saw_complete or
        st.saw_incremental or st.saw_refresh_evidence or st.saw_jobs or st.saw_llms_path or st.saw_rss_path or st.saw_sitemap_path or st.saw_context_dir)
    {
        return error.ConflictingStandardSiteFlags;
    }
    // Smoke-only and verify-only flags have no meaning on the other
    // subcommands; reject them rather than silently ignoring them.
    const saw_smoke_only = st.saw_smoke_namespace or st.saw_smoke_surface_url or st.saw_smoke_indexer_origin;
    switch (st.standard_site_command) {
        .publish => {
            if (st.profile_path == null) return error.MissingStandardSiteProfile;
            if (st.saw_session_did or st.saw_session_handle or st.saw_app_password or saw_smoke_only or st.saw_verify_dist) return error.ConflictingStandardSiteFlags;
        },
        .plan => {
            if (st.profile_path == null) return error.MissingStandardSiteProfile;
            if (st.saw_session_did or st.saw_session_handle or st.saw_app_password or saw_smoke_only or st.saw_verify_dist or st.saw_plan_path or st.publish_prune or st.saw_source_commit) return error.ConflictingStandardSiteFlags;
        },
        .records => {
            if (st.profile_path == null) return error.MissingStandardSiteProfile;
            if (st.saw_session_did or st.saw_session_handle or st.saw_app_password or saw_smoke_only or st.saw_verify_dist or st.saw_plan_path or st.publish_prune or st.saw_source_commit) return error.ConflictingStandardSiteFlags;
        },
        .verify => {
            if (st.profile_path == null) return error.MissingStandardSiteProfile;
            if (st.saw_session_did or st.saw_session_handle or st.saw_app_password or saw_smoke_only or st.saw_plan_path or st.publish_prune or st.saw_source_commit) return error.ConflictingStandardSiteFlags;
        },
        .login => {
            if (st.profile_path != null or st.saw_plan_path or st.publish_prune or st.saw_source_commit or st.saw_out or saw_smoke_only or st.saw_verify_dist) return error.ConflictingStandardSiteFlags;
            if (st.app_password) {
                // App-password login takes exactly one identity: a DID or
                // a handle (resolved to a DID).
                if (st.session_did == null and st.session_handle == null) return error.MissingStandardSiteIdentity;
                if (st.session_did != null and st.session_handle != null) return error.ConflictingStandardSiteFlags;
            } else {
                if (st.session_did == null) return error.MissingStandardSiteIdentity;
                if (st.session_handle != null) return error.ConflictingStandardSiteFlags;
            }
        },
        .logout => {
            if (st.session_did == null and st.session_handle == null) return error.MissingStandardSiteIdentity;
            if (st.session_did != null and st.session_handle != null) return error.ConflictingStandardSiteFlags;
            if (st.app_password or st.profile_path != null or st.saw_plan_path or st.publish_prune or st.saw_source_commit or st.saw_out or saw_smoke_only or st.saw_verify_dist) return error.ConflictingStandardSiteFlags;
        },
        .sessions => {
            if (st.saw_session_did or st.saw_session_handle or st.saw_app_password or st.profile_path != null or st.saw_plan_path or st.publish_prune or st.saw_source_commit or st.saw_out or saw_smoke_only or st.saw_verify_dist) return error.ConflictingStandardSiteFlags;
        },
        .smoke => {
            if (st.session_did == null and st.session_handle == null) return error.MissingStandardSiteIdentity;
            if (st.session_did != null and st.session_handle != null) return error.ConflictingStandardSiteFlags;
            if (st.saw_app_password or st.profile_path != null or st.saw_plan_path or st.publish_prune or st.saw_source_commit or st.saw_verify_dist) return error.ConflictingStandardSiteFlags;
        },
    }
    return .{
        .help = false,
        .quiet = st.quiet,
        .timings = false,
        .command = .standard_site,
        .standard_site_command = st.standard_site_command,
        .standard_site_publish = st.standard_site_command == .publish,
        .plan_path = st.plan_path,
        .publish_out = if (st.saw_out) st.out_dir else null,
        .plan_out = if (st.saw_out) st.out_dir else null,
        .records_out = if (st.saw_out) st.out_dir else null,
        .verify_out = if (st.saw_out) st.out_dir else null,
        .verify_dist = st.verify_dist orelse "dist",
        .publish_prune = st.publish_prune,
        .source_commit = st.source_commit,
        .session_did = st.session_did,
        .session_handle = st.session_handle,
        .app_password = st.app_password,
        .session_root = st.session_root,
        .smoke_namespace = st.smoke_namespace,
        .smoke_surface_url = st.smoke_surface_url,
        .smoke_indexer_origin = st.smoke_indexer_origin,
        .smoke_out = if (st.saw_out) st.out_dir else null,
        .profile_path = st.profile_path,
        .mode = .html,
        .input_format = identity.InputFormat.markdown,
        .input_dir = st.input_dir,
        .out_dir = null,
        .html_dir = null,
        .targets = st.targets,
    };
}

/// Command-shape conflicts for the compiler-facing commands that share the
/// mode-selection tail (`build`, `validate`, `check`, `impact`, `watch`).
/// Per-family validation lives with each command's builder above.
fn validateBuildConflicts(st: *ParseState) ParseError!void {
    // `--profile` on the HTML build is the Standard.site verification-emit
    // opt-in (#533) and the Nostr `nostr:naddr` alternate-link emit (#571).
    // Other modes already have their own profile commands (`plan`,
    // `standard-site *`, `nostr plan`) or do not emit surfaces.
    if (st.saw_profile) {
        if (st.command == .watch or st.saw_watch or st.command == .validate or
            st.command == .check or st.command == .impact or
            st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss())
        {
            return error.ConflictingFlags;
        }
    }
    if (st.saw_fail_on_unreferenced and st.command != .check) return error.ConflictingFlags;

    if (st.command == .validate) {
        // Validation is the no-publication form of the selected HTML source /
        // target compiler path. Export selectors, output-bearing analysis,
        // cache behavior, and rendering worker controls would either
        // select another projection or imply filesystem state.
        if (st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss() or
            st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or st.saw_scope or
            st.saw_split_size or st.saw_bundles_only or st.saw_incremental or st.saw_refresh_evidence or st.saw_jobs or
            st.saw_format)
        {
            return error.ConflictingFlags;
        }
    }

    // `validate --watch` is the zero-write validation daemon (#647): it emits
    // only the optional `--report` file and the `--watch-json` event stream,
    // so explicit output/selection flags that imply filesystem state are usage
    // errors (exit 2) instead of silently selecting nothing.
    if (st.command == .validate and st.saw_watch and
        (st.saw_html_dir or st.hasExplicitTargets() or st.saw_serve or st.serve_port != null))
    {
        return error.ConflictingFlags;
    }

    if (st.command == .check or st.command == .impact) {
        // Analyzer commands never render, so every HTML selector is a
        // conflict; name the offending pair instead of the generic text
        // (#764). The remaining non-HTML projections keep the generic form.
        if (htmlSelectorToken(st)) |selector| {
            return failConflict(st, if (st.command == .check) "check" else "impact", selector);
        }
        if (st.wantsRag() or st.wantsIr() or st.wantsContext() or st.wantsLlms() or st.wantsRss() or st.saw_site_url or st.sawPagesLocation() or st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit or st.saw_jobs or st.saw_watch or st.saw_incremental or st.saw_refresh_evidence) {
            return error.ConflictingFlags;
        }
    } else if (st.command == .build and st.saw_format) {
        return error.ConflictingFlags;
    } else if (st.command == .watch and (st.saw_format or st.saw_report)) {
        return error.ConflictingFlags;
    }

    // The preview server is a watch-mode surface (`boris watch --serve`).
    if ((st.saw_serve or st.serve_port != null) and !st.saw_watch) return error.ConflictingFlags;

    // `--watch-json` is the watch daemon's machine-readable stderr stream; on
    // any other command it would silently produce an empty contract.
    if (st.saw_watch_json and !st.saw_watch) return error.ConflictingFlags;

    try validateProjectionConflicts(st);
}

/// The cross-projection conflict matrix: at most one output projection may
/// be selected, and each projection's companion options must stay with it.
fn validateProjectionConflicts(st: *ParseState) ParseError!void {
    const wants_rag = st.wantsRag();
    const wants_context = st.wantsContext();
    const wants_ir = st.wantsIr();
    const wants_llms = st.wantsLlms();
    const wants_rss = st.wantsRss();
    const wants_sitemap = st.wantsSitemap();
    const explicit_html = st.explicitHtml();
    const saw_pages_location = st.sawPagesLocation();

    if (st.saw_rag and st.saw_no_rag) return failConflict(st, "--rag", "--no-rag");
    if (st.saw_no_rag and st.saw_rag_dir) return failConflict(st, "--no-rag", "--rag-dir");
    // Explicit --out must never be combined with RAG-only selection.
    if (st.saw_out and wants_rag) {
        return failConflict(st, "--out", if (st.saw_rag_dir) "--rag-dir" else "--rag");
    }
    if (wants_context and (wants_rag or wants_ir)) return error.ConflictingFlags;
    if ((st.saw_scope or st.saw_split_size) and !(wants_rag or wants_context)) return error.ConflictingFlags;
    if (st.bundles_only and !wants_rag) return error.ConflictingFlags;
    // Complete-corpus RAG is RAG-only and owns the tree shape; the working
    // pack target and bundle-style flags belong to the default working mode.
    // A complete export is the entire validated corpus, so a scope projection
    // is a usage error rather than a silent partial export.
    if (st.saw_complete and !wants_rag) return error.ConflictingFlags;
    if (st.saw_complete and st.saw_scope) return error.ConflictingFlags;
    if (st.saw_complete and (st.saw_split_size or st.saw_bundles_only)) return error.ConflictingFlags;
    if (wants_llms and (wants_rag or wants_ir or wants_context or wants_rss or explicit_html)) return error.ConflictingFlags;
    if (wants_rss and (wants_rag or wants_ir or wants_context or explicit_html)) return error.ConflictingFlags;
    if (saw_pages_location and (wants_rag or wants_ir or wants_context)) return error.ConflictingFlags;
    if ((st.saw_rss_title or st.saw_rss_description or st.saw_rss_limit) and !wants_rss) return error.ConflictingFlags;
    if (st.saw_site_url and !(wants_rss or wants_sitemap)) return failConflict(st, "--site-url", "--rss/--sitemap");
    if (wants_rss and (st.site_url == null or st.rss_title == null or st.rss_description == null)) return error.RSSMetadataRequired;
    if (wants_sitemap and st.site_url == null) return error.SitemapSiteUrlRequired;
    if (wants_sitemap and (wants_rag or wants_ir or wants_context or wants_llms or wants_rss)) return error.ConflictingFlags;
    // Static passthrough is an HTML-target projection (#804): it must not
    // select a machine projection and applies to exactly one target.
    const wants_static = st.wantsStatic();
    if (wants_static and (wants_rag or wants_ir or wants_context or wants_llms or wants_rss)) return error.ConflictingFlags;
    if (wants_static and st.targets.items.len > 1) return error.ConflictingFlags;
    // Explicit HTML selectors own the output destination; refuse IR/RAG flags.
    // When explicit --out is the collision, name the pair (#764).
    if (explicit_html and (wants_rag or wants_context or st.saw_out)) {
        if (st.saw_out) {
            if (htmlSelectorToken(st)) |selector| return failConflict(st, selector, "--out");
        }
        return error.ConflictingFlags;
    }
    // HTML-only options conflict with IR or RAG selection (default HTML is fine).
    if ((st.saw_jobs or st.saw_watch or st.saw_incremental or st.saw_refresh_evidence) and (wants_ir or wants_rag or wants_context or wants_rss)) {
        return error.ConflictingFlags;
    }
    // Target conflict rules
    if (st.hasExplicitTargets() and st.saw_html_dir) return failConflict(st, "--target", "--html-dir");
    if (wants_sitemap and st.targets.items.len > 1) return error.ConflictingFlags;
}

/// Mode selection:
/// 1. Explicit HTML flags / --target / --target-layout / --layout-rule → HTML
/// 2. --rag / --rag-dir → RAG-only
/// 3. --out / --no-rag → IR
/// 4. Default (no mode flags) → HTML site under dist/
fn resolveMode(st: *const ParseState) Mode {
    return if (st.explicitHtml())
        .html
    else if (st.wantsRag())
        .rag
    else if (st.wantsContext())
        .context
    else if (st.wantsLlms())
        .llms
    else if (st.wantsRss())
        .rss
    else if (st.wantsIr())
        .ir
    else
        .html;
}

/// Validate and normalize the GitHub Pages publication identity, then the
/// reusable site URL. Both are parse-time shape checks; neither touches the
/// filesystem.
fn finalizePublicationIdentity(gpa: std.mem.Allocator, st: *ParseState) ParseError!void {
    if (st.sawPagesLocation() and !(st.saw_pages_base_url and st.saw_pages_origin and st.saw_pages_base_path)) {
        return error.PagesLocationIncomplete;
    }
    if (st.sawPagesLocation()) {
        st.publication_location = github_pages.parse(
            gpa,
            st.pages_base_url.?,
            st.pages_origin.?,
            st.pages_base_path.?,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
    }

    if (st.site_url) |raw_url| {
        const normalized = site_url_mod.normalized(gpa, raw_url) catch |err| switch (err) {
            // Blame this flag, not the first value-taking flag findBadArg
            // scans (#761, #880): a bad --site-url previously surfaced as
            // "invalid value for --input".
            error.InvalidSiteUrl => return failInvalidValue(st, "--site-url", site_url_hint),
            error.OutOfMemory => return error.OutOfMemory,
        };
        gpa.free(normalized);
    }
}

/// Single-target HTML (bare CLI, --html, or --html-dir) maps to target "default".
/// --target-layout / --layout-rule may attach to this synthetic target.
fn synthesizeDefaultTarget(gpa: std.mem.Allocator, st: *ParseState, mode: Mode) ParseError!void {
    if (mode == .html and !st.hasExplicitTargets()) {
        try st.targets.append(gpa, .{
            .name = "default",
            .output_dir = if (st.saw_html_dir) st.html_dir else default_html_dir,
            .layout_path = null,
        });
    }
}

/// Apply --target-layout NAME=PATH onto matching targets. Flag order relative
/// to --target does not matter (layouts are collected first, applied here).
fn applyTargetLayouts(st: *ParseState) ParseError!void {
    for (st.target_layouts.items) |tl| {
        var found = false;
        for (st.targets.items) |*t| {
            if (std.mem.eql(u8, t.name, tl.name)) {
                if (t.layout_path != null) return error.DuplicateFlag;
                t.layout_path = tl.path;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidValue;
    }
}

/// Apply --target-profile NAME=PROFILE onto matching targets (including the
/// synthetic "default" target on bare HTML / --html / --html-dir).
fn applyTargetProfiles(st: *ParseState) ParseError!void {
    for (st.target_profiles.items) |tp| {
        var found = false;
        for (st.targets.items) |*t| {
            if (std.mem.eql(u8, t.name, tp.name)) {
                if (t.html_profile != null) return error.DuplicateFlag;
                t.html_profile = tp.profile;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidValue;
    }
}

/// The effective profile for the synthetic "default" target, surfaced on
/// Options for the single-target compile path (`main.runHtml`).
fn scanDefaultProfile(st: *const ParseState) ?render.OutputProfile {
    for (st.targets.items) |t| {
        if (std.mem.eql(u8, t.name, "default")) {
            return t.html_profile;
        }
    }
    return null;
}

/// Attach --layout-rule TARGET SELECTOR PATH. Order relative to --target is
/// independent; unknown targets and duplicate selectors fail as usage.
fn attachLayoutRules(gpa: std.mem.Allocator, st: *ParseState) ParseError!void {
    // Count rules per target for the 256 limit.
    for (st.targets.items) |*t| {
        var count: usize = 0;
        for (st.pending_rules.items) |pr| {
            if (std.mem.eql(u8, pr.target, t.name)) count += 1;
        }
        if (count > layout_select.max_rules_per_target) return error.InvalidValue;
        if (count == 0) continue;

        var rules = try gpa.alloc(layout_select.LayoutRule, count);
        errdefer gpa.free(rules);
        var filled: usize = 0;
        for (st.pending_rules.items) |pr| {
            if (!std.mem.eql(u8, pr.target, t.name)) continue;
            const parsed = layout_select.parseSelector(pr.selector) catch return error.InvalidValue;
            rules[filled] = .{
                .kind = parsed.kind,
                .value = parsed.value,
                .layout_path = pr.path,
            };
            filled += 1;
        }
        layout_select.rejectDuplicateSelectors(rules) catch {
            // Blame the repeated flag, never the argv scan's first
            // value-taking flag: the duplicate is a --layout-rule selector,
            // not a repeated occurrence of any other option (#867).
            st.err_detail = .{ .blame_flag = "--layout-rule" };
            return error.DuplicateFlag;
        };
        layout_select.sortRulesCanonical(rules);
        t.layout_rules = rules;
    }
    // Unknown rule targets (no matching --target / default).
    for (st.pending_rules.items) |pr| {
        var found = false;
        for (st.targets.items) |t| {
            if (std.mem.eql(u8, t.name, pr.target)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidValue;
    }
}

/// Construct the final `Options` for the resolved build mode. Each arm sets
/// exactly the fields the historical hand-written literal carried; every
/// other field stays at its `Options` default, byte-for-byte equivalent to
/// the previous per-mode struct literals.
fn buildOptionsForMode(
    st: *ParseState,
    mode: Mode,
    default_profile: ?render.OutputProfile,
    had_explicit_targets: bool,
) Options {
    var o = Options{
        .help = false,
        .quiet = st.quiet,
        .timings = st.saw_timings,
        .mode = mode,
        .input_dir = st.input_dir,
        .input_format = st.inputFormat(),
        .targets = st.targets,
    };
    switch (mode) {
        .ir => {
            o.command = st.command;
            o.impact_id = st.impact_id;
            o.analysis_format = st.analysis_format;
            o.analysis_report = st.analysis_report;
            o.out_dir = st.out_dir;
        },
        .rag => {
            o.rag_dir = st.rag_dir;
            o.scope = st.scope;
            o.split_size = st.split_size;
            o.bundles_only = st.bundles_only;
            o.complete = st.complete;
        },
        .context => {
            o.command = st.command;
            o.impact_id = st.impact_id;
            o.analysis_format = st.analysis_format;
            o.analysis_report = st.analysis_report;
            o.context_dir = st.context_dir;
            o.scope = st.scope;
            o.split_size = st.split_size;
        },
        .llms => {
            o.command = st.command;
            o.impact_id = st.impact_id;
            o.analysis_format = st.analysis_format;
            o.analysis_report = st.analysis_report;
            o.llms_path = st.llms_path;
            o.publication_location = st.publication_location;
            o.allow_markdown_links = st.allow_markdown_links;
        },
        .rss => {
            o.command = st.command;
            o.impact_id = st.impact_id;
            o.analysis_format = st.analysis_format;
            o.analysis_report = st.analysis_report;
            o.rss_path = st.rss_path;
            o.site_url = st.site_url;
            o.publication_location = st.publication_location;
            o.allow_markdown_links = st.allow_markdown_links;
            o.rss_title = st.rss_title;
            o.rss_description = st.rss_description;
            o.rss_limit = st.rss_limit;
        },
        .html => {
            const analysis_command = st.command == .check or st.command == .impact;
            o.command = st.command;
            o.impact_id = st.impact_id;
            o.analysis_format = st.analysis_format;
            o.analysis_report = if (analysis_command) st.analysis_report else null;
            o.report_path = if (analysis_command) null else st.analysis_report;
            o.fail_on_unreferenced = st.fail_on_unreferenced;
            o.sitemap_path = if (st.wantsSitemap()) st.sitemap_path else null;
            o.static_dir = if (st.wantsStatic()) st.static_dir else null;
            o.site_url = st.site_url;
            o.publication_location = st.publication_location;
            o.allow_markdown_links = st.allow_markdown_links;
            o.html_dir = if (had_explicit_targets) null else st.html_dir;
            o.html_layout = st.html_layout;
            o.owned_html_layout = st.owned_html_layout;
            o.incremental = st.saw_incremental or st.saw_watch;
            o.refresh_evidence = st.saw_refresh_evidence;
            o.jobs = st.jobs;
            o.watch = st.saw_watch;
            o.watch_json = st.saw_watch_json;
            o.serve = st.saw_serve or st.serve_port != null;
            o.serve_port = st.serve_port;
            o.html_profile = default_profile;
            o.profile_path = st.profile_path;
        },
    }
    return o;
}

/// Read a value for `--name` or `--name=value`. Advances `i` when the value is
/// the next argv token. Empty values are usage errors.
fn takeValue(
    args: []const []const u8,
    i: *usize,
    arg: []const u8,
    comptime name: []const u8,
) ParseError![]const u8 {
    const eq_prefix = name ++ "=";
    if (std.mem.startsWith(u8, arg, eq_prefix)) {
        const v = arg[eq_prefix.len..];
        if (v.len == 0) return error.EmptyValue;
        return v;
    }
    // Space-separated: --name <value>
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    const v = args[i.*];
    if (v.len == 0) return error.EmptyValue;
    return v;
}

/// Read a value for a flag whose empty string is meaningful. GitHub Pages
/// root/custom sites use an explicit empty `base_path`.
fn takeValueAllowEmpty(
    args: []const []const u8,
    i: *usize,
    arg: []const u8,
    comptime name: []const u8,
) ParseError![]const u8 {
    const eq_prefix = name ++ "=";
    if (std.mem.startsWith(u8, arg, eq_prefix)) return arg[eq_prefix.len..];
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

pub fn printUsage() void {
    std.debug.print(
        \\Boris — Zig content compiler (HTML site + IR + optional RAG)
        \\
        \\Usage: boris <command> [options]
        \\
        \\Modes:
        \\  build               Build the HTML site (default command)
        \\  validate            Validate selected HTML source/config without publication
        \\  watch               Build HTML, then watch and rebuild on changes
        \\  check               Read-only graph health report (findings do not fail by default)
        \\  impact <ID>         Read-only transitive impact report for a page
        \\  plan                Emit a normalized publication plan (no publication)
        \\  recipe-scale        Print a derived Cooklang scale view (no rewrite)
        \\  standard-site publish  One-shot Standard.site publish (stored session + reconcile; never implicit)
        \\  standard-site plan    Emit the deterministic Standard.site plan offline (no network)
        \\  standard-site records Dump the full canonical record payloads offline (no network)
        \\  standard-site verify  Cross-check the built head links + well-known file offline (no network)
        \\  standard-site login  Authorize a DID or handle and persist the session
        \\  standard-site sessions  List persisted sessions (DID, flavor, PDS; no secrets)
        \\  standard-site logout  Remove a persisted session (secure erase; does not revoke)
        \\  standard-site smoke  Live interop smoke against a real PDS (manual, opt-in; never in CI)
        \\  nostr plan          Emit the offline Nostr NIP-23 publication plan (no signing, no relay)
        \\  nostr sign          Sign a plan artifact into a signed-event bundle (offline; key via stdin)
        \\  nostr publish       Send a signed-event bundle to the plan's relays; writes the report
        \\  init [DIR]          Write a starter site (content, theme, profile) into DIR (default: .)
        \\  (no command)        Same as build
        \\  standard-site publish options:
        \\  --profile PATH      Standard.site publication profile (required)
        \\  --plan PATH         Committed standard-site plan to validate (fail closed on drift)
        \\  --out PATH          Evidence artifact path (default: stdout)
        \\  --prune             Explicit prune authority (ANDs with the profile prune flag)
        \\  --source-commit C   Source commit recorded in the evidence bindings
        \\  standard-site plan options:
        \\  --profile PATH      Standard.site publication profile (required)
        \\  --out PATH          Plan artifact path (default: stdout)
        \\  standard-site records options:
        \\  --profile PATH      Standard.site publication profile (required)
        \\  --out PATH          Records artifact path (default: stdout)
        \\  standard-site verify options:
        \\  --profile PATH      Standard.site publication profile (required)
        \\  --dist DIR          Built output directory to check (default: dist)
        \\  --out PATH          Verify result artifact path (default: stdout)
        \\  standard-site login/logout options:
        \\  --did DID           AT Protocol DID to authorize (login) or forget (logout)
        \\  --handle HANDLE     AT Protocol handle for login --app-password, logout, or smoke
        \\  --app-password      Opt-in app-password login (broad account write; never OAuth scope)
        \\  standard-site smoke options:
        \\  --did DID           Test identity DID (or use --handle)
        \\  --namespace NAME    Unique rkey namespace prefix (default: clock-derived)
        \\  --surface-url URL   Served verification-surface origin to check (optional)
        \\  --indexer URL       Indexer/AppView origin observed non-normatively (optional)
        \\  --out PATH          Smoke result artifact path (default: stdout)
        \\  standard-site options (all subcommands):
        \\  --session-root PATH Override the persistent session store root
        \\  --profile PATH      Publication profile: emit Standard.site verification and/or Nostr naddr head links
        \\  --html              Explicit HTML site mode → --html-dir (default dist)
        \\  --html-dir <DIR>    HTML site mode with output directory DIR
        \\  --target NAME=DIR   HTML multi-target mode (repeatable; order-independent); implies HTML
        \\  --out <DIR>         IR mode → write JSON under DIR (default .boris when --no-rag)
        \\  --no-rag            Explicit IR mode (JSON under --out, default .boris)
        \\  --rag               RAG-only mode → working-context packs under --rag-dir (default rag)
        \\  --rag-dir <DIR>     RAG-only mode with output directory DIR
        \\  --complete          Complete-corpus RAG export (with --rag): the entire validated corpus — system + per-page + graph + catalog
        \\  --context           Context-only mode → bundle under --context-dir (default context)
        \\  --context-dir DIR   Context-only mode with output directory DIR
        \\  --scope VALUE       RAG/context entity id or collection prefix
        \\  --split-size BYTES  Working-RAG pack target (default 262144); context bundle byte cap
        \\  --bundles-only      Accepted for RAG compatibility; working packs are bundle-style by design
        \\  --llms              Deterministic llms.txt export → llms.txt
        \\  --llms-path PATH    llms.txt export path (implies --llms)
        \\  --rss               Deterministic RSS 2.0 export → rss.xml
        \\  --rss-path PATH     RSS output path (implies --rss)
        \\  --sitemap           Add deterministic sitemap.xml to the HTML target
        \\  --sitemap-path PATH Target-root-relative sitemap path (implies --sitemap)
        \\  --static-dir DIR    Copy a directory of static files byte-identically into
        \\                      the HTML target root (robots.txt, .well-known/; #804)
        \\
        \\Options:
        \\  --input <DIR>       Content root (default: content)
        \\  --textile          Explicit .textile-only input adapter mode (no mixed trees)
        \\  --cooklang         Explicit .cook-only Cooklang recipe mode (no mixed trees)
        \\  --out <DIR>         IR output directory (selects IR mode; default: .boris)
        \\  --rag-dir <DIR>     RAG corpus directory (implies RAG-only; default: rag)
        \\  --site-url URL      Required HTTP(S) deployment URL for RSS or sitemap
        \\  --pages-base-url U  Normalized Pages public base URL
        \\  --pages-origin U    Normalized Pages public origin
        \\  --pages-base-path P Normalized Pages path (empty for root/custom sites)
        \\  --rss-title TITLE   Required RSS channel title
        \\  --rss-description T Required RSS channel description
        \\  --rss-limit N       RSS item limit (1–500; default 20)
        \\  --html-dir <DIR>    HTML output directory (implies HTML; default: dist)
        \\  --html-layout PATH  Global layout template (default: themes/boris/layouts/main.html)
        \\  --theme ROOT        Theme root sugar → ROOT/layouts/main.html (+ managed assets/)
        \\  --target NAME=DIR   Named HTML output root (repeatable; exclusive with --html-dir)
        \\  --target-layout N=P Per-target layout (NAME=PATH; may precede or follow --target)
        \\  --target-profile N=P Per-target Oliver serialization profile (NAME=html|xhtml; default html)
        \\  --layout-rule T S P HTML layout rule: TARGET SELECTOR LAYOUT_PATH (repeatable; max 256/target)
        \\                      Selectors: id:<entity-id> | glob:<seg-pattern> | role:trunk|satellite
        \\  --incremental       Content-addressed incremental HTML rendering (HTML mode)
        \\  --refresh-evidence  Force full evidence re-derivation, skipping reuse of
        \\                      unchanged committed evidence (HTML mode, #728)
        \\  --watch             Compatibility flag; same as the watch command; with `validate`
        \\                      starts the zero-write validation daemon (validate --watch)
        \\  --watch-json        Emit one NDJSON event per build phase on stderr (watch only,
        \\                      including validate --watch); see docs/contracts/watch-mode.md §8
        \\  --serve             Serve the built tree over loopback HTTP (watch only);
        \\                      auto-reload helper: http://127.0.0.1:PORT/__boris/
        \\  --port N            Loopback port for --serve (default 8090; 0 = ephemeral);
        \\                      implies --serve
        \\  --jobs N, -j N      Bounded parallel HTML page workers (1–64; HTML mode; default 1; smoke-validated)
        \\  --timings           Print a machine-readable phase timing/counter JSON report to stdout
        \\                      (opt-in; default output, diagnostics, and exit codes unchanged)
        \\  --quiet             Suppress progress + success stderr; errors always print
        \\                      (exit codes/artifacts unchanged)
        \\  --format human|json  Analysis output format for check/impact (default human)
        \\  --report PATH        Write the report to PATH (check/impact analysis; build/validate HTML diagnostics)
        \\  --fail-on-unreferenced Make check fail when it reports unreferenced pages
        \\  --profile PATH       Selected publication profile for `plan`
        \\  --id PAGE            Recipe page entity id (`recipe-scale`; required)
        \\  --factor TEXT        Scale factor: 2, 1/2, 1.5, 1 1/2 (`recipe-scale`; exclusive with --servings)
        \\  --servings N         Target serving count (`recipe-scale`; exclusive with --factor)
        \\  --out PATH           Scaled-view JSON path (`recipe-scale`; default: stdout only)
        \\  --plan PATH          Plan artifact to sign (`nostr sign`)
        \\  --key-stdin          Read the hex/nsec secret key once from stdin (`nostr sign`)
        \\  --out PATH           Signed-event bundle output path (`nostr sign`; default: stdout)
        \\  --prior PATH         Prior signed bundle to reuse unchanged evidence from (`nostr sign`)
        \\  --created-at N       Explicit signing-time override, unix seconds (`nostr sign`; test/recovery)
        \\  --bundle PATH        Signed-event bundle to publish (`nostr publish`)
        \\  --out PATH           Publish report output path (`nostr publish`; default: stdout)
        \\  -h, --help          Show this help and exit 0
        \\  -V, --version       Print the compiler version (`boris/<ver>`) and exit 0
        \\
        \\HTML artifacts (success; Oliver + layout splice):
        \\  <html-dir>/**/*.html   or   <each-target-dir>/**/*.html
        \\  <target-dir>/sitemap.xml  (with --sitemap; path configurable)
        \\  <target-dir>/**  (with --static-dir; byte-identical passthrough files,
        \\                   declared in _boris/proof/artifacts.json)
        \\  <target-dir>/.boris-cache/manifest.json  (with --incremental / --watch)
        \\  Staging: <target-dir>.boris-stage (ephemeral; committed only on full target success)
        \\
        \\IR artifacts (success; --out or --no-rag):
        \\  <out>/manifest.json  <out>/graph.json  <out>/completion.json  <out>/build-report.json
        \\
        \\RAG artifacts (success; same graph validation as IR):
        \\  working-N.md          model-facing working packs (site documents only)
        \\  manifest.json         sidecar manifest — NOT normally uploaded (scope, counts, hashes)
        \\  (with --complete) INDEX.md  UPLOAD-GUIDE.md  catalog.jsonl  catalog_meta.json  system/**
        \\                      content/pages/**  graph/entity-catalog.md  graph/relations.md
        \\
        \\Context artifacts (success; same graph validation as IR/RAG):
        \\  bundle.md  manifest.json  graph.json  pages/<entity-id>.md
        \\  parts/part-N.md (with --split-size)
        \\
        \\Conflicts (exit 2):
        \\  --rag with --no-rag
        \\  --no-rag with --rag-dir
        \\  --textile with --cooklang
        \\  --complete without --rag / --rag-dir
        \\  --complete with --scope, --split-size, or --bundles-only
        \\  --context / --context-dir with --rag, --out, or HTML selectors
        \\  --rss / --rss-path with HTML, IR, RAG, Context, llms.txt, validate, check, or impact
        \\  --sitemap / --sitemap-path without --site-url, with non-HTML modes,
        \\  or with multiple targets sharing one ambiguous public URL
        \\  --site-url without --rss or --sitemap
        \\  --out with nostr plan (stdout carries the plan document)
        \\  session flags (--did, --handle, --app-password, --prune,
        \\  --source-commit, --dist, --namespace, --surface-url, --indexer,
        \\  --session-root) outside standard-site
        \\  --static-dir with non-HTML modes or multiple targets
        \\  explicit --out with --rag or --rag-dir
        \\  --html / --html-dir / --html-layout / --theme / --target / --target-layout /
        \\  --target-profile / --layout-rule with --rag, --rag-dir, --context, or explicit --out
        \\  --target with --html-dir
        \\  --theme with --html-layout (both select the one global layout)
        \\  check / impact with any HTML selector (--html, --html-dir,
        \\  --html-layout, --theme, --target, --target-layout, --target-profile,
        \\  --layout-rule, --sitemap / --sitemap-path, --static-dir) or --profile
        \\  --watch, --incremental, or --jobs with IR (--out / --no-rag) or RAG / context
        \\  validate with --profile, non-HTML exports, --incremental, --refresh-evidence, --jobs, --format, or --out
        \\  validate --watch with --html-dir, --target, --serve/--port, --incremental, --jobs, or --format
        \\  Invalid target names, duplicate names, output collisions, workspace escape,
        \\  content/layout overlap, unknown --target-layout / --layout-rule target,
        \\  duplicate or invalid layout selectors, invalid layout paths (.. / absolute),
        \\  mixed theme roots, >256 rules/target
        \\
        \\Exit codes: 0 success, 1 content validation, 2 usage, 3 I/O/system
        \\
        \\Note: Bare `boris` builds HTML under dist/ as target "default". Use --out for JSON IR.
        \\      `boris validate` observes the selected HTML target configuration but writes no artifacts.
        \\      `boris validate --watch` repeats that preflight on every change and exits 0 on signal;
        \\      `--report PATH` is rewritten each cycle and `--watch-json` emits mode "validate" events.
        \\      `boris plan --profile PATH` emits only the normalized declaration JSON on stdout.
        \\      `boris recipe-scale --input DIR --id PAGE --factor TEXT` prints a derived
        \\      scaled view on stdout; `--servings N` is the same view with
        \\      factor = N / current (missing current is 1). Never rewrites .cook or graph.json.
        \\      `boris standard-site` (no subcommand) prints the Standard.site family list.
        \\      `boris nostr plan --profile PATH` emits the offline NIP-23 publication plan on stdout;
        \\      it never signs, never contacts a relay, and never reads a key.
        \\      `boris nostr sign --plan PLAN --key-stdin` reads the secret key once from stdin and
        \\      writes the signed-event bundle to stdout (or --out PATH); it never contacts a relay.
        \\      Secrets are never accepted from argv, profile, or environment.
        \\      --html / --html-dir / bare CLI map to a single target named "default".
        \\      Equivalent --target / --target-layout / --layout-rule permutations yield the
        \\      same config (targets sorted by name; rules canonicalized). No layout frontmatter.
        \\      Frontmatter `status:` is exactly draft, published, or archived (unknown
        \\      values fail validation). A draft renders to its .html files but is
        \\      excluded from nav, search, sitemap, RSS, and publication projections.
        \\
    , .{});
}

/// Focused usage for the `standard-site` family. `boris standard-site` with
/// no subcommand, an unknown subcommand, or `standard-site --help` prints
/// this instead of the full compiler help.
pub fn printStandardSiteUsage() void {
    std.debug.print(
        \\Boris Standard.site — Atmosphere publication (explicit; never implicit)
        \\
        \\Usage: boris standard-site <command> [options]
        \\
        \\Offline (no network, no credentials):
        \\  plan     --profile PATH [--out PATH]   Deterministic record projection
        \\  records  --profile PATH [--out PATH]   Full canonical record payloads
        \\  verify   --profile PATH [--dist DIR] [--out PATH]
        \\                                         Check head links + well-known file
        \\
        \\Auth and live:
        \\  login --app-password (--did DID | --handle HANDLE)
        \\                                         Opt-in app-password login (bsky.social path)
        \\  login --did DID                        Browser OAuth (granular repo scopes)
        \\  sessions [--session-root PATH]         List DID, flavor, PDS (no secrets)
        \\  logout (--did DID | --handle HANDLE)   Erase the local session (does not revoke)
        \\  publish --profile PATH [--plan PATH] [--out PATH] [--prune]
        \\                                         One-shot publish from a stored session
        \\  smoke (--did DID | --handle HANDLE) [--namespace NAME] [--surface-url URL] [--indexer URL] [--out PATH]
        \\                                         Live interop smoke (manual, never in CI)
        \\
        \\  --session-root PATH                    Override the 0600 session store
        \\
        \\First testers: see docs/standard-site.md. App passwords grant broad
        \\account write — use a dedicated test identity. OAuth requests granular
        \\repo scopes (site.standard.document, site.standard.publication); a live
        \\smoke against bsky.social confirms the grant.
        \\
    , .{});
}

/// Narrow help for the init command (`boris init --help`, exit 0). Help is
/// a stderr surface like every other text output (docs/contracts/cli.md).
pub fn printInitUsage() void {
    std.debug.print(
        \\Boris init — materialize a deterministic starter site and verify it compiles
        \\
        \\Usage: boris init [DIR] [--quiet]
        \\
        \\Writes a fixed starter tree into DIR (default `.`): three content pages
        \\exercising the graph (trunk, satellites, wiki links, a semantic relation),
        \\a closed-slot theme whose layout ships the rendered-search browser client,
        \\and the two publication profiles (boris.json, standard-site.json).
        \\DIR must be empty or not exist; the tree is byte-deterministic.
        \\
        \\  --quiet          Suppress the success report; errors always print
        \\
        \\After writing, init compiles the fresh tree through the normal HTML
        \\pipeline into a probe directory that is removed again. Exit 0 means
        \\the starter is materialized AND compiled, with the page count in the
        \\report. A target outside the workspace skips the probe (reported);
        \\a probe failure removes the tree and exits 1.
        \\
        \\Next steps:
        \\  boris check                      graph-health report
        \\  boris --help                     full option list
        \\
    , .{});
}

/// Print a usage diagnostic. Uses `std.debug.print` (not `std.log.err`) so
/// unit tests that exercise the usage path are not failed by the test logger.
pub fn printParseError(err: ParseError, bad_arg: ?[]const u8) void {
    printParseErrorDetail(err, bad_arg, null);
}

/// `printParseError` with optional parse context (#761, #764): a recorded
/// conflict pair or blamed option is named; without context the historical
/// generic text stands.
pub fn printParseErrorDetail(err: ParseError, bad_arg: ?[]const u8, detail: ?*const ParseErrorDetail) void {
    switch (err) {
        error.UnknownFlag => {
            if (bad_arg) |a| {
                std.debug.print("error: unknown option: {s} (try --help)\n", .{a});
            } else {
                std.debug.print("error: unknown option (try --help)\n", .{});
            }
        },
        error.MissingValue => {
            if (bad_arg) |a| {
                std.debug.print("error: missing value for {s}\n", .{a});
            } else {
                std.debug.print("error: missing option value\n", .{});
            }
        },
        error.EmptyValue => {
            if (bad_arg) |a| {
                std.debug.print("error: empty value for {s}\n", .{a});
            } else {
                std.debug.print("error: empty option value\n", .{});
            }
        },
        error.UnexpectedPositional => {
            if (bad_arg) |a| {
                std.debug.print("error: unexpected argument: {s} (try --help)\n", .{a});
            } else {
                std.debug.print("error: unexpected positional argument (try --help)\n", .{});
            }
        },
        error.ConflictingFlags => {
            if (detail) |d| {
                if (d.conflict_a) |a| {
                    if (d.conflict_b) |b| {
                        std.debug.print("error: {s} conflicts with {s} (try --help)\n", .{ a, b });
                        return;
                    }
                }
            }
            std.debug.print("error: conflicting options (try --help)\n", .{});
        },
        error.DuplicateFlag => {
            if (bad_arg) |a| {
                std.debug.print("error: duplicate option: {s}\n", .{a});
            } else {
                std.debug.print("error: duplicate option\n", .{});
            }
        },
        error.InvalidValue => {
            if (detail) |d| {
                if (d.blame_flag) |flag| {
                    // The failing path named its flag; never let the argv
                    // scan misattribute the rejection (#761).
                    if (d.blame_hint) |hint| {
                        std.debug.print("error: invalid value for {s} ({s})\n", .{ flag, hint });
                    } else {
                        std.debug.print("error: invalid value for {s}\n", .{flag});
                    }
                    return;
                }
            }
            if (bad_arg) |a| {
                std.debug.print("error: invalid value for {s}\n", .{a});
            } else {
                std.debug.print("error: invalid option value\n", .{});
            }
        },
        error.UnknownNostrSubcommand => {
            std.debug.print("error: unknown nostr subcommand (available: plan, sign, publish)\n", .{});
        },
        error.MissingStandardSiteSubcommand => {
            std.debug.print("error: standard-site requires a subcommand (try: plan, records, verify, login, sessions, logout, publish, smoke)\n", .{});
        },
        error.UnknownStandardSiteSubcommand => {
            std.debug.print("error: unknown standard-site subcommand (try: plan, records, verify, login, sessions, logout, publish, smoke)\n", .{});
        },
        error.MissingStandardSiteProfile => {
            std.debug.print("error: standard-site plan, records, verify, and publish require --profile PATH\n", .{});
        },
        error.MissingStandardSiteIdentity => {
            std.debug.print("error: this standard-site command requires --did DID or --handle HANDLE\n", .{});
        },
        error.ConflictingStandardSiteFlags => {
            std.debug.print("error: conflicting standard-site options\n", .{});
        },
        error.RSSMetadataRequired => {
            // `--rss` / `--rss-path` are mode flags; a missing value here
            // means the required channel metadata was never supplied, not
            // that the mode flag itself needs a value.
            std.debug.print(
                "error: RSS mode requires --site-url, --rss-title, and --rss-description (try --help)\n",
                .{},
            );
        },
        error.SitemapSiteUrlRequired => {
            std.debug.print(
                "error: --sitemap / --sitemap-path require --site-url (try --help)\n",
                .{},
            );
        },
        error.PagesLocationIncomplete => {
            std.debug.print(
                "error: --pages-base-url, --pages-origin, and --pages-base-path are required together (try --help)\n",
                .{},
            );
        },
        error.InvalidRssLimit => {
            std.debug.print(
                "error: invalid value for --rss-limit (must be 1-500; try --help)\n",
                .{},
            );
        },
        error.OutOfMemory => {
            std.debug.print("error: out of memory\n", .{});
        },
    }
}

/// Flags `findBadArg` never blames: boolean switches whose presence must not
/// absorb a failure's attribution (e.g. `--rss` plus an unknown flag, or RSS
/// mode missing its channel metadata). Value-taking flags are intentionally
/// NOT skipped: a missing or empty value reports the flag itself, and any
/// other token (unknown flag, stray positional) reports itself unchanged.
const never_blamed_flags = [_][]const u8{
    "--quiet",
    "--timings",
    "--rag",
    "--no-rag",
    "--html",
    "--textile",
    "--cooklang",
    "--key-stdin",
    "--incremental",
    "--watch",
    "--fail-on-unreferenced",
    "--context",
    "--bundles-only",
    "--complete",
    "--llms",
    "--rss",
    "--sitemap",
    "--allow-markdown-links",
    "--static-dir",
};

/// Find a likely "bad" argv token for error messages (best-effort).
pub fn findBadArg(args: []const []const u8) ?[]const u8 {
    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) continue;
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) continue;
        if (std.mem.eql(u8, a, "--build-info")) continue;
        for (never_blamed_flags) |f| {
            if (std.mem.eql(u8, a, f)) break;
        } else return a;
    }
    return null;
}
/// Dispatch parsed options through a small injectable runner.
///
/// - Version: calls `runner.printVersion()` and returns success; never calls `run`.
/// - Build info: calls `runner.printBuildInfo()` when the runner provides it
///   and returns success; never calls `run` (#776).
/// - Help: calls `runner.printHelp()` and returns success; never calls `run`.
/// - Build modes: calls `runner.run(opts)` and returns its exit code.
///
/// `runner` must provide `printVersion`, `printHelp`, and `run` methods.
pub fn execute(opts: Options, runner: anytype) ExitCode {
    if (opts.version) {
        runner.printVersion();
        return .success;
    }
    if (opts.build_info) {
        const Runner = @TypeOf(runner.*);
        if (@hasDecl(Runner, "printBuildInfo")) runner.printBuildInfo();
        return .success;
    }
    if (opts.help) {
        if (opts.command == .standard_site) {
            printStandardSiteUsage();
        } else if (opts.command == .init) {
            printInitUsage();
        } else {
            runner.printHelp();
        }
        return .success;
    }
    return runner.run(opts);
}

/// Parse argv and execute. Maps all parse failures to exit code 2.
///
/// On parse failure, calls `runner.reportUsage(err, bad_arg, detail)` when
/// that method exists; otherwise falls back to `printParseErrorDetail` +
/// `printUsage`. `detail` carries the failing path's own attribution when it
/// recorded one (#761, #764); `bad_arg` remains the findBadArg scan result.
pub fn runArgs(args: []const []const u8, runner: anytype) u8 {
    const gpa = if (@hasField(@TypeOf(runner.*), "gpa")) runner.gpa else std.testing.allocator;
    var detail = ParseErrorDetail{};
    var opts = parseOptionsWithDetail(gpa, args, &detail) catch |err| {
        const bad = if (detail.blame_flag) |flag| flag else findBadArg(args);
        const Runner = @TypeOf(runner.*);
        if (@hasDecl(Runner, "reportUsage")) {
            runner.reportUsage(err, bad, &detail);
        } else {
            printParseErrorDetail(err, bad, &detail);
            printUsage();
        }
        return ExitCode.usage.int();
    };
    defer opts.deinit(gpa);
    return execute(opts, runner).int();
}

// --- tests -----------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "parse: default is HTML mode" {
    var o = try parseOptions(std.testing.allocator, &.{"boris"});
    defer o.deinit(std.testing.allocator);
    try expect(!o.help);
    try expect(!o.quiet);
    try expectEqual(Mode.html, o.mode);
    try expectEqualStrings(default_input_dir, o.input_dir);
    try expect(o.out_dir == null);
    try expect(o.rag_dir == null);
    try expectEqualStrings(default_html_dir, o.html_dir.?);
    try expectEqualStrings(default_html_layout, o.html_layout);
    try expectEqual(@as(usize, 1), o.targets.items.len);
    try expectEqualStrings("default", o.targets.items[0].name);
    try expectEqualStrings(default_html_dir, o.targets.items[0].output_dir);
    try expectEqual(identity.InputFormat.markdown, o.input_format);
}

test "parse: Textile input mode is explicit and whole-tree" {
    var html = try parseOptions(std.testing.allocator, &.{ "boris", "--textile", "--input", "pages" });
    defer html.deinit(std.testing.allocator);
    try expectEqual(identity.InputFormat.textile, html.input_format);
    try expectEqual(Mode.html, html.mode);

    var ir = try parseOptions(std.testing.allocator, &.{ "boris", "--textile", "--out", ".boris" });
    defer ir.deinit(std.testing.allocator);
    try expectEqual(identity.InputFormat.textile, ir.input_format);
    try expectEqual(Mode.ir, ir.mode);

    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "--textile", "--textile" }));
}

test "parse: documentation intelligence commands" {
    var check = try parseOptions(std.testing.allocator, &.{ "boris", "check", "--input", "docs", "--format", "json", "--report", "report.json" });
    defer check.deinit(std.testing.allocator);
    try expectEqual(Command.check, check.command);
    try expectEqual(AnalysisFormat.json, check.analysis_format);
    try expectEqualStrings("docs", check.input_dir);
    try expectEqualStrings("report.json", check.analysis_report.?);
    try expect(!check.fail_on_unreferenced);

    var strict = try parseOptions(std.testing.allocator, &.{ "boris", "check", "--fail-on-unreferenced" });
    defer strict.deinit(std.testing.allocator);
    try expect(strict.fail_on_unreferenced);
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "check", "--fail-on-unreferenced", "--fail-on-unreferenced" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "check", "--fail-on-unreferenced", "--out", ".boris" }));

    var impact = try parseOptions(std.testing.allocator, &.{ "boris", "impact", "guides/cache", "--quiet" });
    defer impact.deinit(std.testing.allocator);
    try expectEqual(Command.impact, impact.command);
    try expectEqualStrings("guides/cache", impact.impact_id.?);
    try expect(impact.quiet);
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "impact", "guides/cache", "--fail-on-unreferenced" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--fail-on-unreferenced" }));

    // The positional id may follow flags, not only the command token.
    var impact_flags_first = try parseOptions(std.testing.allocator, &.{ "boris", "impact", "--quiet", "guides/cache" });
    defer impact_flags_first.deinit(std.testing.allocator);
    try expectEqual(Command.impact, impact_flags_first.command);
    try expectEqualStrings("guides/cache", impact_flags_first.impact_id.?);
    try expect(impact_flags_first.quiet);
    // A second positional is still a usage error; a missing id after flags is
    // still a missing value.
    try expectError(error.UnexpectedPositional, parseOptions(std.testing.allocator, &.{ "boris", "impact", "a", "b" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "impact", "--quiet" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "impact" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "check", "--out", ".boris" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--format", "json" }));
}

test "parse: validate selects HTML configuration without publication controls" {
    var validate = try parseOptions(std.testing.allocator, &.{
        "boris",          "validate",
        "--input",        "docs",
        "--html-dir",     "preview",
        "--html-layout",  "test/fixtures/layouts/ok.html",
        "--sitemap-path", "meta/sitemap.xml",
        "--site-url",     "https://example.test/docs/",
        "--quiet",
    });
    defer validate.deinit(std.testing.allocator);
    try expectEqual(Command.validate, validate.command);
    try expectEqual(Mode.html, validate.mode);
    try expectEqualStrings("docs", validate.input_dir);
    try expectEqualStrings("preview", validate.html_dir.?);
    try expectEqual(@as(usize, 1), validate.targets.items.len);
    try expectEqualStrings("preview", validate.targets.items[0].output_dir);
    try expect(validate.quiet);
    try expect(!validate.incremental);
    try expect(!validate.watch);

    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--out", ".boris" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--rss", "--site-url", "https://example.test", "--rss-title", "Docs", "--rss-description", "D" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--incremental" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--jobs", "2" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--format", "json" }));
    // `--report` is the HTML-path diagnostics surface: accepted on validate
    // and build, still rejected on watch and on non-HTML build modes.
    var with_report = try parseOptions(std.testing.allocator, &.{ "boris", "validate", "--report", "validation.json" });
    defer with_report.deinit(std.testing.allocator);
    try expectEqualStrings("validation.json", with_report.report_path.?);
    try expect(with_report.analysis_report == null);

    var build_report = try parseOptions(std.testing.allocator, &.{ "boris", "build", "--report", "build-report.json" });
    defer build_report.deinit(std.testing.allocator);
    try expectEqualStrings("build-report.json", build_report.report_path.?);

    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "watch", "--report", "watch.json" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "build", "--out", ".boris", "--report", "x.json" }));
}

test "parse: validate --watch starts the zero-write validation daemon (#647)" {
    var v = try parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch" });
    defer v.deinit(std.testing.allocator);
    try expectEqual(Command.validate, v.command);
    try expectEqual(Mode.html, v.mode);
    try expect(v.watch);
    // `--watch` implies `incremental` in Options (same as HTML watch); the
    // validate action forces incremental off internally (validateHtmlSiteMulti).
    try expect(v.incremental);

    var json = try parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch", "--watch-json" });
    defer json.deinit(std.testing.allocator);
    try expect(json.watch_json);

    var report = try parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch", "--report", "v.json" });
    defer report.deinit(std.testing.allocator);
    try expectEqualStrings("v.json", report.report_path.?);
    try expect(report.analysis_report == null);

    // The zero-write daemon accepts no output/selection flags: conflicts stay
    // exit 2, exactly like every other validate combination.
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch", "--html-dir", "site" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch", "--target", "a=b" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch", "--serve" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch", "--port", "0" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch", "--out", ".boris" }));
}

test "parse: --timings is opt-in and mode-agnostic" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--timings" });
    defer o.deinit(std.testing.allocator);
    try expect(o.timings);
    try expectEqual(Mode.html, o.mode);

    var ir = try parseOptions(std.testing.allocator, &.{ "boris", "--out", ".boris", "--timings" });
    defer ir.deinit(std.testing.allocator);
    try expect(ir.timings);
    try expectEqual(Mode.ir, ir.mode);

    var rag = try parseOptions(std.testing.allocator, &.{ "boris", "--rag", "--quiet", "--timings" });
    defer rag.deinit(std.testing.allocator);
    try expect(rag.timings);
    try expect(rag.quiet);

    var default = try parseOptions(std.testing.allocator, &.{"boris"});
    defer default.deinit(std.testing.allocator);
    try expect(!default.timings);

    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "--timings", "--timings" }));
}

test "parse: plan rejects --timings (stdout is the plan document)" {
    // `plan` writes exactly one JSON document to stdout, and runs no compiler
    // phase, so combining it with the stdout timing report is a usage error.
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "plan", "--profile", "p.toml", "--timings" }));

    // But timings remains accepted on every phase-running mode/command.
    var validate = try parseOptions(std.testing.allocator, &.{ "boris", "validate", "--timings" });
    defer validate.deinit(std.testing.allocator);
    try expect(validate.timings);

    var check = try parseOptions(std.testing.allocator, &.{ "boris", "check", "--timings" });
    defer check.deinit(std.testing.allocator);
    try expect(check.timings);

    var impact = try parseOptions(std.testing.allocator, &.{ "boris", "impact", "x", "--timings" });
    defer impact.deinit(std.testing.allocator);
    try expect(impact.timings);
}

test "parse: explicit build and watch commands are stable aliases" {
    var build = try parseOptions(std.testing.allocator, &.{ "boris", "build", "--html-dir", "site" });
    defer build.deinit(std.testing.allocator);
    try expectEqual(Command.build, build.command);
    try expectEqual(Mode.html, build.mode);
    try expect(!build.watch);
    try expectEqualStrings("site", build.html_dir.?);

    var watch = try parseOptions(std.testing.allocator, &.{ "boris", "watch", "--input", "docs" });
    defer watch.deinit(std.testing.allocator);
    try expectEqual(Command.watch, watch.command);
    try expectEqual(Mode.html, watch.mode);
    try expect(watch.watch);
    try expect(watch.incremental);
    try expectEqualStrings("docs", watch.input_dir);

    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "watch", "--format", "json" }));
}

test "parse: watch --serve and --port (preview server)" {
    // `watch --serve` enables the loopback preview server with the default port.
    var serve = try parseOptions(std.testing.allocator, &.{ "boris", "watch", "--serve" });
    defer serve.deinit(std.testing.allocator);
    try expect(serve.watch);
    try expect(serve.serve);
    try expect(serve.serve_port == null);

    // `--port` implies `--serve` and parses a u16.
    var port = try parseOptions(std.testing.allocator, &.{ "boris", "watch", "--port", "8123" });
    defer port.deinit(std.testing.allocator);
    try expect(port.serve);
    try expectEqual(@as(u16, 8123), port.serve_port.?);

    // `--watch --serve` (flag form) works too.
    var flag = try parseOptions(std.testing.allocator, &.{ "boris", "--watch", "--serve", "--port", "0" });
    defer flag.deinit(std.testing.allocator);
    try expect(flag.serve);
    try expectEqual(@as(u16, 0), flag.serve_port.?);

    // Serve requires watch mode; duplicates are usage errors.
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "build", "--serve" }));
}

test "parse: --watch-json requires watch mode" {
    // `boris watch --watch-json` enables the NDJSON stderr stream.
    var watch = try parseOptions(std.testing.allocator, &.{ "boris", "watch", "--watch-json" });
    defer watch.deinit(std.testing.allocator);
    try expect(watch.watch);
    try expect(watch.watch_json);

    // Flag form (`boris --watch --watch-json`) is the same watch mode.
    var flag = try parseOptions(std.testing.allocator, &.{ "boris", "--watch", "--watch-json" });
    defer flag.deinit(std.testing.allocator);
    try expect(flag.watch);
    try expect(flag.watch_json);

    // Composes with --serve: SSE for browsers, NDJSON for the subprocess.
    var both = try parseOptions(std.testing.allocator, &.{ "boris", "watch", "--watch-json", "--serve" });
    defer both.deinit(std.testing.allocator);
    try expect(both.watch_json);
    try expect(both.serve);

    // Without watch mode it is a usage error, so a typo cannot silently
    // produce an empty stream.
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "build", "--watch-json" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--watch-json" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--watch-json" }));
}

test "parse: --target-profile selects the Oliver serialization profile (#448)" {
    // Per-target XHTML on an explicit target.
    var multi = try parseOptions(std.testing.allocator, &.{ "boris", "build", "--target", "site=dist/site", "--target-profile", "site=xhtml" });
    defer multi.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 1), multi.targets.items.len);
    try expectEqual(render.OutputProfile.xhtml, multi.targets.items[0].html_profile.?);

    // On the synthetic "default" target, the profile is also surfaced on Options.
    var def = try parseOptions(std.testing.allocator, &.{ "boris", "--html-dir", "dist", "--target-profile=default=xhtml" });
    defer def.deinit(std.testing.allocator);
    try expectEqual(render.OutputProfile.xhtml, def.html_profile.?);
    try expectEqual(render.OutputProfile.xhtml, def.targets.items[0].html_profile.?);

    // No profile → defaults to html (null overrides).
    var plain = try parseOptions(std.testing.allocator, &.{"boris"});
    defer plain.deinit(std.testing.allocator);
    try expect(plain.html_profile == null);
    try expect(plain.targets.items[0].html_profile == null);

    // Unknown target, bad profile value, and duplicates are usage errors.
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target-profile", "nope=xhtml" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target-profile", "default=sgml" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target-profile", "default" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "--target-profile", "default=xhtml", "--target-profile", "default=xhtml" }));

    // validate is the no-publication HTML path: like --theme and --layout-rule,
    // the profile selector is honored (validation renders with it), not rejected.
    var val = try parseOptions(std.testing.allocator, &.{ "boris", "validate", "--target-profile", "default=xhtml" });
    defer val.deinit(std.testing.allocator);
    try expectEqual(Command.validate, val.command);
    try expectEqual(render.OutputProfile.xhtml, val.html_profile.?);
}

test "parse: init takes an optional target directory" {
    var bare = try parseOptions(std.testing.allocator, &.{ "boris", "init" });
    defer bare.deinit(std.testing.allocator);
    try expectEqual(Command.init, bare.command);
    try expect(bare.init_dir == null);

    var with_dir = try parseOptions(std.testing.allocator, &.{ "boris", "init", "site" });
    defer with_dir.deinit(std.testing.allocator);
    try expectEqual(Command.init, with_dir.command);
    try expectEqualStrings("site", with_dir.init_dir.?);

    var quiet = try parseOptions(std.testing.allocator, &.{ "boris", "init", "--quiet" });
    defer quiet.deinit(std.testing.allocator);
    try expectEqual(Command.init, quiet.command);
    try expect(quiet.quiet);

    // The positional target may follow flags, not only the command token.
    var flag_first = try parseOptions(std.testing.allocator, &.{ "boris", "init", "--quiet", "site" });
    defer flag_first.deinit(std.testing.allocator);
    try expectEqual(Command.init, flag_first.command);
    try expectEqualStrings("site", flag_first.init_dir.?);
    try expect(flag_first.quiet);

    // init performs no compiler phase: mode/output/analysis flags are usage
    // errors, and the target directory is positional, so --input is not an
    // alias for it.
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "init", "--html-dir", "site" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "init", "--out", "ir" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "init", "--input", "docs" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "init", "--rag" }));
    try expectError(error.UnexpectedPositional, parseOptions(std.testing.allocator, &.{ "boris", "init", "a", "b" }));

    // `--help` / `-h` is init-specific help (exit 0), not the full compiler
    // help; execute() routes on the recorded command.
    var init_help = try parseOptions(std.testing.allocator, &.{ "boris", "init", "--help" });
    defer init_help.deinit(std.testing.allocator);
    try expect(init_help.help);
    try expectEqual(Command.init, init_help.command);

    var init_h = try parseOptions(std.testing.allocator, &.{ "boris", "init", "-h" });
    defer init_h.deinit(std.testing.allocator);
    try expect(init_h.help);
    try expectEqual(Command.init, init_h.command);
}

test "parse: plan selects an explicit profile and preserves only supported overrides" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris",      "plan",    "--profile", "profiles/site.json", "--input",       "docs",    "--textile",
        "--html-dir", "preview", "--jobs",    "4",                  "--incremental", "--quiet",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Command.plan, o.command);
    try expectEqual(Mode.html, o.mode);
    try expectEqualStrings("profiles/site.json", o.profile_path.?);
    try expectEqualStrings("docs", o.profile_input_override.?);
    try expectEqual(identity.InputFormat.textile, o.profile_input_format_override.?);
    try expectEqualStrings("preview", o.profile_html_output_override.?);
    try expectEqual(@as(usize, 4), o.jobs);
    try expect(o.incremental);
    try expect(o.quiet);
    try expectEqual(@as(usize, 0), o.targets.items.len);
}

test "parse: plan requires a profile and rejects execution or projection selectors" {
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "plan" }));
    var html_profile = try parseOptions(std.testing.allocator, &.{ "boris", "--profile", "site.json" });
    defer html_profile.deinit(std.testing.allocator);
    try expectEqual(Mode.html, html_profile.mode);
    try expectEqualStrings("site.json", html_profile.profile_path.?);
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--watch", "--profile", "site.json" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "validate", "--profile", "site.json" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "plan", "--profile", "a", "--profile", "b" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "plan", "--profile", "a", "--out", "out" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "plan", "--profile", "a", "--target", "public=dist" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "plan", "--profile", "a", "--watch" }));
}

test "parse: standard-site publish selects the family and its options" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris", "standard-site", "publish", "--profile",       "boris.json", "--plan",  "standard-site-plan.json",
        "--out", "evidence.json", "--prune", "--source-commit", "abc123",     "--quiet",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Command.standard_site, o.command);
    try expect(o.standard_site_publish);
    try expectEqualStrings("boris.json", o.profile_path.?);
    try expectEqualStrings("standard-site-plan.json", o.plan_path.?);
    try expectEqualStrings("evidence.json", o.publish_out.?);
    try expect(o.publish_prune);
    try expectEqualStrings("abc123", o.source_commit.?);
    try expect(o.quiet);
    try expectEqual(@as(usize, 0), o.targets.items.len);
}

test "parse: standard-site publish validates its contract" {
    // The network family requires the explicit subcommand and a profile.
    try expectError(error.MissingStandardSiteSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "standard-site" }));
    try expectError(error.UnknownStandardSiteSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "bogus" }));
    try expectError(error.MissingStandardSiteProfile, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--plan" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--prune", "--prune" }));
    // Compiler mode / projection selectors are usage errors: publish never
    // runs as a side effect of build/validate/watch/plan flags.
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--rag" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--target", "public=dist" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--watch" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--timings" }));
    var family_help = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "--help" });
    defer family_help.deinit(std.testing.allocator);
    try expect(family_help.help);
    try expectEqual(Command.standard_site, family_help.command);
    // --out is the evidence path here, never an IR mode selector.
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--out", "ev.json" });
    defer o.deinit(std.testing.allocator);
    try expectEqualStrings("ev.json", o.publish_out.?);
    try expectEqual(Mode.html, o.mode);
}

test "parse: standard-site plan emits the offline projection without network flags" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan", "--profile", "site.json", "--out", "plan.json" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(StandardSiteCommand.plan, o.standard_site_command);
    try expect(!o.standard_site_publish);
    try expectEqualStrings("site.json", o.profile_path.?);
    try expectEqualStrings("plan.json", o.plan_out.?);

    try expectError(error.MissingStandardSiteProfile, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan", "--profile", "a", "--did", "d" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan", "--profile", "a", "--prune" }));
}

test "parse: standard-site records emits full record payloads offline" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "records", "--profile", "site.json", "--out", "records.json" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(StandardSiteCommand.records, o.standard_site_command);
    try expect(!o.standard_site_publish);
    try expectEqualStrings("site.json", o.profile_path.?);
    try expectEqualStrings("records.json", o.records_out.?);

    try expectError(error.MissingStandardSiteProfile, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "records" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "records", "--profile", "a", "--did", "d" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "records", "--profile", "a", "--prune" }));
}

test "parse: standard-site verify checks a built output dir offline" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "verify", "--profile", "site.json", "--dist", "site-out", "--out", "verify.json" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(StandardSiteCommand.verify, o.standard_site_command);
    try expect(!o.standard_site_publish);
    try expectEqualStrings("site.json", o.profile_path.?);
    try expectEqualStrings("site-out", o.verify_dist);
    try expectEqualStrings("verify.json", o.verify_out.?);

    // Default dist dir when `--dist` is absent.
    var dflt = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "verify", "--profile", "site.json" });
    defer dflt.deinit(std.testing.allocator);
    try expectEqualStrings("dist", dflt.verify_dist);

    try expectError(error.MissingStandardSiteProfile, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "verify" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "verify", "--profile", "a", "--did", "d" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "verify", "--profile", "a", "--prune" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan", "--profile", "a", "--dist", "x" }));
}

test "parse: standard-site login requires a DID and persists the session root" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "did:plc:ewvi7nxzyoun6zhxrhs64oiz", "--session-root", "/tmp/boris-sessions" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Command.standard_site, o.command);
    try expectEqual(StandardSiteCommand.login, o.standard_site_command);
    try expect(!o.standard_site_publish);
    try expectEqualStrings("did:plc:ewvi7nxzyoun6zhxrhs64oiz", o.session_did.?);
    try expectEqualStrings("/tmp/boris-sessions", o.session_root.?);
}

test "parse: standard-site sessions lists without a DID" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "sessions", "--session-root", "/tmp/boris-sessions" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(StandardSiteCommand.sessions, o.standard_site_command);
    try expect(o.session_did == null);
    try expectEqualStrings("/tmp/boris-sessions", o.session_root.?);
}

test "parse: standard-site logout requires a DID and rejects compiler flags" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "logout", "--did", "did:plc:ewvi7nxzyoun6zhxrhs64oiz" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(StandardSiteCommand.logout, o.standard_site_command);

    var by_handle = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "logout", "--handle", "alice.bsky.social" });
    defer by_handle.deinit(std.testing.allocator);
    try expectEqualStrings("alice.bsky.social", by_handle.session_handle.?);
    try expect(by_handle.session_did == null);
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "logout", "--did", "a", "--handle", "b" }));
    try expectEqualStrings("did:plc:ewvi7nxzyoun6zhxrhs64oiz", o.session_did.?);

    try expectError(error.MissingStandardSiteIdentity, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login" }));
    try expectError(error.MissingStandardSiteIdentity, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "logout" }));
    try expectError(error.UnexpectedPositional, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "a", "extra" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "a", "--rag" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "a", "--profile", "p.json" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "sessions", "--did", "a" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--did", "d" }));
}

test "parse: standard-site login --app-password takes exactly one of --did or --handle" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--app-password", "--did", "did:plc:ewvi7nxzyoun6zhxrhs64oiz" });
    defer o.deinit(std.testing.allocator);
    try expect(o.app_password);
    try expectEqualStrings("did:plc:ewvi7nxzyoun6zhxrhs64oiz", o.session_did.?);
    try expect(o.session_handle == null);

    var h = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--app-password", "--handle", "Alice.Example.COM" });
    defer h.deinit(std.testing.allocator);
    try expect(h.app_password);
    try expect(h.session_did == null);
    try expectEqualStrings("Alice.Example.COM", h.session_handle.?);

    try expectError(error.MissingStandardSiteIdentity, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--app-password" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--app-password", "--did", "a", "--handle", "b" }));
    // The app-password flag is login-only.
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--app-password" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "logout", "--did", "a", "--app-password" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--app-password" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "sessions", "--app-password" }));
}

test "parse: standard-site smoke requires a DID and accepts its opt-in flags" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris",                          "standard-site",      "smoke",             "--did",               "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
        "--namespace",                    "boris-smoke-manual", "--surface-url",     "https://example.com", "--indexer",
        "https://public.api.example.com", "--out",              "smoke-result.json",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(StandardSiteCommand.smoke, o.standard_site_command);
    try expectEqualStrings("did:plc:ewvi7nxzyoun6zhxrhs64oiz", o.session_did.?);
    try expectEqualStrings("boris-smoke-manual", o.smoke_namespace.?);
    try expectEqualStrings("https://example.com", o.smoke_surface_url.?);
    try expectEqualStrings("https://public.api.example.com", o.smoke_indexer_origin.?);
    try expectEqualStrings("smoke-result.json", o.smoke_out.?);
}

test "parse: standard-site smoke validates its contract" {
    try expectError(error.MissingStandardSiteIdentity, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke" }));
    var handle = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--handle", "alice.bsky.social" });
    defer handle.deinit(std.testing.allocator);
    try expectEqualStrings("alice.bsky.social", handle.session_handle.?);
    try expect(handle.session_did == null);
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--handle", "b" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--profile", "p.json" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--plan", "plan.json" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--rag" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--namespace", "n" }));
    try expectError(error.ConflictingStandardSiteFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "a", "--indexer", "i" }));
    // --out is the smoke result path here, never an IR mode selector.
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--out", "smoke.json" });
    defer o.deinit(std.testing.allocator);
    try expectEqualStrings("smoke.json", o.smoke_out.?);
    try expectEqual(Mode.html, o.mode);
}

test "parse: nostr plan selects a profile and keeps content-scan overrides" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris", "nostr", "plan", "--profile", "profiles/site.json", "--input", "docs", "--quiet",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Command.nostr_plan, o.command);
    try expectEqualStrings("profiles/site.json", o.profile_path.?);
    // Unlike `plan`, this command compiles content, so the input overrides are
    // meaningful; the HTML output override is not, and is rejected below.
    try expectEqualStrings("docs", o.profile_input_override.?);
    try expect(o.quiet);
    try expect(!o.timings);
}

test "parse: nostr plan takes the cooklang and textile input overrides" {
    var cook = try parseOptions(std.testing.allocator, &.{ "boris", "nostr", "plan", "--profile", "a", "--cooklang" });
    defer cook.deinit(std.testing.allocator);
    try expectEqual(identity.InputFormat.cook, cook.profile_input_format_override.?);

    var textile = try parseOptions(std.testing.allocator, &.{ "boris", "nostr", "plan", "--profile", "a", "--textile" });
    defer textile.deinit(std.testing.allocator);
    try expectEqual(identity.InputFormat.textile, textile.profile_input_format_override.?);
}

test "parse: nostr subcommands are exactly plan, sign, and publish" {
    // A missing or unknown subcommand is named; each known one demands its
    // inputs.
    try expectError(error.UnknownNostrSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "nostr" }));
    try expectError(error.UnknownNostrSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "--profile", "a" }));
    try expectError(error.UnknownNostrSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "upload" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "plan" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign", "--plan", "plan.json" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--plan", "plan.json" }));
}

test "parse: nostr sign takes plan, key-stdin, out, prior, and created-at" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris", "nostr", "sign", "--plan", "plan.json", "--key-stdin", "--out", "bundle.json", "--prior", "old.json", "--created-at", "1720000000", "--quiet",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Command.nostr_sign, o.command);
    try expectEqualStrings("plan.json", o.nostr_plan_path.?);
    try expect(o.nostr_key_stdin);
    try expectEqualStrings("bundle.json", o.nostr_out_path.?);
    try expectEqualStrings("old.json", o.nostr_prior_path.?);
    try expectEqual(@as(i64, 1720000000), o.nostr_created_at.?);
    try expect(o.quiet);
}

test "parse: nostr sign rejects invalid values and foreign selectors" {
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign", "--plan", "p", "--key-stdin", "--created-at", "abc" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign", "--plan", "p", "--plan", "q" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign", "--plan", "p", "--key-stdin", "--profile", "a" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign", "--plan", "p", "--key-stdin", "--rag" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign", "--plan", "p", "--key-stdin", "--timings" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign", "--plan", "p", "--key-stdin", "--html-dir", "dist" }));
}

test "parse: nostr publish takes plan, bundle, and out" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris", "nostr", "publish", "--plan", "plan.json", "--bundle", "bundle.json", "--out", "report.json", "--quiet",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Command.nostr_publish, o.command);
    try expectEqualStrings("plan.json", o.nostr_plan_path.?);
    try expectEqualStrings("bundle.json", o.nostr_bundle_path.?);
    try expectEqualStrings("report.json", o.nostr_out_path.?);
    try expect(o.quiet);
}

test "parse: nostr publish rejects missing inputs and foreign selectors" {
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--plan", "p" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--bundle", "b" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--plan", "p", "--bundle", "b", "--bundle", "c" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--plan", "p", "--bundle", "b", "--profile", "a" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--plan", "p", "--bundle", "b", "--rag" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--plan", "p", "--bundle", "b", "--timings" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--plan", "p", "--bundle", "b", "--html-dir", "dist" }));
}

test "parse: nostr flags are command-scoped" {
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--key-stdin" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish", "--plan", "p", "--bundle", "b", "--key-stdin" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign", "--plan", "p", "--key-stdin", "--bundle", "x" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "plan", "--profile", "a", "--prior", "old.json" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan", "--profile", "a", "--bundle", "b" }));
}

test "parse: nostr plan owns stdout and rejects every other selector" {
    const rejected = [_][]const []const u8{
        &.{ "boris", "nostr", "plan", "--profile", "a", "--timings" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--html-dir", "dist" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--target", "public=dist" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--rss" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--llms" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--sitemap" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--rag" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--context" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--watch" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--incremental" },
        &.{ "boris", "nostr", "plan", "--profile", "a", "--format", "json" },
    };
    for (rejected) |args| {
        try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, args));
    }
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "plan", "--profile", "a", "--profile", "b" }));
}

test "parse: recipe-scale requires id and a scalable factor" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris",      "recipe-scale", "--input",   "docs/contracts/fixtures/cooklang-compatibility/content",
        "--id",       "carbonara",    "--factor",  "2",
        "--cooklang", "--out",        "view.json", "--quiet",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Command.recipe_scale, o.command);
    try expectEqualStrings("carbonara", o.recipe_scale_id.?);
    try expectEqualStrings("2", o.recipe_scale_factor.?);
    try expectEqualStrings("view.json", o.recipe_scale_out.?);
    try expectEqual(identity.InputFormat.cook, o.input_format);
    try expect(o.out_dir == null);
    try expect(o.quiet);

    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--factor", "2" }));
    var servings_opts = try parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--servings", "4" });
    defer servings_opts.deinit(std.testing.allocator);
    try expectEqualStrings("4", servings_opts.recipe_scale_servings.?);
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--factor", "2", "--servings", "4" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--servings", "0" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--factor", "0" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--factor", "some" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--factor", "1/0" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--factor", "2", "--rag" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--factor", "2", "--timings" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--id", "carbonara" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "recipe-scale", "--id", "carbonara", "--factor", "2", "--textile", "--cooklang" }));
}

test "parse: --out selects IR mode" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--out", ".boris" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.ir, o.mode);
    try expectEqualStrings(".boris", o.out_dir.?);
    try expect(o.html_dir == null);
    try expect(o.rag_dir == null);
}

test "parse: scoped and segmented exports stay on RAG/context surfaces" {
    var rag = try parseOptions(std.testing.allocator, &.{
        "boris", "--rag-dir", "uploads/rag", "--scope", "mascots", "--split-size", "262144", "--bundles-only",
    });
    defer rag.deinit(std.testing.allocator);
    try expectEqual(Mode.rag, rag.mode);
    try expectEqualStrings("mascots", rag.scope.?);
    try expectEqual(@as(usize, 262144), rag.split_size.?);
    try expect(rag.bundles_only);

    var context = try parseOptions(std.testing.allocator, &.{
        "boris", "--context-dir", "uploads/context", "--scope", "mascots/genny", "--split-size=131072",
    });
    defer context.deinit(std.testing.allocator);
    try expectEqual(Mode.context, context.mode);
    try expectEqualStrings("mascots/genny", context.scope.?);
    try expectEqual(@as(usize, 131072), context.split_size.?);
    try expect(!context.bundles_only);

    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--rag", "--split-size", "0" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--scope", "mascots" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--context", "--bundles-only" }));
}

test "parse: valid modes table" {
    const Case = struct {
        args: []const []const u8,
        mode: Mode,
        input: []const u8,
        out: ?[]const u8,
        rag: ?[]const u8,
        html: ?[]const u8,
        quiet: bool,
        jobs: usize = 1,
    };

    const cases = [_]Case{
        .{
            .args = &.{ "boris", "--no-rag" },
            .mode = .ir,
            .input = "content",
            .out = ".boris",
            .rag = null,
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag" },
            .mode = .rag,
            .input = "content",
            .out = null,
            .rag = "rag",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag-dir", "uploads/rag" },
            .mode = .rag,
            .input = "content",
            .out = null,
            .rag = "uploads/rag",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag-dir=x" },
            .mode = .rag,
            .input = "content",
            .out = null,
            .rag = "x",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag", "--rag-dir", "custom" },
            .mode = .rag,
            .input = "content",
            .out = null,
            .rag = "custom",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--input", "docs", "--out", "build/ir", "--quiet" },
            .mode = .ir,
            .input = "docs",
            .out = "build/ir",
            .rag = null,
            .html = null,
            .quiet = true,
        },
        .{
            .args = &.{ "boris", "--input=site", "--no-rag", "--out=.boris" },
            .mode = .ir,
            .input = "site",
            .out = ".boris",
            .rag = null,
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--rag", "--input", "c", "--quiet" },
            .mode = .rag,
            .input = "c",
            .out = null,
            .rag = "rag",
            .html = null,
            .quiet = true,
        },
        .{
            .args = &.{ "boris", "--rag", "--input=c", "--rag-dir=out-rag" },
            .mode = .rag,
            .input = "c",
            .out = null,
            .rag = "out-rag",
            .html = null,
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html-dir", "site/out" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "site/out",
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html-dir=x" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "x",
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html", "--html-dir", "custom-dist" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "custom-dist",
            .quiet = false,
        },
        .{
            .args = &.{ "boris", "--html", "--input", "docs", "--quiet" },
            .mode = .html,
            .input = "docs",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = true,
        },
        .{
            .args = &.{ "boris", "--html", "--jobs", "4" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = false,
            .jobs = 4,
        },
        .{
            .args = &.{ "boris", "--html-dir", "custom-dist", "-j=8" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "custom-dist",
            .quiet = false,
            .jobs = 8,
        },
        // HTML-only flags without --html are valid under the HTML default.
        .{
            .args = &.{ "boris", "--jobs", "4" },
            .mode = .html,
            .input = "content",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = false,
            .jobs = 4,
        },
        .{
            .args = &.{ "boris", "--input", "docs", "--quiet" },
            .mode = .html,
            .input = "docs",
            .out = null,
            .rag = null,
            .html = "dist",
            .quiet = true,
        },
        .{
            .args = &.{ "boris", "--out", ".boris" },
            .mode = .ir,
            .input = "content",
            .out = ".boris",
            .rag = null,
            .html = null,
            .quiet = false,
        },
    };

    for (cases) |c| {
        var o = try parseOptions(std.testing.allocator, c.args);
        errdefer o.deinit(std.testing.allocator);
        try expectEqual(c.mode, o.mode);
        try expectEqualStrings(c.input, o.input_dir);
        try expectEqual(c.quiet, o.quiet);
        try expectEqual(c.jobs, o.jobs);
        if (c.out) |want| {
            try expectEqualStrings(want, o.out_dir.?);
        } else {
            try expect(o.out_dir == null);
        }
        if (c.rag) |want| {
            try expectEqualStrings(want, o.rag_dir.?);
        } else {
            try expect(o.rag_dir == null);
        }
        if (c.html) |want| {
            try expectEqualStrings(want, o.html_dir.?);
        } else {
            try expect(o.html_dir == null);
        }
        o.deinit(std.testing.allocator);
    }
}

test "parse: conflicts and missing values table" {
    const Case = struct {
        args: []const []const u8,
        err: ParseError,
    };

    const cases = [_]Case{
        // Rule 5: --rag + --no-rag
        .{ .args = &.{ "boris", "--rag", "--no-rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--no-rag", "--rag" }, .err = error.ConflictingFlags },
        // Rule 6: --no-rag + --rag-dir
        .{ .args = &.{ "boris", "--no-rag", "--rag-dir", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--rag-dir", "x", "--no-rag" }, .err = error.ConflictingFlags },
        // Rule 7: explicit --out with RAG selection
        .{ .args = &.{ "boris", "--rag", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--out", "x", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--rag-dir", "r", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--out=x", "--rag-dir=r" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--out", "x", "--rag", "--rag-dir", "r" }, .err = error.ConflictingFlags },
        // HTML exclusive of RAG and explicit --out
        .{ .args = &.{ "boris", "--html", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--rag-dir", "r" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html-dir", "d", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html-dir", "d", "--rag-dir", "r" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html-dir", "d", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--out=x", "--html" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--rag-dir=r", "--html-dir=d" }, .err = error.ConflictingFlags },
        // Complete-corpus RAG owns the whole tree: scope, pack target, and
        // bundle-style flags are working-mode surfaces.
        .{ .args = &.{ "boris", "--rag", "--complete", "--scope", "mascots" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--complete", "--scope=mascots", "--rag-dir", "r" }, .err = error.ConflictingFlags },
        // Rule 8: empty values
        .{ .args = &.{ "boris", "--input", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--out", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--rag-dir", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--html-dir", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--input=" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--out=" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--rag-dir=" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--html-dir=" }, .err = error.EmptyValue },
        // Rule 9: unknown, missing value, positional, duplicates
        .{ .args = &.{ "boris", "--unknown" }, .err = error.UnknownFlag },
        .{ .args = &.{ "boris", "-v" }, .err = error.UnknownFlag },
        .{ .args = &.{ "boris", "--wat" }, .err = error.UnknownFlag },
        .{ .args = &.{ "boris", "--input" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--out" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--rag-dir" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--html-dir" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "content" }, .err = error.UnexpectedPositional },
        .{ .args = &.{ "boris", "extra", "args" }, .err = error.UnexpectedPositional },
        .{ .args = &.{ "boris", "--rag", "--rag" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--no-rag", "--no-rag" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--html", "--html" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--quiet", "--quiet" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--input", "a", "--input", "b" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--out", "a", "--out", "b" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--rag-dir", "a", "--rag-dir", "b" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--html-dir", "a", "--html-dir", "b" }, .err = error.DuplicateFlag },
        // Jobs option tests (valid alone under HTML default; conflict with IR/RAG)
        .{ .args = &.{ "boris", "--jobs", "4", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--jobs", "4", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--jobs", "4", "--no-rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--jobs", "0" }, .err = error.InvalidValue },
        .{ .args = &.{ "boris", "--html", "--jobs", "65" }, .err = error.InvalidValue },
        .{ .args = &.{ "boris", "--html", "--jobs", "abc" }, .err = error.InvalidValue },
        .{ .args = &.{ "boris", "--html", "--jobs", "" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--html", "--jobs=" }, .err = error.EmptyValue },
        .{ .args = &.{ "boris", "--html", "--jobs" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--html", "-j" }, .err = error.MissingValue },
        .{ .args = &.{ "boris", "--html", "--jobs", "4", "--jobs", "8" }, .err = error.DuplicateFlag },
        // Watch option tests (valid alone under HTML default; conflict with IR/RAG)
        .{ .args = &.{ "boris", "--watch", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--watch", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--watch", "--no-rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--watch", "--watch" }, .err = error.DuplicateFlag },
        .{ .args = &.{ "boris", "--html", "--watch", "--rag" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--html", "--watch", "--out", "x" }, .err = error.ConflictingFlags },
        .{ .args = &.{ "boris", "--incremental", "--out", "x" }, .err = error.ConflictingFlags },
    };

    for (cases) |c| {
        try expectError(c.err, parseOptions(std.testing.allocator, c.args));
    }
}

test "parse: --watch with HTML implies incremental" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--html", "--watch" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o.mode);
    try expect(o.watch);
    try expect(o.incremental);
    try expectEqualStrings(default_html_dir, o.html_dir.?);

    var o2 = try parseOptions(std.testing.allocator, &.{ "boris", "--html-dir", "site", "--watch", "--jobs", "2" });
    defer o2.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o2.mode);
    try expect(o2.watch);
    try expect(o2.incremental);
    try expectEqual(@as(usize, 2), o2.jobs);
    try expectEqualStrings("site", o2.html_dir.?);

    // Explicit --incremental with --watch remains valid
    var o3 = try parseOptions(std.testing.allocator, &.{ "boris", "--html", "--watch", "--incremental" });
    defer o3.deinit(std.testing.allocator);
    try expect(o3.watch);
    try expect(o3.incremental);

    // Bare --watch is valid under HTML default
    var o4 = try parseOptions(std.testing.allocator, &.{ "boris", "--watch" });
    defer o4.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o4.mode);
    try expect(o4.watch);
    try expect(o4.incremental);
}

test "parse: help/version short-circuit and do not validate trailing junk" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "--help", "--not-a-real-flag", "--rag", "--no-rag" });
    defer o.deinit(std.testing.allocator);
    try expect(o.help);
    try expect(!o.version);

    var o2 = try parseOptions(std.testing.allocator, &.{ "boris", "-h" });
    defer o2.deinit(std.testing.allocator);
    try expect(o2.help);
    try expect(!o2.version);

    var o3 = try parseOptions(std.testing.allocator, &.{ "boris", "--version", "--not-a-real-flag" });
    defer o3.deinit(std.testing.allocator);
    try expect(o3.version);
    try expect(!o3.help);

    var o4 = try parseOptions(std.testing.allocator, &.{ "boris", "-V" });
    defer o4.deinit(std.testing.allocator);
    try expect(o4.version);
    try expect(!o4.help);

    // First flag wins when both appear.
    var o5 = try parseOptions(std.testing.allocator, &.{ "boris", "--version", "--help" });
    defer o5.deinit(std.testing.allocator);
    try expect(o5.version);
    try expect(!o5.help);

    // Targets accumulated before the short-circuit must be released, not
    // leaked: std.testing.allocator fails the test if the allocation survives.
    var o6 = try parseOptions(std.testing.allocator, &.{ "boris", "--target", "a=dist", "--help" });
    defer o6.deinit(std.testing.allocator);
    try expect(o6.help);
    try expectEqual(@as(usize, 0), o6.targets.items.len);

    var o7 = try parseOptions(std.testing.allocator, &.{ "boris", "--target", "a=dist", "--version" });
    defer o7.deinit(std.testing.allocator);
    try expect(o7.version);
    try expectEqual(@as(usize, 0), o7.targets.items.len);
}

test "parse: --build-info joins the short-circuit family" {
    // #776: --build-info is a stdout query surface like --version.
    var o1 = try parseOptions(std.testing.allocator, &.{ "boris", "--build-info" });
    defer o1.deinit(std.testing.allocator);
    try expect(o1.build_info);
    try expect(!o1.help);
    try expect(!o1.version);

    // First flag wins across the whole query family.
    var o2 = try parseOptions(std.testing.allocator, &.{ "boris", "--help", "--build-info" });
    defer o2.deinit(std.testing.allocator);
    try expect(o2.help);
    try expect(!o2.build_info);

    var o3 = try parseOptions(std.testing.allocator, &.{ "boris", "--build-info", "--not-a-real-flag" });
    defer o3.deinit(std.testing.allocator);
    try expect(o3.build_info);

    // Targets accumulated before the short-circuit are released.
    var o4 = try parseOptions(std.testing.allocator, &.{ "boris", "--target", "a=dist", "--build-info" });
    defer o4.deinit(std.testing.allocator);
    try expect(o4.build_info);
    try expectEqual(@as(usize, 0), o4.targets.items.len);
}

test "execute: help does not invoke pipeline (dependency injection)" {
    const Spy = struct {
        pipeline_calls: usize = 0,
        help_calls: usize = 0,
        version_calls: usize = 0,

        pub fn printVersion(self: *@This()) void {
            self.version_calls += 1;
        }

        pub fn printHelp(self: *@This()) void {
            self.help_calls += 1;
        }

        pub fn run(self: *@This(), opts: Options) ExitCode {
            _ = opts;
            self.pipeline_calls += 1;
            return .success;
        }
    };

    var spy: Spy = .{};
    var opts = try parseOptions(std.testing.allocator, &.{ "boris", "--help" });
    defer opts.deinit(std.testing.allocator);
    const code = execute(opts, &spy);
    try expectEqual(ExitCode.success, code);
    try expectEqual(@as(usize, 1), spy.help_calls);
    try expectEqual(@as(usize, 0), spy.pipeline_calls);
}

test "execute: version does not invoke pipeline (dependency injection)" {
    const Spy = struct {
        pipeline_calls: usize = 0,
        help_calls: usize = 0,
        version_calls: usize = 0,

        pub fn printVersion(self: *@This()) void {
            self.version_calls += 1;
        }

        pub fn printHelp(self: *@This()) void {
            self.help_calls += 1;
        }

        pub fn run(self: *@This(), opts: Options) ExitCode {
            _ = opts;
            self.pipeline_calls += 1;
            return .success;
        }
    };

    var spy: Spy = .{};
    var opts = try parseOptions(std.testing.allocator, &.{ "boris", "--version" });
    defer opts.deinit(std.testing.allocator);
    const code = execute(opts, &spy);
    try expectEqual(ExitCode.success, code);
    try expectEqual(@as(usize, 1), spy.version_calls);
    try expectEqual(@as(usize, 0), spy.help_calls);
    try expectEqual(@as(usize, 0), spy.pipeline_calls);
}

test "execute: build mode invokes pipeline once" {
    const Spy = struct {
        pipeline_calls: usize = 0,
        last_mode: ?Mode = null,

        pub fn printVersion(self: *@This()) void {
            _ = self;
        }

        pub fn printHelp(self: *@This()) void {
            _ = self;
        }

        pub fn run(self: *@This(), opts: Options) ExitCode {
            self.pipeline_calls += 1;
            self.last_mode = opts.mode;
            return .success;
        }
    };

    var spy: Spy = .{};
    var opts = try parseOptions(std.testing.allocator, &.{ "boris", "--rag-dir", "x" });
    defer opts.deinit(std.testing.allocator);
    const code = execute(opts, &spy);
    try expectEqual(ExitCode.success, code);
    try expectEqual(@as(usize, 1), spy.pipeline_calls);
    try expectEqual(Mode.rag, spy.last_mode.?);
}

test "runArgs: usage errors exit 2; help/version exit 0" {
    const Spy = struct {
        gpa: std.mem.Allocator = std.testing.allocator,
        pipeline_calls: usize = 0,
        version_calls: usize = 0,

        pub fn printVersion(self: *@This()) void {
            self.version_calls += 1;
        }

        pub fn printHelp(self: *@This()) void {
            _ = self;
        }

        pub fn reportUsage(self: *@This(), err: ParseError, bad_arg: ?[]const u8, detail: *const ParseErrorDetail) void {
            _ = self;
            _ = @errorName(err);
            _ = bad_arg;
            _ = detail;
        }

        pub fn run(self: *@This(), opts: Options) ExitCode {
            _ = opts;
            self.pipeline_calls += 1;
            return .success;
        }
    };

    var spy: Spy = .{};
    try expectEqual(@as(u8, 0), runArgs(&.{ "boris", "--help" }, &spy));
    try expectEqual(@as(usize, 0), spy.pipeline_calls);

    try expectEqual(@as(u8, 0), runArgs(&.{ "boris", "--version" }, &spy));
    try expectEqual(@as(u8, 0), runArgs(&.{ "boris", "-V" }, &spy));
    try expectEqual(@as(usize, 2), spy.version_calls);
    try expectEqual(@as(usize, 0), spy.pipeline_calls);

    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--rag", "--no-rag" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--rag", "--out", "x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--html", "--rag" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--html", "--out", "x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--unknown" }, &spy));
    try expectEqual(@as(usize, 0), spy.pipeline_calls);

    try expectEqual(@as(u8, 0), runArgs(&.{ "boris", "--rag-dir", "x" }, &spy));
    try expectEqual(@as(u8, 0), runArgs(&.{ "boris", "--html" }, &spy));
    try expectEqual(@as(usize, 2), spy.pipeline_calls);
}

test "parse: --target flag parsing and conflict checks" {
    // Normal multi-target parsing
    {
        var o = try parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod", "--target", "stage=dist/stage" });
        defer o.deinit(std.testing.allocator);
        try expectEqual(Mode.html, o.mode);
        try expectEqual(@as(usize, 2), o.targets.items.len);
        try expectEqualStrings("prod", o.targets.items[0].name);
        try expectEqualStrings("dist/prod", o.targets.items[0].output_dir);
        try expectEqualStrings("stage", o.targets.items[1].name);
        try expectEqualStrings("dist/stage", o.targets.items[1].output_dir);
    }

    // Conflict with --html-dir
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod", "--html-dir", "custom" }));

    // Conflict with --out
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod", "--out", "x" }));

    // Conflict with --rag
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod", "--rag" }));

    // Invalid values
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target", "=dist/prod" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod/site=dist" }));

    // Duplicate target flag
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "--target", "prod=dist/prod1", "--target", "prod=dist/prod2" }));

    // Global + per-target layouts
    {
        var o = try parseOptions(std.testing.allocator, &.{
            "boris",
            "--target",
            "prod=dist/prod",
            "--target",
            "stage=dist/stage",
            "--html-layout",
            "layouts/main.html",
            "--target-layout",
            "stage=layouts/stage.html",
        });
        defer o.deinit(std.testing.allocator);
        try expectEqualStrings("layouts/main.html", o.html_layout);
        try expect(o.targets.items[0].layout_path == null);
        try expectEqualStrings("layouts/stage.html", o.targets.items[1].layout_path.?);
    }

    // Unknown target-layout name
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{
        "boris", "--target", "prod=dist/prod", "--target-layout", "nope=layouts/x.html",
    }));
}

test "findBadArg reports --target" {
    try expectEqualStrings("--target", findBadArg(&.{ "boris", "--target" }).?);
    try expectEqualStrings("--target=", findBadArg(&.{ "boris", "--target=" }).?);
    try expectEqualStrings("--target=bad", findBadArg(&.{ "boris", "--target=bad" }).?);
    try expectEqualStrings("--html-layout", findBadArg(&.{ "boris", "--html-layout" }).?);
    try expectEqualStrings("--target-layout", findBadArg(&.{ "boris", "--target-layout" }).?);
}

test "findBadArg never blames a boolean mode flag" {
    // `--rss` / `--sitemap` / `--context` / `--llms` are mode flags, not
    // value flags: a failure with them present must be attributed to the
    // actual offending token, never to the mode flag itself (#405, #407).
    // Value flags (--rss-path, --input, ...) are still reported by design:
    // findBadArg is best-effort and returns the first non-boolean token.
    try expectEqualStrings("--bogus", findBadArg(&.{ "boris", "--rss", "--bogus" }).?);
    try expectEqualStrings("--bogus", findBadArg(&.{ "boris", "--sitemap", "--bogus" }).?);
    try expectEqualStrings("--bogus", findBadArg(&.{ "boris", "--context", "--bogus" }).?);
    try expectEqualStrings("--bogus", findBadArg(&.{ "boris", "--llms", "--bogus" }).?);
}

test "parse: --theme sugar selects theme layouts/main.html" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris", "--theme", "experimental-theme",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o.mode);
    try expectEqualStrings("experimental-theme/layouts/main.html", o.html_layout);
    try expect(o.owned_html_layout);

    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{
        "boris", "--theme", "t", "--html-layout", "layouts/main.html",
    }));
}

test "parse: equivalent --target order yields equivalent configuration" {
    var a = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target",
        "stage=dist/stage",
        "--target",
        "prod=dist/prod",
        "--target-layout",
        "stage=layouts/stage.html",
    });
    defer a.deinit(std.testing.allocator);
    var b = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target",
        "prod=dist/prod",
        "--target",
        "stage=dist/stage",
        "--target-layout",
        "stage=layouts/stage.html",
    });
    defer b.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 2), a.targets.items.len);
    try expectEqual(@as(usize, 2), b.targets.items.len);
    try expectEqualStrings("prod", a.targets.items[0].name);
    try expectEqualStrings("stage", a.targets.items[1].name);
    try expectEqualStrings(a.targets.items[0].name, b.targets.items[0].name);
    try expectEqualStrings(a.targets.items[1].name, b.targets.items[1].name);
    try expectEqualStrings(a.targets.items[0].output_dir, b.targets.items[0].output_dir);
    try expectEqualStrings(a.targets.items[1].output_dir, b.targets.items[1].output_dir);
    try expect(a.targets.items[0].layout_path == null);
    try expect(b.targets.items[0].layout_path == null);
    try expectEqualStrings("layouts/stage.html", a.targets.items[1].layout_path.?);
    try expectEqualStrings(a.targets.items[1].layout_path.?, b.targets.items[1].layout_path.?);
}

test "parse: --target-layout order relative to --target is independent" {
    var before = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target-layout",
        "prod=layouts/prod.html",
        "--target",
        "prod=dist/prod",
        "--target",
        "stage=dist/stage",
    });
    defer before.deinit(std.testing.allocator);
    var after = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target",
        "stage=dist/stage",
        "--target",
        "prod=dist/prod",
        "--target-layout",
        "prod=layouts/prod.html",
    });
    defer after.deinit(std.testing.allocator);

    try expectEqualStrings("prod", before.targets.items[0].name);
    try expectEqualStrings("stage", before.targets.items[1].name);
    try expectEqualStrings("layouts/prod.html", before.targets.items[0].layout_path.?);
    try expect(before.targets.items[1].layout_path == null);
    try expectEqualStrings(before.targets.items[0].name, after.targets.items[0].name);
    try expectEqualStrings(before.targets.items[0].layout_path.?, after.targets.items[0].layout_path.?);
    try expectEqualStrings(before.targets.items[1].output_dir, after.targets.items[1].output_dir);
}

test "parse: bare HTML and --html map to default target; --target-layout attaches" {
    var bare = try parseOptions(std.testing.allocator, &.{"boris"});
    defer bare.deinit(std.testing.allocator);
    try expectEqual(Mode.html, bare.mode);
    try expectEqual(@as(usize, 1), bare.targets.items.len);
    try expectEqualStrings("default", bare.targets.items[0].name);
    try expectEqualStrings(default_html_dir, bare.targets.items[0].output_dir);

    var html = try parseOptions(std.testing.allocator, &.{ "boris", "--html", "--html-dir", "site-out" });
    defer html.deinit(std.testing.allocator);
    try expectEqualStrings("default", html.targets.items[0].name);
    try expectEqualStrings("site-out", html.targets.items[0].output_dir);

    var layout_only = try parseOptions(std.testing.allocator, &.{
        "boris", "--target-layout", "default=layouts/alt.html",
    });
    defer layout_only.deinit(std.testing.allocator);
    try expectEqual(Mode.html, layout_only.mode);
    try expectEqualStrings("default", layout_only.targets.items[0].name);
    try expectEqualStrings("layouts/alt.html", layout_only.targets.items[0].layout_path.?);
    try expectEqualStrings(default_html_dir, layout_only.targets.items[0].output_dir);
}

test "parse: --target with --watch and --incremental" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target",
        "prod=dist/prod",
        "--target",
        "stage=dist/stage",
        "--watch",
        "--incremental",
        "--jobs",
        "2",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o.mode);
    try expect(o.watch);
    try expect(o.incremental);
    try expectEqual(@as(usize, 2), o.jobs);
    try expectEqual(@as(usize, 2), o.targets.items.len);
    try expectEqualStrings("prod", o.targets.items[0].name);
    try expectEqualStrings("stage", o.targets.items[1].name);
    try expect(o.html_dir == null);

    var w = try parseOptions(std.testing.allocator, &.{
        "boris", "--target=a=dist/a", "--watch",
    });
    defer w.deinit(std.testing.allocator);
    try expect(w.watch);
    try expect(w.incremental);
    try expectEqualStrings("a", w.targets.items[0].name);
}

test "runArgs: invalid target parse errors exit 2" {
    const Spy = struct {
        gpa: std.mem.Allocator = std.testing.allocator,
        pipeline_calls: usize = 0,

        pub fn printVersion(self: *@This()) void {
            _ = self;
        }

        pub fn printHelp(self: *@This()) void {
            _ = self;
        }

        pub fn reportUsage(self: *@This(), err: ParseError, bad_arg: ?[]const u8, detail: *const ParseErrorDetail) void {
            _ = self;
            _ = @errorName(err);
            _ = bad_arg;
            _ = detail;
        }

        pub fn run(self: *@This(), opts: Options) ExitCode {
            _ = opts;
            self.pipeline_calls += 1;
            return .success;
        }
    };

    var spy: Spy = .{};
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "bad/name=dist" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod=dist/p", "--target", "prod=dist/q" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod=dist/p", "--html-dir", "x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod=dist/p", "--out", "x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target", "prod=dist/p", "--target-layout", "nope=x" }, &spy));
    try expectEqual(@as(u8, 2), runArgs(&.{ "boris", "--target-layout", "nope=layouts/x.html" }, &spy));
    try expectEqual(@as(usize, 0), spy.pipeline_calls);

    try expectEqual(@as(u8, 0), runArgs(&.{
        "boris", "--target", "b=dist/b", "--target", "a=dist/a", "--watch", "--incremental",
    }, &spy));
    try expectEqual(@as(usize, 1), spy.pipeline_calls);
}

test "parse: --layout-rule attaches to default and named targets" {
    var o = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--theme",
        "experimental-theme",
        "--layout-rule",
        "default",
        "id:index",
        "experimental-theme/layouts/home.html",
        "--layout-rule",
        "default",
        "role:trunk",
        "experimental-theme/layouts/section.html",
    });
    defer o.deinit(std.testing.allocator);
    try expectEqual(Mode.html, o.mode);
    try expectEqual(@as(usize, 1), o.targets.items.len);
    try expectEqualStrings("default", o.targets.items[0].name);
    try expectEqual(@as(usize, 2), o.targets.items[0].layout_rules.len);
    // Canonical sort: id before role
    try expectEqual(layout_select.SelectorKind.id, o.targets.items[0].layout_rules[0].kind);
    try expectEqualStrings("index", o.targets.items[0].layout_rules[0].value);
    try expectEqual(layout_select.SelectorKind.role, o.targets.items[0].layout_rules[1].kind);
}

test "parse: --layout-rule order independent; unknown target and bad selector fail" {
    var a = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--layout-rule",
        "prod",
        "id:index",
        "layouts/home.html",
        "--target",
        "prod=dist/prod",
        "--layout-rule",
        "prod",
        "role:trunk",
        "layouts/section.html",
    });
    defer a.deinit(std.testing.allocator);
    var b = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--target",
        "prod=dist/prod",
        "--layout-rule",
        "prod",
        "role:trunk",
        "layouts/section.html",
        "--layout-rule",
        "prod",
        "id:index",
        "layouts/home.html",
    });
    defer b.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 2), a.targets.items[0].layout_rules.len);
    try expectEqual(a.targets.items[0].layout_rules[0].kind, b.targets.items[0].layout_rules[0].kind);
    try expectEqualStrings(a.targets.items[0].layout_rules[0].value, b.targets.items[0].layout_rules[0].value);

    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{
        "boris", "--target", "prod=dist/p", "--layout-rule", "nope", "id:index", "layouts/x.html",
    }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{
        "boris", "--layout-rule", "default", "layout:home", "layouts/x.html",
    }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{
        "boris", "--layout-rule", "default", "glob:ref*", "layouts/x.html",
    }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{
        "boris",
        "--layout-rule",
        "default",
        "id:index",
        "layouts/a.html",
        "--layout-rule",
        "default",
        "id:index",
        "layouts/b.html",
    }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{
        "boris", "--layout-rule", "default", "id:index", "layouts/a.html", "--out", ".boris",
    }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{
        "boris", "--layout-rule", "default", "id:index", "layouts/a.html", "--rag",
    }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{
        "boris", "--layout-rule", "default", "id:index",
    }));
}

test "parse: layout paths reject .. absolute and backslash escapes" {
    const gpa = std.testing.allocator;
    // --layout-rule
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--layout-rule", "default", "id:index", "../layouts/main.html", "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--layout-rule", "default", "id:index", "/abs/main.html", "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--layout-rule", "default", "id:index", "theme/layouts/../layouts/main.html", "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--layout-rule", "default", "id:index", "layouts\\main.html", "--html-dir", "d",
    }));
    // --html-layout
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--html-layout", "../layouts/main.html", "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--html-layout", "/tmp/escape.html", "--html-dir", "d",
    }));
    // --target-layout
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--target", "prod=dist/prod", "--target-layout", "prod=../layouts/x.html",
    }));
    // --theme root
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--theme", "../evil-theme", "--html-dir", "d",
    }));
    try expectError(error.InvalidValue, parseOptions(gpa, &.{
        "boris", "--theme", "/abs/theme", "--html-dir", "d",
    }));
    // Valid relative forms still parse.
    var ok = try parseOptions(gpa, &.{
        "boris",
        "--html-layout",
        "layouts/main.html",
        "--layout-rule",
        "default",
        "id:index",
        "themes/docs/layouts/home.html",
        "--html-dir",
        "d",
    });
    defer ok.deinit(gpa);
    try expectEqualStrings("layouts/main.html", ok.html_layout);
}

test "parse: llms mode and path" {
    var opts = try parseOptions(std.testing.allocator, &.{ "boris", "--llms-path", "public/llms.txt", "--input", "docs" });
    defer opts.deinit(std.testing.allocator);
    try expectEqual(Mode.llms, opts.mode);
    try expectEqualStrings("public/llms.txt", opts.llms_path.?);
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--llms", "--rag" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--llms", "--html" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--llms-path", "/tmp/llms.txt" }));
}

test "parse: RSS mode, required channel settings, and conflicts" {
    var opts = try parseOptions(std.testing.allocator, &.{ "boris", "--rss-path", "public/rss.xml", "--site-url", "https://example.test/docs/", "--rss-title=Docs", "--rss-description", "Recent updates", "--rss-limit", "20" });
    defer opts.deinit(std.testing.allocator);
    try expectEqual(Mode.rss, opts.mode);
    try expectEqualStrings("public/rss.xml", opts.rss_path.?);
    try expectEqualStrings("https://example.test/docs/", opts.site_url.?);
    // A bare mode flag or a supplied path is not "missing a value": the
    // missing channel metadata is what the parse must report (#405, #407).
    try expectError(error.RSSMetadataRequired, parseOptions(std.testing.allocator, &.{ "boris", "--rss", "--site-url", "https://example.test", "--rss-title", "Docs" }));
    try expectError(error.RSSMetadataRequired, parseOptions(std.testing.allocator, &.{ "boris", "--rss", "--input", "content" }));
    try expectError(error.RSSMetadataRequired, parseOptions(std.testing.allocator, &.{ "boris", "--rss-path", "out.xml", "--site-url", "https://example.test" }));
    try expectError(error.InvalidRssLimit, parseOptions(std.testing.allocator, &.{ "boris", "--rss", "--site-url", "https://example.test", "--rss-title", "Docs", "--rss-description", "D", "--rss-limit", "0" }));
    try expectError(error.InvalidRssLimit, parseOptions(std.testing.allocator, &.{ "boris", "--rss", "--site-url", "https://example.test", "--rss-title", "Docs", "--rss-description", "D", "--rss-limit", "abc" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--rss", "--rag", "--site-url", "https://example.test", "--rss-title", "Docs", "--rss-description", "D" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "check", "--rss", "--site-url", "https://example.test", "--rss-title", "Docs", "--rss-description", "D" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--rss", "--site-url", "relative", "--rss-title", "Docs", "--rss-description", "D" }));
}

test "parse: sitemap selection implication validation conflicts and RSS compatibility" {
    var defaults = try parseOptions(std.testing.allocator, &.{ "boris", "--sitemap", "--site-url", "https://example.test/docs/" });
    defer defaults.deinit(std.testing.allocator);
    try expectEqual(Mode.html, defaults.mode);
    try expectEqualStrings("sitemap.xml", defaults.sitemap_path.?);
    try expectEqualStrings("https://example.test/docs/", defaults.site_url.?);

    var custom = try parseOptions(std.testing.allocator, &.{ "boris", "--sitemap-path", "meta/discovery.xml", "--site-url=https://example.test" });
    defer custom.deinit(std.testing.allocator);
    try expectEqual(Mode.html, custom.mode);
    try expectEqualStrings("meta/discovery.xml", custom.sitemap_path.?);

    try expectError(error.SitemapSiteUrlRequired, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap-path" }));
    try expectError(error.EmptyValue, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap-path=" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap", "--sitemap", "--site-url", "https://example.test" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap-path", "a.xml", "--sitemap-path", "b.xml", "--site-url", "https://example.test" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap", "--site-url", "https://example.test", "--site-url", "https://other.test" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap-path", "../sitemap.xml", "--site-url", "https://example.test" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap-path", "/sitemap.xml", "--site-url", "https://example.test" }));
    try expectError(error.InvalidValue, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap", "--site-url", "mailto:webmaster@example.test" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap", "--site-url", "https://example.test", "--no-rag" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap", "--site-url", "https://example.test", "--rss", "--rss-title", "Docs", "--rss-description", "D" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--sitemap", "--site-url", "https://example.test", "--target", "public=dist/public", "--target", "preview=dist/preview" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "check", "--sitemap", "--site-url", "https://example.test" }));

    var rss_opts = try parseOptions(std.testing.allocator, &.{ "boris", "--rss", "--site-url", "https://example.test", "--rss-title", "Docs", "--rss-description", "D" });
    defer rss_opts.deinit(std.testing.allocator);
    try expectEqual(Mode.rss, rss_opts.mode);
    try std.testing.expect(rss_opts.sitemap_path == null);
}

test "parse: normalized Pages location is required as one three-part identity" {
    var project = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--sitemap",
        "--site-url",
        "https://owner.github.io/boris",
        "--pages-base-url",
        "https://owner.github.io/boris/",
        "--pages-origin",
        "https://owner.github.io/",
        "--pages-base-path",
        "/boris/",
    });
    defer project.deinit(std.testing.allocator);
    try expect(project.publication_location != null);
    try expectEqualStrings("https://owner.github.io/boris", project.publication_location.?.base_url);
    try expectEqualStrings("/boris", project.publication_location.?.base_path);

    var root = try parseOptions(std.testing.allocator, &.{
        "boris",
        "--llms",
        "--pages-base-url=https://owner.github.io",
        "--pages-origin=https://owner.github.io",
        "--pages-base-path=",
    });
    defer root.deinit(std.testing.allocator);
    try expectEqual(Mode.llms, root.mode);
    try expectEqualStrings("", root.publication_location.?.base_path);

    try expectError(error.PagesLocationIncomplete, parseOptions(std.testing.allocator, &.{
        "boris",
        "--pages-base-url",
        "https://owner.github.io",
        "--pages-origin",
        "https://owner.github.io",
    }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{
        "boris",
        "--no-rag",
        "--pages-base-url",
        "https://owner.github.io",
        "--pages-origin",
        "https://owner.github.io",
        "--pages-base-path",
        "",
    }));
}

test "parse detail: out-of-workspace --theme blames --theme, not --input (#761)" {
    var d = ParseErrorDetail{};
    try expectError(error.InvalidValue, parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "--input", ".", "--html-dir", "dist-test", "--theme", "../themes/lab",
    }, &d));
    try expectEqualStrings("--theme", d.blame_flag.?);
    try expect(d.blame_hint != null);
    try expect(d.conflict_a == null);

    // Absolute theme roots fail the same grammar and keep the attribution.
    var abs = ParseErrorDetail{};
    try expectError(error.InvalidValue, parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "--input", "content", "--theme", "/tmp/lab",
    }, &abs));
    try expectEqualStrings("--theme", abs.blame_flag.?);

    // The same grammar on --html-layout names that flag.
    var layout = ParseErrorDetail{};
    try expectError(error.InvalidValue, parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "--html-layout", "../layouts/main.html",
    }, &layout));
    try expectEqualStrings("--html-layout", layout.blame_flag.?);

    // Unrelated value failures keep the historical findBadArg behavior: no
    // recorded blame, generic rendering.
    var plain = ParseErrorDetail{};
    try expectError(error.InvalidValue, parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "--split-size", "0",
    }, &plain));
    try expect(plain.blame_flag == null);
}

test "parse detail: conflicting pairs name both sides (#764)" {
    // Analyzer × HTML selector (the audited repro).
    var check = ParseErrorDetail{};
    try expectError(error.ConflictingFlags, parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "check", "--input", "content", "--theme", "themes/boris",
    }, &check));
    try expectEqualStrings("check", check.conflict_a.?);
    try expectEqualStrings("--theme", check.conflict_b.?);

    var impact = ParseErrorDetail{};
    try expectError(error.ConflictingFlags, parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "impact", "x", "--html-dir", "dist",
    }, &impact));
    try expectEqualStrings("impact", impact.conflict_a.?);
    try expectEqualStrings("--html-dir", impact.conflict_b.?);

    // Theme × explicit --out (the second audited repro).
    var theme_out = ParseErrorDetail{};
    try expectError(error.ConflictingFlags, parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "--out", "ir", "--theme", "themes/boris",
    }, &theme_out));
    try expectEqualStrings("--theme", theme_out.conflict_a.?);
    try expectEqualStrings("--out", theme_out.conflict_b.?);

    // Unambiguous single pairs elsewhere in the matrix.
    const cases = [_]struct { argv: []const []const u8, a: []const u8, b: []const u8 }{
        .{ .argv = &.{ "boris", "--rag", "--no-rag" }, .a = "--rag", .b = "--no-rag" },
        .{ .argv = &.{ "boris", "--no-rag", "--rag-dir", "r" }, .a = "--no-rag", .b = "--rag-dir" },
        .{ .argv = &.{ "boris", "--out", ".boris", "--rag" }, .a = "--out", .b = "--rag" },
        .{ .argv = &.{ "boris", "--target", "a=da", "--html-dir", "dd" }, .a = "--target", .b = "--html-dir" },
        .{ .argv = &.{ "boris", "--textile", "--cooklang" }, .a = "--textile", .b = "--cooklang" },
        .{ .argv = &.{ "boris", "--theme", "t", "--html-layout", "l.html" }, .a = "--theme", .b = "--html-layout" },
    };
    for (cases) |c| {
        var d = ParseErrorDetail{};
        try expectError(error.ConflictingFlags, parseOptionsWithDetail(std.testing.allocator, c.argv, &d));
        try expectEqualStrings(c.a, d.conflict_a.?);
        try expectEqualStrings(c.b, d.conflict_b.?);
    }

    // Multi-cause conflicts stay unnamed rather than guessing a pair.
    var generic = ParseErrorDetail{};
    try expectError(error.ConflictingFlags, parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "validate", "--format", "json",
    }, &generic));
    try expect(generic.conflict_a == null and generic.conflict_b == null);
}

test "parse detail: channel stays empty on success and parseOptions is unchanged" {
    var d = ParseErrorDetail{};
    var o = try parseOptionsWithDetail(std.testing.allocator, &.{
        "boris", "--input", "content", "--theme", "themes/boris", "--quiet",
    }, &d);
    defer o.deinit(std.testing.allocator);
    try expect(d.blame_flag == null and d.conflict_a == null);

    // The historical entry point keeps its signature and results.
    var plain = try parseOptions(std.testing.allocator, &.{ "boris", "--theme", "themes/boris" });
    defer plain.deinit(std.testing.allocator);
    try expectEqual(Mode.html, plain.mode);
}

test "parse detail: audit batch names flags instead of misattributing (#867, #872, #880, #905)" {
    // #867: duplicate --layout-rule selectors blame --layout-rule, never a
    // flag that occurs once (here --html-layout).
    {
        var d = ParseErrorDetail{};
        try expectError(error.DuplicateFlag, parseOptionsWithDetail(std.testing.allocator, &.{
            "boris", "--quiet", "--html-layout", "layouts/global.html",
            "--layout-rule", "default", "id:reference/config", "layouts/exact.html",
            "--layout-rule", "default", "id:reference/config", "layouts/exact.html",
        }, &d));
        try expectEqualStrings("--layout-rule", d.blame_flag.?);
    }
    // #872: session-family flags are rejected outside standard-site, naming
    // the command and the flag.
    {
        const cases = [_]struct { argv: []const []const u8, a: []const u8, b: []const u8 }{
            .{ .argv = &.{ "boris", "--quiet", "--did", "did:plc:x" }, .a = "build", .b = "--did" },
            .{ .argv = &.{ "boris", "validate", "--dist", "d" }, .a = "validate", .b = "--dist" },
            .{ .argv = &.{ "boris", "check", "--prune" }, .a = "check", .b = "--prune" },
        };
        for (cases) |c| {
            var d = ParseErrorDetail{};
            try expectError(error.ConflictingFlags, parseOptionsWithDetail(std.testing.allocator, c.argv, &d));
            try expectEqualStrings(c.a, d.conflict_a.?);
            try expectEqualStrings(c.b, d.conflict_b.?);
        }
    }
    // #880: bad --site-url values blame --site-url, not --input.
    {
        var d = ParseErrorDetail{};
        try expectError(error.InvalidValue, parseOptionsWithDetail(std.testing.allocator, &.{
            "boris", "--input", "content", "--rss", "--site-url", "ftp://bad.example/",
            "--rss-title", "t", "--rss-description", "d",
        }, &d));
        try expectEqualStrings("--site-url", d.blame_flag.?);
    }
    // #905: --site-url without --rss/--sitemap and --out with nostr plan
    // name their pairs.
    {
        var d = ParseErrorDetail{};
        try expectError(error.ConflictingFlags, parseOptionsWithDetail(std.testing.allocator, &.{
            "boris", "--input", "content", "--html-dir", "out", "--site-url", "https://example.test/",
        }, &d));
        try expectEqualStrings("--site-url", d.conflict_a.?);
        try expectEqualStrings("--rss/--sitemap", d.conflict_b.?);
    }
    {
        var d = ParseErrorDetail{};
        try expectError(error.ConflictingFlags, parseOptionsWithDetail(std.testing.allocator, &.{
            "boris", "nostr", "plan", "--profile", "p.json", "--out", "np.json",
        }, &d));
        try expectEqualStrings("nostr plan", d.conflict_a.?);
        try expectEqualStrings("--out", d.conflict_b.?);
    }
}
