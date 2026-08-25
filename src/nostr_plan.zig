//! Deterministic, offline Nostr NIP-23 publication plan.
//!
//! This module answers one question and refuses to answer any other: given a
//! validated corpus and a `nostr` profile section, exactly which kind-30023
//! event intentions would be published, with exactly which bytes?
//!
//! ## The three stages, and why only the first one lives here
//!
//! ```text
//! boris nostr plan   → deterministic unsigned intentions   (this module)
//! boris nostr sign   → event id + BIP-340 signature        (later slice)
//! boris nostr publish→ relay delivery + observed evidence  (later slice)
//! ```
//!
//! The plan is an **event-intention document, not an incomplete event**. It
//! carries no `created_at`, no event id, and no signature, because all three
//! depend on the signing moment: `created_at` participates in the NIP-01 event
//! id, so a plan that guessed one would be a signing input masquerading as a
//! deterministic declaration. It reads no private key, opens no socket, calls
//! no clock, and reads no ambient git state, so identical eligible source and
//! configuration produce byte-identical bytes.
//!
//! ## Failing closed
//!
//! Selection is an explicit entity-id allowlist. An entity the author named but
//! Boris cannot publish is therefore a **failure**, never a silent omission —
//! quietly emitting a plan short one article is how a publication surface lies.
//! Every rejection names the entity, the defect, and the remediation.

const std = @import("std");
const aside = @import("aside.zig");
const content_asset = @import("content_asset.zig");
const diag = @import("diag.zig");
const doclink = @import("doclink.zig");
const github_pages = @import("github_pages.zig");
const graph = @import("graph.zig");
const identity = @import("identity.zig");
const include_mod = @import("include.zig");
const json_out = @import("json_out.zig");
const nostr = @import("nostr.zig");
const parser = @import("parser.zig");
const pipeline = @import("pipeline.zig");
const render = @import("render.zig");
const timings = @import("timings.zig");
const wikilink = @import("wikilink.zig");

const Io = std.Io;

pub const artifact_format = "boris-nostr-publication-plan";
pub const schema_version: u32 = 1;

/// The NIPs revision this mapping was derived against. Recorded in the artifact
/// so a consumer can tell which protocol text a plan was built from, and so a
/// future drift shows up as a value change rather than as a silent behavior
/// change (`docs/contracts/nostr-publication.md`).
pub const nips_revision = "656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab";
pub const nips_research_date = "2026-08-14";

pub const Options = struct {
    content_root: []const u8 = "content",
    input_format: identity.InputFormat = .markdown,
    quiet: bool = false,
    /// Normalized publication location. Required: the canonical article URL
    /// must be the URL that actually serves the page.
    location: *const github_pages.Location,
    /// Expected author public key (64 lowercase hex). Public, never a secret.
    pubkey: []const u8,
    /// Exact entity ids, pre-sorted and deduplicated by the profile parser.
    articles: []const []const u8,
    /// Normalized relay targets, pre-sorted by the profile parser.
    relays: []const []const u8,
    timeout_ms: usize = nostr.default_timeout_ms,
    retries: usize = 0,
    timings: ?*timings.Recorder = null,
};

pub const Result = struct {
    compile: pipeline.Result,
    /// Canonical artifact bytes, owned by the caller's allocator. Present only
    /// when every selected entity produced an intention.
    plan: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        if (self.plan) |bytes| self.allocator.free(bytes);
        self.compile.deinit();
    }

    pub fn ok(self: *const Result) bool {
        return self.compile.ok and self.plan != null;
    }
};

/// One kind-30023 event intention.
///
/// Every string is arena-owned for the duration of `run`, so the whole set is
/// released in one step after the artifact is serialized.
const Intention = struct {
    entity_id: []const u8,
    source_path: []const u8,
    canonical_url: []const u8,
    published_at: []const u8,
    published_at_unix: []const u8,
    tags: []const nostr.Tag,
    content: []const u8,
    content_digest: [nostr.digest_hex_len]u8,
    /// Digest over kind + tags + content only. Relay targets and signing time
    /// are deliberately excluded, which is what makes "unchanged since the last
    /// publish" answerable without a remote fetch, and what lets a
    /// relay-list-only change reuse an existing signature.
    intention_digest: [nostr.digest_hex_len]u8,
};

/// Build the plan. Returns a `Result` whose `plan` is null when any selected
/// entity was rejected; the reasons are appended to `compile.diagnostics`.
pub fn run(io: Io, gpa: std.mem.Allocator, options: Options) !Result {
    if (std.fs.path.isAbsolute(options.content_root)) return error.AbsolutePath;
    nostr.validatePubkey(options.pubkey) catch return error.InvalidPubkey;
    if (options.articles.len == 0 or options.relays.len == 0) return error.InvalidNostrConfig;

    var result = Result{ .allocator = gpa, .compile = try pipeline.compile(io, gpa, .{
        .content_root = options.content_root,
        .quiet = options.quiet,
        .input_format = options.input_format,
        .timings = options.timings,
    }) };
    errdefer result.deinit();
    if (!result.compile.ok) return result;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cwd = Io.Dir.cwd();
    var content_dir = try cwd.openDir(io, options.content_root, .{});
    defer content_dir.close(io);

    const pages = result.compile.pages.items;
    var assets = try loadAssets(io, gpa, content_dir, pages);
    defer assets.deinit();

    var intentions: std.ArrayList(Intention) = .empty;
    defer intentions.deinit(arena);

    for (options.articles) |entity_id| {
        const index = findPage(pages, entity_id) orelse {
            try reject(gpa, &result, .ENOSTRELIGIBILITY, entity_id, "", "selected entity does not exist in the validated corpus", "remove it from nostr.articles, or add the page");
            continue;
        };
        const node = pages[index];
        const kind = identity.contentKind(node.source_path) catch {
            try reject(gpa, &result, .ENOSTRELIGIBILITY, entity_id, node.source_path, "source extension is not a publishable page", "publish Markdown, or remove this entity from nostr.articles");
            continue;
        };
        if (nostr.ineligibility(node, kind)) |defect| {
            try reject(gpa, &result, .ENOSTRELIGIBILITY, entity_id, node.source_path, defect.name(), defect.remediation());
            continue;
        }
        const intention = buildIntention(io, gpa, arena, content_dir, &result, options, pages, &assets, index) catch |err| switch (err) {
            error.Rejected => continue,
            else => return err,
        };
        try intentions.append(arena, intention);
    }

    diag.sortDiagnostics(result.compile.diagnostics.items);
    if (diag.countErrors(result.compile.diagnostics.items) > 0) {
        result.compile.ok = false;
        result.compile.failure = .content;
        return result;
    }
    result.plan = try renderPlan(gpa, options, intentions.items);
    return result;
}

/// Content-local asset inventory for the whole corpus, so image destinations
/// resolve exactly as the HTML path resolves them.
fn loadAssets(io: Io, gpa: std.mem.Allocator, content_dir: Io.Dir, pages: []const graph.Node) !content_asset.SiteAssetInventory {
    const source_paths = try gpa.alloc([]const u8, pages.len);
    defer gpa.free(source_paths);
    const entity_ids = try gpa.alloc([]const u8, pages.len);
    defer gpa.free(entity_ids);
    for (pages, 0..) |page, i| {
        source_paths[i] = page.source_path;
        entity_ids[i] = page.id;
    }
    var fail: content_asset.FailInfo = .{};
    return try content_asset.loadSiteAssets(io, gpa, content_dir, source_paths, entity_ids, &fail);
}

fn findPage(pages: []const graph.Node, entity_id: []const u8) ?usize {
    for (pages, 0..) |page, i| {
        if (std.mem.eql(u8, page.id, entity_id)) return i;
    }
    return null;
}

/// Transform one page into its publication-safe Markdown view and its event
/// intention, or record why it cannot be published.
///
/// The transformation order matches the HTML path exactly (doc-links, then
/// includes, then wiki-links, then content-local images) so a published article
/// says what the published page says. The only difference is the destination
/// form: absolute canonical URLs, because these bytes are read off-site where a
/// relative href resolves against the wrong origin.
fn buildIntention(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    content_dir: Io.Dir,
    result: *Result,
    options: Options,
    pages: []const graph.Node,
    assets: *const content_asset.SiteAssetInventory,
    index: usize,
) !Intention {
    const node = pages[index];
    const base_url = options.location.base_url;

    const source = try readSource(io, content_dir, node.source_path, arena);
    const parsed = parser.parse(source);
    if (parsed.diagnostic != null) {
        // The corpus already validated, so a parse failure here means the file
        // changed under us rather than that the content is bad.
        try reject(gpa, result, .ENOSTRPLAN, node.id, node.source_path, "source no longer parses", "re-run after the content settles");
        return error.Rejected;
    }

    const output_path = try identity.safeOutputRelativePath(arena, node.id);
    const canonical_url = try nostr.canonicalArticleUrl(arena, base_url, node.id);

    const with_doc_links = doclink.rewrite(arena, parsed.doc.body, .{
        .nodes = pages,
        .source_path = node.source_path,
        .output_path = output_path,
        .base_url = base_url,
    }) catch {
        try reject(gpa, result, .ENOSTRMARKDOWN, node.id, node.source_path, "a documentation link does not resolve", "point the link at an existing page, or opt this entity out of nostr.articles");
        return error.Rejected;
    };

    var include_fail: include_mod.FailInfo = .{ .line_base = include_mod.frontmatterLineBase(source, parsed.doc.body_offset) };
    const expanded = include_mod.expandIncludes(io, content_dir, gpa, arena, with_doc_links, node.source_path, &include_fail) catch {
        try reject(gpa, result, .ENOSTRMARKDOWN, node.id, node.source_path, "an include does not expand", "fix the include, or opt this entity out of nostr.articles");
        return error.Rejected;
    };

    var wiki_fail: wikilink.FailInfo = .{};
    const with_wiki = wikilink.rewriteWikiLinksOpts(arena, expanded, pages, output_path, &wiki_fail, .{
        .base_url = base_url,
    }) catch {
        try reject(gpa, result, .ENOSTRMARKDOWN, node.id, node.source_path, "a wiki-link does not resolve", "point the link at an existing entity, or opt this entity out of nostr.articles");
        return error.Rejected;
    };

    var asset_fail: content_asset.FailInfo = .{};
    const with_assets = content_asset.rewriteImageLinks(arena, with_wiki, &assets.pages[index], output_path, &asset_fail, base_url) catch {
        try reject(gpa, result, .ENOSTRMARKDOWN, node.id, node.source_path, "a content-local image does not resolve", "add the asset, use an absolute URL, or opt this entity out of nostr.articles");
        return error.Rejected;
    };

    // Boris-only components have no interoperable Markdown form. Publishing
    // their source text would ship markup no Nostr client understands.
    const tok = try aside.tokenizeBody(with_assets, arena);
    if (tok.asides.len > 0 or tok.details.len > 0 or tok.hasErrors()) {
        try reject(gpa, result, .ENOSTRMARKDOWN, node.id, node.source_path, "Boris-only component (<Aside> or <Details>) is not interoperable Markdown", "replace it with ordinary Markdown, or opt this entity out of nostr.articles");
        return error.Rejected;
    }

    var inspect_arena = std.heap.ArenaAllocator.init(gpa);
    defer inspect_arena.deinit();
    if (try render.inspectMarkdown(with_assets, &inspect_arena)) |finding| {
        const line = nostr.decimal(finding.line);
        var message: std.ArrayList(u8) = .empty;
        try message.appendSlice(arena, "publication-safe Markdown line ");
        try message.appendSlice(arena, line.slice());
        try message.appendSlice(arena, ": ");
        try message.appendSlice(arena, finding.defect.name());
        const remediation = switch (finding.defect) {
            .raw_html => "NIP-23 forbids HTML in long-form content; replace it with Markdown",
            .hard_wrapped_paragraph => "join the paragraph onto one line; NIP-23 forbids hard-wrapped prose",
        };
        try reject(gpa, result, .ENOSTRMARKDOWN, node.id, node.source_path, message.items, remediation);
        return error.Rejected;
    }

    for (node.tags) |topic| {
        nostr.validateTopic(topic) catch {
            try reject(gpa, result, .ENOSTRELIGIBILITY, node.id, node.source_path, "a tag is not a valid NIP-24 topic", "use lowercase tags without a leading '#'");
            return error.Rejected;
        };
    }

    const unix = nostr.publishedAtUnix(node.published_at.?) catch {
        try reject(gpa, result, .ENOSTRTIME, node.id, node.source_path, "published_at is not a representable UTC timestamp", "use published_at: YYYY-MM-DDTHH:MM:SSZ at or after 1970-01-01");
        return error.Rejected;
    };
    // Every runtime string this module writes comes from a reviewed protocol
    // helper and goes out through `json_out`; the emitter itself formats
    // nothing (see `src/emitter_discipline_test.zig`).
    const published_at_decimal = nostr.decimal(unix);
    const published_at_unix = try arena.dupe(u8, published_at_decimal.slice());

    const tags = try arena.alloc(nostr.Tag, nostr.tagCount(node.tags.len));
    const built = nostr.buildTags(
        tags,
        node.id,
        node.title.?,
        node.summary.?,
        published_at_unix,
        node.tags,
        canonical_url,
    );

    var out = Intention{
        .entity_id = node.id,
        .source_path = node.source_path,
        .canonical_url = canonical_url,
        .published_at = node.published_at.?,
        .published_at_unix = published_at_unix,
        .tags = built,
        .content = with_assets,
        .content_digest = undefined,
        .intention_digest = undefined,
    };
    nostr.digestHex(with_assets, &out.content_digest);
    try nostr.intentionDigestHex(arena, built, with_assets, &out.intention_digest);
    return out;
}

fn readSource(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

/// Record a rejection as an ordinary error-severity diagnostic, so it prints
/// through the same path as every other content failure.
///
/// Message and remediation are allocated from the compile result's retain
/// arena, which is what owns every other diagnostic string; the list itself is
/// `gpa`-owned, exactly as `pipeline.Result.deinit` expects.
fn reject(
    gpa: std.mem.Allocator,
    result: *Result,
    code: diag.Code,
    entity_id: []const u8,
    source_path: []const u8,
    reason: []const u8,
    remediation: []const u8,
) !void {
    const retain = result.compile.arena.allocator();
    var message: std.ArrayList(u8) = .empty;
    errdefer message.deinit(retain);
    try message.appendSlice(retain, entity_id);
    try message.appendSlice(retain, ": ");
    try message.appendSlice(retain, reason);
    try result.compile.diagnostics.append(gpa, .{
        .severity = .error_,
        .code = code,
        .message = message.items,
        .remediation = try retain.dupe(u8, remediation),
        .source_path = if (source_path.len > 0) source_path else entity_id,
        // No source position: a defect's position is known only in the
        // publication-safe view (after includes), so claiming a source line
        // would point at the wrong byte. Where a position matters it is stated
        // in the message as a view line.
        .line = null,
        .column = null,
    });
}

// =============================================================================
// Serialization
// =============================================================================

/// Render the artifact: fixed key order, LF terminated, no wall-clock time, no
/// absolute paths, no host data, no secret.
fn renderPlan(gpa: std.mem.Allocator, options: Options, intentions: []const Intention) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, artifact_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"protocol\": {\n    \"nips_revision\": ");
    try json_out.writeString(&out, gpa, nips_revision);
    try out.appendSlice(gpa, ",\n    \"research_date\": ");
    try json_out.writeString(&out, gpa, nips_research_date);
    try out.appendSlice(gpa, ",\n    \"kind\": ");
    try json_out.writeUsize(&out, gpa, nostr.kind_long_form);
    try out.appendSlice(gpa, "\n  },\n  \"site\": {\n    \"base_url\": ");
    try json_out.writeString(&out, gpa, options.location.base_url);
    try out.appendSlice(gpa, ",\n    \"origin\": ");
    try json_out.writeString(&out, gpa, options.location.origin);
    try out.appendSlice(gpa, ",\n    \"base_path\": ");
    try json_out.writeString(&out, gpa, options.location.base_path);
    try out.appendSlice(gpa, "\n  },\n  \"author\": {\n    \"expected_pubkey\": ");
    try json_out.writeString(&out, gpa, options.pubkey);
    var npub_buf: [nostr.npub_max_len]u8 = undefined;
    const npub = try nostr.encodeNpub(options.pubkey, &npub_buf);
    try out.appendSlice(gpa, ",\n    \"npub\": ");
    try json_out.writeString(&out, gpa, npub);
    try out.appendSlice(gpa, "\n  },\n  \"delivery\": {\n    \"relays\": [");
    for (options.relays, 0..) |relay, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n      ");
        try json_out.writeString(&out, gpa, relay);
    }
    if (options.relays.len > 0) try out.appendSlice(gpa, "\n    ");
    try out.appendSlice(gpa, "],\n    \"timeout_ms\": ");
    try json_out.writeUsize(&out, gpa, options.timeout_ms);
    try out.appendSlice(gpa, ",\n    \"retries\": ");
    try json_out.writeUsize(&out, gpa, options.retries);
    try out.appendSlice(gpa, ",\n    \"config_digest\": ");
    try writeDeliveryDigest(&out, gpa, options);
    try out.appendSlice(gpa, "\n  },\n  \"articles\": [");
    for (intentions, 0..) |intention, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try renderIntention(&out, gpa, intention, options.pubkey, options.relays);
    }
    if (intentions.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "]\n}\n");
    return out.toOwnedSlice(gpa);
}

/// Digest of the delivery configuration alone, so a relay-list change is
/// visibly a delivery change and not an article change.
fn writeDeliveryDigest(out: *std.ArrayList(u8), gpa: std.mem.Allocator, options: Options) !void {
    var digest: [nostr.digest_hex_len]u8 = undefined;
    try nostr.deliveryDigestHex(gpa, options.relays, options.timeout_ms, options.retries, &digest);
    try json_out.writeString(out, gpa, &digest);
}

fn renderIntention(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    intention: Intention,
    pubkey: []const u8,
    relays: []const []const u8,
) !void {
    try out.appendSlice(gpa, "\n    {\n      \"entity_id\": ");
    try json_out.writeString(out, gpa, intention.entity_id);
    try out.appendSlice(gpa, ",\n      \"source_path\": ");
    try json_out.writeString(out, gpa, intention.source_path);
    try out.appendSlice(gpa, ",\n      \"canonical_url\": ");
    try json_out.writeString(out, gpa, intention.canonical_url);
    try out.appendSlice(gpa, ",\n      \"kind\": ");
    try json_out.writeUsize(out, gpa, nostr.kind_long_form);
    try out.appendSlice(gpa, ",\n      \"published_at\": ");
    try json_out.writeString(out, gpa, intention.published_at);
    try out.appendSlice(gpa, ",\n      \"tags\": [");
    for (intention.tags, 0..) |tag, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n        [");
        try json_out.writeString(out, gpa, tag.name);
        try out.appendSlice(gpa, ", ");
        try json_out.writeString(out, gpa, tag.value);
        try out.appendSlice(gpa, "]");
    }
    if (intention.tags.len > 0) try out.appendSlice(gpa, "\n      ");
    try out.appendSlice(gpa, "],\n      \"content\": ");
    try json_out.writeString(out, gpa, intention.content);
    try out.appendSlice(gpa, ",\n      \"content_digest\": ");
    try json_out.writeString(out, gpa, &intention.content_digest);
    try out.appendSlice(gpa, ",\n      \"intention_digest\": ");
    try json_out.writeString(out, gpa, &intention.intention_digest);
    try out.appendSlice(gpa, ",\n      \"created_at\": null,\n      \"created_at_policy\": ");
    try json_out.writeString(out, gpa, "signing-time");
    var naddr_buf: [nostr.naddr_max_len]u8 = undefined;
    const naddr = try nostr.encodeNaddr(intention.entity_id, pubkey, nostr.kind_long_form, relays, &naddr_buf);
    try out.appendSlice(gpa, ",\n      \"event_id\": null,\n      \"signature\": null,\n      \"naddr\": ");
    try json_out.writeString(out, gpa, naddr);
    try out.appendSlice(gpa, ",\n      \"naddr_uri\": ");
    var uri_buf: [nostr.naddr_max_len + 6]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "nostr:{s}", .{naddr});
    try json_out.writeString(out, gpa, uri);
    try out.appendSlice(gpa, "\n    }");
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const publication_profile = @import("publication_profile.zig");

const fixture_root = "docs/contracts/fixtures/nostr-publication";

fn readFixture(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
}

/// Parse a fixture profile and run the plan exactly as `boris nostr plan` does.
fn runFixture(profile_path: []const u8) !Result {
    const source = try readFixture(profile_path);
    defer testing.allocator.free(source);
    var request = try publication_profile.parseBytes(
        testing.allocator,
        .{ .root = try testing.allocator.dupe(u8, "/private/boris/nostr-fixture") },
        source,
        .{},
    );
    defer request.deinit(testing.allocator);

    const config = request.plan.nostr.?;
    const publication = request.plan.publication.?;
    return try run(testing.io, testing.allocator, .{
        .content_root = request.plan.input,
        .input_format = switch (request.plan.input_format) {
            .markdown => .markdown,
            .textile => .textile,
            .cook => .cook,
        },
        .quiet = true,
        .location = &publication.github_pages,
        .pubkey = config.pubkey,
        .articles = config.articles,
        .relays = config.relays,
        .timeout_ms = config.timeout_ms,
        .retries = config.retries,
    });
}

test "plan: eligible articles match the exact golden bytes" {
    const expected = try readFixture(fixture_root ++ "/expected/plan.json");
    defer testing.allocator.free(expected);
    var result = try runFixture(fixture_root ++ "/profile.json");
    defer result.deinit();
    try testing.expect(result.ok());
    try testing.expectEqualStrings(expected, result.plan.?);
}

test "plan: the artifact leaks no workspace, execution, or signing state" {
    var result = try runFixture(fixture_root ++ "/profile.json");
    defer result.deinit();
    const bytes = result.plan.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "/private/boris/nostr-fixture") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "docs/contracts/fixtures") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "nsec") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"jobs\"") == null);
    // `created_at`, the event id, and the signature exist as declared holes, so
    // a consumer cannot mistake a plan for a signable event.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"created_at\": null") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"event_id\": null") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"signature\": null") != null);
}

test "plan: repeated runs over one corpus are byte-identical" {
    var first = try runFixture(fixture_root ++ "/profile.json");
    defer first.deinit();
    var second = try runFixture(fixture_root ++ "/profile.json");
    defer second.deinit();
    try testing.expectEqualStrings(first.plan.?, second.plan.?);
}

test "plan: articles and relays are canonically ordered, not profile-ordered" {
    var result = try runFixture(fixture_root ++ "/profile.json");
    defer result.deinit();
    const bytes = result.plan.?;
    // The fixture profile lists `articles/second` first and the `relay`
    // host after the `a.relay` host; both come back sorted.
    const first_at = std.mem.indexOf(u8, bytes, "\"articles/first\"").?;
    const second_at = std.mem.indexOf(u8, bytes, "\"articles/second\"").?;
    try testing.expect(first_at < second_at);
    const a_relay = std.mem.indexOf(u8, bytes, "wss://a.relay.example.com").?;
    const relay = std.mem.indexOf(u8, bytes, "\"wss://relay.example.com\"").?;
    try testing.expect(a_relay < relay);
}

test "plan: every unpublishable selection is refused with its own diagnostic" {
    var result = try runFixture(fixture_root ++ "/profile-rejects.json");
    defer result.deinit();
    // No plan at all: an allowlisted entity Boris cannot publish is a failure,
    // never a quietly shorter article list.
    try testing.expect(result.plan == null);
    try testing.expect(!result.compile.ok);

    var eligibility: usize = 0;
    var markdown: usize = 0;
    for (result.compile.diagnostics.items) |d| {
        switch (d.code) {
            .ENOSTRELIGIBILITY => eligibility += 1,
            .ENOSTRMARKDOWN => markdown += 1,
            else => {},
        }
        try testing.expectEqual(diag.Severity.error_, d.severity);
        try testing.expect(d.remediation.len > 0);
    }
    // draft, path-derived id, and a selection absent from the corpus.
    try testing.expectEqual(@as(usize, 3), eligibility);
    // raw HTML and hard-wrapped prose.
    try testing.expectEqual(@as(usize, 2), markdown);

    try expectRejection(result, "articles/draft", "draft-status");
    try expectRejection(result, "articles/derived", "derived-entity-id");
    try expectRejection(result, "articles/missing", "does not exist in the validated corpus");
    try expectRejection(result, "articles/raw", "raw-html");
    try expectRejection(result, "articles/wrapped", "hard-wrapped-paragraph");
}

/// Asserts one rejection exists for `entity_id` naming `needle`.
///
/// Deliberately silent on failure: this module is an enforced emitter, and the
/// discipline guard reads the whole file, so a formatting call here — even in a
/// test — would be indistinguishable from an emitter bypassing the encoder.
fn expectRejection(result: Result, entity_id: []const u8, needle: []const u8) !void {
    for (result.compile.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, entity_id) != null and
            std.mem.indexOf(u8, d.message, needle) != null) return;
    }
    return error.TestUnexpectedResult;
}

test "plan: a defect position is reported in the publication-safe view, not as a source line" {
    var result = try runFixture(fixture_root ++ "/profile-rejects.json");
    defer result.deinit();
    for (result.compile.diagnostics.items) |d| {
        if (d.code != .ENOSTRMARKDOWN) continue;
        // Claiming a source line would point at the wrong byte once an include
        // has contributed content, so no position is attached to the record.
        try testing.expectEqual(@as(?u32, null), d.line);
        try testing.expect(std.mem.indexOf(u8, d.message, "publication-safe Markdown line ") != null);
    }
}

test "plan: a bad pubkey or an empty selection is refused before any compile" {
    // Built through the real parser rather than a struct literal: `Location`
    // owns its strings, and the invariant it enforces is part of the fixture.
    var location = try github_pages.parse(
        testing.allocator,
        "https://example.github.io/docs",
        "https://example.github.io",
        "/docs",
    );
    defer location.deinit(testing.allocator);
    const articles = [_][]const u8{"articles/first"};
    const relays = [_][]const u8{"wss://relay.example.com"};
    try testing.expectError(error.InvalidPubkey, run(testing.io, testing.allocator, .{
        .content_root = fixture_root ++ "/content",
        .location = &location,
        .pubkey = "NOTHEX",
        .articles = &articles,
        .relays = &relays,
    }));
    try testing.expectError(error.InvalidNostrConfig, run(testing.io, testing.allocator, .{
        .content_root = fixture_root ++ "/content",
        .location = &location,
        .pubkey = "a" ** 64,
        .articles = &.{},
        .relays = &relays,
    }));
    try testing.expectError(error.AbsolutePath, run(testing.io, testing.allocator, .{
        .content_root = "/etc",
        .location = &location,
        .pubkey = "a" ** 64,
        .articles = &articles,
        .relays = &relays,
    }));
}
