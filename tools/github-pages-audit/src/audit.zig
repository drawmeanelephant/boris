//! Bounded, post-deploy observer for a Boris GitHub Pages publication.
//!
//! This module deliberately consumes the normalized publication plan and the
//! target-local artifact inventory as declarations. It never changes those
//! declarations, never turns HTTP into compiler input, and never writes into
//! the public Pages tree.

const std = @import("std");
const Io = std.Io;
const artifacts = @import("artifact_inventory");
const github_pages = @import("github_pages");
const location_policy = @import("location_policy");

pub const evidence_format = "boris-github-pages-deployment-evidence";
pub const evidence_schema_version: usize = 1;

pub const Outcome = enum {
    passed,
    failed,
    incomplete,
    not_applicable,

    pub fn name(self: Outcome) []const u8 {
        return switch (self) {
            .passed => "passed",
            .failed => "failed",
            .incomplete => "incomplete",
            .not_applicable => "not-applicable",
        };
    }
};

pub const Bounds = struct {
    max_requests: usize = 256,
    max_body_bytes: usize = 8 * 1024 * 1024,
    max_redirects: usize = 3,
    timeout_ms: usize = 10_000,
    max_projection_urls: usize = 256,

    pub fn validate(self: Bounds) !void {
        if (self.max_requests == 0 or self.max_requests > 4096) return error.InvalidBounds;
        if (self.max_body_bytes == 0 or self.max_body_bytes > 64 * 1024 * 1024) return error.InvalidBounds;
        if (self.max_redirects > 16) return error.InvalidBounds;
        if (self.timeout_ms == 0 or self.timeout_ms > 120_000) return error.InvalidBounds;
        if (self.max_projection_urls == 0 or self.max_projection_urls > 4096) return error.InvalidBounds;
    }
};

pub const Metadata = struct {
    repository: ?[]const u8 = null,
    source_commit: ?[]const u8 = null,
    workflow_ref: ?[]const u8 = null,
    workflow_sha: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    run_attempt: ?[]const u8 = null,
    deployment_id: ?[]const u8 = null,
    public_artifact_name: ?[]const u8 = null,
    audited_at: []const u8,
};

pub const ProjectionPaths = struct {
    sitemap: ?[]u8 = null,
    rss: ?[]u8 = null,
    llms: ?[]u8 = null,

    fn deinit(self: *ProjectionPaths, gpa: std.mem.Allocator) void {
        if (self.sitemap) |value| gpa.free(value);
        if (self.rss) |value| gpa.free(value);
        if (self.llms) |value| gpa.free(value);
        self.* = undefined;
    }
};

pub const Plan = struct {
    gpa: std.mem.Allocator,
    location: github_pages.Location,
    target: []const u8,
    projections: ProjectionPaths,

    pub fn deinit(self: *Plan) void {
        self.location.deinit(self.gpa);
        self.gpa.free(self.target);
        self.projections.deinit(self.gpa);
        self.* = undefined;
    }
};

pub const Check = struct {
    id: []u8,
    status: Outcome,
    detail: []u8,
};

pub const Redirect = struct {
    status: u16,
    url: []u8,
};

pub const Observation = struct {
    check_id: []u8,
    kind: []u8,
    path: []u8,
    requested_url: []u8,
    final_url: ?[]u8,
    status: ?u16,
    redirects: []Redirect,
    content_type: ?[]u8,
    cache_control: ?[]u8,
    etag: ?[]u8,
    last_modified: ?[]u8,
    content_encoding: ?[]u8,
    content_length: ?u64,
    body_bytes: ?usize,
    observed_sha256: ?[64]u8,
    expected_sha256: ?[64]u8,
    expected_bytes: ?usize,
    transfer_decoded: bool,
    byte_result: Outcome,
    result: Outcome,
    detail: []u8,
};

pub const Report = struct {
    gpa: std.mem.Allocator,
    plan: *const Plan,
    inventory: *const artifacts.Inventory,
    plan_sha256: [64]u8,
    inventory_sha256: [64]u8,
    page_url: []u8,
    normalized_page_url: []u8,
    metadata: Metadata,
    bounds: Bounds,
    requests: usize = 0,
    completed_requests: usize = 0,
    truncated: bool = false,
    result: Outcome = .passed,
    checks: std.ArrayList(Check) = .empty,
    observations: std.ArrayList(Observation) = .empty,
    limitations: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Report) void {
        for (self.checks.items) |check| {
            self.gpa.free(check.id);
            self.gpa.free(check.detail);
        }
        self.checks.deinit(self.gpa);
        for (self.observations.items) |observation| {
            self.gpa.free(observation.check_id);
            self.gpa.free(observation.kind);
            self.gpa.free(observation.path);
            self.gpa.free(observation.requested_url);
            if (observation.final_url) |value| self.gpa.free(value);
            for (observation.redirects) |redirect| self.gpa.free(redirect.url);
            self.gpa.free(observation.redirects);
            if (observation.content_type) |value| self.gpa.free(value);
            if (observation.cache_control) |value| self.gpa.free(value);
            if (observation.etag) |value| self.gpa.free(value);
            if (observation.last_modified) |value| self.gpa.free(value);
            if (observation.content_encoding) |value| self.gpa.free(value);
            self.gpa.free(observation.detail);
        }
        self.observations.deinit(self.gpa);
        for (self.limitations.items) |limitation| self.gpa.free(limitation);
        self.limitations.deinit(self.gpa);
        self.gpa.free(self.page_url);
        self.gpa.free(self.normalized_page_url);
        self.* = undefined;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidPlan,
    InvalidInventory,
    InvalidPageUrl,
    InvalidBounds,
    InvalidUrl,
    UnsafeRedirect,
    RequestLimitExceeded,
    ResponseTooLarge,
    UnsupportedResponse,
    WriteFailed,
};

fn valueString(object: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const value = object.get(key) orelse return error.InvalidPlan;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidPlan,
    };
}

fn optionalObjectString(
    gpa: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) Error!?[]u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try gpa.dupe(u8, text),
        else => error.InvalidPlan,
    };
}

fn requiredBool(object: std.json.ObjectMap, key: []const u8) Error!bool {
    const value = object.get(key) orelse return error.InvalidPlan;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidPlan,
    };
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) Error!i64 {
    const value = object.get(key) orelse return error.InvalidPlan;
    return switch (value) {
        .integer => |number| number,
        else => error.InvalidPlan,
    };
}

fn projectionPath(
    gpa: std.mem.Allocator,
    projections: std.json.ObjectMap,
    name: []const u8,
) Error!?[]u8 {
    const value = projections.get(name) orelse return error.InvalidPlan;
    return switch (value) {
        .null => null,
        .object => |object| try optionalObjectString(gpa, object, "path"),
        else => error.InvalidPlan,
    };
}

/// Parse only the normalized declaration facts needed by the observer. The
/// full publication-plan producer remains authoritative for plan semantics.
pub fn parsePlan(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    expected_target: []const u8,
) Error!Plan {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidPlan;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidPlan,
    };
    if (!std.mem.eql(u8, try valueString(root, "format"), "boris-publication-plan")) return error.InvalidPlan;
    if (try requiredInteger(root, "schema_version") != 1) return error.InvalidPlan;

    const publication_value = root.get("publication") orelse return error.InvalidPlan;
    const publication = switch (publication_value) {
        .object => |object| object,
        else => return error.InvalidPlan,
    };
    if (!std.mem.eql(u8, try valueString(publication, "target"), "github-pages")) return error.InvalidPlan;
    const base_url = try valueString(publication, "base_url");
    const origin = try valueString(publication, "origin");
    const base_path = try valueString(publication, "base_path");
    var location = github_pages.parse(gpa, base_url, origin, base_path) catch return error.InvalidPlan;
    errdefer location.deinit(gpa);

    const targets_value = root.get("targets") orelse return error.InvalidPlan;
    const targets = switch (targets_value) {
        .array => |array| array.items,
        else => return error.InvalidPlan,
    };
    var target_name: ?[]u8 = null;
    var projections = ProjectionPaths{};
    errdefer {
        if (target_name) |name| gpa.free(name);
        projections.deinit(gpa);
    }

    for (targets) |target_value| {
        const target_object = switch (target_value) {
            .object => |object| object,
            else => return error.InvalidPlan,
        };
        const name = try valueString(target_object, "name");
        if (!std.mem.eql(u8, name, expected_target)) continue;
        if (!(try requiredBool(target_object, "public"))) return error.InvalidPlan;
        const projection_value = target_object.get("projections") orelse return error.InvalidPlan;
        const projection_object = switch (projection_value) {
            .object => |object| object,
            else => return error.InvalidPlan,
        };
        if (!(switch (projection_object.get("html") orelse return error.InvalidPlan) {
            .bool => |flag| flag,
            else => return error.InvalidPlan,
        })) return error.InvalidPlan;
        projections.sitemap = try projectionPath(gpa, projection_object, "sitemap");
        projections.rss = try projectionPath(gpa, projection_object, "rss");
        projections.llms = try projectionPath(gpa, projection_object, "llms");
        target_name = try gpa.dupe(u8, name);
        break;
    }
    if (target_name == null) return error.InvalidPlan;

    return .{
        .gpa = gpa,
        .location = location,
        .target = target_name.?,
        .projections = projections,
    };
}

pub fn parseInventory(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    expected_target: []const u8,
) Error!artifacts.Inventory {
    var reader = Io.Reader.fixed(bytes);
    return artifacts.parseStream(gpa, &reader, expected_target) catch return error.InvalidInventory;
}

fn hashHex(bytes: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeJsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try buf.append(gpa, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (byte < 0x20) {
                    var escape: [6]u8 = undefined;
                    try buf.appendSlice(gpa, std.fmt.bufPrint(&escape, "\\u{x:0>4}", .{byte}) catch unreachable);
                } else try buf.append(gpa, byte);
            },
        }
    }
    try buf.append(gpa, '"');
}

fn writeJsonNull(buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try buf.appendSlice(gpa, "null");
}

fn writeJsonBool(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: bool) !void {
    try buf.appendSlice(gpa, if (value) "true" else "false");
}

fn writeJsonUsize(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: usize) !void {
    var number: [32]u8 = undefined;
    try buf.appendSlice(gpa, std.fmt.bufPrint(&number, "{d}", .{value}) catch unreachable);
}

fn sameText(left: ?[]const u8, right: []const u8) bool {
    return if (left) |value| std.mem.eql(u8, value, right) else false;
}

fn outcomeMerge(current: *Outcome, next: Outcome) void {
    if (next == .failed or current.* == .failed) {
        current.* = .failed;
    } else if (next == .incomplete or current.* == .incomplete) {
        current.* = .incomplete;
    } else if (next == .passed or current.* == .passed) {
        current.* = .passed;
    } else {
        current.* = .not_applicable;
    }
}

fn appendLimited(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    value: []const u8,
    max: usize,
) !bool {
    if (list.items.len + value.len > max) return false;
    try list.appendSlice(gpa, value);
    return true;
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

fn isHttpUrl(value: []const u8) bool {
    return (value.len >= 7 and std.ascii.eqlIgnoreCase(value[0..7], "http://")) or
        (value.len >= 8 and std.ascii.eqlIgnoreCase(value[0..8], "https://"));
}

fn routePath(route: []const u8) []const u8 {
    var end = route.len;
    if (std.mem.indexOfScalar(u8, route, '?')) |index| end = @min(end, index);
    if (std.mem.indexOfScalar(u8, route, '#')) |index| end = @min(end, index);
    return route[0..end];
}

fn expectedRouteForPath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "index.html")) return gpa.dupe(u8, "/");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '/');
    try out.appendSlice(gpa, path);
    return out.toOwnedSlice(gpa);
}

fn pathUrl(gpa: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    try out.writer.writeAll(base_url);
    try out.writer.writeByte('/');
    const component = std.Uri.Component{ .raw = path };
    try component.formatPath(&out.writer);
    return out.toOwnedSlice();
}

fn copyOptional(gpa: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try gpa.dupe(u8, text) else null;
}

fn copyDigest(gpa: std.mem.Allocator, value: [64]u8) ![64]u8 {
    _ = gpa;
    return value;
}

fn getRecord(inventory: *const artifacts.Inventory, path: []const u8) ?artifacts.Record {
    for (inventory.records) |record| {
        if (record.status == .committed and std.mem.eql(u8, record.path, path)) return record;
    }
    return null;
}

fn kindCheckId(kind: artifacts.Kind) []const u8 {
    return switch (kind) {
        .html_page => "html-reachability",
        .theme_asset, .content_asset => "asset-reachability",
        .rendered_search => "rendered-search",
        .sitemap => "sitemap",
        .rss => "rss",
        .llms => "llms",
    };
}

fn findCheck(checks: []Check, id: []const u8) ?*Check {
    for (checks) |*check| if (std.mem.eql(u8, check.id, id)) return check;
    return null;
}

fn updateCheck(checks: []Check, id: []const u8, result: Outcome, detail: []const u8, gpa: std.mem.Allocator) !void {
    const check = findCheck(checks, id) orelse return error.InvalidPlan;
    outcomeMerge(&check.status, result);
    if (detail.len != 0 and std.mem.eql(u8, check.detail, "")) {
        gpa.free(check.detail);
        check.detail = try gpa.dupe(u8, detail);
    }
}

fn initialChecks(gpa: std.mem.Allocator) !std.ArrayList(Check) {
    var checks: std.ArrayList(Check) = .empty;
    errdefer {
        for (checks.items) |check| {
            gpa.free(check.id);
            gpa.free(check.detail);
        }
        checks.deinit(gpa);
    }
    for ([_][]const u8{
        "deployment-location",
        "html-reachability",
        "asset-reachability",
        "projection-metadata",
        "sitemap",
        "rendered-search",
        "rss",
        "llms",
        "byte-identity",
    }) |id| {
        try checks.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .status = .not_applicable,
            .detail = try gpa.dupe(u8, ""),
        });
    }
    return checks;
}

fn validatePageUrl(gpa: std.mem.Allocator, plan: *const Plan, raw: []const u8) Error!struct { raw: []u8, normalized: []u8 } {
    const uri = std.Uri.parse(raw) catch return error.InvalidPageUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidPageUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidPageUrl;
    const normalized_slice = trimTrailingSlash(raw);
    if (normalized_slice.len == 0) return error.InvalidPageUrl;
    const normalized = try gpa.dupe(u8, normalized_slice);
    errdefer gpa.free(normalized);
    location_policy.validateSiteUrl(gpa, &plan.location, normalized) catch return error.InvalidPageUrl;
    return .{
        .raw = try gpa.dupe(u8, raw),
        .normalized = normalized,
    };
}

pub fn allowedRedirect(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    candidate: []const u8,
) bool {
    const uri = std.Uri.parse(candidate) catch return false;
    if (uri.user != null or uri.password != null or uri.fragment != null) return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    const classified = location_policy.classify(gpa, &plan.location, candidate, true) catch return false;
    switch (classified) {
        .publication => |route| gpa.free(route),
        else => return false,
    }
    return true;
}

fn resolveRedirect(gpa: std.mem.Allocator, current: []const u8, location: []const u8) ![]u8 {
    if (location.len > 8192) return error.UnsafeRedirect;
    var buffer = try gpa.alloc(u8, 16 * 1024);
    defer gpa.free(buffer);
    const copied = buffer[0..location.len];
    @memcpy(copied, location);
    // `resolveInPlace` reads `location.len` bytes from this slice, so it must
    // view the copied bytes — pointing it past them fed it uninitialized
    // memory and made the first observed redirect resolve to a garbage URL
    // (#441).
    var remaining = buffer[0..location.len];
    const base = std.Uri.parse(current) catch return error.UnsafeRedirect;
    const resolved = std.Uri.resolveInPlace(base, location.len, &remaining) catch return error.UnsafeRedirect;
    var out = std.Io.Writer.Allocating.init(gpa);
    std.Uri.format(&resolved, &out.writer) catch return error.UnsafeRedirect;
    return out.toOwnedSlice();
}

fn htmlAttribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < tag.len) {
        const at = std.ascii.indexOfIgnoreCasePos(tag, cursor, name) orelse return null;
        if (at > 0 and (std.ascii.isAlphanumeric(tag[at - 1]) or tag[at - 1] == '-' or tag[at - 1] == '_')) {
            cursor = at + name.len;
            continue;
        }
        var after = at + name.len;
        while (after < tag.len and (tag[after] == ' ' or tag[after] == '\t' or tag[after] == '\n' or tag[after] == '\r')) : (after += 1) {}
        if (after >= tag.len or tag[after] != '=') {
            cursor = after;
            continue;
        }
        after += 1;
        while (after < tag.len and (tag[after] == ' ' or tag[after] == '\t' or tag[after] == '\n' or tag[after] == '\r')) : (after += 1) {}
        if (after >= tag.len) return null;
        const quote = tag[after];
        if (quote != '"' and quote != '\'') return null;
        const start = after + 1;
        const end = std.mem.indexOfScalarPos(u8, tag, start, quote) orelse return null;
        return tag[start..end];
    }
    return null;
}

fn tagHasToken(tag: []const u8, name: []const u8, value: []const u8) bool {
    const raw = htmlAttribute(tag, name) orelse return false;
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (it.next()) |token| if (std.ascii.eqlIgnoreCase(token, value)) return true;
    return false;
}

fn inspectHtml(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    path: []const u8,
    body: []const u8,
    max_urls: usize,
) struct { metadata: Outcome, links: Outcome, detail: []const u8 } {
    var metadata: Outcome = .not_applicable;
    var links: Outcome = .passed;
    var found_metadata = false;
    var metadata_bad = false;
    var metadata_truncated = false;
    var cursor: usize = 0;
    var inspected: usize = 0;
    while (cursor < body.len and inspected < max_urls) {
        const start = std.mem.indexOfScalarPos(u8, body, cursor, '<') orelse break;
        const end = std.mem.indexOfScalarPos(u8, body, start + 1, '>') orelse break;
        const tag = body[start .. end + 1];
        if (std.ascii.indexOfIgnoreCase(tag, "<link") != null and tagHasToken(tag, "rel", "canonical")) {
            found_metadata = true;
            const href = htmlAttribute(tag, "href") orelse {
                metadata_bad = true;
                cursor = end + 1;
                continue;
            };
            const classified = location_policy.classify(gpa, &plan.location, href, true) catch {
                metadata_bad = true;
                cursor = end + 1;
                continue;
            };
            switch (classified) {
                .publication => |route| {
                    const expected = expectedRouteForPath(gpa, path) catch {
                        metadata_bad = true;
                        gpa.free(route);
                        cursor = end + 1;
                        continue;
                    };
                    defer gpa.free(expected);
                    if (!std.mem.eql(u8, routePath(route), expected) and
                        !(std.mem.eql(u8, path, "index.html") and std.mem.eql(u8, routePath(route), "/index.html"))) metadata_bad = true;
                    gpa.free(route);
                },
                else => metadata_bad = true,
            }
        }
        if (std.ascii.indexOfIgnoreCase(tag, "<meta") != null) {
            const property = htmlAttribute(tag, "property") orelse htmlAttribute(tag, "name") orelse "";
            if (std.ascii.eqlIgnoreCase(property, "og:url") or std.ascii.eqlIgnoreCase(property, "twitter:url")) {
                found_metadata = true;
                const content = htmlAttribute(tag, "content") orelse {
                    metadata_bad = true;
                    cursor = end + 1;
                    continue;
                };
                if (!allowedRedirect(gpa, plan, content)) metadata_bad = true;
            }
        }

        const href = htmlAttribute(tag, "href") orelse htmlAttribute(tag, "src");
        if (href) |raw| {
            inspected += 1;
            if (raw.len > 0 and raw[0] != '#' and raw[0] != '?' and
                (raw[0] == '/' or isHttpUrl(raw)))
            {
                _ = location_policy.classify(gpa, &plan.location, raw, false) catch {
                    links = .failed;
                };
            }
        }
        cursor = end + 1;
    }
    if (inspected >= max_urls and cursor < body.len) {
        links = .incomplete;
        metadata_truncated = true;
    }
    if (found_metadata) {
        metadata = if (metadata_bad) .failed else if (metadata_truncated) .incomplete else .passed;
    } else if (metadata_truncated) {
        metadata = .incomplete;
    }
    return .{
        .metadata = metadata,
        .links = links,
        .detail = if (metadata_bad) "canonical or public metadata is outside the declared publication location" else if (links == .failed) "same-origin HTML URL escapes the declared publication location" else if (metadata_truncated) "HTML URL and metadata inspection reached max_projection_urls" else "",
    };
}

const ProjectionSample = struct {
    path: []u8,
    url: []u8,
};

const ProjectionScan = struct {
    result: Outcome = .passed,
    samples: std.ArrayList(ProjectionSample) = .empty,
    detail: []const u8 = "",

    fn deinit(self: *ProjectionScan, gpa: std.mem.Allocator) void {
        for (self.samples.items) |sample| {
            gpa.free(sample.path);
            gpa.free(sample.url);
        }
        self.samples.deinit(gpa);
    }
};

fn appendProjectionSample(
    gpa: std.mem.Allocator,
    scan: *ProjectionScan,
    path: []const u8,
    url: []const u8,
) !void {
    try scan.samples.append(gpa, .{
        .path = try gpa.dupe(u8, path),
        .url = try gpa.dupe(u8, url),
    });
}

fn scanSitemap(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    body: []const u8,
    max_urls: usize,
) !ProjectionScan {
    var scan = ProjectionScan{};
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < body.len and count < max_urls) {
        const start = std.ascii.indexOfIgnoreCasePos(body, cursor, "<loc") orelse break;
        const open_end = std.mem.indexOfScalarPos(u8, body, start, '>') orelse {
            scan.result = .failed;
            scan.detail = "sitemap contains an unterminated loc element";
            return scan;
        };
        const end = std.ascii.indexOfIgnoreCasePos(body, open_end + 1, "</loc>") orelse {
            scan.result = .failed;
            scan.detail = "sitemap contains an unterminated loc element";
            return scan;
        };
        const raw = std.mem.trim(u8, body[open_end + 1 .. end], " \t\r\n");
        if (raw.len == 0 or !allowedRedirect(gpa, plan, raw)) {
            scan.result = .failed;
            scan.detail = "sitemap URLs were not all inside the declared location";
            return scan;
        }
        try appendProjectionSample(gpa, &scan, raw, raw);
        count += 1;
        cursor = end + 6;
    }
    if (count == 0) {
        scan.result = .failed;
        scan.detail = "sitemap did not contain a bounded loc sample";
    } else if (cursor < body.len and std.ascii.indexOfIgnoreCasePos(body, cursor, "<loc") != null) {
        scan.result = .incomplete;
        scan.detail = "sitemap URL sampling reached max_projection_urls";
    }
    return scan;
}

fn scanSearch(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    body: []const u8,
    max_urls: usize,
) !ProjectionScan {
    var scan = ProjectionScan{};
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch {
        scan.result = .failed;
        scan.detail = "rendered-search was not valid JSON";
        return scan;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            scan.result = .failed;
            scan.detail = "rendered-search root was not an object";
            return scan;
        },
    };
    const format = root.get("format") orelse {
        scan.result = .failed;
        scan.detail = "rendered-search format was missing or invalid";
        return scan;
    };
    if (format != .string or !std.mem.eql(u8, format.string, "boris-rendered-search-index")) {
        scan.result = .failed;
        scan.detail = "rendered-search format was missing or invalid";
        return scan;
    }
    const version = root.get("schema_version") orelse {
        scan.result = .failed;
        scan.detail = "rendered-search schema version was missing or invalid";
        return scan;
    };
    if (version != .integer or version.integer != 1) {
        scan.result = .failed;
        scan.detail = "rendered-search schema version was missing or invalid";
        return scan;
    }
    const documents = root.get("documents") orelse {
        scan.result = .failed;
        scan.detail = "rendered-search documents were missing or invalid";
        return scan;
    };
    const items = switch (documents) {
        .array => |array| array.items,
        else => {
            scan.result = .failed;
            scan.detail = "rendered-search documents were missing or invalid";
            return scan;
        },
    };
    const count = @min(items.len, max_urls);
    for (items[0..count]) |document| {
        const object = switch (document) {
            .object => |value| value,
            else => {
                scan.result = .failed;
                scan.detail = "rendered-search contains a malformed document";
                return scan;
            },
        };
        const path = object.get("path") orelse {
            scan.result = .failed;
            scan.detail = "rendered-search contains a document without a path";
            return scan;
        };
        if (path != .string or !artifacts.validateRelativePath(path.string) or !std.mem.endsWith(u8, path.string, ".html")) {
            scan.result = .failed;
            scan.detail = "rendered-search contains an unsafe or non-HTML path";
            return scan;
        }
        const url = try pathUrl(gpa, plan.location.base_url, path.string);
        defer gpa.free(url);
        try appendProjectionSample(gpa, &scan, path.string, url);
    }
    if (items.len > max_urls) {
        scan.result = .incomplete;
        scan.detail = "rendered-search sampling reached max_projection_urls";
    }
    return scan;
}

fn scanLlms(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    body: []const u8,
    max_urls: usize,
) !ProjectionScan {
    var scan = ProjectionScan{};
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < body.len and count < max_urls) {
        const open = std.mem.indexOfScalarPos(u8, body, cursor, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, body, open + 1, ')') orelse {
            scan.result = .failed;
            scan.detail = "llms.txt contains an unterminated link";
            return scan;
        };
        const raw = std.mem.trim(u8, body[open + 1 .. close], " \t\r\n");
        if (raw.len != 0 and isHttpUrl(raw)) {
            if (!allowedRedirect(gpa, plan, raw)) {
                scan.result = .failed;
                scan.detail = "llms.txt contains a URL outside the declared location";
                return scan;
            }
            try appendProjectionSample(gpa, &scan, raw, raw);
            count += 1;
        }
        cursor = close + 1;
    }
    if (cursor < body.len and count >= max_urls) {
        scan.result = .incomplete;
        scan.detail = "llms.txt URL sampling reached max_projection_urls";
    } else if (count == 0) {
        scan.result = .not_applicable;
        scan.detail = "llms.txt declared no absolute hosted URLs";
    }
    return scan;
}

fn scanRss(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    body: []const u8,
    max_urls: usize,
) !ProjectionScan {
    var scan = ProjectionScan{};
    if (std.ascii.indexOfIgnoreCase(body, "<rss") == null or std.ascii.indexOfIgnoreCase(body, "<channel") == null) {
        scan.result = .failed;
        scan.detail = "RSS root or channel was missing";
        return scan;
    }
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < body.len and count < max_urls) {
        const start = std.ascii.indexOfIgnoreCasePos(body, cursor, "<link") orelse break;
        const end = std.mem.indexOfScalarPos(u8, body, start, '>') orelse {
            scan.result = .failed;
            scan.detail = "RSS contains an unterminated link element";
            return scan;
        };
        const close = std.ascii.indexOfIgnoreCasePos(body, end + 1, "</link>") orelse {
            scan.result = .failed;
            scan.detail = "RSS contains an unterminated link element";
            return scan;
        };
        const raw = std.mem.trim(u8, body[end + 1 .. close], " \t\r\n");
        if (raw.len != 0) {
            if (!allowedRedirect(gpa, plan, raw)) {
                scan.result = .failed;
                scan.detail = "RSS links were not all inside the declared location";
                return scan;
            }
            try appendProjectionSample(gpa, &scan, raw, raw);
            count += 1;
        }
        cursor = close + 7;
    }
    if (count == 0) {
        scan.result = .failed;
        scan.detail = "RSS did not contain a bounded public-link sample";
    } else if (cursor < body.len and count >= max_urls) {
        scan.result = .incomplete;
        scan.detail = "RSS URL sampling reached max_projection_urls";
    }
    return scan;
}

fn scanProjection(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    record: artifacts.Record,
    body: []const u8,
    bounds: Bounds,
) !ProjectionScan {
    return switch (record.kind) {
        .sitemap => scanSitemap(gpa, plan, body, bounds.max_projection_urls),
        .rendered_search => scanSearch(gpa, plan, body, bounds.max_projection_urls),
        .rss => scanRss(gpa, plan, body, bounds.max_projection_urls),
        .llms => scanLlms(gpa, plan, body, bounds.max_projection_urls),
        else => ProjectionScan{ .result = .not_applicable },
    };
}

const HeaderSet = struct {
    content_type: ?[]u8 = null,
    cache_control: ?[]u8 = null,
    etag: ?[]u8 = null,
    last_modified: ?[]u8 = null,
};

const SingleResponse = struct {
    status: u16,
    location: ?[]u8,
    headers: HeaderSet,
    content_encoding: std.http.ContentEncoding,
    content_length: ?u64,
    body: []u8,
    body_too_large: bool,
};

const FetchResult = struct {
    response: SingleResponse,
    final_url: []u8,
    redirects: []Redirect,
    policy_error: ?[]const u8 = null,
};

fn headerCopy(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8) !?[]u8 {
    var iterator = std.http.HeaderIterator.init(bytes);
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return try gpa.dupe(u8, header.value);
    }
    return null;
}

fn fetchSingle(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    raw_url: []const u8,
    bounds: Bounds,
) !SingleResponse {
    const uri = std.Uri.parse(raw_url) catch return error.InvalidUrl;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUrl;
    var request = try client.request(.GET, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = "boris-github-pages-audit/1" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer request.deinit();

    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    const status = @intFromEnum(response.head.status);
    const content_encoding = response.head.content_encoding;
    const content_length = response.head.content_length;
    const location = try copyOptional(gpa, response.head.location);
    const headers = HeaderSet{
        .content_type = try headerCopy(gpa, response.head.bytes, "content-type"),
        .cache_control = try headerCopy(gpa, response.head.bytes, "cache-control"),
        .etag = try headerCopy(gpa, response.head.bytes, "etag"),
        .last_modified = try headerCopy(gpa, response.head.bytes, "last-modified"),
    };
    var decompress_buffer: []u8 = &.{};
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    if (content_encoding.minBufferCapacity() != 0) {
        decompress_buffer = try gpa.alloc(u8, content_encoding.minBufferCapacity());
    }
    var transfer_buffer: [64]u8 = undefined;
    var decompressor: std.http.Decompress = undefined;
    var body_reader = response.readerDecompressing(
        &transfer_buffer,
        &decompressor,
        decompress_buffer,
    );
    const body = body_reader.allocRemaining(gpa, Io.Limit.limited(bounds.max_body_bytes)) catch |err| switch (err) {
        error.StreamTooLong => {
            // The connection is deliberately discarded. The next response
            // byte is not consumed, so deinit must not drain an unbounded
            // body while trying to reuse the socket.
            request.reader.state = .closing;
            return .{
                .status = status,
                .location = location,
                .headers = headers,
                .content_encoding = content_encoding,
                .content_length = content_length,
                .body = &.{},
                .body_too_large = true,
            };
        },
        else => return err,
    };
    return .{
        .status = status,
        .location = location,
        .headers = headers,
        .content_encoding = content_encoding,
        .content_length = content_length,
        .body = body,
        .body_too_large = false,
    };
}

fn sleepUntilTimeout(io: Io, timeout: Io.Timeout) Io.Cancelable!void {
    return timeout.sleep(io);
}

/// Bound the complete transport operation, including a peer that accepts a
/// connection and then stalls. The caller's arena owns any response
/// allocations left by a canceled task.
fn fetchSingleWithTimeout(
    gpa: std.mem.Allocator,
    io: Io,
    client: *std.http.Client,
    raw_url: []const u8,
    bounds: Bounds,
) !SingleResponse {
    const Task = union(enum) {
        response: anyerror!SingleResponse,
        timeout: anyerror!void,
    };
    var queue_buffer: [2]Task = undefined;
    var select = Io.Select(Task).init(io, &queue_buffer);
    select.async(.response, fetchSingle, .{ gpa, client, raw_url, bounds });
    select.async(.timeout, sleepUntilTimeout, .{
        io,
        Io.Timeout{ .duration = .{
            .raw = Io.Duration.fromMilliseconds(@intCast(bounds.timeout_ms)),
            .clock = .awake,
        } },
    });
    const selected = select.await() catch return error.Timeout;
    return switch (selected) {
        .response => |response| {
            select.cancelDiscard();
            return response catch |err| return err;
        },
        .timeout => {
            while (select.cancel()) |_| {}
            return error.Timeout;
        },
    };
}

fn fetchUrl(
    gpa: std.mem.Allocator,
    io: Io,
    plan: *const Plan,
    raw_url: []const u8,
    bounds: Bounds,
    request_count: *usize,
) !FetchResult {
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    var current = try gpa.dupe(u8, raw_url);
    var redirects: std.ArrayList(Redirect) = .empty;

    while (true) {
        if (request_count.* >= bounds.max_requests) return error.RequestLimitExceeded;
        request_count.* += 1;
        const response = try fetchSingleWithTimeout(gpa, io, &client, current, bounds);
        if (response.status < 300 or response.status >= 400) {
            return .{
                .response = response,
                .final_url = current,
                .redirects = try redirects.toOwnedSlice(gpa),
            };
        }
        const raw_location = response.location orelse {
            return .{
                .response = response,
                .final_url = current,
                .redirects = try redirects.toOwnedSlice(gpa),
                .policy_error = "redirect response did not provide a Location header",
            };
        };
        if (response.body_too_large) {
            return .{
                .response = response,
                .final_url = current,
                .redirects = try redirects.toOwnedSlice(gpa),
                .policy_error = "redirect response exceeded the bounded body size",
            };
        }
        if (redirects.items.len >= bounds.max_redirects) {
            return .{
                .response = response,
                .final_url = current,
                .redirects = try redirects.toOwnedSlice(gpa),
                .policy_error = "redirect limit exceeded",
            };
        }
        const candidate = try resolveRedirect(gpa, current, raw_location);
        if (!allowedRedirect(gpa, plan, candidate)) {
            return .{
                .response = response,
                .final_url = current,
                .redirects = try redirects.toOwnedSlice(gpa),
                .policy_error = "redirect leaves the declared deployment location",
            };
        }
        try redirects.append(gpa, .{ .status = response.status, .url = candidate });
        current = candidate;
    }
}

fn appendCheckFailure(gpa: std.mem.Allocator, report: *Report, id: []const u8, result: Outcome, detail: []const u8) !void {
    try updateCheck(report.checks.items, id, result, detail, gpa);
    outcomeMerge(&report.result, result);
}

fn observationResult(response: *const SingleResponse, expected: ?artifacts.Record, policy_error: ?[]const u8) struct { byte: Outcome, result: Outcome } {
    if (expected == null) {
        if (policy_error != null or response.status != 200) return .{ .byte = .not_applicable, .result = .failed };
        if (response.body_too_large) return .{ .byte = .not_applicable, .result = .incomplete };
        return .{ .byte = .not_applicable, .result = .passed };
    }
    if (policy_error != null) return .{ .byte = .failed, .result = .failed };
    if (response.body_too_large) return .{ .byte = .incomplete, .result = .incomplete };
    if (response.status != 200) return .{ .byte = .failed, .result = .failed };
    const record = expected.?;
    const observed = hashHex(response.body);
    if (response.body.len != record.bytes or !std.mem.eql(u8, &observed, &record.sha256)) {
        return .{ .byte = .failed, .result = .failed };
    }
    return .{ .byte = .passed, .result = .passed };
}

fn appendObservation(
    gpa: std.mem.Allocator,
    report: *Report,
    check_id: []const u8,
    kind: []const u8,
    path: []const u8,
    requested_url: []const u8,
    expected: ?artifacts.Record,
    fetched: *const FetchResult,
) !*Observation {
    const result = observationResult(&fetched.response, expected, fetched.policy_error);
    const detail: []u8 = if (fetched.policy_error) |message|
        try gpa.dupe(u8, message)
    else if (fetched.response.body_too_large)
        try gpa.dupe(u8, "response body exceeded max_body_bytes")
    else if (fetched.response.status != 200)
        try std.fmt.allocPrint(gpa, "HTTP status {d}", .{fetched.response.status})
    else if (result.byte == .failed)
        try gpa.dupe(u8, "deployed body did not match the committed inventory digest and byte count")
    else
        try gpa.dupe(u8, "");
    errdefer gpa.free(detail);

    var redirects = try gpa.alloc(Redirect, fetched.redirects.len);
    errdefer {
        for (redirects) |redirect| gpa.free(redirect.url);
        gpa.free(redirects);
    }
    for (fetched.redirects, 0..) |redirect, index| {
        redirects[index] = .{ .status = redirect.status, .url = try gpa.dupe(u8, redirect.url) };
    }
    const observed = if (fetched.response.body_too_large) null else hashHex(fetched.response.body);
    const observation = Observation{
        .check_id = try gpa.dupe(u8, check_id),
        .kind = try gpa.dupe(u8, kind),
        .path = try gpa.dupe(u8, path),
        .requested_url = try gpa.dupe(u8, requested_url),
        .final_url = try gpa.dupe(u8, fetched.final_url),
        .status = fetched.response.status,
        .redirects = redirects,
        .content_type = try copyOptional(gpa, fetched.response.headers.content_type),
        .cache_control = try copyOptional(gpa, fetched.response.headers.cache_control),
        .etag = try copyOptional(gpa, fetched.response.headers.etag),
        .last_modified = try copyOptional(gpa, fetched.response.headers.last_modified),
        .content_encoding = try gpa.dupe(u8, @tagName(fetched.response.content_encoding)),
        .content_length = fetched.response.content_length,
        .body_bytes = if (fetched.response.body_too_large) null else fetched.response.body.len,
        .observed_sha256 = observed,
        .expected_sha256 = if (expected) |record| try copyDigest(gpa, record.sha256) else null,
        .expected_bytes = if (expected) |record| record.bytes else null,
        .transfer_decoded = fetched.response.content_encoding != .identity,
        .byte_result = result.byte,
        .result = result.result,
        .detail = detail,
    };
    try report.observations.append(gpa, observation);
    return &report.observations.items[report.observations.items.len - 1];
}

fn appendUnavailableObservation(
    gpa: std.mem.Allocator,
    report: *Report,
    check_id: []const u8,
    kind: []const u8,
    path: []const u8,
    requested_url: []const u8,
    expected: ?artifacts.Record,
    detail: []const u8,
) !void {
    const redirects = try gpa.alloc(Redirect, 0);
    try report.observations.append(gpa, .{
        .check_id = try gpa.dupe(u8, check_id),
        .kind = try gpa.dupe(u8, kind),
        .path = try gpa.dupe(u8, path),
        .requested_url = try gpa.dupe(u8, requested_url),
        .final_url = null,
        .status = null,
        .redirects = redirects,
        .content_type = null,
        .cache_control = null,
        .etag = null,
        .last_modified = null,
        .content_encoding = null,
        .content_length = null,
        .body_bytes = null,
        .observed_sha256 = null,
        .expected_sha256 = if (expected) |record| try copyDigest(gpa, record.sha256) else null,
        .expected_bytes = if (expected) |record| record.bytes else null,
        .transfer_decoded = false,
        .byte_result = if (expected == null) .not_applicable else .incomplete,
        .result = .incomplete,
        .detail = try gpa.dupe(u8, detail),
    });
    try appendCheckFailure(gpa, report, check_id, .incomplete, detail);
}

fn processFetched(
    gpa: std.mem.Allocator,
    scratch_gpa: std.mem.Allocator,
    report: *Report,
    plan: *const Plan,
    path: []const u8,
    kind: []const u8,
    requested_url: []const u8,
    check_id_override: ?[]const u8,
    expected: ?artifacts.Record,
    fetched: *const FetchResult,
    bounds: Bounds,
) !?ProjectionScan {
    report.completed_requests += 1;
    const check_id = check_id_override orelse if (expected) |record| kindCheckId(record.kind) else "html-reachability";
    const observation = try appendObservation(gpa, report, check_id, kind, path, requested_url, expected, fetched);
    try appendCheckFailure(gpa, report, "byte-identity", observation.byte_result, observation.detail);
    try appendCheckFailure(gpa, report, check_id, observation.result, observation.detail);

    if (fetched.response.status == 200 and !fetched.response.body_too_large) {
        if (expected) |record| {
            switch (record.kind) {
                .html_page => {
                    const html = inspectHtml(gpa, plan, record.path, fetched.response.body, bounds.max_projection_urls);
                    try appendCheckFailure(gpa, report, "projection-metadata", html.metadata, html.detail);
                    try appendCheckFailure(gpa, report, "html-reachability", html.links, html.detail);
                },
                .sitemap, .rendered_search, .rss, .llms => return try scanProjection(scratch_gpa, plan, record, fetched.response.body, bounds),
                else => {},
            }
        }
    }
    return null;
}

fn findProjectionRecord(
    inventory: *const artifacts.Inventory,
    kind: artifacts.Kind,
    configured_path: ?[]const u8,
) ?artifacts.Record {
    if (configured_path) |path| {
        for (inventory.records) |record| {
            if (record.kind == kind and std.mem.eql(u8, record.path, path)) return record;
        }
        return null;
    }
    for (inventory.records) |record| {
        if (record.kind == kind and record.status == .committed) return record;
    }
    return null;
}

fn expectedRecordForUrl(
    gpa: std.mem.Allocator,
    plan: *const Plan,
    inventory: *const artifacts.Inventory,
    raw_url: []const u8,
) ?artifacts.Record {
    const classified = location_policy.classify(gpa, &plan.location, raw_url, true) catch return null;
    return switch (classified) {
        .publication => |route| {
            defer gpa.free(route);
            const path = routePath(route);
            if (std.mem.eql(u8, path, "/")) return getRecord(inventory, "index.html");
            if (path.len > 1 and path[0] == '/') return getRecord(inventory, path[1..]);
            return null;
        },
        else => null,
    };
}

fn addLimitation(gpa: std.mem.Allocator, report: *Report, text: []const u8) !void {
    try report.limitations.append(gpa, try gpa.dupe(u8, text));
}

/// Run one bounded deployment observation. A valid report is returned for
/// deployment URL contradictions and network failures so the workflow can
/// upload actionable failed/incomplete evidence even when the audit fails.
pub fn runAudit(
    gpa: std.mem.Allocator,
    io: Io,
    plan: *const Plan,
    inventory: *const artifacts.Inventory,
    plan_bytes: []const u8,
    inventory_bytes: []const u8,
    raw_page_url: []const u8,
    metadata: Metadata,
    bounds: Bounds,
) Error!Report {
    try bounds.validate();
    const page = validatePageUrl(gpa, plan, raw_page_url) catch |err| {
        if (err != error.InvalidPageUrl) return err;
        var checks = try initialChecks(gpa);
        errdefer {
            for (checks.items) |check| {
                gpa.free(check.id);
                gpa.free(check.detail);
            }
            checks.deinit(gpa);
        }
        try updateCheck(checks.items, "deployment-location", .failed, "page_url does not match the normalized publication identity", gpa);
        var report = Report{
            .gpa = gpa,
            .plan = plan,
            .inventory = inventory,
            .plan_sha256 = hashHex(plan_bytes),
            .inventory_sha256 = hashHex(inventory_bytes),
            .page_url = try gpa.dupe(u8, raw_page_url),
            .normalized_page_url = try gpa.dupe(u8, ""),
            .metadata = metadata,
            .bounds = bounds,
            .result = .failed,
            .checks = checks,
        };
        try addLimitation(gpa, &report, "The deployment URL precondition failed; no HTTP request was made.");
        return report;
    };
    var page_owned = true;
    errdefer if (page_owned) {
        gpa.free(page.raw);
        gpa.free(page.normalized);
    };

    var report = Report{
        .gpa = gpa,
        .plan = plan,
        .inventory = inventory,
        .plan_sha256 = hashHex(plan_bytes),
        .inventory_sha256 = hashHex(inventory_bytes),
        .page_url = page.raw,
        .normalized_page_url = page.normalized,
        .metadata = metadata,
        .bounds = bounds,
        .checks = try initialChecks(gpa),
    };
    page_owned = false;
    errdefer report.deinit();
    try addLimitation(gpa, &report, "HTTP observations are temporal and do not certify future requests, browser behavior, or CDN consistency.");
    try addLimitation(gpa, &report, "Only the bounded request, response-byte, projection, and metadata checks listed in this report were attempted.");
    try appendCheckFailure(gpa, &report, "deployment-location", .passed, "");

    for (inventory.records) |record| {
        if (record.required and record.status != .committed) {
            try addLimitation(gpa, &report, "A required target-local inventory record was not committed; deployment comparison is incomplete.");
            try appendCheckFailure(gpa, &report, kindCheckId(record.kind), .failed, "required inventory record is not committed");
        }
    }

    var temp_arena = std.heap.ArenaAllocator.init(gpa);
    defer temp_arena.deinit();

    const process = struct {
        fn one(
            gpa_inner: std.mem.Allocator,
            io_inner: Io,
            plan_inner: *const Plan,
            report_inner: *Report,
            path: []const u8,
            kind: []const u8,
            requested_url: []const u8,
            check_id_override: ?[]const u8,
            expected: ?artifacts.Record,
            bounds_inner: Bounds,
            temp: *std.heap.ArenaAllocator,
        ) !?ProjectionScan {
            const temp_gpa = temp.allocator();
            const fetched = fetchUrl(temp_gpa, io_inner, plan_inner, requested_url, bounds_inner, &report_inner.requests) catch |err| {
                const detail = switch (err) {
                    error.RequestLimitExceeded => "request limit exhausted before this observation",
                    error.InvalidUrl, error.UnsafeRedirect => "deployment request URL or redirect was rejected by the safety policy",
                    error.Timeout => "deployment request timed out",
                    else => "deployment request failed before a complete response was observed",
                };
                try appendUnavailableObservation(gpa_inner, report_inner, check_id_override orelse if (expected) |record| kindCheckId(record.kind) else "html-reachability", kind, path, requested_url, expected, detail);
                return null;
            };
            return try processFetched(gpa_inner, temp_gpa, report_inner, plan_inner, path, kind, requested_url, check_id_override, expected, &fetched, bounds_inner);
        }
    }.one;

    const index_record = getRecord(inventory, "index.html");
    if (index_record == null) {
        try addLimitation(gpa, &report, "The target-local inventory did not contain a committed index.html entry page.");
        try appendCheckFailure(gpa, &report, "html-reachability", .failed, "committed inventory is missing index.html");
    }
    const root_url = try gpa.dupe(u8, raw_page_url);
    defer gpa.free(root_url);
    if (report.requests < bounds.max_requests) {
        _ = try process(gpa, io, plan, &report, "/", "html-page", root_url, null, index_record, bounds, &temp_arena);
    } else {
        report.truncated = true;
    }
    _ = temp_arena.reset(.retain_capacity);

    for (inventory.records) |record| {
        if (record.status != .committed) continue;
        if (report.requests >= bounds.max_requests) {
            report.truncated = true;
            break;
        }
        const requested = try pathUrl(temp_arena.allocator(), plan.location.base_url, record.path);
        const projection_scan = try process(gpa, io, plan, &report, record.path, record.kind.name(), requested, null, record, bounds, &temp_arena);
        if (projection_scan) |scan| {
            try appendCheckFailure(gpa, &report, kindCheckId(record.kind), scan.result, scan.detail);
            for (scan.samples.items) |sample| {
                if (report.requests >= bounds.max_requests) {
                    report.truncated = true;
                    try appendCheckFailure(gpa, &report, kindCheckId(record.kind), .incomplete, "max_requests truncated projection reachability samples");
                    break;
                }
                const expected = expectedRecordForUrl(temp_arena.allocator(), plan, inventory, sample.url);
                _ = try process(gpa, io, plan, &report, sample.path, record.kind.name(), sample.url, kindCheckId(record.kind), expected, bounds, &temp_arena);
            }
        }
        _ = temp_arena.reset(.retain_capacity);
    }
    if (report.truncated) {
        try addLimitation(gpa, &report, "The deterministic inventory request set was truncated at max_requests.");
        try appendCheckFailure(gpa, &report, "html-reachability", .incomplete, "max_requests truncated the declared inventory request set");
    }

    const projection_cases = [_]struct { kind: artifacts.Kind, path: ?[]u8, check: []const u8 }{
        .{ .kind = .sitemap, .path = plan.projections.sitemap, .check = "sitemap" },
        .{ .kind = .rendered_search, .path = null, .check = "rendered-search" },
        .{ .kind = .rss, .path = plan.projections.rss, .check = "rss" },
        .{ .kind = .llms, .path = plan.projections.llms, .check = "llms" },
    };
    for (projection_cases) |projection| {
        if (projection.path != null and findProjectionRecord(inventory, projection.kind, projection.path) == null) {
            try appendCheckFailure(gpa, &report, projection.check, .failed, "the normalized plan selected a projection that is absent from the target-local inventory");
        } else if (projection.path == null and projection.kind != .rendered_search and findProjectionRecord(inventory, projection.kind, null) != null) {
            try appendCheckFailure(gpa, &report, projection.check, .failed, "the target-local inventory contains a projection omitted by the normalized plan");
        }
    }

    if (report.completed_requests == 0 and report.result == .passed) report.result = .incomplete;
    if (report.truncated and report.result == .passed) report.result = .incomplete;
    for (report.checks.items) |check| outcomeMerge(&report.result, check.status);
    return report;
}

fn writeNullableString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: ?[]const u8) !void {
    if (value) |text| try writeJsonString(out, gpa, text) else try writeJsonNull(out, gpa);
}

fn writeNullableU64(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: ?u64) !void {
    if (value) |number| {
        var buffer: [32]u8 = undefined;
        try out.appendSlice(gpa, std.fmt.bufPrint(&buffer, "{d}", .{number}) catch unreachable);
    } else try writeJsonNull(out, gpa);
}

fn writeMetadata(out: *std.ArrayList(u8), gpa: std.mem.Allocator, metadata: Metadata) !void {
    try out.appendSlice(gpa, "{\n      \"repository\": ");
    try writeNullableString(out, gpa, metadata.repository);
    try out.appendSlice(gpa, ",\n      \"source_commit\": ");
    try writeNullableString(out, gpa, metadata.source_commit);
    try out.appendSlice(gpa, ",\n      \"workflow_ref\": ");
    try writeNullableString(out, gpa, metadata.workflow_ref);
    try out.appendSlice(gpa, ",\n      \"workflow_sha\": ");
    try writeNullableString(out, gpa, metadata.workflow_sha);
    try out.appendSlice(gpa, ",\n      \"run_id\": ");
    try writeNullableString(out, gpa, metadata.run_id);
    try out.appendSlice(gpa, ",\n      \"run_attempt\": ");
    try writeNullableString(out, gpa, metadata.run_attempt);
    try out.appendSlice(gpa, ",\n      \"deployment_id\": ");
    try writeNullableString(out, gpa, metadata.deployment_id);
    try out.appendSlice(gpa, ",\n      \"public_artifact_name\": ");
    try writeNullableString(out, gpa, metadata.public_artifact_name);
    try out.appendSlice(gpa, "\n    }");
}

fn writeBounds(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bounds: Bounds) !void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{{\n        \"max_requests\": {d},\n        \"max_body_bytes\": {d},\n        \"max_redirects\": {d},\n        \"timeout_ms\": {d},\n        \"max_projection_urls\": {d}\n      }}", .{
        bounds.max_requests,
        bounds.max_body_bytes,
        bounds.max_redirects,
        bounds.timeout_ms,
        bounds.max_projection_urls,
    }) catch unreachable;
    try out.appendSlice(gpa, text);
}

fn writeCheck(out: *std.ArrayList(u8), gpa: std.mem.Allocator, check: Check, comma: bool) !void {
    try out.appendSlice(gpa, "\n      {\n        \"id\": ");
    try writeJsonString(out, gpa, check.id);
    try out.appendSlice(gpa, ",\n        \"status\": ");
    try writeJsonString(out, gpa, check.status.name());
    try out.appendSlice(gpa, ",\n        \"detail\": ");
    try writeJsonString(out, gpa, check.detail);
    try out.appendSlice(gpa, if (comma) "\n      }," else "\n      }");
}

fn writeObservation(out: *std.ArrayList(u8), gpa: std.mem.Allocator, observation: Observation, comma: bool) !void {
    try out.appendSlice(gpa, "\n      {\n        \"check_id\": ");
    try writeJsonString(out, gpa, observation.check_id);
    try out.appendSlice(gpa, ",\n        \"kind\": ");
    try writeJsonString(out, gpa, observation.kind);
    try out.appendSlice(gpa, ",\n        \"path\": ");
    try writeJsonString(out, gpa, observation.path);
    try out.appendSlice(gpa, ",\n        \"requested_url\": ");
    try writeJsonString(out, gpa, observation.requested_url);
    try out.appendSlice(gpa, ",\n        \"final_url\": ");
    try writeNullableString(out, gpa, observation.final_url);
    try out.appendSlice(gpa, ",\n        \"status\": ");
    if (observation.status) |status| {
        var buffer: [16]u8 = undefined;
        try out.appendSlice(gpa, std.fmt.bufPrint(&buffer, "{d}", .{status}) catch unreachable);
    } else try writeJsonNull(out, gpa);
    try out.appendSlice(gpa, ",\n        \"redirects\": [");
    for (observation.redirects, 0..) |redirect, index| {
        if (index != 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n          {\"status\": ");
        var buffer: [16]u8 = undefined;
        try out.appendSlice(gpa, std.fmt.bufPrint(&buffer, "{d}", .{redirect.status}) catch unreachable);
        try out.appendSlice(gpa, ", \"url\": ");
        try writeJsonString(out, gpa, redirect.url);
        try out.appendSlice(gpa, "}");
    }
    if (observation.redirects.len != 0) try out.appendSlice(gpa, "\n        ");
    try out.appendSlice(gpa, "],\n        \"headers\": {\n          \"content_type\": ");
    try writeNullableString(out, gpa, observation.content_type);
    try out.appendSlice(gpa, ",\n          \"cache_control\": ");
    try writeNullableString(out, gpa, observation.cache_control);
    try out.appendSlice(gpa, ",\n          \"etag\": ");
    try writeNullableString(out, gpa, observation.etag);
    try out.appendSlice(gpa, ",\n          \"last_modified\": ");
    try writeNullableString(out, gpa, observation.last_modified);
    try out.appendSlice(gpa, ",\n          \"content_encoding\": ");
    try writeNullableString(out, gpa, observation.content_encoding);
    try out.appendSlice(gpa, ",\n          \"content_length\": ");
    try writeNullableU64(out, gpa, observation.content_length);
    try out.appendSlice(gpa, "\n        },\n        \"body_bytes\": ");
    if (observation.body_bytes) |bytes| {
        var number: [32]u8 = undefined;
        try out.appendSlice(gpa, std.fmt.bufPrint(&number, "{d}", .{bytes}) catch unreachable);
    } else try writeJsonNull(out, gpa);
    try out.appendSlice(gpa, ",\n        \"observed_sha256\": ");
    if (observation.observed_sha256) |digest| try writeJsonString(out, gpa, &digest) else try writeJsonNull(out, gpa);
    try out.appendSlice(gpa, ",\n        \"expected_sha256\": ");
    if (observation.expected_sha256) |digest| try writeJsonString(out, gpa, &digest) else try writeJsonNull(out, gpa);
    try out.appendSlice(gpa, ",\n        \"expected_bytes\": ");
    if (observation.expected_bytes) |bytes| {
        var number: [32]u8 = undefined;
        try out.appendSlice(gpa, std.fmt.bufPrint(&number, "{d}", .{bytes}) catch unreachable);
    } else try writeJsonNull(out, gpa);
    try out.appendSlice(gpa, ",\n        \"transfer_decoded\": ");
    try writeJsonBool(out, gpa, observation.transfer_decoded);
    try out.appendSlice(gpa, ",\n        \"byte_result\": ");
    try writeJsonString(out, gpa, observation.byte_result.name());
    try out.appendSlice(gpa, ",\n        \"result\": ");
    try writeJsonString(out, gpa, observation.result.name());
    try out.appendSlice(gpa, ",\n        \"detail\": ");
    try writeJsonString(out, gpa, observation.detail);
    try out.appendSlice(gpa, if (comma) "\n      }," else "\n      }");
}

/// Render the deployment evidence with fixed object and array ordering.
pub fn renderEvidence(gpa: std.mem.Allocator, report: *const Report) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n  \"format\": ");
    try writeJsonString(&out, gpa, evidence_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": 1,\n  \"identity\": ");
    try writeMetadata(&out, gpa, report.metadata);
    try out.appendSlice(gpa, ",\n  \"deployment\": {\n    \"provider\": \"github-pages\",\n    \"target\": ");
    try writeJsonString(&out, gpa, report.plan.target);
    try out.appendSlice(gpa, ",\n    \"site_kind\": ");
    try writeJsonString(&out, gpa, report.plan.location.site_kind.name());
    try out.appendSlice(gpa, ",\n    \"base_url\": ");
    try writeJsonString(&out, gpa, report.plan.location.base_url);
    try out.appendSlice(gpa, ",\n    \"origin\": ");
    try writeJsonString(&out, gpa, report.plan.location.origin);
    try out.appendSlice(gpa, ",\n    \"base_path\": ");
    try writeJsonString(&out, gpa, report.plan.location.base_path);
    try out.appendSlice(gpa, ",\n    \"page_url\": ");
    try writeJsonString(&out, gpa, report.page_url);
    try out.appendSlice(gpa, ",\n    \"normalized_page_url\": ");
    try writeJsonString(&out, gpa, report.normalized_page_url);
    try out.appendSlice(gpa, "\n  },\n  \"binding\": {\n    \"plan\": {\n      \"path\": \"publication-plan.json\",\n      \"sha256\": ");
    try writeJsonString(&out, gpa, &report.plan_sha256);
    try out.appendSlice(gpa, "\n    },\n    \"inventory\": {\n      \"path\": \"proof/artifacts.json\",\n      \"sha256\": ");
    try writeJsonString(&out, gpa, &report.inventory_sha256);
    var binding_buffer: [256]u8 = undefined;
    const binding_prefix = std.fmt.bufPrint(&binding_buffer, ",\n      \"format\": \"{s}\",\n      \"schema_version\": {d},\n      \"target\": ", .{ artifacts.artifact_format, artifacts.schema_version }) catch unreachable;
    try out.appendSlice(gpa, binding_prefix);
    try writeJsonString(&out, gpa, report.inventory.target);
    var binding_suffix: [256]u8 = undefined;
    const binding_end = std.fmt.bufPrint(&binding_suffix, ",\n      \"artifact_count\": {d}\n    }}\n  }},\n  \"audit\": {{\n    \"audited_at\": ", .{report.inventory.records.len}) catch unreachable;
    try out.appendSlice(gpa, binding_end);
    try writeJsonString(&out, gpa, report.metadata.audited_at);
    try out.appendSlice(gpa, ",\n    \"result\": ");
    try writeJsonString(&out, gpa, report.result.name());
    try out.appendSlice(gpa, ",\n    \"requests\": ");
    try writeJsonUsize(&out, gpa, report.requests);
    try out.appendSlice(gpa, ",\n    \"completed_requests\": ");
    try writeJsonUsize(&out, gpa, report.completed_requests);
    try out.appendSlice(gpa, ",\n    \"truncated\": ");
    try writeJsonBool(&out, gpa, report.truncated);
    try out.appendSlice(gpa, ",\n    \"bounds\": ");
    try writeBounds(&out, gpa, report.bounds);
    try out.appendSlice(gpa, ",\n    \"checks\": [");
    for (report.checks.items, 0..) |check, index| try writeCheck(&out, gpa, check, index + 1 < report.checks.items.len);
    try out.appendSlice(gpa, "\n    ],\n    \"observations\": [");
    for (report.observations.items, 0..) |observation, index| try writeObservation(&out, gpa, observation, index + 1 < report.observations.items.len);
    try out.appendSlice(gpa, "\n    ]\n  },\n  \"limitations\": [");
    for (report.limitations.items, 0..) |limitation, index| {
        if (index != 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n    ");
        try writeJsonString(&out, gpa, limitation);
    }
    try out.appendSlice(gpa, "\n  ]\n}\n");
    return out.toOwnedSlice(gpa);
}

test "deployment location accepts project, root, and custom Pages identities" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { base: []const u8, origin: []const u8, path: []const u8, page: []const u8 }{
        .{ .base = "https://owner.github.io/boris", .origin = "https://owner.github.io", .path = "/boris", .page = "https://owner.github.io/boris/" },
        .{ .base = "https://owner.github.io", .origin = "https://owner.github.io", .path = "", .page = "https://owner.github.io/" },
        .{ .base = "https://docs.example.test", .origin = "https://docs.example.test", .path = "", .page = "https://docs.example.test/" },
    };
    for (cases) |case| {
        var location = try github_pages.parse(gpa, case.base, case.origin, case.path);
        defer location.deinit(gpa);
        const plan = Plan{
            .gpa = gpa,
            .location = location,
            .target = "public",
            .projections = .{},
        };
        try std.testing.expect(allowedRedirect(gpa, &plan, case.page));
        // The test-owned plan must not deinitialize the borrowed location.
    }
}

test "resolveRedirect follows a same-location canonical 301 without uninitialized memory (#441)" {
    const gpa = std.testing.allocator;
    // The oliver incident: the RSS channel link is the no-trailing-slash base
    // URL, and Pages answers it with a 301 to the canonical trailing-slash
    // form, inside the declared location.
    const current = "https://drawmeanelephant.github.io/oliver";
    const location_header = "https://drawmeanelephant.github.io/oliver/";
    const resolved = try resolveRedirect(gpa, current, location_header);
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings(location_header, resolved);

    // The resolved candidate is a permitted redirect for the project-site plan.
    var location = try github_pages.parse(gpa, "https://drawmeanelephant.github.io/oliver", "https://drawmeanelephant.github.io", "/oliver");
    defer location.deinit(gpa);
    const plan = Plan{ .gpa = gpa, .location = location, .target = "public", .projections = .{} };
    try std.testing.expect(allowedRedirect(gpa, &plan, resolved));
}

test "redirect policy rejects wrong origins and unsafe schemes" {
    const gpa = std.testing.allocator;
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);
    const plan = Plan{ .gpa = gpa, .location = location, .target = "public", .projections = .{} };
    try std.testing.expect(allowedRedirect(gpa, &plan, "https://owner.github.io/boris/next"));
    try std.testing.expect(allowedRedirect(gpa, &plan, "https://owner.github.io/boris/next?x=1"));
    try std.testing.expect(!allowedRedirect(gpa, &plan, "https://evil.example/boris/next"));
    try std.testing.expect(!allowedRedirect(gpa, &plan, "file:///tmp/site"));
    try std.testing.expect(!allowedRedirect(gpa, &plan, "https://user:secret@owner.github.io/boris/next"));
}

test "fixture outcome vocabulary keeps unavailable checks distinct" {
    try std.testing.expectEqualStrings("passed", Outcome.passed.name());
    try std.testing.expectEqualStrings("failed", Outcome.failed.name());
    try std.testing.expectEqualStrings("incomplete", Outcome.incomplete.name());
    try std.testing.expectEqualStrings("not-applicable", Outcome.not_applicable.name());
}

test "local deterministic fixture matrix keeps failures and bounds explicit" {
    const gpa = std.testing.allocator;
    const body = "fixture-page";
    const digest = hashHex(body);
    const expected = artifacts.Record{
        .path = "index.html",
        .kind = .html_page,
        .producer = "html-render",
        .required = true,
        .status = .committed,
        .bytes = body.len,
        .sha256 = digest,
        .format_version = null,
    };
    const fixtures = [_]struct {
        name: []const u8,
        status: u16,
        body_too_large: bool,
        policy_error: ?[]const u8,
        expected_result: Outcome,
    }{
        .{ .name = "project-site", .status = 200, .body_too_large = false, .policy_error = null, .expected_result = .passed },
        .{ .name = "root-unavailable", .status = 503, .body_too_large = false, .policy_error = null, .expected_result = .failed },
        .{ .name = "expected-page-404", .status = 404, .body_too_large = false, .policy_error = null, .expected_result = .failed },
        .{ .name = "asset-404", .status = 404, .body_too_large = false, .policy_error = null, .expected_result = .failed },
        .{ .name = "wrong-origin-redirect", .status = 301, .body_too_large = false, .policy_error = "redirect leaves the declared deployment location", .expected_result = .failed },
        .{ .name = "bounded-response", .status = 200, .body_too_large = true, .policy_error = null, .expected_result = .incomplete },
    };
    for (fixtures) |fixture| {
        const response = SingleResponse{
            .status = fixture.status,
            .location = null,
            .headers = .{},
            .content_encoding = .identity,
            .content_length = body.len,
            .body = @constCast(body),
            .body_too_large = fixture.body_too_large,
        };
        const result = observationResult(&response, expected, fixture.policy_error);
        try std.testing.expectEqual(fixture.expected_result, result.result);
        _ = fixture.name;
    }
    _ = gpa;
}

test "projection scanners bound samples and reject location disagreements" {
    const gpa = std.testing.allocator;
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);
    const plan = Plan{
        .gpa = gpa,
        .location = location,
        .target = "public",
        .projections = .{},
    };

    var sitemap = try scanSitemap(
        gpa,
        &plan,
        "<urlset><url><loc>https://owner.github.io/boris/</loc></url><url><loc>https://owner.github.io/boris/docs.html</loc></url></urlset>",
        1,
    );
    defer sitemap.deinit(gpa);
    try std.testing.expectEqual(Outcome.incomplete, sitemap.result);
    try std.testing.expectEqual(@as(usize, 1), sitemap.samples.items.len);

    var sitemap_bad = try scanSitemap(
        gpa,
        &plan,
        "<urlset><url><loc>https://evil.example/docs.html</loc></url></urlset>",
        4,
    );
    defer sitemap_bad.deinit(gpa);
    try std.testing.expectEqual(Outcome.failed, sitemap_bad.result);

    var rss = try scanRss(
        gpa,
        &plan,
        "<rss><channel><link>https://owner.github.io/boris/</link><item><link>https://owner.github.io/boris/docs.html</link></item></channel></rss>",
        4,
    );
    defer rss.deinit(gpa);
    try std.testing.expectEqual(Outcome.passed, rss.result);
    try std.testing.expectEqual(@as(usize, 2), rss.samples.items.len);

    var rss_bad = try scanRss(
        gpa,
        &plan,
        "<rss><channel><link>https://evil.example/docs.html</link></channel></rss>",
        4,
    );
    defer rss_bad.deinit(gpa);
    try std.testing.expectEqual(Outcome.failed, rss_bad.result);

    var search = try scanSearch(
        gpa,
        &plan,
        "{\"format\":\"boris-rendered-search-index\",\"schema_version\":1,\"documents\":[{\"path\":\"docs/start.html\"}]}",
        4,
    );
    defer search.deinit(gpa);
    try std.testing.expectEqual(Outcome.passed, search.result);
    try std.testing.expectEqualStrings("https://owner.github.io/boris/docs/start.html", search.samples.items[0].url);

    var llms_absent = try scanLlms(gpa, &plan, "# Docs\nA local note without hosted links.\n", 4);
    defer llms_absent.deinit(gpa);
    try std.testing.expectEqual(Outcome.not_applicable, llms_absent.result);

    var llms_bad = try scanLlms(gpa, &plan, "- [bad](https://evil.example/docs.html)\n", 4);
    defer llms_bad.deinit(gpa);
    try std.testing.expectEqual(Outcome.failed, llms_bad.result);

    const html = inspectHtml(
        gpa,
        &plan,
        "index.html",
        "<link rel=\"canonical\" href=\"https://evil.example/\">",
        4,
    );
    try std.testing.expectEqual(Outcome.failed, html.metadata);
}

test "sample failures do not fabricate byte identity" {
    const body: []u8 = @constCast("missing");
    const response = SingleResponse{
        .status = 404,
        .location = null,
        .headers = .{},
        .content_encoding = .identity,
        .content_length = body.len,
        .body = body,
        .body_too_large = false,
    };
    const result = observationResult(&response, null, null);
    try std.testing.expectEqual(Outcome.not_applicable, result.byte);
    try std.testing.expectEqual(Outcome.failed, result.result);
}
