//! Semantic URL/path checks for a normalized publication location.
//!
//! A Pages base path is part of the public URL, not a filesystem prefix. This
//! module converts root-relative and same-origin absolute references back to
//! Boris target-relative routes before the existing route resolver checks
//! them. Unrelated external URLs remain external links.

const std = @import("std");
const github_pages = @import("github_pages.zig");
const site_url = @import("site_url.zig");

pub const Location = github_pages.Location;

pub const Error = std.mem.Allocator.Error || error{
    InvalidAbsoluteUrl,
    OriginMismatch,
    BasePathMismatch,
    SiteUrlMismatch,
};

pub const Classification = union(enum) {
    /// A target-relative reference. The existing route resolver should use the
    /// original target against the source page.
    relative,
    /// A root-relative or same-origin absolute publication reference. The
    /// payload is a target-relative route (including query/fragment suffixes)
    /// and is allocator-owned by the caller.
    publication: []u8,
    /// An unrelated external URL. It is not a Boris-owned publication route.
    external,
};

fn isHttpUrl(value: []const u8) bool {
    return value.len >= 7 and
        (std.ascii.eqlIgnoreCase(value[0..7], "http://") or
            (value.len >= 8 and std.ascii.eqlIgnoreCase(value[0..8], "https://")));
}

fn httpSchemeLength(value: []const u8) ?usize {
    if (value.len >= 7 and std.ascii.eqlIgnoreCase(value[0..7], "http://")) return 7;
    if (value.len >= 8 and std.ascii.eqlIgnoreCase(value[0..8], "https://")) return 8;
    return null;
}

fn hasGenericScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value, 0..) |byte, index| {
        if (byte == ':') return index > 0;
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    }
    return false;
}

fn suffixStart(value: []const u8) usize {
    var result = value.len;
    if (std.mem.indexOfScalar(u8, value, '?')) |index| result = @min(result, index);
    if (std.mem.indexOfScalar(u8, value, '#')) |index| result = @min(result, index);
    return result;
}

fn authorityEnd(value: []const u8, start: usize) usize {
    var result = value.len;
    if (std.mem.indexOfScalarPos(u8, value, start, '/')) |index| result = @min(result, index);
    if (std.mem.indexOfScalarPos(u8, value, start, '?')) |index| result = @min(result, index);
    if (std.mem.indexOfScalarPos(u8, value, start, '#')) |index| result = @min(result, index);
    return result;
}

fn sameOrigin(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn stripPublicationBase(location: *const Location, raw_path: []const u8) Error![]const u8 {
    const path = if (raw_path.len == 0) "/" else raw_path;
    if (path[0] != '/') return error.InvalidAbsoluteUrl;

    if (location.base_path.len == 0) return path;
    if (std.mem.eql(u8, path, location.base_path)) return "/";
    if (path.len > location.base_path.len and
        std.mem.startsWith(u8, path, location.base_path) and
        path[location.base_path.len] == '/')
    {
        return path[location.base_path.len..];
    }
    return error.BasePathMismatch;
}

fn makeRoute(
    allocator: std.mem.Allocator,
    location: *const Location,
    raw_path: []const u8,
    suffix: []const u8,
) Error![]u8 {
    const route_path = try stripPublicationBase(location, raw_path);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, route_path);
    try out.appendSlice(allocator, suffix);
    return try out.toOwnedSlice(allocator);
}

/// Classify one rendered URL in the context of a normalized publication.
/// `require_public` is used for canonical/public metadata such as a canonical
/// link or `og:url`; ordinary external hyperlinks remain valid external URLs.
pub fn classify(
    allocator: std.mem.Allocator,
    location: *const Location,
    raw: []const u8,
    require_public: bool,
) Error!Classification {
    if (raw.len == 0 or raw[0] == '#') return .relative;
    if (std.mem.startsWith(u8, raw, "//")) {
        if (require_public) return error.OriginMismatch;
        return .external;
    }
    if (std.mem.startsWith(u8, raw, "/")) {
        const end = suffixStart(raw);
        return .{ .publication = try makeRoute(allocator, location, raw[0..end], raw[end..]) };
    }

    if (isHttpUrl(raw)) {
        const scheme_len = httpSchemeLength(raw).?;
        const origin_end = authorityEnd(raw, scheme_len);
        if (origin_end == scheme_len) {
            if (require_public) return error.InvalidAbsoluteUrl;
            return .external;
        }
        const raw_origin = raw[0..origin_end];
        if (!sameOrigin(raw_origin, location.origin)) {
            if (require_public) return error.OriginMismatch;
            return .external;
        }

        const end = suffixStart(raw);
        // Validate the absolute URL grammar after stripping the query and
        // fragment, which are valid URL suffixes but are not location data.
        const normalized = site_url.normalized(allocator, raw[0..end]) catch |err| switch (err) {
            error.InvalidSiteUrl => return error.InvalidAbsoluteUrl,
            error.OutOfMemory => return error.OutOfMemory,
        };
        allocator.free(normalized);
        return .{ .publication = try makeRoute(allocator, location, raw[origin_end..end], raw[end..]) };
    }

    if (hasGenericScheme(raw)) {
        if (require_public) return error.InvalidAbsoluteUrl;
        return .external;
    }
    return .relative;
}

/// Validate an absolute URL emitted by a machine-facing projection against the
/// normalized location. This deliberately accepts only the declared public
/// origin and base path; it never performs network access.
pub fn validatePublicUrl(
    allocator: std.mem.Allocator,
    location: *const Location,
    raw: []const u8,
) Error!void {
    const classified = try classify(allocator, location, raw, true);
    switch (classified) {
        .publication => |route| allocator.free(route),
        .relative, .external => return error.InvalidAbsoluteUrl,
    }
}

/// Validate a projection's normalized site URL while preserving the rule that
/// URL paths are case-sensitive but schemes/authorities are not.
pub fn validateSiteUrl(
    allocator: std.mem.Allocator,
    location: *const Location,
    raw: []const u8,
) Error!void {
    const normalized = site_url.normalized(allocator, raw) catch |err| switch (err) {
        error.InvalidSiteUrl => return error.InvalidAbsoluteUrl,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(normalized);

    const scheme_len = httpSchemeLength(normalized) orelse return error.InvalidAbsoluteUrl;
    const origin_end = authorityEnd(normalized, scheme_len);
    const expected_scheme_len = httpSchemeLength(location.base_url) orelse return error.SiteUrlMismatch;
    const expected_origin_end = authorityEnd(location.base_url, expected_scheme_len);
    if (!sameOrigin(normalized[0..origin_end], location.origin) or
        !sameOrigin(location.origin, location.base_url[0..expected_origin_end]) or
        !std.mem.eql(u8, normalized[origin_end..], location.base_path))
    {
        return error.SiteUrlMismatch;
    }
}

test "project, root, and custom locations classify public paths semantically" {
    const gpa = std.testing.allocator;
    var project = try github_pages.parse(gpa, "https://owner.github.io/boris/", "https://owner.github.io/", "/boris/");
    defer project.deinit(gpa);
    var root = try github_pages.parse(gpa, "https://owner.github.io", "https://owner.github.io", "");
    defer root.deinit(gpa);
    var custom = try github_pages.parse(gpa, "https://docs.example.com/", "https://docs.example.com/", "");
    defer custom.deinit(gpa);

    const project_route = try classify(gpa, &project, "/boris/guides/start.html", true);
    defer switch (project_route) {
        .publication => |route| gpa.free(route),
        else => {},
    };
    try std.testing.expectEqualStrings("/guides/start.html", project_route.publication);
    try std.testing.expectError(error.BasePathMismatch, classify(gpa, &project, "/guides/start.html", true));

    const root_route = try classify(gpa, &root, "/guides/start.html", true);
    defer switch (root_route) {
        .publication => |route| gpa.free(route),
        else => {},
    };
    try std.testing.expectEqualStrings("/guides/start.html", root_route.publication);
    const custom_route = try classify(gpa, &custom, "https://docs.example.com/guides/start.html", true);
    defer switch (custom_route) {
        .publication => |route| gpa.free(route),
        else => {},
    };
    try std.testing.expectEqualStrings("/guides/start.html", custom_route.publication);
}

test "wrong origins are external links unless a public URL is required" {
    const gpa = std.testing.allocator;
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris", "https://owner.github.io", "/boris");
    defer location.deinit(gpa);
    try std.testing.expectEqual(Classification.external, try classify(gpa, &location, "https://www.github.io/boris/start.html", false));
    try std.testing.expectError(error.OriginMismatch, classify(gpa, &location, "https://www.github.io/boris/start.html", true));
    try std.testing.expectError(error.BasePathMismatch, classify(gpa, &location, "https://owner.github.io/other/start.html", true));
}

test "projection site URLs must equal the normalized publication identity" {
    const gpa = std.testing.allocator;
    var location = try github_pages.parse(gpa, "https://owner.github.io/boris/", "https://owner.github.io", "/boris/");
    defer location.deinit(gpa);
    try validateSiteUrl(gpa, &location, "https://owner.github.io/boris");
    try std.testing.expectError(error.SiteUrlMismatch, validateSiteUrl(gpa, &location, "https://owner.github.io"));
    try std.testing.expectError(error.SiteUrlMismatch, validateSiteUrl(gpa, &location, "https://owner.github.io/other"));
}
