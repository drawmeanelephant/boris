//! Cooklang menu profile: a semantic day/meal view over a parsed Recipe.
//!
//! Per the official conventions ("Menu Files",
//! https://cooklang.org/docs/conventions/; provenance in
//! docs/CLEANROOM.md session 23, policy in docs/COOKLANG.md §12), a
//! `.menu` file is a **valid Cooklang file** that uses sections for
//! days (or meals) and recipe references to compose a plan. Oliver
//! therefore parses `.menu` content with the ordinary Cooklang frontend
//! — there is no second parser — and this module is the explicit
//! convenience layer that exposes the menu *structure* semantically:
//!
//!     Menu { days: []Day }
//!     Day  { name, date: ?Date, references: []Reference }
//!     Reference { path, quantity, units }
//!
//! Rules (all pinned by tests and docs/COOKLANG.md §12):
//!
//! - Every top-level section is a day, in order; sections may carry an
//!   ISO date in their title (`Day 1 (2026-03-07)`). The date is
//!   recognized only as a trailing `(YYYY-MM-DD)` group with a valid
//!   month (1–12) and day (1–31); anything else is part of the plain
//!   name, conservatively.
//! - A day's recipe references are collected in step order, each with
//!   its path and its scaling directive (`{2}`, `{}`, `{4%servings}`)
//!   preserved as source text. References are never deduplicated — each
//!   occurrence is a directive — and never resolved (filesystem
//!   resolution is a consumer concern; Oliver parses the path only).
//! - Non-section top-level blocks are not part of the menu view
//!   (a well-formed `.menu` file has none); they remain visible in the
//!   Recipe for consumers that want them.
//!
//! Ownership: `menuView` builds the view into a fresh arena owned by
//! the returned `Menu` (the day/reference arrays live there); every
//! name/path/quantity/units slice borrows the parsed Recipe, so the
//! Recipe and its source bytes must outlive the Menu.
//!
//! `writeMenu` renders a deterministic plain-text dump of the view
//! (one line per day: `name (YYYY-MM-DD): path{quantity%units} …`),
//! shared by the `oliver menu --from cooklang` CLI and the fixtures.
//! No HTML escaping is performed — it is a text serialization of the
//! structure, like the canonical Cooklang serializer.

const std = @import("std");
const cooklang = @import("cooklang.zig");

/// A calendar date (year zero-padded to four digits).
pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

/// One recipe reference in a day, with its scaling directive preserved
/// as source text (`{2}` -> quantity "2"; `{}` -> quantity ""; null
/// quantity means no braces at all).
pub const Reference = struct {
    path: []const u8,
    quantity: ?[]const u8,
    units: ?[]const u8,
};

/// One day (or meal): a section, with an optional ISO date extracted
/// from its title and its recipe references in order.
pub const Day = struct {
    name: []const u8,
    date: ?Date,
    references: []const Reference,
};

/// The semantic menu view. Owns the day/reference arrays (arena); the
/// string payloads borrow the Recipe the view was built from.
pub const Menu = struct {
    days: []Day,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Menu) void {
        self.arena.deinit();
    }
};

/// Builds the menu view over a parsed Recipe (any Cooklang parse whose
/// top-level blocks are sections — `.menu` files are valid Cooklang).
/// The Recipe must outlive the returned Menu.
pub fn menuView(allocator: std.mem.Allocator, recipe: *const cooklang.Recipe) !Menu {
    var out = Menu{
        .days = &.{},
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer out.deinit();
    const a = out.arena.allocator();

    var days = std.ArrayList(Day).empty;
    defer days.deinit(a);
    for (recipe.blocks) |block| {
        if (block != .section) continue; // not part of the menu view
        const section = block.section;
        const title = dayTitle(section.name);

        var refs = std.ArrayList(Reference).empty;
        defer refs.deinit(a);
        for (section.blocks) |b| {
            if (b != .step) continue;
            for (b.step.parts) |part| {
                if (part != .ingredient) continue;
                const ig = part.ingredient;
                if (!ig.is_recipe_reference) continue;
                try refs.append(a, .{
                    .path = ig.name,
                    .quantity = ig.quantity,
                    .units = ig.units,
                });
            }
        }
        try days.append(a, .{
            .name = title.name,
            .date = title.date,
            .references = try refs.toOwnedSlice(a),
        });
    }
    out.days = try days.toOwnedSlice(a);
    return out;
}

/// Writes the deterministic plain-text menu dump: one line per day,
/// `name (YYYY-MM-DD): path{quantity%units} path{...}`. Dates are
/// zero-padded; references are canonical token text (`{2}`, `{}`,
/// `{4%servings}`).
pub fn writeMenu(writer: anytype, menu: *const Menu) !void {
    for (menu.days) |day| {
        try writer.writeAll(day.name);
        if (day.date) |d| {
            var buf: [16]u8 = undefined;
            // 16 bytes always suffice: ` (9999-99-99)` is 14.
            const ds = std.fmt.bufPrint(&buf, " ({d:0>4}-{d:0>2}-{d:0>2})", .{ d.year, d.month, d.day }) catch unreachable;
            try writer.writeAll(ds);
        }
        try writer.writeAll(": ");
        var first = true;
        for (day.references) |ref| {
            if (!first) try writer.writeAll(" ");
            first = false;
            try writer.writeAll(ref.path);
            if (ref.quantity) |q| {
                try writer.writeAll("{");
                try writer.writeAll(q);
                if (ref.units) |u| {
                    if (u.len > 0) {
                        try writer.writeAll("%");
                        try writer.writeAll(u);
                    }
                }
                try writer.writeAll("}");
            }
        }
        try writer.writeAll("\n");
    }
}

/// Splits a section title into its day name and an optional ISO date.
/// The date is recognized only as a trailing `(YYYY-MM-DD)` group with
/// a valid month (1–12) and day (1–31); any other shape leaves the
/// whole title as the name.
fn dayTitle(name: []const u8) struct { name: []const u8, date: ?Date } {
    if (name.len >= 12 and name[name.len - 1] == ')') {
        const end = name.len - 1;
        if (std.mem.lastIndexOfScalar(u8, name, '(')) |open| {
            if (parseDate(name[open + 1 .. end])) |date| {
                return .{ .name = std.mem.trim(u8, name[0..open], " \t"), .date = date };
            }
        }
    }
    return .{ .name = name, .date = null };
}

/// `YYYY-MM-DD` exactly, with a valid month and day.
fn parseDate(text: []const u8) ?Date {
    if (text.len != 10) return null;
    if (text[4] != '-' or text[7] != '-') return null;
    const year = parseDigitsU16(text[0..4]) orelse return null;
    const month = parseDigitsU8(text[5..7]) orelse return null;
    const day = parseDigitsU8(text[8..10]) orelse return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    return .{ .year = year, .month = month, .day = day };
}

fn parseDigitsU16(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseUnsigned(u16, text, 10) catch null;
}

fn parseDigitsU8(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseUnsigned(u8, text, 10) catch null;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

/// Parses, views, and dumps the menu text (the observable contract).
fn menuText(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try cooklang.parse(allocator, input, .{});
    defer result.deinit();
    var menu = try menuView(allocator, &result.recipe);
    defer menu.deinit();
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try writeMenu(&aw.writer, &menu);
    var list = aw.toArrayList();
    return try list.toOwnedSlice(allocator);
}

test "cooklang menu: sections become days with names and ISO dates" {
    var result = try cooklang.parse(std.testing.allocator, "= Monday\n@./mains/pasta carbonara{2}\n\n== Day 1 (2026-03-07) ==\n@./breakfast/shakshuka{4%servings}", .{});
    defer result.deinit();
    var menu = try menuView(std.testing.allocator, &result.recipe);
    defer menu.deinit();
    try std.testing.expectEqual(@as(usize, 2), menu.days.len);
    try std.testing.expectEqualStrings("Monday", menu.days[0].name);
    try std.testing.expect(menu.days[0].date == null);
    try std.testing.expectEqualStrings("Day 1", menu.days[1].name);
    const d = menu.days[1].date.?;
    try std.testing.expectEqual(@as(u16, 2026), d.year);
    try std.testing.expectEqual(@as(u8, 3), d.month);
    try std.testing.expectEqual(@as(u8, 7), d.day);
}

test "cooklang menu: reference directives carry quantity and units" {
    var result = try cooklang.parse(std.testing.allocator, "= Monday\n@./mains/pasta carbonara{2} \\\n@./sides/green salad{} and @./sauces/Hollandaise{150%g}", .{});
    defer result.deinit();
    var menu = try menuView(std.testing.allocator, &result.recipe);
    defer menu.deinit();
    const refs = menu.days[0].references;
    try std.testing.expectEqual(@as(usize, 3), refs.len);
    try std.testing.expectEqualStrings("./mains/pasta carbonara", refs[0].path);
    try std.testing.expectEqualStrings("2", refs[0].quantity.?);
    try std.testing.expect(refs[0].units.?.len == 0); // no `%` segment
    try std.testing.expectEqualStrings("./sides/green salad", refs[1].path);
    try std.testing.expectEqualStrings("", refs[1].quantity.?);
    try std.testing.expectEqualStrings("./sauces/Hollandaise", refs[2].path);
    try std.testing.expectEqualStrings("150", refs[2].quantity.?);
    try std.testing.expectEqualStrings("g", refs[2].units.?);
}

test "cooklang menu: date extraction is conservative" {
    // Recognized: a trailing, valid `(YYYY-MM-DD)`.
    try std.testing.expectEqualStrings("Day 1", dayTitle("Day 1 (2026-03-07)").name);
    try std.testing.expect(dayTitle("Day 1 (2026-03-07)").date != null);
    // Invalid month/day, wrong widths, and trailing junk stay names.
    try std.testing.expect(dayTitle("Day 1 (2026-13-07)").date == null);
    try std.testing.expect(dayTitle("Day 1 (2026-03-32)").date == null);
    try std.testing.expect(dayTitle("Day 1 (2026-3-7)").date == null);
    try std.testing.expect(dayTitle("Day 1 (2026-03-07) x").date == null);
    try std.testing.expect(dayTitle("Day 1 (2026-03-07)(notes)").date == null);
    try std.testing.expect(dayTitle("Day (2026-03-07) 1").date == null);
    try std.testing.expect(dayTitle("2026-03-07").date == null);
    // A lone date is a nameless day with a date.
    const lone = dayTitle("(2026-03-07)");
    try std.testing.expectEqualStrings("", lone.name);
    try std.testing.expect(lone.date != null);
}

test "cooklang menu: non-section top-level blocks are ignored" {
    const text = try menuText(std.testing.allocator, "Intro step, not a day.\n\n= Monday\n@./x{2}");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Monday: ./x{2}\n", text);
}

test "cooklang menu: empty and reference-less inputs" {
    const a = try menuText(std.testing.allocator, "");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("", a);

    const b = try menuText(std.testing.allocator, "= Monday\n\nJust some text, no references.");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("Monday: \n", b);
}

test "cooklang menu: writeMenu matches the conventions example" {
    const input =
        "= Monday\n@./mains/pasta carbonara{2} \\\n@./sides/green salad{}\n\n" ++
        "= Tuesday\n@./mains/chicken stir fry{4} \\\n@./sides/steamed rice{4}\n\n" ++
        "= Wednesday\n@./soups/minestrone{6} \\\n@./breads/focaccia{1}\n\n" ++
        "== Day 1 (2026-03-07) ==\n@./breakfast/shakshuka{4%servings}\n\n" ++
        "== Day 2 (2026-03-08) ==\n@./mains/chicken stir fry{4%servings}";
    const text = try menuText(std.testing.allocator, input);
    defer std.testing.allocator.free(text);
    const expected =
        "Monday: ./mains/pasta carbonara{2} ./sides/green salad{}\n" ++
        "Tuesday: ./mains/chicken stir fry{4} ./sides/steamed rice{4}\n" ++
        "Wednesday: ./soups/minestrone{6} ./breads/focaccia{1}\n" ++
        "Day 1 (2026-03-07): ./breakfast/shakshuka{4%servings}\n" ++
        "Day 2 (2026-03-08): ./mains/chicken stir fry{4%servings}\n";
    try std.testing.expectEqualStrings(expected, text);
}
