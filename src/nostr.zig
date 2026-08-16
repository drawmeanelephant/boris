//! Nostr NIP-23 long-form protocol primitives.
//!
//! This module owns the protocol facts and nothing else: kind, tag vocabulary
//! and order, pubkey and relay-URL grammar, timestamp conversion, canonical
//! article URLs, and the eligibility predicate. It is deliberately free of
//! profile, CLI, filesystem, clock, network, and key material, so the mapping
//! can be tested exhaustively without any of them.
//!
//! ## Protocol authority
//!
//! Mapped against `nostr-protocol/nips` at
//! `656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab` (2026-08-08), which was still the
//! repository head when this slice landed:
//!
//! - NIP-01 — addressable events, tag shape.
//! - NIP-23 — kind `30023`, the Markdown profile, `d`/`title`/`summary`/
//!   `published_at` metadata and `created_at` as the update time.
//! - NIP-24 — `r` is a web URL the event refers to; `t` values MUST be
//!   lowercase.
//! - NIP-73 — a normalized, fragment-free URL is an external content id:
//!   `["i", url]` with `["k", "web"]`.
//!
//! ## What is deliberately absent
//!
//! No event id, no signature, no `created_at`: all three require the author key
//! or the signing moment, which the offline plan must not have (`created_at`
//! participates in the NIP-01 event id, so supplying it here would make the
//! plan a signing input rather than a deterministic declaration). No relay
//! connection, no NIP-42 authentication, and no NIP-09 deletion.

const std = @import("std");
const graph = @import("graph.zig");
const identity = @import("identity.zig");
const rss_date = @import("rss_date.zig");

/// NIP-23 long-form article. Addressable: `(kind, pubkey, d)` is the address.
pub const kind_long_form: u32 = 30023;

/// A NIP-01 x-only public key in the hex form profiles and plans carry.
pub const pubkey_hex_len: usize = 64;

/// Bounds on relay configuration. Publishing is a later slice; these keep a
/// profile from declaring an unbounded wait before that slice exists.
pub const max_relays: usize = 32;
pub const min_timeout_ms: usize = 100;
pub const max_timeout_ms: usize = 60_000;
pub const default_timeout_ms: usize = 10_000;
pub const max_retries: usize = 5;

pub const Error = error{
    /// Author public key is not exactly 64 lowercase hex digits.
    InvalidPubkey,
    /// Relay URL is not a bare `wss://` (or loopback `ws://`) origin+path.
    InvalidRelay,
    /// Two configured relays normalize to the same target.
    DuplicateRelay,
    /// Relay list is empty, or longer than `max_relays`.
    InvalidRelayCount,
    /// Timeout or retry budget outside the documented bounds.
    InvalidRelayBudget,
    /// `published_at` is not the strict `YYYY-MM-DDTHH:MM:SSZ` form, or falls
    /// outside the representable range.
    InvalidPublishedAt,
    /// A `t` topic is empty, over-long, uppercase, or `#`-prefixed.
    InvalidTopic,
} || std.mem.Allocator.Error || identity.PathError;

// =============================================================================
// Author identity
// =============================================================================

/// Validate a NIP-01 public key as carried in a profile: exactly 64 lowercase
/// hex digits.
///
/// Lowercase is required rather than normalized. A pubkey is an identity, and
/// silently rewriting an identity to make it match is precisely the behavior a
/// signer-vs-plan mismatch check exists to catch.
pub fn validatePubkey(value: []const u8) Error!void {
    if (value.len != pubkey_hex_len) return error.InvalidPubkey;
    for (value) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return error.InvalidPubkey;
    }
}

// =============================================================================
// Relay targets
// =============================================================================

/// Normalize one configured relay URL, or reject it.
///
/// Accepted: `wss://host[:port][/path]`, and `ws://` only for an explicit
/// loopback host (mock relays in tests). Rejected: any other scheme, userinfo,
/// query, fragment, empty host, and a port that is not a bounded number.
///
/// Normalization is total and deterministic: scheme and host are lowercased,
/// the default port is dropped (443 for `wss`, 80 for `ws`), and a bare root
/// path is dropped so `wss://a/` and `wss://a` are one target rather than two.
pub fn normalizeRelayUrl(allocator: std.mem.Allocator, raw: []const u8) Error![]u8 {
    const secure_prefix = "wss://";
    const plain_prefix = "ws://";
    const secure = std.ascii.startsWithIgnoreCase(raw, secure_prefix);
    const plain = !secure and std.ascii.startsWithIgnoreCase(raw, plain_prefix);
    if (!secure and !plain) return error.InvalidRelay;

    const rest = raw[(if (secure) secure_prefix.len else plain_prefix.len)..];
    if (rest.len == 0) return error.InvalidRelay;
    if (std.mem.indexOfScalar(u8, rest, '@') != null) return error.InvalidRelay;
    if (std.mem.indexOfScalar(u8, rest, '?') != null) return error.InvalidRelay;
    if (std.mem.indexOfScalar(u8, rest, '#') != null) return error.InvalidRelay;
    for (rest) |c| {
        if (c <= 0x20 or c == 0x7f) return error.InvalidRelay;
    }

    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..path_start];
    const path = rest[path_start..];
    if (authority.len == 0) return error.InvalidRelay;
    if (std.mem.indexOf(u8, path, "//") != null) return error.InvalidRelay;
    if (std.mem.indexOf(u8, path, "..") != null) return error.InvalidRelay;

    var host = authority;
    var port: ?u16 = null;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        // A bracketed IPv6 literal keeps its colons; only a colon after the
        // closing bracket (or in a bare host) is a port separator.
        const in_ipv6 = authority[0] == '[' and colon < (std.mem.indexOfScalar(u8, authority, ']') orelse 0);
        if (!in_ipv6) {
            host = authority[0..colon];
            const digits = authority[colon + 1 ..];
            if (digits.len == 0 or digits.len > 5) return error.InvalidRelay;
            var value: u32 = 0;
            for (digits) |c| {
                if (c < '0' or c > '9') return error.InvalidRelay;
                value = value * 10 + (c - '0');
            }
            if (value == 0 or value > std.math.maxInt(u16)) return error.InvalidRelay;
            port = @intCast(value);
        }
    }
    if (host.len == 0) return error.InvalidRelay;
    for (host) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '[' or c == ']' or c == ':';
        if (!ok) return error.InvalidRelay;
    }
    if (plain and !isLoopbackHost(host)) return error.InvalidRelay;

    const default_port: u16 = if (secure) 443 else 80;
    const keep_port = if (port) |p| p != default_port else false;
    const keep_path = path.len > 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, if (secure) secure_prefix else plain_prefix);
    for (host) |c| try out.append(allocator, std.ascii.toLower(c));
    if (keep_port) try out.print(allocator, ":{d}", .{port.?});
    if (keep_path) try out.appendSlice(allocator, path);
    return try out.toOwnedSlice(allocator);
}

/// `ws://` is permitted only for a loopback relay, which is what a mock relay
/// in a test binds. Production traffic must be `wss://`.
fn isLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "[::1]");
}

/// Order normalized relays bytewise and reject duplicates.
///
/// Sorting in place makes the plan's relay list independent of profile order,
/// which is what lets two authors with the same relays produce the same bytes.
pub fn sortRelays(relays: [][]u8) Error!void {
    std.mem.sort([]u8, relays, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var i: usize = 1;
    while (i < relays.len) : (i += 1) {
        if (std.mem.eql(u8, relays[i - 1], relays[i])) return error.DuplicateRelay;
    }
}

// =============================================================================
// Time
// =============================================================================

/// Convert Boris's authored `published_at` to the decimal Unix seconds NIP-23's
/// `published_at` tag carries.
///
/// Clock-free by construction: the only input is the authored UTC timestamp, so
/// the same source always yields the same tag. Rejects pre-epoch dates, which
/// cannot be a first-publication time for a Boris page and would otherwise
/// serialize as a negative tag value.
pub fn publishedAtUnix(text: []const u8) Error!i64 {
    const ts = rss_date.parse(text) catch return error.InvalidPublishedAt;
    if (ts.year < 1970) return error.InvalidPublishedAt;
    const days = daysFromCivil(ts.year, ts.month, ts.day);
    const seconds = @as(i64, days) * 86_400 +
        @as(i64, ts.hour) * 3600 +
        @as(i64, ts.minute) * 60 +
        @as(i64, ts.second);
    return seconds;
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`). Pure integer arithmetic, no clock, no libc.
fn daysFromCivil(year: u16, month: u8, day: u8) i32 {
    var y: i32 = year;
    const m: i32 = month;
    const d: i32 = day;
    y -= if (m <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i32, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

// =============================================================================
// Canonical article URL
// =============================================================================

/// The absolute public URL of a Boris page: the publication `base_url` joined
/// to the page's HTML output path.
///
/// This is the value NIP-24's `r` and NIP-73's `i` both carry, so it must be
/// the URL that actually serves the page. `base_url` carries no trailing slash
/// (the publication-location invariant), and the output path is built only from
/// a validated entity id, so the result is absolute, fragment-free, and
/// single-slash-joined — which is exactly NIP-73's "normalized, no fragment".
pub fn canonicalArticleUrl(allocator: std.mem.Allocator, base_url: []const u8, entity_id: []const u8) Error![]u8 {
    const output_path = try identity.safeOutputRelativePath(allocator, entity_id);
    defer allocator.free(output_path);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url, output_path });
}

// =============================================================================
// Eligibility
// =============================================================================

/// Why a selected entity cannot become a NIP-23 article.
///
/// Every reason is reported, never silently skipped: an author who named a page
/// in the allowlist asked for it to be published, so the plan owes them the
/// specific defect.
pub const Ineligible = enum {
    /// Source is Textile or Cooklang. NIP-23 content is Markdown, and Boris
    /// does not convert between markup dialects.
    non_markdown_source,
    /// `status: draft`.
    draft_status,
    /// The entity id is path-derived, so an ordinary file rename would change
    /// the article's `d` tag and silently create a second article.
    derived_entity_id,
    missing_title,
    missing_summary,
    missing_published_at,

    pub fn name(self: Ineligible) []const u8 {
        return switch (self) {
            .non_markdown_source => "non-markdown-source",
            .draft_status => "draft-status",
            .derived_entity_id => "derived-entity-id",
            .missing_title => "missing-title",
            .missing_summary => "missing-summary",
            .missing_published_at => "missing-published-at",
        };
    }

    pub fn remediation(self: Ineligible) []const u8 {
        return switch (self) {
            .non_markdown_source => "publish Markdown, or remove this entity from nostr.articles",
            .draft_status => "set status: published, or remove this entity from nostr.articles",
            .derived_entity_id => "add an explicit frontmatter id: so the article address survives a rename",
            .missing_title => "add a frontmatter title:",
            .missing_summary => "add a frontmatter summary:",
            .missing_published_at => "add a frontmatter published_at: YYYY-MM-DDTHH:MM:SSZ",
        };
    }
};

/// First defect for a selected page, in a fixed check order, or `null` when the
/// page is eligible.
///
/// The order is fixed so a page with several defects always reports the same
/// one, and so the most structural defect (wrong dialect) is reported before a
/// missing field the author would otherwise fix first and still fail.
pub fn ineligibility(node: graph.Node, kind: identity.ContentKind) ?Ineligible {
    if (kind != .md and kind != .mdx) return .non_markdown_source;
    if (node.status) |status| {
        if (std.mem.eql(u8, status, "draft")) return .draft_status;
    }
    if (!node.id_explicit) return .derived_entity_id;
    if (node.title == null) return .missing_title;
    if (node.summary == null) return .missing_summary;
    if (node.published_at == null) return .missing_published_at;
    return null;
}

// =============================================================================
// Tags
// =============================================================================

/// One NIP-01 tag as this slice emits it: a name and exactly one value.
///
/// NIP-01 tags are arrays of arbitrary length; every tag in the v1 NIP-23
/// mapping is a two-element tag, so the narrower type makes an over-long tag
/// unrepresentable rather than merely unlikely.
pub const Tag = struct {
    name: []const u8,
    value: []const u8,
};

/// Validate one authored tag token as a NIP-24 `t` topic.
///
/// NIP-24 requires lowercase; NIP-73 says not to prepend `#`. Both are
/// rejected rather than normalized, because a topic is authored content and
/// rewriting it would publish something the author did not write.
pub fn validateTopic(value: []const u8) Error!void {
    if (value.len == 0 or value.len > 128) return error.InvalidTopic;
    if (value[0] == '#') return error.InvalidTopic;
    for (value) |c| {
        if (std.ascii.isUpper(c)) return error.InvalidTopic;
        if (c <= 0x20 or c == 0x7f) return error.InvalidTopic;
    }
}

/// The fixed tag order for a kind-30023 article:
/// `d`, `title`, `summary`, `published_at`, every `t` in authored order, `r`,
/// then NIP-73's `i` and `k`.
///
/// Callers own `out`, which must hold `tagCount(topics.len)` entries. Authored
/// topic order is preserved (it is authored data, not a set), while everything
/// else is positional, so identical input always yields an identical tag list.
pub fn tagCount(topic_count: usize) usize {
    return 7 + topic_count;
}

pub fn buildTags(
    out: []Tag,
    entity_id: []const u8,
    title: []const u8,
    summary: []const u8,
    published_at_unix: []const u8,
    topics: []const []const u8,
    canonical_url: []const u8,
) []Tag {
    std.debug.assert(out.len >= tagCount(topics.len));
    var i: usize = 0;
    out[i] = .{ .name = "d", .value = entity_id };
    i += 1;
    out[i] = .{ .name = "title", .value = title };
    i += 1;
    out[i] = .{ .name = "summary", .value = summary };
    i += 1;
    out[i] = .{ .name = "published_at", .value = published_at_unix };
    i += 1;
    for (topics) |topic| {
        out[i] = .{ .name = "t", .value = topic };
        i += 1;
    }
    out[i] = .{ .name = "r", .value = canonical_url };
    i += 1;
    out[i] = .{ .name = "i", .value = canonical_url };
    i += 1;
    out[i] = .{ .name = "k", .value = "web" };
    i += 1;
    return out[0..i];
}

// =============================================================================
// Digests
// =============================================================================

/// Lowercase hex SHA-256 of `bytes`, written into `out`.
///
/// The plan carries digests rather than the bytes themselves wherever a
/// consumer only needs to answer "did this change", which is what makes an
/// unchanged republish detectable without a remote fetch.
pub const digest_hex_len: usize = 64;

pub fn digestHex(bytes: []const u8, out: *[digest_hex_len]u8) void {
    var raw: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    _ = std.fmt.bufPrint(out, "{x}", .{&raw}) catch unreachable;
}

/// Decimal text for a protocol integer, in a caller-owned fixed buffer.
///
/// Protocol values (`published_at`, a defect's line) are formatted here rather
/// than in the plan emitter: `nostr_plan.zig` is an enforced `json_out` emitter
/// and must not format bytes itself, so every runtime string it writes is
/// produced by a reviewed helper and handed to the encoder.
pub const Decimal = struct {
    buf: [24]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Decimal) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn decimal(value: i64) Decimal {
    var out = Decimal{};
    const written = std.fmt.bufPrint(&out.buf, "{d}", .{value}) catch unreachable;
    out.len = written.len;
    return out;
}

/// Digest the event intention: kind, then every tag as `name\x1Fvalue\x1E`,
/// then the content.
///
/// The unit and record separators make the digest injective — without them a
/// different tag split could produce identical bytes. Relay destinations and
/// signing time are deliberately excluded, which is what lets an unchanged
/// article be recognized without a remote fetch, and lets a relay-list-only
/// change reuse an existing signature.
pub fn intentionDigestHex(
    allocator: std.mem.Allocator,
    tags: []const Tag,
    content: []const u8,
    out: *[digest_hex_len]u8,
) Error!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const kind = decimal(kind_long_form);
    try buf.appendSlice(allocator, kind.slice());
    try buf.append(allocator, 0x1E);
    for (tags) |tag| {
        try buf.appendSlice(allocator, tag.name);
        try buf.append(allocator, 0x1F);
        try buf.appendSlice(allocator, tag.value);
        try buf.append(allocator, 0x1E);
    }
    try buf.appendSlice(allocator, content);
    digestHex(buf.items, out);
}

/// Digest the delivery configuration alone, so a relay or budget change is
/// visibly a delivery change rather than an article change.
pub fn deliveryDigestHex(
    allocator: std.mem.Allocator,
    relays: []const []const u8,
    timeout_ms: usize,
    retries: usize,
    out: *[digest_hex_len]u8,
) Error!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (relays) |relay| {
        try buf.appendSlice(allocator, relay);
        try buf.append(allocator, 0x1E);
    }
    const timeout = decimal(@intCast(timeout_ms));
    try buf.appendSlice(allocator, timeout.slice());
    try buf.append(allocator, 0x1F);
    const retry = decimal(@intCast(retries));
    try buf.appendSlice(allocator, retry.slice());
    digestHex(buf.items, out);
}

// =============================================================================
// NIP-01 event serialization
// =============================================================================

/// Escape one string exactly as the canonical NIP-01 event serialization
/// requires: the compact JSON form `JSON.stringify` produces for the same
/// string. The event id is the SHA-256 of these exact bytes, so the escaping
/// is part of the protocol: `\"`, `\\`, `\b`, `\f`, `\n`, `\r`, `\t`, and
/// `\u00xx` for other control bytes, everything else verbatim (non-ASCII
/// stays raw UTF-8, exactly like standard JSON serializers).
pub fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '\"');
    for (s) |c| {
        switch (c) {
            '\"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const piece = try std.fmt.bufPrint(&tmp, "\\u00{x:0>2}", .{c});
                    try out.appendSlice(allocator, piece);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '\"');
}

/// The exact NIP-01 preimage: `[0, "<pubkey>", <created_at>, <kind>,
/// [<tags>], "<content>"]` — compact, no whitespace, canonical escaping. The
/// event id is the SHA-256 of these bytes; the signing and publish slices both
/// serialize through this one function so a signed bundle and a re-verified
/// publish never disagree about the wire bytes.
pub fn appendEventPreimage(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pubkey_hex: []const u8,
    created_at: i64,
    kind: u32,
    tags: []const Tag,
    content: []const u8,
) !void {
    try out.appendSlice(allocator, "[0,\"");
    try out.appendSlice(allocator, pubkey_hex);
    try out.appendSlice(allocator, "\",");
    try out.appendSlice(allocator, decimal(created_at).slice());
    try out.appendSlice(allocator, ",");
    try out.appendSlice(allocator, decimal(kind).slice());
    try out.appendSlice(allocator, ",[");
    for (tags, 0..) |tag, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '[');
        try appendJsonString(out, allocator, tag.name);
        try out.append(allocator, ',');
        try appendJsonString(out, allocator, tag.value);
        try out.append(allocator, ']');
    }
    try out.appendSlice(allocator, "],");
    try appendJsonString(out, allocator, content);
    try out.append(allocator, ']');
}

// =============================================================================
// Secret key input (NIP-19 nsec and hex)
// =============================================================================

/// Bech32 charset (BIP-173). NIP-19 secret keys use bech32 with the `nsec`
/// human-readable part and a 32-byte payload.
const bech32_charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

fn bech32CharValue(c: u8) ?u5 {
    const index = std.mem.indexOfScalar(u8, bech32_charset, c) orelse return null;
    return @intCast(index);
}

fn bech32Polymod(values: []const u5) u32 {
    const gen = [5]u32{ 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };
    var chk: u32 = 1;
    for (values) |v| {
        const top = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ v;
        for (0..5) |i| {
            if (((top >> @as(u5, @intCast(i))) & 1) == 1) chk ^= gen[i];
        }
    }
    return chk;
}

/// BIP-173 `HrpExpand`: the HRP as 5-bit high then low halves around a zero
/// separator. Caller owns `out`, which must hold `2 * hrp.len + 1` entries.
fn bech32HrpExpand(hrp: []const u8, out: []u5) usize {
    var n: usize = 0;
    for (hrp) |ch| {
        out[n] = @intCast(ch >> 5);
        n += 1;
    }
    out[n] = 0;
    n += 1;
    for (hrp) |ch| {
        out[n] = @intCast(ch & 0x1f);
        n += 1;
    }
    return n;
}

/// Decode a NIP-19 `nsec` secret key (bech32 with BIP-173 checksum) into
/// `out`. Returns `false` for a wrong HRP, malformed characters, a bad
/// checksum, or a payload that is not exactly 32 bytes. The secret key is a
/// credential, so any of these is a refusal, never a guess.
pub fn decodeNsec(input: []const u8, out: *[32]u8) bool {
    const sep = std.mem.indexOfScalar(u8, input, '1') orelse return false;
    const hrp = input[0..sep];
    if (hrp.len == 0 or !std.mem.eql(u8, hrp, "nsec")) return false;
    const data = input[sep + 1 ..];
    if (data.len < 6 or data.len > 100) return false;

    // Decode the data chars once: they feed both the payload and the
    // checksum (BIP-173 polymod over HRP expansion plus the whole data part
    // must equal 1).
    var values: [100]u5 = undefined;
    var check: [128]u5 = undefined;
    var check_len = bech32HrpExpand(hrp, &check);
    for (data, 0..) |ch, i| {
        const v = bech32CharValue(ch) orelse return false;
        values[i] = v;
        check[check_len + i] = v;
    }
    check_len += data.len;
    if (bech32Polymod(check[0..check_len]) != 1) return false;

    // Convert the 5-bit payload (everything before the checksum) to bytes.
    const payload = values[0 .. data.len - 6];
    var acc: u32 = 0;
    var bits: u5 = 0;
    var out_len: usize = 0;
    for (payload) |v| {
        acc = (acc << 5) | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            out[out_len] = @intCast((acc >> bits) & 0xff);
            out_len += 1;
            if (out_len > 32) return false;
        }
    }
    // Padding must be zero; a non-zero trailing group is a malformed string.
    if (bits != 0 and (acc & ((@as(u32, 1) << bits) - 1)) != 0) return false;
    return out_len == 32;
}

/// Decode one secret-key input line into a 32-byte secret: exactly 64 hex
/// digits (either case) or a NIP-19 `nsec` string. Leading/trailing
/// whitespace is ignored. Any other input is refused.
pub fn decodeSecretKey(input: []const u8, out: *[32]u8) bool {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (trimmed.len == 64) {
        const bytes = std.fmt.hexToBytes(out, trimmed) catch return false;
        return bytes.len == 32;
    }
    return decodeNsec(trimmed, out);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "pubkey: exactly 64 lowercase hex digits" {
    const good = "a" ** 64;
    try validatePubkey(good);
    try testing.expectError(error.InvalidPubkey, validatePubkey("a" ** 63));
    try testing.expectError(error.InvalidPubkey, validatePubkey("a" ** 65));
    try testing.expectError(error.InvalidPubkey, validatePubkey("A" ** 64));
    try testing.expectError(error.InvalidPubkey, validatePubkey("g" ** 64));
    try testing.expectError(error.InvalidPubkey, validatePubkey(""));
}

fn expectRelay(expected: []const u8, raw: []const u8) !void {
    const got = try normalizeRelayUrl(testing.allocator, raw);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "relay: normalization is total and deterministic" {
    try expectRelay("wss://relay.example.com", "wss://relay.example.com");
    try expectRelay("wss://relay.example.com", "wss://relay.example.com/");
    try expectRelay("wss://relay.example.com", "WSS://Relay.Example.COM");
    try expectRelay("wss://relay.example.com", "wss://relay.example.com:443");
    try expectRelay("wss://relay.example.com:8443", "wss://relay.example.com:8443");
    try expectRelay("wss://relay.example.com/nostr", "wss://relay.example.com/nostr");
}

test "relay: ws is loopback-only, everything else is refused" {
    try expectRelay("ws://localhost:7447", "ws://localhost:7447");
    try expectRelay("ws://127.0.0.1", "ws://127.0.0.1:80");
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "ws://relay.example.com"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "https://relay.example.com"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "relay.example.com"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "wss://"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "wss://user:pw@relay.example.com"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "wss://relay.example.com?x=1"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "wss://relay.example.com#frag"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "wss://relay.example.com:0"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "wss://relay.example.com:99999"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "wss://relay example.com"));
    try testing.expectError(error.InvalidRelay, normalizeRelayUrl(testing.allocator, "wss://relay.example.com/a/../b"));
}

test "relay: an IPv6 literal keeps its colons" {
    try expectRelay("wss://[2001:db8::1]", "wss://[2001:db8::1]");
    try expectRelay("wss://[2001:db8::1]:8443", "wss://[2001:db8::1]:8443");
}

test "relay: sorting is bytewise and duplicates fail closed" {
    var a = try testing.allocator.dupe(u8, "wss://b.example.com");
    var b = try testing.allocator.dupe(u8, "wss://a.example.com");
    var relays = [_][]u8{ a, b };
    try sortRelays(&relays);
    try testing.expectEqualStrings("wss://a.example.com", relays[0]);
    try testing.expectEqualStrings("wss://b.example.com", relays[1]);
    testing.allocator.free(a);
    testing.allocator.free(b);

    a = try testing.allocator.dupe(u8, "wss://a.example.com");
    b = try testing.allocator.dupe(u8, "wss://a.example.com");
    var dupes = [_][]u8{ a, b };
    defer testing.allocator.free(a);
    defer testing.allocator.free(b);
    try testing.expectError(error.DuplicateRelay, sortRelays(&dupes));
}

test "published_at: authored UTC converts to unix seconds" {
    try testing.expectEqual(@as(i64, 0), try publishedAtUnix("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(i64, 1675642635), try publishedAtUnix("2023-02-06T00:17:15Z"));
    // A leap day and a century non-leap boundary.
    try testing.expectEqual(@as(i64, 951782400), try publishedAtUnix("2000-02-29T00:00:00Z"));
    try testing.expectEqual(@as(i64, 1709164800), try publishedAtUnix("2024-02-29T00:00:00Z"));
    try testing.expectEqual(@as(i64, 4102444800), try publishedAtUnix("2100-01-01T00:00:00Z"));
}

test "published_at: only the strict authored form is accepted" {
    try testing.expectError(error.InvalidPublishedAt, publishedAtUnix("2024-02-30T00:00:00Z"));
    try testing.expectError(error.InvalidPublishedAt, publishedAtUnix("2024-01-01"));
    try testing.expectError(error.InvalidPublishedAt, publishedAtUnix("2024-01-01T00:00:00+01:00"));
    try testing.expectError(error.InvalidPublishedAt, publishedAtUnix("1969-12-31T23:59:59Z"));
}

test "canonical url: absolute, single-slash, html output path" {
    const url = try canonicalArticleUrl(testing.allocator, "https://example.com/docs", "guides/intro");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://example.com/docs/guides/intro.html", url);
    try testing.expect(std.mem.indexOf(u8, url, "docs//") == null);
    try testing.expect(std.mem.indexOfScalar(u8, url, '#') == null);
}

test "canonical url: an unusable entity id fails rather than building a path" {
    try testing.expectError(error.EmptyId, canonicalArticleUrl(testing.allocator, "https://example.com", ""));
    try testing.expectError(error.AbsolutePath, canonicalArticleUrl(testing.allocator, "https://example.com", "/abs"));
}

fn testNode(overrides: struct {
    status: ?[]const u8 = null,
    id_explicit: bool = true,
    title: ?[]const u8 = "Title",
    summary: ?[]const u8 = "Summary",
    published_at: ?[]const u8 = "2024-01-20T14:30:00Z",
}) graph.Node {
    return .{
        .id = "guides/intro",
        .source_path = "guides/intro.md",
        .status = overrides.status,
        .id_explicit = overrides.id_explicit,
        .title = overrides.title,
        .summary = overrides.summary,
        .published_at = overrides.published_at,
    };
}

test "eligibility: a complete explicit-id Markdown page is eligible" {
    try testing.expectEqual(@as(?Ineligible, null), ineligibility(testNode(.{}), .md));
    try testing.expectEqual(@as(?Ineligible, null), ineligibility(testNode(.{}), .mdx));
    try testing.expectEqual(@as(?Ineligible, null), ineligibility(testNode(.{ .status = "published" }), .md));
    try testing.expectEqual(@as(?Ineligible, null), ineligibility(testNode(.{ .status = "archived" }), .md));
}

test "eligibility: every defect is named, in a fixed order" {
    try testing.expectEqual(Ineligible.non_markdown_source, ineligibility(testNode(.{}), .textile).?);
    try testing.expectEqual(Ineligible.non_markdown_source, ineligibility(testNode(.{}), .cook).?);
    try testing.expectEqual(Ineligible.draft_status, ineligibility(testNode(.{ .status = "draft" }), .md).?);
    try testing.expectEqual(Ineligible.derived_entity_id, ineligibility(testNode(.{ .id_explicit = false }), .md).?);
    try testing.expectEqual(Ineligible.missing_title, ineligibility(testNode(.{ .title = null }), .md).?);
    try testing.expectEqual(Ineligible.missing_summary, ineligibility(testNode(.{ .summary = null }), .md).?);
    try testing.expectEqual(Ineligible.missing_published_at, ineligibility(testNode(.{ .published_at = null }), .md).?);

    // Dialect outranks a missing field; a derived id outranks metadata.
    try testing.expectEqual(Ineligible.non_markdown_source, ineligibility(testNode(.{ .title = null }), .cook).?);
    try testing.expectEqual(Ineligible.derived_entity_id, ineligibility(testNode(.{ .id_explicit = false, .title = null }), .md).?);
}

test "topics: lowercase, unprefixed, bounded" {
    try validateTopic("recipes");
    try validateTopic("long-form");
    try testing.expectError(error.InvalidTopic, validateTopic(""));
    try testing.expectError(error.InvalidTopic, validateTopic("Recipes"));
    try testing.expectError(error.InvalidTopic, validateTopic("#recipes"));
    try testing.expectError(error.InvalidTopic, validateTopic("a b"));
    try testing.expectError(error.InvalidTopic, validateTopic("a" ** 129));
}

test "tags: fixed order with authored topics preserved" {
    var buf: [16]Tag = undefined;
    const topics = [_][]const u8{ "zeta", "alpha" };
    const tags = buildTags(
        &buf,
        "guides/intro",
        "Intro",
        "A summary.",
        "1705761000",
        &topics,
        "https://example.com/guides/intro.html",
    );
    try testing.expectEqual(@as(usize, 9), tags.len);
    try testing.expectEqual(tagCount(topics.len), tags.len);
    try testing.expectEqualStrings("d", tags[0].name);
    try testing.expectEqualStrings("guides/intro", tags[0].value);
    try testing.expectEqualStrings("title", tags[1].name);
    try testing.expectEqualStrings("summary", tags[2].name);
    try testing.expectEqualStrings("published_at", tags[3].name);
    try testing.expectEqualStrings("1705761000", tags[3].value);
    // Authored order, not sorted: topics are content.
    try testing.expectEqualStrings("t", tags[4].name);
    try testing.expectEqualStrings("zeta", tags[4].value);
    try testing.expectEqualStrings("t", tags[5].name);
    try testing.expectEqualStrings("alpha", tags[5].value);
    try testing.expectEqualStrings("r", tags[6].name);
    try testing.expectEqualStrings("i", tags[7].name);
    try testing.expectEqualStrings("https://example.com/guides/intro.html", tags[7].value);
    try testing.expectEqualStrings("k", tags[8].name);
    try testing.expectEqualStrings("web", tags[8].value);
}

test "tags: an article with no topics still carries the seven positional tags" {
    var buf: [8]Tag = undefined;
    const tags = buildTags(&buf, "index", "Home", "Summary.", "0", &.{}, "https://example.com/index.html");
    try testing.expectEqual(@as(usize, 7), tags.len);
    try testing.expectEqualStrings("published_at", tags[3].name);
    try testing.expectEqualStrings("r", tags[4].name);
}

test "digest: lowercase hex sha-256 of the exact bytes" {
    var out: [digest_hex_len]u8 = undefined;
    digestHex("", &out);
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &out);
    digestHex("abc", &out);
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &out);
}

test "nsec: the NIP-19 test vector decodes to its hex secret" {
    // nostr-protocol/nips @ 656cecc7, 19.md: this nsec is the NIP-19 test
    // vector for the hex secret below.
    var out: [32]u8 = undefined;
    try testing.expect(decodeNsec("nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5", &out));
    const expected = try testing.allocator.dupe(u8, "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa");
    defer testing.allocator.free(expected);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{out}) catch unreachable;
    try testing.expectEqualStrings(expected, &hex);
}

test "nsec: wrong HRP, bad checksum, and wrong length are refused" {
    var out: [32]u8 = undefined;
    // npub HRP is a public key, not a secret.
    try testing.expect(!decodeNsec("npub1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5", &out));
    // Flip one payload character: checksum must fail.
    try testing.expect(!decodeNsec("nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe4", &out));
    // Uppercase data is invalid bech32.
    try testing.expect(!decodeNsec("NSEC1VL029MGPSPEDVA04G90VLTKH6FVH240ZQTV9K0T9AF8935KE9LAQSNLFE5", &out));
    // No separator.
    try testing.expect(!decodeNsec("nsec0", &out));
}

test "secret key: hex and nsec inputs decode to the same secret" {
    const hex_input = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa";
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try testing.expect(decodeSecretKey(hex_input, &a));
    try testing.expect(decodeSecretKey("nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5", &b));
    try testing.expectEqual(a, b);
    // Whitespace is tolerated around the input line.
    try testing.expect(decodeSecretKey("  " ++ hex_input ++ "\n", &a));
}

test "secret key: malformed inputs are refused" {
    var out: [32]u8 = undefined;
    try testing.expect(!decodeSecretKey("", &out));
    try testing.expect(!decodeSecretKey("not-a-key", &out));
    try testing.expect(!decodeSecretKey("zz" ** 32, &out));
    try testing.expect(!decodeSecretKey("a" ** 63, &out));
    try testing.expect(!decodeSecretKey("a" ** 65, &out));
}
