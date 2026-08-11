//! Small observer-side URL policy adapter.
//!
//! The compiler's publication-location module remains authoritative for local
//! publication checks. This copy is intentionally limited to the observer's
//! network-safety questions so the standalone tool does not make the compiler
//! import graph or product CLI network-aware.

const std = @import("std");
const github_pages = @import("github_pages");

pub const Location = github_pages.Location;

pub const Error = std.mem.Allocator.Error || error{
    InvalidAbsoluteUrl,
    OriginMismatch,
    BasePathMismatch,
    SiteUrlMismatch,
};

pub const Classification = union(enum) {
    relative,
    publication: []u8,
    external,
};

fn isHttp(raw: []const u8) bool {
    return (raw.len >= 7 and std.ascii.eqlIgnoreCase(raw[0..7], "http://")) or
        (raw.len >= 8 and std.ascii.eqlIgnoreCase(raw[0..8], "https://"));
}

fn hasScheme(raw: []const u8) bool {
    if (raw.len == 0 or !std.ascii.isAlphabetic(raw[0])) return false;
    for (raw) |byte| {
        if (byte == ':') return true;
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    }
    return false;
}

fn suffixStart(raw: []const u8) usize {
    var end = raw.len;
    if (std.mem.indexOfScalar(u8, raw, '?')) |index| end = @min(end, index);
    if (std.mem.indexOfScalar(u8, raw, '#')) |index| end = @min(end, index);
    return end;
}

fn originEnd(raw: []const u8) usize {
    const scheme_end: usize = if (raw.len >= 7 and std.ascii.eqlIgnoreCase(raw[0..7], "http://")) 7 else if (raw.len >= 8 and std.ascii.eqlIgnoreCase(raw[0..8], "https://")) 8 else return 0;
    var end = scheme_end;
    while (end < raw.len and raw[end] != '/' and raw[end] != '?' and raw[end] != '#') : (end += 1) {}
    return end;
}

fn stripBase(location: *const Location, raw_path: []const u8) Error![]const u8 {
    const path = if (raw_path.len == 0) "/" else raw_path;
    if (path.len == 0 or path[0] != '/') return error.InvalidAbsoluteUrl;
    if (location.base_path.len == 0) return path;
    if (std.mem.eql(u8, path, location.base_path)) return "/";
    if (path.len > location.base_path.len and
        std.mem.startsWith(u8, path, location.base_path) and
        path[location.base_path.len] == '/') return path[location.base_path.len..];
    return error.BasePathMismatch;
}

fn route(gpa: std.mem.Allocator, location: *const Location, raw_path: []const u8, suffix: []const u8) Error![]u8 {
    const stripped = try stripBase(location, raw_path);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, stripped);
    try out.appendSlice(gpa, suffix);
    return out.toOwnedSlice(gpa);
}

pub fn classify(gpa: std.mem.Allocator, location: *const Location, raw: []const u8, require_public: bool) Error!Classification {
    if (raw.len == 0 or raw[0] == '#' or raw[0] == '?') return .relative;
    if (std.mem.startsWith(u8, raw, "//")) {
        if (require_public) return error.OriginMismatch;
        return .external;
    }
    if (raw[0] == '/') {
        const end = suffixStart(raw);
        return .{ .publication = try route(gpa, location, raw[0..end], raw[end..]) };
    }
    if (!isHttp(raw)) {
        if (hasScheme(raw)) {
            if (require_public) return error.InvalidAbsoluteUrl;
            return .external;
        }
        return .relative;
    }
    const end = originEnd(raw);
    if (end == 0) return error.InvalidAbsoluteUrl;
    if (!std.ascii.eqlIgnoreCase(raw[0..end], location.origin)) {
        if (require_public) return error.OriginMismatch;
        return .external;
    }
    const path_end = suffixStart(raw);
    return .{ .publication = try route(gpa, location, raw[end..path_end], raw[path_end..]) };
}

pub fn validateSiteUrl(gpa: std.mem.Allocator, location: *const Location, raw: []const u8) Error!void {
    const uri = std.Uri.parse(raw) catch return error.InvalidAbsoluteUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidAbsoluteUrl;
    if (!isHttp(raw)) return error.InvalidAbsoluteUrl;
    const end = originEnd(raw);
    if (end == 0 or !std.ascii.eqlIgnoreCase(raw[0..end], location.origin)) return error.SiteUrlMismatch;
    const path = raw[end..];
    const trimmed = if (path.len == 0) "" else blk: {
        var at = path.len;
        while (at > 0 and path[at - 1] == '/') : (at -= 1) {}
        break :blk path[0..at];
    };
    if (!std.mem.eql(u8, trimmed, location.base_path)) return error.SiteUrlMismatch;
    _ = gpa;
}
