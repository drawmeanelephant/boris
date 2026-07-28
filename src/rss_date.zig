//! Strict UTC timestamps and RFC 822 dates for the RSS projection.
//!
//! This module is deliberately clock- and timezone-free. It accepts only the
//! author-facing RFC 3339 subset documented by the RSS contract.

const std = @import("std");

pub const Timestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const Error = error{InvalidTimestamp};

pub fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

pub fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn number(text: []const u8) Error!u16 {
    var out: u16 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidTimestamp;
        out = out * 10 + (byte - '0');
    }
    return out;
}

/// Parse exactly `YYYY-MM-DDTHH:MM:SSZ`, with a real Gregorian calendar date.
pub fn parse(text: []const u8) Error!Timestamp {
    if (text.len != 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':' or text[19] != 'Z') return error.InvalidTimestamp;
    const year = try number(text[0..4]);
    const month: u8 = @intCast(try number(text[5..7]));
    const day: u8 = @intCast(try number(text[8..10]));
    const hour: u8 = @intCast(try number(text[11..13]));
    const minute: u8 = @intCast(try number(text[14..16]));
    const second: u8 = @intCast(try number(text[17..19]));
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second };
}

pub fn lessThan(a: Timestamp, b: Timestamp) bool {
    const a_key = [_]u16{ a.year, a.month, a.day, a.hour, a.minute, a.second };
    const b_key = [_]u16{ b.year, b.month, b.day, b.hour, b.minute, b.second };
    for (a_key, b_key) |left, right| {
        if (left != right) return left < right;
    }
    return false;
}

/// Sunday is zero, matching the RFC 822 weekday spelling table below.
pub fn weekday(timestamp: Timestamp) u3 {
    // Howard Hinnant's civil-date conversion, fixed to the proleptic Gregorian
    // calendar. It never consults the host timezone or clock.
    var year: i64 = timestamp.year;
    if (timestamp.month <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const month: i64 = timestamp.month;
    const day: i64 = timestamp.day;
    const shifted_month: i64 = if (month > 2) -3 else 9;
    const doy = @divFloor(153 * (month + shifted_month) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days_since_unix = era * 146097 + doe - 719468;
    return @intCast(@mod(days_since_unix + 4, 7)); // 1970-01-01 was Thursday.
}

pub fn appendRfc822(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, timestamp: Timestamp) !void {
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    try buf.appendSlice(allocator, weekdays[weekday(timestamp)]);
    try buf.appendSlice(allocator, ", ");
    try appendTwo(buf, allocator, timestamp.day);
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, months[timestamp.month - 1]);
    try buf.append(allocator, ' ');
    try appendFour(buf, allocator, timestamp.year);
    try buf.append(allocator, ' ');
    try appendTwo(buf, allocator, timestamp.hour);
    try buf.append(allocator, ':');
    try appendTwo(buf, allocator, timestamp.minute);
    try buf.append(allocator, ':');
    try appendTwo(buf, allocator, timestamp.second);
    try buf.appendSlice(allocator, " GMT");
}

fn appendTwo(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u8) !void {
    try buf.append(allocator, '0' + @as(u8, @intCast(value / 10)));
    try buf.append(allocator, '0' + @as(u8, @intCast(value % 10)));
}

fn appendFour(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try buf.append(allocator, '0' + @as(u8, @intCast((value / 1000) % 10)));
    try buf.append(allocator, '0' + @as(u8, @intCast((value / 100) % 10)));
    try buf.append(allocator, '0' + @as(u8, @intCast((value / 10) % 10)));
    try buf.append(allocator, '0' + @as(u8, @intCast(value % 10)));
}

test "strict timestamp grammar and calendar validation" {
    try std.testing.expect((try parse("2026-07-28T14:30:00Z")).day == 28);
    try std.testing.expect((try parse("2000-02-29T00:00:00Z")).day == 29);
    const invalid = [_][]const u8{
        "2100-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-04-31T00:00:00Z",
        "2026-01-01T24:00:00Z", "2026-01-01T00:60:00Z", "2026-01-01T00:00:60Z",
        "2026-01-01t00:00:00Z", "2026-01-01T00:00:00z", "2026-01-01T00:00:00+00:00",
        "2026-01-01", "2026-01-01T00:00:00.1Z", "2026-01-01T00:00:00Zx",
    };
    for (invalid) |value| try std.testing.expectError(error.InvalidTimestamp, parse(value));
}

test "RFC 822 date uses known UTC weekday" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendRfc822(&out, std.testing.allocator, try parse("2026-07-28T14:30:00Z"));
    try std.testing.expectEqualStrings("Tue, 28 Jul 2026 14:30:00 GMT", out.items);
}
