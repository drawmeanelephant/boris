//! Compiler-owned scaling over Cooklang string quantities (#554).
//!
//! The recipe IR facet keeps authored amounts as text. This module classifies
//! those strings and scales only the ones that are exact rationals. Fixed
//! amounts (`some`, `1-2`) and timers are copied verbatim. Source `.cook`
//! files are never rewritten.

const std = @import("std");

pub const Class = enum {
    empty,
    scalable,
    fixed,

    pub fn jsonName(self: Class) []const u8 {
        return switch (self) {
            .empty => "empty",
            .scalable => "scalable",
            .fixed => "fixed",
        };
    }
};

pub const Factor = struct {
    num: u64,
    den: u64,

    pub fn reduce(self: Factor) Factor {
        const g = gcd(self.num, self.den);
        return .{ .num = self.num / g, .den = self.den / g };
    }
};

pub const ScaleError = error{
    InvalidFactor,
    AmountOverflow,
    OutOfMemory,
};

pub const ScaledAmount = struct {
    class: Class,
    original: []const u8,
    scaled: []const u8,

    pub fn deinit(self: ScaledAmount, allocator: std.mem.Allocator) void {
        if (self.scaled.ptr != self.original.ptr) allocator.free(self.scaled);
    }
};

/// Classify an authored amount string. Leading and trailing ASCII spaces are
/// ignored. The rules are closed:
///
/// - empty → `.empty`
/// - unsigned integer, `a/b` fraction (b ≠ 0), decimal `a.b`, or mixed
///   `a b/c` → `.scalable`
/// - everything else, including ranges (`1-2`) and words (`some`) → `.fixed`
pub fn classify(amount: []const u8) Class {
    const text = std.mem.trim(u8, amount, " \t");
    if (text.len == 0) return .empty;
    if (parseRational(text) != null) return .scalable;
    return .fixed;
}

/// Parse a scale factor. Accepts the same scalable forms as amounts.
/// Zero and a zero denominator are invalid.
pub fn parseFactor(text: []const u8) ScaleError!Factor {
    const rational = parseRational(std.mem.trim(u8, text, " \t")) orelse return error.InvalidFactor;
    if (rational.num == 0) return error.InvalidFactor;
    return rational.reduce();
}

/// Scale one authored amount. Scalable amounts become a reduced integer or
/// `num/den` fraction. Fixed and empty amounts are returned unchanged
/// (the `scaled` slice aliases `original`).
pub fn scaleAmount(allocator: std.mem.Allocator, amount: []const u8, factor: Factor) ScaleError!ScaledAmount {
    const trimmed = std.mem.trim(u8, amount, " \t");
    const class = classify(trimmed);
    if (class != .scalable) {
        return .{ .class = class, .original = amount, .scaled = amount };
    }
    const value = parseRational(trimmed) orelse return error.InvalidFactor;
    const product = mul(value, factor) catch return error.AmountOverflow;
    const reduced = product.reduce();
    const rendered = try renderRational(allocator, reduced);
    return .{ .class = .scalable, .original = amount, .scaled = rendered };
}

/// Timers are never scaled: cooking time is not linear with yield.
pub fn scaleTimerAmount(amount: []const u8) ScaledAmount {
    const class = classify(amount);
    return .{ .class = class, .original = amount, .scaled = amount };
}

fn parseRational(text: []const u8) ?Factor {
    if (parseMixed(text)) |value| return value;
    if (parseFraction(text)) |value| return value;
    if (parseDecimal(text)) |value| return value;
    if (parseInteger(text)) |value| return value;
    return null;
}

fn parseInteger(text: []const u8) ?Factor {
    const n = parseDigits(text) orelse return null;
    return .{ .num = n, .den = 1 };
}

fn parseFraction(text: []const u8) ?Factor {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
    if (slash == 0 or slash + 1 >= text.len) return null;
    if (std.mem.indexOfScalar(u8, text[slash + 1 ..], '/') != null) return null;
    const num = parseDigits(text[0..slash]) orelse return null;
    const den = parseDigits(text[slash + 1 ..]) orelse return null;
    if (den == 0) return null;
    return .{ .num = num, .den = den };
}

fn parseDecimal(text: []const u8) ?Factor {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return null;
    if (std.mem.indexOfScalar(u8, text[dot + 1 ..], '.') != null) return null;
    const whole_text = text[0..dot];
    const frac_text = text[dot + 1 ..];
    if (whole_text.len == 0 and frac_text.len == 0) return null;
    const whole = if (whole_text.len == 0) 0 else parseDigits(whole_text) orelse return null;
    const frac = if (frac_text.len == 0) 0 else parseDigits(frac_text) orelse return null;
    var den: u64 = 1;
    var i: usize = 0;
    while (i < frac_text.len) : (i += 1) {
        den = std.math.mul(u64, den, 10) catch return null;
    }
    const whole_part = std.math.mul(u64, whole, den) catch return null;
    const num = std.math.add(u64, whole_part, frac) catch return null;
    if (den == 0) return null;
    return .{ .num = num, .den = den };
}

fn parseMixed(text: []const u8) ?Factor {
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
    const whole = parseDigits(text[0..space]) orelse return null;
    const rest = std.mem.trim(u8, text[space + 1 ..], " ");
    const frac = parseFraction(rest) orelse return null;
    const whole_part = std.math.mul(u64, whole, frac.den) catch return null;
    const num = std.math.add(u64, whole_part, frac.num) catch return null;
    return .{ .num = num, .den = frac.den };
}

fn parseDigits(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var n: u64 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return null;
        n = std.math.mul(u64, n, 10) catch return null;
        n = std.math.add(u64, n, byte - '0') catch return null;
    }
    return n;
}

fn mul(left: Factor, right: Factor) error{AmountOverflow}!Factor {
    const num = std.math.mul(u64, left.num, right.num) catch return error.AmountOverflow;
    const den = std.math.mul(u64, left.den, right.den) catch return error.AmountOverflow;
    return .{ .num = num, .den = den };
}

fn renderRational(allocator: std.mem.Allocator, value: Factor) error{OutOfMemory}![]u8 {
    if (value.den == 1) return std.fmt.allocPrint(allocator, "{d}", .{value.num});
    return std.fmt.allocPrint(allocator, "{d}/{d}", .{ value.num, value.den });
}

fn gcd(a_in: u64, b_in: u64) u64 {
    var a = a_in;
    var b = b_in;
    while (b != 0) {
        const t = a % b;
        a = b;
        b = t;
    }
    return if (a == 0) 1 else a;
}

test "classify closed amount forms" {
    try std.testing.expectEqual(Class.empty, classify(""));
    try std.testing.expectEqual(Class.empty, classify("   "));
    try std.testing.expectEqual(Class.scalable, classify("2"));
    try std.testing.expectEqual(Class.scalable, classify("400"));
    try std.testing.expectEqual(Class.scalable, classify("1/2"));
    try std.testing.expectEqual(Class.scalable, classify("3/4"));
    try std.testing.expectEqual(Class.scalable, classify("1.5"));
    try std.testing.expectEqual(Class.scalable, classify("1 1/2"));
    try std.testing.expectEqual(Class.fixed, classify("1-2"));
    try std.testing.expectEqual(Class.fixed, classify("some"));
    try std.testing.expectEqual(Class.fixed, classify("a pinch"));
    try std.testing.expectEqual(Class.fixed, classify("1/0"));
    try std.testing.expectEqual(Class.fixed, classify("2/"));
}

test "scale scalable amounts to reduced rationals" {
    const allocator = std.testing.allocator;
    const double = try parseFactor("2");
    var half_tsp = try scaleAmount(allocator, "1/2", double);
    defer half_tsp.deinit(allocator);
    try std.testing.expectEqual(Class.scalable, half_tsp.class);
    try std.testing.expectEqualStrings("1", half_tsp.scaled);

    var four_hundred = try scaleAmount(allocator, "400", double);
    defer four_hundred.deinit(allocator);
    try std.testing.expectEqualStrings("800", four_hundred.scaled);

    var mixed = try scaleAmount(allocator, "1 1/2", double);
    defer mixed.deinit(allocator);
    try std.testing.expectEqualStrings("3", mixed.scaled);

    const triple = try parseFactor("3");
    var third = try scaleAmount(allocator, "1/2", triple);
    defer third.deinit(allocator);
    try std.testing.expectEqualStrings("3/2", third.scaled);
}

test "fixed and empty amounts are copied, not rounded" {
    const allocator = std.testing.allocator;
    const double = try parseFactor("2");
    var some = try scaleAmount(allocator, "some", double);
    defer some.deinit(allocator);
    try std.testing.expectEqual(Class.fixed, some.class);
    try std.testing.expectEqualStrings("some", some.scaled);
    try std.testing.expect(some.scaled.ptr == some.original.ptr);

    var range = try scaleAmount(allocator, "1-2", double);
    defer range.deinit(allocator);
    try std.testing.expectEqual(Class.fixed, range.class);
    try std.testing.expectEqualStrings("1-2", range.scaled);

    var empty = try scaleAmount(allocator, "", double);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(Class.empty, empty.class);
}

test "timers are never scaled" {
    const timer = scaleTimerAmount("9");
    try std.testing.expectEqual(Class.scalable, timer.class);
    try std.testing.expectEqualStrings("9", timer.scaled);
}

test "factors reject zero and junk" {
    try std.testing.expectError(error.InvalidFactor, parseFactor("0"));
    try std.testing.expectError(error.InvalidFactor, parseFactor("0/1"));
    try std.testing.expectError(error.InvalidFactor, parseFactor("1-2"));
    try std.testing.expectError(error.InvalidFactor, parseFactor("some"));
    const half = try parseFactor("1/2");
    try std.testing.expectEqual(@as(u64, 1), half.num);
    try std.testing.expectEqual(@as(u64, 2), half.den);
}
