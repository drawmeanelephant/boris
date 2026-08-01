//! A small Markdown document AST used by the generator.
//!
//! The generator creates typed blocks and inline nodes first, then renders
//! them. That keeps the corpus grammar reviewable and makes each mutation a
//! deliberate change to a known page surface.

const std = @import("std");
const graph = @import("graph.zig");

pub const Style = enum {
    readme,
    reference,
    compact,
};

pub const Inline = union(enum) {
    text: []const u8,
    code: []const u8,
    link: struct { label: []const u8, destination: []const u8 },
    wiki: []const u8,
};

pub const ListItem = struct { inlines: []const Inline };

pub const Block = union(enum) {
    heading: struct { level: u8, inlines: []const Inline },
    paragraph: []const Inline,
    unordered_list: []const ListItem,
    quote: []const Inline,
    code_fence: struct { language: []const u8, body: []const u8 },
    table: struct { headers: []const []const u8, rows: []const []const []const u8 },
    image: struct { alt: []const u8, destination: []const u8 },
    thematic_break: void,
};

pub const Document = struct {
    blocks: std.ArrayList(Block) = .empty,
    owned_source: ?[]u8 = null,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        self.blocks.deinit(allocator);
        if (self.owned_source) |source| allocator.free(source);
        self.* = undefined;
    }
};

pub const Context = struct {
    page: graph.PagePlan,
    id: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    related_id: []const u8,
    related_source: []const u8,
    seed: u64,
    include_path: []const u8 = "includes/common.md",
    has_image: bool = false,
};

fn oneInline(allocator: std.mem.Allocator, value: Inline) ![]const Inline {
    const out = try allocator.alloc(Inline, 1);
    out[0] = value;
    return out;
}

fn twoInlines(allocator: std.mem.Allocator, first: Inline, second: Inline) ![]const Inline {
    const out = try allocator.alloc(Inline, 2);
    out[0] = first;
    out[1] = second;
    return out;
}

fn threeInlines(allocator: std.mem.Allocator, a: Inline, b: Inline, c: Inline) ![]const Inline {
    const out = try allocator.alloc(Inline, 3);
    out[0] = a;
    out[1] = b;
    out[2] = c;
    return out;
}

fn listItem(allocator: std.mem.Allocator, text: []const u8) !ListItem {
    return .{ .inlines = try oneInline(allocator, .{ .text = text }) };
}

pub fn synthetic(allocator: std.mem.Allocator, context: Context, style: Style) !Document {
    var document: Document = .{};
    errdefer document.deinit(allocator);

    try document.blocks.append(allocator, .{ .heading = .{
        .level = 1,
        .inlines = try oneInline(allocator, .{ .text = context.title }),
    } });

    const intro = try allocator.alloc(Inline, 5);
    intro[0] = .{ .text = "This page is a deterministic Boris benchmark document. It belongs to " };
    intro[1] = .{ .wiki = context.related_id };
    intro[2] = .{ .text = " and carries a source link to " };
    intro[3] = .{ .link = .{ .label = "the related page", .destination = context.related_source } };
    intro[4] = .{ .text = "." };
    try document.blocks.append(allocator, .{ .paragraph = intro });

    try document.blocks.append(allocator, .{ .heading = .{
        .level = 2,
        .inlines = try oneInline(allocator, .{ .text = "Overview" }),
    } });

    const overview = try allocator.alloc(Inline, 3);
    overview[0] = .{ .text = "The page seed is " };
    const seed_text = try std.fmt.allocPrint(allocator, "{d}", .{context.seed});
    overview[1] = .{ .code = seed_text };
    overview[2] = .{ .text = "; repeated runs should produce identical bytes and ordering." };
    try document.blocks.append(allocator, .{ .paragraph = overview });

    var items = try allocator.alloc(ListItem, 3);
    items[0] = try listItem(allocator, "Frontmatter is closed and intentionally boring.");
    items[1] = try listItem(allocator, "Graph edges are planned before Markdown rendering.");
    items[2] = try listItem(allocator, "Barbs mutate a valid baseline at named loci.");
    try document.blocks.append(allocator, .{ .unordered_list = items });

    if (style != .compact) {
        try document.blocks.append(allocator, .{ .quote = try oneInline(
            allocator,
            .{ .text = "A benchmark fixture is an explanation of its own shape." },
        ) });
        try document.blocks.append(allocator, .{ .code_fence = .{
            .language = "text",
            .body = "{{include includes/in-code-fence.md}}\n[[literal/example]]\n",
        } });

        const headers = try allocator.alloc([]const u8, 3);
        headers[0] = "surface";
        headers[1] = "mode";
        headers[2] = "determinism";
        const rows = try allocator.alloc([]const []const u8, 2);
        rows[0] = try allocator.dupe([]const u8, &.{ "graph", "planned", "stable" });
        rows[1] = try allocator.dupe([]const u8, &.{ "document", "streamed", "stable" });
        try document.blocks.append(allocator, .{ .table = .{ .headers = headers, .rows = rows } });
    }

    try document.blocks.append(allocator, .{ .paragraph = try threeInlines(
        allocator,
        .{ .text = "The shared fragment is " },
        .{ .text = try std.fmt.allocPrint(allocator, "{{{{include {s}}}}}", .{context.include_path}) },
        .{ .text = "." },
    ) });

    if (context.has_image) {
        try document.blocks.append(allocator, .{ .image = .{
            .alt = "Generated diagram",
            .destination = "index.assets/diagram.svg",
        } });
    }

    try document.blocks.append(allocator, .thematic_break);
    return document;
}

pub fn render(document: Document, writer: *std.Io.Writer) !void {
    for (document.blocks.items, 0..) |block, index| {
        if (index != 0) try writer.writeByte('\n');
        switch (block) {
            .heading => |heading| {
                var i: u8 = 0;
                while (i < heading.level) : (i += 1) try writer.writeByte('#');
                try writer.writeByte(' ');
                try renderInlines(writer, heading.inlines);
                try writer.writeByte('\n');
            },
            .paragraph => |inlines| {
                try renderInlines(writer, inlines);
                try writer.writeByte('\n');
            },
            .unordered_list => |items| {
                for (items) |item| {
                    try writer.writeAll("- ");
                    try renderInlines(writer, item.inlines);
                    try writer.writeByte('\n');
                }
            },
            .quote => |inlines| {
                try writer.writeAll("> ");
                try renderInlines(writer, inlines);
                try writer.writeByte('\n');
            },
            .code_fence => |code| {
                try writer.print("```{s}\n{s}```\n", .{ code.language, code.body });
            },
            .table => |table| {
                try renderTable(writer, table.headers, table.rows);
            },
            .image => |image| {
                try writer.print("![{s}]({s})\n", .{ image.alt, image.destination });
            },
            .thematic_break => try writer.writeAll("---\n"),
        }
    }
}

fn renderInlines(writer: *std.Io.Writer, inlines: []const Inline) !void {
    for (inlines) |value| switch (value) {
        .text => |text| try writer.writeAll(text),
        .code => |code| try writer.print("`{s}`", .{code}),
        .link => |link| try writer.print("[{s}]({s})", .{ link.label, link.destination }),
        .wiki => |target| try writer.print("[[{s}#overview]]", .{target}),
    };
}

fn renderTable(writer: *std.Io.Writer, headers: []const []const u8, rows: []const []const []const u8) !void {
    try writer.writeAll("|");
    for (headers) |header| try writer.print(" {s} |", .{header});
    try writer.writeAll("\n|");
    for (headers) |_| try writer.writeAll(" --- |");
    try writer.writeByte('\n');
    for (rows) |row| {
        try writer.writeByte('|');
        for (row) |cell| try writer.print(" {s} |", .{cell});
        try writer.writeByte('\n');
    }
}

pub const TemplateContext = struct {
    id: []const u8,
    title: []const u8,
    parent: []const u8,
    index: usize,
    seed: u64,
    related: []const u8,
    include: []const u8,
};

/// Expand the intentionally tiny external-template vocabulary, then parse the
/// result into the same block AST used by synthetic documents.
pub fn parseTemplate(allocator: std.mem.Allocator, source: []const u8, context: TemplateContext) !Document {
    var expanded = std.Io.Writer.Allocating.init(allocator);
    defer expanded.deinit();
    var cursor: usize = 0;
    while (cursor < source.len) {
        const open = std.mem.indexOfPos(u8, source, cursor, "{{") orelse {
            try expanded.writer.writeAll(source[cursor..]);
            break;
        };
        try expanded.writer.writeAll(source[cursor..open]);
        const close = std.mem.indexOfPos(u8, source, open + 2, "}}") orelse {
            try expanded.writer.writeAll(source[open..]);
            break;
        };
        const token = source[open + 2 .. close];
        if (std.mem.eql(u8, token, "id")) try expanded.writer.writeAll(context.id) else if (std.mem.eql(u8, token, "title")) try expanded.writer.writeAll(context.title) else if (std.mem.eql(u8, token, "parent")) try expanded.writer.writeAll(context.parent) else if (std.mem.eql(u8, token, "related")) try expanded.writer.writeAll(context.related) else if (std.mem.eql(u8, token, "include")) try expanded.writer.writeAll(context.include) else if (std.mem.eql(u8, token, "index")) try expanded.writer.print("{d}", .{context.index}) else if (std.mem.eql(u8, token, "seed")) try expanded.writer.print("{d}", .{context.seed}) else try expanded.writer.writeAll(source[open .. close + 2]);
        cursor = close + 2;
    }
    const bytes = try expanded.toOwnedSlice();
    errdefer allocator.free(bytes);
    var document = try parseSimpleMarkdown(allocator, bytes);
    document.owned_source = bytes;
    return document;
}

fn parseSimpleMarkdown(allocator: std.mem.Allocator, source: []const u8) !Document {
    var document: Document = .{};
    errdefer document.deinit(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') {
            var level: u8 = 0;
            while (level < line.len and line[level] == '#') : (level += 1) {}
            if (level > 0 and level < line.len and line[level] == ' ') {
                try document.blocks.append(allocator, .{ .heading = .{
                    .level = level,
                    .inlines = try oneInline(allocator, .{ .text = line[level + 1 ..] }),
                } });
                continue;
            }
        }
        if (std.mem.startsWith(u8, line, "> ")) {
            try document.blocks.append(allocator, .{ .quote = try oneInline(allocator, .{ .text = line[2..] }) });
            continue;
        }
        if (std.mem.startsWith(u8, line, "- ")) {
            try document.blocks.append(allocator, .{ .unordered_list = try allocator.dupe(
                ListItem,
                &.{try listItem(allocator, line[2..])},
            ) });
            continue;
        }
        if (std.mem.eql(u8, line, "---")) {
            try document.blocks.append(allocator, .thematic_break);
            continue;
        }
        try document.blocks.append(allocator, .{ .paragraph = try oneInline(allocator, .{ .text = line }) });
    }
    return document;
}

test "synthetic AST renders headings, links, code, tables, and includes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = graph.PagePlan{ .index = 0, .kind = .home, .guide_number = 0, .article_number = 0, .parent_index = null, .seed = 7 };
    var document = try synthetic(a, .{
        .page = page,
        .id = "index",
        .title = "Home",
        .parent = null,
        .related_id = "index",
        .related_source = "index.md",
        .seed = 7,
        .has_image = true,
    }, .readme);
    defer document.deinit(a);

    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try render(document, &out.writer);
    const bytes = try out.toOwnedSlice();
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "# Home") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "{{include includes/common.md}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "![Generated diagram]") != null);
}

test "external template expands into the same AST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var document = try parseTemplate(a, "# {{title}}\n- {{id}}\n", .{
        .id = "guides/demo",
        .title = "Demo",
        .parent = "",
        .index = 2,
        .seed = 99,
        .related = "index",
        .include = "{{include includes/common.md}}",
    });
    defer document.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), document.blocks.items.len);
}
