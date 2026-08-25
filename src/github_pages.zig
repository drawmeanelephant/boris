//! GitHub Pages publication-location validation.
//!
//! `actions/configure-pages` is the authoritative source of these values in
//! Actions. Boris keeps the same values usable offline so a local declaration
//! can prove that the base URL, origin, and base path describe one location.

const std = @import("std");
const site_url = @import("site_url.zig");

pub const Error = error{
    InvalidBaseUrl,
    InvalidOrigin,
    InvalidBasePath,
    OriginMismatch,
    BasePathMismatch,
    CustomDomainBasePath,
} || std.mem.Allocator.Error;

pub const SiteKind = enum {
    project_site,
    root_site,
    custom_domain,

    pub fn name(self: SiteKind) []const u8 {
        return switch (self) {
            .project_site => "project-site",
            .root_site => "root-site",
            .custom_domain => "custom-domain",
        };
    }
};

pub const Location = struct {
    base_url: []u8,
    origin: []u8,
    base_path: []u8,
    site_kind: SiteKind,

    pub fn deinit(self: *Location, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.origin);
        allocator.free(self.base_path);
        self.* = undefined;
    }
};

const https_scheme = "https://";
const http_scheme = "http://";
const github_io_suffix = ".github.io";

pub const target_name = "github-pages";

fn schemeEnd(url: []const u8) ?usize {
    if (std.mem.startsWith(u8, url, https_scheme)) return https_scheme.len;
    if (std.mem.startsWith(u8, url, http_scheme)) return http_scheme.len;
    return null;
}

fn originLength(url: []const u8) Error!usize {
    const start = schemeEnd(url) orelse return error.InvalidBaseUrl;
    return std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
}

fn host(origin: []const u8) Error![]const u8 {
    const start = schemeEnd(origin) orelse return error.InvalidOrigin;
    const authority = origin[start..];
    if (authority.len == 0) return error.InvalidOrigin;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidOrigin;
        return authority[0 .. close + 1];
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    return authority[0 .. colon orelse authority.len];
}

fn isDefaultPagesDomain(origin: []const u8) Error!bool {
    const h = try host(origin);
    return h.len > github_io_suffix.len and
        std.ascii.eqlIgnoreCase(h[h.len - github_io_suffix.len ..], github_io_suffix);
}

fn normalizeBasePath(allocator: std.mem.Allocator, raw: []const u8) Error![]u8 {
    if (raw.len == 0) return try allocator.dupe(u8, "");
    if (raw.len > 2048 or raw[0] != '/') return error.InvalidBasePath;

    var end = raw.len;
    while (end > 1 and raw[end - 1] == '/') : (end -= 1) {}
    const candidate = raw[0..end];
    if (candidate.len == 1) return try allocator.dupe(u8, "");
    if (std.mem.indexOf(u8, candidate, "//") != null or
        std.mem.indexOfScalar(u8, candidate, '\\') != null or
        std.mem.indexOfScalar(u8, candidate, '?') != null or
        std.mem.indexOfScalar(u8, candidate, '#') != null)
    {
        return error.InvalidBasePath;
    }
    var segments = std.mem.splitScalar(u8, candidate[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidBasePath;
        }
    }

    // Reuse the audited URL grammar for path bytes and percent escapes. The
    // synthetic authority is not retained and does not become publication
    // data.
    const synthetic = try std.fmt.allocPrint(allocator, "https://example.invalid{s}", .{candidate});
    defer allocator.free(synthetic);
    const checked = site_url.normalized(allocator, synthetic) catch |err| switch (err) {
        error.InvalidSiteUrl => return error.InvalidBasePath,
        error.OutOfMemory => return error.OutOfMemory,
    };
    allocator.free(checked);
    return try allocator.dupe(u8, candidate);
}

/// Normalize and cross-check the three authoritative Pages values.
///
/// `base_url` must equal `origin + base_path` after trailing-slash
/// normalization. Custom domains are root sites: a non-empty base path is a
/// contradiction, not a hint to guess a different URL.
pub fn parse(
    allocator: std.mem.Allocator,
    raw_base_url: []const u8,
    raw_origin: []const u8,
    raw_base_path: []const u8,
) Error!Location {
    const base_url = site_url.normalized(allocator, raw_base_url) catch |err| switch (err) {
        error.InvalidSiteUrl => return error.InvalidBaseUrl,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer allocator.free(base_url);
    const origin = site_url.normalized(allocator, raw_origin) catch |err| switch (err) {
        error.InvalidSiteUrl => return error.InvalidOrigin,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer allocator.free(origin);
    const base_origin_len = originLength(base_url) catch return error.InvalidBaseUrl;
    const declared_origin_len = originLength(origin) catch return error.InvalidOrigin;
    if (declared_origin_len != origin.len) return error.InvalidOrigin;
    if (!std.mem.eql(u8, base_url[0..base_origin_len], origin)) return error.OriginMismatch;

    const base_path = try normalizeBasePath(allocator, raw_base_path);
    errdefer allocator.free(base_path);
    const derived_path = base_url[base_origin_len..];
    if (!std.mem.eql(u8, derived_path, base_path)) return error.BasePathMismatch;

    const default_domain = try isDefaultPagesDomain(origin);
    if (!default_domain and base_path.len > 0) return error.CustomDomainBasePath;
    const site_kind: SiteKind = if (!default_domain)
        .custom_domain
    else if (base_path.len > 0)
        .project_site
    else
        .root_site;

    return .{
        .base_url = base_url,
        .origin = origin,
        .base_path = base_path,
        .site_kind = site_kind,
    };
}

test "Pages project site normalizes and classifies the repository path" {
    var location = try parse(
        std.testing.allocator,
        "https://owner.github.io/boris/",
        "https://owner.github.io/",
        "/boris/",
    );
    defer location.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://owner.github.io/boris", location.base_url);
    try std.testing.expectEqualStrings("https://owner.github.io", location.origin);
    try std.testing.expectEqualStrings("/boris", location.base_path);
    try std.testing.expectEqual(SiteKind.project_site, location.site_kind);
}

test "Pages root and custom sites are distinct without a CNAME" {
    var root = try parse(std.testing.allocator, "https://owner.github.io", "https://owner.github.io", "");
    defer root.deinit(std.testing.allocator);
    try std.testing.expectEqual(SiteKind.root_site, root.site_kind);

    var custom = try parse(std.testing.allocator, "https://docs.example.com/", "https://docs.example.com/", "");
    defer custom.deinit(std.testing.allocator);
    try std.testing.expectEqual(SiteKind.custom_domain, custom.site_kind);
    try std.testing.expectEqualStrings("", custom.base_path);

    var custom_www = try parse(std.testing.allocator, "https://www.docs.example.com", "https://www.docs.example.com", "");
    defer custom_www.deinit(std.testing.allocator);
    try std.testing.expectEqual(SiteKind.custom_domain, custom_www.site_kind);
    try std.testing.expectEqualStrings("https://www.docs.example.com", custom_www.base_url);

    var uppercase = try parse(std.testing.allocator, "https://OWNER.GITHUB.IO/docs/", "https://OWNER.GITHUB.IO", "/docs");
    defer uppercase.deinit(std.testing.allocator);
    try std.testing.expectEqual(SiteKind.project_site, uppercase.site_kind);
}

test "Pages location rejects contradictions and malformed paths" {
    try std.testing.expectError(
        error.OriginMismatch,
        parse(std.testing.allocator, "https://owner.github.io/boris", "https://other.github.io", "/boris"),
    );
    try std.testing.expectError(
        error.BasePathMismatch,
        parse(std.testing.allocator, "https://owner.github.io/boris", "https://owner.github.io", "/docs"),
    );
    try std.testing.expectError(
        error.CustomDomainBasePath,
        parse(std.testing.allocator, "https://docs.example.com/boris", "https://docs.example.com", "/boris"),
    );
    try std.testing.expectError(
        error.InvalidBasePath,
        parse(std.testing.allocator, "https://owner.github.io/boris", "https://owner.github.io", "/a/../boris"),
    );
}
