//! WordPress WXR → Boris migration laboratory core.
//!
//! Reads a WordPress WXR/XML export (and optional local media tree), emits
//! deterministic Boris-ready Markdown under `--out/content/`, plus machine and
//! human review reports. Never mutates the export or media inputs. No network.
//!
//! Not part of the Boris product compiler pipeline.

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-wordpress-migration-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const RunOptions = struct {
    /// Path to WXR/XML export file (never modified).
    wxr_path: []const u8,
    /// Optional local media directory (uploads mirror); never modified.
    media_dir: ?[]const u8 = null,
    /// Output root: content/ + report.json + REPORT.md.
    out_dir: []const u8,
    quiet: bool = false,
};

/// Conversion classification for a page or feature finding.
pub const ConversionClass = enum {
    exact,
    transformed,
    unsupported,
    human_review,

    pub fn jsonName(self: ConversionClass) []const u8 {
        return switch (self) {
            .exact => "exact",
            .transformed => "transformed",
            .unsupported => "unsupported",
            .human_review => "human_review",
        };
    }

    /// Worse rank wins when combining classifications.
    pub fn rank(self: ConversionClass) u8 {
        return switch (self) {
            .exact => 0,
            .transformed => 1,
            .unsupported => 2,
            .human_review => 3,
        };
    }

    pub fn worse(a: ConversionClass, b: ConversionClass) ConversionClass {
        return if (a.rank() >= b.rank()) a else b;
    }
};

// ---------------------------------------------------------------------------
// Parsed WXR model
// ---------------------------------------------------------------------------

pub const CategoryRef = struct {
    domain: []const u8, // "category" | "post_tag" | other
    nicename: []const u8,
    label: []const u8,
};

pub const WxrItem = struct {
    title: []const u8 = "",
    link: []const u8 = "",
    pub_date: []const u8 = "",
    creator: []const u8 = "",
    guid: []const u8 = "",
    description: []const u8 = "",
    content_encoded: []const u8 = "",
    excerpt_encoded: []const u8 = "",
    post_id: []const u8 = "",
    post_date: []const u8 = "",
    post_date_gmt: []const u8 = "",
    post_name: []const u8 = "",
    status: []const u8 = "",
    post_parent: []const u8 = "0",
    menu_order: []const u8 = "0",
    post_type: []const u8 = "",
    is_sticky: []const u8 = "0",
    attachment_url: []const u8 = "",
    categories: []CategoryRef = &.{},
};

pub const WxrAuthor = struct {
    login: []const u8 = "",
    email: []const u8 = "",
    display_name: []const u8 = "",
};

pub const WxrTaxonomy = struct {
    domain: []const u8, // category | tag
    nicename: []const u8,
    name: []const u8,
    parent: []const u8 = "",
};

pub const WxrDocument = struct {
    title: []const u8 = "",
    link: []const u8 = "",
    base_site_url: []const u8 = "",
    base_blog_url: []const u8 = "",
    wxr_version: []const u8 = "",
    authors: []WxrAuthor = &.{},
    taxonomies: []WxrTaxonomy = &.{},
    items: []WxrItem = &.{},
};

// ---------------------------------------------------------------------------
// Report model
// ---------------------------------------------------------------------------

pub const Provenance = struct {
    output_path: []const u8,
    source_export: []const u8,
    post_id: []const u8,
    post_type: []const u8,
    guid: []const u8,
    post_name: []const u8,
    author: []const u8,
    post_date: []const u8,
    link: []const u8,
    conversion: ConversionClass,
};

pub const PageRecord = struct {
    output_path: []const u8,
    post_id: []const u8,
    post_type: []const u8,
    title: []const u8,
    slug: []const u8,
    author: []const u8,
    post_date: []const u8,
    status_wp: []const u8,
    status_boris: []const u8,
    categories: []const []const u8,
    tags: []const []const u8,
    parent_post_id: []const u8,
    proposed_entity_id: []const u8,
    proposed_parent: ?[]const u8,
    proposed_frontmatter: []const u8,
    conversion: ConversionClass,
    feature_codes: []const []const u8,
};

pub const ParentRel = struct {
    child_post_id: []const u8,
    child_entity_id: []const u8,
    parent_post_id: []const u8,
    parent_entity_id: ?[]const u8,
    reason: []const u8,
    confidence: []const u8,
    note: []const u8,
};

pub const LinkFinding = struct {
    source_post_id: []const u8,
    source_output: []const u8,
    kind: []const u8, // internal_href | media_src | shortcode_url
    target: []const u8,
    resolved_post_id: ?[]const u8,
    status: []const u8, // ok | unresolved | external_skipped
};

pub const MediaRef = struct {
    source_post_id: []const u8,
    source_output: []const u8,
    referenced: []const u8,
    local_path: ?[]const u8,
    status: []const u8, // present | missing | attachment_only
};

pub const FeatureFinding = struct {
    source_post_id: []const u8,
    source_output: []const u8,
    code: []const u8,
    classification: ConversionClass,
    excerpt: []const u8,
    message: []const u8,
};

pub const SlugConflict = struct {
    slug: []const u8,
    post_ids: []const []const u8,
    output_paths: []const []const u8,
    kind: []const u8,
};

pub const UnsupportedItem = struct {
    post_id: []const u8,
    post_type: []const u8,
    title: []const u8,
    reason: []const u8,
    /// Path under out/ where raw payload was preserved (never discarded).
    preserved_path: []const u8,
};

pub const HumanReview = struct {
    source_post_id: []const u8,
    source_output: []const u8,
    reason: []const u8,
    codes: []const []const u8,
};

pub const Report = struct {
    source_export: []const u8,
    media_dir: ?[]const u8,
    site_title: []const u8,
    base_site_url: []const u8,
    base_blog_url: []const u8,
    authors: []WxrAuthor,
    taxonomies: []WxrTaxonomy,
    pages: []PageRecord,
    parent_relationships: []ParentRel,
    links: []LinkFinding,
    media_references: []MediaRef,
    missing_media: []MediaRef,
    features: []FeatureFinding,
    slug_conflicts: []SlugConflict,
    unsupported_items: []UnsupportedItem,
    human_review: []HumanReview,
    provenance: []Provenance,
};

// ---------------------------------------------------------------------------
// XML helpers (WXR-focused, not a general XML library)
// ---------------------------------------------------------------------------

fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

/// Decode a minimal set of XML/HTML entities common in WXR.
pub fn decodeEntities(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&apos;") or std.mem.startsWith(u8, input[i..], "&#039;")) {
                try out.append(allocator, '\'');
                i += if (input[i + 1] == '#') 6 else 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&nbsp;")) {
                try out.append(allocator, ' ');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&#")) {
                const semi = std.mem.indexOfScalar(u8, input[i..], ';') orelse {
                    try out.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                const body = input[i + 2 .. i + semi];
                var codepoint: u21 = 0;
                var ok = false;
                if (body.len > 0 and (body[0] == 'x' or body[0] == 'X')) {
                    codepoint = std.fmt.parseInt(u21, body[1..], 16) catch 0;
                    ok = body.len > 1;
                } else if (body.len > 0) {
                    codepoint = std.fmt.parseInt(u21, body, 10) catch 0;
                    ok = true;
                }
                if (ok and codepoint != 0) {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(codepoint, &buf) catch {
                        try out.appendSlice(allocator, input[i .. i + semi + 1]);
                        i += semi + 1;
                        continue;
                    };
                    try out.appendSlice(allocator, buf[0..n]);
                    i += semi + 1;
                    continue;
                }
            }
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// Extract text or CDATA between first matching open/close tags. Returns empty if missing.
pub fn extractTagContent(xml: []const u8, open_tag: []const u8, close_tag: []const u8) []const u8 {
    const open_idx = std.mem.indexOf(u8, xml, open_tag) orelse return "";
    var content_start = open_idx + open_tag.len;
    // Skip attributes form: <tag attr="...">
    if (open_tag[open_tag.len - 1] != '>') {
        // open_tag without '>'; find '>'
        if (std.mem.indexOfScalar(u8, xml[open_idx..], '>')) |gt| {
            content_start = open_idx + gt + 1;
        }
    }
    const close_idx = std.mem.indexOf(u8, xml[content_start..], close_tag) orelse return "";
    var content = xml[content_start .. content_start + close_idx];
    content = trimSpace(content);
    // Strip CDATA wrapper.
    if (std.mem.startsWith(u8, content, "<![CDATA[") and std.mem.endsWith(u8, content, "]]>")) {
        content = content["<![CDATA[".len .. content.len - 3];
    }
    return content;
}

/// Like extractTagContent but open form is `<local` with optional namespace prefix and attrs.
pub fn extractElementImpl(xml: []const u8, local_name: []const u8) []const u8 {
    // Find opening tag ending with local_name (optionally prefixed) then > or space.
    var i: usize = 0;
    while (i < xml.len) : (i += 1) {
        if (xml[i] != '<') continue;
        if (i + 1 < xml.len and xml[i + 1] == '/') continue;
        if (i + 1 < xml.len and xml[i + 1] == '!') continue;
        if (i + 1 < xml.len and xml[i + 1] == '?') continue;
        const name_start = i + 1;
        // optional namespace prefix
        var name_end = name_start;
        while (name_end < xml.len and xml[name_end] != '>' and xml[name_end] != ' ' and xml[name_end] != '/' and xml[name_end] != '\t' and xml[name_end] != '\n' and xml[name_end] != '\r') : (name_end += 1) {}
        const full_name = xml[name_start..name_end];
        const bare = if (std.mem.lastIndexOfScalar(u8, full_name, ':')) |c| full_name[c + 1 ..] else full_name;
        if (!std.mem.eql(u8, bare, local_name)) continue;

        // Self-closing?
        var gt = name_end;
        while (gt < xml.len and xml[gt] != '>') : (gt += 1) {}
        if (gt >= xml.len) return "";
        if (gt > name_start and xml[gt - 1] == '/') return "";

        const content_start = gt + 1;
        // Build close tag </full_name> or </ns:local>
        var close_buf: [160]u8 = undefined;
        const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{full_name}) catch return "";
        const rel = std.mem.indexOf(u8, xml[content_start..], close) orelse return "";
        var content = xml[content_start .. content_start + rel];
        content = trimSpace(content);
        if (std.mem.startsWith(u8, content, "<![CDATA[") and std.mem.endsWith(u8, content, "]]>")) {
            content = content["<![CDATA[".len .. content.len - 3];
        }
        return content;
    }
    return "";
}

/// Extract attribute value from an open-tag fragment (e.g. domain="category").
pub fn extractAttr(open_tag: []const u8, attr: []const u8) []const u8 {
    var pat_buf: [96]u8 = undefined;
    const pat_dq = std.fmt.bufPrint(&pat_buf, "{s}=\"", .{attr}) catch return "";
    if (std.mem.indexOf(u8, open_tag, pat_dq)) |idx| {
        const start = idx + pat_dq.len;
        const end = std.mem.indexOfScalar(u8, open_tag[start..], '"') orelse return "";
        return open_tag[start .. start + end];
    }
    const pat_sq = std.fmt.bufPrint(&pat_buf, "{s}='", .{attr}) catch return "";
    if (std.mem.indexOf(u8, open_tag, pat_sq)) |idx| {
        const start = idx + pat_sq.len;
        const end = std.mem.indexOfScalar(u8, open_tag[start..], '\'') orelse return "";
        return open_tag[start .. start + end];
    }
    return "";
}

fn nextItemSlice(xml: []const u8, from: usize) ?struct { slice: []const u8, next: usize } {
    const open = std.mem.indexOfPos(u8, xml, from, "<item>") orelse
        std.mem.indexOfPos(u8, xml, from, "<item ");
    if (open == null) return null;
    const start = open.?;
    // Find true end of open tag
    const gt = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse return null;
    const content_start = gt + 1;
    const close = std.mem.indexOfPos(u8, xml, content_start, "</item>") orelse return null;
    return .{ .slice = xml[start .. close + "</item>".len], .next = close + "</item>".len };
}

fn parseCategoryTags(allocator: std.mem.Allocator, item_xml: []const u8) ![]CategoryRef {
    var list: std.ArrayList(CategoryRef) = .empty;
    errdefer list.deinit(allocator);
    var from: usize = 0;
    while (from < item_xml.len) {
        const open_rel = std.mem.indexOfPos(u8, item_xml, from, "<category") orelse break;
        const gt = std.mem.indexOfScalarPos(u8, item_xml, open_rel, '>') orelse break;
        const open_tag = item_xml[open_rel .. gt + 1];
        if (std.mem.indexOf(u8, open_tag, "/>") != null) {
            from = gt + 1;
            continue;
        }
        const close = std.mem.indexOfPos(u8, item_xml, gt + 1, "</category>") orelse break;
        var label = trimSpace(item_xml[gt + 1 .. close]);
        if (std.mem.startsWith(u8, label, "<![CDATA[") and std.mem.endsWith(u8, label, "]]>")) {
            label = label["<![CDATA[".len .. label.len - 3];
        }
        const domain = extractAttr(open_tag, "domain");
        const nicename = extractAttr(open_tag, "nicename");
        const nice = if (nicename.len > 0) nicename else (if (label.len > 0) label else "uncategorized");
        try list.append(allocator, .{
            .domain = try allocator.dupe(u8, if (domain.len > 0) domain else "category"),
            .nicename = try allocator.dupe(u8, nice),
            .label = try allocator.dupe(u8, label),
        });
        from = close + "</category>".len;
    }
    return try list.toOwnedSlice(allocator);
}

fn parseAuthors(allocator: std.mem.Allocator, channel: []const u8) ![]WxrAuthor {
    var list: std.ArrayList(WxrAuthor) = .empty;
    errdefer list.deinit(allocator);
    var from: usize = 0;
    while (from < channel.len) {
        const open = std.mem.indexOfPos(u8, channel, from, "<wp:author>") orelse break;
        const close = std.mem.indexOfPos(u8, channel, open, "</wp:author>") orelse break;
        const block = channel[open .. close + "</wp:author>".len];
        try list.append(allocator, .{
            .login = try allocator.dupe(u8, extractElementImpl(block, "author_login")),
            .email = try allocator.dupe(u8, extractElementImpl(block, "author_email")),
            .display_name = try allocator.dupe(u8, extractElementImpl(block, "author_display_name")),
        });
        from = close + "</wp:author>".len;
    }
    return try list.toOwnedSlice(allocator);
}

fn parseTaxonomies(allocator: std.mem.Allocator, channel: []const u8) ![]WxrTaxonomy {
    var list: std.ArrayList(WxrTaxonomy) = .empty;
    errdefer list.deinit(allocator);

    // Categories
    var from: usize = 0;
    while (from < channel.len) {
        const open = std.mem.indexOfPos(u8, channel, from, "<wp:category>") orelse break;
        const close = std.mem.indexOfPos(u8, channel, open, "</wp:category>") orelse break;
        const block = channel[open .. close + "</wp:category>".len];
        try list.append(allocator, .{
            .domain = "category",
            .nicename = try allocator.dupe(u8, extractElementImpl(block, "category_nicename")),
            .name = try allocator.dupe(u8, extractElementImpl(block, "cat_name")),
            .parent = try allocator.dupe(u8, extractElementImpl(block, "category_parent")),
        });
        from = close + "</wp:category>".len;
    }
    // Tags
    from = 0;
    while (from < channel.len) {
        const open = std.mem.indexOfPos(u8, channel, from, "<wp:tag>") orelse break;
        const close = std.mem.indexOfPos(u8, channel, open, "</wp:tag>") orelse break;
        const block = channel[open .. close + "</wp:tag>".len];
        try list.append(allocator, .{
            .domain = "tag",
            .nicename = try allocator.dupe(u8, extractElementImpl(block, "tag_slug")),
            .name = try allocator.dupe(u8, extractElementImpl(block, "tag_name")),
            .parent = "",
        });
        from = close + "</wp:tag>".len;
    }
    return try list.toOwnedSlice(allocator);
}

pub fn parseWxr(allocator: std.mem.Allocator, xml: []const u8) !WxrDocument {
    var doc: WxrDocument = .{};
    doc.title = try allocator.dupe(u8, extractElementImpl(xml, "title"));
    // Prefer channel-level link: take first <link> after <channel>
    if (std.mem.indexOf(u8, xml, "<channel>")) |ch| {
        doc.link = try allocator.dupe(u8, extractElementImpl(xml[ch..], "link"));
    } else {
        doc.link = try allocator.dupe(u8, extractElementImpl(xml, "link"));
    }
    doc.base_site_url = try allocator.dupe(u8, extractElementImpl(xml, "base_site_url"));
    doc.base_blog_url = try allocator.dupe(u8, extractElementImpl(xml, "base_blog_url"));
    doc.wxr_version = try allocator.dupe(u8, extractElementImpl(xml, "wxr_version"));
    doc.authors = try parseAuthors(allocator, xml);
    doc.taxonomies = try parseTaxonomies(allocator, xml);

    var items: std.ArrayList(WxrItem) = .empty;
    errdefer items.deinit(allocator);
    var from: usize = 0;
    while (nextItemSlice(xml, from)) |hit| {
        const block = hit.slice;
        from = hit.next;
        const cats = try parseCategoryTags(allocator, block);
        try items.append(allocator, .{
            .title = try allocator.dupe(u8, extractElementImpl(block, "title")),
            .link = try allocator.dupe(u8, extractElementImpl(block, "link")),
            .pub_date = try allocator.dupe(u8, extractElementImpl(block, "pubDate")),
            .creator = try allocator.dupe(u8, extractElementImpl(block, "creator")),
            .guid = try allocator.dupe(u8, extractElementImpl(block, "guid")),
            .description = try allocator.dupe(u8, extractElementImpl(block, "description")),
            .content_encoded = try allocator.dupe(u8, extractElementImpl(block, "encoded")), // content:encoded local name
            .excerpt_encoded = "", // filled below if second encoded differs — handled carefully
            .post_id = try allocator.dupe(u8, extractElementImpl(block, "post_id")),
            .post_date = try allocator.dupe(u8, extractElementImpl(block, "post_date")),
            .post_date_gmt = try allocator.dupe(u8, extractElementImpl(block, "post_date_gmt")),
            .post_name = try allocator.dupe(u8, extractElementImpl(block, "post_name")),
            .status = try allocator.dupe(u8, extractElementImpl(block, "status")),
            .post_parent = try allocator.dupe(u8, extractElementImpl(block, "post_parent")),
            .menu_order = try allocator.dupe(u8, extractElementImpl(block, "menu_order")),
            .post_type = try allocator.dupe(u8, extractElementImpl(block, "post_type")),
            .is_sticky = try allocator.dupe(u8, extractElementImpl(block, "is_sticky")),
            .attachment_url = try allocator.dupe(u8, extractElementImpl(block, "attachment_url")),
            .categories = cats,
        });
        // Fix content:encoded vs excerpt:encoded — extractElementImpl finds first "encoded".
        // Re-parse both explicitly.
        const content = extractNamedElement(block, "content:encoded");
        const excerpt = extractNamedElement(block, "excerpt:encoded");
        if (content.len > 0) {
            items.items[items.items.len - 1].content_encoded = try allocator.dupe(u8, content);
        }
        if (excerpt.len > 0) {
            items.items[items.items.len - 1].excerpt_encoded = try allocator.dupe(u8, excerpt);
        }
    }
    // Deterministic order: by post_id numeric then lexical
    std.mem.sort(WxrItem, items.items, {}, struct {
        fn less(_: void, a: WxrItem, b: WxrItem) bool {
            const ai = std.fmt.parseInt(u64, a.post_id, 10) catch std.math.maxInt(u64);
            const bi = std.fmt.parseInt(u64, b.post_id, 10) catch std.math.maxInt(u64);
            if (ai != bi) return ai < bi;
            return std.mem.order(u8, a.post_id, b.post_id) == .lt;
        }
    }.less);
    doc.items = try items.toOwnedSlice(allocator);
    return doc;
}

/// Extract element by full name including optional namespace prefix (e.g. content:encoded).
pub fn extractNamedElement(xml: []const u8, full_name: []const u8) []const u8 {
    var open_buf: [128]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}", .{full_name}) catch return "";
    const open_idx = std.mem.indexOf(u8, xml, open) orelse return "";
    const gt = std.mem.indexOfScalarPos(u8, xml, open_idx, '>') orelse return "";
    if (gt > open_idx and xml[gt - 1] == '/') return "";
    const content_start = gt + 1;
    var close_buf: [132]u8 = undefined;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{full_name}) catch return "";
    const rel = std.mem.indexOf(u8, xml[content_start..], close) orelse return "";
    var content = xml[content_start .. content_start + rel];
    content = trimSpace(content);
    if (std.mem.startsWith(u8, content, "<![CDATA[") and std.mem.endsWith(u8, content, "]]>")) {
        content = content["<![CDATA[".len .. content.len - 3];
    }
    return content;
}

// ---------------------------------------------------------------------------
// Slug / path helpers
// ---------------------------------------------------------------------------

pub fn slugifyAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var prev_dash = false;
    for (input) |c| {
        const lower: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            try out.append(allocator, lower);
            prev_dash = false;
        } else if (lower == '-' or lower == '_' or lower == ' ' or lower == '/') {
            if (!prev_dash and out.items.len > 0) {
                try out.append(allocator, '-');
                prev_dash = true;
            }
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "untitled");
    return try out.toOwnedSlice(allocator);
}

pub fn sanitizeEntitySegment(allocator: std.mem.Allocator, slug: []const u8) ![]u8 {
    // Boris wiki ids prefer ASCII path stems; keep [a-z0-9/_-]
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (slug) |c| {
        const lower: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or lower == '-' or lower == '_' or lower == '/') {
            try out.append(allocator, lower);
        } else if (lower == ' ') {
            try out.append(allocator, '-');
        }
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "untitled");
    return try out.toOwnedSlice(allocator);
}

pub fn mapWpStatus(wp_status: []const u8) []const u8 {
    if (std.mem.eql(u8, wp_status, "publish")) return "published";
    if (std.mem.eql(u8, wp_status, "draft") or std.mem.eql(u8, wp_status, "auto-draft") or
        std.mem.eql(u8, wp_status, "pending") or std.mem.eql(u8, wp_status, "future") or
        std.mem.eql(u8, wp_status, "private"))
        return "draft";
    return "draft";
}

// ---------------------------------------------------------------------------
// Feature detection + HTML → Markdown conversion
// ---------------------------------------------------------------------------

pub const ConvertResult = struct {
    markdown_body: []const u8,
    classification: ConversionClass,
    feature_codes: []const []const u8,
    features: []FeatureFinding,
    links: []LinkFinding,
    media_refs: []MediaRef,
};

const FeatureHit = struct {
    code: []const u8,
    class: ConversionClass,
    excerpt: []const u8,
    message: []const u8,
};

fn appendUniqueCode(allocator: std.mem.Allocator, codes: *std.ArrayList([]const u8), code: []const u8) !void {
    for (codes.items) |c| {
        if (std.mem.eql(u8, c, code)) return;
    }
    try codes.append(allocator, try allocator.dupe(u8, code));
}

pub fn detectFeatures(allocator: std.mem.Allocator, content: []const u8) ![]FeatureHit {
    var hits: std.ArrayList(FeatureHit) = .empty;
    errdefer hits.deinit(allocator);

    // Gutenberg blocks
    if (std.mem.indexOf(u8, content, "<!-- wp:") != null) {
        try hits.append(allocator, .{
            .code = "gutenberg_block",
            .class = .transformed,
            .excerpt = "<!-- wp:… -->",
            .message = "Gutenberg block comments detected; block chrome stripped, inner HTML converted",
        });
    }
    if (std.mem.indexOf(u8, content, "<!-- wp:gallery") != null or std.mem.indexOf(u8, content, "<!-- wp:image") != null) {
        try hits.append(allocator, .{
            .code = "gallery_or_image_block",
            .class = .human_review,
            .excerpt = "<!-- wp:gallery|image -->",
            .message = "Gallery/image blocks need media path verification",
        });
    }
    if (std.mem.indexOf(u8, content, "<!-- wp:embed") != null or std.mem.indexOf(u8, content, "<!-- wp:html") != null) {
        try hits.append(allocator, .{
            .code = "embed_or_custom_html_block",
            .class = .unsupported,
            .excerpt = "<!-- wp:embed|html -->",
            .message = "Embed/custom HTML blocks preserved as raw HTML",
        });
    }
    // Shortcodes
    if (std.mem.indexOf(u8, content, "[gallery") != null) {
        try hits.append(allocator, .{
            .code = "shortcode_gallery",
            .class = .unsupported,
            .excerpt = "[gallery …]",
            .message = "Gallery shortcode cannot be expanded offline; preserved raw",
        });
    }
    if (std.mem.indexOf(u8, content, "[caption") != null) {
        try hits.append(allocator, .{
            .code = "shortcode_caption",
            .class = .transformed,
            .excerpt = "[caption …]",
            .message = "Caption shortcode unwrapped to image + italic caption when possible",
        });
    }
    if (std.mem.indexOf(u8, content, "[embed") != null or std.mem.indexOf(u8, content, "[video") != null or
        std.mem.indexOf(u8, content, "[audio") != null)
    {
        try hits.append(allocator, .{
            .code = "shortcode_embed_media",
            .class = .unsupported,
            .excerpt = "[embed|video|audio]",
            .message = "Media/embed shortcodes preserved raw (no network expansion)",
        });
    }
    // Generic shortcode heuristic: [word ...]
    if (hasGenericShortcode(content)) {
        try hits.append(allocator, .{
            .code = "shortcode_generic",
            .class = .unsupported,
            .excerpt = "[shortcode]",
            .message = "One or more shortcodes remain in body",
        });
    }
    if (std.mem.indexOf(u8, content, "<script") != null or std.mem.indexOf(u8, content, "<iframe") != null) {
        try hits.append(allocator, .{
            .code = "raw_script_or_iframe",
            .class = .human_review,
            .excerpt = "<script>|<iframe>",
            .message = "Script/iframe present; review for security and fit",
        });
    }
    if (std.mem.indexOf(u8, content, "<table") != null) {
        try hits.append(allocator, .{
            .code = "html_table",
            .class = .transformed,
            .excerpt = "<table>",
            .message = "HTML tables preserved as HTML blocks (not markdown tables)",
        });
    }
    return try hits.toOwnedSlice(allocator);
}

fn hasGenericShortcode(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] != '[') continue;
        if (i + 1 >= content.len) break;
        const c = content[i + 1];
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'))) continue;
        // not a markdown link [text](
        if (std.mem.indexOfScalarPos(u8, content, i, ']')) |rb| {
            if (rb + 1 < content.len and content[rb + 1] == '(') continue;
            // likely shortcode
            return true;
        }
    }
    return false;
}

fn stripGutenbergChrome(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < content.len) {
        if (std.mem.startsWith(u8, content[i..], "<!-- wp:") or std.mem.startsWith(u8, content[i..], "<!-- /wp:")) {
            if (std.mem.indexOf(u8, content[i..], "-->")) |end| {
                i += end + 3;
                // drop following single newline
                if (i < content.len and content[i] == '\r') i += 1;
                if (i < content.len and content[i] == '\n') i += 1;
                continue;
            }
        }
        try out.append(allocator, content[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// Convert a subset of HTML to Markdown. Unrecognized tags are kept as HTML (never dropped).
pub fn htmlToMarkdown(allocator: std.mem.Allocator, html_in: []const u8) !struct { []u8, ConversionClass } {
    var class: ConversionClass = .exact;
    if (html_in.len == 0) return .{ try allocator.dupe(u8, ""), .exact };

    var html = try stripGutenbergChrome(allocator, html_in);
    defer allocator.free(html);

    // If still has block chrome removal changes, mark transformed.
    if (!std.mem.eql(u8, html, html_in)) class = .transformed;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var pure_text = true;

    while (i < html.len) {
        if (html[i] == '<') {
            pure_text = false;
            // comment
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                if (std.mem.indexOf(u8, html[i..], "-->")) |end| {
                    // Preserve non-wp comments
                    const comment = html[i .. i + end + 3];
                    try out.appendSlice(allocator, comment);
                    i += end + 3;
                    class = ConversionClass.worse(class, .human_review);
                    continue;
                }
            }
            const gt = std.mem.indexOfScalarPos(u8, html, i, '>') orelse {
                try out.append(allocator, html[i]);
                i += 1;
                continue;
            };
            const tag_raw = html[i + 1 .. gt];
            const self_close = tag_raw.len > 0 and tag_raw[tag_raw.len - 1] == '/';
            var tag_body = if (self_close) trimSpace(tag_raw[0 .. tag_raw.len - 1]) else tag_raw;
            const is_close = tag_body.len > 0 and tag_body[0] == '/';
            if (is_close) tag_body = trimSpace(tag_body[1..]);
            var name_end: usize = 0;
            while (name_end < tag_body.len and tag_body[name_end] != ' ' and tag_body[name_end] != '\t' and tag_body[name_end] != '\n' and tag_body[name_end] != '\r') : (name_end += 1) {}
            var name = tag_body[0..name_end];
            // lower-case name for matching
            var name_buf: [32]u8 = undefined;
            if (name.len < name_buf.len) {
                for (name, 0..) |c, idx| {
                    name_buf[idx] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                }
                name = name_buf[0..name.len];
            }

            if (is_close) {
                if (std.mem.eql(u8, name, "p") or std.mem.eql(u8, name, "div")) {
                    try out.appendSlice(allocator, "\n\n");
                    class = ConversionClass.worse(class, .transformed);
                } else if (std.mem.eql(u8, name, "h1") or std.mem.eql(u8, name, "h2") or std.mem.eql(u8, name, "h3") or
                    std.mem.eql(u8, name, "h4") or std.mem.eql(u8, name, "h5") or std.mem.eql(u8, name, "h6"))
                {
                    try out.appendSlice(allocator, "\n\n");
                    class = ConversionClass.worse(class, .transformed);
                } else if (std.mem.eql(u8, name, "li")) {
                    try out.append(allocator, '\n');
                    class = ConversionClass.worse(class, .transformed);
                } else if (std.mem.eql(u8, name, "ul") or std.mem.eql(u8, name, "ol") or std.mem.eql(u8, name, "blockquote")) {
                    try out.appendSlice(allocator, "\n\n");
                    class = ConversionClass.worse(class, .transformed);
                } else if (std.mem.eql(u8, name, "strong") or std.mem.eql(u8, name, "b")) {
                    try out.appendSlice(allocator, "**");
                    class = ConversionClass.worse(class, .transformed);
                } else if (std.mem.eql(u8, name, "em") or std.mem.eql(u8, name, "i")) {
                    try out.appendSlice(allocator, "*");
                    class = ConversionClass.worse(class, .transformed);
                } else if (std.mem.eql(u8, name, "code")) {
                    try out.append(allocator, '`');
                    class = ConversionClass.worse(class, .transformed);
                } else if (std.mem.eql(u8, name, "pre")) {
                    try out.appendSlice(allocator, "\n```\n");
                    class = ConversionClass.worse(class, .transformed);
                } else if (std.mem.eql(u8, name, "a")) {
                    // closing </a> handled with stack? simplified: just close paren if we emitted md link
                    // For simplicity keep as nothing — open tag emitted markdown start
                    try out.append(allocator, ')');
                    class = ConversionClass.worse(class, .transformed);
                } else {
                    // preserve close tag
                    try out.appendSlice(allocator, html[i .. gt + 1]);
                    class = ConversionClass.worse(class, .unsupported);
                }
                i = gt + 1;
                continue;
            }

            // open / void tags
            if (std.mem.eql(u8, name, "br") or std.mem.eql(u8, name, "br/")) {
                try out.append(allocator, '\n');
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "hr") or std.mem.eql(u8, name, "hr/")) {
                try out.appendSlice(allocator, "\n\n---\n\n");
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "p") or std.mem.eql(u8, name, "div")) {
                if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(allocator, "\n\n");
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') {
                const level = name[1] - '0';
                if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(allocator, "\n\n");
                var h: usize = 0;
                while (h < level) : (h += 1) try out.append(allocator, '#');
                try out.append(allocator, ' ');
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "strong") or std.mem.eql(u8, name, "b")) {
                try out.appendSlice(allocator, "**");
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "em") or std.mem.eql(u8, name, "i")) {
                try out.appendSlice(allocator, "*");
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "code")) {
                try out.append(allocator, '`');
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "pre")) {
                try out.appendSlice(allocator, "\n```\n");
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "li")) {
                try out.appendSlice(allocator, "- ");
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "ul") or std.mem.eql(u8, name, "ol") or std.mem.eql(u8, name, "blockquote")) {
                if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(allocator, "\n\n");
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            if (std.mem.eql(u8, name, "a")) {
                const href = extractAttr(html[i .. gt + 1], "href");
                try out.append(allocator, '[');
                // find inner text until </a>
                const close = std.mem.indexOfPos(u8, html, gt + 1, "</a>") orelse std.mem.indexOfPos(u8, html, gt + 1, "</A>");
                if (close) |cidx| {
                    const inner = html[gt + 1 .. cidx];
                    // strip nested tags lightly
                    const plain = try stripTagsPlain(allocator, inner);
                    defer allocator.free(plain);
                    try out.appendSlice(allocator, plain);
                    try out.appendSlice(allocator, "](");
                    try out.appendSlice(allocator, href);
                    try out.append(allocator, ')');
                    i = cidx + 4;
                    class = ConversionClass.worse(class, .transformed);
                    continue;
                } else {
                    try out.appendSlice(allocator, "](");
                    try out.appendSlice(allocator, href);
                    try out.append(allocator, ')');
                    i = gt + 1;
                    class = ConversionClass.worse(class, .transformed);
                    continue;
                }
            }
            if (std.mem.eql(u8, name, "img")) {
                const src = extractAttr(html[i .. gt + 1], "src");
                const alt = extractAttr(html[i .. gt + 1], "alt");
                try out.appendSlice(allocator, "![");
                try out.appendSlice(allocator, alt);
                try out.appendSlice(allocator, "](");
                try out.appendSlice(allocator, src);
                try out.append(allocator, ')');
                class = ConversionClass.worse(class, .transformed);
                i = gt + 1;
                continue;
            }
            // Unknown / unsupported tags: preserve as raw HTML (never discard)
            try out.appendSlice(allocator, html[i .. gt + 1]);
            class = ConversionClass.worse(class, .unsupported);
            i = gt + 1;
            continue;
        }

        // text node — decode entities later in batch; copy raw for now
        try out.append(allocator, html[i]);
        i += 1;
    }

    if (pure_text and html_in.len > 0) {
        // still decode entities
        class = .exact;
    } else if (class == .exact) {
        class = .transformed;
    }

    const raw_md = try out.toOwnedSlice(allocator);
    defer allocator.free(raw_md);
    const decoded = try decodeEntities(allocator, raw_md);

    // Collapse excess blank lines (max 2)
    const collapsed = try collapseBlankLines(allocator, decoded);
    allocator.free(decoded);
    return .{ collapsed, class };
}

fn stripTagsPlain(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, html, i, '>')) |gt| {
                i = gt + 1;
                continue;
            }
        }
        try out.append(allocator, html[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn collapseBlankLines(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var nl_run: usize = 0;
    for (input) |c| {
        if (c == '\n') {
            nl_run += 1;
            if (nl_run <= 2) try out.append(allocator, c);
        } else {
            nl_run = 0;
            try out.append(allocator, c);
        }
    }
    // trim trailing space
    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\n' or out.items[out.items.len - 1] == '\t')) {
        _ = out.pop();
    }
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

/// Preserve shortcodes that we cannot expand: leave them in the body.
fn unwrapCaptionShortcodes(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    // [caption ...]<img ...>text[/caption] → img md later + *text*
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < content.len) {
        if (std.mem.startsWith(u8, content[i..], "[caption")) {
            const close_open = std.mem.indexOfScalarPos(u8, content, i, ']') orelse {
                try out.append(allocator, content[i]);
                i += 1;
                continue;
            };
            const end = std.mem.indexOfPos(u8, content, close_open, "[/caption]") orelse {
                try out.appendSlice(allocator, content[i .. close_open + 1]);
                i = close_open + 1;
                continue;
            };
            const inner = content[close_open + 1 .. end];
            try out.appendSlice(allocator, inner);
            try out.appendSlice(allocator, "\n");
            i = end + "[/caption]".len;
            continue;
        }
        try out.append(allocator, content[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Link + media extraction from converted / original body
// ---------------------------------------------------------------------------

fn isExternalUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "mailto:") or std.mem.startsWith(u8, url, "//");
}

fn isMediaPath(url: []const u8) bool {
    if (std.mem.indexOf(u8, url, "wp-content/uploads/") != null) return true;
    const ext = fileExtension(url);
    if (ext.len == 0) return false;
    const media_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf", ".mp4", ".mp3", ".zip" };
    for (media_exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

pub fn fileExtension(path: []const u8) []const u8 {
    // strip query
    var p = path;
    if (std.mem.indexOfScalar(u8, p, '?')) |q| p = p[0..q];
    const base = std.fs.path.basename(p);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot == 0) return "";
        return base[dot..];
    }
    return "";
}

/// Normalize a media URL/path to a uploads-relative path when possible.
pub fn mediaRelativeKey(url: []const u8) ?[]const u8 {
    const marker = "wp-content/uploads/";
    if (std.mem.indexOf(u8, url, marker)) |idx| {
        var rest = url[idx + marker.len ..];
        if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
        return rest;
    }
    // bare relative uploads path
    if (std.mem.startsWith(u8, url, "uploads/")) {
        var rest = url["uploads/".len..];
        if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
        return rest;
    }
    return null;
}

fn extractMarkdownLinks(allocator: std.mem.Allocator, body: []const u8, post_id: []const u8, output: []const u8) !struct { []LinkFinding, []MediaRef } {
    var links: std.ArrayList(LinkFinding) = .empty;
    errdefer links.deinit(allocator);
    var media: std.ArrayList(MediaRef) = .empty;
    errdefer media.deinit(allocator);

    // ![alt](url) and [text](url)
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '[') continue;
        const is_img = i > 0 and body[i - 1] == '!';
        const rb = std.mem.indexOfScalarPos(u8, body, i, ']') orelse continue;
        if (rb + 1 >= body.len or body[rb + 1] != '(') continue;
        const re = std.mem.indexOfScalarPos(u8, body, rb + 2, ')') orelse continue;
        const target = body[rb + 2 .. re];
        if (target.len == 0) continue;
        if (is_img or isMediaPath(target)) {
            try media.append(allocator, .{
                .source_post_id = try allocator.dupe(u8, post_id),
                .source_output = try allocator.dupe(u8, output),
                .referenced = try allocator.dupe(u8, target),
                .local_path = null,
                .status = "pending",
            });
        } else if (isExternalUrl(target) and std.mem.indexOf(u8, target, "wp-content/uploads/") == null) {
            // external non-media: skip from internal list but still note as external_skipped when site-local handled later
            try links.append(allocator, .{
                .source_post_id = try allocator.dupe(u8, post_id),
                .source_output = try allocator.dupe(u8, output),
                .kind = "href",
                .target = try allocator.dupe(u8, target),
                .resolved_post_id = null,
                .status = "external_skipped",
            });
        } else {
            try links.append(allocator, .{
                .source_post_id = try allocator.dupe(u8, post_id),
                .source_output = try allocator.dupe(u8, output),
                .kind = if (is_img) "media_src" else "internal_href",
                .target = try allocator.dupe(u8, target),
                .resolved_post_id = null,
                .status = "unresolved",
            });
        }
        i = re;
    }
    return .{ try links.toOwnedSlice(allocator), try media.toOwnedSlice(allocator) };
}

// ---------------------------------------------------------------------------
// Frontmatter emission
// ---------------------------------------------------------------------------

pub fn escapeFmValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    // Quote if contains special chars
    var needs_quote = false;
    for (value) |c| {
        if (c == ':' or c == '#' or c == '"' or c == '[' or c == ']' or c == '\n' or c == ',') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote and value.len > 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) needs_quote = true;
    if (!needs_quote) return try allocator.dupe(u8, value);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |c| {
        if (c == '"') try out.appendSlice(allocator, "'") // no escape sequences in Boris dquoted; drop raw quotes
        else if (c != '\n' and c != '\r') try out.append(allocator, c);
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

pub fn buildFrontmatter(
    allocator: std.mem.Allocator,
    title: []const u8,
    parent: ?[]const u8,
    status: []const u8,
    tags: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "---\n");
    const title_e = try escapeFmValue(allocator, title);
    defer allocator.free(title_e);
    try buf.print(allocator, "title: {s}\n", .{title_e});
    if (parent) |p| {
        try buf.print(allocator, "parent: {s}\n", .{p});
    }
    try buf.print(allocator, "status: {s}\n", .{status});
    if (tags.len > 0) {
        try buf.appendSlice(allocator, "tags: [");
        for (tags, 0..) |t, idx| {
            if (idx > 0) try buf.appendSlice(allocator, ", ");
            // tag tokens: plain if safe
            var safe = true;
            for (t) |c| {
                if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_')) safe = false;
            }
            if (safe) {
                try buf.appendSlice(allocator, t);
            } else {
                try buf.print(allocator, "\"{s}\"", .{t});
            }
        }
        try buf.appendSlice(allocator, "]\n");
    }
    try buf.appendSlice(allocator, "---\n");
    return try buf.toOwnedSlice(allocator);
}

pub fn buildProvenanceComment(allocator: std.mem.Allocator, p: Provenance) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\<!-- boris-migration-provenance
        \\source_format: wordpress-wxr
        \\source_export: {s}
        \\post_id: {s}
        \\post_type: {s}
        \\guid: {s}
        \\post_name: {s}
        \\author: {s}
        \\post_date: {s}
        \\link: {s}
        \\conversion: {s}
        \\-->
        \\
    , .{
        p.source_export,
        p.post_id,
        p.post_type,
        p.guid,
        p.post_name,
        p.author,
        p.post_date,
        p.link,
        p.conversion.jsonName(),
    });
}

// ---------------------------------------------------------------------------
// Media directory walk
// ---------------------------------------------------------------------------

fn isSkippedDirName(name: []const u8) bool {
    const skip = [_][]const u8{ ".git", ".DS_Store", "zig-cache", ".zig-cache" };
    for (skip) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn collectMediaFiles(
    io: Io,
    gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    dir: Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isSkippedDirName(entry.name)) continue;
            const child_rel = if (prefix.len == 0)
                try retain.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, entry.name });
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try collectMediaFiles(io, gpa, retain, sub, child_rel, out);
            continue;
        }
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;
        const child_rel = if (prefix.len == 0)
            try retain.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(retain, "{s}/{s}", .{ prefix, entry.name });
        try out.append(gpa, child_rel);
    }
}

fn findLocalMedia(files: []const []const u8, key: []const u8) ?[]const u8 {
    for (files) |f| {
        if (std.mem.eql(u8, f, key)) return f;
    }
    for (files) |f| {
        if (std.mem.endsWith(u8, f, key) or std.mem.endsWith(u8, key, f)) return f;
    }
    // basename match
    const base = std.fs.path.basename(key);
    for (files) |f| {
        if (std.mem.eql(u8, std.fs.path.basename(f), base)) return f;
    }
    return null;
}

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

pub fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn ensureParent(io: Io, root: Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

// ---------------------------------------------------------------------------
// Core conversion pipeline
// ---------------------------------------------------------------------------

const ItemMeta = struct {
    item: WxrItem,
    entity_id: []const u8,
    output_path: []const u8,
    slug: []const u8,
};

fn proposeEntityId(allocator: std.mem.Allocator, post_type: []const u8, slug: []const u8) ![]u8 {
    if (std.mem.eql(u8, post_type, "page")) {
        return try std.fmt.allocPrint(allocator, "pages/{s}", .{slug});
    }
    if (std.mem.eql(u8, post_type, "post")) {
        return try std.fmt.allocPrint(allocator, "posts/{s}", .{slug});
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ post_type, slug });
}

fn proposeOutputPath(allocator: std.mem.Allocator, entity_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "content/{s}.md", .{entity_id});
}

pub fn convertItemBody(
    allocator: std.mem.Allocator,
    item: WxrItem,
    output_path: []const u8,
    source_export: []const u8,
) !ConvertResult {
    _ = source_export;
    var class: ConversionClass = .exact;
    var codes: std.ArrayList([]const u8) = .empty;
    errdefer codes.deinit(allocator);
    var feature_findings: std.ArrayList(FeatureFinding) = .empty;
    errdefer feature_findings.deinit(allocator);

    const raw = item.content_encoded;
    const hits = try detectFeatures(allocator, raw);
    defer allocator.free(hits);
    for (hits) |h| {
        class = ConversionClass.worse(class, h.class);
        try appendUniqueCode(allocator, &codes, h.code);
        try feature_findings.append(allocator, .{
            .source_post_id = try allocator.dupe(u8, item.post_id),
            .source_output = try allocator.dupe(u8, output_path),
            .code = try allocator.dupe(u8, h.code),
            .classification = h.class,
            .excerpt = try allocator.dupe(u8, h.excerpt),
            .message = try allocator.dupe(u8, h.message),
        });
    }

    // Unwrap captions then HTML→MD
    const unwrapped = try unwrapCaptionShortcodes(allocator, raw);
    defer allocator.free(unwrapped);
    if (!std.mem.eql(u8, unwrapped, raw)) {
        class = ConversionClass.worse(class, .transformed);
        try appendUniqueCode(allocator, &codes, "shortcode_caption");
    }

    const md_pair = try htmlToMarkdown(allocator, unwrapped);
    var body = md_pair[0];
    class = ConversionClass.worse(class, md_pair[1]);

    // If body still contains shortcodes, ensure unsupported classification
    if (hasGenericShortcode(body)) {
        class = ConversionClass.worse(class, .unsupported);
        try appendUniqueCode(allocator, &codes, "shortcode_remaining");
    }

    // Empty content is still exact empty
    if (raw.len == 0 and body.len <= 1) {
        class = .exact;
        allocator.free(body);
        body = try allocator.dupe(u8, "\n");
    }

    const link_media = try extractMarkdownLinks(allocator, body, item.post_id, output_path);

    return .{
        .markdown_body = body,
        .classification = class,
        .feature_codes = try codes.toOwnedSlice(allocator),
        .features = try feature_findings.toOwnedSlice(allocator),
        .links = link_media[0],
        .media_refs = link_media[1],
    };
}

fn jsonEscapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(gpa, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

fn emitJson(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try buf.appendSlice(gpa, "  \"format\": ");
    try jsonEscapeAppend(&buf, gpa, format_id);
    try buf.print(gpa, ",\n  \"schema_version\": {d},\n  \"tool_version\": ", .{schema_version});
    try jsonEscapeAppend(&buf, gpa, tool_version);
    try buf.appendSlice(gpa, ",\n  \"source_export\": ");
    try jsonEscapeAppend(&buf, gpa, report.source_export);
    try buf.appendSlice(gpa, ",\n  \"media_dir\": ");
    if (report.media_dir) |m| {
        try jsonEscapeAppend(&buf, gpa, m);
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ",\n  \"site_title\": ");
    try jsonEscapeAppend(&buf, gpa, report.site_title);
    try buf.appendSlice(gpa, ",\n  \"base_site_url\": ");
    try jsonEscapeAppend(&buf, gpa, report.base_site_url);
    try buf.appendSlice(gpa, ",\n  \"base_blog_url\": ");
    try jsonEscapeAppend(&buf, gpa, report.base_blog_url);

    // summary
    try buf.appendSlice(gpa, ",\n  \"summary\": {\n");
    try buf.print(gpa, "    \"pages\": {d},\n", .{report.pages.len});
    try buf.print(gpa, "    \"parent_relationships\": {d},\n", .{report.parent_relationships.len});
    try buf.print(gpa, "    \"links\": {d},\n", .{report.links.len});
    try buf.print(gpa, "    \"media_references\": {d},\n", .{report.media_references.len});
    try buf.print(gpa, "    \"missing_media\": {d},\n", .{report.missing_media.len});
    try buf.print(gpa, "    \"features\": {d},\n", .{report.features.len});
    try buf.print(gpa, "    \"slug_conflicts\": {d},\n", .{report.slug_conflicts.len});
    try buf.print(gpa, "    \"unsupported_items\": {d},\n", .{report.unsupported_items.len});
    try buf.print(gpa, "    \"human_review\": {d},\n", .{report.human_review.len});
    try buf.print(gpa, "    \"provenance\": {d}\n", .{report.provenance.len});
    try buf.appendSlice(gpa, "  }");

    // authors
    try buf.appendSlice(gpa, ",\n  \"authors\": [\n");
    for (report.authors, 0..) |a, idx| {
        try buf.appendSlice(gpa, "    {\"login\": ");
        try jsonEscapeAppend(&buf, gpa, a.login);
        try buf.appendSlice(gpa, ", \"email\": ");
        try jsonEscapeAppend(&buf, gpa, a.email);
        try buf.appendSlice(gpa, ", \"display_name\": ");
        try jsonEscapeAppend(&buf, gpa, a.display_name);
        try buf.append(gpa, '}');
        if (idx + 1 < report.authors.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // taxonomies
    try buf.appendSlice(gpa, ",\n  \"taxonomies\": [\n");
    for (report.taxonomies, 0..) |t, idx| {
        try buf.appendSlice(gpa, "    {\"domain\": ");
        try jsonEscapeAppend(&buf, gpa, t.domain);
        try buf.appendSlice(gpa, ", \"nicename\": ");
        try jsonEscapeAppend(&buf, gpa, t.nicename);
        try buf.appendSlice(gpa, ", \"name\": ");
        try jsonEscapeAppend(&buf, gpa, t.name);
        try buf.appendSlice(gpa, ", \"parent\": ");
        try jsonEscapeAppend(&buf, gpa, t.parent);
        try buf.append(gpa, '}');
        if (idx + 1 < report.taxonomies.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // pages
    try buf.appendSlice(gpa, ",\n  \"pages\": [\n");
    for (report.pages, 0..) |p, idx| {
        try buf.appendSlice(gpa, "    {\n");
        try buf.appendSlice(gpa, "      \"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.output_path);
        try buf.appendSlice(gpa, ",\n      \"post_id\": ");
        try jsonEscapeAppend(&buf, gpa, p.post_id);
        try buf.appendSlice(gpa, ",\n      \"post_type\": ");
        try jsonEscapeAppend(&buf, gpa, p.post_type);
        try buf.appendSlice(gpa, ",\n      \"title\": ");
        try jsonEscapeAppend(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n      \"slug\": ");
        try jsonEscapeAppend(&buf, gpa, p.slug);
        try buf.appendSlice(gpa, ",\n      \"author\": ");
        try jsonEscapeAppend(&buf, gpa, p.author);
        try buf.appendSlice(gpa, ",\n      \"post_date\": ");
        try jsonEscapeAppend(&buf, gpa, p.post_date);
        try buf.appendSlice(gpa, ",\n      \"status_wp\": ");
        try jsonEscapeAppend(&buf, gpa, p.status_wp);
        try buf.appendSlice(gpa, ",\n      \"status_boris\": ");
        try jsonEscapeAppend(&buf, gpa, p.status_boris);
        try buf.appendSlice(gpa, ",\n      \"categories\": [");
        for (p.categories, 0..) |c, ci| {
            try jsonEscapeAppend(&buf, gpa, c);
            if (ci + 1 < p.categories.len) try buf.appendSlice(gpa, ", ");
        }
        try buf.appendSlice(gpa, "],\n      \"tags\": [");
        for (p.tags, 0..) |t, ti| {
            try jsonEscapeAppend(&buf, gpa, t);
            if (ti + 1 < p.tags.len) try buf.appendSlice(gpa, ", ");
        }
        try buf.appendSlice(gpa, "],\n      \"parent_post_id\": ");
        try jsonEscapeAppend(&buf, gpa, p.parent_post_id);
        try buf.appendSlice(gpa, ",\n      \"proposed_entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, p.proposed_entity_id);
        try buf.appendSlice(gpa, ",\n      \"proposed_parent\": ");
        if (p.proposed_parent) |pp| try jsonEscapeAppend(&buf, gpa, pp) else try buf.appendSlice(gpa, "null");
        try buf.appendSlice(gpa, ",\n      \"proposed_frontmatter\": ");
        try jsonEscapeAppend(&buf, gpa, p.proposed_frontmatter);
        try buf.appendSlice(gpa, ",\n      \"conversion\": ");
        try jsonEscapeAppend(&buf, gpa, p.conversion.jsonName());
        try buf.appendSlice(gpa, ",\n      \"feature_codes\": [");
        for (p.feature_codes, 0..) |c, ci| {
            try jsonEscapeAppend(&buf, gpa, c);
            if (ci + 1 < p.feature_codes.len) try buf.appendSlice(gpa, ", ");
        }
        try buf.appendSlice(gpa, "]\n    }");
        if (idx + 1 < report.pages.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // parent_relationships
    try buf.appendSlice(gpa, ",\n  \"parent_relationships\": [\n");
    for (report.parent_relationships, 0..) |r, idx| {
        try buf.appendSlice(gpa, "    {\"child_post_id\": ");
        try jsonEscapeAppend(&buf, gpa, r.child_post_id);
        try buf.appendSlice(gpa, ", \"child_entity_id\": ");
        try jsonEscapeAppend(&buf, gpa, r.child_entity_id);
        try buf.appendSlice(gpa, ", \"parent_post_id\": ");
        try jsonEscapeAppend(&buf, gpa, r.parent_post_id);
        try buf.appendSlice(gpa, ", \"parent_entity_id\": ");
        if (r.parent_entity_id) |pe| try jsonEscapeAppend(&buf, gpa, pe) else try buf.appendSlice(gpa, "null");
        try buf.appendSlice(gpa, ", \"reason\": ");
        try jsonEscapeAppend(&buf, gpa, r.reason);
        try buf.appendSlice(gpa, ", \"confidence\": ");
        try jsonEscapeAppend(&buf, gpa, r.confidence);
        try buf.appendSlice(gpa, ", \"note\": ");
        try jsonEscapeAppend(&buf, gpa, r.note);
        try buf.append(gpa, '}');
        if (idx + 1 < report.parent_relationships.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // links
    try buf.appendSlice(gpa, ",\n  \"links\": [\n");
    for (report.links, 0..) |l, idx| {
        try buf.appendSlice(gpa, "    {\"source_post_id\": ");
        try jsonEscapeAppend(&buf, gpa, l.source_post_id);
        try buf.appendSlice(gpa, ", \"source_output\": ");
        try jsonEscapeAppend(&buf, gpa, l.source_output);
        try buf.appendSlice(gpa, ", \"kind\": ");
        try jsonEscapeAppend(&buf, gpa, l.kind);
        try buf.appendSlice(gpa, ", \"target\": ");
        try jsonEscapeAppend(&buf, gpa, l.target);
        try buf.appendSlice(gpa, ", \"resolved_post_id\": ");
        if (l.resolved_post_id) |rp| try jsonEscapeAppend(&buf, gpa, rp) else try buf.appendSlice(gpa, "null");
        try buf.appendSlice(gpa, ", \"status\": ");
        try jsonEscapeAppend(&buf, gpa, l.status);
        try buf.append(gpa, '}');
        if (idx + 1 < report.links.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // media_references
    try buf.appendSlice(gpa, ",\n  \"media_references\": [\n");
    for (report.media_references, 0..) |m, idx| {
        try buf.appendSlice(gpa, "    {\"source_post_id\": ");
        try jsonEscapeAppend(&buf, gpa, m.source_post_id);
        try buf.appendSlice(gpa, ", \"source_output\": ");
        try jsonEscapeAppend(&buf, gpa, m.source_output);
        try buf.appendSlice(gpa, ", \"referenced\": ");
        try jsonEscapeAppend(&buf, gpa, m.referenced);
        try buf.appendSlice(gpa, ", \"local_path\": ");
        if (m.local_path) |lp| try jsonEscapeAppend(&buf, gpa, lp) else try buf.appendSlice(gpa, "null");
        try buf.appendSlice(gpa, ", \"status\": ");
        try jsonEscapeAppend(&buf, gpa, m.status);
        try buf.append(gpa, '}');
        if (idx + 1 < report.media_references.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // missing_media
    try buf.appendSlice(gpa, ",\n  \"missing_media\": [\n");
    for (report.missing_media, 0..) |m, idx| {
        try buf.appendSlice(gpa, "    {\"source_post_id\": ");
        try jsonEscapeAppend(&buf, gpa, m.source_post_id);
        try buf.appendSlice(gpa, ", \"source_output\": ");
        try jsonEscapeAppend(&buf, gpa, m.source_output);
        try buf.appendSlice(gpa, ", \"referenced\": ");
        try jsonEscapeAppend(&buf, gpa, m.referenced);
        try buf.appendSlice(gpa, ", \"local_path\": null, \"status\": ");
        try jsonEscapeAppend(&buf, gpa, m.status);
        try buf.append(gpa, '}');
        if (idx + 1 < report.missing_media.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // features
    try buf.appendSlice(gpa, ",\n  \"features\": [\n");
    for (report.features, 0..) |f, idx| {
        try buf.appendSlice(gpa, "    {\"source_post_id\": ");
        try jsonEscapeAppend(&buf, gpa, f.source_post_id);
        try buf.appendSlice(gpa, ", \"source_output\": ");
        try jsonEscapeAppend(&buf, gpa, f.source_output);
        try buf.appendSlice(gpa, ", \"code\": ");
        try jsonEscapeAppend(&buf, gpa, f.code);
        try buf.appendSlice(gpa, ", \"classification\": ");
        try jsonEscapeAppend(&buf, gpa, f.classification.jsonName());
        try buf.appendSlice(gpa, ", \"excerpt\": ");
        try jsonEscapeAppend(&buf, gpa, f.excerpt);
        try buf.appendSlice(gpa, ", \"message\": ");
        try jsonEscapeAppend(&buf, gpa, f.message);
        try buf.append(gpa, '}');
        if (idx + 1 < report.features.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // slug_conflicts
    try buf.appendSlice(gpa, ",\n  \"slug_conflicts\": [\n");
    for (report.slug_conflicts, 0..) |c, idx| {
        try buf.appendSlice(gpa, "    {\"slug\": ");
        try jsonEscapeAppend(&buf, gpa, c.slug);
        try buf.appendSlice(gpa, ", \"kind\": ");
        try jsonEscapeAppend(&buf, gpa, c.kind);
        try buf.appendSlice(gpa, ", \"post_ids\": [");
        for (c.post_ids, 0..) |pid, pi| {
            try jsonEscapeAppend(&buf, gpa, pid);
            if (pi + 1 < c.post_ids.len) try buf.appendSlice(gpa, ", ");
        }
        try buf.appendSlice(gpa, "], \"output_paths\": [");
        for (c.output_paths, 0..) |op, oi| {
            try jsonEscapeAppend(&buf, gpa, op);
            if (oi + 1 < c.output_paths.len) try buf.appendSlice(gpa, ", ");
        }
        try buf.appendSlice(gpa, "]}");
        if (idx + 1 < report.slug_conflicts.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // unsupported_items
    try buf.appendSlice(gpa, ",\n  \"unsupported_items\": [\n");
    for (report.unsupported_items, 0..) |u, idx| {
        try buf.appendSlice(gpa, "    {\"post_id\": ");
        try jsonEscapeAppend(&buf, gpa, u.post_id);
        try buf.appendSlice(gpa, ", \"post_type\": ");
        try jsonEscapeAppend(&buf, gpa, u.post_type);
        try buf.appendSlice(gpa, ", \"title\": ");
        try jsonEscapeAppend(&buf, gpa, u.title);
        try buf.appendSlice(gpa, ", \"reason\": ");
        try jsonEscapeAppend(&buf, gpa, u.reason);
        try buf.appendSlice(gpa, ", \"preserved_path\": ");
        try jsonEscapeAppend(&buf, gpa, u.preserved_path);
        try buf.append(gpa, '}');
        if (idx + 1 < report.unsupported_items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // human_review
    try buf.appendSlice(gpa, ",\n  \"human_review\": [\n");
    for (report.human_review, 0..) |h, idx| {
        try buf.appendSlice(gpa, "    {\"source_post_id\": ");
        try jsonEscapeAppend(&buf, gpa, h.source_post_id);
        try buf.appendSlice(gpa, ", \"source_output\": ");
        try jsonEscapeAppend(&buf, gpa, h.source_output);
        try buf.appendSlice(gpa, ", \"reason\": ");
        try jsonEscapeAppend(&buf, gpa, h.reason);
        try buf.appendSlice(gpa, ", \"codes\": [");
        for (h.codes, 0..) |c, ci| {
            try jsonEscapeAppend(&buf, gpa, c);
            if (ci + 1 < h.codes.len) try buf.appendSlice(gpa, ", ");
        }
        try buf.appendSlice(gpa, "]}");
        if (idx + 1 < report.human_review.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]");

    // provenance
    try buf.appendSlice(gpa, ",\n  \"provenance\": [\n");
    for (report.provenance, 0..) |p, idx| {
        try buf.appendSlice(gpa, "    {\"output_path\": ");
        try jsonEscapeAppend(&buf, gpa, p.output_path);
        try buf.appendSlice(gpa, ", \"source_export\": ");
        try jsonEscapeAppend(&buf, gpa, p.source_export);
        try buf.appendSlice(gpa, ", \"post_id\": ");
        try jsonEscapeAppend(&buf, gpa, p.post_id);
        try buf.appendSlice(gpa, ", \"post_type\": ");
        try jsonEscapeAppend(&buf, gpa, p.post_type);
        try buf.appendSlice(gpa, ", \"guid\": ");
        try jsonEscapeAppend(&buf, gpa, p.guid);
        try buf.appendSlice(gpa, ", \"post_name\": ");
        try jsonEscapeAppend(&buf, gpa, p.post_name);
        try buf.appendSlice(gpa, ", \"author\": ");
        try jsonEscapeAppend(&buf, gpa, p.author);
        try buf.appendSlice(gpa, ", \"post_date\": ");
        try jsonEscapeAppend(&buf, gpa, p.post_date);
        try buf.appendSlice(gpa, ", \"link\": ");
        try jsonEscapeAppend(&buf, gpa, p.link);
        try buf.appendSlice(gpa, ", \"conversion\": ");
        try jsonEscapeAppend(&buf, gpa, p.conversion.jsonName());
        try buf.append(gpa, '}');
        if (idx + 1 < report.provenance.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "  ]\n}\n");

    return try buf.toOwnedSlice(gpa);
}

fn emitMarkdown(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "# WordPress → Boris migration laboratory\n\n");
    try buf.print(gpa, "Format `{s}` schema `{d}` tool `{s}`.\n\n", .{ format_id, schema_version, tool_version });
    try buf.print(gpa, "Source export: `{s}`\n\n", .{report.source_export});
    if (report.media_dir) |m| {
        try buf.print(gpa, "Media directory: `{s}`\n\n", .{m});
    } else {
        try buf.appendSlice(gpa, "Media directory: _(none)_\n\n");
    }
    try buf.appendSlice(gpa, "Original WXR/export and media inputs were **not modified**. ");
    try buf.appendSlice(gpa, "No network access. Content is never silently discarded: ");
    try buf.appendSlice(gpa, "unsupported items are preserved under `content/_preserved/`.\n\n");

    try buf.appendSlice(gpa, "## Summary\n\n");
    try buf.appendSlice(gpa, "| Metric | Count |\n|---|---:|\n");
    try buf.print(gpa, "| Generated pages (posts/pages) | {d} |\n", .{report.pages.len});
    try buf.print(gpa, "| Parent relationships | {d} |\n", .{report.parent_relationships.len});
    try buf.print(gpa, "| Links | {d} |\n", .{report.links.len});
    try buf.print(gpa, "| Media references | {d} |\n", .{report.media_references.len});
    try buf.print(gpa, "| Missing media | {d} |\n", .{report.missing_media.len});
    try buf.print(gpa, "| Feature findings | {d} |\n", .{report.features.len});
    try buf.print(gpa, "| Duplicate slugs | {d} |\n", .{report.slug_conflicts.len});
    try buf.print(gpa, "| Unsupported items (preserved) | {d} |\n", .{report.unsupported_items.len});
    try buf.print(gpa, "| Human review | {d} |\n", .{report.human_review.len});
    try buf.print(gpa, "| Provenance records | {d} |\n\n", .{report.provenance.len});

    try buf.appendSlice(gpa, "## Authors\n\n");
    if (report.authors.len == 0) {
        try buf.appendSlice(gpa, "_None declared in export._\n\n");
    } else {
        try buf.appendSlice(gpa, "| login | display_name | email |\n|---|---|---|\n");
        for (report.authors) |a| {
            try buf.print(gpa, "| `{s}` | {s} | `{s}` |\n", .{ a.login, a.display_name, a.email });
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Taxonomies\n\n");
    try buf.appendSlice(gpa, "| domain | nicename | name | parent |\n|---|---|---|---|\n");
    for (report.taxonomies) |t| {
        try buf.print(gpa, "| {s} | `{s}` | {s} | `{s}` |\n", .{ t.domain, t.nicename, t.name, t.parent });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Posts and pages\n\n");
    try buf.appendSlice(gpa, "| output | type | title | slug | author | date | wp status | conversion |\n|---|---|---|---|---|---|---|---|\n");
    for (report.pages) |p| {
        try buf.print(gpa, "| `{s}` | {s} | {s} | `{s}` | `{s}` | `{s}` | {s} | **{s}** |\n", .{
            p.output_path,
            p.post_type,
            p.title,
            p.slug,
            p.author,
            p.post_date,
            p.status_wp,
            p.conversion.jsonName(),
        });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Proposed Boris frontmatter\n\n");
    for (report.pages) |p| {
        try buf.print(gpa, "### `{s}` → `{s}`\n\n", .{ p.post_id, p.proposed_entity_id });
        try buf.appendSlice(gpa, "```yaml\n");
        try buf.appendSlice(gpa, p.proposed_frontmatter);
        try buf.appendSlice(gpa, "```\n\n");
        if (p.categories.len > 0 or p.tags.len > 0) {
            try buf.appendSlice(gpa, "- Categories: ");
            for (p.categories, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                try buf.print(gpa, "`{s}`", .{c});
            }
            try buf.appendSlice(gpa, "\n- Tags: ");
            for (p.tags, 0..) |t, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                try buf.print(gpa, "`{s}`", .{t});
            }
            try buf.appendSlice(gpa, "\n\n");
        }
    }

    try buf.appendSlice(gpa, "## Parent / page relationships\n\n");
    if (report.parent_relationships.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        try buf.appendSlice(gpa, "| child | parent_post_id | parent_entity | reason | confidence | note |\n|---|---|---|---|---|---|\n");
        for (report.parent_relationships) |r| {
            try buf.print(gpa, "| `{s}` | `{s}` | `{s}` | {s} | {s} | {s} |\n", .{
                r.child_entity_id,
                r.parent_post_id,
                r.parent_entity_id orelse "—",
                r.reason,
                r.confidence,
                r.note,
            });
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Internal links\n\n");
    try buf.appendSlice(gpa, "| source | kind | target | status | resolved |\n|---|---|---|---|---|\n");
    for (report.links) |l| {
        if (std.mem.eql(u8, l.status, "external_skipped")) continue;
        try buf.print(gpa, "| `{s}` | {s} | `{s}` | {s} | `{s}` |\n", .{
            l.source_output,
            l.kind,
            l.target,
            l.status,
            l.resolved_post_id orelse "—",
        });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Media references\n\n");
    try buf.appendSlice(gpa, "| source | referenced | local | status |\n|---|---|---|---|\n");
    for (report.media_references) |m| {
        try buf.print(gpa, "| `{s}` | `{s}` | `{s}` | {s} |\n", .{
            m.source_output,
            m.referenced,
            m.local_path orelse "—",
            m.status,
        });
    }
    try buf.appendSlice(gpa, "\n");

    try buf.appendSlice(gpa, "## Missing media\n\n");
    if (report.missing_media.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.missing_media) |m| {
            try buf.print(gpa, "- `{s}` from `{s}` ({s})\n", .{ m.referenced, m.source_output, m.status });
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Raw HTML, shortcodes, embeds, galleries, custom blocks\n\n");
    if (report.features.len == 0) {
        try buf.appendSlice(gpa, "_None detected._\n\n");
    } else {
        try buf.appendSlice(gpa, "| source | code | classification | message |\n|---|---|---|---|\n");
        for (report.features) |f| {
            try buf.print(gpa, "| `{s}` | `{s}` | **{s}** | {s} |\n", .{
                f.source_output,
                f.code,
                f.classification.jsonName(),
                f.message,
            });
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Duplicate slugs\n\n");
    if (report.slug_conflicts.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.slug_conflicts) |c| {
            try buf.print(gpa, "- **`{s}`** ({s}): ", .{ c.slug, c.kind });
            for (c.post_ids, 0..) |pid, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                try buf.print(gpa, "post_id={s}", .{pid});
            }
            try buf.appendSlice(gpa, "\n");
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Unsupported content (preserved)\n\n");
    if (report.unsupported_items.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.unsupported_items) |u| {
            try buf.print(gpa, "- post_id=`{s}` type=`{s}` title={s} → `{s}` — {s}\n", .{
                u.post_id,
                u.post_type,
                u.title,
                u.preserved_path,
                u.reason,
            });
        }
        try buf.appendSlice(gpa, "\n");
    }

    try buf.appendSlice(gpa, "## Human review queue\n\n");
    if (report.human_review.len == 0) {
        try buf.appendSlice(gpa, "_None._\n\n");
    } else {
        for (report.human_review) |h| {
            try buf.print(gpa, "### `{s}` (post_id={s})\n\n", .{ h.source_output, h.source_post_id });
            try buf.print(gpa, "- Reason: {s}\n", .{h.reason});
            try buf.appendSlice(gpa, "- Codes: ");
            for (h.codes, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                try buf.print(gpa, "`{s}`", .{c});
            }
            try buf.appendSlice(gpa, "\n\n");
        }
    }

    try buf.appendSlice(gpa, "## Provenance index\n\n");
    try buf.appendSlice(gpa, "Every generated Markdown file carries a provenance HTML comment and appears here.\n\n");
    try buf.appendSlice(gpa, "| output_path | post_id | type | conversion |\n|---|---|---|---|\n");
    for (report.provenance) |p| {
        try buf.print(gpa, "| `{s}` | `{s}` | {s} | {s} |\n", .{
            p.output_path,
            p.post_id,
            p.post_type,
            p.conversion.jsonName(),
        });
    }
    try buf.appendSlice(gpa, "\n---\n\nMachine-readable twin: `report.json`.\nGenerated Markdown under `content/`.\n");

    return try buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// run()
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    // Read WXR from cwd-relative path without modifying it.
    const wxr_bytes = blk: {
        // Support path with directories
        if (std.fs.path.dirname(opts.wxr_path)) |dir_name| {
            var dir = try Io.Dir.cwd().openDir(io, dir_name, .{});
            defer dir.close(io);
            const base = std.fs.path.basename(opts.wxr_path);
            break :blk try readFileAlloc(io, dir, base, gpa);
        } else {
            break :blk try readFileAlloc(io, Io.Dir.cwd(), opts.wxr_path, gpa);
        }
    };
    defer gpa.free(wxr_bytes);

    // Snapshot hash not required; preserve by never writing to wxr path.
    const doc = try parseWxr(retain, wxr_bytes);

    // Optional media inventory
    var media_files: []const []const u8 = &.{};
    if (opts.media_dir) |mdir| {
        var list: std.ArrayList([]const u8) = .empty;
        var mroot = try Io.Dir.cwd().openDir(io, mdir, .{ .iterate = true });
        defer mroot.close(io);
        try collectMediaFiles(io, gpa, retain, mroot, "", &list);
        std.mem.sort([]const u8, list.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        media_files = try list.toOwnedSlice(gpa);
    }
    defer if (media_files.len > 0) gpa.free(media_files);

    // Index items by post_id and by link/slug for link resolution
    var by_id: std.StringHashMapUnmanaged(WxrItem) = .empty;
    defer by_id.deinit(gpa);
    for (doc.items) |it| {
        try by_id.put(gpa, it.post_id, it);
    }

    // Build meta for posts/pages
    var metas: std.ArrayList(ItemMeta) = .empty;
    defer metas.deinit(gpa);

    var slug_to_ids: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    defer {
        var it = slug_to_ids.iterator();
        while (it.next()) |e| e.value_ptr.deinit(gpa);
        slug_to_ids.deinit(gpa);
    }

    for (doc.items) |item| {
        if (!std.mem.eql(u8, item.post_type, "post") and !std.mem.eql(u8, item.post_type, "page")) continue;
        const raw_slug = if (item.post_name.len > 0) item.post_name else try slugifyAlloc(retain, item.title);
        const slug = try sanitizeEntitySegment(retain, raw_slug);
        const entity_id = try proposeEntityId(retain, item.post_type, slug);
        const output_path = try proposeOutputPath(retain, entity_id);
        try metas.append(gpa, .{
            .item = item,
            .entity_id = entity_id,
            .output_path = output_path,
            .slug = slug,
        });
        const gop = try slug_to_ids.getOrPut(gpa, slug);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            // key must be retained
            gop.key_ptr.* = try retain.dupe(u8, slug);
        }
        try gop.value_ptr.append(gpa, item.post_id);
    }

    // Sort metas by entity_id for deterministic emission
    std.mem.sort(ItemMeta, metas.items, {}, struct {
        fn less(_: void, a: ItemMeta, b: ItemMeta) bool {
            return std.mem.order(u8, a.entity_id, b.entity_id) == .lt;
        }
    }.less);

    // Prepare out dir
    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out_root = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out_root.close(io);

    var pages: std.ArrayList(PageRecord) = .empty;
    defer pages.deinit(gpa);
    var parents: std.ArrayList(ParentRel) = .empty;
    defer parents.deinit(gpa);
    var all_links: std.ArrayList(LinkFinding) = .empty;
    defer all_links.deinit(gpa);
    var all_media: std.ArrayList(MediaRef) = .empty;
    defer all_media.deinit(gpa);
    var all_features: std.ArrayList(FeatureFinding) = .empty;
    defer all_features.deinit(gpa);
    var unsupported: std.ArrayList(UnsupportedItem) = .empty;
    defer unsupported.deinit(gpa);
    var human: std.ArrayList(HumanReview) = .empty;
    defer human.deinit(gpa);
    var provenance: std.ArrayList(Provenance) = .empty;
    defer provenance.deinit(gpa);

    // Map post_id → entity_id for pages/posts
    var id_to_entity: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer id_to_entity.deinit(gpa);
    for (metas.items) |m| {
        try id_to_entity.put(gpa, m.item.post_id, m.entity_id);
    }

    // Also emit trunk landing stubs for posts/ and pages/ when we have those types
    var have_posts = false;
    var have_pages = false;
    for (metas.items) |m| {
        if (std.mem.eql(u8, m.item.post_type, "post")) have_posts = true;
        if (std.mem.eql(u8, m.item.post_type, "page")) have_pages = true;
    }

    // Convert each post/page
    for (metas.items) |m| {
        const item = m.item;
        var conv = try convertItemBody(retain, item, m.output_path, opts.wxr_path);

        // Collect categories / tags
        var cats: std.ArrayList([]const u8) = .empty;
        var tags: std.ArrayList([]const u8) = .empty;
        var code_list: std.ArrayList([]const u8) = .empty;
        for (conv.feature_codes) |fc| try code_list.append(retain, fc);
        for (item.categories) |c| {
            if (std.mem.eql(u8, c.domain, "category")) {
                try cats.append(retain, c.nicename);
            } else if (std.mem.eql(u8, c.domain, "post_tag") or std.mem.eql(u8, c.domain, "tag")) {
                try tags.append(retain, c.nicename);
            } else {
                // other taxonomies → tags + human review
                try tags.append(retain, c.nicename);
                conv.classification = ConversionClass.worse(conv.classification, .human_review);
                try appendUniqueCode(retain, &code_list, "unknown_taxonomy");
            }
        }

        // Parent proposal
        var proposed_parent: ?[]const u8 = null;
        const parent_id = item.post_parent;
        if (parent_id.len > 0 and !std.mem.eql(u8, parent_id, "0")) {
            if (id_to_entity.get(parent_id)) |pe| {
                // Boris is one-level: satellites parent trunks only.
                // If parent is itself a satellite, flag human review and parent to type trunk.
                if (std.mem.eql(u8, item.post_type, "page")) {
                    // Prefer direct parent entity; note depth risk.
                    const parent_item = by_id.get(parent_id);
                    const parent_of_parent = if (parent_item) |pi| pi.post_parent else "0";
                    if (parent_of_parent.len > 0 and !std.mem.eql(u8, parent_of_parent, "0")) {
                        proposed_parent = "pages";
                        conv.classification = ConversionClass.worse(conv.classification, .human_review);
                        try appendUniqueCode(retain, &code_list, "deep_page_hierarchy");
                        try parents.append(gpa, .{
                            .child_post_id = item.post_id,
                            .child_entity_id = m.entity_id,
                            .parent_post_id = parent_id,
                            .parent_entity_id = pe,
                            .reason = "wp_post_parent",
                            .confidence = "low",
                            .note = "Parent is not a trunk; Boris allows one hop only — proposed parent pages trunk",
                        });
                    } else {
                        // Parent page becomes a trunk candidate; child parents to parent entity.
                        // Actually Boris: only trunks can be parents. Parent page without parent is trunk-like.
                        proposed_parent = pe;
                        try parents.append(gpa, .{
                            .child_post_id = item.post_id,
                            .child_entity_id = m.entity_id,
                            .parent_post_id = parent_id,
                            .parent_entity_id = pe,
                            .reason = "wp_post_parent",
                            .confidence = "medium",
                            .note = "Page hierarchy mapped to parent entity id; ensure parent has no parent (trunk)",
                        });
                    }
                } else {
                    proposed_parent = "posts";
                    try parents.append(gpa, .{
                        .child_post_id = item.post_id,
                        .child_entity_id = m.entity_id,
                        .parent_post_id = parent_id,
                        .parent_entity_id = pe,
                        .reason = "wp_post_parent",
                        .confidence = "low",
                        .note = "Non-page parent ignored for Boris graph; using posts trunk",
                    });
                }
            } else {
                proposed_parent = if (std.mem.eql(u8, item.post_type, "page")) "pages" else "posts";
                conv.classification = ConversionClass.worse(conv.classification, .human_review);
                try appendUniqueCode(retain, &code_list, "missing_parent_item");
                try parents.append(gpa, .{
                    .child_post_id = item.post_id,
                    .child_entity_id = m.entity_id,
                    .parent_post_id = parent_id,
                    .parent_entity_id = null,
                    .reason = "wp_post_parent",
                    .confidence = "low",
                    .note = "Parent post_id not present as post/page in export",
                });
            }
        } else {
            // Top-level: posts → parent posts trunk; pages → no parent (trunk) or parent pages
            if (std.mem.eql(u8, item.post_type, "post")) {
                proposed_parent = "posts";
            } else if (std.mem.eql(u8, item.post_type, "page")) {
                proposed_parent = null; // trunk page
            }
        }

        const status_boris = mapWpStatus(item.status);
        if (!std.mem.eql(u8, item.status, "publish")) {
            conv.classification = ConversionClass.worse(conv.classification, .human_review);
            try appendUniqueCode(retain, &code_list, "non_publish_status");
        }

        // Boris tags: merge WP tags + categories (categories become tags for closed grammar)
        var boris_tags: std.ArrayList([]const u8) = .empty;
        for (tags.items) |t| try boris_tags.append(retain, t);
        for (cats.items) |c| {
            // avoid dups
            var dup = false;
            for (boris_tags.items) |t| {
                if (std.mem.eql(u8, t, c)) dup = true;
            }
            if (!dup) try boris_tags.append(retain, c);
        }

        const fm = try buildFrontmatter(retain, if (item.title.len > 0) item.title else m.slug, proposed_parent, status_boris, boris_tags.items);

        // Resolve links against site URLs and item links
        for (conv.links) |lnk| {
            var resolved = lnk;
            resolved.source_post_id = try retain.dupe(u8, lnk.source_post_id);
            resolved.source_output = try retain.dupe(u8, lnk.source_output);
            resolved.kind = try retain.dupe(u8, lnk.kind);
            resolved.target = try retain.dupe(u8, lnk.target);
            resolved.status = try retain.dupe(u8, lnk.status);

            if (std.mem.eql(u8, lnk.status, "external_skipped")) {
                // Check if actually site-local
                const base = if (doc.base_blog_url.len > 0) doc.base_blog_url else doc.base_site_url;
                if (base.len > 0 and std.mem.startsWith(u8, lnk.target, base)) {
                    resolved.status = try retain.dupe(u8, "unresolved");
                    resolved.kind = try retain.dupe(u8, "internal_href");
                    // try match by link
                    for (doc.items) |it2| {
                        if (it2.link.len > 0 and (std.mem.eql(u8, it2.link, lnk.target) or std.mem.startsWith(u8, lnk.target, it2.link))) {
                            resolved.resolved_post_id = try retain.dupe(u8, it2.post_id);
                            resolved.status = try retain.dupe(u8, "ok");
                            break;
                        }
                    }
                }
            } else {
                for (doc.items) |it2| {
                    if (it2.link.len > 0 and std.mem.eql(u8, it2.link, lnk.target)) {
                        resolved.resolved_post_id = try retain.dupe(u8, it2.post_id);
                        resolved.status = try retain.dupe(u8, "ok");
                        break;
                    }
                    if (it2.post_name.len > 0 and (std.mem.endsWith(u8, lnk.target, it2.post_name) or std.mem.endsWith(u8, lnk.target, try std.fmt.allocPrint(retain, "{s}/", .{it2.post_name})))) {
                        resolved.resolved_post_id = try retain.dupe(u8, it2.post_id);
                        resolved.status = try retain.dupe(u8, "ok");
                        break;
                    }
                }
            }
            try all_links.append(gpa, resolved);
            if (std.mem.eql(u8, resolved.status, "unresolved") and std.mem.eql(u8, resolved.kind, "internal_href")) {
                conv.classification = ConversionClass.worse(conv.classification, .human_review);
                try appendUniqueCode(retain, &code_list, "unresolved_internal_link");
            }
        }

        // Media matching
        for (conv.media_refs) |mr| {
            var entry = mr;
            entry.source_post_id = try retain.dupe(u8, mr.source_post_id);
            entry.source_output = try retain.dupe(u8, mr.source_output);
            entry.referenced = try retain.dupe(u8, mr.referenced);
            if (mediaRelativeKey(mr.referenced)) |key| {
                if (findLocalMedia(media_files, key)) |local| {
                    entry.local_path = try retain.dupe(u8, local);
                    entry.status = "present";
                } else {
                    entry.local_path = null;
                    entry.status = "missing";
                    conv.classification = ConversionClass.worse(conv.classification, .human_review);
                    try appendUniqueCode(retain, &code_list, "missing_media");
                }
            } else if (opts.media_dir != null) {
                const base = std.fs.path.basename(mr.referenced);
                if (findLocalMedia(media_files, base)) |local| {
                    entry.local_path = try retain.dupe(u8, local);
                    entry.status = "present";
                } else {
                    entry.status = "missing";
                    conv.classification = ConversionClass.worse(conv.classification, .human_review);
                    try appendUniqueCode(retain, &code_list, "missing_media");
                }
            } else {
                entry.status = "missing";
                entry.local_path = null;
                // no media dir: still report
                try appendUniqueCode(retain, &code_list, "media_unverified");
                conv.classification = ConversionClass.worse(conv.classification, .human_review);
            }
            try all_media.append(gpa, entry);
        }

        for (conv.features) |f| {
            try all_features.append(gpa, .{
                .source_post_id = try retain.dupe(u8, f.source_post_id),
                .source_output = try retain.dupe(u8, f.source_output),
                .code = try retain.dupe(u8, f.code),
                .classification = f.classification,
                .excerpt = try retain.dupe(u8, f.excerpt),
                .message = try retain.dupe(u8, f.message),
            });
        }

        const prov: Provenance = .{
            .output_path = m.output_path,
            .source_export = opts.wxr_path,
            .post_id = item.post_id,
            .post_type = item.post_type,
            .guid = item.guid,
            .post_name = item.post_name,
            .author = item.creator,
            .post_date = item.post_date,
            .link = item.link,
            .conversion = conv.classification,
        };
        const prov_comment = try buildProvenanceComment(retain, prov);

        // Assemble file after final classification
        var file_buf: std.ArrayList(u8) = .empty;
        try file_buf.appendSlice(retain, fm);
        try file_buf.append(retain, '\n');
        try file_buf.appendSlice(retain, prov_comment);
        try file_buf.append(retain, '\n');
        try file_buf.appendSlice(retain, conv.markdown_body);
        if (conv.markdown_body.len == 0 or conv.markdown_body[conv.markdown_body.len - 1] != '\n') {
            try file_buf.append(retain, '\n');
        }
        try writeBytes(io, out_root, m.output_path, file_buf.items);

        const codes_slice = try code_list.toOwnedSlice(retain);
        try pages.append(gpa, .{
            .output_path = m.output_path,
            .post_id = item.post_id,
            .post_type = item.post_type,
            .title = item.title,
            .slug = m.slug,
            .author = item.creator,
            .post_date = item.post_date,
            .status_wp = item.status,
            .status_boris = status_boris,
            .categories = try cats.toOwnedSlice(retain),
            .tags = try tags.toOwnedSlice(retain),
            .parent_post_id = parent_id,
            .proposed_entity_id = m.entity_id,
            .proposed_parent = proposed_parent,
            .proposed_frontmatter = fm,
            .conversion = conv.classification,
            .feature_codes = codes_slice,
        });

        try provenance.append(gpa, prov);

        if (conv.classification == .human_review or conv.classification == .unsupported) {
            try human.append(gpa, .{
                .source_post_id = item.post_id,
                .source_output = m.output_path,
                .reason = if (conv.classification == .unsupported)
                    "Contains unsupported constructs preserved in body; author review required"
                else
                    "Flagged for human review (status, media, hierarchy, or links)",
                .codes = codes_slice,
            });
        }
    }

    // Trunk stubs
    if (have_posts) {
        const fm = try buildFrontmatter(retain, "Posts", null, "published", &.{"posts"});
        const body =
            \\<!-- boris-migration-provenance
            \\source_format: wordpress-wxr
            \\synthetic: trunk-stub
            \\entity_id: posts
            \\conversion: exact
            \\-->
            \\
            \\# Posts
            \\
            \\Trunk landing for migrated WordPress posts.
            \\
        ;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(retain, fm);
        try buf.append(retain, '\n');
        try buf.appendSlice(retain, body);
        try writeBytes(io, out_root, "content/posts.md", buf.items);
        try provenance.append(gpa, .{
            .output_path = "content/posts.md",
            .source_export = opts.wxr_path,
            .post_id = "synthetic:posts",
            .post_type = "trunk",
            .guid = "",
            .post_name = "posts",
            .author = "",
            .post_date = "",
            .link = "",
            .conversion = .exact,
        });
        try pages.append(gpa, .{
            .output_path = "content/posts.md",
            .post_id = "synthetic:posts",
            .post_type = "trunk",
            .title = "Posts",
            .slug = "posts",
            .author = "",
            .post_date = "",
            .status_wp = "publish",
            .status_boris = "published",
            .categories = &.{},
            .tags = &.{"posts"},
            .parent_post_id = "0",
            .proposed_entity_id = "posts",
            .proposed_parent = null,
            .proposed_frontmatter = fm,
            .conversion = .exact,
            .feature_codes = &.{},
        });
    }
    if (have_pages) {
        const fm = try buildFrontmatter(retain, "Pages", null, "published", &.{"pages"});
        const body =
            \\<!-- boris-migration-provenance
            \\source_format: wordpress-wxr
            \\synthetic: trunk-stub
            \\entity_id: pages
            \\conversion: exact
            \\-->
            \\
            \\# Pages
            \\
            \\Trunk landing for migrated WordPress pages (use when hierarchy was flattened).
            \\
        ;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(retain, fm);
        try buf.append(retain, '\n');
        try buf.appendSlice(retain, body);
        try writeBytes(io, out_root, "content/pages.md", buf.items);
        try provenance.append(gpa, .{
            .output_path = "content/pages.md",
            .source_export = opts.wxr_path,
            .post_id = "synthetic:pages",
            .post_type = "trunk",
            .guid = "",
            .post_name = "pages",
            .author = "",
            .post_date = "",
            .link = "",
            .conversion = .exact,
        });
        try pages.append(gpa, .{
            .output_path = "content/pages.md",
            .post_id = "synthetic:pages",
            .post_type = "trunk",
            .title = "Pages",
            .slug = "pages",
            .author = "",
            .post_date = "",
            .status_wp = "publish",
            .status_boris = "published",
            .categories = &.{},
            .tags = &.{"pages"},
            .parent_post_id = "0",
            .proposed_entity_id = "pages",
            .proposed_parent = null,
            .proposed_frontmatter = fm,
            .conversion = .exact,
            .feature_codes = &.{},
        });
    }

    // Unsupported item types: preserve raw under content/_preserved/
    for (doc.items) |item| {
        if (std.mem.eql(u8, item.post_type, "post") or std.mem.eql(u8, item.post_type, "page")) continue;
        const safe_type = try sanitizeEntitySegment(retain, item.post_type);
        const safe_id = if (item.post_id.len > 0) item.post_id else "unknown";
        const path = try std.fmt.allocPrint(retain, "content/_preserved/{s}-{s}.md", .{ safe_type, safe_id });
        const reason = if (std.mem.eql(u8, item.post_type, "attachment"))
            "attachment item; not a Boris page — preserved for media inventory"
        else
            "non post/page post_type; preserved raw for review";

        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(retain, "---\n");
        try body.print(retain, "title: {s}\n", .{if (item.title.len > 0) item.title else safe_id});
        try body.appendSlice(retain, "status: draft\n");
        try body.appendSlice(retain, "tags: [preserved, wordpress]\n");
        try body.appendSlice(retain, "---\n\n");
        try body.appendSlice(retain, "<!-- boris-migration-provenance\n");
        try body.appendSlice(retain, "source_format: wordpress-wxr\n");
        try body.print(retain, "post_id: {s}\n", .{item.post_id});
        try body.print(retain, "post_type: {s}\n", .{item.post_type});
        try body.appendSlice(retain, "conversion: unsupported\n");
        try body.appendSlice(retain, "-->\n\n");
        try body.appendSlice(retain, "> **Preserved unsupported WordPress item** — not silently discarded.\n\n");
        try body.print(retain, "- post_type: `{s}`\n", .{item.post_type});
        try body.print(retain, "- post_id: `{s}`\n", .{item.post_id});
        try body.print(retain, "- guid: `{s}`\n", .{item.guid});
        try body.print(retain, "- attachment_url: `{s}`\n", .{item.attachment_url});
        try body.print(retain, "- link: `{s}`\n\n", .{item.link});
        try body.appendSlice(retain, "### Original content:encoded\n\n");
        try body.appendSlice(retain, "```html\n");
        try body.appendSlice(retain, item.content_encoded);
        if (item.content_encoded.len > 0 and item.content_encoded[item.content_encoded.len - 1] != '\n') try body.append(retain, '\n');
        try body.appendSlice(retain, "```\n");
        try writeBytes(io, out_root, path, body.items);

        try unsupported.append(gpa, .{
            .post_id = item.post_id,
            .post_type = item.post_type,
            .title = item.title,
            .reason = reason,
            .preserved_path = path,
        });
        try provenance.append(gpa, .{
            .output_path = path,
            .source_export = opts.wxr_path,
            .post_id = item.post_id,
            .post_type = item.post_type,
            .guid = item.guid,
            .post_name = item.post_name,
            .author = item.creator,
            .post_date = item.post_date,
            .link = item.link,
            .conversion = .unsupported,
        });

        // Attachment media inventory
        if (std.mem.eql(u8, item.post_type, "attachment") and item.attachment_url.len > 0) {
            var entry: MediaRef = .{
                .source_post_id = item.post_id,
                .source_output = path,
                .referenced = item.attachment_url,
                .local_path = null,
                .status = "attachment_only",
            };
            if (mediaRelativeKey(item.attachment_url)) |key| {
                if (findLocalMedia(media_files, key)) |local| {
                    entry.local_path = local;
                    entry.status = "present";
                } else {
                    entry.status = "missing";
                }
            } else if (opts.media_dir != null) {
                entry.status = if (findLocalMedia(media_files, std.fs.path.basename(item.attachment_url)) != null) "present" else "missing";
                if (std.mem.eql(u8, entry.status, "present")) {
                    entry.local_path = findLocalMedia(media_files, std.fs.path.basename(item.attachment_url));
                }
            } else {
                entry.status = "missing";
            }
            try all_media.append(gpa, entry);
        }
    }

    // Slug conflicts
    var slug_conflicts: std.ArrayList(SlugConflict) = .empty;
    defer slug_conflicts.deinit(gpa);
    var slug_it = slug_to_ids.iterator();
    while (slug_it.next()) |e| {
        if (e.value_ptr.items.len < 2) continue;
        var paths: std.ArrayList([]const u8) = .empty;
        for (e.value_ptr.items) |pid| {
            for (metas.items) |m| {
                if (std.mem.eql(u8, m.item.post_id, pid)) {
                    try paths.append(retain, m.output_path);
                }
            }
        }
        // Sort ids for determinism
        std.mem.sort([]const u8, e.value_ptr.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        try slug_conflicts.append(gpa, .{
            .slug = e.key_ptr.*,
            .post_ids = try retain.dupe([]const u8, e.value_ptr.items),
            .output_paths = try paths.toOwnedSlice(retain),
            .kind = "duplicate_post_name",
        });
        // human review for conflicting pages
        for (e.value_ptr.items) |pid| {
            for (pages.items) |*p| {
                if (std.mem.eql(u8, p.post_id, pid)) {
                    p.conversion = ConversionClass.worse(p.conversion, .human_review);
                }
            }
        }
    }
    std.mem.sort(SlugConflict, slug_conflicts.items, {}, struct {
        fn less(_: void, a: SlugConflict, b: SlugConflict) bool {
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.less);

    // Missing media list
    var missing: std.ArrayList(MediaRef) = .empty;
    defer missing.deinit(gpa);
    for (all_media.items) |m| {
        if (std.mem.eql(u8, m.status, "missing")) try missing.append(gpa, m);
    }

    // Sort report arrays for determinism
    std.mem.sort(PageRecord, pages.items, {}, struct {
        fn less(_: void, a: PageRecord, b: PageRecord) bool {
            return std.mem.order(u8, a.output_path, b.output_path) == .lt;
        }
    }.less);
    std.mem.sort(ParentRel, parents.items, {}, struct {
        fn less(_: void, a: ParentRel, b: ParentRel) bool {
            return std.mem.order(u8, a.child_entity_id, b.child_entity_id) == .lt;
        }
    }.less);
    std.mem.sort(LinkFinding, all_links.items, {}, struct {
        fn less(_: void, a: LinkFinding, b: LinkFinding) bool {
            const o = std.mem.order(u8, a.source_output, b.source_output);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.target, b.target) == .lt;
        }
    }.less);
    std.mem.sort(MediaRef, all_media.items, {}, struct {
        fn less(_: void, a: MediaRef, b: MediaRef) bool {
            const o = std.mem.order(u8, a.source_output, b.source_output);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.referenced, b.referenced) == .lt;
        }
    }.less);
    std.mem.sort(MediaRef, missing.items, {}, struct {
        fn less(_: void, a: MediaRef, b: MediaRef) bool {
            return std.mem.order(u8, a.referenced, b.referenced) == .lt;
        }
    }.less);
    std.mem.sort(FeatureFinding, all_features.items, {}, struct {
        fn less(_: void, a: FeatureFinding, b: FeatureFinding) bool {
            const o = std.mem.order(u8, a.source_output, b.source_output);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.code, b.code) == .lt;
        }
    }.less);
    std.mem.sort(UnsupportedItem, unsupported.items, {}, struct {
        fn less(_: void, a: UnsupportedItem, b: UnsupportedItem) bool {
            return std.mem.order(u8, a.preserved_path, b.preserved_path) == .lt;
        }
    }.less);
    std.mem.sort(HumanReview, human.items, {}, struct {
        fn less(_: void, a: HumanReview, b: HumanReview) bool {
            return std.mem.order(u8, a.source_output, b.source_output) == .lt;
        }
    }.less);
    std.mem.sort(Provenance, provenance.items, {}, struct {
        fn less(_: void, a: Provenance, b: Provenance) bool {
            return std.mem.order(u8, a.output_path, b.output_path) == .lt;
        }
    }.less);

    const report: Report = .{
        .source_export = opts.wxr_path,
        .media_dir = opts.media_dir,
        .site_title = doc.title,
        .base_site_url = doc.base_site_url,
        .base_blog_url = doc.base_blog_url,
        .authors = doc.authors,
        .taxonomies = doc.taxonomies,
        .pages = pages.items,
        .parent_relationships = parents.items,
        .links = all_links.items,
        .media_references = all_media.items,
        .missing_media = missing.items,
        .features = all_features.items,
        .slug_conflicts = slug_conflicts.items,
        .unsupported_items = unsupported.items,
        .human_review = human.items,
        .provenance = provenance.items,
    };

    const json = try emitJson(gpa, report);
    defer gpa.free(json);
    const md = try emitMarkdown(gpa, report);
    defer gpa.free(md);

    try writeBytes(io, out_root, "report.json", json);
    try writeBytes(io, out_root, "REPORT.md", md);

    if (!opts.quiet) {
        std.debug.print("wordpress-migration-lab: wrote {s}/content/, {s}/report.json, {s}/REPORT.md\n", .{
            opts.out_dir,
            opts.out_dir,
            opts.out_dir,
        });
        std.debug.print("  pages={d} features={d} missing_media={d} human_review={d} preserved={d}\n", .{
            report.pages.len,
            report.features.len,
            report.missing_media.len,
            report.human_review.len,
            report.unsupported_items.len,
        });
    }
}
