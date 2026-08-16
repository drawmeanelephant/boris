//! Derived Cooklang scale view (#554 S2 / #596).
//!
//! Compiles the selected tree through the ordinary Cooklang load/adapt path,
//! then prints a JSON envelope. Source `.cook` files and `graph.json` are not
//! written. Timers keep their authored amounts.

const std = @import("std");
const cooklang_seam = @import("cooklang_seam.zig");
const json_out = @import("json_out.zig");
const pipeline = @import("pipeline.zig");
const recipe_scale = @import("recipe_scale.zig");

pub const format_name = "boris-recipe-scale";
pub const schema_version = "0.1.0";

/// Scale one compiled page into the contracted view document.
pub fn renderFromCompile(
    gpa: std.mem.Allocator,
    result: *const pipeline.Result,
    page_id: []const u8,
    factor: recipe_scale.Factor,
) ![]u8 {
    const page = findPage(result, page_id) orelse return error.PageNotFound;
    return render(gpa, page.id, page.recipe, factor);
}

fn findPage(result: *const pipeline.Result, page_id: []const u8) ?*const pipeline.PageEntry {
    for (result.pages.items) |*page| {
        if (std.mem.eql(u8, page.id, page_id)) return page;
    }
    return null;
}

pub fn render(
    gpa: std.mem.Allocator,
    page_id: []const u8,
    recipe: cooklang_seam.Recipe,
    factor: recipe_scale.Factor,
) ![]u8 {
    var owned: std.ArrayList(recipe_scale.ScaledAmount) = .empty;
    defer {
        for (owned.items) |item| item.deinit(gpa);
        owned.deinit(gpa);
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"format\": ");
    try json_out.writeString(&buf, gpa, format_name);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"schemaVersion\": ");
    try json_out.writeString(&buf, gpa, schema_version);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"compiler\": ");
    try json_out.writeString(&buf, gpa, pipeline.recipe_compiler_id);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"factor\": { \"num\": ");
    try writeU64(&buf, gpa, factor.num);
    try buf.appendSlice(gpa, ", \"den\": ");
    try writeU64(&buf, gpa, factor.den);
    try buf.appendSlice(gpa, " },\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"page\": ");
    try json_out.writeString(&buf, gpa, page_id);
    try buf.appendSlice(gpa, ",\n");

    try writeIngredientList(&buf, gpa, &owned, recipe.ingredients, factor);
    try writeNamedList(&buf, gpa, &owned, "cookware", recipe.cookware, factor, false);
    try writeNamedList(&buf, gpa, &owned, "timers", recipe.timers, factor, true);

    try buf.appendSlice(gpa, "}\n");
    return buf.toOwnedSlice(gpa);
}

fn writeIngredientList(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    owned: *std.ArrayList(recipe_scale.ScaledAmount),
    items: []const cooklang_seam.Ingredient,
    factor: recipe_scale.Factor,
) !void {
    try json_out.indent(buf, gpa, 1);
    try buf.appendSlice(gpa, "\"ingredients\": [\n");
    for (items, 0..) |item, i| {
        const amount = try takeScaled(gpa, owned, item.quantity.amount, factor, false);
        try json_out.indent(buf, gpa, 2);
        try buf.appendSlice(gpa, "{ \"name\": ");
        try json_out.writeString(buf, gpa, item.name);
        try buf.appendSlice(gpa, ", \"quantity\": ");
        try writeQuantity(buf, gpa, amount, item.quantity.unit);
        try buf.appendSlice(gpa, ", \"preparation\": ");
        try json_out.writeString(buf, gpa, item.preparation);
        try buf.appendSlice(gpa, ", \"recipeRef\": ");
        if (item.isRecipeRef()) {
            try json_out.writeString(buf, gpa, item.recipe_ref);
        } else {
            try json_out.writeNull(buf, gpa);
        }
        try buf.appendSlice(gpa, " }");
        if (i + 1 < items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(buf, gpa, 1);
    try buf.appendSlice(gpa, "],\n");
}

fn writeNamedList(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    owned: *std.ArrayList(recipe_scale.ScaledAmount),
    key: []const u8,
    items: anytype,
    factor: recipe_scale.Factor,
    last: bool,
) !void {
    try json_out.indent(buf, gpa, 1);
    try buf.append(gpa, '"');
    try buf.appendSlice(gpa, key);
    try buf.appendSlice(gpa, "\": [\n");
    const is_timer = std.mem.eql(u8, key, "timers");
    for (items, 0..) |item, i| {
        const amount = try takeScaled(gpa, owned, item.quantity.amount, factor, is_timer);
        try json_out.indent(buf, gpa, 2);
        try buf.appendSlice(gpa, "{ \"name\": ");
        try json_out.writeString(buf, gpa, item.name);
        try buf.appendSlice(gpa, ", \"quantity\": ");
        try writeQuantity(buf, gpa, amount, item.quantity.unit);
        try buf.appendSlice(gpa, " }");
        if (i + 1 < items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(buf, gpa, 1);
    try buf.appendSlice(gpa, if (last) "]\n" else "],\n");
}

fn writeQuantity(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    amount: recipe_scale.ScaledAmount,
    unit: []const u8,
) !void {
    try buf.appendSlice(gpa, "{ \"amount\": { \"class\": ");
    try json_out.writeString(buf, gpa, amount.class.jsonName());
    try buf.appendSlice(gpa, ", \"original\": ");
    try json_out.writeString(buf, gpa, amount.original);
    try buf.appendSlice(gpa, ", \"scaled\": ");
    try json_out.writeString(buf, gpa, amount.scaled);
    try buf.appendSlice(gpa, " }, \"unit\": ");
    try json_out.writeString(buf, gpa, unit);
    try buf.appendSlice(gpa, " }");
}

fn takeScaled(
    gpa: std.mem.Allocator,
    owned: *std.ArrayList(recipe_scale.ScaledAmount),
    amount: []const u8,
    factor: recipe_scale.Factor,
    timer: bool,
) !recipe_scale.ScaledAmount {
    if (timer) return recipe_scale.scaleTimerAmount(amount);
    const scaled = recipe_scale.scaleAmount(gpa, amount, factor) catch |err| switch (err) {
        error.AmountOverflow => return error.AmountOverflow,
        error.InvalidFactor => return error.AmountOverflow,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (scaled.scaled.ptr != scaled.original.ptr) {
        try owned.append(gpa, scaled);
    }
    return scaled;
}

fn writeU64(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u64) !void {
    var tmp: [32]u8 = undefined;
    const piece = try std.fmt.bufPrint(&tmp, "{d}", .{v});
    try buf.appendSlice(gpa, piece);
}

test "carbonara doubled matches the contracted golden" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var compiled = try pipeline.compile(io, gpa, .{
        .content_root = "docs/contracts/fixtures/cooklang-compatibility/content",
        .quiet = true,
        .input_format = .cook,
    });
    defer compiled.deinit();
    try std.testing.expect(compiled.ok);

    const factor = try recipe_scale.parseFactor("2");
    const first = try renderFromCompile(gpa, &compiled, "carbonara", factor);
    defer gpa.free(first);
    const second = try renderFromCompile(gpa, &compiled, "carbonara", factor);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);

    const golden = try std.Io.Dir.cwd().readFileAlloc(io, "docs/contracts/fixtures/cooklang-compatibility/expected/recipe-scale-carbonara-x2.json", gpa, .limited(64 * 1024));
    defer gpa.free(golden);
    try std.testing.expectEqualStrings(golden, first);
}

test "missing page is a view error, not a rewrite" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var compiled = try pipeline.compile(io, gpa, .{
        .content_root = "docs/contracts/fixtures/cooklang-compatibility/content",
        .quiet = true,
        .input_format = .cook,
    });
    defer compiled.deinit();
    try std.testing.expect(compiled.ok);

    const factor = try recipe_scale.parseFactor("2");
    try std.testing.expectError(error.PageNotFound, renderFromCompile(gpa, &compiled, "missing", factor));
}

test "fixed amounts and timers stay put in the view" {
    const gpa = std.testing.allocator;
    const factor = try recipe_scale.parseFactor("2");
    const recipe = cooklang_seam.Recipe{
        .ingredients = &.{
            .{ .name = "salt", .quantity = .{ .amount = "some", .unit = "" } },
            .{ .name = "onions", .quantity = .{ .amount = "1-2", .unit = "" } },
            .{ .name = "water", .quantity = .{ .amount = "1", .unit = "cup" } },
        },
        .cookware = &.{
            .{ .name = "pot", .quantity = .{ .amount = "1", .unit = "" } },
        },
        .timers = &.{
            .{ .name = "simmer", .quantity = .{ .amount = "10", .unit = "minutes" } },
        },
    };

    const bytes = try render(gpa, "fixed", recipe, factor);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"original\": \"some\", \"scaled\": \"some\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"original\": \"1-2\", \"scaled\": \"1-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"original\": \"1\", \"scaled\": \"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"original\": \"10\", \"scaled\": \"10\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"class\": \"fixed\"") != null);
}
