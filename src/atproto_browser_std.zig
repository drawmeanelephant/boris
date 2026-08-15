//! Narrow native browser-launch capability for the ATProto OAuth handoff.
//!
//! No shell is involved. Only a previously constructed HTTPS authorization
//! URL is accepted, and child output and execution time are bounded.

const std = @import("std");
const builtin = @import("builtin");
const transport = @import("atproto_transport.zig");

pub const Error = std.mem.Allocator.Error || error{
    BrowserFailed,
    BrowserUnavailable,
    InvalidAuthorizationUrl,
    Timeout,
};

pub fn open(allocator: std.mem.Allocator, io: std.Io, url: []const u8) Error!void {
    try validate(url);
    const command = commandForHost() orelse return error.BrowserUnavailable;
    const argv = [_][]const u8{ command, url };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    }) catch |err| return switch (err) {
        error.Timeout => error.Timeout,
        error.FileNotFound => error.BrowserUnavailable,
        else => error.BrowserFailed,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.BrowserFailed,
        else => return error.BrowserFailed,
    }
}

fn validate(url: []const u8) Error!void {
    if (url.len == 0 or url.len > transport.max_url_bytes or !std.mem.startsWith(u8, url, "https://")) {
        return error.InvalidAuthorizationUrl;
    }
    for (url) |byte| if (byte <= 0x20 or byte >= 0x7f or byte == '\\') return error.InvalidAuthorizationUrl;
    const parsed = std.Uri.parse(url) catch return error.InvalidAuthorizationUrl;
    if (parsed.host == null or parsed.user != null or parsed.password != null or parsed.fragment != null) {
        return error.InvalidAuthorizationUrl;
    }
}

fn commandForHost() ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => "/usr/bin/open",
        .linux => "xdg-open",
        else => null,
    };
}

test "browser boundary accepts only bounded HTTPS URLs" {
    try validate("https://auth.example.com/authorize?client_id=x&request_uri=y");
    try std.testing.expectError(error.InvalidAuthorizationUrl, validate("http://auth.example.com/authorize"));
    try std.testing.expectError(error.InvalidAuthorizationUrl, validate("https://user@auth.example.com/authorize"));
    try std.testing.expectError(error.InvalidAuthorizationUrl, validate("https://auth.example.com/authorize#fragment"));
}
