//! Compact deterministic identity and topology planning.

const std = @import("std");
const barbs = @import("barbs.zig");

pub const articles_per_guide: usize = 24;

pub const PageKind = enum {
    home,
    guide,
    article,
};

pub const PagePlan = struct {
    index: usize,
    kind: PageKind,
    guide_number: usize,
    article_number: usize,
    parent_index: ?usize,
    seed: u64,
};

pub const GraphPlan = struct {
    pages: []PagePlan,
    guide_count: usize,

    pub fn init(allocator: std.mem.Allocator, page_count: usize, seed: u64) !GraphPlan {
        if (page_count == 0) return error.InvalidPageCount;
        const pages = try allocator.alloc(PagePlan, page_count);
        var guide_count: usize = 0;

        pages[0] = .{
            .index = 0,
            .kind = .home,
            .guide_number = 0,
            .article_number = 0,
            .parent_index = null,
            .seed = barbs.mix(seed, 0),
        };

        for (pages[1..], 1..) |*page, index| {
            const offset = index - 1;
            const guide = offset / articles_per_guide;
            const article = offset % articles_per_guide;
            const is_guide = article == 0;
            if (is_guide) guide_count += 1;

            page.* = .{
                .index = index,
                .kind = if (is_guide) .guide else .article,
                .guide_number = guide,
                .article_number = article,
                .parent_index = if (is_guide) null else 1 + guide * articles_per_guide,
                .seed = barbs.mix(seed, index),
            };
        }

        return .{ .pages = pages, .guide_count = guide_count };
    }

    pub fn deinit(self: *GraphPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.pages);
        self.* = undefined;
    }

    pub fn id(page: PagePlan, buffer: []u8) ![]const u8 {
        return switch (page.kind) {
            .home => std.fmt.bufPrint(buffer, "index", .{}),
            .guide => std.fmt.bufPrint(buffer, "guides/guide-{d:0>4}", .{page.guide_number}),
            .article => std.fmt.bufPrint(
                buffer,
                "guides/guide-{d:0>4}/article-{d:0>2}",
                .{ page.guide_number, page.article_number },
            ),
        };
    }

    pub fn sourcePath(page: PagePlan, buffer: []u8) ![]const u8 {
        var id_buffer: [160]u8 = undefined;
        const entity_id = try id(page, &id_buffer);
        return std.fmt.bufPrint(buffer, "{s}.md", .{entity_id});
    }

    pub fn title(page: PagePlan, buffer: []u8) ![]const u8 {
        return switch (page.kind) {
            .home => std.fmt.bufPrint(buffer, "Generated Boris Documentation", .{}),
            .guide => std.fmt.bufPrint(buffer, "Guide {d:0>4}", .{page.guide_number}),
            .article => std.fmt.bufPrint(
                buffer,
                "Guide {d:0>4} Article {d:0>2}",
                .{ page.guide_number, page.article_number },
            ),
        };
    }

    pub fn role(page: PagePlan) []const u8 {
        return if (page.parent_index == null) "trunk" else "satellite";
    }

    pub fn relativeSourcePath(self: *const GraphPlan, from: PagePlan, to: PagePlan, buffer: []u8) ![]const u8 {
        _ = self;
        var from_id_buffer: [160]u8 = undefined;
        var to_id_buffer: [160]u8 = undefined;
        const from_id = try id(from, &from_id_buffer);
        const to_id = try id(to, &to_id_buffer);
        const depth = std.mem.count(u8, from_id, "/");

        var writer = std.Io.Writer.fixed(buffer);
        var i: usize = 0;
        while (i < depth) : (i += 1) try writer.writeAll("../");
        try writer.print("{s}.md", .{to_id});
        return writer.buffered();
    }

    pub fn targetForPage(self: *const GraphPlan, page: PagePlan) PagePlan {
        if (self.pages.len <= 1) return page;
        const target = (page.index + 1) % self.pages.len;
        return self.pages[target];
    }

    pub fn applyGraphBarbs(self: *GraphPlan, assignments: []const barbs.Assignment) void {
        for (assignments) |assignment| switch (assignment.kind) {
            .self_parent => {
                if (assignment.target < self.pages.len) self.pages[assignment.target].parent_index = assignment.target;
            },
            .missing_parent => {
                if (assignment.target < self.pages.len) self.pages[assignment.target].parent_index = self.pages.len;
            },
            .parent_cycle => {
                if (assignment.target < self.pages.len and assignment.secondary != null and assignment.secondary.? < self.pages.len) {
                    self.pages[assignment.target].parent_index = assignment.secondary.?;
                    self.pages[assignment.secondary.?].parent_index = assignment.target;
                }
            },
            else => {},
        };
    }
};

test "graph plan has stable roots and compact article topology" {
    const a = std.testing.allocator;
    var plan = try GraphPlan.init(a, 51, 20260801);
    defer plan.deinit(a);

    try std.testing.expectEqual(@as(usize, 3), plan.guide_count);
    try std.testing.expectEqual(PageKind.home, plan.pages[0].kind);
    try std.testing.expectEqual(PageKind.guide, plan.pages[1].kind);
    try std.testing.expectEqual(PageKind.article, plan.pages[2].kind);
    try std.testing.expectEqual(@as(?usize, 1), plan.pages[2].parent_index);
    try std.testing.expectEqual(@as(?usize, 25), plan.pages[26].parent_index);
}

test "relative source paths use stable slash-separated links" {
    const a = std.testing.allocator;
    var plan = try GraphPlan.init(a, 4, 7);
    defer plan.deinit(a);
    var buffer: [256]u8 = undefined;
    const link = try plan.relativeSourcePath(plan.pages[2], plan.pages[0], &buffer);
    try std.testing.expectEqualStrings("../../index.md", link);
}
