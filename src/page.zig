//! Discovery metadata, parsed-document views, and durable PageDb (m4–m6).
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
//! into PageDb; see `parser.zig` ownership notes.
//!
//! ## Milestone 6 — PageDb (durable promoted metadata)
//!
//! After parse, only durable fields are copied into a retain arena:
//! entity_id, title, parent, source_path, output_path, status, tags,
//! body_offset, kind. Parser slices into temporary file buffers must never
//! be retained after that buffer is freed.

const std = @import("std");
const identity = @import("identity.zig");
const cooklang_seam = @import("cooklang_seam.zig");

pub const max_entity_id_bytes = identity.max_entity_id_bytes;
pub const ContentKind = identity.ContentKind;

// ---------------------------------------------------------------------------
// Parser bounds (single source of truth; see docs/contracts/frontmatter.md)
// ---------------------------------------------------------------------------

/// Max UTF-8 **bytes** for a frontmatter `title` value.
pub const max_title_bytes: usize = 512;

/// Max UTF-8 bytes for a frontmatter RSS summary.
pub const max_summary_bytes: usize = 1024;

/// Max UTF-8 bytes for a frontmatter `servings` / `serves` / `yield` value.
pub const max_servings_bytes: usize = 64;

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

/// Maximum semantic relations on one page in the IR 0.3 grammar.
///
/// This is deliberately a compile-time bound rather than a project setting:
/// it leaves relation storage predictable while accommodating real evidence
/// pages with substantially more than a handful of typed links.
pub const max_relation_count: usize = 128;

/// Maximum bytes for a semantic relation kind token. Kinds are ASCII tokens
/// today; the bound keeps parsing and durable storage predictable.
pub const max_relation_kind_bytes: usize = 64;

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

/// Constrained open semantic relation kind. The token grammar is
/// `[a-z][a-z0-9_]{0,63}`; Boris preserves the token but does not assign it
/// domain meaning. The original four names are therefore still valid without
/// being a closed registry.
pub const RelationKind = struct {
    value: []const u8,

    pub fn parse(s: []const u8) ?RelationKind {
        if (s.len == 0 or s.len > max_relation_kind_bytes) return null;
        if (s[0] < 'a' or s[0] > 'z') return null;
        for (s[1..]) |c| {
            const ok = (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '_';
            if (!ok) return null;
        }
        return .{ .value = s };
    }

    pub fn name(self: RelationKind) []const u8 {
        return self.value;
    }

    pub fn eql(a: RelationKind, b: RelationKind) bool {
        return std.mem.eql(u8, a.value, b.value);
    }
};

pub const SemanticRelation = struct {
    kind: RelationKind,
    target: []const u8,
};

/// Parsed Cooklang-convention serving count.
///
/// Author keys `servings`, `serves`, and `yield` collapse to this one field.
/// `count` is the leading positive integer; `authored` is the raw value
/// (so `15 cups worth` keeps its units text).
pub const Servings = struct {
    count: u32,
    authored: []const u8,
};

/// True for the closed Cooklang serving-count aliases. Every other Cooklang
/// metadata name (`source`, `author`, `course`, …) stays an unknown key.
pub fn isServingsKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "servings") or
        std.mem.eql(u8, key, "serves") or
        std.mem.eql(u8, key, "yield");
}

/// Leading positive integer, optionally a space/tab and units (`2`,
/// `15 cups worth`). Rejects `0`, leading zeros, fractions, and decimals.
pub fn parseServingsValue(value: []const u8) error{BadServings}!u32 {
    if (value.len == 0 or value[0] < '1' or value[0] > '9') return error.BadServings;
    var end: usize = 1;
    while (end < value.len and value[end] >= '0' and value[end] <= '9') end += 1;
    const count = std.fmt.parseInt(u32, value[0..end], 10) catch return error.BadServings;
    if (count == 0) return error.BadServings;
    if (end < value.len and value[end] != ' ' and value[end] != '\t') return error.BadServings;
    return count;
}

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
    /// Optional strict UTC publication timestamp, retained verbatim for RSS.
    published_at: ?[]const u8 = null,
    /// Optional short plain-text description for future projections and RSS.
    summary: ?[]const u8 = null,
    /// Optional serving count from `servings` / `serves` / `yield`.
    servings: ?Servings = null,
    /// Tag token slices into source; only `tags[0..tag_count]` is defined.
    tags: [max_tag_count][]const u8 = undefined,
    tag_count: usize = 0,
    relations: [max_relation_count]SemanticRelation = undefined,
    relation_count: usize = 0,

    pub fn tagsSlice(self: *const FrontmatterView) []const []const u8 {
        return self.tags[0..self.tag_count];
    }

    pub fn relationsSlice(self: *const FrontmatterView) []const SemanticRelation {
        return self.relations[0..self.relation_count];
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
    /// Walk path of the page whose identity derivation failed (#851),
    /// duplicated into `retain` and carried to the diagnostic boundary so
    /// the EINVALIDPATH diagnostic can name the file. Arena-owned, so deinit
    /// frees it with the rest of the retained strings.
    invalid_path: ?[]const u8 = null,

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

// ---------------------------------------------------------------------------
// Durable PageDb (milestone 6)
// ---------------------------------------------------------------------------

/// Trunk / Satellite role after graph classification.
pub const Role = enum {
    trunk,
    satellite,

    pub fn name(self: Role) []const u8 {
        return @tagName(self);
    }
};

/// Durable page metadata retained for the compile session.
///
/// **All string fields are owned by the PageDb retain allocator.** Never store
/// parser source-buffer slices here without first duplicating them.
pub const DurablePage = struct {
    /// Final entity id (path-derived or frontmatter `id:` override).
    entity_id: []const u8,
    /// Whether `entity_id` came from a frontmatter `id:` override rather than
    /// path derivation. Recorded at promotion because only the caller knows
    /// which branch of the id resolution was taken; consumers needing
    /// rename-stable external identity cannot re-derive it afterwards.
    id_explicit: bool = false,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    source_path: []const u8,
    output_path: []const u8,
    status: ?Status = null,
    published_at: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    /// Cooklang convention count; not written into graph.json.
    servings: ?Servings = null,
    /// Retain-owned tag strings (may be empty slice).
    tags: []const []const u8 = &.{},
    /// Retain-owned semantic relation targets (IR 0.3 when emitted).
    relations: []const SemanticRelation = &.{},
    /// Structured recipe extracted from a `.cook` page (IR 0.4 when emitted).
    ///
    /// Retain-owned like every other field here: the Cooklang adapter is handed
    /// the retain allocator so its strings outlive the per-page scratch arena.
    /// Empty for every other input format.
    recipe: cooklang_seam.Recipe = .{},
    kind: ContentKind = .md,
    /// Byte offset of body start in the source file (not a live buffer).
    body_offset: usize = 0,

    // Graph fields — provisional until freeze; stable after freeze.
    role: Role = .trunk,
    index: u32 = 0,
    parent_index: ?u32 = null,
};

/// Long-lived page database for one compile run.
///
/// - `list_gpa` owns the `ArrayList` spine.
/// - `retain` (typically a build-session arena) owns every string on each page.
pub const PageDb = struct {
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    pages: std.ArrayList(DurablePage) = .empty,

    pub fn init(list_gpa: std.mem.Allocator, retain: std.mem.Allocator) PageDb {
        return .{
            .list_gpa = list_gpa,
            .retain = retain,
            .pages = .empty,
        };
    }

    pub fn deinit(self: *PageDb) void {
        self.pages.deinit(self.list_gpa);
        self.* = undefined;
    }

    pub fn append(self: *PageDb, page: DurablePage) !void {
        try self.pages.append(self.list_gpa, page);
    }

    pub fn items(self: *const PageDb) []const DurablePage {
        return self.pages.items;
    }

    pub fn itemsMut(self: *PageDb) []DurablePage {
        return self.pages.items;
    }

    pub fn len(self: *const PageDb) usize {
        return self.pages.items.len;
    }

    /// Duplicate a string into the retain arena.
    pub fn dupe(self: *PageDb, s: []const u8) ![]u8 {
        return try self.retain.dupe(u8, s);
    }

    /// Duplicate optional string (null stays null).
    pub fn dupeOpt(self: *PageDb, s: ?[]const u8) !?[]const u8 {
        if (s) |v| return try self.retain.dupe(u8, v);
        return null;
    }

    /// Promote discovery + parsed frontmatter into a durable page.
    ///
    /// All string data is copied onto `retain`. Callers may free the source
    /// buffer immediately after this returns.
    ///
    /// `path_entity_id` / `source_path` / `output_path` / `kind` come from
    /// discovery (already retain-owned or duped by the caller). When the
    /// caller passes discovery slices that already live on `retain`, they are
    /// re-used without a second copy when equal-owner is not detectable — the
    /// pipeline always re-dupes path strings that came from a separate scan
    /// arena into the PageDb retain arena for a single owner.
    pub fn promote(
        self: *PageDb,
        discovery: Page,
        /// Final entity id (after optional frontmatter override).
        entity_id: []const u8,
        /// True when `entity_id` came from `meta.id`; the caller owns the
        /// resolution decision, so it is passed rather than re-derived here.
        id_explicit: bool,
        meta: FrontmatterView,
        body_offset: usize,
        /// Already retain-owned; empty for every format but Cooklang.
        recipe: cooklang_seam.Recipe,
    ) !void {
        const tags_src = meta.tagsSlice();
        var tags_owned: []const []const u8 = &.{};
        if (tags_src.len > 0) {
            const buf = try self.retain.alloc([]const u8, tags_src.len);
            for (tags_src, 0..) |t, i| {
                buf[i] = try self.retain.dupe(u8, t);
            }
            tags_owned = buf;
        }

        const relations_src = meta.relationsSlice();
        var relations_owned: []const SemanticRelation = &.{};
        if (relations_src.len > 0) {
            const buf = try self.retain.alloc(SemanticRelation, relations_src.len);
            for (relations_src, 0..) |relation, i| {
                buf[i] = .{
                    .kind = .{ .value = try self.retain.dupe(u8, relation.kind.name()) },
                    .target = try self.retain.dupe(u8, relation.target),
                };
            }
            relations_owned = buf;
        }

        // Recompute output path from final entity id when id was overridden.
        const output_path = if (std.mem.eql(u8, entity_id, discovery.entity_id))
            try self.retain.dupe(u8, discovery.output_path)
        else
            try identity.safeOutputRelativePath(self.retain, entity_id);

        try self.append(.{
            .entity_id = try self.retain.dupe(u8, entity_id),
            .id_explicit = id_explicit,
            .title = try self.dupeOpt(meta.title),
            .parent = try self.dupeOpt(meta.parent),
            .source_path = try self.retain.dupe(u8, discovery.source_path),
            .output_path = output_path,
            .status = meta.status,
            .published_at = try self.dupeOpt(meta.published_at),
            .summary = try self.dupeOpt(meta.summary),
            .servings = if (meta.servings) |s| .{
                .count = s.count,
                .authored = try self.retain.dupe(u8, s.authored),
            } else null,
            .tags = tags_owned,
            .relations = relations_owned,
            .recipe = recipe,
            .kind = discovery.kind,
            .body_offset = body_offset,
            .role = if (meta.parent != null) .satellite else .trunk,
        });
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

test "RelationKind accepts bounded lowercase domain tokens" {
    try std.testing.expectEqualStrings("relates_to", RelationKind.parse("relates_to").?.name());
    try std.testing.expectEqualStrings("verified_by2", RelationKind.parse("verified_by2").?.name());
    try std.testing.expect(RelationKind.parse("Unknown") == null);
    try std.testing.expect(RelationKind.parse("unknown-kind") == null);
    try std.testing.expect(RelationKind.parse("1kind") == null);
    var too_long: [max_relation_kind_bytes + 1]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expect(RelationKind.parse(&too_long) == null);
}

test "PageDb.promote owns strings after source buffer free" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var db = PageDb.init(gpa, retain);
    defer db.deinit();

    // Simulate a temporary source buffer that will be freed.
    const source = try gpa.dupe(u8,
        \\---
        \\title: Durable Title
        \\parent: home
        \\status: draft
        \\tags: [a, b]
        \\---
        \\
        \\body
    );
    // Parse views into source (manual view to avoid depending on parser here).
    const title_view = source[std.mem.indexOf(u8, source, "Durable Title").?..][0.."Durable Title".len];
    const parent_view = source[std.mem.indexOf(u8, source, "home").?..][0.."home".len];
    const tag_a = source[std.mem.indexOf(u8, source, "[a, b]").? + 1 ..][0..1];
    const tag_b = source[std.mem.indexOf(u8, source, "b]").?..][0..1];

    var meta: FrontmatterView = .{
        .title = title_view,
        .parent = parent_view,
        .status = .draft,
        .tag_count = 2,
    };
    meta.tags[0] = tag_a;
    meta.tags[1] = tag_b;

    const discovery: Page = .{
        .source_path = "child.md",
        .entity_id = "child",
        .output_path = "child.html",
        .kind = .md,
    };

    try db.promote(discovery, "child", false, meta, 64, .{});

    // Free the temporary source — promoted strings must remain valid.
    gpa.free(source);

    const p = db.items()[0];
    try std.testing.expectEqualStrings("child", p.entity_id);
    try std.testing.expectEqualStrings("Durable Title", p.title.?);
    try std.testing.expectEqualStrings("home", p.parent.?);
    try std.testing.expectEqualStrings("child.md", p.source_path);
    try std.testing.expectEqualStrings("child.html", p.output_path);
    try std.testing.expect(p.status.? == .draft);
    try std.testing.expectEqual(@as(usize, 2), p.tags.len);
    try std.testing.expectEqualStrings("a", p.tags[0]);
    try std.testing.expectEqualStrings("b", p.tags[1]);
    try std.testing.expect(p.role == .satellite);
}

test "PageDb.promote records frontmatter id override provenance" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var db = PageDb.init(gpa, retain);
    defer db.deinit();

    const derived: Page = .{
        .source_path = "notes/child.md",
        .entity_id = "notes-child",
        .output_path = "notes-child.html",
        .kind = .md,
    };
    const no_id: FrontmatterView = .{};
    try db.promote(derived, derived.entity_id, false, no_id, 0, .{});

    // Same discovery, but the author pinned `id: pinned` in frontmatter.
    const overridden: FrontmatterView = .{ .id = "pinned" };
    try db.promote(derived, overridden.id.?, true, overridden, 0, .{});

    try std.testing.expect(!db.items()[0].id_explicit);
    try std.testing.expectEqualStrings("notes-child", db.items()[0].entity_id);
    try std.testing.expect(db.items()[1].id_explicit);
    try std.testing.expectEqualStrings("pinned", db.items()[1].entity_id);
}
