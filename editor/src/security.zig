const std = @import("std");

pub const Headers = struct {
    host: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    token: ?[]const u8 = null,
};

pub const Error = error{ InvalidHost, InvalidOrigin, InvalidToken };

pub fn validate(headers: Headers, port: u16, expected_token: []const u8) Error!void {
    const host = headers.host orelse return error.InvalidHost;
    var expected_ip: [64]u8 = undefined;
    const ip = std.fmt.bufPrint(&expected_ip, "127.0.0.1:{d}", .{port}) catch unreachable;
    var expected_localhost: [64]u8 = undefined;
    const localhost = std.fmt.bufPrint(&expected_localhost, "localhost:{d}", .{port}) catch unreachable;
    if (!std.ascii.eqlIgnoreCase(host, ip) and !std.ascii.eqlIgnoreCase(host, localhost)) return error.InvalidHost;

    if (headers.origin) |origin| {
        var expected_origin_ip: [80]u8 = undefined;
        const origin_ip = std.fmt.bufPrint(&expected_origin_ip, "http://127.0.0.1:{d}", .{port}) catch unreachable;
        var expected_origin_localhost: [80]u8 = undefined;
        const origin_localhost = std.fmt.bufPrint(&expected_origin_localhost, "http://localhost:{d}", .{port}) catch unreachable;
        if (!std.ascii.eqlIgnoreCase(origin, origin_ip) and !std.ascii.eqlIgnoreCase(origin, origin_localhost)) return error.InvalidOrigin;
    }

    const actual = headers.token orelse return error.InvalidToken;
    if (actual.len != expected_token.len or !std.crypto.timing_safe.eql([32]u8, actual[0..32].*, expected_token[0..32].*)) {
        return error.InvalidToken;
    }
}

test "API validation accepts loopback aliases and rejects rebinding" {
    const token = "0123456789abcdef0123456789abcdef";
    try validate(.{ .host = "127.0.0.1:4317", .origin = "http://127.0.0.1:4317", .token = token }, 4317, token);
    try validate(.{ .host = "localhost:4317", .token = token }, 4317, token);
    try std.testing.expectError(error.InvalidHost, validate(.{ .host = "attacker.test:4317", .token = token }, 4317, token));
    try std.testing.expectError(error.InvalidOrigin, validate(.{ .host = "127.0.0.1:4317", .origin = "https://attacker.test", .token = token }, 4317, token));
    try std.testing.expectError(error.InvalidToken, validate(.{ .host = "127.0.0.1:4317", .token = "bad" }, 4317, token));
}
