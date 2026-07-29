//! Shared validation for public HTTP(S) deployment URLs.
//!
//! RSS and HTML sitemap publication use the same bounded, fragment-free,
//! userinfo-free base URL grammar. The returned form has no trailing slash so
//! projections can append Boris's exact `.html` output paths consistently.

const std = @import("std");
const Io = std.Io;

pub const Error = error{InvalidSiteUrl};

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn isSubDelimiter(byte: u8) bool {
    return switch (byte) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

fn validatePort(port: []const u8) Error!void {
    if (port.len == 0) return error.InvalidSiteUrl;
    for (port) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSiteUrl;
    _ = std.fmt.parseInt(u16, port, 10) catch return error.InvalidSiteUrl;
}

fn validateDnsHost(host: []const u8) Error!void {
    if (host.len == 0 or host.len > 253) return error.InvalidSiteUrl;
    var label_start: usize = 0;
    for (host, 0..) |byte, index| {
        if (byte == '.') {
            const label_len = index - label_start;
            if (label_len == 0 or label_len > 63 or host[label_start] == '-' or host[index - 1] == '-') return error.InvalidSiteUrl;
            label_start = index + 1;
        } else if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) {
            return error.InvalidSiteUrl;
        }
    }
    const final_label_len = host.len - label_start;
    if (final_label_len == 0 or final_label_len > 63 or host[label_start] == '-' or host[host.len - 1] == '-') return error.InvalidSiteUrl;
}

fn validateAuthority(authority: []const u8) Error!void {
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidSiteUrl;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidSiteUrl;
        if (close == 1) return error.InvalidSiteUrl;
        _ = Io.net.Ip6Address.parse(authority[1..close], 0) catch return error.InvalidSiteUrl;
        const remainder = authority[close + 1 ..];
        if (remainder.len == 0) return;
        if (remainder[0] != ':') return error.InvalidSiteUrl;
        return validatePort(remainder[1..]);
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |index| authority[0..index] else authority;
    if (std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidSiteUrl;
    try validateDnsHost(host);
    if (colon) |index| try validatePort(authority[index + 1 ..]);
}

fn validatePath(path: []const u8) Error!void {
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        const byte = path[index];
        if (isUnreserved(byte) or isSubDelimiter(byte) or byte == ':' or byte == '@' or byte == '/') continue;
        if (byte == '%' and index + 2 < path.len and
            std.ascii.isHex(path[index + 1]) and std.ascii.isHex(path[index + 2]))
        {
            index += 2;
            continue;
        }
        return error.InvalidSiteUrl;
    }
}

/// Validate a bounded absolute deployment URL and return the no-trailing-slash
/// form. Query strings, fragments, userinfo, non-HTTP(S) schemes, non-ASCII
/// authority bytes, and malformed percent escapes are rejected.
pub fn normalized(
    allocator: std.mem.Allocator,
    raw: []const u8,
) (Error || std.mem.Allocator.Error)![]u8 {
    if (raw.len == 0 or raw.len > 2048) return error.InvalidSiteUrl;
    const scheme_end: usize = if (std.mem.startsWith(u8, raw, "https://"))
        8
    else if (std.mem.startsWith(u8, raw, "http://"))
        7
    else
        return error.InvalidSiteUrl;
    if (scheme_end >= raw.len) return error.InvalidSiteUrl;

    var host_end = scheme_end;
    while (host_end < raw.len and raw[host_end] != '/' and raw[host_end] != '?' and raw[host_end] != '#') : (host_end += 1) {
        if (raw[host_end] <= 0x20 or raw[host_end] >= 0x7f) return error.InvalidSiteUrl;
    }
    try validateAuthority(raw[scheme_end..host_end]);
    if (host_end < raw.len and (raw[host_end] == '?' or raw[host_end] == '#')) return error.InvalidSiteUrl;
    try validatePath(raw[host_end..]);

    var end = raw.len;
    while (end > host_end and raw[end - 1] == '/') : (end -= 1) {}
    return try allocator.dupe(u8, raw[0..end]);
}

test "shared public site URL validation normalizes strict HTTP(S) bases" {
    const normalized_url = try normalized(std.testing.allocator, "https://[2001:db8::1]:8443/docs/%E2%9C%93/");
    defer std.testing.allocator.free(normalized_url);
    try std.testing.expectEqualStrings("https://[2001:db8::1]:8443/docs/%E2%9C%93", normalized_url);

    const invalid = [_][]const u8{
        "",
        "/docs",
        "ftp://example.test/docs",
        "https://example.test/?x=1",
        "https://example.test/docs#frag",
        "https://user@example.test/docs",
        "https:///docs",
        "https://example.test:port/docs",
        "https://exa mple.test/docs",
        "https://example.test/%not-encoded",
        "https://[::1/docs",
    };
    for (invalid) |url| {
        try std.testing.expectError(error.InvalidSiteUrl, normalized(std.testing.allocator, url));
    }
}
