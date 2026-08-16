//! Deterministic, credential-free Standard.site offline record projection.
//!
//! This module turns a configured Boris corpus into exactly one
//! `site.standard.publication` record plus the eligible
//! `site.standard.document` records, with deterministic rkeys, canonical
//! fixed-key-order payloads, per-record payload digests, eligibility
//! decisions, and verification surfaces. It performs no DNS, HTTP, clock,
//! randomness, credential, or filesystem-cache work beyond the declared
//! inputs; the static website stays canonical and the records are a
//! machine-readable projection of it.
//!
//! This is the remaining implementation slice of
//! https://github.com/drawmeanelephant/boris/issues/473 and builds on the
//! merged ATProto identity and OAuth foundations (#458, #467, #472).

const std = @import("std");
const identity = @import("atproto_identity.zig");
const json_out = @import("json_out.zig");
const site_url = @import("site_url.zig");

pub const target_name = "standard-site";
pub const publication_collection = "site.standard.publication";
pub const document_collection = "site.standard.document";
pub const default_publication_rkey = "self";

pub const max_rkey_bytes = 512;
pub const max_did_bytes = 2048;
pub const max_name_bytes = 5000;
pub const max_description_bytes = 30000;
pub const max_tag_bytes = 1280;
pub const max_text_content_bytes = 256 * 1024;
pub const max_pages = 4096;

/// Project-relative web-facing path of the Standard.site publication discovery
/// file. Fixed (never configurable) so indexers and the ownership cleanup can
/// rely on it.
pub const well_known_path = ".well-known/site.standard.publication";

pub const Error = std.mem.Allocator.Error || error{
    NoSpaceLeft,
    InvalidBasePath,
    InvalidDid,
    InvalidDescription,
    InvalidLocation,
    InvalidName,
    InvalidOutputPath,
    InvalidPage,
    InvalidPublishedAt,
    InvalidTag,
    InvalidTitle,
    RkeyCollision,
    RecordTooLarge,
    TooManyPages,
};

/// Normalized public location for a Standard.site publication. `base_url`
/// must equal `origin + base_path`; this is the same location invariant the
/// GitHub Pages target enforces, without any platform-specific site-kind
/// classification (a base-path deployment is legal but limits verification,
/// see the plan's `verification` section).
pub const Location = struct {
    base_url: []u8,
    origin: []u8,
    base_path: []u8,

    pub fn deinit(self: *Location, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.origin);
        allocator.free(self.base_path);
        self.* = undefined;
    }
};

fn schemeEnd(url: []const u8) ?usize {
    if (std.mem.startsWith(u8, url, "https://")) return "https://".len;
    if (std.mem.startsWith(u8, url, "http://")) return "http://".len;
    return null;
}

fn originLength(url: []const u8) ?usize {
    const start = schemeEnd(url) orelse return null;
    return std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
}

/// Normalize and cross-check the three authoritative location values. This is
/// platform-neutral: unlike the GitHub Pages target it does not reject a
/// non-empty base path on a custom domain, because Standard.site base-path
/// deployments are legal (the verification plan then reports the domain-root
/// limitation honestly instead of guessing a URL).
pub fn parseLocation(
    allocator: std.mem.Allocator,
    raw_base_url: []const u8,
    raw_origin: []const u8,
    raw_base_path: []const u8,
) Error!Location {
    const base_url = site_url.normalized(allocator, raw_base_url) catch return error.InvalidLocation;
    errdefer allocator.free(base_url);
    const origin = site_url.normalized(allocator, raw_origin) catch return error.InvalidLocation;
    errdefer allocator.free(origin);
    const base_origin_len = originLength(base_url) orelse return error.InvalidLocation;
    if (originLength(origin) != origin.len) return error.InvalidLocation;
    if (!std.mem.eql(u8, base_url[0..base_origin_len], origin)) return error.InvalidLocation;

    const base_path = try normalizeBasePath(allocator, raw_base_path);
    errdefer allocator.free(base_path);
    const derived_path = base_url[base_origin_len..];
    if (!std.mem.eql(u8, derived_path, base_path)) return error.InvalidLocation;
    return .{ .base_url = base_url, .origin = origin, .base_path = base_path };
}

fn normalizeBasePath(allocator: std.mem.Allocator, raw: []const u8) Error![]u8 {
    if (raw.len == 0) return allocator.dupe(u8, "");
    if (raw.len > 2048 or raw[0] != '/') return error.InvalidBasePath;
    var end = raw.len;
    while (end > 1 and raw[end - 1] == '/') : (end -= 1) {}
    const candidate = raw[0..end];
    if (candidate.len == 1) return allocator.dupe(u8, "");
    if (std.mem.indexOf(u8, candidate, "//") != null or
        std.mem.indexOfScalar(u8, candidate, '\\') != null or
        std.mem.indexOfScalar(u8, candidate, '?') != null or
        std.mem.indexOfScalar(u8, candidate, '#') != null)
    {
        return error.InvalidBasePath;
    }
    var segments = std.mem.splitScalar(u8, candidate[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidBasePath;
        }
    }
    return allocator.dupe(u8, candidate);
}

/// Profile-owned Standard.site publication configuration. Strings are
/// allocator-owned copies of normalized profile values.
pub const TargetConfig = struct {
    location: Location,
    did: []u8,
    /// Authoritative account PDS origin (where `com.atproto.repo.*` writes
    /// land), bound at plan time so the reconciler can verify the authorized
    /// session before mutating anything.
    pds_origin: ?[]u8 = null,
    /// Publication name override; defaults to `site.title` at projection time.
    name: ?[]u8 = null,
    description: ?[]u8 = null,
    show_in_discover: bool = false,
    /// Entity-id include/exclude filters. An entry ending in `*` is a prefix
    /// glob on the entity id; any other entry is an exact id match.
    include: [][]const u8 = &.{},
    exclude: [][]const u8 = &.{},
    /// When true, the reconciler may delete remote records whose local page
    /// disappeared, but only under an explicit publish invocation.
    prune: bool = false,

    pub fn deinit(self: *TargetConfig, allocator: std.mem.Allocator) void {
        self.location.deinit(allocator);
        allocator.free(self.did);
        if (self.pds_origin) |v| allocator.free(v);
        if (self.name) |v| allocator.free(v);
        if (self.description) |v| allocator.free(v);
        for (self.include) |entry| allocator.free(entry);
        if (self.include.len > 0) allocator.free(self.include);
        for (self.exclude) |entry| allocator.free(entry);
        if (self.exclude.len > 0) allocator.free(self.exclude);
        self.* = undefined;
    }
};

/// True when `text` is a syntactically valid HTTPS origin with no path,
/// query, fragment, userinfo, or port that could drift the PDS write target.
pub fn validPdsOrigin(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "https://")) return false;
    const rest = text["https://".len..];
    if (rest.len == 0) return false;
    if (std.mem.indexOfAny(u8, rest, "/?#@") != null) return false;
    if (std.mem.indexOf(u8, rest, ":") != null) return false;
    for (rest) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

/// True when `text` is a syntactically valid ATProto DID (`did:plc` or
/// host-level `did:web`). The profile parser uses this to fail closed before
/// any plan depends on the identity; resolution happens only at publish time.
pub fn validDid(text: []const u8) bool {
    return blk: {
        _ = identity.Did.parse(text) catch break :blk false;
        break :blk true;
    };
}

pub const Status = enum { published, archived, draft, none };

/// Minimal, explicit per-page input for the projection. The compiler maps its
/// discovered pages onto this shape; the projection never re-parses markup.
pub const PageInput = struct {
    entity_id: []const u8,
    /// Compiler-owned HTML output path relative to the target root, e.g.
    /// `guides/intro.html`.
    output_path: []const u8,
    title: ?[]const u8 = null,
    status: Status = .none,
    /// Frontmatter `published_at` in `YYYY-MM-DDTHH:MM:SSZ` form, or null.
    published_at: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    /// Deterministic plain-text projection (Oliver); null for metadata-only.
    text_content: ?[]const u8 = null,
};

pub const ExclusionReason = enum { draft, missing_date, filtered, unsupported };

pub const Exclusion = struct {
    entity_id: []u8,
    reason: ExclusionReason,
    detail: []u8,
};

pub const PlannedPublication = struct {
    rkey: []u8,
    at_uri: []u8,
    url: []u8,
    name: []u8,
    description: ?[]u8,
    show_in_discover: bool,
    payload: []u8,
    payload_sha256: [64]u8,
};

pub const DocumentIntent = enum { create };

pub const PlannedDocument = struct {
    entity_id: []u8,
    eligibility: Status,
    rkey: []u8,
    at_uri: []u8,
    path: []u8,
    title: []u8,
    published_at: []u8,
    description: ?[]u8,
    tags: [][]const u8,
    /// Owned plain-text projection; null for metadata-only documents.
    text_content: ?[]const u8,
    text_content_sha256: ?[64]u8,
    payload: []u8,
    payload_sha256: [64]u8,
    intent: DocumentIntent = .create,
};

pub const Projection = struct {
    publication: PlannedPublication,
    documents: []PlannedDocument,
    exclusions: []Exclusion,

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        deinitPlannedPublication(&self.publication, allocator);
        for (self.documents) |*document| deinitPlannedDocument(document, allocator);
        if (self.documents.len > 0) allocator.free(self.documents);
        for (self.exclusions) |*exclusion| {
            allocator.free(exclusion.entity_id);
            allocator.free(exclusion.detail);
        }
        if (self.exclusions.len > 0) allocator.free(self.exclusions);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// rkey derivation (the settled injective scheme from #473)
// ---------------------------------------------------------------------------

/// Derive a deterministic, injective AT Protocol record key from a
/// compiler-owned entity id:
///
/// - preserve ASCII letters, digits, `-`, and `.`;
/// - map `/` to `:`;
/// - encode every other byte as `~XX` with uppercase hexadecimal (`~` itself
///   becomes `~7E`, so reversible output can never contain `~~`);
/// - when the reversible form exceeds the rkey byte limit, use `~~` plus the
///   lowercase hex SHA-256 of the entity id.
///
/// Reversible and digest forms can never collide with each other because
/// `~~` cannot appear in reversible output. The caller still runs a
/// collection-wide collision check and fails closed on any duplicate.
pub fn entityRkey(gpa: std.mem.Allocator, entity_id: []const u8) Error![]u8 {
    if (entity_id.len == 0) return error.InvalidPage;
    var reversible: std.ArrayList(u8) = .empty;
    errdefer reversible.deinit(gpa);
    const hex = "0123456789ABCDEF";
    for (entity_id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.') {
            try reversible.append(gpa, byte);
        } else if (byte == '/') {
            try reversible.append(gpa, ':');
        } else {
            try reversible.appendSlice(gpa, &.{ '~', hex[byte >> 4], hex[byte & 15] });
        }
    }
    if (reversible.items.len > max_rkey_bytes or reversible.items.len == 0) {
        reversible.deinit(gpa);
        reversible = .empty;
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entity_id, &digest, .{});
        const prefix = "~~";
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, prefix);
        for (digest) |byte| try out.appendSlice(gpa, &.{ hexLower(byte >> 4), hexLower(byte & 15) });
        return out.toOwnedSlice(gpa);
    }
    if (std.mem.eql(u8, reversible.items, ".") or std.mem.eql(u8, reversible.items, "..")) {
        return error.InvalidPage;
    }
    return reversible.toOwnedSlice(gpa);
}

fn parseDigits(text: []const u8) !u16 {
    if (text.len != 2) return error.InvalidPublishedAt;
    var value: u16 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidPublishedAt;
        value = value * 10 + (byte - '0');
    }
    return value;
}

fn hexLower(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + (nibble - 10);
}

// ---------------------------------------------------------------------------
// publishedAt normalization
// ---------------------------------------------------------------------------

/// Normalize a frontmatter `published_at` value into the atproto datetime
/// form `YYYY-MM-DDTHH:MM:SS.000Z`. Accepts `YYYY-MM-DDTHH:MM:SSZ` and the
/// already-normalized `.000Z` form; anything else fails closed.
pub fn normalizePublishedAt(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    const plain_len = 20; // YYYY-MM-DDTHH:MM:SSZ
    if (raw.len != plain_len and raw.len != plain_len + 4) return error.InvalidPublishedAt;
    if (raw.len == plain_len + 4) {
        if (!std.mem.endsWith(u8, raw, "Z") or !std.mem.eql(u8, raw[plain_len - 1 ..][0..4], ".000")) {
            return error.InvalidPublishedAt;
        }
    } else if (!std.mem.endsWith(u8, raw, "Z")) {
        return error.InvalidPublishedAt;
    }
    if (raw[4] != '-' or raw[7] != '-' or raw[10] != 'T' or raw[13] != ':' or raw[16] != ':') {
        return error.InvalidPublishedAt;
    }
    for (raw[0 .. raw.len - 1]) |byte| {
        if (!std.ascii.isDigit(byte) and byte != '-' and byte != 'T' and byte != ':' and byte != '.') {
            return error.InvalidPublishedAt;
        }
    }
    const month = parseDigits(raw[5..7]) catch return error.InvalidPublishedAt;
    const day = parseDigits(raw[8..10]) catch return error.InvalidPublishedAt;
    const hour = parseDigits(raw[11..13]) catch return error.InvalidPublishedAt;
    const minute = parseDigits(raw[14..16]) catch return error.InvalidPublishedAt;
    const second = parseDigits(raw[17..19]) catch return error.InvalidPublishedAt;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) {
        return error.InvalidPublishedAt;
    }
    if (raw.len == plain_len) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, raw[0 .. raw.len - 1]);
        try out.appendSlice(gpa, ".000Z");
        return out.toOwnedSlice(gpa);
    }
    return gpa.dupe(u8, raw);
}

// ---------------------------------------------------------------------------
// eligibility
// ---------------------------------------------------------------------------

/// Mirrors the RSS eligibility rule: a document is eligible when it has a
/// `published_at` and its status is omitted / published / archived. Drafts
/// and missing dates are excluded; profile filters are applied separately.
fn isEligibleStatus(status: Status) bool {
    return switch (status) {
        .published, .archived, .none => true,
        .draft => false,
    };
}

fn filterAllows(config: *const TargetConfig, entity_id: []const u8) bool {
    var included = config.include.len == 0;
    for (config.include) |entry| {
        if (filterMatches(entry, entity_id)) {
            included = true;
            break;
        }
    }
    if (!included) return false;
    for (config.exclude) |entry| {
        if (filterMatches(entry, entity_id)) return false;
    }
    return true;
}

fn filterMatches(entry: []const u8, entity_id: []const u8) bool {
    if (entry.len == 0) return false;
    if (entry[entry.len - 1] == '*') {
        const prefix = entry[0 .. entry.len - 1];
        return std.mem.startsWith(u8, entity_id, prefix);
    }
    return std.mem.eql(u8, entry, entity_id);
}

// ---------------------------------------------------------------------------
// payload digest
// ---------------------------------------------------------------------------

fn sha256HexLower(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = hexLower(byte >> 4);
        out[i * 2 + 1] = hexLower(byte & 15);
    }
    return out;
}

// ---------------------------------------------------------------------------
// canonical record payloads
// ---------------------------------------------------------------------------

/// Canonical `site.standard.publication` payload. Unsupported optional
/// lexicon fields are absent, never empty placeholders. Fixed key order:
/// url, name, description, preferences.
pub fn publicationPayload(gpa: std.mem.Allocator, config: *const TargetConfig, name: []const u8) Error![]u8 {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidName;
    const description = config.description;
    if (description) |value| if (value.len > max_description_bytes) return error.InvalidDescription;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"url\":");
    try json_out.writeString(&out, gpa, config.location.base_url);
    try out.appendSlice(gpa, ",\"name\":");
    try json_out.writeString(&out, gpa, name);
    if (description) |value| {
        try out.appendSlice(gpa, ",\"description\":");
        try json_out.writeString(&out, gpa, value);
    }
    if (config.show_in_discover) {
        try out.appendSlice(gpa, ",\"preferences\":{\"showInDiscover\":true}");
    }
    try out.appendSlice(gpa, "}");
    if (out.items.len > 64 * 1024) return error.RecordTooLarge;
    return out.toOwnedSlice(gpa);
}

/// Canonical `site.standard.document` payload. Fixed key order: site, title,
/// publishedAt, path, description, tags, textContent.
pub fn documentPayload(
    gpa: std.mem.Allocator,
    publication_at_uri: []const u8,
    title: []const u8,
    published_at: []const u8,
    path: []const u8,
    description: ?[]const u8,
    tags: []const []const u8,
    text_content: ?[]const u8,
) Error![]u8 {
    if (title.len == 0 or title.len > max_name_bytes) return error.InvalidTitle;
    if (description) |value| if (value.len > max_description_bytes) return error.InvalidDescription;
    if (text_content) |value| if (value.len == 0 or value.len > max_text_content_bytes) return error.InvalidTitle;
    for (tags) |tag| {
        if (tag.len == 0 or tag.len > max_tag_bytes) return error.InvalidTag;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"site\":");
    try json_out.writeString(&out, gpa, publication_at_uri);
    try out.appendSlice(gpa, ",\"title\":");
    try json_out.writeString(&out, gpa, title);
    try out.appendSlice(gpa, ",\"publishedAt\":");
    try json_out.writeString(&out, gpa, published_at);
    try out.appendSlice(gpa, ",\"path\":");
    try json_out.writeString(&out, gpa, path);
    if (description) |value| {
        try out.appendSlice(gpa, ",\"description\":");
        try json_out.writeString(&out, gpa, value);
    }
    if (tags.len > 0) {
        try out.appendSlice(gpa, ",\"tags\":[");
        for (tags, 0..) |tag, index| {
            if (index > 0) try out.append(gpa, ',');
            try json_out.writeString(&out, gpa, tag);
        }
        try out.appendSlice(gpa, "]");
    }
    if (text_content) |value| {
        try out.appendSlice(gpa, ",\"textContent\":");
        try json_out.writeString(&out, gpa, value);
    }
    try out.appendSlice(gpa, "}");
    if (out.items.len > max_record_bytes) return error.RecordTooLarge;
    return out.toOwnedSlice(gpa);
}

const max_record_bytes = 256 * 1024;

// ---------------------------------------------------------------------------
// projection
// ---------------------------------------------------------------------------

pub const ProjectInput = struct {
    config: *const TargetConfig,
    /// Default publication name; `config.name` overrides it.
    site_title: ?[]const u8,
    /// `site.url` from the profile, when present; the location invariant is
    /// already enforced by the profile parser.
    pages: []const PageInput,
};

fn validateOutputPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 1024) return false;
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOf(u8, path, "..") != null) return false;
    if (!std.mem.endsWith(u8, path, ".html")) return false;
    return true;
}

/// Compute the deterministic projection. Eligibility decisions are recorded
/// with reasons; rkey collisions fail closed across the planned collection.
pub fn project(gpa: std.mem.Allocator, input: ProjectInput) Error!Projection {
    const config = input.config;
    const name = config.name orelse input.site_title orelse return error.InvalidName;
    if (config.did.len == 0 or config.did.len > max_did_bytes) return error.InvalidDid;

    const publication_at_uri = try buildAtUri(gpa, config.did, publication_collection, default_publication_rkey);
    defer gpa.free(publication_at_uri);
    const publication_payload = try publicationPayload(gpa, config, name);
    defer gpa.free(publication_payload);
    var publication: PlannedPublication = .{
        .rkey = try gpa.dupe(u8, default_publication_rkey),
        .at_uri = try gpa.dupe(u8, publication_at_uri),
        .url = try gpa.dupe(u8, config.location.base_url),
        .name = try gpa.dupe(u8, name),
        .description = if (config.description) |value| try gpa.dupe(u8, value) else null,
        .show_in_discover = config.show_in_discover,
        .payload = try gpa.dupe(u8, publication_payload),
        .payload_sha256 = sha256HexLower(publication_payload),
    };
    errdefer deinitPlannedPublication(&publication, gpa);

    var documents: std.ArrayList(PlannedDocument) = .empty;
    errdefer {
        for (documents.items) |*document| deinitPlannedDocument(document, gpa);
        documents.deinit(gpa);
    }
    var exclusions: std.ArrayList(Exclusion) = .empty;
    errdefer {
        for (exclusions.items) |*exclusion| {
            gpa.free(exclusion.entity_id);
            gpa.free(exclusion.detail);
        }
        exclusions.deinit(gpa);
    }
    var seen_rkeys: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_rkeys.deinit(gpa);

    if (input.pages.len > max_pages) return error.TooManyPages;
    for (input.pages) |page| {
        if (page.entity_id.len == 0) return error.InvalidPage;
        if (!validateOutputPath(page.output_path)) return error.InvalidPage;
        if (page.status == .draft) {
            try exclusions.append(gpa, .{
                .entity_id = try gpa.dupe(u8, page.entity_id),
                .reason = .draft,
                .detail = try gpa.dupe(u8, "status is draft; drafts are excluded"),
            });
            continue;
        }
        if (page.published_at == null) {
            try exclusions.append(gpa, .{
                .entity_id = try gpa.dupe(u8, page.entity_id),
                .reason = .missing_date,
                .detail = try gpa.dupe(u8, "no published_at; documents require a publish date"),
            });
            continue;
        }
        if (!filterAllows(config, page.entity_id)) {
            try exclusions.append(gpa, .{
                .entity_id = try gpa.dupe(u8, page.entity_id),
                .reason = .filtered,
                .detail = try gpa.dupe(u8, "excluded by the configured include/exclude filters"),
            });
            continue;
        }
        if (!isEligibleStatus(page.status)) {
            try exclusions.append(gpa, .{
                .entity_id = try gpa.dupe(u8, page.entity_id),
                .reason = .unsupported,
                .detail = try gpa.dupe(u8, "status is not publishable"),
            });
            continue;
        }

        var document = try projectDocument(
            gpa,
            config,
            publication_at_uri,
            &seen_rkeys,
            page,
        );
        errdefer deinitPlannedDocument(&document, gpa);
        try documents.append(gpa, document);
    }

    return .{
        .publication = publication,
        .documents = try documents.toOwnedSlice(gpa),
        .exclusions = try exclusions.toOwnedSlice(gpa),
    };
}

/// Build one owned planned document. All errdefers are scoped to this helper,
/// so appended documents can never be double-freed by an outer error path.
fn projectDocument(
    gpa: std.mem.Allocator,
    config: *const TargetConfig,
    publication_at_uri: []const u8,
    seen_rkeys: *std.StringHashMapUnmanaged(void),
    page: PageInput,
) Error!PlannedDocument {
    const rkey = try entityRkey(gpa, page.entity_id);
    errdefer gpa.free(rkey);
    if (seen_rkeys.contains(rkey)) return error.RkeyCollision;
    try seen_rkeys.put(gpa, rkey, {});
    const at_uri = try buildAtUri(gpa, config.did, document_collection, rkey);
    errdefer gpa.free(at_uri);
    const published_at = try normalizePublishedAt(gpa, page.published_at.?);
    errdefer gpa.free(published_at);
    const path = try joinWithSlash(gpa, page.output_path);
    errdefer gpa.free(path);
    const title = page.title orelse page.entity_id;
    const payload = try documentPayload(
        gpa,
        publication_at_uri,
        title,
        published_at,
        path,
        page.summary,
        page.tags,
        page.text_content,
    );
    errdefer gpa.free(payload);
    const description = if (page.summary) |summary| try gpa.dupe(u8, summary) else null;
    errdefer if (description) |value| gpa.free(value);
    const text_content = if (page.text_content) |text| try gpa.dupe(u8, text) else null;
    errdefer if (text_content) |value| gpa.free(value);
    const entity_id = try gpa.dupe(u8, page.entity_id);
    errdefer gpa.free(entity_id);
    const title_owned = try gpa.dupe(u8, title);
    errdefer gpa.free(title_owned);
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer tags.deinit(gpa);
    for (page.tags) |tag| try tags.append(gpa, tag);
    const tags_owned = try tags.toOwnedSlice(gpa);
    errdefer gpa.free(tags_owned);

    return .{
        .entity_id = entity_id,
        .eligibility = page.status,
        .rkey = rkey,
        .at_uri = at_uri,
        .path = path,
        .title = title_owned,
        .published_at = published_at,
        .description = description,
        .tags = tags_owned,
        .text_content = text_content,
        .text_content_sha256 = if (page.text_content) |text| sha256HexLower(text) else null,
        .payload = payload,
        .payload_sha256 = sha256HexLower(payload),
    };
}

fn buildAtUri(gpa: std.mem.Allocator, did: []const u8, collection: []const u8, rkey: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "at://");
    try out.appendSlice(gpa, did);
    try out.append(gpa, '/');
    try out.appendSlice(gpa, collection);
    try out.append(gpa, '/');
    try out.appendSlice(gpa, rkey);
    return out.toOwnedSlice(gpa);
}

/// `/{s}` join for a relative path; avoids `allocPrint` in an emitter module.
fn joinWithSlash(gpa: std.mem.Allocator, rest: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '/');
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

/// `{origin}/{path}` join; avoids `allocPrint` in an emitter module.
fn joinOriginPath(gpa: std.mem.Allocator, origin: []const u8, path: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, origin);
    try out.append(gpa, '/');
    try out.appendSlice(gpa, path);
    return out.toOwnedSlice(gpa);
}

fn deinitPlannedPublication(publication: *PlannedPublication, allocator: std.mem.Allocator) void {
    allocator.free(publication.rkey);
    allocator.free(publication.at_uri);
    allocator.free(publication.url);
    allocator.free(publication.name);
    if (publication.description) |value| allocator.free(value);
    allocator.free(publication.payload);
    publication.* = undefined;
}

fn deinitPlannedDocument(document: *PlannedDocument, allocator: std.mem.Allocator) void {
    allocator.free(document.entity_id);
    allocator.free(document.rkey);
    allocator.free(document.at_uri);
    allocator.free(document.path);
    allocator.free(document.title);
    allocator.free(document.published_at);
    if (document.description) |value| allocator.free(value);
    if (document.tags.len > 0) allocator.free(document.tags);
    if (document.text_content) |value| allocator.free(value);
    allocator.free(document.payload);
    document.* = undefined;
}

// ---------------------------------------------------------------------------
// verification surfaces
// ---------------------------------------------------------------------------

pub const WellKnownPlan = struct {
    /// Plain-text content of the well-known file: the publication AT-URI.
    content: []u8,
    /// True when the project tree can serve the required domain-root path
    /// itself (root/custom-domain site, `base_path == ""`).
    emittable: bool,
    /// Project-relative emission path when emittable (`.well-known/...`).
    project_path: ?[]u8,
    /// The exact public URL an indexer will probe.
    required_public_url: []u8,
};

pub const DocumentLink = struct {
    page: []u8,
    href: []u8,
};

pub const VerificationSurfaces = struct {
    well_known: WellKnownPlan,
    document_links: []DocumentLink,
};

/// Compute the web-facing verification surfaces from a committed projection.
pub fn verificationSurfaces(gpa: std.mem.Allocator, config: *const TargetConfig, projection: *const Projection) Error!VerificationSurfaces {
    var document_links: std.ArrayList(DocumentLink) = .empty;
    errdefer {
        for (document_links.items) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        document_links.deinit(gpa);
    }
    for (projection.documents) |document| {
        try document_links.append(gpa, .{
            .page = try joinWithSlash(gpa, document.entity_id),
            .href = try gpa.dupe(u8, document.at_uri),
        });
    }

    const emittable = config.location.base_path.len == 0;
    const well_known: WellKnownPlan = .{
        .content = try gpa.dupe(u8, projection.publication.at_uri),
        .emittable = emittable,
        .project_path = if (emittable) try gpa.dupe(u8, well_known_path) else null,
        // The URL an indexer probes is always the domain-root well-known path;
        // a base-path site cannot serve it, which is precisely why the build
        // records `limited` instead of emitting a decoy.
        .required_public_url = try joinOriginPath(gpa, config.location.origin, well_known_path),
    };
    return .{ .well_known = well_known, .document_links = try document_links.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// plan artifact
// ---------------------------------------------------------------------------

pub const plan_format = "boris-standard-site-plan";
pub const plan_schema_version: u32 = 1;

/// Render the deterministic, machine-readable Standard.site projection plan.
/// Fixed JSON key order, LF endings, no timestamps or host data. The returned
/// bytes are allocator-owned and always end in one LF.
pub fn renderPlan(
    gpa: std.mem.Allocator,
    config: *const TargetConfig,
    projection: *const Projection,
    surfaces: *const VerificationSurfaces,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, plan_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, plan_schema_version);
    try out.appendSlice(gpa, ",\n  \"inputs\": {\n    \"did\": ");
    try json_out.writeString(&out, gpa, config.did);
    try out.appendSlice(gpa, ",\n    \"pds_origin\": ");
    if (config.pds_origin) |pds| {
        try json_out.writeString(&out, gpa, pds);
    } else {
        try json_out.writeNull(&out, gpa);
    }
    try out.appendSlice(gpa, ",\n    \"base_url\": ");
    try json_out.writeString(&out, gpa, config.location.base_url);
    try out.appendSlice(gpa, ",\n    \"origin\": ");
    try json_out.writeString(&out, gpa, config.location.origin);
    try out.appendSlice(gpa, ",\n    \"base_path\": ");
    try json_out.writeString(&out, gpa, config.location.base_path);
    try out.appendSlice(gpa, ",\n    \"publication_rkey\": ");
    try json_out.writeString(&out, gpa, default_publication_rkey);
    try out.appendSlice(gpa, ",\n    \"prune\": ");
    try json_out.writeBool(&out, gpa, config.prune);
    try out.appendSlice(gpa, "\n  },\n  \"publication\": {\n    \"type\": ");
    try json_out.writeString(&out, gpa, publication_collection);
    try out.appendSlice(gpa, ",\n    \"rkey\": ");
    try json_out.writeString(&out, gpa, projection.publication.rkey);
    try out.appendSlice(gpa, ",\n    \"at_uri\": ");
    try json_out.writeString(&out, gpa, projection.publication.at_uri);
    try out.appendSlice(gpa, ",\n    \"url\": ");
    try json_out.writeString(&out, gpa, projection.publication.url);
    try out.appendSlice(gpa, ",\n    \"name\": ");
    try json_out.writeString(&out, gpa, projection.publication.name);
    try out.appendSlice(gpa, ",\n    \"description\": ");
    if (projection.publication.description) |description| {
        try json_out.writeString(&out, gpa, description);
    } else {
        try json_out.writeNull(&out, gpa);
    }
    try out.appendSlice(gpa, ",\n    \"show_in_discover\": ");
    try json_out.writeBool(&out, gpa, projection.publication.show_in_discover);
    try out.appendSlice(gpa, ",\n    \"payload_sha256\": ");
    try writeHex(&out, gpa, &projection.publication.payload_sha256);
    try out.appendSlice(gpa, ",\n    \"intent\": \"create\"\n  },\n  \"documents\": [");
    for (projection.documents, 0..) |document, index| {
        if (index > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n    {\n      \"entity_id\": ");
        try json_out.writeString(&out, gpa, document.entity_id);
        try out.appendSlice(gpa, ",\n      \"type\": ");
        try json_out.writeString(&out, gpa, document_collection);
        try out.appendSlice(gpa, ",\n      \"rkey\": ");
        try json_out.writeString(&out, gpa, document.rkey);
        try out.appendSlice(gpa, ",\n      \"at_uri\": ");
        try json_out.writeString(&out, gpa, document.at_uri);
        try out.appendSlice(gpa, ",\n      \"path\": ");
        try json_out.writeString(&out, gpa, document.path);
        try out.appendSlice(gpa, ",\n      \"eligibility\": ");
        try json_out.writeString(&out, gpa, statusName(document.eligibility));
        try out.appendSlice(gpa, ",\n      \"title\": ");
        try json_out.writeString(&out, gpa, document.title);
        try out.appendSlice(gpa, ",\n      \"published_at\": ");
        try json_out.writeString(&out, gpa, document.published_at);
        try out.appendSlice(gpa, ",\n      \"description\": ");
        if (document.description) |description| {
            try json_out.writeString(&out, gpa, description);
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, ",\n      \"tags\": ");
        if (document.tags.len > 0) {
            try out.appendSlice(gpa, "[");
            for (document.tags, 0..) |tag, tag_index| {
                if (tag_index > 0) try out.append(gpa, ',');
                try json_out.writeString(&out, gpa, tag);
            }
            try out.appendSlice(gpa, "]");
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, ",\n      \"text_content\": ");
        if (document.text_content) |text| {
            try json_out.writeString(&out, gpa, text);
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, ",\n      \"text_content_sha256\": ");
        if (document.text_content_sha256) |digest| {
            try writeHex(&out, gpa, &digest);
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, ",\n      \"payload_sha256\": ");
        try writeHex(&out, gpa, &document.payload_sha256);
        try out.appendSlice(gpa, ",\n      \"intent\": \"create\"\n    }");
    }
    if (projection.documents.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "],\n  \"exclusions\": [");
    for (projection.exclusions, 0..) |exclusion, index| {
        if (index > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n    {\n      \"entity_id\": ");
        try json_out.writeString(&out, gpa, exclusion.entity_id);
        try out.appendSlice(gpa, ",\n      \"reason\": ");
        try json_out.writeString(&out, gpa, exclusionReasonName(exclusion.reason));
        try out.appendSlice(gpa, ",\n      \"detail\": ");
        try json_out.writeString(&out, gpa, exclusion.detail);
        try out.appendSlice(gpa, "\n    }");
    }
    if (projection.exclusions.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "],\n  \"verification\": {\n    \"publication_well_known\": {\n      \"content_at_uri\": ");
    try json_out.writeString(&out, gpa, surfaces.well_known.content);
    try out.appendSlice(gpa, ",\n      \"emittable\": ");
    try json_out.writeBool(&out, gpa, surfaces.well_known.emittable);
    try out.appendSlice(gpa, ",\n      \"project_path\": ");
    if (surfaces.well_known.project_path) |path| {
        try json_out.writeString(&out, gpa, path);
    } else {
        try json_out.writeNull(&out, gpa);
    }
    try out.appendSlice(gpa, ",\n      \"required_public_url\": ");
    try json_out.writeString(&out, gpa, surfaces.well_known.required_public_url);
    try out.appendSlice(gpa, "\n    },\n    \"document_links\": [");
    for (surfaces.document_links, 0..) |link, index| {
        if (index > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n      {\"page\": ");
        try json_out.writeString(&out, gpa, link.page);
        try out.appendSlice(gpa, ", \"href\": ");
        try json_out.writeString(&out, gpa, link.href);
        try out.appendSlice(gpa, "}");
    }
    if (surfaces.document_links.len > 0) try out.appendSlice(gpa, "\n    ");
    try out.appendSlice(gpa, "]\n  }\n}\n");
    return out.toOwnedSlice(gpa);
}

pub const records_format = "boris-standard-site-records";
pub const records_schema_version: u32 = 1;

/// Render the full, canonical record payloads — the exact JSON bodies `publish`
/// would PUT — for byte-level offline review. Unlike the plan (which carries
/// only per-record digests), this embeds each record's complete payload,
/// including the document `textContent`. Fixed key order, LF endings, no
/// timestamps or host data. The returned bytes are allocator-owned and always
/// end in one LF.
pub fn renderRecords(gpa: std.mem.Allocator, projection: *const Projection) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, records_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, records_schema_version);
    try out.appendSlice(gpa, ",\n  \"records\": [\n    {\n      \"collection\": ");
    try json_out.writeString(&out, gpa, publication_collection);
    try out.appendSlice(gpa, ",\n      \"rkey\": ");
    try json_out.writeString(&out, gpa, projection.publication.rkey);
    try out.appendSlice(gpa, ",\n      \"at_uri\": ");
    try json_out.writeString(&out, gpa, projection.publication.at_uri);
    try out.appendSlice(gpa, ",\n      \"payload\": ");
    try out.appendSlice(gpa, projection.publication.payload);
    try out.appendSlice(gpa, "\n    }");

    for (projection.documents) |document| {
        try out.appendSlice(gpa, ",\n    {\n      \"collection\": ");
        try json_out.writeString(&out, gpa, document_collection);
        try out.appendSlice(gpa, ",\n      \"rkey\": ");
        try json_out.writeString(&out, gpa, document.rkey);
        try out.appendSlice(gpa, ",\n      \"at_uri\": ");
        try json_out.writeString(&out, gpa, document.at_uri);
        try out.appendSlice(gpa, ",\n      \"entity_id\": ");
        try json_out.writeString(&out, gpa, document.entity_id);
        try out.appendSlice(gpa, ",\n      \"payload\": ");
        try out.appendSlice(gpa, document.payload);
        try out.appendSlice(gpa, "\n    }");
    }

    try out.appendSlice(gpa, "\n  ]\n}\n");
    return out.toOwnedSlice(gpa);
}

fn writeHex(out: *std.ArrayList(u8), gpa: std.mem.Allocator, digest: *const [64]u8) !void {
    try out.append(gpa, '"');
    try out.appendSlice(gpa, digest);
    try out.append(gpa, '"');
}

fn statusName(status: Status) []const u8 {
    return switch (status) {
        .published => "published",
        .archived => "archived",
        .draft => "draft",
        .none => "none",
    };
}

fn exclusionReasonName(reason: ExclusionReason) []const u8 {
    return switch (reason) {
        .draft => "draft",
        .missing_date => "missing-date",
        .filtered => "filtered",
        .unsupported => "unsupported",
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn testConfig(gpa: std.mem.Allocator) !TargetConfig {
    return .{
        .location = try parseLocation(gpa, "https://example.com", "https://example.com", ""),
        .did = try gpa.dupe(u8, "did:plc:ewvi7nxzyoun6zhxrhs64oiz"),
    };
}

test "rkey derivation is injective and rkey-safe" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { id: []const u8, expected: []const u8 }{
        .{ .id = "guides/intro", .expected = "guides:intro" },
        .{ .id = "a/b", .expected = "a:b" },
        .{ .id = "a:b", .expected = "a~3Ab" },
        .{ .id = "a~b", .expected = "a~7Eb" },
        .{ .id = "café", .expected = "caf~C3~A9" },
        .{ .id = "plain-title", .expected = "plain-title" },
        .{ .id = "index", .expected = "index" },
        .{ .id = "with space", .expected = "with~20space" },
    };
    for (cases) |case| {
        const rkey = try entityRkey(gpa, case.id);
        defer gpa.free(rkey);
        try std.testing.expectEqualStrings(case.expected, rkey);
    }
    // Reversible and digest forms never collide: `~~` cannot appear in
    // reversible output, and the digest form always starts with `~~`. A 200
    // repeated space encodes to 3 bytes each, so the reversible form exceeds
    // the rkey limit and the digest form is used.
    const long_id = " " ** 200;
    const long_rkey = try entityRkey(gpa, long_id);
    defer gpa.free(long_rkey);
    try std.testing.expect(std.mem.startsWith(u8, long_rkey, "~~"));
    try std.testing.expectEqual(@as(usize, 66), long_rkey.len);
    const short_rkey = try entityRkey(gpa, "index");
    defer gpa.free(short_rkey);
    try std.testing.expect(!std.mem.startsWith(u8, short_rkey, "~~"));
    try std.testing.expect(!std.mem.eql(u8, short_rkey, long_rkey));
}

test "rkey derivation handles unicode and percent-like ids without collisions" {
    const gpa = std.testing.allocator;
    const a = try entityRkey(gpa, "a/b");
    defer gpa.free(a);
    const b = try entityRkey(gpa, "a~2Fb");
    defer gpa.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    const c = try entityRkey(gpa, "a:b");
    defer gpa.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "publishedAt normalization produces the atproto datetime form" {
    const gpa = std.testing.allocator;
    const normalized = try normalizePublishedAt(gpa, "2024-01-20T14:30:00Z");
    defer gpa.free(normalized);
    try std.testing.expectEqualStrings("2024-01-20T14:30:00.000Z", normalized);
    const already = try normalizePublishedAt(gpa, "2024-01-20T14:30:00.000Z");
    defer gpa.free(already);
    try std.testing.expectEqualStrings("2024-01-20T14:30:00.000Z", already);
    try std.testing.expectError(error.InvalidPublishedAt, normalizePublishedAt(gpa, "2024-01-20T14:30:00"));
    try std.testing.expectError(error.InvalidPublishedAt, normalizePublishedAt(gpa, "2024-13-20T14:30:00Z"));
    try std.testing.expectError(error.InvalidPublishedAt, normalizePublishedAt(gpa, "not a date"));
    try std.testing.expectError(error.InvalidPublishedAt, normalizePublishedAt(gpa, "2024-01-20T14:30:00.00Z"));
}

test "publication and document payloads are canonical fixed-key-order JSON" {
    const gpa = std.testing.allocator;
    var config = try testConfig(gpa);
    defer config.deinit(gpa);
    const payload = try publicationPayload(gpa, &config, "Boris");
    defer gpa.free(payload);
    try std.testing.expectEqualStrings(
        "{\"url\":\"https://example.com\",\"name\":\"Boris\"}",
        payload,
    );
    config.description = try gpa.dupe(u8, "A deterministic compiler");
    config.show_in_discover = true;
    const payload_full = try publicationPayload(gpa, &config, "Boris");
    defer gpa.free(payload_full);
    try std.testing.expectEqualStrings(
        "{\"url\":\"https://example.com\",\"name\":\"Boris\",\"description\":\"A deterministic compiler\",\"preferences\":{\"showInDiscover\":true}}",
        payload_full,
    );
    const document = try documentPayload(
        gpa,
        "at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self",
        "Intro",
        "2024-01-20T14:30:00.000Z",
        "/guides/intro.html",
        "A guide",
        &.{ "guide", "zig" },
        null,
    );
    defer gpa.free(document);
    try std.testing.expectEqualStrings(
        "{\"site\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self\",\"title\":\"Intro\",\"publishedAt\":\"2024-01-20T14:30:00.000Z\",\"path\":\"/guides/intro.html\",\"description\":\"A guide\",\"tags\":[\"guide\",\"zig\"]}",
        document,
    );
}

test "projection maps an eligible corpus deterministically with reasons" {
    const gpa = std.testing.allocator;
    var config = try testConfig(gpa);
    defer config.deinit(gpa);
    const pages = [_]PageInput{
        .{ .entity_id = "index", .output_path = "index.html", .title = "Home", .status = .none },
        .{ .entity_id = "guides/intro", .output_path = "guides/intro.html", .title = "Intro", .status = .published, .published_at = "2024-01-20T14:30:00Z", .summary = "A guide", .tags = &.{ "guide", "zig" } },
        .{ .entity_id = "drafts/wip", .output_path = "drafts/wip.html", .title = "WIP", .status = .draft, .published_at = "2024-02-01T00:00:00Z" },
        .{ .entity_id = "notes/no-date", .output_path = "notes/no-date.html", .title = "No date", .status = .published },
        .{ .entity_id = "archive/old", .output_path = "archive/old.html", .title = "Old", .status = .archived, .published_at = "2020-01-01T00:00:00Z" },
    };
    var projection = try project(gpa, .{ .config = &config, .site_title = "Boris", .pages = &pages });
    defer projection.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), projection.documents.len);
    try std.testing.expectEqualStrings("guides:intro", projection.documents[0].rkey);
    try std.testing.expectEqualStrings("at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.document/guides:intro", projection.documents[0].at_uri);
    try std.testing.expectEqualStrings("/guides/intro.html", projection.documents[0].path);
    try std.testing.expectEqualStrings("2024-01-20T14:30:00.000Z", projection.documents[0].published_at);
    try std.testing.expectEqual(Status.archived, projection.documents[1].eligibility);

    // Exclusion order follows page input order: index (missing date), then
    // the draft, then the second missing date.
    try std.testing.expectEqual(@as(usize, 3), projection.exclusions.len);
    try std.testing.expectEqualStrings("index", projection.exclusions[0].entity_id);
    try std.testing.expectEqual(ExclusionReason.missing_date, projection.exclusions[0].reason);
    try std.testing.expectEqualStrings("drafts/wip", projection.exclusions[1].entity_id);
    try std.testing.expectEqual(ExclusionReason.draft, projection.exclusions[1].reason);
    try std.testing.expectEqualStrings("notes/no-date", projection.exclusions[2].entity_id);
    try std.testing.expectEqual(ExclusionReason.missing_date, projection.exclusions[2].reason);

    try std.testing.expectEqualStrings("https://example.com", projection.publication.url);
    try std.testing.expectEqualStrings("self", projection.publication.rkey);
    try std.testing.expectEqualStrings("at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self", projection.publication.at_uri);
}

test "filters and prune policy participate in the plan inputs" {
    const gpa = std.testing.allocator;
    var config = try testConfig(gpa);
    defer config.deinit(gpa);
    config.include = try gpa.dupe([]const u8, &.{try gpa.dupe(u8, "guides/*")});
    config.exclude = try gpa.dupe([]const u8, &.{try gpa.dupe(u8, "guides/secret*")});
    config.prune = true;
    const pages = [_]PageInput{
        .{ .entity_id = "guides/intro", .output_path = "guides/intro.html", .title = "Intro", .status = .published, .published_at = "2024-01-20T14:30:00Z" },
        .{ .entity_id = "guides/secret/x", .output_path = "guides/secret/x.html", .title = "Secret", .status = .published, .published_at = "2024-01-21T00:00:00Z" },
        .{ .entity_id = "outside", .output_path = "outside.html", .title = "Outside", .status = .published, .published_at = "2024-01-22T00:00:00Z" },
    };
    var projection = try project(gpa, .{ .config = &config, .site_title = "Boris", .pages = &pages });
    defer projection.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), projection.documents.len);
    try std.testing.expectEqualStrings("guides:intro", projection.documents[0].rkey);
    try std.testing.expectEqual(@as(usize, 2), projection.exclusions.len);
    try std.testing.expectEqual(ExclusionReason.filtered, projection.exclusions[0].reason);
    try std.testing.expectEqual(ExclusionReason.filtered, projection.exclusions[1].reason);
}

test "rkey collisions across the collection fail closed" {
    const gpa = std.testing.allocator;
    var config = try testConfig(gpa);
    defer config.deinit(gpa);
    // `a/b` and `a:b` map to different rkeys, but two ids that both derive to
    // the same rkey cannot exist because the encoding is injective. The
    // collision guard still fires when a caller supplies duplicate ids.
    const pages = [_]PageInput{
        .{ .entity_id = "same", .output_path = "same.html", .title = "A", .status = .published, .published_at = "2024-01-20T14:30:00Z" },
        .{ .entity_id = "same", .output_path = "same.html", .title = "B", .status = .published, .published_at = "2024-01-21T14:30:00Z" },
    };
    try std.testing.expectError(error.RkeyCollision, project(gpa, .{ .config = &config, .site_title = "Boris", .pages = &pages }));
}

test "plan rendering is byte-identical and carries digests and surfaces" {
    const gpa = std.testing.allocator;
    var config = try testConfig(gpa);
    defer config.deinit(gpa);
    const pages = [_]PageInput{
        .{ .entity_id = "guides/intro", .output_path = "guides/intro.html", .title = "Intro", .status = .published, .published_at = "2024-01-20T14:30:00Z", .summary = "A guide", .text_content = "Intro prose.\n" },
    };
    var projection = try project(gpa, .{ .config = &config, .site_title = "Boris", .pages = &pages });
    defer projection.deinit(gpa);
    const surfaces = try verificationSurfaces(gpa, &config, &projection);
    defer {
        gpa.free(surfaces.well_known.content);
        if (surfaces.well_known.project_path) |path| gpa.free(path);
        gpa.free(surfaces.well_known.required_public_url);
        for (surfaces.document_links) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        gpa.free(surfaces.document_links);
    }

    const first = try renderPlan(gpa, &config, &projection, &surfaces);
    defer gpa.free(first);
    const second = try renderPlan(gpa, &config, &projection, &surfaces);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"format\": \"boris-standard-site-plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"emittable\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"project_path\": \".well-known/site.standard.publication\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"text_content\": \"Intro prose.\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"text_content_sha256\": \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "jobs") == null);
}

test "records rendering embeds the full canonical payloads with textContent" {
    const gpa = std.testing.allocator;
    var config = try testConfig(gpa);
    defer config.deinit(gpa);
    const pages = [_]PageInput{
        .{ .entity_id = "guides/intro", .output_path = "guides/intro.html", .title = "Intro", .status = .published, .published_at = "2024-01-20T14:30:00Z", .summary = "A guide", .tags = &.{"guide"}, .text_content = "Intro prose.\n" },
    };
    var projection = try project(gpa, .{ .config = &config, .site_title = "Boris", .pages = &pages });
    defer projection.deinit(gpa);

    const first = try renderRecords(gpa, &projection);
    defer gpa.free(first);
    const second = try renderRecords(gpa, &projection);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"format\": \"boris-standard-site-records\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"collection\": \"site.standard.publication\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"payload\": {\"url\":\"https://example.com\",\"name\":\"Boris\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"collection\": \"site.standard.document\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"entity_id\": \"guides/intro\"") != null);
    // The full document payload — including the plain-text `textContent` — is
    // embedded verbatim, unlike the plan's digest-only projection.
    try std.testing.expect(std.mem.indexOf(u8, first, "\"textContent\":\"Intro prose.\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"payload_sha256\"") == null);
}

test "base-path deployments report the well-known limitation instead of a decoy" {
    const gpa = std.testing.allocator;
    var config = try testConfig(gpa);
    defer config.deinit(gpa);
    gpa.free(config.location.base_url);
    gpa.free(config.location.origin);
    gpa.free(config.location.base_path);
    config.location = try parseLocation(gpa, "https://example.com/repo", "https://example.com", "/repo");
    const pages = [_]PageInput{
        .{ .entity_id = "guides/intro", .output_path = "guides/intro.html", .title = "Intro", .status = .published, .published_at = "2024-01-20T14:30:00Z" },
    };
    var projection = try project(gpa, .{ .config = &config, .site_title = "Boris", .pages = &pages });
    defer projection.deinit(gpa);
    const surfaces = try verificationSurfaces(gpa, &config, &projection);
    defer {
        gpa.free(surfaces.well_known.content);
        if (surfaces.well_known.project_path) |path| gpa.free(path);
        gpa.free(surfaces.well_known.required_public_url);
        for (surfaces.document_links) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        gpa.free(surfaces.document_links);
    }
    try std.testing.expect(!surfaces.well_known.emittable);
    try std.testing.expect(surfaces.well_known.project_path == null);
    // The indexer always probes the domain-root path; the project tree cannot
    // serve it, which is why the build records `limited` instead of a decoy.
    try std.testing.expectEqualStrings("https://example.com/.well-known/site.standard.publication", surfaces.well_known.required_public_url);
}

test "location invariant rejects contradictions" {
    try std.testing.expectError(
        error.InvalidLocation,
        parseLocation(std.testing.allocator, "https://example.com/repo", "https://example.com", ""),
    );
    try std.testing.expectError(
        error.InvalidLocation,
        parseLocation(std.testing.allocator, "https://example.com/repo", "https://other.example", "/repo"),
    );
    var location = try parseLocation(std.testing.allocator, "https://example.com/repo/", "https://example.com", "/repo/");
    defer location.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://example.com/repo", location.base_url);
    try std.testing.expectEqualStrings("/repo", location.base_path);
}
