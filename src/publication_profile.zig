//! Strict, internal schema-v1 publication-profile parsing and static planning.
//!
//! This module deliberately has no CLI or publisher dependency. A future
//! coordinator receives only the owned `PublicationRequest`; JSON parser nodes
//! and argv views stop at `parseBytes` / `applyOverrides`.

const std = @import("std");
const github_pages = @import("github_pages.zig");
const identity = @import("identity.zig");
const layout_select = @import("layout_select.zig");
const rss = @import("rss.zig");
const sitemap = @import("sitemap.zig");
const standard_site = @import("standard_site.zig");
const nostr = @import("nostr.zig");
const target = @import("target.zig");
const theme = @import("theme.zig");

pub const max_profile_bytes: usize = 256 * 1024;
pub const max_json_depth: usize = 16;
pub const max_string_bytes: usize = 4 * 1024;
pub const max_path_bytes: usize = 1024;
pub const max_targets: usize = 32;
pub const max_array_items: usize = 256;
pub const max_target_name_bytes: usize = 64;
pub const max_site_text_bytes: usize = 1024;
pub const max_nostr_articles: usize = 256;

pub const Error = error{
    ProfileTooLarge,
    InvalidUtf8,
    EmbeddedNul,
    NestingTooDeep,
    ArrayLimitExceeded,
    StringTooLong,
    InvalidJson,
    DuplicateKey,
    UnknownKey,
    WrongType,
    MissingField,
    InvalidFormat,
    InvalidSchemaVersion,
    InvalidInputFormat,
    InvalidPath,
    InvalidTarget,
    InvalidLayout,
    InvalidSite,
    InvalidLimit,
    NoPublicationOutput,
    MultiplePublicTargets,
    PublicArtifactRequiresPublicTarget,
    PublicArtifactRequiresSiteUrl,
    RssRequiresSiteMetadata,
    InvalidPublication,
    PublicationRequiresPublicTarget,
    PublicationSiteMismatch,
    OutputConflict,
    ReservedOutputRoot,
    AmbiguousHtmlOverride,
    /// A `nostr` section is malformed: bad pubkey, relay, article id, or
    /// budget. The protocol-level cause is reported by `nostr.Error`.
    InvalidNostr,
    /// Nostr publication needs the canonical page URL, which only the
    /// publication location provides.
    NostrRequiresPublication,
} || std.mem.Allocator.Error;

pub const InputFormat = enum { markdown, textile, cook };

pub const ProfileWorkspace = struct {
    /// Normalized absolute parent directory of the selected profile file.
    root: []u8,

    pub fn deinit(self: *ProfileWorkspace, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.* = undefined;
    }
};

/// Normalize a selected profile path against the caller-provided current
/// directory. This does no discovery and does not read the filesystem.
pub fn profileWorkspace(allocator: std.mem.Allocator, cwd: []const u8, selected_path: []const u8) !ProfileWorkspace {
    if (selected_path.len == 0 or std.mem.indexOfScalar(u8, selected_path, 0) != null) return error.InvalidPath;
    const resolved = try std.fs.path.resolve(allocator, &.{ cwd, selected_path });
    defer allocator.free(resolved);
    const parent = std.fs.path.dirname(resolved) orelse return error.InvalidPath;
    return .{ .root = try allocator.dupe(u8, parent) };
}

pub const SiteMetadata = struct {
    url: ?[]u8 = null,
    title: ?[]u8 = null,
    description: ?[]u8 = null,

    fn deinit(self: *SiteMetadata, allocator: std.mem.Allocator) void {
        if (self.url) |v| allocator.free(v);
        if (self.title) |v| allocator.free(v);
        if (self.description) |v| allocator.free(v);
        self.* = undefined;
    }
};

pub const SitemapPlan = struct { path: []u8 };
pub const RssPlan = struct { path: []u8, limit: usize = 20 };
pub const LlmsPlan = struct { path: []u8 };
/// Static passthrough declaration (#804): a project-relative directory whose
/// contents copy byte-identically into the target root.
pub const StaticPlan = struct { dir: []u8 };
pub const IrPlan = struct { output: []u8 };
pub const RagPlan = struct { output: []u8, scope: ?[]u8 = null, split_size: ?usize = null, bundles_only: bool = false };
pub const ContextPlan = struct { output: []u8, scope: ?[]u8 = null, split_size: ?usize = null };

/// The publication-target registry. The seam stays closed and additive:
/// existing `github-pages` profiles parse byte-identically, and `standard-site`
/// is the second verified target (see docs/contracts/standard-site.md).
pub const PublicationTargetPlan = union(enum) {
    github_pages: github_pages.Location,
    standard_site: standard_site.TargetConfig,

    fn deinit(self: *PublicationTargetPlan, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .github_pages => |*location| location.deinit(allocator),
            .standard_site => |*config| config.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Owned Nostr NIP-23 publication configuration.
///
/// Public configuration only: the *expected author* public key, the exact
/// entity-id allowlist, the relay targets, and bounded delivery budgets. No
/// secret ever enters this type — the private key belongs to a later signing
/// slice, reads from a dedicated channel, and is never a profile field.
pub const NostrPlan = struct {
    enabled: bool = false,
    /// Expected author x-only public key, 64 lowercase hex digits.
    pubkey: []u8,
    /// Exact entity ids selected for publication, sorted ascending and
    /// deduplicated. Selection is an allowlist rather than a filter: putting an
    /// article on the network is not something a glob should be able to do by
    /// accident.
    articles: [][]u8 = &.{},
    /// Normalized relay targets, sorted bytewise. Never a default list:
    /// where an article is published is the author's decision.
    relays: [][]u8 = &.{},
    timeout_ms: usize = nostr.default_timeout_ms,
    retries: usize = 0,

    fn deinit(self: *NostrPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.pubkey);
        for (self.articles) |v| allocator.free(v);
        if (self.articles.len > 0) allocator.free(self.articles);
        for (self.relays) |v| allocator.free(v);
        if (self.relays.len > 0) allocator.free(self.relays);
        self.* = undefined;
    }
};

pub const HtmlTargetPlan = struct {
    name: []u8,
    output: []u8,
    public: bool = false,
    theme: ?[]u8 = null,
    layout: ?[]u8 = null,
    layout_rules: []layout_select.LayoutRule = &.{},
    sitemap: ?SitemapPlan = null,
    rss: ?RssPlan = null,
    llms: ?LlmsPlan = null,
    static: ?StaticPlan = null,

    fn deinit(self: *HtmlTargetPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.output);
        if (self.theme) |v| allocator.free(v);
        if (self.layout) |v| allocator.free(v);
        for (self.layout_rules) |rule| {
            allocator.free(rule.value);
            allocator.free(rule.layout_path);
        }
        if (self.layout_rules.len > 0) allocator.free(self.layout_rules);
        if (self.sitemap) |v| allocator.free(v.path);
        if (self.rss) |v| allocator.free(v.path);
        if (self.llms) |v| allocator.free(v.path);
        if (self.static) |v| allocator.free(v.dir);
        self.* = undefined;
    }
};

/// Owned canonical publication identity. Execution knobs do not live here.
pub const PublicationPlan = struct {
    input: []u8,
    input_format: InputFormat = .markdown,
    site: ?SiteMetadata = null,
    publication: ?PublicationTargetPlan = null,
    targets: []HtmlTargetPlan = &.{},
    ir: ?IrPlan = null,
    rag: ?RagPlan = null,
    context: ?ContextPlan = null,
    nostr: ?NostrPlan = null,

    pub fn deinit(self: *PublicationPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.input);
        if (self.site) |*v| v.deinit(allocator);
        if (self.publication) |*v| v.deinit(allocator);
        for (self.targets) |*v| v.deinit(allocator);
        if (self.targets.len > 0) allocator.free(self.targets);
        if (self.ir) |v| allocator.free(v.output);
        if (self.rag) |v| {
            allocator.free(v.output);
            if (v.scope) |scope| allocator.free(scope);
        }
        if (self.context) |v| {
            allocator.free(v.output);
            if (v.scope) |scope| allocator.free(scope);
        }
        if (self.nostr) |*v| v.deinit(allocator);
        self.* = undefined;
    }
};

pub const PublicationExecution = struct { jobs: usize = 1, incremental: bool = false, quiet: bool = false };
pub const PublicationRequest = struct {
    workspace: ProfileWorkspace,
    plan: PublicationPlan,
    execution: PublicationExecution = .{},

    pub fn deinit(self: *PublicationRequest, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        self.workspace.deinit(allocator);
        self.* = undefined;
    }
};

/// Every override preserves omitted versus explicit state. No legacy defaults
/// enter this type, so profile normalization remains deterministic.
pub const ProfileOverrides = struct {
    input: ?[]const u8 = null,
    input_format: ?InputFormat = null,
    /// Global HTML output override; only meaningful for a single target.
    html_output: ?[]const u8 = null,
    jobs: ?usize = null,
    incremental: ?bool = null,
    quiet: ?bool = null,
};

pub fn parseBytes(allocator: std.mem.Allocator, workspace: ProfileWorkspace, bytes: []const u8, overrides: ProfileOverrides) Error!PublicationRequest {
    // The selected workspace transfers into this boundary even when parsing
    // fails; callers never retain a partially constructed request.
    errdefer {
        var rejected_workspace = workspace;
        rejected_workspace.deinit(allocator);
    }
    if (bytes.len > max_profile_bytes) return error.ProfileTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
    try checkDepth(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_string_bytes,
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.DuplicateField => error.DuplicateKey,
        error.ValueTooLong => error.StringTooLong,
        else => error.InvalidJson,
    };
    defer parsed.deinit();

    var plan = try parsePlan(allocator, parsed.value);
    errdefer plan.deinit(allocator);
    try applyOverrides(allocator, &plan, overrides);
    try validatePlan(&plan);
    return .{ .workspace = workspace, .plan = plan, .execution = .{
        .jobs = overrides.jobs orelse 1,
        .incremental = overrides.incremental orelse false,
        .quiet = overrides.quiet orelse false,
    } };
}

fn checkDepth(bytes: []const u8) Error!void {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') in_string = true else if (c == '{' or c == '[') {
            depth += 1;
            if (depth > max_json_depth) return error.NestingTooDeep;
        } else if ((c == '}' or c == ']') and depth > 0) {
            depth -= 1;
        }
    }
}

fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return switch (value) {
        .object => |v| v,
        else => error.WrongType,
    };
}
fn array(value: std.json.Value) Error![]std.json.Value {
    return switch (value) {
        .array => |v| v.items,
        else => error.WrongType,
    };
}
fn string(value: std.json.Value) Error![]const u8 {
    const v = switch (value) {
        .string => |s| s,
        else => return error.WrongType,
    };
    if (v.len > max_string_bytes) return error.StringTooLong;
    if (std.mem.indexOfScalar(u8, v, 0) != null) return error.EmbeddedNul;
    return v;
}
fn boolean(value: std.json.Value) Error!bool {
    return switch (value) {
        .bool => |v| v,
        else => error.WrongType,
    };
}
fn integer(value: std.json.Value) Error!usize {
    return switch (value) {
        .integer => |v| if (v >= 0) @intCast(v) else error.InvalidLimit,
        else => error.WrongType,
    };
}
fn field(obj: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    return obj.get(name);
}
fn required(obj: std.json.ObjectMap, name: []const u8) Error!std.json.Value {
    return field(obj, name) orelse error.MissingField;
}
fn only(obj: std.json.ObjectMap, names: []const []const u8) Error!void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        var known = false;
        for (names) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.UnknownKey;
    }
}
fn dup(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    return allocator.dupe(u8, value);
}

fn parsePlan(allocator: std.mem.Allocator, value: std.json.Value) Error!PublicationPlan {
    const root = try object(value);
    try only(root, &.{ "format", "schema_version", "input", "input_format", "site", "publication", "targets", "editions", "nostr" });
    if (!std.mem.eql(u8, try string(try required(root, "format")), "boris-publication-profile")) return error.InvalidFormat;
    if ((try integer(try required(root, "schema_version"))) != 1) return error.InvalidSchemaVersion;
    var plan = PublicationPlan{ .input = try dup(allocator, if (field(root, "input")) |v| try checkedPath(v) else "content") };
    errdefer plan.deinit(allocator);
    if (field(root, "input_format")) |v| plan.input_format = try parseInputFormat(v);
    if (field(root, "site")) |v| plan.site = try parseSite(allocator, v);
    if (field(root, "publication")) |v| plan.publication = try parsePublication(allocator, v);
    if (field(root, "targets")) |v| plan.targets = try parseTargets(allocator, v);
    if (field(root, "editions")) |v| try parseEditions(allocator, &plan, v);
    if (field(root, "nostr")) |v| plan.nostr = try parseNostr(allocator, v);
    return plan;
}

/// Parse the `nostr` section: a NIP-23 long-form publication surface.
///
/// Every protocol judgement (pubkey grammar, relay grammar and normalization,
/// relay ordering) is delegated to `nostr.zig`; this function owns only the
/// JSON shape, the allowlist canonicalization, and the ownership transfer.
fn parseNostr(allocator: std.mem.Allocator, value: std.json.Value) Error!NostrPlan {
    const obj = try object(value);
    try only(obj, &.{ "enabled", "pubkey", "articles", "relays", "timeout_ms", "retries" });

    const pubkey_raw = try string(try required(obj, "pubkey"));
    const pubkey = nostr.parseAuthorPubkey(allocator, pubkey_raw) catch return error.InvalidNostr;

    var out = NostrPlan{ .pubkey = pubkey };
    errdefer out.deinit(allocator);

    if (field(obj, "enabled")) |v| out.enabled = try boolean(v);
    out.articles = try parseNostrArticles(allocator, try required(obj, "articles"));
    out.relays = try parseNostrRelays(allocator, try required(obj, "relays"));
    if (field(obj, "timeout_ms")) |v| {
        const n = try integer(v);
        if (n < nostr.min_timeout_ms or n > nostr.max_timeout_ms) return error.InvalidNostr;
        out.timeout_ms = n;
    }
    if (field(obj, "retries")) |v| {
        const n = try integer(v);
        if (n > nostr.max_retries) return error.InvalidNostr;
        out.retries = n;
    }
    return out;
}

/// The selected entity ids, validated as ids, sorted ascending, duplicates
/// refused. Sorting here (rather than at emission) is what makes the plan
/// independent of the order the author happened to list them in.
fn parseNostrArticles(allocator: std.mem.Allocator, value: std.json.Value) Error![][]u8 {
    const values = try array(value);
    if (values.len == 0) return error.InvalidNostr;
    if (values.len > max_nostr_articles or values.len > max_array_items) return error.ArrayLimitExceeded;

    var out = try allocator.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |v| allocator.free(v);
        allocator.free(out);
    }
    for (values) |v| {
        const id = try string(v);
        if (!identity.validateEntityId(id)) return error.InvalidNostr;
        out[initialized] = try dup(allocator, id);
        initialized += 1;
    }
    std.mem.sort([]u8, out, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var i: usize = 1;
    while (i < out.len) : (i += 1) {
        if (std.mem.eql(u8, out[i - 1], out[i])) return error.InvalidNostr;
    }
    return out;
}

fn parseNostrRelays(allocator: std.mem.Allocator, value: std.json.Value) Error![][]u8 {
    const values = try array(value);
    if (values.len == 0 or values.len > nostr.max_relays) return error.InvalidNostr;

    var out = try allocator.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |v| allocator.free(v);
        allocator.free(out);
    }
    for (values) |v| {
        out[initialized] = nostr.normalizeRelayUrl(allocator, try string(v)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.InvalidNostr;
        };
        initialized += 1;
    }
    nostr.sortRelays(out) catch return error.InvalidNostr;
    return out;
}

fn parseInputFormat(value: std.json.Value) Error!InputFormat {
    const v = try string(value);
    if (std.mem.eql(u8, v, "markdown")) return .markdown;
    if (std.mem.eql(u8, v, "textile")) return .textile;
    if (std.mem.eql(u8, v, "cook")) return .cook;
    return error.InvalidInputFormat;
}
fn checkedPath(value: std.json.Value) Error![]const u8 {
    const v = try string(value);
    if (v.len == 0 or v.len > max_path_bytes) return error.InvalidPath;
    layout_select.validateLayoutPath(v) catch return error.InvalidPath;
    return v;
}
fn parseSite(allocator: std.mem.Allocator, value: std.json.Value) Error!SiteMetadata {
    const obj = try object(value);
    try only(obj, &.{ "url", "title", "description" });
    var site = SiteMetadata{};
    errdefer site.deinit(allocator);
    if (field(obj, "url")) |v| {
        const raw = try string(v);
        if (raw.len == 0) return error.InvalidSite;
        site.url = rss.normalizedSiteUrl(allocator, raw) catch return error.InvalidSite;
    }
    if (field(obj, "title")) |v| site.title = try boundedText(allocator, v);
    if (field(obj, "description")) |v| site.description = try boundedText(allocator, v);
    return site;
}

fn parsePublication(allocator: std.mem.Allocator, value: std.json.Value) Error!PublicationTargetPlan {
    const obj = try object(value);
    try only(obj, &.{ "target", "base_url", "origin", "base_path", "did", "pds", "name", "description", "show_in_discover", "include", "exclude", "prune" });
    const target_text = try string(try required(obj, "target"));
    if (std.mem.eql(u8, target_text, github_pages.target_name)) {
        try only(obj, &.{ "target", "base_url", "origin", "base_path" });
        const base_url = try string(try required(obj, "base_url"));
        const origin = try string(try required(obj, "origin"));
        const base_path = try string(try required(obj, "base_path"));
        const location = github_pages.parse(allocator, base_url, origin, base_path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.InvalidPublication;
        };
        return .{ .github_pages = location };
    }
    if (std.mem.eql(u8, target_text, standard_site.target_name)) {
        const base_url = try string(try required(obj, "base_url"));
        const origin = try string(try required(obj, "origin"));
        const base_path = try string(try required(obj, "base_path"));
        const did = try string(try required(obj, "did"));
        if (did.len == 0 or !standard_site.validDid(did)) return error.InvalidPublication;
        const location = standard_site.parseLocation(allocator, base_url, origin, base_path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.InvalidPublication;
        };
        var config: standard_site.TargetConfig = .{
            .location = location,
            .did = try dup(allocator, did),
        };
        errdefer config.deinit(allocator);
        if (field(obj, "pds")) |v| {
            const pds = try boundedText(allocator, v);
            if (!standard_site.validPdsOrigin(pds)) return error.InvalidPublication;
            config.pds_origin = pds;
        }
        if (field(obj, "name")) |v| config.name = try boundedText(allocator, v);
        if (field(obj, "description")) |v| config.description = try boundedText(allocator, v);
        if (field(obj, "show_in_discover")) |v| config.show_in_discover = try boolean(v);
        if (field(obj, "include")) |v| config.include = try parseFilters(allocator, v);
        if (field(obj, "exclude")) |v| config.exclude = try parseFilters(allocator, v);
        if (field(obj, "prune")) |v| config.prune = try boolean(v);
        return .{ .standard_site = config };
    }
    return error.InvalidPublication;
}

fn parseFilters(allocator: std.mem.Allocator, value: std.json.Value) Error![][]const u8 {
    const values = try array(value);
    if (values.len > max_array_items) return error.ArrayLimitExceeded;
    var filters = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (filters[0..initialized]) |entry| allocator.free(entry);
        allocator.free(filters);
    }
    for (values) |entry| {
        const text = try string(entry);
        if (text.len == 0) return error.InvalidPublication;
        filters[initialized] = try dup(allocator, text);
        initialized += 1;
    }
    return filters;
}
fn boundedText(allocator: std.mem.Allocator, value: std.json.Value) Error![]u8 {
    const v = try string(value);
    if (v.len == 0 or v.len > max_site_text_bytes) return error.InvalidSite;
    return dup(allocator, v);
}

fn parseTargets(allocator: std.mem.Allocator, value: std.json.Value) Error![]HtmlTargetPlan {
    const values = try array(value);
    if (values.len > max_targets or values.len > max_array_items) return error.ArrayLimitExceeded;
    var targets = try allocator.alloc(HtmlTargetPlan, values.len);
    var initialized: usize = 0;
    errdefer {
        for (targets[0..initialized]) |*v| v.deinit(allocator);
        allocator.free(targets);
    }
    for (values) |v| {
        targets[initialized] = try parseTarget(allocator, v);
        initialized += 1;
    }
    std.mem.sort(HtmlTargetPlan, targets, {}, struct {
        fn less(_: void, a: HtmlTargetPlan, b: HtmlTargetPlan) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    return targets;
}
fn parseTarget(allocator: std.mem.Allocator, value: std.json.Value) Error!HtmlTargetPlan {
    const obj = try object(value);
    try only(obj, &.{ "name", "output", "public", "theme", "layout", "layout_rules", "sitemap", "rss", "llms", "static" });
    const name = try string(try required(obj, "name"));
    if (name.len > max_target_name_bytes or !target.isValidTargetName(name)) return error.InvalidTarget;
    var out = HtmlTargetPlan{ .name = try dup(allocator, name), .output = try dup(allocator, try checkedPath(try required(obj, "output"))) };
    errdefer out.deinit(allocator);
    if (field(obj, "public")) |v| out.public = try boolean(v);
    if (field(obj, "theme")) |v| {
        const path = try checkedPath(v);
        theme.validateThemeRootPath(path) catch return error.InvalidPath;
        out.theme = try dup(allocator, path);
    }
    if (field(obj, "layout")) |v| out.layout = try dup(allocator, try checkedPath(v));
    if (out.theme != null and out.layout != null) return error.InvalidLayout;
    if (field(obj, "layout_rules")) |v| out.layout_rules = try parseRules(allocator, v);
    if (field(obj, "sitemap")) |v| out.sitemap = try parseSitemap(allocator, v);
    if (field(obj, "rss")) |v| out.rss = try parseRss(allocator, v);
    if (field(obj, "llms")) |v| out.llms = try parseLlms(allocator, v);
    if (field(obj, "static")) |v| out.static = try parseStatic(allocator, v);
    return out;
}
fn parseRules(allocator: std.mem.Allocator, value: std.json.Value) Error![]layout_select.LayoutRule {
    const values = try array(value);
    if (values.len > layout_select.max_rules_per_target or values.len > max_array_items) return error.ArrayLimitExceeded;
    var rules = try allocator.alloc(layout_select.LayoutRule, values.len);
    var initialized: usize = 0;
    errdefer {
        for (rules[0..initialized]) |rule| {
            allocator.free(rule.value);
            allocator.free(rule.layout_path);
        }
        allocator.free(rules);
    }
    for (values) |value_| {
        const obj = try object(value_);
        try only(obj, &.{ "selector", "layout" });
        const selector = try string(try required(obj, "selector"));
        const parsed = layout_select.parseSelector(selector) catch return error.InvalidLayout;
        rules[initialized] = .{ .kind = parsed.kind, .value = try dup(allocator, parsed.value), .layout_path = try dup(allocator, try checkedPath(try required(obj, "layout"))) };
        initialized += 1;
    }
    layout_select.rejectDuplicateSelectors(rules) catch return error.InvalidLayout;
    layout_select.sortRulesCanonical(rules);
    return rules;
}
fn parseSitemap(allocator: std.mem.Allocator, value: std.json.Value) Error!SitemapPlan {
    const obj = try object(value);
    try only(obj, &.{"path"});
    const path = try string(try required(obj, "path"));
    sitemap.validateOutputPath(path) catch return error.InvalidPath;
    return .{ .path = try dup(allocator, path) };
}
fn parseRss(allocator: std.mem.Allocator, value: std.json.Value) Error!RssPlan {
    const obj = try object(value);
    try only(obj, &.{ "path", "limit" });
    const path = try checkedPath(try required(obj, "path"));
    sitemap.validateOutputPath(path) catch return error.InvalidPath;
    const limit = if (field(obj, "limit")) |v| try integer(v) else 20;
    if (limit < 1 or limit > 500) return error.InvalidLimit;
    return .{ .path = try dup(allocator, path), .limit = limit };
}
fn parseLlms(allocator: std.mem.Allocator, value: std.json.Value) Error!LlmsPlan {
    const obj = try object(value);
    try only(obj, &.{"path"});
    const path = try checkedPath(try required(obj, "path"));
    sitemap.validateOutputPath(path) catch return error.InvalidPath;
    return .{ .path = try dup(allocator, path) };
}
fn parseStatic(allocator: std.mem.Allocator, value: std.json.Value) Error!StaticPlan {
    const obj = try object(value);
    try only(obj, &.{"dir"});
    return .{ .dir = try dup(allocator, try checkedPath(try required(obj, "dir"))) };
}

fn parseEditions(allocator: std.mem.Allocator, plan: *PublicationPlan, value: std.json.Value) Error!void {
    const obj = try object(value);
    try only(obj, &.{ "ir", "rag", "context" });
    if (field(obj, "ir")) |v| plan.ir = try parseIr(allocator, v);
    if (field(obj, "rag")) |v| plan.rag = try parseRag(allocator, v);
    if (field(obj, "context")) |v| plan.context = try parseContext(allocator, v);
}
fn parseIr(allocator: std.mem.Allocator, value: std.json.Value) Error!IrPlan {
    const obj = try object(value);
    try only(obj, &.{"output"});
    return .{ .output = try dup(allocator, try checkedPath(try required(obj, "output"))) };
}
fn parseRag(allocator: std.mem.Allocator, value: std.json.Value) Error!RagPlan {
    const obj = try object(value);
    try only(obj, &.{ "output", "scope", "split_size", "bundles_only" });
    var out = RagPlan{ .output = try dup(allocator, try checkedPath(try required(obj, "output"))) };
    errdefer {
        allocator.free(out.output);
        if (out.scope) |v| allocator.free(v);
    }
    if (field(obj, "scope")) |v| out.scope = try dup(allocator, try checkedScope(v));
    if (field(obj, "split_size")) |v| {
        const n = try integer(v);
        if (n == 0) return error.InvalidLimit;
        out.split_size = n;
    }
    if (field(obj, "bundles_only")) |v| out.bundles_only = try boolean(v);
    return out;
}
fn parseContext(allocator: std.mem.Allocator, value: std.json.Value) Error!ContextPlan {
    const obj = try object(value);
    try only(obj, &.{ "output", "scope", "split_size" });
    var out = ContextPlan{ .output = try dup(allocator, try checkedPath(try required(obj, "output"))) };
    errdefer {
        allocator.free(out.output);
        if (out.scope) |v| allocator.free(v);
    }
    if (field(obj, "scope")) |v| out.scope = try dup(allocator, try checkedScope(v));
    if (field(obj, "split_size")) |v| {
        const n = try integer(v);
        if (n == 0) return error.InvalidLimit;
        out.split_size = n;
    }
    return out;
}

pub fn applyOverrides(allocator: std.mem.Allocator, plan: *PublicationPlan, overrides: ProfileOverrides) Error!void {
    if (overrides.input) |v| {
        const path = try checkedPathValue(v);
        allocator.free(plan.input);
        plan.input = try dup(allocator, path);
    }
    if (overrides.input_format) |v| plan.input_format = v;
    if (overrides.html_output) |v| {
        if (plan.targets.len != 1) return error.AmbiguousHtmlOverride;
        const path = try checkedPathValue(v);
        allocator.free(plan.targets[0].output);
        plan.targets[0].output = try dup(allocator, path);
    }
}
fn checkedPathValue(v: []const u8) Error![]const u8 {
    if (v.len == 0 or v.len > max_path_bytes) return error.InvalidPath;
    layout_select.validateLayoutPath(v) catch return error.InvalidPath;
    return v;
}
fn checkedScope(value: std.json.Value) Error![]const u8 {
    const v = try string(value);
    // Scope is an existing entity-id / collection-prefix selector, not a
    // filesystem path. Preserve its current exporter grammar while preventing
    // traversal-shaped configuration from reaching that later semantic check.
    if (v.len == 0 or v.len > max_path_bytes or v[0] == '/' or std.mem.indexOfScalar(u8, v, '\\') != null or std.mem.indexOf(u8, v, "..") != null) return error.InvalidPath;
    return v;
}

pub fn validatePlan(plan: *const PublicationPlan) Error!void {
    if (plan.targets.len == 0 and plan.ir == null and plan.rag == null and plan.context == null) return error.NoPublicationOutput;
    var public_count: usize = 0;
    for (plan.targets, 0..) |t, i| {
        if (t.public) public_count += 1;
        for (plan.targets[i + 1 ..]) |other| if (std.mem.eql(u8, t.name, other.name)) return error.InvalidTarget;
        if (t.theme) |theme_root| {
            if (pathNest(t.output, theme_root)) return error.OutputConflict;
            for (t.layout_rules) |rule| {
                const derived = theme.themeRootFromLayoutPath(rule.layout_path) orelse return error.InvalidLayout;
                if (!std.mem.eql(u8, derived, theme_root)) return error.InvalidLayout;
                if (pathNest(t.output, rule.layout_path)) return error.OutputConflict;
            }
        } else {
            target.rejectMixedThemeRoots(t.layout orelse "themes/boris/layouts/main.html", t.layout_rules) catch return error.InvalidLayout;
            if (t.layout) |layout_path| if (pathNest(t.output, layout_path)) return error.OutputConflict;
            for (t.layout_rules) |rule| if (pathNest(t.output, rule.layout_path)) return error.OutputConflict;
        }
        if (t.sitemap != null or t.rss != null or t.llms != null) {
            if (!t.public) return error.PublicArtifactRequiresPublicTarget;
            const site = plan.site orelse return error.PublicArtifactRequiresSiteUrl;
            if (t.sitemap != null and site.url == null) return error.PublicArtifactRequiresSiteUrl;
            if (t.rss != null and (site.url == null or site.title == null or site.description == null)) return error.RssRequiresSiteMetadata;
            if (t.sitemap) |a| if (t.rss) |b| if (std.mem.eql(u8, a.path, b.path)) return error.OutputConflict;
            if (t.sitemap) |a| if (t.llms) |b| if (std.mem.eql(u8, a.path, b.path)) return error.OutputConflict;
            if (t.rss) |a| if (t.llms) |b| if (std.mem.eql(u8, a.path, b.path)) return error.OutputConflict;
        }
        if (std.mem.eql(u8, t.output, ".boris-cache") or std.mem.startsWith(u8, t.output, "_boris/")) return error.ReservedOutputRoot;
        if (std.mem.eql(u8, t.output, plan.input) or pathNest(t.output, plan.input)) return error.OutputConflict;
        // Static passthrough (#804) is an input tree: it may not nest with the
        // target output or the content root in either direction.
        if (t.static) |static| {
            if (pathNest(t.output, static.dir) or pathNest(static.dir, t.output)) return error.OutputConflict;
            if (pathNest(plan.input, static.dir) or pathNest(static.dir, plan.input)) return error.OutputConflict;
        }
        for (plan.targets[i + 1 ..]) |other| if (pathNest(t.output, other.output)) return error.OutputConflict;
    }
    if (public_count > 1) return error.MultiplePublicTargets;
    if (plan.publication) |publication| {
        if (public_count != 1) return error.PublicationRequiresPublicTarget;
        if (plan.site) |site| if (site.url) |url| {
            const base_url = switch (publication) {
                .github_pages => |location| location.base_url,
                .standard_site => |config| config.location.base_url,
            };
            if (!std.mem.eql(u8, url, base_url)) return error.PublicationSiteMismatch;
        };
    }
    if (plan.nostr) |nostr_plan| {
        // Every article carries the canonical page URL in its `r`/`i` tags, and
        // that URL must be the one that actually serves the page. Only the
        // publication location establishes it, so a Nostr surface without one
        // is a configuration error rather than a plan with guessed URLs.
        if (nostr_plan.enabled and plan.publication == null) return error.NostrRequiresPublication;
    }
    if (plan.ir) |e| try validateMachineRoot(plan, e.output);
    if (plan.rag) |e| try validateMachineRoot(plan, e.output);
    if (plan.context) |e| try validateMachineRoot(plan, e.output);
    if (plan.ir) |a| if (plan.rag) |b| if (pathNest(a.output, b.output)) return error.OutputConflict;
    if (plan.ir) |a| if (plan.context) |b| if (pathNest(a.output, b.output)) return error.OutputConflict;
    if (plan.rag) |a| if (plan.context) |b| if (pathNest(a.output, b.output)) return error.OutputConflict;
}
fn pathNest(a: []const u8, b: []const u8) bool {
    return target.pathsNestOrEqual(a, b, false);
}
fn validateMachineRoot(plan: *const PublicationPlan, output: []const u8) Error!void {
    if (std.mem.eql(u8, output, ".boris-cache") or std.mem.startsWith(u8, output, "_boris/")) return error.ReservedOutputRoot;
    if (pathNest(output, plan.input)) return error.OutputConflict;
    for (plan.targets) |t| if (pathNest(output, t.output)) return error.OutputConflict;
}

test "minimal markdown profile normalizes and owns canonical targets" {
    const source =
        \\{"format":"boris-publication-profile","schema_version":1,"targets":[{"name":"z","output":"preview","layout":"layouts/main.html"},{"name":"a","output":"dist","theme":"themes/boris"}]}
    ;
    var request = try parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, source, .{});
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(InputFormat.markdown, request.plan.input_format);
    try std.testing.expectEqualStrings("a", request.plan.targets[0].name);
    try std.testing.expectEqualStrings("content", request.plan.input);
}

test "textile profile and explicit overrides preserve plan identity boundary" {
    const source =
        \\{"format":"boris-publication-profile","schema_version":1,"input_format":"textile","targets":[{"name":"public","output":"dist","layout":"layouts/main.html"}]}
    ;
    var request = try parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, source, .{ .html_output = "preview", .jobs = 4, .quiet = true });
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(InputFormat.textile, request.plan.input_format);
    try std.testing.expectEqualStrings("preview", request.plan.targets[0].output);
    try std.testing.expectEqual(@as(usize, 4), request.execution.jobs);
    try std.testing.expect(request.execution.quiet);
}

test "strict parser rejects duplicate unknown malformed and bounded input" {
    const cases = [_]struct { text: []const u8, err: anyerror }{
        .{ .text = "{\"format\":\"boris-publication-profile\",\"format\":\"boris-publication-profile\",\"schema_version\":1,\"editions\":{\"ir\":{\"output\":\".boris\"}}}", .err = error.DuplicateKey },
        .{ .text = "{\"format\":\"boris-publication-profile\",\"schema_version\":1,\"nope\":true,\"editions\":{\"ir\":{\"output\":\".boris\"}}}", .err = error.UnknownKey },
        .{ .text = "{\"format\":\"boris-publication-profile\",\"schema_version\":1", .err = error.InvalidJson },
        .{ .text = "{\"format\":\"wrong\",\"schema_version\":1,\"editions\":{\"ir\":{\"output\":\".boris\"}}}", .err = error.InvalidFormat },
        .{ .text = "{\"schema_version\":1,\"editions\":{\"ir\":{\"output\":\".boris\"}}}", .err = error.MissingField },
        .{ .text = "{\"format\":\"boris-publication-profile\",\"schema_version\":1,\"editions\":{\"ir\":{\"output\":\".boris\",\"output\":\"other\"}}}", .err = error.DuplicateKey },
        .{ .text = "{\"format\":\"boris-publication-profile\",\"schema_version\":1,\"targets\":[{\"name\":\"x\",\"output\":\"dist\",\"layout\":\"layouts/main.html\",\"layuot\":\"nope\"}]}", .err = error.UnknownKey },
    };
    for (cases) |case| try std.testing.expectError(case.err, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, case.text, .{}));
}

test "JSON byte, string, and nesting bounds fail before plan construction" {
    const oversized = try std.testing.allocator.alloc(u8, max_profile_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.ProfileTooLarge, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, oversized, .{}));
    try std.testing.expectError(error.InvalidUtf8, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, &.{0xff}, .{}));
    try std.testing.expectError(error.EmbeddedNul, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, "{\x00}", .{}));

    var at_limit: [max_json_depth * 2]u8 = undefined;
    @memset(at_limit[0..max_json_depth], '{');
    @memset(at_limit[max_json_depth..], '}');
    try checkDepth(&at_limit);
    var past_limit: [max_json_depth * 2 + 1]u8 = undefined;
    @memset(past_limit[0 .. max_json_depth + 1], '{');
    @memset(past_limit[max_json_depth + 1 ..], '}');
    try std.testing.expectError(error.NestingTooDeep, checkDepth(&past_limit));

    var string_limit: std.ArrayList(u8) = .empty;
    defer string_limit.deinit(std.testing.allocator);
    try string_limit.appendSlice(std.testing.allocator, "{\"format\":\"");
    try string_limit.appendNTimes(std.testing.allocator, 'x', max_string_bytes + 1);
    try string_limit.appendSlice(std.testing.allocator, "\",\"schema_version\":1}");
    try std.testing.expectError(error.StringTooLong, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, string_limit.items, .{}));
}

test "static public and output validation is fail closed" {
    const bad_public =
        \\{"format":"boris-publication-profile","schema_version":1,"targets":[{"name":"x","output":"dist","layout":"layouts/main.html","rss":{"path":"rss.xml"}}]}
    ;
    try std.testing.expectError(error.PublicArtifactRequiresPublicTarget, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, bad_public, .{}));
    const overlap =
        \\{"format":"boris-publication-profile","schema_version":1,"input":"content","targets":[{"name":"x","output":"content/site","layout":"layouts/main.html"}]}
    ;
    try std.testing.expectError(error.OutputConflict, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, overlap, .{}));
}

test "GitHub Pages publication metadata is normalized in the owned plan" {
    const source =
        \\{"format":"boris-publication-profile","schema_version":1,"publication":{"target":"github-pages","base_url":"https://owner.github.io/boris/","origin":"https://owner.github.io/","base_path":"/boris/"},"targets":[{"name":"public","output":"dist","public":true,"layout":"layouts/main.html"}]}
    ;
    var request = try parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, source, .{});
    defer request.deinit(std.testing.allocator);
    const location = request.plan.publication.?.github_pages;
    try std.testing.expectEqualStrings("https://owner.github.io/boris", location.base_url);
    try std.testing.expectEqualStrings("/boris", location.base_path);
    try std.testing.expectEqual(github_pages.SiteKind.project_site, location.site_kind);
}

test "GitHub Pages publication metadata fails closed on contradictory inputs" {
    const source =
        \\{"format":"boris-publication-profile","schema_version":1,"publication":{"target":"github-pages","base_url":"https://owner.github.io/boris","origin":"https://other.github.io","base_path":"/boris"},"targets":[{"name":"public","output":"dist","public":true,"layout":"layouts/main.html"}]}
    ;
    try std.testing.expectError(error.InvalidPublication, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, source, .{}));
}

test "GitHub Pages publication requires one public target and matching site URL" {
    const no_public_target =
        \\{"format":"boris-publication-profile","schema_version":1,"publication":{"target":"github-pages","base_url":"https://owner.github.io/boris","origin":"https://owner.github.io","base_path":"/boris"},"targets":[{"name":"preview","output":"dist","layout":"layouts/main.html"}]}
    ;
    try std.testing.expectError(error.PublicationRequiresPublicTarget, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, no_public_target, .{}));

    const mismatched_site =
        \\{"format":"boris-publication-profile","schema_version":1,"site":{"url":"https://owner.github.io/other"},"publication":{"target":"github-pages","base_url":"https://owner.github.io/boris","origin":"https://owner.github.io","base_path":"/boris"},"targets":[{"name":"public","output":"dist","public":true,"layout":"layouts/main.html"}]}
    ;
    try std.testing.expectError(error.PublicationSiteMismatch, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, mismatched_site, .{}));
}

test "profile workspace is selected parent and has no discovery" {
    var workspace = try profileWorkspace(std.testing.allocator, "/tmp", "/work/project/boris.publication.json");
    defer workspace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/work/project", workspace.root);
}

// --- the `nostr` NIP-23 publication surface --------------------------------

const nostr_prefix =
    "{\"format\":\"boris-publication-profile\",\"schema_version\":1," ++
    "\"publication\":{\"target\":\"github-pages\",\"base_url\":\"https://owner.github.io/boris\",\"origin\":\"https://owner.github.io\",\"base_path\":\"/boris\"}," ++
    "\"targets\":[{\"name\":\"public\",\"output\":\"dist\",\"public\":true,\"layout\":\"layouts/main.html\"}],\"nostr\":";

fn parseNostrProfile(section: []const u8) Error!PublicationRequest {
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}}}", .{ nostr_prefix, section });
    defer std.testing.allocator.free(source);
    return parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, source, .{});
}

const valid_pubkey = "\"a695f6b60119d9521934a691347d9f78e8770b56da16bb255ee286ddf9fda919\"";

test "nostr section normalizes selection and relays into the owned plan" {
    var request = try parseNostrProfile(
        "{\"enabled\":true,\"pubkey\":" ++ valid_pubkey ++
            ",\"articles\":[\"guides/z\",\"articles/a\"]," ++
            "\"relays\":[\"wss://relay.example.com/\",\"WSS://A.Relay.Example.com:443\"],\"timeout_ms\":250,\"retries\":2}",
    );
    defer request.deinit(std.testing.allocator);
    const config = request.plan.nostr.?;
    try std.testing.expect(config.enabled);
    // Both lists are canonical, so profile order cannot change the plan bytes.
    try std.testing.expectEqualStrings("articles/a", config.articles[0]);
    try std.testing.expectEqualStrings("guides/z", config.articles[1]);
    try std.testing.expectEqualStrings("wss://a.relay.example.com", config.relays[0]);
    try std.testing.expectEqualStrings("wss://relay.example.com", config.relays[1]);
    try std.testing.expectEqual(@as(usize, 250), config.timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), config.retries);
}

test "nostr section accepts npub and stores hex" {
    var request = try parseNostrProfile(
        "{\"pubkey\":\"npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg\",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"]}",
    );
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e",
        request.plan.nostr.?.pubkey,
    );
}

test "nostr section defaults are bounded and explicit" {
    var request = try parseNostrProfile(
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"]}",
    );
    defer request.deinit(std.testing.allocator);
    const config = request.plan.nostr.?;
    // Disabled unless asked: a profile that merely describes a surface must not
    // become a publication surface by omission.
    try std.testing.expect(!config.enabled);
    try std.testing.expectEqual(nostr.default_timeout_ms, config.timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), config.retries);
}

test "nostr section fails closed on identity, selection, and relay defects" {
    const cases = [_][]const u8{
        // Pubkey grammar: wrong length, uppercase hex, non-hex.
        "{\"pubkey\":\"abc\",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"]}",
        "{\"pubkey\":\"A695F6B60119D9521934A691347D9F78E8770B56DA16BB255EE286DDF9FDA919\",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"]}",
        "{\"pubkey\":\"npub1notreal\",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"]}",
        // Empty selection, duplicate selection, unusable entity id.
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[],\"relays\":[\"wss://r.example.com\"]}",
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\",\"a\"],\"relays\":[\"wss://r.example.com\"]}",
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"/abs\"],\"relays\":[\"wss://r.example.com\"]}",
        // Empty relay list, non-loopback ws://, duplicate after normalization.
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\"],\"relays\":[]}",
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\"],\"relays\":[\"ws://r.example.com\"]}",
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\",\"wss://r.example.com:443/\"]}",
        // Budgets outside the documented bounds.
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"],\"timeout_ms\":1}",
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"],\"retries\":99}",
    };
    for (cases) |section| {
        try std.testing.expectError(error.InvalidNostr, parseNostrProfile(section));
    }
}

test "nostr section requires the closed key set and both required keys" {
    try std.testing.expectError(error.UnknownKey, parseNostrProfile(
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"],\"nsec\":\"x\"}",
    ));
    try std.testing.expectError(error.MissingField, parseNostrProfile(
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"relays\":[\"wss://r.example.com\"]}",
    ));
    try std.testing.expectError(error.MissingField, parseNostrProfile(
        "{\"pubkey\":" ++ valid_pubkey ++ ",\"articles\":[\"a\"]}",
    ));
    try std.testing.expectError(error.MissingField, parseNostrProfile(
        "{\"articles\":[\"a\"],\"relays\":[\"wss://r.example.com\"]}",
    ));
}

test "an enabled nostr surface requires a publication location" {
    // Without a location there is no canonical URL, so `r`/`i` would have to be
    // guessed. Refuse instead.
    const source =
        \\{"format":"boris-publication-profile","schema_version":1,"targets":[{"name":"public","output":"dist","public":true,"layout":"layouts/main.html"}],"nostr":{"enabled":true,"pubkey":"a695f6b60119d9521934a691347d9f78e8770b56da16bb255ee286ddf9fda919","articles":["a"],"relays":["wss://r.example.com"]}}
    ;
    try std.testing.expectError(error.NostrRequiresPublication, parseBytes(std.testing.allocator, .{ .root = try std.testing.allocator.dupe(u8, "/work") }, source, .{}));
}
