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

pub const ExitCode = diagnostic.ExitCode;
pub const RunResult = diagnostic.RunResult;

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
    init,
    /// `standard-site publish` — the explicit one-shot publish family. The
    /// network operation lives only here; no other command publishes.
    standard_site,
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
    /// Handle for `standard-site login --app-password` (alternative to
    /// `--did`; resolves to the DID via DNS/HTTPS).
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
    /// HTML output directory. Set for HTML mode only (default `dist`).
    html_dir: ?[]const u8 = null,
    /// Global HTML layout template (default managed Boris theme).
    html_layout: []const u8 = "themes/boris/layouts/main.html",
    /// When set, `html_layout` was allocated for `--theme` sugar and must be freed.
    owned_html_layout: bool = false,
    /// Explicit incremental HTML build mode (HTML mode only).
    incremental: bool = false,
    /// Bounded parallel rendering worker count (HTML mode only).
    jobs: usize = 1,
    /// Opt-in local-development watch mode for HTML builds.
    watch: bool = false,
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
pub fn parseOptions(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var quiet = false;
    var input_dir: []const u8 = default_input_dir;
    var out_dir: []const u8 = default_out_dir;
    var rag_dir: []const u8 = default_rag_dir;
    var context_dir: []const u8 = default_context_dir;
    var llms_path: []const u8 = default_llms_path;
    var rss_path: []const u8 = default_rss_path;
    var site_url: ?[]const u8 = null;
    var pages_base_url: ?[]const u8 = null;
    var pages_origin: ?[]const u8 = null;
    var pages_base_path: ?[]const u8 = null;
    var rss_title: ?[]const u8 = null;
    var rss_description: ?[]const u8 = null;
    var rss_limit: usize = 20;
    var sitemap_path: []const u8 = default_sitemap_path;
    var html_dir: []const u8 = default_html_dir;
    var scope: ?[]const u8 = null;
    var split_size: ?usize = null;
    var bundles_only = false;
    var complete = false;

    var saw_quiet = false;
    var saw_timings = false;
    var saw_input = false;
    var saw_out = false;
    var saw_rag = false;
    var saw_no_rag = false;
    var saw_rag_dir = false;
    var saw_context = false;
    var saw_context_dir = false;
    var saw_scope = false;
    var saw_split_size = false;
    var saw_bundles_only = false;
    var saw_complete = false;
    var saw_llms = false;
    var saw_llms_path = false;
    var saw_rss = false;
    var saw_rss_path = false;
    var saw_site_url = false;
    var saw_pages_base_url = false;
    var saw_pages_origin = false;
    var saw_pages_base_path = false;
    var saw_rss_title = false;
    var saw_rss_description = false;
    var saw_rss_limit = false;
    var saw_sitemap = false;
    var saw_sitemap_path = false;
    var saw_html = false;
    var saw_html_dir = false;
    var saw_html_layout = false;
    var saw_theme = false;
    var saw_incremental = false;
    var saw_jobs = false;
    var saw_watch = false;
    var saw_serve = false;
    var serve_port: ?u16 = null;
    var saw_textile = false;
    var saw_cooklang = false;
    var saw_format = false;
    var saw_report = false;
    // `standard-site` family state.
    var standard_site_command: StandardSiteCommand = .publish;
    var standard_site_publish = false;
    var session_did: ?[]const u8 = null;
    var saw_session_did = false;
    var session_handle: ?[]const u8 = null;
    var saw_session_handle = false;
    var app_password = false;
    var saw_app_password = false;
    var session_root: ?[]const u8 = null;
    var saw_session_root = false;
    var plan_path: ?[]const u8 = null;
    var saw_plan_path = false;
    var publish_prune = false;
    var source_commit: ?[]const u8 = null;
    var saw_source_commit = false;
    var smoke_namespace: ?[]const u8 = null;
    var saw_smoke_namespace = false;
    var smoke_surface_url: ?[]const u8 = null;
    var saw_smoke_surface_url = false;
    var smoke_indexer_origin: ?[]const u8 = null;
    var saw_smoke_indexer_origin = false;
    var verify_dist: ?[]const u8 = null;
    var saw_verify_dist = false;
    var saw_fail_on_unreferenced = false;
    var saw_profile = false;
    var jobs: usize = 1;
    var html_layout: []const u8 = default_html_layout;
    var theme_root: ?[]const u8 = null;
    var profile_path: ?[]const u8 = null;

    var targets: std.ArrayListUnmanaged(target_mod.TargetSpec) = .{ .items = &.{}, .capacity = 0 };
    errdefer {
        for (targets.items) |t| {
            if (t.layout_rules.len > 0) gpa.free(t.layout_rules);
        }
        targets.deinit(gpa);
    }
    var publication_location: ?github_pages.Location = null;
    var allow_markdown_links: bool = false;
    errdefer if (publication_location) |*location| location.deinit(gpa);
    // Pending --target-layout NAME=PATH applied after targets are known.
    var target_layouts: std.ArrayListUnmanaged(struct { name: []const u8, path: []const u8 }) = .{ .items = &.{}, .capacity = 0 };
    defer target_layouts.deinit(gpa);
    // Pending --target-profile NAME=PROFILE applied after targets are known.
    var target_profiles: std.ArrayListUnmanaged(struct { name: []const u8, profile: render.OutputProfile }) = .{ .items = &.{}, .capacity = 0 };
    defer target_profiles.deinit(gpa);
    // Pending --layout-rule TARGET SELECTOR LAYOUT_PATH (three following args).
    var pending_rules: std.ArrayListUnmanaged(struct {
        target: []const u8,
        selector: []const u8,
        path: []const u8,
    }) = .{ .items = &.{}, .capacity = 0 };
    defer pending_rules.deinit(gpa);

    var command: Command = .build;
    var impact_id: ?[]const u8 = null;
    var init_dir: ?[]const u8 = null;
    var analysis_format: AnalysisFormat = .human;
    var analysis_report: ?[]const u8 = null;
    var fail_on_unreferenced = false;

    var i: usize = if (args.len > 0) 1 else 0;
    if (i < args.len and std.mem.eql(u8, args[i], "build")) {
        command = .build;
        i += 1;
    } else if (i < args.len and std.mem.eql(u8, args[i], "validate")) {
        command = .validate;
        i += 1;
    } else if (i < args.len and std.mem.eql(u8, args[i], "watch")) {
        command = .watch;
        saw_watch = true;
        i += 1;
    } else if (i < args.len and std.mem.eql(u8, args[i], "check")) {
        command = .check;
        i += 1;
    } else if (i < args.len and std.mem.eql(u8, args[i], "impact")) {
        command = .impact;
        i += 1;
        // The target id is captured in the loop so flags may precede it
        // (`boris impact --quiet ID`); a missing target is checked after
        // the loop so `boris impact` stays a usage error.
    } else if (i < args.len and std.mem.eql(u8, args[i], "plan")) {
        command = .plan;
        i += 1;
    } else if (i < args.len and std.mem.eql(u8, args[i], "nostr")) {
        i += 1;
        // Exactly one subcommand today. An unknown one is a usage error rather
        // than a stub, so nothing can look like signing or publishing exists.
        if (i >= args.len or !std.mem.eql(u8, args[i], "plan")) return error.UnknownNostrSubcommand;
        command = .nostr_plan;
        i += 1;
    } else if (i < args.len and std.mem.eql(u8, args[i], "init")) {
        command = .init;
        i += 1;
        // `boris init [DIR]` — exactly one optional positional target
        // directory. A second positional is a usage error.
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            init_dir = args[i];
            i += 1;
        }
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) return error.UnexpectedPositional;
    } else if (i < args.len and std.mem.eql(u8, args[i], "standard-site")) {
        command = .standard_site;
        i += 1;
        // The network family has four explicit subcommands. A missing or
        // unknown subcommand is a usage error, never a silent fallback.
        if (i >= args.len) return error.UnexpectedPositional;
        if (std.mem.eql(u8, args[i], "publish")) {
            standard_site_command = .publish;
            standard_site_publish = true;
        } else if (std.mem.eql(u8, args[i], "plan")) {
            standard_site_command = .plan;
        } else if (std.mem.eql(u8, args[i], "records")) {
            standard_site_command = .records;
        } else if (std.mem.eql(u8, args[i], "verify")) {
            standard_site_command = .verify;
        } else if (std.mem.eql(u8, args[i], "login")) {
            standard_site_command = .login;
        } else if (std.mem.eql(u8, args[i], "sessions")) {
            standard_site_command = .sessions;
        } else if (std.mem.eql(u8, args[i], "logout")) {
            standard_site_command = .logout;
        } else if (std.mem.eql(u8, args[i], "smoke")) {
            standard_site_command = .smoke;
        } else {
            return error.UnexpectedPositional;
        }
        i += 1;
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) return error.UnexpectedPositional;
    }
    while (i < args.len) : (i += 1) {
        const a = args[i];

        // `init [DIR]` and `impact <ID>` — the single positional may also
        // follow flags (`boris init --quiet DIR`, `boris impact --quiet ID`);
        // the pre-loop capture handles the immediate-after-command form, this
        // handles flags in between. A second positional still falls through
        // to UnexpectedPositional.
        if (command == .init and init_dir == null and !std.mem.startsWith(u8, a, "-")) {
            init_dir = a;
            continue;
        }
        if (command == .impact and impact_id == null and !std.mem.startsWith(u8, a, "-")) {
            impact_id = a;
            continue;
        }

        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h") or
            std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V"))
        {
            // Help/version short-circuits: do not validate remaining args.
            // The first of the two flags wins (they share one exit path).
            // Release any targets accumulated before the flag: the returned
            // Options carries an empty list (no allocation), and the caller's
            // deinit would never see the accumulated one (errdefer only fires
            // on error), so `--target X --help`/`--version` must not leak it.
            for (targets.items) |t| {
                if (t.layout_rules.len > 0) gpa.free(t.layout_rules);
            }
            targets.deinit(gpa);
            const wants_help = std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
            return .{
                .help = wants_help,
                .version = !wants_help,
                .quiet = quiet,
                .timings = saw_timings,
                .mode = .ir,
                .input_dir = input_dir,
                .out_dir = out_dir,
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

        if (std.mem.eql(u8, a, "--quiet")) {
            if (saw_quiet) return error.DuplicateFlag;
            saw_quiet = true;
            quiet = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--timings")) {
            if (saw_timings) return error.DuplicateFlag;
            saw_timings = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--profile") or std.mem.startsWith(u8, a, "--profile=")) {
            if (saw_profile) return error.DuplicateFlag;
            saw_profile = true;
            profile_path = try takeValue(args, &i, a, "--profile");
            continue;
        }

        if (std.mem.eql(u8, a, "--textile")) {
            if (saw_textile) return error.DuplicateFlag;
            saw_textile = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--cooklang")) {
            if (saw_cooklang) return error.DuplicateFlag;
            saw_cooklang = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--rag")) {
            if (saw_rag) return error.DuplicateFlag;
            saw_rag = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--context")) {
            if (saw_context) return error.DuplicateFlag;
            saw_context = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--bundles-only")) {
            if (saw_bundles_only) return error.DuplicateFlag;
            saw_bundles_only = true;
            bundles_only = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--complete")) {
            if (saw_complete) return error.DuplicateFlag;
            saw_complete = true;
            complete = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--llms")) {
            if (saw_llms) return error.DuplicateFlag;
            saw_llms = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--rss")) {
            if (saw_rss) return error.DuplicateFlag;
            saw_rss = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--sitemap")) {
            if (saw_sitemap) return error.DuplicateFlag;
            saw_sitemap = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--allow-markdown-links")) {
            allow_markdown_links = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-rag")) {
            if (saw_no_rag) return error.DuplicateFlag;
            saw_no_rag = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--html")) {
            if (saw_html) return error.DuplicateFlag;
            saw_html = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--incremental")) {
            if (saw_incremental) return error.DuplicateFlag;
            saw_incremental = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--watch")) {
            if (saw_watch) return error.DuplicateFlag;
            saw_watch = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--serve")) {
            if (saw_serve) return error.DuplicateFlag;
            saw_serve = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--port") or std.mem.startsWith(u8, a, "--port=")) {
            if (serve_port != null) return error.DuplicateFlag;
            const value = try takeValue(args, &i, a, "--port");
            serve_port = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidValue;
            continue;
        }

        if (std.mem.eql(u8, a, "--format") or std.mem.startsWith(u8, a, "--format=")) {
            if (saw_format) return error.DuplicateFlag;
            saw_format = true;
            const value = try takeValue(args, &i, a, "--format");
            analysis_format = if (std.mem.eql(u8, value, "human")) .human else if (std.mem.eql(u8, value, "json")) .json else return error.InvalidValue;
            continue;
        }

        if (std.mem.eql(u8, a, "--report") or std.mem.startsWith(u8, a, "--report=")) {
            if (saw_report) return error.DuplicateFlag;
            saw_report = true;
            analysis_report = try takeValue(args, &i, a, "--report");
            continue;
        }

        if (std.mem.eql(u8, a, "--fail-on-unreferenced")) {
            if (saw_fail_on_unreferenced) return error.DuplicateFlag;
            saw_fail_on_unreferenced = true;
            fail_on_unreferenced = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--target") or std.mem.startsWith(u8, a, "--target=")) {
            const val = try takeValue(args, &i, a, "--target");
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
            for (targets.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return error.DuplicateFlag;
                }
            }
            try targets.append(gpa, .{
                .name = name,
                .output_dir = output_dir,
                .layout_path = null,
            });
            continue;
        }

        if (std.mem.eql(u8, a, "--target-layout") or std.mem.startsWith(u8, a, "--target-layout=")) {
            const val = try takeValue(args, &i, a, "--target-layout");
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
            for (target_layouts.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return error.DuplicateFlag;
                }
            }
            try target_layouts.append(gpa, .{ .name = name, .path = path });
            continue;
        }

        // --target-profile NAME=PROFILE (html|xhtml), applied after targets are
        // known. Mirrors --target-layout; the profile is a serialization switch
        // (#448) and composes with layout/rule selection.
        if (std.mem.eql(u8, a, "--target-profile") or std.mem.startsWith(u8, a, "--target-profile=")) {
            const val = try takeValue(args, &i, a, "--target-profile");
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
            for (target_profiles.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return error.DuplicateFlag;
                }
            }
            try target_profiles.append(gpa, .{ .name = name, .profile = profile });
            continue;
        }

        // --layout-rule TARGET SELECTOR LAYOUT_PATH (exactly three following args).
        if (std.mem.eql(u8, a, "--layout-rule") or std.mem.startsWith(u8, a, "--layout-rule=")) {
            if (std.mem.startsWith(u8, a, "--layout-rule=")) return error.InvalidValue;
            if (i + 3 >= args.len) return error.MissingValue;
            const tname = args[i + 1];
            const selector = args[i + 2];
            const path = args[i + 3];
            if (tname.len == 0 or selector.len == 0 or path.len == 0) return error.EmptyValue;
            if (!target_mod.isValidTargetName(tname)) return error.InvalidValue;
            // Reject values that look like flags (prevent silent arg shift).
            if (tname[0] == '-' or selector[0] == '-' or path[0] == '-') return error.InvalidValue;
            // Validate selector grammar early (fail before discovery).
            _ = layout_select.parseSelector(selector) catch return error.InvalidValue;
            layout_select.validateLayoutPath(path) catch return error.InvalidValue;
            try pending_rules.append(gpa, .{ .target = tname, .selector = selector, .path = path });
            i += 3;
            continue;
        }

        if (std.mem.eql(u8, a, "--jobs") or std.mem.startsWith(u8, a, "--jobs=") or
            std.mem.eql(u8, a, "-j") or std.mem.startsWith(u8, a, "-j="))
        {
            if (saw_jobs) return error.DuplicateFlag;
            saw_jobs = true;
            const val_str = if (std.mem.startsWith(u8, a, "-j"))
                try takeValue(args, &i, a, "-j")
            else
                try takeValue(args, &i, a, "--jobs");
            const parsed_val = std.fmt.parseInt(usize, val_str, 10) catch {
                return error.InvalidValue;
            };
            if (parsed_val < 1 or parsed_val > 64) {
                return error.InvalidValue;
            }
            jobs = parsed_val;
            continue;
        }

        if (std.mem.eql(u8, a, "--plan") or std.mem.startsWith(u8, a, "--plan=")) {
            if (saw_plan_path) return error.DuplicateFlag;
            saw_plan_path = true;
            plan_path = try takeValue(args, &i, a, "--plan");
            continue;
        }

        if (std.mem.eql(u8, a, "--prune")) {
            if (publish_prune) return error.DuplicateFlag;
            publish_prune = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--source-commit") or std.mem.startsWith(u8, a, "--source-commit=")) {
            if (saw_source_commit) return error.DuplicateFlag;
            saw_source_commit = true;
            source_commit = try takeValue(args, &i, a, "--source-commit");
            continue;
        }

        if (std.mem.eql(u8, a, "--did") or std.mem.startsWith(u8, a, "--did=")) {
            if (saw_session_did) return error.DuplicateFlag;
            saw_session_did = true;
            session_did = try takeValue(args, &i, a, "--did");
            continue;
        }

        if (std.mem.eql(u8, a, "--handle") or std.mem.startsWith(u8, a, "--handle=")) {
            if (saw_session_handle) return error.DuplicateFlag;
            saw_session_handle = true;
            session_handle = try takeValue(args, &i, a, "--handle");
            continue;
        }

        if (std.mem.eql(u8, a, "--app-password")) {
            if (saw_app_password) return error.DuplicateFlag;
            saw_app_password = true;
            app_password = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--session-root") or std.mem.startsWith(u8, a, "--session-root=")) {
            if (saw_session_root) return error.DuplicateFlag;
            saw_session_root = true;
            session_root = try takeValue(args, &i, a, "--session-root");
            continue;
        }

        if (std.mem.eql(u8, a, "--dist") or std.mem.startsWith(u8, a, "--dist=")) {
            if (saw_verify_dist) return error.DuplicateFlag;
            saw_verify_dist = true;
            verify_dist = try takeValue(args, &i, a, "--dist");
            continue;
        }

        if (std.mem.eql(u8, a, "--namespace") or std.mem.startsWith(u8, a, "--namespace=")) {
            if (saw_smoke_namespace) return error.DuplicateFlag;
            saw_smoke_namespace = true;
            smoke_namespace = try takeValue(args, &i, a, "--namespace");
            continue;
        }

        if (std.mem.eql(u8, a, "--surface-url") or std.mem.startsWith(u8, a, "--surface-url=")) {
            if (saw_smoke_surface_url) return error.DuplicateFlag;
            saw_smoke_surface_url = true;
            smoke_surface_url = try takeValue(args, &i, a, "--surface-url");
            continue;
        }

        if (std.mem.eql(u8, a, "--indexer") or std.mem.startsWith(u8, a, "--indexer=")) {
            if (saw_smoke_indexer_origin) return error.DuplicateFlag;
            saw_smoke_indexer_origin = true;
            smoke_indexer_origin = try takeValue(args, &i, a, "--indexer");
            continue;
        }

        if (std.mem.eql(u8, a, "--input") or std.mem.startsWith(u8, a, "--input=")) {
            if (saw_input) return error.DuplicateFlag;
            saw_input = true;
            input_dir = try takeValue(args, &i, a, "--input");
            continue;
        }

        if (std.mem.eql(u8, a, "--out") or std.mem.startsWith(u8, a, "--out=")) {
            if (saw_out) return error.DuplicateFlag;
            saw_out = true;
            out_dir = try takeValue(args, &i, a, "--out");
            continue;
        }

        if (std.mem.eql(u8, a, "--rag-dir") or std.mem.startsWith(u8, a, "--rag-dir=")) {
            if (saw_rag_dir) return error.DuplicateFlag;
            saw_rag_dir = true;
            rag_dir = try takeValue(args, &i, a, "--rag-dir");
            continue;
        }

        if (std.mem.eql(u8, a, "--context-dir") or std.mem.startsWith(u8, a, "--context-dir=")) {
            if (saw_context_dir) return error.DuplicateFlag;
            saw_context_dir = true;
            context_dir = try takeValue(args, &i, a, "--context-dir");
            continue;
        }

        if (std.mem.eql(u8, a, "--scope") or std.mem.startsWith(u8, a, "--scope=")) {
            if (saw_scope) return error.DuplicateFlag;
            saw_scope = true;
            scope = try takeValue(args, &i, a, "--scope");
            continue;
        }

        if (std.mem.eql(u8, a, "--split-size") or std.mem.startsWith(u8, a, "--split-size=")) {
            if (saw_split_size) return error.DuplicateFlag;
            saw_split_size = true;
            const raw = try takeValue(args, &i, a, "--split-size");
            const parsed = std.fmt.parseInt(usize, raw, 10) catch return error.InvalidValue;
            if (parsed == 0) return error.InvalidValue;
            split_size = parsed;
            continue;
        }

        if (std.mem.eql(u8, a, "--llms-path") or std.mem.startsWith(u8, a, "--llms-path=")) {
            if (saw_llms_path) return error.DuplicateFlag;
            saw_llms_path = true;
            llms_path = try takeValue(args, &i, a, "--llms-path");
            if (std.fs.path.isAbsolute(llms_path)) return error.InvalidValue;
            continue;
        }

        if (std.mem.eql(u8, a, "--rss-path") or std.mem.startsWith(u8, a, "--rss-path=")) {
            if (saw_rss_path) return error.DuplicateFlag;
            saw_rss_path = true;
            rss_path = try takeValue(args, &i, a, "--rss-path");
            if (std.fs.path.isAbsolute(rss_path)) return error.InvalidValue;
            continue;
        }

        if (std.mem.eql(u8, a, "--sitemap-path") or std.mem.startsWith(u8, a, "--sitemap-path=")) {
            if (saw_sitemap_path) return error.DuplicateFlag;
            saw_sitemap_path = true;
            sitemap_path = try takeValue(args, &i, a, "--sitemap-path");
            sitemap.validateOutputPath(sitemap_path) catch return error.InvalidValue;
            continue;
        }

        if (std.mem.eql(u8, a, "--site-url") or std.mem.startsWith(u8, a, "--site-url=")) {
            if (saw_site_url) return error.DuplicateFlag;
            saw_site_url = true;
            site_url = try takeValue(args, &i, a, "--site-url");
            continue;
        }

        if (std.mem.eql(u8, a, "--pages-base-url") or std.mem.startsWith(u8, a, "--pages-base-url=")) {
            if (saw_pages_base_url) return error.DuplicateFlag;
            saw_pages_base_url = true;
            pages_base_url = try takeValue(args, &i, a, "--pages-base-url");
            continue;
        }

        if (std.mem.eql(u8, a, "--pages-origin") or std.mem.startsWith(u8, a, "--pages-origin=")) {
            if (saw_pages_origin) return error.DuplicateFlag;
            saw_pages_origin = true;
            pages_origin = try takeValue(args, &i, a, "--pages-origin");
            continue;
        }

        if (std.mem.eql(u8, a, "--pages-base-path") or std.mem.startsWith(u8, a, "--pages-base-path=")) {
            if (saw_pages_base_path) return error.DuplicateFlag;
            saw_pages_base_path = true;
            pages_base_path = try takeValueAllowEmpty(args, &i, a, "--pages-base-path");
            continue;
        }

        if (std.mem.eql(u8, a, "--rss-title") or std.mem.startsWith(u8, a, "--rss-title=")) {
            if (saw_rss_title) return error.DuplicateFlag;
            saw_rss_title = true;
            rss_title = try takeValue(args, &i, a, "--rss-title");
            continue;
        }

        if (std.mem.eql(u8, a, "--rss-description") or std.mem.startsWith(u8, a, "--rss-description=")) {
            if (saw_rss_description) return error.DuplicateFlag;
            saw_rss_description = true;
            rss_description = try takeValue(args, &i, a, "--rss-description");
            continue;
        }

        if (std.mem.eql(u8, a, "--rss-limit") or std.mem.startsWith(u8, a, "--rss-limit=")) {
            if (saw_rss_limit) return error.DuplicateFlag;
            saw_rss_limit = true;
            rss_limit = std.fmt.parseInt(usize, try takeValue(args, &i, a, "--rss-limit"), 10) catch return error.InvalidRssLimit;
            if (rss_limit < 1 or rss_limit > 500) return error.InvalidRssLimit;
            continue;
        }

        if (std.mem.eql(u8, a, "--html-dir") or std.mem.startsWith(u8, a, "--html-dir=")) {
            if (saw_html_dir) return error.DuplicateFlag;
            saw_html_dir = true;
            html_dir = try takeValue(args, &i, a, "--html-dir");
            continue;
        }

        if (std.mem.eql(u8, a, "--html-layout") or std.mem.startsWith(u8, a, "--html-layout=")) {
            if (saw_html_layout) return error.DuplicateFlag;
            saw_html_layout = true;
            html_layout = try takeValue(args, &i, a, "--html-layout");
            layout_select.validateLayoutPath(html_layout) catch return error.InvalidValue;
            continue;
        }

        // F9.1: --theme ROOT is sugar for --html-layout ROOT/layouts/main.html
        // (theme asset root is derived from the layout path at compile time).
        if (std.mem.eql(u8, a, "--theme") or std.mem.startsWith(u8, a, "--theme=")) {
            if (saw_theme) return error.DuplicateFlag;
            saw_theme = true;
            theme_root = try takeValue(args, &i, a, "--theme");
            // Theme root uses the same no-escape relative path grammar; the
            // synthesized layout path is validated after composition below.
            layout_select.validateLayoutPath(theme_root.?) catch return error.InvalidValue;
            continue;
        }

        if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        }
        return error.UnexpectedPositional;
    }

    // Resolve --theme sugar before mode selection (implies HTML layout path).
    var owned_html_layout = false;
    if (theme_root) |tr| {
        if (tr.len == 0) return error.EmptyValue;
        if (saw_html_layout) return error.ConflictingFlags;
        // Joined path is owned by Options (freed in deinit).
        html_layout = try std.fmt.allocPrint(gpa, "{s}/layouts/main.html", .{tr});
        owned_html_layout = true;
        saw_html_layout = true;
        layout_select.validateLayoutPath(html_layout) catch {
            gpa.free(html_layout);
            owned_html_layout = false;
            return error.InvalidValue;
        };
    }

    // `impact` requires its target; the loop capture defers the immediate-
    // after-command check so flags may precede the positional.
    if (command == .impact and impact_id == null) return error.MissingValue;
    errdefer if (owned_html_layout) gpa.free(html_layout);

    const has_explicit_targets = targets.items.len > 0;
    const has_target_layouts = target_layouts.items.len > 0;
    const has_target_profiles = target_profiles.items.len > 0;
    const has_layout_rules = pending_rules.items.len > 0;
    const wants_sitemap = saw_sitemap or saw_sitemap_path;
    // Explicit HTML selectors (not the bare default).
    const explicit_html = saw_html or saw_html_dir or has_explicit_targets or saw_html_layout or has_target_layouts or has_target_profiles or saw_theme or has_layout_rules or wants_sitemap;
    const wants_rag = saw_rag or saw_rag_dir;
    const wants_context = saw_context or saw_context_dir;
    const wants_llms = saw_llms or saw_llms_path;
    const wants_rss = saw_rss or saw_rss_path;
    const saw_pages_location = saw_pages_base_url or saw_pages_origin or saw_pages_base_path;
    // Explicit IR: --out and/or --no-rag (bare CLI is HTML, not IR).
    const wants_ir = saw_out or saw_no_rag;

    // One explicit source family per build. Two adapters at once has no
    // meaning: each is a whole-tree mode that refuses the other's extension.
    if (saw_textile and saw_cooklang) return error.ConflictingFlags;
    const input_format: identity.InputFormat = if (saw_textile)
        .textile
    else if (saw_cooklang)
        .cook
    else
        .markdown;
    const saw_input_format = saw_textile or saw_cooklang;

    if (command == .plan) {
        if (profile_path == null) return error.MissingValue;
        // The plan command has one publication identity boundary: profile
        // input, input format, and the single-target HTML output override.
        // Other projection selectors would either execute or invent a second
        // configuration source, so keep them as usage errors.
        // `--timings` is rejected here too: `plan` owns stdout for its single
        // declaration JSON document, and it runs no compiler phase, so the
        // machine-readable timing report has nowhere to go without corrupting
        // the plan stream.
        if (saw_html or has_explicit_targets or saw_html_layout or saw_theme or has_target_layouts or has_target_profiles or has_layout_rules or wants_sitemap or
            wants_rag or wants_ir or wants_context or wants_llms or wants_rss or saw_site_url or saw_pages_location or saw_rss_title or saw_rss_description or saw_rss_limit or
            saw_format or saw_report or saw_watch or saw_timings)
        {
            return error.ConflictingFlags;
        }
        return .{
            .help = false,
            .quiet = quiet,
            .timings = saw_timings,
            .command = .plan,
            .profile_path = profile_path,
            .profile_input_override = if (saw_input) input_dir else null,
            .profile_input_format_override = if (saw_input_format) input_format else null,
            .profile_html_output_override = if (saw_html_dir) html_dir else null,
            .mode = .html,
            .input_format = input_format,
            .input_dir = input_dir,
            .html_dir = if (saw_html_dir) html_dir else null,
            .incremental = saw_incremental,
            .jobs = jobs,
            .targets = targets,
        };
    }

    if (command == .nostr_plan) {
        if (profile_path == null) return error.MissingValue;
        // Same boundary as `plan`, and for the same reason: the profile is the
        // only configuration source. This command does scan content, so
        // `--input`/`--cooklang`/`--textile` overrides stay meaningful, but
        // stdout belongs to the single plan document — hence no `--timings`.
        if (saw_html or has_explicit_targets or saw_html_layout or saw_theme or has_target_layouts or has_layout_rules or wants_sitemap or
            wants_rag or wants_ir or wants_context or wants_llms or wants_rss or saw_site_url or saw_pages_location or saw_rss_title or saw_rss_description or saw_rss_limit or
            saw_format or saw_report or saw_watch or saw_timings or saw_html_dir or saw_incremental)
        {
            return error.ConflictingFlags;
        }
        return .{
            .help = false,
            .quiet = quiet,
            .timings = false,
            .command = .nostr_plan,
            .profile_path = profile_path,
            .profile_input_override = if (saw_input) input_dir else null,
            .profile_input_format_override = if (saw_input_format) input_format else null,
            .mode = .html,
            .input_format = input_format,
            .input_dir = input_dir,
            .jobs = jobs,
            .targets = targets,
        };
    }

    if (command == .init) {
        // `init` writes a deterministic starter tree into one positional
        // target directory. Compiler modes, output selectors, publication
        // inputs, analysis flags, and watch/incremental controls select work
        // init does not perform; the target directory is positional, so
        // `--input` is rejected rather than silently misread.
        if (saw_html or saw_html_dir or has_explicit_targets or saw_html_layout or saw_theme or has_target_layouts or has_target_profiles or has_layout_rules or
            wants_rag or wants_ir or wants_context or wants_llms or wants_rss or saw_site_url or saw_pages_location or
            saw_rss_title or saw_rss_description or saw_rss_limit or saw_format or saw_report or saw_watch or saw_timings or
            saw_profile or saw_input or saw_textile or saw_cooklang or saw_out or saw_rag_dir or saw_incremental or saw_jobs)
        {
            return error.ConflictingFlags;
        }
        return .{
            .help = false,
            .quiet = quiet,
            .timings = false,
            .command = .init,
            .init_dir = init_dir,
            .mode = .html,
            .input_format = identity.InputFormat.markdown,
            .input_dir = "content",
            .out_dir = null,
            .html_dir = null,
            .targets = targets,
        };
    }

    if (command == .standard_site) {
        // The `standard-site` family is the one-shot network family: publish,
        // login, sessions, and logout. Compiler modes, targets, and projection
        // selectors have no meaning here, and `--timings` must not corrupt the
        // evidence stream on stdout. `publish` requires a profile and forbids
        // `--did`; `login`/`logout` require `--did`; `sessions` forbids it.
        if (saw_html or saw_html_dir or has_explicit_targets or saw_html_layout or saw_theme or has_target_layouts or has_layout_rules or
            wants_sitemap or wants_rag or saw_no_rag or wants_context or wants_llms or wants_rss or saw_site_url or saw_pages_location or
            saw_rss_title or saw_rss_description or saw_rss_limit or saw_format or saw_report or saw_watch or saw_timings or
            saw_input or saw_textile or saw_cooklang or saw_rag_dir or saw_scope or saw_split_size or saw_bundles_only or saw_complete or
            saw_incremental or saw_jobs or saw_llms_path or saw_rss_path or saw_sitemap_path or saw_context_dir)
        {
            return error.ConflictingFlags;
        }
        // Smoke-only and verify-only flags have no meaning on the other
        // subcommands; reject them rather than silently ignoring them.
        const saw_smoke_only = saw_smoke_namespace or saw_smoke_surface_url or saw_smoke_indexer_origin;
        switch (standard_site_command) {
            .publish => {
                if (profile_path == null) return error.MissingValue;
                if (saw_session_did or saw_session_handle or saw_app_password or saw_smoke_only or saw_verify_dist) return error.ConflictingFlags;
            },
            .plan => {
                if (profile_path == null) return error.MissingValue;
                if (saw_session_did or saw_session_handle or saw_app_password or saw_smoke_only or saw_verify_dist or saw_plan_path or publish_prune or saw_source_commit) return error.ConflictingFlags;
            },
            .records => {
                if (profile_path == null) return error.MissingValue;
                if (saw_session_did or saw_session_handle or saw_app_password or saw_smoke_only or saw_verify_dist or saw_plan_path or publish_prune or saw_source_commit) return error.ConflictingFlags;
            },
            .verify => {
                if (profile_path == null) return error.MissingValue;
                if (saw_session_did or saw_session_handle or saw_app_password or saw_smoke_only or saw_plan_path or publish_prune or saw_source_commit) return error.ConflictingFlags;
            },
            .login => {
                if (profile_path != null or saw_plan_path or publish_prune or saw_source_commit or saw_out or saw_smoke_only or saw_verify_dist) return error.ConflictingFlags;
                if (app_password) {
                    // App-password login takes exactly one identity: a DID or
                    // a handle (resolved to a DID).
                    if (session_did == null and session_handle == null) return error.MissingValue;
                    if (session_did != null and session_handle != null) return error.ConflictingFlags;
                } else {
                    if (session_did == null) return error.MissingValue;
                    if (session_handle != null) return error.ConflictingFlags;
                }
            },
            .logout => {
                if (session_did == null) return error.MissingValue;
                if (session_handle != null or app_password or profile_path != null or saw_plan_path or publish_prune or saw_source_commit or saw_out or saw_smoke_only or saw_verify_dist) return error.ConflictingFlags;
            },
            .sessions => {
                if (saw_session_did or saw_session_handle or saw_app_password or profile_path != null or saw_plan_path or publish_prune or saw_source_commit or saw_out or saw_smoke_only or saw_verify_dist) return error.ConflictingFlags;
            },
            .smoke => {
                if (session_did == null) return error.MissingValue;
                if (session_handle != null or saw_app_password or profile_path != null or saw_plan_path or publish_prune or saw_source_commit or saw_verify_dist) return error.ConflictingFlags;
            },
        }
        return .{
            .help = false,
            .quiet = quiet,
            .timings = false,
            .command = .standard_site,
            .standard_site_command = standard_site_command,
            .standard_site_publish = standard_site_command == .publish,
            .plan_path = plan_path,
            .publish_out = if (saw_out) out_dir else null,
            .plan_out = if (saw_out) out_dir else null,
            .records_out = if (saw_out) out_dir else null,
            .verify_out = if (saw_out) out_dir else null,
            .verify_dist = verify_dist orelse "dist",
            .publish_prune = publish_prune,
            .source_commit = source_commit,
            .session_did = session_did,
            .session_handle = session_handle,
            .app_password = app_password,
            .session_root = session_root,
            .smoke_namespace = smoke_namespace,
            .smoke_surface_url = smoke_surface_url,
            .smoke_indexer_origin = smoke_indexer_origin,
            .smoke_out = if (saw_out) out_dir else null,
            .profile_path = profile_path,
            .mode = .html,
            .input_format = identity.InputFormat.markdown,
            .input_dir = input_dir,
            .out_dir = null,
            .html_dir = null,
            .targets = targets,
        };
    }

    if (saw_profile) return error.ConflictingFlags;
    if (saw_fail_on_unreferenced and command != .check) return error.ConflictingFlags;

    if (command == .validate) {
        // Validation is the no-publication form of the selected HTML source /
        // target compiler path. Export selectors, output-bearing analysis,
        // watch/cache behavior, and rendering worker controls would either
        // select another projection or imply filesystem state.
        if (wants_rag or wants_ir or wants_context or wants_llms or wants_rss or
            saw_rss_title or saw_rss_description or saw_rss_limit or saw_scope or
            saw_split_size or saw_bundles_only or saw_incremental or saw_watch or
            saw_jobs or saw_format)
        {
            return error.ConflictingFlags;
        }
    } else if (command == .check or command == .impact) {
        if (wants_rag or wants_ir or wants_context or wants_llms or wants_rss or wants_sitemap or saw_site_url or saw_pages_location or saw_rss_title or saw_rss_description or saw_rss_limit or explicit_html or saw_jobs or saw_watch or saw_incremental or saw_theme or saw_html_layout or has_target_layouts or has_target_profiles or has_layout_rules) {
            return error.ConflictingFlags;
        }
    } else if (command == .build and saw_format) {
        return error.ConflictingFlags;
    } else if (command == .watch and (saw_format or saw_report)) {
        return error.ConflictingFlags;
    }

    // The preview server is a watch-mode surface (`boris watch --serve`).
    if ((saw_serve or serve_port != null) and !saw_watch) return error.ConflictingFlags;

    // --- conflict matrix ---------------------------------------------------
    if (saw_rag and saw_no_rag) return error.ConflictingFlags;
    if (saw_no_rag and saw_rag_dir) return error.ConflictingFlags;
    // Explicit --out must never be combined with RAG-only selection.
    if (saw_out and wants_rag) return error.ConflictingFlags;
    if (wants_context and (wants_rag or wants_ir)) return error.ConflictingFlags;
    if ((saw_scope or saw_split_size) and !(wants_rag or wants_context)) return error.ConflictingFlags;
    if (bundles_only and !wants_rag) return error.ConflictingFlags;
    // Complete-corpus RAG is RAG-only and owns the tree shape; the working
    // pack target and bundle-style flags belong to the default working mode.
    // A complete export is the entire validated corpus, so a scope projection
    // is a usage error rather than a silent partial export.
    if (saw_complete and !wants_rag) return error.ConflictingFlags;
    if (saw_complete and saw_scope) return error.ConflictingFlags;
    if (saw_complete and (saw_split_size or saw_bundles_only)) return error.ConflictingFlags;
    if (wants_llms and (wants_rag or wants_ir or wants_context or wants_rss or explicit_html)) return error.ConflictingFlags;
    if (wants_rss and (wants_rag or wants_ir or wants_context or explicit_html)) return error.ConflictingFlags;
    if (saw_pages_location and (wants_rag or wants_ir or wants_context)) return error.ConflictingFlags;
    if ((saw_rss_title or saw_rss_description or saw_rss_limit) and !wants_rss) return error.ConflictingFlags;
    if (saw_site_url and !(wants_rss or wants_sitemap)) return error.ConflictingFlags;
    if (wants_rss and (site_url == null or rss_title == null or rss_description == null)) return error.RSSMetadataRequired;
    if (wants_sitemap and site_url == null) return error.SitemapSiteUrlRequired;
    if (wants_sitemap and (wants_rag or wants_ir or wants_context or wants_llms or wants_rss)) return error.ConflictingFlags;
    // Explicit HTML selectors own the output destination; refuse IR/RAG flags.
    if (explicit_html and (wants_rag or wants_context or saw_out)) {
        return error.ConflictingFlags;
    }
    // HTML-only options conflict with IR or RAG selection (default HTML is fine).
    if ((saw_jobs or saw_watch or saw_incremental) and (wants_ir or wants_rag or wants_context or wants_rss)) {
        return error.ConflictingFlags;
    }
    // Target conflict rules
    if (has_explicit_targets and saw_html_dir) return error.ConflictingFlags;
    if (wants_sitemap and targets.items.len > 1) return error.ConflictingFlags;
    // --target-layout / --layout-rule attach to a named --target, or to the
    // synthetic "default" target on bare HTML / --html / --html-dir. Unknown
    // target names are rejected after default synthesis (InvalidValue).

    // Mode selection:
    // 1. Explicit HTML flags / --target / --target-layout / --layout-rule → HTML
    // 2. --rag / --rag-dir → RAG-only
    // 3. --out / --no-rag → IR
    // 4. Default (no mode flags) → HTML site under dist/
    const mode: Mode = if (explicit_html)
        .html
    else if (wants_rag)
        .rag
    else if (wants_context)
        .context
    else if (wants_llms)
        .llms
    else if (wants_rss)
        .rss
    else if (wants_ir)
        .ir
    else
        .html;

    // The HTML-path diagnostics report (`--report`) belongs to the HTML mode.
    // `check`/`impact` reuse the same flag name for their analysis report (see
    // `analysis_report`), so only non-HTML build/watch runs must refuse it.
    if (mode != .html and (command == .build or command == .watch) and saw_report) {
        return error.ConflictingFlags;
    }

    if (saw_pages_location and !(saw_pages_base_url and saw_pages_origin and saw_pages_base_path)) {
        return error.PagesLocationIncomplete;
    }
    if (saw_pages_location) {
        publication_location = github_pages.parse(
            gpa,
            pages_base_url.?,
            pages_origin.?,
            pages_base_path.?,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidValue,
        };
    }

    if (site_url) |raw_url| {
        const normalized = site_url_mod.normalized(gpa, raw_url) catch |err| switch (err) {
            error.InvalidSiteUrl => return error.InvalidValue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        gpa.free(normalized);
    }

    // Single-target HTML (bare CLI, --html, or --html-dir) maps to target "default".
    // --target-layout / --layout-rule may attach to this synthetic target.
    if (mode == .html and !has_explicit_targets) {
        try targets.append(gpa, .{
            .name = "default",
            .output_dir = if (saw_html_dir) html_dir else default_html_dir,
            .layout_path = null,
        });
    }

    // Apply --target-layout NAME=PATH onto matching targets. Flag order relative
    // to --target does not matter (layouts are collected first, applied here).
    for (target_layouts.items) |tl| {
        var found = false;
        for (targets.items) |*t| {
            if (std.mem.eql(u8, t.name, tl.name)) {
                if (t.layout_path != null) return error.DuplicateFlag;
                t.layout_path = tl.path;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidValue;
    }

    // Apply --target-profile NAME=PROFILE onto matching targets (including the
    // synthetic "default" target on bare HTML / --html / --html-dir).
    for (target_profiles.items) |tp| {
        var found = false;
        for (targets.items) |*t| {
            if (std.mem.eql(u8, t.name, tp.name)) {
                if (t.html_profile != null) return error.DuplicateFlag;
                t.html_profile = tp.profile;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidValue;
    }

    // The effective profile for the synthetic "default" target, surfaced on
    // Options for the single-target compile path (`main.runHtml`).
    var default_profile: ?render.OutputProfile = null;
    for (targets.items) |t| {
        if (std.mem.eql(u8, t.name, "default")) {
            default_profile = t.html_profile;
            break;
        }
    }

    // Attach --layout-rule TARGET SELECTOR PATH. Order relative to --target is
    // independent; unknown targets and duplicate selectors fail as usage.
    if (has_layout_rules) {
        // Count rules per target for the 256 limit.
        for (targets.items) |*t| {
            var count: usize = 0;
            for (pending_rules.items) |pr| {
                if (std.mem.eql(u8, pr.target, t.name)) count += 1;
            }
            if (count > layout_select.max_rules_per_target) return error.InvalidValue;
            if (count == 0) continue;

            var rules = try gpa.alloc(layout_select.LayoutRule, count);
            errdefer gpa.free(rules);
            var filled: usize = 0;
            for (pending_rules.items) |pr| {
                if (!std.mem.eql(u8, pr.target, t.name)) continue;
                const parsed = layout_select.parseSelector(pr.selector) catch return error.InvalidValue;
                rules[filled] = .{
                    .kind = parsed.kind,
                    .value = parsed.value,
                    .layout_path = pr.path,
                };
                filled += 1;
            }
            layout_select.rejectDuplicateSelectors(rules) catch return error.DuplicateFlag;
            layout_select.sortRulesCanonical(rules);
            t.layout_rules = rules;
        }
        // Unknown rule targets (no matching --target / default).
        for (pending_rules.items) |pr| {
            var found = false;
            for (targets.items) |t| {
                if (std.mem.eql(u8, t.name, pr.target)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.InvalidValue;
        }
    }

    // Canonical target order: equivalent --target argv permutations produce the
    // same Options.targets sequence (sorted by name). Execution/diagnostics use
    // the same order via validateTargets.
    if (targets.items.len > 1) {
        target_mod.sortTargetSpecsByName(targets.items);
    }

    return switch (mode) {
        .ir => .{
            .help = false,
            .quiet = quiet,
            .timings = saw_timings,
            .mode = .ir,
            .input_dir = input_dir,
            .out_dir = out_dir,
            .rag_dir = null,
            .scope = null,
            .split_size = null,
            .bundles_only = false,
            .llms_path = null,
            .html_dir = null,
            .targets = targets,
            .command = command,
            .impact_id = impact_id,
            .analysis_format = analysis_format,
            .analysis_report = analysis_report,
            .input_format = input_format,
        },
        .rag => .{
            .help = false,
            .quiet = quiet,
            .timings = saw_timings,
            .mode = .rag,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = rag_dir,
            .context_dir = null,
            .scope = scope,
            .split_size = split_size,
            .bundles_only = bundles_only,
            .complete = complete,
            .llms_path = null,
            .html_dir = null,
            .targets = targets,
            .input_format = input_format,
        },
        .context => .{
            .help = false,
            .quiet = quiet,
            .timings = saw_timings,
            .mode = .context,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = null,
            .context_dir = context_dir,
            .scope = scope,
            .split_size = split_size,
            .bundles_only = false,
            .llms_path = null,
            .html_dir = null,
            .targets = targets,
            .command = command,
            .impact_id = impact_id,
            .analysis_format = analysis_format,
            .analysis_report = analysis_report,
            .input_format = input_format,
        },
        .llms => .{
            .help = false,
            .quiet = quiet,
            .timings = saw_timings,
            .mode = .llms,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = null,
            .context_dir = null,
            .scope = null,
            .split_size = null,
            .bundles_only = false,
            .llms_path = llms_path,
            .publication_location = publication_location,
            .allow_markdown_links = allow_markdown_links,
            .targets = targets,
            .command = command,
            .impact_id = impact_id,
            .analysis_format = analysis_format,
            .analysis_report = analysis_report,
            .input_format = input_format,
        },
        .rss => .{
            .help = false,
            .quiet = quiet,
            .timings = saw_timings,
            .mode = .rss,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = null,
            .context_dir = null,
            .scope = null,
            .split_size = null,
            .bundles_only = false,
            .llms_path = null,
            .rss_path = rss_path,
            .site_url = site_url,
            .publication_location = publication_location,
            .allow_markdown_links = allow_markdown_links,
            .rss_title = rss_title,
            .rss_description = rss_description,
            .rss_limit = rss_limit,
            .html_dir = null,
            .targets = targets,
            .command = command,
            .impact_id = impact_id,
            .analysis_format = analysis_format,
            .analysis_report = analysis_report,
            .input_format = input_format,
        },
        .html => .{
            .help = false,
            .quiet = quiet,
            .timings = saw_timings,
            .mode = .html,
            .input_dir = input_dir,
            .out_dir = null,
            .rag_dir = null,
            .context_dir = null,
            .scope = null,
            .split_size = null,
            .bundles_only = false,
            .llms_path = null,
            .sitemap_path = if (wants_sitemap) sitemap_path else null,
            .site_url = site_url,
            .publication_location = publication_location,
            .allow_markdown_links = allow_markdown_links,
            .html_dir = if (has_explicit_targets) null else html_dir,
            .html_layout = html_layout,
            .owned_html_layout = owned_html_layout,
            .incremental = saw_incremental or saw_watch,
            .jobs = jobs,
            .watch = saw_watch,
            .serve = saw_serve or serve_port != null,
            .serve_port = serve_port,
            .html_profile = default_profile,
            .targets = targets,
            .command = command,
            .impact_id = impact_id,
            .analysis_format = analysis_format,
            .analysis_report = if (command == .check or command == .impact) analysis_report else null,
            .report_path = if (command == .check or command == .impact) null else analysis_report,
            .fail_on_unreferenced = fail_on_unreferenced,
            .input_format = input_format,
        },
    };
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
        \\  standard-site publish  One-shot Standard.site publish (OAuth + reconcile; never implicit)
        \\  standard-site plan    Emit the deterministic Standard.site plan offline (no network)
        \\  standard-site records Dump the full canonical record payloads offline (no network)
        \\  standard-site verify  Cross-check the built head links + well-known file offline (no network)
        \\  standard-site login  Authorize a DID and persist the session for later publishes
        \\  standard-site sessions  List persisted sessions (DIDs only; no secrets)
        \\  standard-site logout  Remove a persisted session (secure erase; does not revoke)
        \\  standard-site smoke  Live interop smoke against a real PDS (manual, opt-in; never in CI)
        \\  nostr plan          Emit the offline Nostr NIP-23 publication plan (no signing, no relay)
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
        \\  --handle HANDLE     AT Protocol handle for `login --app-password` (resolved to a DID)
        \\  --app-password      Opt-in app-password login (broad account write; never OAuth scope)
        \\  standard-site smoke options:
        \\  --did DID           Test identity DID (required)
        \\  --namespace NAME    Unique rkey namespace prefix (default: clock-derived)
        \\  --surface-url URL   Served verification-surface origin to check (optional)
        \\  --indexer URL       Indexer/AppView origin observed non-normatively (optional)
        \\  --out PATH          Smoke result artifact path (default: stdout)
        \\  standard-site options (all subcommands):
        \\  --session-root PATH Override the persistent session store root
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
        \\  --watch             Compatibility flag; same as the watch command
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
        \\  --report PATH        Write an analysis report instead of stdout
        \\  --fail-on-unreferenced Make check fail when it reports unreferenced pages
        \\  --profile PATH       Selected publication profile for `plan`
        \\  -h, --help          Show this help and exit 0
        \\  -V, --version       Print the compiler version (`boris/<ver>`) and exit 0
        \\
        \\HTML artifacts (success; Oliver + layout splice):
        \\  <html-dir>/**/*.html   or   <each-target-dir>/**/*.html
        \\  <target-dir>/sitemap.xml  (with --sitemap; path configurable)
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
        \\  --complete without --rag / --rag-dir
        \\  --complete with --scope, --split-size, or --bundles-only
        \\  --context / --context-dir with --rag, --out, or HTML selectors
        \\  --rss / --rss-path with HTML, IR, RAG, Context, llms.txt, validate, check, or impact
        \\  --sitemap / --sitemap-path without --site-url, with non-HTML modes,
        \\  or with multiple targets sharing one ambiguous public URL
        \\  explicit --out with --rag or --rag-dir
        \\  --html / --html-dir / --target / --target-layout / --layout-rule with --rag, --rag-dir, --context, or explicit --out
        \\  --target with --html-dir
        \\  --watch, --incremental, or --jobs with IR (--out / --no-rag) or RAG / context
        \\  validate with non-HTML exports, --incremental, --watch, --jobs, --format, or --report
        \\  Invalid target names, duplicate names, output collisions, workspace escape,
        \\  content/layout overlap, unknown --target-layout / --layout-rule target,
        \\  duplicate or invalid layout selectors, invalid layout paths (.. / absolute),
        \\  mixed theme roots, >256 rules/target
        \\
        \\Exit codes: 0 success, 1 content validation, 2 usage, 3 I/O/system
        \\
        \\Note: Bare `boris` builds HTML under dist/ as target "default". Use --out for JSON IR.
        \\      `boris validate` observes the selected HTML target configuration but writes no artifacts.
        \\      `boris plan --profile PATH` emits only the normalized declaration JSON on stdout.
        \\      `boris nostr plan --profile PATH` emits the offline NIP-23 publication plan on stdout;
        \\      it never signs, never contacts a relay, and never reads a key.
        \\      --html / --html-dir / bare CLI map to a single target named "default".
        \\      Equivalent --target / --target-layout / --layout-rule permutations yield the
        \\      same config (targets sorted by name; rules canonicalized). No layout frontmatter.
        \\
    , .{});
}

/// Print a usage diagnostic. Uses `std.debug.print` (not `std.log.err`) so
/// unit tests that exercise the usage path are not failed by the test logger.
pub fn printParseError(err: ParseError, bad_arg: ?[]const u8) void {
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
            if (bad_arg) |a| {
                std.debug.print("error: invalid value for {s}\n", .{a});
            } else {
                std.debug.print("error: invalid option value\n", .{});
            }
        },
        error.UnknownNostrSubcommand => {
            std.debug.print("error: unknown nostr subcommand (available: plan)\n", .{});
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

/// Find a likely "bad" argv token for error messages (best-effort).
pub fn findBadArg(args: []const []const u8) ?[]const u8 {
    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) continue;
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) continue;
        // Boolean mode/switch flags: never the bad arg — a failure elsewhere
        // must not be misattributed to them (e.g. `--rss` plus an unknown
        // flag, or RSS mode missing its channel metadata).
        if (std.mem.eql(u8, a, "--quiet") or
            std.mem.eql(u8, a, "--timings") or
            std.mem.eql(u8, a, "--rag") or
            std.mem.eql(u8, a, "--no-rag") or
            std.mem.eql(u8, a, "--html") or
            std.mem.eql(u8, a, "--textile") or
            std.mem.eql(u8, a, "--cooklang") or
            std.mem.eql(u8, a, "--incremental") or
            std.mem.eql(u8, a, "--watch") or
            std.mem.eql(u8, a, "--fail-on-unreferenced") or
            std.mem.eql(u8, a, "--context") or
            std.mem.eql(u8, a, "--bundles-only") or
            std.mem.eql(u8, a, "--complete") or
            std.mem.eql(u8, a, "--llms") or
            std.mem.eql(u8, a, "--rss") or
            std.mem.eql(u8, a, "--sitemap") or
            std.mem.eql(u8, a, "--allow-markdown-links"))
        {
            continue;
        }
        if (std.mem.eql(u8, a, "--input") or
            std.mem.eql(u8, a, "--profile") or
            std.mem.eql(u8, a, "--out") or
            std.mem.eql(u8, a, "--rag-dir") or
            std.mem.eql(u8, a, "--context-dir") or
            std.mem.eql(u8, a, "--scope") or
            std.mem.eql(u8, a, "--split-size") or
            std.mem.eql(u8, a, "--llms-path") or
            std.mem.eql(u8, a, "--rss-path") or
            std.mem.eql(u8, a, "--rss-title") or
            std.mem.eql(u8, a, "--rss-description") or
            std.mem.eql(u8, a, "--rss-limit") or
            std.mem.eql(u8, a, "--site-url") or
            std.mem.eql(u8, a, "--sitemap-path") or
            std.mem.eql(u8, a, "--pages-base-url") or
            std.mem.eql(u8, a, "--pages-origin") or
            std.mem.eql(u8, a, "--pages-base-path") or
            std.mem.eql(u8, a, "--format") or
            std.mem.eql(u8, a, "--report") or
            std.mem.eql(u8, a, "--theme") or
            std.mem.eql(u8, a, "--html-dir") or
            std.mem.eql(u8, a, "--html-layout") or
            std.mem.eql(u8, a, "--target") or
            std.mem.eql(u8, a, "--target-layout") or
            std.mem.eql(u8, a, "--layout-rule") or
            std.mem.eql(u8, a, "--jobs") or
            std.mem.eql(u8, a, "-j"))
        {
            // Value may be missing or empty — report the flag name.
            return a;
        }
        if (std.mem.startsWith(u8, a, "--input=") or
            std.mem.startsWith(u8, a, "--profile=") or
            std.mem.startsWith(u8, a, "--out=") or
            std.mem.startsWith(u8, a, "--rag-dir=") or
            std.mem.startsWith(u8, a, "--context-dir=") or
            std.mem.startsWith(u8, a, "--scope=") or
            std.mem.startsWith(u8, a, "--split-size=") or
            std.mem.startsWith(u8, a, "--llms-path=") or
            std.mem.startsWith(u8, a, "--rss-path=") or
            std.mem.startsWith(u8, a, "--rss-title=") or
            std.mem.startsWith(u8, a, "--rss-description=") or
            std.mem.startsWith(u8, a, "--rss-limit=") or
            std.mem.startsWith(u8, a, "--site-url=") or
            std.mem.startsWith(u8, a, "--sitemap-path=") or
            std.mem.startsWith(u8, a, "--pages-base-url=") or
            std.mem.startsWith(u8, a, "--pages-origin=") or
            std.mem.startsWith(u8, a, "--pages-base-path=") or
            std.mem.startsWith(u8, a, "--format=") or
            std.mem.startsWith(u8, a, "--report=") or
            std.mem.startsWith(u8, a, "--theme=") or
            std.mem.startsWith(u8, a, "--html-dir=") or
            std.mem.startsWith(u8, a, "--html-layout=") or
            std.mem.startsWith(u8, a, "--target=") or
            std.mem.startsWith(u8, a, "--target-layout=") or
            std.mem.startsWith(u8, a, "--layout-rule=") or
            std.mem.startsWith(u8, a, "--jobs=") or
            std.mem.startsWith(u8, a, "-j="))
        {
            return a;
        }
        return a;
    }
    return null;
}

/// Dispatch parsed options through a small injectable runner.
///
/// - Version: calls `runner.printVersion()` and returns success; never calls `run`.
/// - Help: calls `runner.printHelp()` and returns success; never calls `run`.
/// - Build modes: calls `runner.run(opts)` and returns its exit code.
///
/// `runner` must provide `printVersion`, `printHelp`, and `run` methods.
pub fn execute(opts: Options, runner: anytype) ExitCode {
    if (opts.version) {
        runner.printVersion();
        return .success;
    }
    if (opts.help) {
        runner.printHelp();
        return .success;
    }
    return runner.run(opts);
}

/// Parse argv and execute. Maps all parse failures to exit code 2.
///
/// On parse failure, calls `runner.reportUsage(err, bad_arg)` when that method
/// exists; otherwise falls back to `printParseError` + `printUsage`.
pub fn runArgs(args: []const []const u8, runner: anytype) u8 {
    const gpa = if (@hasField(@TypeOf(runner.*), "gpa")) runner.gpa else std.testing.allocator;
    var opts = parseOptions(gpa, args) catch |err| {
        const bad = findBadArg(args);
        const Runner = @TypeOf(runner.*);
        if (@hasDecl(Runner, "reportUsage")) {
            runner.reportUsage(err, bad);
        } else {
            printParseError(err, bad);
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
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "--profile", "site.json" }));
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
    try expectError(error.UnexpectedPositional, parseOptions(std.testing.allocator, &.{ "boris", "standard-site" }));
    try expectError(error.UnexpectedPositional, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "bogus" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--plan" }));
    try expectError(error.DuplicateFlag, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--prune", "--prune" }));
    // Compiler mode / projection selectors are usage errors: publish never
    // runs as a side effect of build/validate/watch/plan flags.
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--rag" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--target", "public=dist" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--watch" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--timings" }));
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

    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan", "--profile", "a", "--did", "d" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan", "--profile", "a", "--prune" }));
}

test "parse: standard-site records emits full record payloads offline" {
    var o = try parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "records", "--profile", "site.json", "--out", "records.json" });
    defer o.deinit(std.testing.allocator);
    try expectEqual(StandardSiteCommand.records, o.standard_site_command);
    try expect(!o.standard_site_publish);
    try expectEqualStrings("site.json", o.profile_path.?);
    try expectEqualStrings("records.json", o.records_out.?);

    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "records" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "records", "--profile", "a", "--did", "d" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "records", "--profile", "a", "--prune" }));
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

    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "verify" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "verify", "--profile", "a", "--did", "d" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "verify", "--profile", "a", "--prune" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "plan", "--profile", "a", "--dist", "x" }));
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
    try expectEqualStrings("did:plc:ewvi7nxzyoun6zhxrhs64oiz", o.session_did.?);

    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "logout" }));
    try expectError(error.UnexpectedPositional, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "a", "extra" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "a", "--rag" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "a", "--profile", "p.json" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "sessions", "--did", "a" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--did", "d" }));
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

    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--app-password" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--app-password", "--did", "a", "--handle", "b" }));
    // The app-password flag is login-only, and --handle is login-only.
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--app-password" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "logout", "--did", "a", "--app-password" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--app-password" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "sessions", "--app-password" }));
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
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--profile", "p.json" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--plan", "plan.json" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "smoke", "--did", "a", "--rag" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "publish", "--profile", "a", "--namespace", "n" }));
    try expectError(error.ConflictingFlags, parseOptions(std.testing.allocator, &.{ "boris", "standard-site", "login", "--did", "a", "--indexer", "i" }));
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

test "parse: nostr has exactly one subcommand, and it needs a profile" {
    // A missing or unknown subcommand is named, so nothing suggests that
    // signing or publishing exists in this build.
    try expectError(error.UnknownNostrSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "nostr" }));
    try expectError(error.UnknownNostrSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "sign" }));
    try expectError(error.UnknownNostrSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "publish" }));
    try expectError(error.UnknownNostrSubcommand, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "--profile", "a" }));
    try expectError(error.MissingValue, parseOptions(std.testing.allocator, &.{ "boris", "nostr", "plan" }));
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

        pub fn reportUsage(self: *@This(), err: ParseError, bad_arg: ?[]const u8) void {
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

        pub fn reportUsage(self: *@This(), err: ParseError, bad_arg: ?[]const u8) void {
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
