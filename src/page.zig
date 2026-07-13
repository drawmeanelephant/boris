//! Core content-database unit for Boris.
//!
//! A `Page` is a node in the in-memory Trunk-and-Satellite graph. Paths and
//! metadata live here; rendering output is produced later in the compile loop
//! and is *not* stored permanently on the Page (whiteboard memory).
//!
//! Components (asides/admonitions) are parse-time tokens only — they are not
//! first-class Page fields and do not become graph nodes or fragment pages.
//!
//! ## Allocator ownership (survives document `free_all`)
//!
//! Every string field that remains on `Page` after the compile loop must be
//! allocated with the **PageDb arena** (or be a static empty slice), never
//! with the per-document whiteboard arena:
//!
//! | Field | Owner | When |
//! |-------|-------|------|
//! | `source_path`, `output_path`, `entity_id` | PageDb arena | scan (`scanner.zig`) via `dupe` |
//! | `frontmatter.title`, `frontmatter.parent_entry` | PageDb arena | compile promote (`dupe`) |
//! | `frontmatter.extras` | not promoted after compile | parse-time only |
//! | `raw_source`, `body_md` | PageDb if retained; usually empty | optional tooling |
//!
//! Storing a raw parse slice (sub-slice of document-arena source) on `Page`
//! is a use-after-free once `doc_arena.reset(.free_all)` runs.

const std = @import("std");

/// Max UTF-8 **bytes** for promoted display titles (PageDb arena protection).
/// Values longer than this are rejected at parse time with a diagnostic; they
/// are never `dupe`d into the long-lived PageDb / retain arena.
pub const max_title_bytes: usize = 512;

/// Max UTF-8 **bytes** for entity ids (path-derived, frontmatter `id`, and
/// parent foreign keys). Same arena-protection rationale as `max_title_bytes`.
pub const max_entity_id_bytes: usize = 255;

/// Frontmatter keys Boris understands for graph relations and display.
pub const Frontmatter = struct {
    /// Optional display title from bounded frontmatter `title:`.
    /// After compile promotion: PageDb-owned. At parse time: document-arena slice.
    title: ?[]const u8 = null,
    /// Foreign key: if set, this page is a Satellite of the named Trunk entity.
    /// After compile promotion: PageDb-owned. Null path skips dupe (no copy needed).
    parent_entry: ?[]const u8 = null,
    /// Raw key/value pairs for keys we do not specially interpret.
    /// Values and keys are slices into the page's source buffer (document arena)
    /// unless the caller has explicitly duped them — do not promote wholesale.
    extras: []const Kv = &.{},

    pub const Kv = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn isSatellite(self: Frontmatter) bool {
        return self.parent_entry != null;
    }
};

/// Core unit of the Boris content database.
pub const Page = struct {
    /// Path relative to `content/` (e.g. `guides/intro.md`). PageDb-owned.
    source_path: []const u8,
    /// Destination path relative to `dist/` (e.g. `guides/intro.html`). PageDb-owned.
    output_path: []const u8,
    /// Stable entity identity used as graph key (derived from source path).
    /// Case-preserving ASCII with `/` hierarchy separators (never `\`).
    /// Derived at scan time via `pathutil.canonicalEntityId`.
    /// PageDb-owned.
    entity_id: []const u8,
    /// Parsed frontmatter / relational metadata (promoted fields PageDb-owned).
    frontmatter: Frontmatter = .{},
    /// Full file bytes (frontmatter + body). Owned by the long-lived page arena when set.
    raw_source: []const u8 = "",
    /// Markdown body after frontmatter (component tags may be stripped for tools).
    /// Owned by the long-lived page arena when retained.
    body_md: []const u8 = "",

    pub fn role(self: Page) []const u8 {
        if (self.frontmatter.isSatellite()) return "satellite";
        return "trunk";
    }
};

/// Mutable list of pages that forms the in-memory content graph database.
pub const PageDb = struct {
    pages: std.ArrayList(Page) = .empty,
    /// Long-lived arena for path strings and page-owned source buffers.
    /// Reset only when the entire build finishes (not per-document).
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) PageDb {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
        };
    }

    pub fn deinit(self: *PageDb) void {
        self.pages.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    pub fn allocator(self: *PageDb) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn append(self: *PageDb, page: Page) !void {
        // Use child allocator for the list spine so path/source data in the
        // arena is independent of list growth reallocations.
        try self.pages.append(self.arena.child_allocator, page);
    }

    pub fn items(self: *const PageDb) []const Page {
        return self.pages.items;
    }
};

test "Page role satellite vs trunk" {
    var trunk: Page = .{
        .source_path = "a.md",
        .output_path = "a.html",
        .entity_id = "a",
    };
    try std.testing.expectEqualStrings("trunk", trunk.role());

    var sat: Page = .{
        .source_path = "b.md",
        .output_path = "b.html",
        .entity_id = "b",
        .frontmatter = .{ .parent_entry = "a" },
    };
    try std.testing.expectEqualStrings("satellite", sat.role());
}
