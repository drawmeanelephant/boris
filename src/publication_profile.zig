//! Strict, internal schema-v1 publication-profile parsing and static planning.
//!
//! This module deliberately has no CLI or publisher dependency. A future
//! coordinator receives only the owned `PublicationRequest`; JSON parser nodes
//! and argv views stop at `parseBytes` / `applyOverrides`.

const std = @import("std");
const github_pages = @import("github_pages.zig");
const layout_select = @import("layout_select.zig");
const rss = @import("rss.zig");
const sitemap = @import("sitemap.zig");
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
pub const IrPlan = struct { output: []u8 };
pub const RagPlan = struct { output: []u8, scope: ?[]u8 = null, split_size: ?usize = null, bundles_only: bool = false };
pub const ContextPlan = struct { output: []u8, scope: ?[]u8 = null, split_size: ?usize = null };

pub const PublicationTargetPlan = struct {
    location: github_pages.Location,

    fn deinit(self: *PublicationTargetPlan, allocator: std.mem.Allocator) void {
        self.location.deinit(allocator);
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
    try only(root, &.{ "format", "schema_version", "input", "input_format", "site", "publication", "targets", "editions" });
    if (!std.mem.eql(u8, try string(try required(root, "format")), "boris-publication-profile")) return error.InvalidFormat;
    if ((try integer(try required(root, "schema_version"))) != 1) return error.InvalidSchemaVersion;
    var plan = PublicationPlan{ .input = try dup(allocator, if (field(root, "input")) |v| try checkedPath(v) else "content") };
    errdefer plan.deinit(allocator);
    if (field(root, "input_format")) |v| plan.input_format = try parseInputFormat(v);
    if (field(root, "site")) |v| plan.site = try parseSite(allocator, v);
    if (field(root, "publication")) |v| plan.publication = try parsePublication(allocator, v);
    if (field(root, "targets")) |v| plan.targets = try parseTargets(allocator, v);
    if (field(root, "editions")) |v| try parseEditions(allocator, &plan, v);
    return plan;
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
    try only(obj, &.{ "target", "base_url", "origin", "base_path" });
    if (!std.mem.eql(u8, try string(try required(obj, "target")), github_pages.target_name)) return error.InvalidPublication;
    const base_url = try string(try required(obj, "base_url"));
    const origin = try string(try required(obj, "origin"));
    const base_path = try string(try required(obj, "base_path"));
    const location = github_pages.parse(allocator, base_url, origin, base_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidPublication;
    };
    return .{ .location = location };
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
    try only(obj, &.{ "name", "output", "public", "theme", "layout", "layout_rules", "sitemap", "rss", "llms" });
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
        for (plan.targets[i + 1 ..]) |other| if (pathNest(t.output, other.output)) return error.OutputConflict;
    }
    if (public_count > 1) return error.MultiplePublicTargets;
    if (plan.publication) |publication| {
        if (public_count != 1) return error.PublicationRequiresPublicTarget;
        if (plan.site) |site| if (site.url) |url| {
            if (!std.mem.eql(u8, url, publication.location.base_url)) return error.PublicationSiteMismatch;
        };
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
    const location = request.plan.publication.?.location;
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
