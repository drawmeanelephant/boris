//! Cooklang HTML rendering policy.
//!
//! This is Oliver's own deterministic HTML vocabulary for generic
//! publication — **not** a "Cooklang-conformant" output: the Cooklang
//! specification defines recipe semantics, not an HTML vocabulary, and
//! no conformance claim is made (docs/COOKLANG.md §7).
//!
//! The policy preserves the Recipe's semantic distinctions with semantic
//! elements, classes, and data attributes:
//!
//!     <article class="recipe">
//!       <section class="ingredients">        one entry per distinct
//!         <h2>Ingredients</h2>                ingredient (first
//!         <ul><li class="ingredient" data-quantity="200" data-units="g">
//!           <span class="quantity">200 g</span> flour</li></ul>
//!       </section>
//!       <section><h2>Dough</h2>…</section>     sections (no <h2> when
//!       <ol class="steps"><li>…</li></ol>      the name is empty)
//!       <aside class="note">…</aside>          notes
//!       <span class="ingredient" data-quantity="200" data-units="g">flour</span>
//!       <span class="preparation">grated</span>
//!       <span class="cookware" data-quantity="2">pot</span>
//!       <time class="timer" data-quantity="25" data-units="minutes"
//!             datetime="PT25M">25 minutes</time>
//!       <span class="recipe-ref" data-ref="./sauces/Hollandaise">./sauces/Hollandaise</span>
//!
//! Ingredients index: every ingredient (and recipe reference) in the
//! recipe appears once, in order of first appearance; distinct names are
//! exact and case-sensitive, and the first occurrence's quantity, units,
//! and preparation are shown. The index is a deterministic summary for
//! generic publication — aggregating quantities or building shopping
//! lists is ecosystem logic Oliver deliberately does not own. Timers
//! render as `<time>` with an ISO-8601 `datetime` (`PT25M`) whenever the
//! quantity is a whole number and the unit is a recognized
//! day/hour/minute/second form (case-insensitive); everything else keeps
//! the `data-quantity`/`data-units` contract without `datetime`.
//!
//! Text and attribute values are HTML-escaped (`&`, `<`, `>`, `"`), and
//! NUL (U+0000) is replaced with U+FFFD like the shared renderer
//! (docs/ARCHITECTURE.md), so the XHTML profile stays well-formed even
//! for hostile input. Quantities render as their trimmed source text;
//! `data-quantity` is emitted only when the token carried an explicit
//! non-empty quantity, and `data-units` only when units are present.
//! Recipe references stay
//! unresolvable data (`data-ref`) — Oliver never resolves paths. YAML
//! front matter is not rendered here; metadata presentation is a
//! consumer concern.

const std = @import("std");
const cooklang = @import("cooklang.zig");
const html_mod = @import("html.zig");

/// The serializer output profile; shared with the Document renderer
/// (docs/XHTML.md). Under `.xhtml`, the Recipe's HTML vocabulary is
/// serialized XML-compatibly (void elements use `<br />`); all text and
/// attribute values are already escaped for both profiles.
pub const OutputProfile = html_mod.OutputProfile;

pub const RenderOptions = struct {
    /// The output profile: `.html` (default) or `.xhtml`.
    profile: OutputProfile = .html,
};

pub fn render(gpa: std.mem.Allocator, writer: anytype, recipe: *const cooklang.Recipe, options: RenderOptions) !void {
    try writer.writeAll("<article class=\"recipe\">\n");
    try writeIngredientsIndex(gpa, writer, recipe.blocks);
    try renderBlocks(writer, recipe.blocks, options.profile);
    try writer.writeAll("</article>\n");
}

// ---------------------------------------------------------------------------
// Ingredients index.
// ---------------------------------------------------------------------------

const IndexItem = struct {
    name: []const u8,
    quantity: ?[]const u8,
    units: ?[]const u8,
    preparation: ?[]const u8,
    is_recipe_reference: bool,
};

/// Writes the ingredients index (once per distinct name, in first-
/// appearance order, recursing into sections). Nothing is written when
/// the recipe has no ingredient or reference tokens.
fn writeIngredientsIndex(gpa: std.mem.Allocator, writer: anytype, blocks: []const cooklang.Block) !void {
    var items = std.ArrayList(IndexItem).empty;
    defer items.deinit(gpa);
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    try collectIngredients(gpa, blocks, &items, &seen);
    if (items.items.len == 0) return;

    try writer.writeAll("<section class=\"ingredients\">\n<h2>Ingredients</h2>\n<ul>\n");
    for (items.items) |item| {
        if (item.is_recipe_reference) {
            try writer.writeAll("<li class=\"recipe-ref\" data-ref=\"");
            try escapeInto(writer, item.name, true);
            try writer.writeAll("\">");
            try escapeInto(writer, item.name, false);
            try writer.writeAll("</li>\n");
            continue;
        }
        try writer.writeAll("<li class=\"ingredient\"");
        try writeQuantity(writer, item.quantity, item.units);
        try writer.writeAll(">");
        if (item.quantity) |q| {
            if (q.len > 0) {
                try writer.writeAll("<span class=\"quantity\">");
                try escapeInto(writer, q, false);
                if (item.units) |u| {
                    if (u.len > 0) {
                        try writer.writeAll(" ");
                        try escapeInto(writer, u, false);
                    }
                }
                try writer.writeAll("</span> ");
            }
        }
        try escapeInto(writer, item.name, false);
        if (item.preparation) |prep| {
            try writer.writeAll(" <span class=\"preparation\">");
            try escapeInto(writer, prep, false);
            try writer.writeAll("</span>");
        }
        try writer.writeAll("</li>\n");
    }
    try writer.writeAll("</ul>\n</section>\n");
}

fn collectIngredients(
    gpa: std.mem.Allocator,
    blocks: []const cooklang.Block,
    items: *std.ArrayList(IndexItem),
    seen: *std.StringHashMap(void),
) !void {
    for (blocks) |block| {
        switch (block) {
            .step => |step| {
                for (step.parts) |part| {
                    if (part != .ingredient) continue;
                    const ig = part.ingredient;
                    if (seen.contains(ig.name)) continue;
                    try seen.put(ig.name, {});
                    try items.append(gpa, .{
                        .name = ig.name,
                        .quantity = ig.quantity,
                        .units = ig.units,
                        .preparation = ig.preparation,
                        .is_recipe_reference = ig.is_recipe_reference,
                    });
                }
            },
            .note => {},
            .section => |section| try collectIngredients(gpa, section.blocks, items, seen),
        }
    }
}

// ---------------------------------------------------------------------------
// Blocks and parts.
// ---------------------------------------------------------------------------

/// Renders a run of blocks, opening one `<ol class="steps">` for each
/// contiguous run of steps (notes and sections interrupt the run).
fn renderBlocks(writer: anytype, blocks: []const cooklang.Block, profile: OutputProfile) !void {
    var ol_open = false;
    for (blocks) |block| {
        switch (block) {
            .step => |step| {
                if (!ol_open) {
                    try writer.writeAll("<ol class=\"steps\">\n");
                    ol_open = true;
                }
                try writer.writeAll("<li>");
                // Text parts carry their own source spacing, so parts
                // render adjacent without a synthetic separator.
                for (step.parts) |part| try renderPart(writer, part, profile);
                try writer.writeAll("</li>\n");
            },
            .note => |note| {
                if (ol_open) {
                    try writer.writeAll("</ol>\n");
                    ol_open = false;
                }
                try writer.writeAll("<aside class=\"note\">");
                try escapeInto(writer, note.text, false);
                try writer.writeAll("</aside>\n");
            },
            .section => |section| {
                if (ol_open) {
                    try writer.writeAll("</ol>\n");
                    ol_open = false;
                }
                try writer.writeAll("<section>\n");
                // An unnamed section (`= `) gets no empty heading.
                if (section.name.len > 0) {
                    try writer.writeAll("<h2>");
                    try escapeInto(writer, section.name, false);
                    try writer.writeAll("</h2>\n");
                }
                try renderBlocks(writer, section.blocks, profile);
                try writer.writeAll("</section>\n");
            },
        }
    }
    if (ol_open) try writer.writeAll("</ol>\n");
}

fn renderPart(writer: anytype, part: cooklang.Part, profile: OutputProfile) !void {
    switch (part) {
        .text => |t| try escapeInto(writer, t.text, false),
        .line_break => try writer.writeAll(if (profile == .xhtml) "<br />" else "<br>"),
        .ingredient => |ig| {
            if (ig.is_recipe_reference) {
                try writer.writeAll("<span class=\"recipe-ref\" data-ref=\"");
                try escapeInto(writer, ig.name, true);
                try writer.writeAll("\">");
                try escapeInto(writer, ig.name, false);
                try writer.writeAll("</span>");
                return;
            }
            try writer.writeAll("<span class=\"ingredient\"");
            try writeQuantity(writer, ig.quantity, ig.units);
            try writer.writeAll(">");
            try escapeInto(writer, ig.name, false);
            if (ig.preparation) |prep| {
                try writer.writeAll(" <span class=\"preparation\">");
                try escapeInto(writer, prep, false);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("</span>");
        },
        .cookware => |cw| {
            try writer.writeAll("<span class=\"cookware\"");
            try writeQuantity(writer, cw.quantity, null);
            try writer.writeAll(">");
            try escapeInto(writer, cw.name, false);
            try writer.writeAll("</span>");
        },
        .timer => |tm| {
            try writer.writeAll("<time class=\"timer\"");
            try writeQuantity(writer, tm.quantity, tm.units);
            var dur_buf: [32]u8 = undefined;
            if (tm.quantity) |q| {
                if (isoDuration(q, tm.units, &dur_buf)) |dur| {
                    try writer.writeAll(" datetime=\"");
                    try writer.writeAll(dur);
                    try writer.writeAll("\"");
                }
            }
            try writer.writeAll(">");
            if (tm.name.len > 0) {
                // Named timer: the name, plus the duration in parens
                // when one was given (`~eggs{3%minutes}`).
                try escapeInto(writer, tm.name, false);
                if (tm.quantity) |q| {
                    if (q.len > 0) {
                        try writer.writeAll(" (");
                        try escapeInto(writer, q, false);
                        if (tm.units) |u| {
                            if (u.len > 0) {
                                try writer.writeAll(" ");
                                try escapeInto(writer, u, false);
                            }
                        }
                        try writer.writeAll(")");
                    }
                }
            } else {
                // Unnamed timer: show the quantity and units as text.
                if (tm.quantity) |q| {
                    if (q.len > 0) {
                        try escapeInto(writer, q, false);
                        try writer.writeAll(" ");
                    }
                }
                if (tm.units) |u| {
                    if (u.len > 0) try escapeInto(writer, u, false);
                }
            }
            try writer.writeAll("</time>");
        },
    }
}

/// Writes the `data-quantity`/`data-units` attributes for a token,
/// omitting empty values (no braces, or empty braces).
fn writeQuantity(writer: anytype, quantity: ?[]const u8, units: ?[]const u8) !void {
    if (quantity) |q| {
        if (q.len > 0) {
            try writer.writeAll(" data-quantity=\"");
            try escapeInto(writer, q, true);
            try writer.writeAll("\"");
        }
    }
    if (units) |u| {
        if (u.len > 0) {
            try writer.writeAll(" data-units=\"");
            try escapeInto(writer, u, true);
            try writer.writeAll("\"");
        }
    }
}

/// The ISO-8601 duration for a whole-number timer quantity with a
/// recognized unit, or null (no `datetime` attribute). Recognized units
/// are days, hours, minutes, and seconds with common singular/plural
/// and abbreviation forms, matched case-insensitively. Non-integer
/// quantities (fractions, decimals) are deliberately excluded — only
/// exact whole durations get machine-readable time.
fn isoDuration(quantity: []const u8, units: ?[]const u8, buf: []u8) ?[]const u8 {
    const q = cooklang.parseQuantity(quantity) orelse return null;
    const n: u64 = switch (q) {
        .int => |v| @intCast(v),
        else => return null,
    };
    const u = units orelse return null;
    const unit = std.mem.trim(u8, u, " \t");
    if (unitsEqual(unit, "day") or unitsEqual(unit, "days")) {
        return std.fmt.bufPrint(buf, "P{d}D", .{n}) catch null;
    }
    if (unitsEqual(unit, "hour") or unitsEqual(unit, "hours") or
        unitsEqual(unit, "hr") or unitsEqual(unit, "hrs") or unitsEqual(unit, "h"))
    {
        return std.fmt.bufPrint(buf, "PT{d}H", .{n}) catch null;
    }
    if (unitsEqual(unit, "minute") or unitsEqual(unit, "minutes") or
        unitsEqual(unit, "min") or unitsEqual(unit, "mins") or unitsEqual(unit, "m"))
    {
        return std.fmt.bufPrint(buf, "PT{d}M", .{n}) catch null;
    }
    if (unitsEqual(unit, "second") or unitsEqual(unit, "seconds") or
        unitsEqual(unit, "sec") or unitsEqual(unit, "secs") or unitsEqual(unit, "s"))
    {
        return std.fmt.bufPrint(buf, "PT{d}S", .{n}) catch null;
    }
    return null;
}

fn unitsEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Escapes `&`, `<`, `>`, NUL (U+0000 → U+FFFD), and `"` for attribute
/// contexts into `writer`. The NUL replacement mirrors the shared
/// renderer's text-escaping policy (docs/ARCHITECTURE.md): the parser
/// deliberately preserves NUL in payloads (docs/COOKLANG.md §4), so it
/// must be neutralized here, and U+FFFD is a valid XML character, so the
/// XHTML profile stays well-formed (docs/XHTML.md).
fn escapeInto(writer: anytype, text: []const u8, attribute: bool) !void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const rep: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => if (attribute) "&quot;" else null,
            0 => "\xEF\xBF\xBD", // U+FFFD
            else => null,
        };
        if (rep) |r| {
            try writer.writeAll(text[start..i]);
            try writer.writeAll(r);
            start = i + 1;
        }
    }
    try writer.writeAll(text[start..]);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

/// Parses and renders `input` to an owned buffer.
fn renderT(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try cooklang.parse(allocator, input, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try render(allocator, &aw.writer, &result.recipe, .{});
    var list = aw.toArrayList();
    return try list.toOwnedSlice(allocator);
}

/// Convenience: isoDuration against a stack buffer.
fn durT(quantity: []const u8, units: ?[]const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    return isoDuration(quantity, units, &buf);
}

test "cooklang html: ISO-8601 timer durations" {
    // Recognized units, plurals, and abbreviations (case-insensitive).
    try std.testing.expectEqualStrings("PT25M", durT("25", "minutes").?);
    try std.testing.expectEqualStrings("PT25M", durT("25", "Minutes").?);
    try std.testing.expectEqualStrings("PT25M", durT("25", "min").?);
    try std.testing.expectEqualStrings("P2D", durT("2", "days").?);
    try std.testing.expectEqualStrings("PT3H", durT("3", "hour").?);
    try std.testing.expectEqualStrings("PT90S", durT("90", "s").?);
    try std.testing.expectEqualStrings("PT1M", durT("1", "m").?);
    // Non-integer quantities and unknown units get no datetime.
    try std.testing.expect(durT("1/2", "hour") == null);
    try std.testing.expect(durT("0.5", "minutes") == null);
    try std.testing.expect(durT("25", "cups") == null);
    try std.testing.expect(durT("25", null) == null);
    try std.testing.expect(durT("two", "minutes") == null);
}

test "cooklang html: richer policy structure" {
    const html = try renderT(std.testing.allocator, "= Dough\n\nMix @flour{200%g} and @cheese{100%g}(grated).\n\n== Filling ==\nCombine @cheese{50%g} with @./sauces/Hollandaise{150%g}, season with @salt, and simmer for ~{25%minutes}, then ~eggs{3%minutes}.");
    defer std.testing.allocator.free(html);

    // Ingredients index: dedup by name (cheese once, first occurrence),
    // recipe references included, quantity span + preparation visible.
    try std.testing.expect(std.mem.indexOf(u8, html, "<section class=\"ingredients\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>Ingredients</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"quantity\">200 g</span> flour") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"quantity\">100 g</span> cheese <span class=\"preparation\">grated</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<li class=\"recipe-ref\" data-ref=\"./sauces/Hollandaise\">./sauces/Hollandaise</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<li class=\"ingredient\">salt</li>") != null);
    // Dedup: cheese appears once in the index (first occurrence, 100 g) —
    // the later 50 g occurrence stays out of the index (it is still
    // inline in its step).
    try std.testing.expect(std.mem.indexOf(u8, html, "<li class=\"ingredient\" data-quantity=\"50\"") == null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, html, "cheese"));

    // Timers: `<time>` with ISO-8601 datetime; named timer shows name
    // plus the duration.
    try std.testing.expect(std.mem.indexOf(u8, html, "<time class=\"timer\" data-quantity=\"25\" data-units=\"minutes\" datetime=\"PT25M\">25 minutes</time>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<time class=\"timer\" data-quantity=\"3\" data-units=\"minutes\" datetime=\"PT3M\">eggs (3 minutes)</time>") != null);

    // Sections render with their names; unnamed sections omit `<h2>`.
    try std.testing.expect(std.mem.indexOf(u8, html, "<section>\n<h2>Dough</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<section>\n<h2>Filling</h2>") != null);

    // No index when there are no ingredient tokens at all.
    const plain = try renderT(std.testing.allocator, "Boil water, then serve.");
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "class=\"ingredients\"") == null);
}

test "cooklang html: xhtml profile serializes line breaks with the XML void form" {
    // A trailing backslash at end of line is a step line break (Cooklang
    // spec); the HTML profile emits `<br>`, the XHTML profile `<br />`.
    // Everything else is identical (text and attribute values are escaped
    // for both profiles).
    const input = "Chop @onion, then simmer \\\n~{25%minutes}.";
    var result = try cooklang.parse(std.testing.allocator, input, .{});
    defer result.deinit();

    var html_aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer html_aw.deinit();
    try render(std.testing.allocator, &html_aw.writer, &result.recipe, .{});
    var html_out = html_aw.toArrayList();
    defer html_out.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, html_out.items, "simmer <br><time class=\"timer\" data-quantity=\"25\" data-units=\"minutes\" datetime=\"PT25M\">25 minutes</time>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_out.items, "<br />") == null);

    var xhtml_aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer xhtml_aw.deinit();
    try render(std.testing.allocator, &xhtml_aw.writer, &result.recipe, .{ .profile = .xhtml });
    var xhtml_out = xhtml_aw.toArrayList();
    defer xhtml_out.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, xhtml_out.items, "simmer <br /><time class=\"timer\" data-quantity=\"25\" data-units=\"minutes\" datetime=\"PT25M\">25 minutes</time>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xhtml_out.items, "<br>") == null);

    // The only difference is the void serialization: strip `<br />` from
    // the xhtml output and compare with the html output.
    const xhtml_with_br = try std.mem.replaceOwned(u8, std.testing.allocator, xhtml_out.items, "<br />", "<br>");
    defer std.testing.allocator.free(xhtml_with_br);
    try std.testing.expectEqualSlices(u8, html_out.items, xhtml_with_br);
}

test "cooklang html: NUL bytes render as U+FFFD in both profiles" {
    // Regression (issue #56): escapeInto used to pass NUL (U+0000)
    // through into the output — invalid HTML and, under `.xhtml`,
    // non-well-formed XML (U+0000 is not a valid XML character). Both
    // profiles must replace NUL with U+FFFD wherever a payload is
    // written: step text, ingredient/cookware names, quantities, units,
    // notes, and section titles. The parser deliberately preserves NUL
    // in payloads (docs/COOKLANG.md §4), so this exercises every
    // `escapeInto` call site.
    const input = "Add @salt \x00 and @x{1\x00%g} to #pan\x00 for ~{5\x00%min}.\n" ++
        "\n> Note \x00 text.\n" ++
        "\n= Section\x00\nMore \x00 text.\n";
    for ([_]OutputProfile{ .html, .xhtml }) |profile| {
        var result = try cooklang.parse(std.testing.allocator, input, .{});
        defer result.deinit();
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try render(std.testing.allocator, &aw.writer, &result.recipe, .{ .profile = profile });
        var out = aw.toArrayList();
        defer out.deinit(std.testing.allocator);

        // No raw NUL byte anywhere in the fragment.
        try std.testing.expect(std.mem.indexOfScalar(u8, out.items, 0) == null);
        // The replacement U+FFFD (UTF-8 EF BF BD) is present.
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\xEF\xBF\xBD") != null);
    }
}
