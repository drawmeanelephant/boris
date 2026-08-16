//! Compiler-owned scaling over Cooklang string quantities (#554).
//!
//! The recipe IR facet keeps authored amounts as text. Classification and
//! exact-rational rewrite come from the pinned Oliver string API
//! (`classifyQuantity` / `parseFactor` / `scaleAmount`, oliver#77). This
//! module is the Boris wrapper: same public types the CLI/editor consume,
//! plus `scaleTimerAmount` (timers never scale). Source `.cook` files are
//! never rewritten.

const std = @import("std");
const oliver = @import("oliver");

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

    fn fromOliver(class: oliver.cooklang.QuantityClass) Class {
        return switch (class) {
            .empty => .empty,
            .scalable => .scalable,
            .fixed => .fixed,
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

/// Classify an authored amount string. Delegates to Oliver
/// `classifyQuantity` (docs/COOKLANG.md §11 on the pin).
pub fn classify(amount: []const u8) Class {
    return Class.fromOliver(oliver.cooklang.classifyQuantity(amount));
}

/// Parse a scale factor. Accepts the same scalable forms as amounts.
/// Zero and a zero denominator are invalid.
pub fn parseFactor(text: []const u8) ScaleError!Factor {
    const parsed = oliver.cooklang_scale.parseFactor(text) catch return error.InvalidFactor;
    return .{ .num = parsed.num, .den = parsed.den };
}

/// Scale one authored amount through Oliver. Scalable amounts become the
/// exact rational product (integer, reduced `num/den`, or terminating
/// decimal for a decimal-family source). Fixed and empty amounts, and
/// overflow, leave `scaled` aliasing `original`.
pub fn scaleAmount(allocator: std.mem.Allocator, amount: []const u8, factor: Factor) ScaleError!ScaledAmount {
    const inner = oliver.cooklang_scale.scaleAmount(allocator, amount, .{
        .num = factor.num,
        .den = factor.den,
    }) catch |err| switch (err) {
        error.InvalidScaleFactor => return error.InvalidFactor,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{
        .class = Class.fromOliver(inner.class),
        .original = inner.original,
        .scaled = inner.scaled,
    };
}

/// Timers are never scaled: cooking time is not linear with yield.
pub fn scaleTimerAmount(amount: []const u8) ScaledAmount {
    const class = classify(amount);
    return .{ .class = class, .original = amount, .scaled = amount };
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
    try std.testing.expectEqual(Class.scalable, classify("1 / 2"));
    try std.testing.expectEqual(Class.scalable, classify("3/4"));
    try std.testing.expectEqual(Class.scalable, classify("1.5"));
    try std.testing.expectEqual(Class.scalable, classify("1 1/2"));
    try std.testing.expectEqual(Class.fixed, classify("1-2"));
    try std.testing.expectEqual(Class.fixed, classify("some"));
    try std.testing.expectEqual(Class.fixed, classify("a pinch"));
    try std.testing.expectEqual(Class.fixed, classify("1/0"));
    try std.testing.expectEqual(Class.fixed, classify("2/"));
    try std.testing.expectEqual(Class.fixed, classify("=1"));
    try std.testing.expectEqual(Class.fixed, classify("02"));
    try std.testing.expectEqual(Class.fixed, classify("1 3/2"));
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

    var decimal = try scaleAmount(allocator, "1.5", triple);
    defer decimal.deinit(allocator);
    try std.testing.expectEqualStrings("4.5", decimal.scaled);
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

    var locked = try scaleAmount(allocator, "=1", double);
    defer locked.deinit(allocator);
    try std.testing.expectEqual(Class.fixed, locked.class);
    try std.testing.expectEqualStrings("=1", locked.scaled);

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
