//! Compiler-owned Nostr head emit for the HTML build (#571).
//!
//! When `boris --profile PATH` names an enabled `nostr` section, eligible
//! allowlisted pages receive one alternate link:
//!
//! ```html
//!   <link rel="alternate" href="nostr:naddr1…">
//! ```
//!
//! The address is the same NIP-19 `naddr` the plan emits. Markdown-body
//! inspection stays on `boris nostr plan`; this path never fails the HTML
//! build for a hard-wrapped paragraph.

const std = @import("std");
const graph = @import("graph.zig");
const identity = @import("identity.zig");
const nostr = @import("nostr.zig");
const page_mod = @import("page.zig");

pub const HeadConfig = struct {
    pubkey: []const u8,
    articles: []const []const u8,
    relays: []const []const u8,
};

pub fn isAllowlisted(config: *const HeadConfig, entity_id: []const u8) bool {
    for (config.articles) |id| {
        if (std.mem.eql(u8, id, entity_id)) return true;
    }
    return false;
}

/// True when the page is on the allowlist and would pass `nostr.ineligibility`
/// (dialect, draft, explicit id, title, summary, published_at).
pub fn pageEligible(config: *const HeadConfig, page: *const page_mod.DurablePage) bool {
    if (!isAllowlisted(config, page.entity_id)) return false;
    const status_name: ?[]const u8 = if (page.status) |s| @tagName(s) else null;
    const node = graph.Node{
        .id = page.entity_id,
        .source_path = page.source_path,
        .id_explicit = page.id_explicit,
        .title = page.title,
        .status = status_name,
        .published_at = page.published_at,
        .summary = page.summary,
    };
    return nostr.ineligibility(node, page.kind) == null;
}

/// `nostr:naddr…` for an eligible page, or null.
pub fn pageNaddrUri(
    config: *const HeadConfig,
    page: *const page_mod.DurablePage,
    out: []u8,
) ?[]const u8 {
    if (!pageEligible(config, page)) return null;
    var naddr_buf: [nostr.naddr_max_len]u8 = undefined;
    const naddr = nostr.encodeNaddr(
        page.entity_id,
        config.pubkey,
        nostr.kind_long_form,
        config.relays,
        &naddr_buf,
    ) catch return null;
    if (out.len < 6 + naddr.len) return null;
    @memcpy(out[0..6], "nostr:");
    @memcpy(out[6 .. 6 + naddr.len], naddr);
    return out[0 .. 6 + naddr.len];
}

/// Head fragment for one page. Empty when the page is not an eligible
/// allowlisted article.
pub fn pageHeadFragment(
    allocator: std.mem.Allocator,
    config: *const HeadConfig,
    page: *const page_mod.DurablePage,
) ![]u8 {
    var uri_buf: [nostr.naddr_max_len + 6]u8 = undefined;
    const uri = pageNaddrUri(config, page, &uri_buf) orelse return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "  <link rel=\"alternate\" href=\"");
    try out.appendSlice(allocator, uri);
    try out.appendSlice(allocator, "\">\n");
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

fn testPage(overrides: struct {
    entity_id: []const u8 = "articles/first",
    id_explicit: bool = true,
    title: ?[]const u8 = "First",
    summary: ?[]const u8 = "A summary.",
    published_at: ?[]const u8 = "2024-01-20T14:30:00Z",
    status: ?page_mod.Status = .published,
    kind: identity.ContentKind = .md,
}) page_mod.DurablePage {
    return .{
        .entity_id = overrides.entity_id,
        .id_explicit = overrides.id_explicit,
        .title = overrides.title,
        .source_path = "articles/first.md",
        .output_path = "articles/first.html",
        .status = overrides.status,
        .published_at = overrides.published_at,
        .summary = overrides.summary,
        .kind = overrides.kind,
    };
}

fn testConfig() HeadConfig {
    return .{
        .pubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
        .articles = &.{ "articles/first", "articles/second" },
        .relays = &.{"wss://relay.example.com"},
    };
}

test "emit: eligible allowlisted page gets a nostr:naddr alternate link" {
    const config = testConfig();
    const page = testPage(.{});
    const frag = try pageHeadFragment(testing.allocator, &config, &page);
    defer testing.allocator.free(frag);
    try testing.expect(std.mem.startsWith(u8, frag, "  <link rel=\"alternate\" href=\"nostr:naddr1"));
    try testing.expect(std.mem.endsWith(u8, frag, "\">\n"));
}

test "emit: draft, derived id, missing fields, and off-list pages stay empty" {
    const config = testConfig();
    const cases = [_]page_mod.DurablePage{
        testPage(.{ .status = .draft }),
        testPage(.{ .id_explicit = false }),
        testPage(.{ .title = null }),
        testPage(.{ .summary = null }),
        testPage(.{ .published_at = null }),
        testPage(.{ .entity_id = "not-listed" }),
        testPage(.{ .kind = .textile }),
    };
    for (cases) |page| {
        const frag = try pageHeadFragment(testing.allocator, &config, &page);
        defer testing.allocator.free(frag);
        try testing.expectEqualStrings("", frag);
    }
}

test "emit: the href matches encodeNaddr" {
    const config = testConfig();
    const page = testPage(.{});
    var naddr_buf: [nostr.naddr_max_len]u8 = undefined;
    const naddr = try nostr.encodeNaddr(page.entity_id, config.pubkey, nostr.kind_long_form, config.relays, &naddr_buf);
    const frag = try pageHeadFragment(testing.allocator, &config, &page);
    defer testing.allocator.free(frag);
    var expected_buf: [nostr.naddr_max_len + 64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "  <link rel=\"alternate\" href=\"nostr:{s}\">\n", .{naddr});
    try testing.expectEqualStrings(expected, frag);
}
