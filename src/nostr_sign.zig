//! Offline Nostr NIP-23 signing: `boris nostr sign`.
//!
//! Reads the unsigned publication plan emitted by `boris nostr plan`,
//! verifies it byte-for-byte, supplies `created_at`, produces the exact
//! NIP-01 event id and BIP-340 signature for every article, and writes a
//! signed-event bundle bound to the exact plan bytes. It opens no socket,
//! contacts no relay, and never publishes; the bundle is the artifact a later
//! publish slice delivers.
//!
//! ```text
//! boris nostr plan   → deterministic unsigned intentions   (nostr_plan.zig)
//! boris nostr sign   → event id + BIP-340 signature        (this module)
//! boris nostr publish→ relay delivery + observed evidence  (later slice)
//! ```
//!
//! ## The signing boundary (#454 §10, #495)
//!
//! - The secret key is read once from stdin (`--key-stdin`), as 64 hex digits
//!   or a NIP-19 `nsec`, and zeroed best-effort after use. It never enters
//!   the plan, the bundle, diagnostics, logs, or git history.
//! - The signer public key must match the plan's expected author. A mismatch
//!   is a refusal (`ENOSTRSIGN`), never a silent re-identity.
//! - Signing is a controlled mutation of a plan intention: `created_at` is a
//!   signing-time input (current Unix seconds by default, or an explicit
//!   test/recovery `--created-at` override), never a build-phase value.
//! - The signature is verified before any bundle is written. An unverified
//!   signature is never emitted.
//! - BIP-340 auxiliary randomness: fresh 32-byte CSPRNG bytes for production
//!   signing, failing closed when unavailable; conformance tests inject fixed
//!   aux bytes so expected signatures are reproducible.
//!
//! ## Update ordering (NIP-01 tie-break, #495)
//!
//! For addressable events with the same `created_at`, relays resolve the tie
//! by event-id ordering. When a prior signed bundle is supplied with
//! `--prior`:
//!
//! - an unchanged intention reuses the exact prior signed event (same id,
//!   signature, and `created_at`; disposition `reused`);
//! - a changed intention requires the new `created_at` to be **strictly
//!   greater than** the prior event's `created_at`;
//! - if the wall clock cannot satisfy that (same-second rapid update, or a
//!   future prior timestamp), the run fails deterministically with
//!   `ENOSTRTIME` unless an explicit documented `--created-at` override
//!   satisfies it — never a silently weaker event that some relays discard
//!   as the older addressable event.
//!
//! ## Determinism
//!
//! The bundle is byte-deterministic for identical plan bytes, key, aux, and
//! `created_at`. The only signing-time inputs are the wall clock (default
//! `created_at`) and the CSPRNG (aux), both of which the CLI can pin for
//! tests. The bundle carries the SHA-256 digest of the exact plan bytes it
//! was signed from.

const std = @import("std");
const diag = @import("diag.zig");
const json_out = @import("json_out.zig");
const nostr = @import("nostr.zig");
const keys = @import("nostr_keys.zig");
const plan_mod = @import("nostr_plan.zig");

const Io = std.Io;

pub const artifact_format = "boris-nostr-signed-bundle";
pub const schema_version: u32 = 1;

/// Bounds for artifacts the runner reads. The plan embeds full article
/// content, so the bound is generous but still finite; a plan beyond it is
/// refused rather than unboundedly buffered.
pub const max_plan_bytes: usize = 256 * 1024 * 1024;
/// Secret-key stdin bound: hex is 64 chars, nsec is 63; 128 leaves room for
/// surrounding whitespace and a trailing newline, and keeps the read bounded.
pub const max_secret_bytes: usize = 128;

pub const Options = struct {
    /// Exact bytes of the plan artifact (`boris nostr plan` output).
    plan: []const u8,
    /// Secret key input: 64 hex digits or a NIP-19 `nsec` string.
    key: []const u8,
    /// `created_at` in Unix seconds. `null` → the wall clock at run time
    /// (the signing-time policy).
    created_at: ?i64 = null,
    /// BIP-340 auxiliary randomness. `null` → fresh CSPRNG bytes. Production
    /// must never supply a fixed value; conformance/vector tests inject one
    /// so expected signatures are reproducible.
    aux_rand: ?[32]u8 = null,
    /// Exact bytes of a prior signed bundle, for reuse and update ordering.
    prior: ?[]const u8 = null,
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    /// Owns every parsed plan string, tag copy, and diagnostic string.
    arena: std.heap.ArenaAllocator,
    /// gpa-owned list; the strings inside are arena-owned.
    diagnostics: std.ArrayList(diag.Diagnostic) = .empty,
    /// Canonical bundle bytes, gpa-owned. Present only when every selected
    /// article produced a signed or reused event.
    bundle: ?[]u8 = null,

    pub fn ok(self: *const Result) bool {
        return self.bundle != null;
    }

    pub fn deinit(self: *Result) void {
        if (self.bundle) |bytes| self.gpa.free(bytes);
        self.diagnostics.deinit(self.gpa);
        self.arena.deinit();
    }
};

// =============================================================================
// Plan artifact shape (parsed from the `boris nostr plan` JSON)
// =============================================================================

const ArticleJson = struct {
    entity_id: []const u8,
    kind: u32,
    tags: [][]const []const u8,
    content: []const u8,
    intention_digest: []const u8,
};

const PlanJson = struct {
    format: []const u8,
    schema_version: u32,
    protocol: struct {
        nips_revision: []const u8 = "",
        research_date: []const u8 = "",
        kind: u32 = 0,
    },
    author: struct { expected_pubkey: []const u8 = "" },
    articles: []const ArticleJson,
};

const PriorArticle = struct {
    d: []const u8 = "",
    intention_digest: []const u8 = "",
    created_at: i64 = 0,
    event_id: []const u8 = "",
    signature: []const u8 = "",
};

const PriorBundleJson = struct {
    format: []const u8,
    schema_version: u32,
    signer: struct { pubkey: []const u8 = "" },
    articles: []const PriorArticle,
};

/// One signed article as the emitter renders it.
const ArticleOut = struct {
    entity_id: []const u8,
    intention_digest: []const u8,
    /// `"signed"` or `"reused"`.
    disposition: []const u8,
    created_at: i64,
    published_at_unix: i64,
    event_id: []const u8,
    signature: []const u8,
    signature_verified: bool,
    tags: []const nostr.Tag,
    content: []const u8,
};

/// Build the signed bundle, or collect diagnostics. A non-null `bundle` means
/// every selected article produced a verified signed (or reused) event; any
/// error diagnostic means no bundle at all — a signing run never emits a
/// partially signed artifact.
pub fn run(io: Io, gpa: std.mem.Allocator, options: Options) !Result {
    var result = Result{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer result.deinit();
    const arena = result.arena.allocator();

    const plan = parsePlan(arena, options.plan) catch |err| {
        try reject(&result, .ENOSTRPLAN, "", "plan artifact is invalid", planRemediation(err));
        return result;
    };
    var plan_digest: [nostr.digest_hex_len]u8 = undefined;
    nostr.digestHex(options.plan, &plan_digest);

    // Secret key: bounded, decoded once, zeroed best-effort after use.
    var secret: [32]u8 = undefined;
    if (!nostr.decodeSecretKey(options.key, &secret)) {
        try reject(&result, .ENOSTRSIGN, "", "secret key input is neither 64 hex digits nor a NIP-19 nsec", "pipe the key on stdin; never pass it as an argument, in a profile, or in an environment variable");
        return result;
    }
    defer std.crypto.secureZero(u8, &secret);

    var ctx = keys.Context.initRandomized(io) catch {
        try reject(&result, .ENOSTRSIGN, "", "could not initialize the secp256k1 context with fresh randomness", "retry; the signer fails closed when secure randomness is unavailable");
        return result;
    };
    defer ctx.deinit();

    var keypair = ctx.keyPairFromSecretKey(secret) catch {
        try reject(&result, .ENOSTRSIGN, "", "the secret key does not yield a valid secp256k1 keypair", "check the key; a zero or out-of-range secret is refused");
        return result;
    };
    defer std.crypto.secureZero(u8, &keypair.secret_key);

    var pubkey_hex_buf: [64]u8 = undefined;
    const pubkey_hex = try std.fmt.bufPrint(&pubkey_hex_buf, "{x}", .{keypair.public_key});
    if (!std.mem.eql(u8, pubkey_hex, plan.author.expected_pubkey)) {
        try reject(&result, .ENOSTRSIGN, "", "signer public key does not match the plan's expected author public key", "sign with the key the plan's nostr.pubkey names");
        return result;
    }

    const aux: [32]u8 = options.aux_rand orelse blk: {
        var buf: [32]u8 = undefined;
        io.randomSecure(&buf) catch {
            try reject(&result, .ENOSTRSIGN, "", "could not obtain fresh randomness for BIP-340 auxiliary randomness", "retry; the signer fails closed when aux randomness is unavailable");
            return result;
        };
        break :blk buf;
    };

    const created_at: i64 = options.created_at orelse blk: {
        const now = Io.Timestamp.now(io, .real);
        break :blk @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    };

    var prior_articles: ?[]const PriorArticle = null;
    if (options.prior) |prior_bytes| {
        const prior = parsePrior(arena, prior_bytes) catch |err| {
            try reject(&result, .ENOSTRPLAN, "", "prior signed bundle is invalid", priorRemediation(err));
            return result;
        };
        if (!std.mem.eql(u8, prior.signer.pubkey, pubkey_hex)) {
            try reject(&result, .ENOSTRPLAN, "", "prior signed bundle was produced by a different identity", "supply a prior bundle signed by the plan's expected author");
            return result;
        }
        prior_articles = prior.articles;
    }

    var articles: std.ArrayList(ArticleOut) = .empty;
    defer articles.deinit(arena);

    for (plan.articles) |article| {
        try processArticle(arena, &result, &articles, article, &ctx, keypair, pubkey_hex, created_at, aux, prior_articles);
    }

    diag.sortDiagnostics(result.diagnostics.items);
    if (hasError(result.diagnostics.items)) return result;

    result.bundle = try renderBundle(gpa, &plan_digest, pubkey_hex, articles.items);
    return result;
}

fn hasError(diagnostics: []const diag.Diagnostic) bool {
    for (diagnostics) |d| {
        if (d.severity == .error_) return true;
    }
    return false;
}

fn planRemediation(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidPlanFormat => "re-run boris nostr plan; the artifact format is not a publication plan",
        error.InvalidPlanSchema => "re-run boris nostr plan; the artifact schema version is not supported",
        error.InvalidPlanKind => "re-run boris nostr plan; the protocol kind is not 30023",
        else => "re-run boris nostr plan and sign its exact output",
    };
}

fn priorRemediation(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidPriorFormat => "supply the exact bundle boris nostr sign produced",
        error.InvalidPriorSchema => "supply a prior bundle with a supported schema version",
        else => "supply the exact bundle boris nostr sign produced",
    };
}

fn parsePlan(arena: std.mem.Allocator, bytes: []const u8) !PlanJson {
    // Envelope fields the signer does not consume (site, delivery) are part
    // of the plan artifact; a version-tolerant reader ignores them and stays
    // strict about the fields it does consume.
    const parsed = try std.json.parseFromSlice(PlanJson, arena, bytes, .{ .ignore_unknown_fields = true });
    const plan = parsed.value;
    if (!std.mem.eql(u8, plan.format, plan_mod.artifact_format)) return error.InvalidPlanFormat;
    if (plan.schema_version != plan_mod.schema_version) return error.InvalidPlanSchema;
    if (plan.protocol.kind != nostr.kind_long_form) return error.InvalidPlanKind;
    return plan;
}

fn parsePrior(arena: std.mem.Allocator, bytes: []const u8) !PriorBundleJson {
    const parsed = try std.json.parseFromSlice(PriorBundleJson, arena, bytes, .{ .ignore_unknown_fields = true });
    const prior = parsed.value;
    if (!std.mem.eql(u8, prior.format, artifact_format)) return error.InvalidPriorFormat;
    if (prior.schema_version != schema_version) return error.InvalidPriorSchema;
    return prior;
}

/// One article: validate against the plan contract, resolve reuse/update
/// ordering against a prior bundle, sign (or reuse), verify, and append to
/// `articles`.
fn processArticle(
    arena: std.mem.Allocator,
    result: *Result,
    articles: *std.ArrayList(ArticleOut),
    article: ArticleJson,
    ctx: *const keys.Context,
    keypair: keys.KeyPair,
    pubkey_hex: []const u8,
    created_at: i64,
    aux: [32]u8,
    prior_articles: ?[]const PriorArticle,
) !void {
    if (article.kind != nostr.kind_long_form) {
        try reject(result, .ENOSTRPLAN, article.entity_id, "plan article is not kind 30023", "re-plan; the kind is a protocol constant");
        return;
    }
    const tags = parseTags(arena, article.tags) catch {
        try reject(result, .ENOSTRPLAN, article.entity_id, "plan article tags are malformed", "re-plan and sign the fresh output");
        return;
    };
    // The `d` tag names the address `(kind, pubkey, d)` and must equal the
    // entity id, which is the stable address rule the plan enforces.
    var has_d = false;
    for (tags) |tag| {
        if (std.mem.eql(u8, tag.name, "d")) {
            has_d = true;
            if (!std.mem.eql(u8, tag.value, article.entity_id)) {
                try reject(result, .ENOSTRPLAN, article.entity_id, "plan article d tag does not match its entity id", "re-plan; the d tag is the article address");
                return;
            }
        }
    }
    if (!has_d) {
        try reject(result, .ENOSTRPLAN, article.entity_id, "plan article carries no d tag", "re-plan; an editable NIP-23 article needs a stable d");
        return;
    }

    // The intention digest is the plan's own identity for this article: it
    // proves the exact tags and content were signed, and it is what makes
    // "unchanged since the last publish" answerable without a remote fetch.
    var recomputed: [nostr.digest_hex_len]u8 = undefined;
    try nostr.intentionDigestHex(arena, tags, article.content, &recomputed);
    if (!std.mem.eql(u8, &recomputed, article.intention_digest)) {
        try reject(result, .ENOSTRPLAN, article.entity_id, "plan article changed after planning (intention digest mismatch)", "re-run boris nostr plan and sign its fresh output");
        return;
    }

    const published_at_unix = findPublishedAt(tags) orelse {
        try reject(result, .ENOSTRPLAN, article.entity_id, "plan article carries no valid published_at tag", "re-plan; NIP-23 requires a first-publication time");
        return;
    };

    var disposition: []const u8 = "signed";
    var article_created_at = created_at;
    var reuse: ?*const PriorArticle = null;
    if (prior_articles) |prior| {
        for (prior) |*pa| {
            if (std.mem.eql(u8, pa.d, article.entity_id)) {
                if (std.mem.eql(u8, pa.intention_digest, article.intention_digest)) {
                    // Unchanged intention: reuse the exact prior signed event;
                    // never re-sign merely to change created_at.
                    disposition = "reused";
                    article_created_at = pa.created_at;
                    reuse = pa;
                } else if (created_at <= pa.created_at) {
                    // Changed intention: the new event must win the
                    // addressable-event replacement tie-break by created_at.
                    try reject(result, .ENOSTRTIME, article.entity_id, "update ordering: a changed article needs created_at strictly greater than the prior event's created_at (NIP-01 tie-break)", "sign with --created-at one second after the prior created_at, or use the documented recovery override");
                    return;
                }
                break;
            }
        }
    }

    if (article_created_at < published_at_unix) {
        try reject(result, .ENOSTRTIME, article.entity_id, "created_at precedes the article's published_at", "sign at or after the authored first-publication time, or use an explicit --created-at override");
        return;
    }

    var event_id_hex: []const u8 = undefined;
    var signature_hex: []const u8 = undefined;
    const signature_verified = true;
    var event_id_bytes: [32]u8 = undefined;

    if (reuse) |pa| {
        event_id_hex = try arena.dupe(u8, pa.event_id);
        signature_hex = try arena.dupe(u8, pa.signature);
    } else {
        var preimage: std.ArrayList(u8) = .empty;
        defer preimage.deinit(arena);
        try nostr.appendEventPreimage(&preimage, arena, pubkey_hex, article_created_at, nostr.kind_long_form, tags, article.content);
        std.crypto.hash.sha2.Sha256.hash(preimage.items, &event_id_bytes, .{});
        event_id_hex = try hexOf(arena, &event_id_bytes);
        const sig = ctx.signId(event_id_bytes, keypair, aux) catch {
            try reject(result, .ENOSTRSIGN, article.entity_id, "BIP-340 signing failed", "retry; a signing failure is a refusal, never a retry with a different event");
            return;
        };
        if (!ctx.verify(sig, event_id_bytes, keypair.public_key)) {
            try reject(result, .ENOSTRSIGN, article.entity_id, "signature verification failed before the bundle was written", "retry; the signer never emits an unverified signature");
            return;
        }
        signature_hex = try hexOf(arena, &sig);
    }

    try articles.append(arena, .{
        .entity_id = article.entity_id,
        .intention_digest = article.intention_digest,
        .disposition = disposition,
        .created_at = article_created_at,
        .published_at_unix = published_at_unix,
        .event_id = event_id_hex,
        .signature = signature_hex,
        .signature_verified = signature_verified,
        .tags = tags,
        .content = article.content,
    });
}

fn parseTags(arena: std.mem.Allocator, raw: [][]const []const u8) ![]nostr.Tag {
    const out = try arena.alloc(nostr.Tag, raw.len);
    for (raw, 0..) |pair, i| {
        if (pair.len != 2) return error.InvalidPlanTags;
        out[i] = .{ .name = pair[0], .value = pair[1] };
    }
    return out;
}

fn findPublishedAt(tags: []const nostr.Tag) ?i64 {
    for (tags) |tag| {
        if (std.mem.eql(u8, tag.name, "published_at")) {
            return std.fmt.parseInt(i64, tag.value, 10) catch return null;
        }
    }
    return null;
}

/// Lowercase hex of a fixed-size byte array, dupe'd into `arena`.
fn hexOf(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var buf: [128]u8 = undefined;
    const piece = try std.fmt.bufPrint(&buf, "{x}", .{bytes});
    return arena.dupe(u8, piece);
}

/// Record one error-severity diagnostic; message and remediation are
/// arena-owned so they outlive `run`.
fn reject(result: *Result, code: diag.Code, entity_id: []const u8, reason: []const u8, remediation: []const u8) !void {
    const arena = result.arena.allocator();
    var message: std.ArrayList(u8) = .empty;
    errdefer message.deinit(arena);
    if (entity_id.len > 0) {
        try message.appendSlice(arena, entity_id);
        try message.appendSlice(arena, ": ");
    }
    try message.appendSlice(arena, reason);
    try result.diagnostics.append(result.gpa, .{
        .severity = .error_,
        .code = code,
        .message = message.items,
        .remediation = try arena.dupe(u8, remediation),
        .source_path = entity_id,
        .line = null,
        .column = null,
        .id = entity_id,
    });
}

// The NIP-01 preimage serializer lives in `nostr.zig` (shared by signing and
// publish so both agree about the wire bytes): `nostr.appendEventPreimage`.

// =============================================================================
// Signed-event bundle serialization (json_out emitter; formats nothing)
// =============================================================================

fn renderBundle(gpa: std.mem.Allocator, plan_digest: *const [nostr.digest_hex_len]u8, pubkey_hex: []const u8, articles: []const ArticleOut) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, artifact_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"protocol\": {\n    \"nips_revision\": ");
    try json_out.writeString(&out, gpa, plan_mod.nips_revision);
    try out.appendSlice(gpa, ",\n    \"research_date\": ");
    try json_out.writeString(&out, gpa, plan_mod.nips_research_date);
    try out.appendSlice(gpa, ",\n    \"kind\": ");
    try json_out.writeUsize(&out, gpa, nostr.kind_long_form);
    try out.appendSlice(gpa, "\n  },\n  \"plan\": {\n    \"format\": ");
    try json_out.writeString(&out, gpa, plan_mod.artifact_format);
    try out.appendSlice(gpa, ",\n    \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, plan_mod.schema_version);
    try out.appendSlice(gpa, ",\n    \"digest\": ");
    try json_out.writeString(&out, gpa, plan_digest);
    try out.appendSlice(gpa, "\n  },\n  \"signer\": {\n    \"pubkey\": ");
    try json_out.writeString(&out, gpa, pubkey_hex);
    try out.appendSlice(gpa, ",\n    \"created_at_policy\": ");
    try json_out.writeString(&out, gpa, "signing-time");
    try out.appendSlice(gpa, "\n  },\n  \"articles\": [");
    for (articles, 0..) |article, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try renderArticle(&out, gpa, pubkey_hex, article);
    }
    if (articles.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "]\n}\n");
    return out.toOwnedSlice(gpa);
}

fn renderArticle(out: *std.ArrayList(u8), gpa: std.mem.Allocator, pubkey_hex: []const u8, article: ArticleOut) !void {
    try out.appendSlice(gpa, "\n    {\n      \"entity_id\": ");
    try json_out.writeString(out, gpa, article.entity_id);
    try out.appendSlice(gpa, ",\n      \"d\": ");
    try json_out.writeString(out, gpa, article.entity_id);
    try out.appendSlice(gpa, ",\n      \"intention_digest\": ");
    try json_out.writeString(out, gpa, article.intention_digest);
    try out.appendSlice(gpa, ",\n      \"disposition\": ");
    try json_out.writeString(out, gpa, article.disposition);
    try out.appendSlice(gpa, ",\n      \"created_at\": ");
    try out.appendSlice(gpa, nostr.decimal(article.created_at).slice());
    try out.appendSlice(gpa, ",\n      \"published_at_unix\": ");
    try out.appendSlice(gpa, nostr.decimal(article.published_at_unix).slice());
    try out.appendSlice(gpa, ",\n      \"event_id\": ");
    try json_out.writeString(out, gpa, article.event_id);
    try out.appendSlice(gpa, ",\n      \"signature\": ");
    try json_out.writeString(out, gpa, article.signature);
    try out.appendSlice(gpa, ",\n      \"signature_verified\": ");
    try json_out.writeBool(out, gpa, article.signature_verified);
    try out.appendSlice(gpa, ",\n      \"event\": {");
    try renderEvent(out, gpa, pubkey_hex, article);
    try out.appendSlice(gpa, "\n      }\n    }");
}

/// The signed NIP-01 event: id, pubkey, created_at, kind, tags, content, sig
/// — in that fixed order, every value already computed, signed, or parsed.
fn renderEvent(out: *std.ArrayList(u8), gpa: std.mem.Allocator, pubkey_hex: []const u8, article: ArticleOut) !void {
    try out.appendSlice(gpa, "\n        \"id\": ");
    try json_out.writeString(out, gpa, article.event_id);
    try out.appendSlice(gpa, ",\n        \"pubkey\": ");
    try json_out.writeString(out, gpa, pubkey_hex);
    try out.appendSlice(gpa, ",\n        \"created_at\": ");
    try out.appendSlice(gpa, nostr.decimal(article.created_at).slice());
    try out.appendSlice(gpa, ",\n        \"kind\": ");
    try json_out.writeUsize(out, gpa, nostr.kind_long_form);
    try out.appendSlice(gpa, ",\n        \"tags\": [");
    for (article.tags, 0..) |tag, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n          [");
        try json_out.writeString(out, gpa, tag.name);
        try out.appendSlice(gpa, ", ");
        try json_out.writeString(out, gpa, tag.value);
        try out.appendSlice(gpa, "]");
    }
    if (article.tags.len > 0) try out.appendSlice(gpa, "\n        ");
    try out.appendSlice(gpa, "],\n        \"content\": ");
    try json_out.writeString(out, gpa, article.content);
    try out.appendSlice(gpa, ",\n        \"sig\": ");
    try json_out.writeString(out, gpa, article.signature);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// BIP-340 test-vector secret (vector 1) — its public key is `test_pubkey`.
/// Fixed aux + fixed created_at make every signed bundle here reproducible.
const test_secret_key = "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef";
const test_pubkey = "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659";
const test_aux = [_]u8{0} ** 32;
const test_created_at: i64 = 1705762000;
const test_published_at: i64 = 1705761000;

/// A minimal valid plan artifact for exactly one article. `tags_json` is the
/// JSON array text for the article's tags (including the `d` tag) and
/// `content_json` is the JSON-escaped content field text; both are embedded
/// verbatim, so the test controls the exact bytes the plan carries.
fn planForOne(
    arena: std.mem.Allocator,
    entity_id: []const u8,
    tags_json: []const u8,
    content_json: []const u8,
    intention_digest: []const u8,
) ![]u8 {
    // Fixed-buffer formatting: emitter modules stay on the bounded formatter
    // (never allocPrint) even in test scaffolding; the plan is a fixture
    // input, not emitted output, so no encoder is involved.
    var buf: [4096]u8 = undefined;
    const piece = try std.fmt.bufPrint(
        &buf,
        "{{\"format\":\"boris-nostr-publication-plan\",\"schema_version\":1," ++
            "\"protocol\":{{\"nips_revision\":\"656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab\"," ++
            "\"research_date\":\"2026-08-14\",\"kind\":30023}}," ++
            "\"author\":{{\"expected_pubkey\":\"{s}\"}}," ++
            "\"articles\":[{{\"entity_id\":\"{s}\",\"kind\":30023,\"tags\":{s}," ++
            "\"content\":\"{s}\",\"intention_digest\":\"{s}\"}}]}}",
        .{ test_pubkey, entity_id, tags_json, content_json, intention_digest },
    );
    return arena.dupe(u8, piece);
}

/// The exact bundle JSON shape the emitter writes, for assertion only.
const BundleTestJson = struct {
    signer: struct { pubkey: []const u8 },
    articles: []const struct {
        entity_id: []const u8,
        disposition: []const u8,
        created_at: i64,
        published_at_unix: i64,
        event_id: []const u8,
        signature: []const u8,
        signature_verified: bool,
        event: struct {
            id: []const u8,
            pubkey: []const u8,
            created_at: i64,
            kind: u32,
            tags: [][]const []const u8,
            content: []const u8,
            sig: []const u8,
        },
    },
};

fn parseBundle(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(BundleTestJson) {
    // The bundle carries format/schema/protocol/plan envelope fields the
    // assertion struct does not declare; ignore them.
    return std.json.parseFromSlice(BundleTestJson, gpa, bytes, .{ .ignore_unknown_fields = true });
}

/// Independent NIP-01 cross-check: the event id in the bundle must equal the
/// SHA-256 of the canonical preimage built from the bundle's own fields, and
/// the signature must verify against that id with the plan's public key.
fn expectSelfConsistentEvent(gpa: std.mem.Allocator, article: anytype) !void {
    var tags: std.ArrayList(nostr.Tag) = .empty;
    defer tags.deinit(gpa);
    for (article.event.tags) |pair| {
        try tags.append(gpa, .{ .name = pair[0], .value = pair[1] });
    }
    var preimage: std.ArrayList(u8) = .empty;
    defer preimage.deinit(gpa);
    try nostr.appendEventPreimage(&preimage, gpa, article.event.pubkey, article.event.created_at, article.event.kind, tags.items, article.event.content);
    var recomputed: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(preimage.items, &recomputed, .{});
    var id_hex_buf: [64]u8 = undefined;
    const id_hex = try std.fmt.bufPrint(&id_hex_buf, "{x}", .{&recomputed});
    try testing.expectEqualStrings(article.event.id, id_hex);
    try testing.expectEqualStrings(article.event_id, id_hex);
    try testing.expectEqualStrings(article.event.sig, article.signature);

    var id_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&id_bytes, article.event.id);
    var sig_bytes: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sig_bytes, article.event.sig);
    var pubkey_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&pubkey_bytes, article.event.pubkey);
    var ctx = try keys.Context.init();
    defer ctx.deinit();
    try testing.expect(ctx.verify(sig_bytes, id_bytes, pubkey_bytes));
}

const vec_tags = "[[\"d\",\"articles/vec\"],[\"published_at\",\"1705761000\"],[\"title\",\"Vector\"],[\"r\",\"https://example.com/a.html\"]]";
/// JSON-escaped content text: newline, quotes, backslash, tab, ünïcode, and
/// the three short control escapes \b \f \r.
const vec_content_json = "Line one\\nLine \\\"two\\\" with \\\\ backslash\\ttab and \u{00fc}n\u{00ef}code. \\b\\f\\r";
const vec_intention_digest = "52d9d153d14dbd22c7530da30ea3a6ad82d82339984fa9ccd1ecb68b5b35d9ab";
/// The canonical preimage for the vector article, computed independently
/// (python3 + hashlib over the exact NIP-01 serialization).
const vec_golden_event_id = "266eeee304aa1044b6c415609446b914a39b24492e7ee5c07aab395332570068";

test "sign: golden NIP-01 event id for a control-character-laden article" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try planForOne(arena_state.allocator(), "articles/vec", vec_tags, vec_content_json, vec_intention_digest);

    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(result.ok());

    var parsed = try parseBundle(gpa, result.bundle.?);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.articles.len);
    const article = parsed.value.articles[0];
    try testing.expectEqualStrings("articles/vec", article.entity_id);
    try testing.expectEqualStrings("signed", article.disposition);
    try testing.expectEqual(test_created_at, article.created_at);
    try testing.expectEqual(test_published_at, article.published_at_unix);
    // The independently computed NIP-01 id — the escaping of the content is
    // part of the protocol, so this pins every escape rule at once.
    try testing.expectEqualStrings(vec_golden_event_id, article.event_id);
    try testing.expect(article.signature_verified);
    // Content round-trips verbatim: the bundle carries the exact plan bytes,
    // not a re-escaped view.
    try testing.expectEqualStrings(
        "Line one\nLine \"two\" with \\ backslash\ttab and \u{00fc}n\u{00ef}code. \x08\x0c\x0d",
        article.event.content,
    );
    try expectSelfConsistentEvent(gpa, article);
}

test "sign: identical inputs produce byte-identical bundles" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try planForOne(arena_state.allocator(), "articles/vec", vec_tags, vec_content_json, vec_intention_digest);

    var a = try run(testing.io, gpa, .{ .plan = plan, .key = test_secret_key, .created_at = test_created_at, .aux_rand = test_aux });
    defer a.deinit();
    var b = try run(testing.io, gpa, .{ .plan = plan, .key = test_secret_key, .created_at = test_created_at, .aux_rand = test_aux });
    defer b.deinit();
    try testing.expectEqualStrings(a.bundle.?, b.bundle.?);
}

test "sign: an unchanged intention reuses the exact prior signed event" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plan = try planForOne(arena, "articles/vec", vec_tags, vec_content_json, vec_intention_digest);

    var first = try run(testing.io, gpa, .{ .plan = plan, .key = test_secret_key, .created_at = test_created_at, .aux_rand = test_aux });
    defer first.deinit();
    var first_parsed = try parseBundle(gpa, first.bundle.?);
    defer first_parsed.deinit();
    const first_article = first_parsed.value.articles[0];

    // Re-signing at a *later* wall-clock time must not re-sign an unchanged
    // intention: the exact prior event (id, signature, created_at) is reused.
    var second = try run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_created_at + 100,
        .aux_rand = test_aux,
        .prior = first.bundle.?,
    });
    defer second.deinit();
    var second_parsed = try parseBundle(gpa, second.bundle.?);
    defer second_parsed.deinit();
    const second_article = second_parsed.value.articles[0];
    try testing.expectEqualStrings("reused", second_article.disposition);
    try testing.expectEqual(first_article.created_at, second_article.created_at);
    try testing.expectEqualStrings(first_article.event_id, second_article.event_id);
    try testing.expectEqualStrings(first_article.signature, second_article.signature);
}

test "sign: a changed intention requires strictly newer created_at (NIP-01 tie-break)" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a_tags = "[[\"d\",\"articles/a\"],[\"published_at\",\"1705761000\"]]";
    const v1 = try planForOne(arena, "articles/a", a_tags, "# v1\\n", "b2e3e61e0a57770c6afb9534b7fd429fb5d0080e482023cfc11f041188195581");
    const v2 = try planForOne(arena, "articles/a", a_tags, "# v2\\n", "185cb04b8c936b19c6348dad081130af5f5ab7dd28f8222061e59fa0f45b925b");

    var first = try run(testing.io, gpa, .{ .plan = v1, .key = test_secret_key, .created_at = test_created_at, .aux_rand = test_aux });
    defer first.deinit();
    var first_parsed = try parseBundle(gpa, first.bundle.?);
    defer first_parsed.deinit();
    const first_event_id = first_parsed.value.articles[0].event_id;

    // Same created_at as the prior event: the addressable-event tie-break
    // would be decided by id ordering, which relays do not guarantee — refuse.
    var same_time = try run(testing.io, gpa, .{
        .plan = v2,
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
        .prior = first.bundle.?,
    });
    defer same_time.deinit();
    try testing.expect(!same_time.ok());
    try testing.expect(hasCode(same_time.diagnostics.items, .ENOSTRTIME));

    // One second later: the update is accepted and produces a new event.
    var later = try run(testing.io, gpa, .{
        .plan = v2,
        .key = test_secret_key,
        .created_at = test_created_at + 1,
        .aux_rand = test_aux,
        .prior = first.bundle.?,
    });
    defer later.deinit();
    try testing.expect(later.ok());
    var later_parsed = try parseBundle(gpa, later.bundle.?);
    defer later_parsed.deinit();
    try testing.expectEqualStrings("signed", later_parsed.value.articles[0].disposition);
    try testing.expectEqual(test_created_at + 1, later_parsed.value.articles[0].created_at);
    try testing.expect(!std.mem.eql(u8, later_parsed.value.articles[0].event_id, first_event_id));
}

test "sign: created_at before published_at is refused" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try planForOne(arena_state.allocator(), "articles/vec", vec_tags, vec_content_json, vec_intention_digest);

    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_published_at - 1,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(!result.ok());
    try testing.expect(hasCode(result.diagnostics.items, .ENOSTRTIME));
}

test "sign: a signer that does not match the plan author is refused" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try planForOne(arena_state.allocator(), "articles/vec", vec_tags, vec_content_json, vec_intention_digest);

    // BIP-340 vector-0 secret — a different identity than the plan expects.
    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = "0000000000000000000000000000000000000000000000000000000000000003",
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(!result.ok());
    try testing.expect(hasCode(result.diagnostics.items, .ENOSTRSIGN));
}

test "sign: malformed and empty secret key inputs are refused" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try planForOne(arena_state.allocator(), "articles/vec", vec_tags, vec_content_json, vec_intention_digest);

    for ([_][]const u8{ "", "not-a-key", "zz" ** 32, test_secret_key[0..62] }) |bad_key| {
        var result = try run(testing.io, gpa, .{
            .plan = plan,
            .key = bad_key,
            .created_at = test_created_at,
            .aux_rand = test_aux,
        });
        defer result.deinit();
        try testing.expect(!result.ok());
        try testing.expect(hasCode(result.diagnostics.items, .ENOSTRSIGN));
    }
}

test "sign: a malformed plan artifact is refused without a bundle" {
    const gpa = testing.allocator;
    var result = try run(testing.io, gpa, .{
        .plan = "{\"format\":\"boris-nostr-publication-plan\",\"schema_version\":999}",
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(!result.ok());
    try testing.expect(hasCode(result.diagnostics.items, .ENOSTRPLAN));
}

test "sign: a prior bundle from a different identity is refused" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plan = try planForOne(arena, "articles/vec", vec_tags, vec_content_json, vec_intention_digest);
    // A well-formed prior bundle whose signer is vector-0's pubkey.
    const other_pubkey = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9";
    var prior_buf: [512]u8 = undefined;
    const prior_piece = try std.fmt.bufPrint(&prior_buf, "{{\"format\":\"boris-nostr-signed-bundle\",\"schema_version\":1,\"signer\":{{\"pubkey\":\"{s}\"}},\"articles\":[]}}", .{other_pubkey});
    const prior = try arena.dupe(u8, prior_piece);

    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
        .prior = prior,
    });
    defer result.deinit();
    try testing.expect(!result.ok());
    try testing.expect(hasCode(result.diagnostics.items, .ENOSTRPLAN));
}

test "sign: a 255-byte d tag is accepted and carried verbatim" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long_d = "x" ** 255;
    var tags_buf: [1024]u8 = undefined;
    const tags_piece = try std.fmt.bufPrint(&tags_buf, "[[\"d\",\"{s}\"],[\"published_at\",\"1705761000\"]]", .{long_d});
    const tags = try arena.dupe(u8, tags_piece);
    const plan = try planForOne(arena, long_d, tags, "long\\n", "8023a99bcd3c7e0c3dfffb9d465a474dacd971d6215477fdd645fe25d16618ac");

    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(result.ok());
    var parsed = try parseBundle(gpa, result.bundle.?);
    defer parsed.deinit();
    const article = parsed.value.articles[0];
    try testing.expectEqualStrings(long_d, article.entity_id);
    try testing.expectEqualStrings(long_d, article.event.tags[0][1]);
    try expectSelfConsistentEvent(gpa, article);
}

test "sign: a d tag that does not match the entity id is refused" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try planForOne(arena_state.allocator(), "articles/vec", "[[\"d\",\"other\"],[\"published_at\",\"1705761000\"]]", vec_content_json, vec_intention_digest);

    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(!result.ok());
    try testing.expect(hasCode(result.diagnostics.items, .ENOSTRPLAN));
}

test "sign: an intention digest mismatch is refused" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try planForOne(arena_state.allocator(), "articles/vec", vec_tags, vec_content_json, "00" ** 32);

    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(!result.ok());
    try testing.expect(hasCode(result.diagnostics.items, .ENOSTRPLAN));
}

test "sign: an out-of-range secret key is refused at the crypto boundary" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try planForOne(arena_state.allocator(), "articles/vec", vec_tags, vec_content_json, vec_intention_digest);

    // n (2^256 - 2^32 - 977) is not a valid secp256k1 secret.
    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(!result.ok());
    try testing.expect(hasCode(result.diagnostics.items, .ENOSTRSIGN));
}

fn hasCode(diagnostics: []const diag.Diagnostic, code: diag.Code) bool {
    for (diagnostics) |d| {
        if (d.code == code) return true;
    }
    return false;
}

test "sign: the golden plan fixture signs to the exact golden bundle bytes" {
    const gpa = testing.allocator;
    const plan = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/contracts/fixtures/nostr-publication/sign/plan.json", gpa, .limited(1024 * 1024));
    defer gpa.free(plan);
    const expected = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/contracts/fixtures/nostr-publication/expected/signed-bundle.json", gpa, .limited(1024 * 1024));
    defer gpa.free(expected);

    var result = try run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer result.deinit();
    try testing.expect(result.ok());
    try testing.expectEqualStrings(expected, result.bundle.?);
}
