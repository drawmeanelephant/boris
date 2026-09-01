//! Canonical Cooklang serializer.
//!
//! Turns a parsed `Recipe` back into valid `.cook` text — deterministically
//! and semantically: `serialize(parse(input))` is a fixed point
//! (re-parsing the output yields the same semantic model), and
//! serializing twice yields identical bytes. This is **canonical
//! serialization, not byte-identical round-tripping**: the source's exact
//! spelling (marker style, whitespace, braces, `== Name ==` vs `= Name`,
//! comment placement) is normalized away by parsing, so the output is
//! one deterministic valid spelling of the same recipe — not the original
//! text (docs/COOKLANG.md §10).
//!
//! Canonical rules:
//!
//! - Blocks render in order, separated by one blank line; the recipe ends
//!   with a single `\n`. Front matter renders first as
//!   `---\n` + raw payload + `---\n` (the payload is passed through
//!   byte-for-byte — it is data, not parsed).
//! - A step renders its parts in order: text verbatim (text values are
//!   already join-normalized by the parser, so a multi-line step without
//!   forced breaks collapses to one line), tokens in canonical form, and
//!   a `line_break` part as `\` + `\n`.
//! - Tokens: `@name`, `#name`, `~name`; braces are emitted exactly when
//!   the model says the token carried them (`quantity != null` — the
//!   empty-braces form `@x{}` is `quantity = ""`, distinct from no
//!   braces at all), with `%units` when units are non-empty; the
//!   shorthand `(preparation)` follows the closing brace verbatim.
//!   Recipe references need no special form: `is_recipe_reference` is a
//!   derived flag from the name shape, and the name renders as-is.
//! - A note renders as `>` plus the note text; a section as `= ` plus
//!   its title, then its blocks.
//!
//! No escaping is needed or performed: text values cannot contain a
//! valid token shape (it would have parsed as one) or a `\` at end of
//! line (it would be a break), so verbatim emission re-parses to the
//! same parts; `-`/`[-`-carrying literal text re-parses identically by
//! the same rules the parser applies.
//!
//! The serializer has no filesystem/network/global-state dependencies,
//! like the rest of the core. See docs/COOKLANG.md §10 for the policy
//! and the canonical-vs-roundtrip distinction.

const std = @import("std");
const cooklang = @import("cooklang.zig");

/// The recursive write functions' error set (writer failures only).
const WriteError = error{WriteFailed};

pub const SerializeOptions = struct {};

/// Writes the canonical Cooklang text for `recipe` to `writer`.
/// `gpa` is accepted for interface parity with the other renderers;
/// the serializer itself allocates nothing.
pub fn serialize(gpa: std.mem.Allocator, writer: anytype, recipe: *const cooklang.Recipe, options: SerializeOptions) !void {
    _ = gpa;
    _ = options;

    if (recipe.frontmatter) |fm| {
        try writer.writeAll("---\n");
        try writer.writeAll(fm.raw);
        try writer.writeAll("---\n");
    }
    try writeBlocks(writer, recipe.blocks, recipe.frontmatter != null);
}

fn writeBlocks(writer: anytype, blocks: []const cooklang.Block, lead_blank: bool) WriteError!void {
    var first = !lead_blank;
    for (blocks) |block| {
        if (!first) try writer.writeAll("\n");
        first = false;
        try writeBlock(writer, block);
    }
}

fn writeBlock(writer: anytype, block: cooklang.Block) WriteError!void {
    switch (block) {
        .step => |step| {
            for (step.parts) |part| try writePart(writer, part);
            try writer.writeAll("\n");
        },
        .note => |note| {
            try writer.writeAll(">");
            if (note.text.len > 0) {
                try writer.writeAll(" ");
                try writer.writeAll(note.text);
            }
            try writer.writeAll("\n");
        },
        .section => |section| {
            try writer.writeAll("= ");
            try writer.writeAll(section.name);
            try writer.writeAll("\n");
            try writeBlocks(writer, section.blocks, true);
        },
    }
}

fn writePart(writer: anytype, part: cooklang.Part) !void {
    switch (part) {
        .text => |t| try writer.writeAll(t.text),
        .line_break => try writer.writeAll("\\\n"),
        .ingredient => |ig| {
            try writer.writeAll("@");
            try writer.writeAll(ig.name);
            try writeQuantity(writer, ig.quantity, ig.units);
            if (ig.preparation) |prep| {
                try writer.writeAll("(");
                try writer.writeAll(prep);
                try writer.writeAll(")");
            }
        },
        .cookware => |cw| {
            try writer.writeAll("#");
            try writer.writeAll(cw.name);
            try writeQuantity(writer, cw.quantity, null);
        },
        .timer => |tm| {
            try writer.writeAll("~");
            try writer.writeAll(tm.name);
            try writeQuantity(writer, tm.quantity, tm.units);
        },
    }
}

/// Writes `{quantity%units}` for a token that carried braces
/// (`quantity != null`); the empty-braces form is `{}`. `units` may be
/// null (cookware) or an empty string; both mean no `%` segment.
fn writeQuantity(writer: anytype, quantity: ?[]const u8, units: ?[]const u8) !void {
    const q = quantity orelse return;
    try writer.writeAll("{");
    try writer.writeAll(q);
    if (units) |u| {
        if (u.len > 0) {
            try writer.writeAll("%");
            try writer.writeAll(u);
        }
    }
    try writer.writeAll("}");
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

/// Serializes `input` to an owned buffer.
fn serializeT(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try cooklang.parse(allocator, input, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try serialize(allocator, &aw.writer, &result.recipe, .{});
    var list = aw.toArrayList();
    return try list.toOwnedSlice(allocator);
}

/// Semantic equality between two recipes, ignoring source spans (the
/// round-trip contract: re-parsing canonical output yields the same
/// model). Spans are intentionally not compared — they are positions in
/// the (different) source texts.
fn expectSemanticEqual(a: *const cooklang.Recipe, b: *const cooklang.Recipe) !void {
    // Front matter: raw payloads must match byte-for-byte.
    if (a.frontmatter) |fa| {
        const fb = b.frontmatter orelse return error.FrontmatterMismatch;
        try std.testing.expectEqualStrings(fa.raw, fb.raw);
    } else if (b.frontmatter != null) {
        return error.FrontmatterMismatch;
    }
    try std.testing.expectEqual(a.blocks.len, b.blocks.len);
    for (a.blocks, b.blocks) |ba, bb| try expectBlockEqual(ba, bb);
}

fn expectBlockEqual(a: cooklang.Block, b: cooklang.Block) !void {
    switch (a) {
        .step => |sa| switch (b) {
            .step => |sb| {
                try std.testing.expectEqual(sa.parts.len, sb.parts.len);
                for (sa.parts, sb.parts) |pa, pb| try expectPartEqual(pa, pb);
            },
            else => return error.BlockMismatch,
        },
        .note => |na| switch (b) {
            .note => |nb| try std.testing.expectEqualStrings(na.text, nb.text),
            else => return error.BlockMismatch,
        },
        .section => |sa| switch (b) {
            .section => |sb| {
                try std.testing.expectEqualStrings(sa.name, sb.name);
                try std.testing.expectEqual(sa.blocks.len, sb.blocks.len);
                for (sa.blocks, sb.blocks) |ba, bb| try expectBlockEqual(ba, bb);
            },
            else => return error.BlockMismatch,
        },
    }
}

fn expectPartEqual(a: cooklang.Part, b: cooklang.Part) !void {
    switch (a) {
        .text => |ta| switch (b) {
            .text => |tb| try std.testing.expectEqualStrings(ta.text, tb.text),
            else => return error.PartMismatch,
        },
        .line_break => switch (b) {
            .line_break => {},
            else => return error.PartMismatch,
        },
        .ingredient => |ia| switch (b) {
            .ingredient => |ib| {
                try std.testing.expectEqualStrings(ia.name, ib.name);
                try std.testing.expectEqualStrings(ia.quantity orelse "", ib.quantity orelse "");
                try std.testing.expectEqualStrings(ia.units orelse "", ib.units orelse "");
                try std.testing.expectEqual(ia.is_recipe_reference, ib.is_recipe_reference);
                try std.testing.expectEqualStrings(ia.preparation orelse "", ib.preparation orelse "");
            },
            else => return error.PartMismatch,
        },
        .cookware => |ca| switch (b) {
            .cookware => |cb| {
                try std.testing.expectEqualStrings(ca.name, cb.name);
                try std.testing.expectEqualStrings(ca.quantity orelse "", cb.quantity orelse "");
            },
            else => return error.PartMismatch,
        },
        .timer => |ta| switch (b) {
            .timer => |tb| {
                try std.testing.expectEqualStrings(ta.name, tb.name);
                try std.testing.expectEqualStrings(ta.quantity orelse "", tb.quantity orelse "");
                try std.testing.expectEqualStrings(ta.units orelse "", tb.units orelse "");
            },
            else => return error.PartMismatch,
        },
    }
}

// The round-trip contract: parse -> serialize -> parse must yield the
// same semantic model as the first parse, and serializing the canonical
// output again must be byte-identical (a fixed point).
test "cooklang serialize: canonical output is a semantic round-trip fixed point" {
    const cases = [_][]const u8{
        "",
        "Add @salt.",
        "Mix @flour{200%g} and @water{100%ml}.",
        "Add @salt, @ground black pepper{} and @potato{2}.",
        "Fry in #frying pan{2} for ~{25%minutes}, then ~rest and ~eggs{3%minutes}.",
        "Pour over with @./sauces/Hollandaise{150%g}.",
        "Mix @onion{1}(peeled and finely chopped) and @garlic{2%cloves}(peeled and minced).",
        "Mash @potato{2%kg} until smooth -- alternatively boil 'em",
        "Slowly add @milk{4%cup} [- TODO -], keep mixing",
        "Lay out @rice paper{1}.\\\nTop with @avocado{1/2}(sliced).",
        "> Don't burn the roux!",
        "= Dough\n\nMix @flour{200%g} and @water{100%ml} together until smooth.\n\n== Filling ==\nCombine @cheese{100%g}(grated) and @spinach{50%g}.",
        "---\ntitle: Pasta\nservings: 2\n---\n\nBoil @pasta{200%g} in salted water.",
        "---\n---\n\nEmpty front matter.",
        "Add @salt and @pepper{1%tsp} and @1000 island dressing{ }.",
        "Keep @red-chilli and @salt and keep @🧂 intact.",
        "Message @ example{} and @{3} and ~ 5 stay literal.",
        "@abc\xFFdef{1} with malformed bytes.",
    };
    for (cases) |input| {
        const once = try serializeT(std.testing.allocator, input);
        defer std.testing.allocator.free(once);

        // Fixed point: serializing the canonical output again is stable.
        const twice = try serializeT(std.testing.allocator, once);
        defer std.testing.allocator.free(twice);
        try std.testing.expectEqualStrings(once, twice);

        // Semantic round trip: the first parse and the canonical re-parse
        // yield the same model (spans ignored).
        var r1 = try cooklang.parse(std.testing.allocator, input, .{});
        defer r1.deinit();
        var r2 = try cooklang.parse(std.testing.allocator, once, .{});
        defer r2.deinit();
        try expectSemanticEqual(&r1.recipe, &r2.recipe);
    }
}

test "cooklang serialize: canonical spellings" {
    const a = try serializeT(std.testing.allocator, "Add @salt, @ground black pepper{} and @potato{2}.");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("Add @salt, @ground black pepper{} and @potato{2}.\n", a);

    // The empty-braces form is preserved (quantity "" vs no braces).
    const b = try serializeT(std.testing.allocator, "@x{}");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("@x{}\n", b);

    // `== Name ==` normalizes to `= Name`; breaks and notes keep shape.
    const c = try serializeT(std.testing.allocator, "== Filling ==\n\n> A note.\n\nLay out @rice paper{1}.\\\nTop with @avocado{1/2}(sliced).");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("= Filling\n\n> A note.\n\nLay out @rice paper{1}.\\\nTop with @avocado{1/2}(sliced).\n", c);

    // Front matter passes through verbatim with a canonical fence pair.
    const d = try serializeT(std.testing.allocator, "---\ntitle: Pasta\n---\n\nBoil @pasta{200%g}.");
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("---\ntitle: Pasta\n---\n\nBoil @pasta{200%g}.\n", d);

    // Empty input serializes to nothing.
    const e = try serializeT(std.testing.allocator, "");
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("", e);
}
