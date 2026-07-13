//! Discovery metadata and parsed-document views (milestones 4–5).
//!
//! ## Milestone 4 — discovery `Page`
//!
//! Scan-time identity only: content-root-relative source path, canonical
//! entity id, content kind, and a safe output-relative path.
//!
//! ## Milestone 5 — frontmatter views
//!
//! `FrontmatterView` / `Status` hold **parsed** fields as slices into the
//! caller's source buffer (or closed enums). They are **not** owned by a
//! long-lived retain allocator. Callers that need durable storage must dupe
//! into PageDb later; see `parser.zig` ownership notes.
//!
//! ## Allocator ownership (discovery)
//!
//! All string fields on `Page` are owned by the caller's **long-lived retain
//! allocator** (typically a build-session arena). The list spine is owned by a
//! separate list allocator (often the same GPA used for temporary walk state).

const std = @import("std");
const identity = @import("identity.zig");

pub const max_entity_id_bytes = identity.max_entity_id_bytes;
pub const ContentKind = identity.ContentKind;

// ---------------------------------------------------------------------------
// Parser bounds (single source of truth; see docs/contracts/frontmatter.md)
// ---------------------------------------------------------------------------

/// Max UTF-8 **bytes** for a frontmatter `title` value.
pub const max_title_bytes: usize = 512;

/// Max UTF-8 **bytes** for one tag token (after quote strip).
pub const max_tag_bytes: usize = 64;

/// Max number of tags in one `tags: […]` list.
pub const max_tag_count: usize = 32;

/// Max source file size the frontmatter/body parser accepts (bytes).
pub const max_source_bytes: usize = 1024 * 1024;

/// Max bytes **inside** the frontmatter fences (excluding the fence lines).
pub const max_frontmatter_bytes: usize = 64 * 1024;

/// Max non-blank field lines inside one frontmatter block.
pub const max_frontmatter_fields: usize = 32;

/// Closed `status` vocabulary (exact spellings only).
pub const Status = enum {
    draft,
    published,
    archived,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "draft")) return .draft;
        if (std.mem.eql(u8, s, "published")) return .published;
        if (std.mem.eql(u8, s, "archived")) return .archived;
        return null;
    }
};

/// Parsed frontmatter fields as **views into the source buffer**.
///
/// Lifetime is tied to the `source` slice passed to `parser.parse`. Do **not**
/// store these slices on a durable `Page` / PageDb without copying first.
///
/// When `title` is absent, it is `null` — v0.1 does **not** derive a title
/// from the filename or from Markdown headings.
pub const FrontmatterView = struct {
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    status: ?Status = null,
    /// Tag token slices into source; only `tags[0..tag_count]` is defined.
    tags: [max_tag_count][]const u8 = undefined,
    tag_count: usize = 0,

    pub fn tagsSlice(self: *const FrontmatterView) []const []const u8 {
        return self.tags[0..self.tag_count];
    }
};

// ---------------------------------------------------------------------------
// Discovery Page (milestone 4)
// ---------------------------------------------------------------------------

/// One discovered content page (durable scan metadata only).
pub const Page = struct {
    /// Content-root-relative path with `/` separators (retain-owned).
    /// Never a host absolute path. Example: `guides/intro.md`.
    source_path: []const u8,
    /// Canonical entity id from `identity.canonicalEntityId` (retain-owned).
    /// Example: `guides/intro`.
    entity_id: []const u8,
    /// Safe path relative to an eventual output root (retain-owned).
    /// Built only from the validated entity id — never escapes that root.
    /// Example: `guides/intro.html`.
    output_path: []const u8,
    /// Case-sensitive extension class (`.md` vs `.mdx`).
    kind: ContentKind,
};

/// Flat collection of discovered pages. List spine and string data have
/// explicit separate owners.
pub const PageList = struct {
    /// GPA (or other non-arena) that owns the `ArrayList` spine.
    list_gpa: std.mem.Allocator,
    /// Long-lived allocator that owns every string on each `Page`.
    retain: std.mem.Allocator,
    pages: std.ArrayList(Page) = .empty,

    pub fn init(list_gpa: std.mem.Allocator, retain: std.mem.Allocator) PageList {
        return .{
            .list_gpa = list_gpa,
            .retain = retain,
            .pages = .empty,
        };
    }

    pub fn deinit(self: *PageList) void {
        // Strings live on `retain` (arena: free via arena deinit).
        self.pages.deinit(self.list_gpa);
        self.* = undefined;
    }

    pub fn append(self: *PageList, page: Page) !void {
        try self.pages.append(self.list_gpa, page);
    }

    pub fn items(self: *const PageList) []const Page {
        return self.pages.items;
    }

    pub fn len(self: *const PageList) usize {
        return self.pages.items.len;
    }
};

/// Sort key for discovery determinism: entity_id ascending (bytewise UTF-8),
/// then source_path as a stable tie-breaker.
pub fn pageLessThan(_: void, a: Page, b: Page) bool {
    const id_ord = std.mem.order(u8, a.entity_id, b.entity_id);
    if (id_ord != .eq) return id_ord == .lt;
    return std.mem.order(u8, a.source_path, b.source_path) == .lt;
}

pub fn sortPages(pages: []Page) void {
    std.mem.sort(Page, pages, {}, pageLessThan);
}

test "pageLessThan sort key entity_id then source_path" {
    const pages = [_]Page{
        .{ .source_path = "z.md", .entity_id = "z", .output_path = "z.html", .kind = .md },
        .{ .source_path = "a.md", .entity_id = "a", .output_path = "a.html", .kind = .md },
        .{ .source_path = "m.md", .entity_id = "m", .output_path = "m.html", .kind = .md },
    };
    var buf = pages;
    sortPages(&buf);
    try std.testing.expectEqualStrings("a", buf[0].entity_id);
    try std.testing.expectEqualStrings("m", buf[1].entity_id);
    try std.testing.expectEqualStrings("z", buf[2].entity_id);
}

test "pageLessThan ties break on source_path" {
    // Same entity_id (duplicate-id case preserved for later diagnostics).
    var pages = [_]Page{
        .{ .source_path = "b.md", .entity_id = "dup", .output_path = "dup.html", .kind = .md },
        .{ .source_path = "a.md", .entity_id = "dup", .output_path = "dup.html", .kind = .md },
    };
    sortPages(&pages);
    try std.testing.expectEqualStrings("a.md", pages[0].source_path);
    try std.testing.expectEqualStrings("b.md", pages[1].source_path);
}

test "Status.parse closed vocabulary" {
    try std.testing.expect(Status.parse("draft").? == .draft);
    try std.testing.expect(Status.parse("published").? == .published);
    try std.testing.expect(Status.parse("archived").? == .archived);
    try std.testing.expect(Status.parse("Draft") == null);
    try std.testing.expect(Status.parse("") == null);
}
