//! Offline-to-online Nostr NIP-23 publication: `boris nostr publish`.
//!
//! Reads the plan artifact (`boris nostr plan`) and the signed-event bundle
//! (`boris nostr sign`), re-verifies that the bundle is bound to the exact
//! plan bytes and that every event id and signature still verify, then sends
//! each exact signed event to every configured relay over the bounded
//! in-repo RFC-6455 client (`ws_client.zig`, the #494 decision), recording
//! per-relay, per-event evidence and one overall classification.
//!
//! ## Classification (#454 §12, the #496 contract)
//!
//! There is deliberately **no single "published" boolean**. The truth is
//! distributed across relays, and the report says exactly what happened:
//!
//! - `complete` — every configured relay accepted every event.
//! - `partial` — at least one relay accepted at least one event, but not
//!   every relay accepted every event.
//! - `failed` — no relay accepted any event, and every relay produced a
//!   definitive negative (rejection, protocol error, `auth-required`,
//!   closed connection).
//! - `incomplete` — no relay accepted any event and at least one relay timed
//!   out: the run cannot say the publish failed, only that it ran out of
//!   time before a definitive answer.
//!
//! ## NIP-42 (the #493 decision)
//!
//! NIP-42 client authentication is out of v1. An `["AUTH", ...]` message or
//! an `OK` whose reason starts with the `auth-required:` prefix yields a
//! per-relay `auth-required` (unsupported) outcome; the remaining configured
//! relays are attempted normally. No ephemeral `kind: 22242` signing flow
//! exists in ordinary v1. Explicit schema-2 session mode adds a proactive
//! gate through the keyless child's private anonymous-pipe channel.
//!
//! ## Idempotence
//!
//! A retry resends the **identical event** — same id, same signature, same
//! bytes — which relays deduplicate by id, so resends are safe by
//! construction. There is no automatic NIP-09 deletion: removing a local
//! file mutates nothing remotely.

const std = @import("std");

fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const arr = comptime blk: {
        @setEvalBranchQuota(s.len * n * 4 + 100);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        break :blk out;
    };
    return &arr;
}

const diag = @import("diag.zig");
const json_out = @import("json_out.zig");
const keys = @import("nostr_keys.zig");
const nostr = @import("nostr.zig");
const plan_mod = @import("nostr_plan.zig");
const sign_mod = @import("nostr_sign.zig");
const ws = @import("ws_client.zig");
const auth = @import("nostr_auth.zig");
const ipc = @import("nostr_auth_ipc.zig");

const Io = std.Io;

pub const artifact_format = "boris-nostr-publish-report";
pub const schema_version: u32 = 1;

pub const Options = struct {
    /// Exact bytes of the plan artifact (`boris nostr plan` output).
    plan: []const u8,
    /// Exact bytes of the signed-event bundle (`boris nostr sign` output).
    bundle: []const u8,
    /// TLS client options for relay connections; the conformance matrix uses
    /// this to pin a local mock relay's self-signed CA.
    tls: ws.TlsOptions = .{},
    auth_channel: ?*ipc.Channel = null,
};

pub const Classification = enum {
    complete,
    partial,
    failed,
    incomplete,

    pub fn jsonName(self: Classification) []const u8 {
        return @tagName(self);
    }
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    diagnostics: std.ArrayList(diag.Diagnostic) = .empty,
    /// Canonical report bytes (json_out), present when the run reached a
    /// verdict. A verdict is always reachable: every relay attempt is
    /// bounded, and relays with no definitive result are `timeout`.
    report: ?[]u8 = null,
    classification: ?Classification = null,
    usage_refusal: bool = false,

    pub fn deinit(self: *Result) void {
        if (self.report) |bytes| self.gpa.free(bytes);
        self.diagnostics.deinit(self.gpa);
        self.arena.deinit();
    }
};

// =============================================================================
// Artifact shapes (parsed from plan / signed bundle JSON)
// =============================================================================

pub const PlanJson = struct {
    format: []const u8,
    schema_version: u32,
    protocol: struct { kind: u32 = 0, nips_revision: []const u8 = "" },
    author: struct { expected_pubkey: []const u8 = "" },
    delivery: struct {
        relays: []const []const u8 = &.{},
        timeout_ms: u32 = nostr.default_timeout_ms,
        retries: u8 = 0,
        auth: ?auth.Declaration = null,
    },
    articles: []const struct { entity_id: []const u8 = "" } = &.{},
};

pub const SignedArticle = struct {
    entity_id: []const u8,
    event_id: []const u8,
    event: struct {
        id: []const u8,
        pubkey: []const u8,
        created_at: i64,
        kind: u32,
        tags: [][]const []const u8,
        content: []const u8,
        sig: []const u8,
    },
};

const BundleJson = struct {
    format: []const u8,
    schema_version: u32,
    plan: struct {
        format: []const u8 = "",
        schema_version: u32 = 0,
        digest: []const u8 = "",
    },
    signer: struct { pubkey: []const u8 = "" },
    articles: []const SignedArticle,
};

const EventResult = enum {
    accepted,
    rejected,
    timeout,
    /// Protocol/transport failure; emitted as "error" in the report JSON.
    failed,
    not_attempted,
    /// The relay demands NIP-42 authentication, which v1 does not implement
    /// (#493); the event was not accepted and no retry was attempted.
    auth_required,
    /// The relay closed the connection before an OK arrived.
    closed,
    /// An OK named a different event id than the one just sent.
    wrong_id,

    pub fn jsonName(self: EventResult) []const u8 {
        return switch (self) {
            .failed => "error",
            .wrong_id => "wrong-id",
            .auth_required => "auth-required",
            .not_attempted => "not-attempted",
            else => @tagName(self),
        };
    }
};

const RelayStatus = enum {
    accepted,
    rejected,
    timeout,
    /// Transport/protocol failure; emitted as "error" in the report JSON.
    failed,
    auth_required,
    closed,
    wrong_id,

    pub fn jsonName(self: RelayStatus) []const u8 {
        return switch (self) {
            .failed => "error",
            .wrong_id => "wrong-id",
            .auth_required => "auth-required",
            else => @tagName(self),
        };
    }
};

const EventOutcome = struct {
    entity_id: []const u8,
    event_id: []const u8,
    result: EventResult,
    /// OK reason / NOTICE text / error name; empty when there is none.
    message: []const u8 = "",
};

const RelayOutcome = struct {
    url: []const u8,
    status: RelayStatus,
    attempts: usize,
    events: []const EventOutcome,
    auth_evidence: AuthEvidence = .{},
};

const Exchange = struct {
    generation: u8,
    event_id: ?[]const u8 = null,
    created_at: ?i64 = null,
    result: []const u8 = "signer-error",
};
const AuthEvidence = struct {
    status: []const u8 = "not-requested",
    reason: []const u8 = "not-opted-in",
    phase: []const u8 = "challenge",
    signing_requests: usize = 0,
    auth_sends: usize = 0,
    exchanges: [2]Exchange = undefined,
    count: usize = 0,
};

// =============================================================================
// Verification (fail closed before any socket opens)
// =============================================================================

fn parsePlan(arena: std.mem.Allocator, bytes: []const u8) !PlanJson {
    const parsed = try std.json.parseFromSlice(PlanJson, arena, bytes, .{ .ignore_unknown_fields = true });
    const plan = parsed.value;
    if (!std.mem.eql(u8, plan.format, plan_mod.artifact_format)) return error.InvalidPlanFormat;
    auth.validateVersion(plan.schema_version, plan.delivery.auth) catch return error.InvalidPlanSchema;
    if (plan.delivery.auth) |declaration| {
        if (!auth.hex(plan.author.expected_pubkey, 64)) return error.InvalidPlanSchema;
        try auth.checkDeclarationShape(arena, bytes);
        try auth.validateDeclaration(arena, declaration, plan.delivery.relays);
        if (!std.mem.eql(u8, plan.protocol.nips_revision, auth.revision) or plan.delivery.timeout_ms < nostr.min_timeout_ms or
            plan.delivery.timeout_ms > nostr.max_timeout_ms or plan.delivery.retries > nostr.max_retries or plan.delivery.relays.len > nostr.max_relays) return error.InvalidPlanSchema;
    }
    if (plan.protocol.kind != nostr.kind_long_form) return error.InvalidPlanKind;
    if (plan.delivery.relays.len == 0) return error.NoRelays;
    return plan;
}

fn parseBundle(arena: std.mem.Allocator, bytes: []const u8) !BundleJson {
    const parsed = try std.json.parseFromSlice(BundleJson, arena, bytes, .{ .ignore_unknown_fields = true });
    const bundle = parsed.value;
    if (!std.mem.eql(u8, bundle.format, sign_mod.artifact_format)) return error.InvalidBundleFormat;
    if (bundle.schema_version != sign_mod.schema_version and bundle.schema_version != 2) return error.InvalidBundleSchema;
    return bundle;
}

/// Re-verify the bundle against the plan and the crypto before any event is
/// sent: the bundle digest must equal the SHA-256 of the exact plan bytes,
/// the signer must be the plan's expected author, and every event id must
/// equal the SHA-256 of its canonical NIP-01 preimage with a verifying
/// BIP-340 signature. A tampered or corrupted bundle is a refusal, never a
/// partial send.
fn verifyBundle(
    gpa: std.mem.Allocator,
    result: *Result,
    plan_bytes: []const u8,
    plan: *const PlanJson,
    bundle: *const BundleJson,
) !bool {
    if (bundle.schema_version != plan.schema_version or bundle.plan.schema_version != plan.schema_version or
        !std.mem.eql(u8, bundle.plan.format, plan_mod.artifact_format))
    {
        try reject(result, .ENOSTRPLAN, "", "plan and bundle schema negotiation does not match", "re-sign the exact plan");
        return false;
    }
    var plan_digest: [nostr.digest_hex_len]u8 = undefined;
    nostr.digestHex(plan_bytes, &plan_digest);
    if (!std.mem.eql(u8, &plan_digest, bundle.plan.digest)) {
        try reject(result, .ENOSTRPLAN, "", "the signed bundle is not bound to this plan (plan digest mismatch)", "re-run boris nostr sign over the exact plan output");
        return false;
    }
    if (!std.mem.eql(u8, bundle.signer.pubkey, plan.author.expected_pubkey)) {
        try reject(result, .ENOSTRPLAN, "", "the signed bundle's signer does not match the plan's expected author", "re-sign with the key the plan's nostr.pubkey names");
        return false;
    }

    var ctx = keys.Context.init() catch {
        try reject(result, .ENOSTRSIGN, "", "could not initialize the secp256k1 context to re-verify the bundle", "retry");
        return false;
    };
    defer ctx.deinit();

    for (bundle.articles) |article| {
        if (!std.mem.eql(u8, article.event_id, article.event.id)) {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event id does not match its event object", "re-sign from the plan");
            return false;
        }
        if (!std.mem.eql(u8, article.event.pubkey, bundle.signer.pubkey)) {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event was produced by a different signer", "re-sign from the plan");
            return false;
        }
        if (article.event.kind != nostr.kind_long_form) {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event is not kind 30023", "re-sign from the plan");
            return false;
        }

        var tags: std.ArrayList(nostr.Tag) = .empty;
        defer tags.deinit(gpa);
        for (article.event.tags) |pair| {
            if (pair.len != 2) {
                try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event carries a malformed tag", "re-sign from the plan");
                return false;
            }
            try tags.append(gpa, .{ .name = pair[0], .value = pair[1] });
        }

        var preimage: std.ArrayList(u8) = .empty;
        defer preimage.deinit(gpa);
        try nostr.appendEventPreimage(&preimage, gpa, article.event.pubkey, article.event.created_at, article.event.kind, tags.items, article.event.content);
        var recomputed: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(preimage.items, &recomputed, .{});
        var id_hex_buf: [64]u8 = undefined;
        const id_hex = try std.fmt.bufPrint(&id_hex_buf, "{x}", .{&recomputed});
        if (!std.mem.eql(u8, id_hex, article.event.id)) {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event id does not match its serialized fields", "re-sign from the plan");
            return false;
        }

        var id_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id_bytes, article.event.id) catch {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event id is not valid hex", "re-sign from the plan");
            return false;
        };
        var sig_bytes: [64]u8 = undefined;
        _ = std.fmt.hexToBytes(&sig_bytes, article.event.sig) catch {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event signature is not valid hex", "re-sign from the plan");
            return false;
        };
        var pubkey_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pubkey_bytes, article.event.pubkey) catch {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event pubkey is not valid hex", "re-sign from the plan");
            return false;
        };
        if (!ctx.verify(sig_bytes, id_bytes, pubkey_bytes)) {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle event signature does not verify", "re-sign from the plan; never send an unverified event");
            return false;
        }
    }

    if (plan.articles.len != bundle.articles.len) {
        try reject(result, .ENOSTRPLAN, "", "the signed bundle article set does not match the plan", "re-sign from the exact plan output; publish sends every planned article and no extras");
        return false;
    }
    for (plan.articles) |planned| {
        var found = false;
        for (bundle.articles) |article| {
            if (std.mem.eql(u8, planned.entity_id, article.entity_id)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try reject(result, .ENOSTRPLAN, planned.entity_id, "the signed bundle is missing a planned article", "re-sign from the exact plan output");
            return false;
        }
    }
    for (bundle.articles) |article| {
        var found = false;
        for (plan.articles) |planned| {
            if (std.mem.eql(u8, planned.entity_id, article.entity_id)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try reject(result, .ENOSTRPLAN, article.entity_id, "the signed bundle carries an article that is not in the plan", "re-sign from the exact plan output");
            return false;
        }
    }
    return true;
}

// =============================================================================
// The publish loop
// =============================================================================

pub fn run(io: Io, gpa: std.mem.Allocator, options: Options) !Result {
    var result = Result{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer result.deinit();
    const arena = result.arena.allocator();

    const plan = parsePlan(arena, options.plan) catch |err| {
        try reject(&result, .ENOSTRPLAN, "", "plan artifact is invalid", planRemediation(err));
        return result;
    };
    const bundle = parseBundle(arena, options.bundle) catch |err| {
        try reject(&result, .ENOSTRPLAN, "", "signed bundle is invalid", bundleRemediation(err));
        return result;
    };

    if (!try verifyBundle(gpa, &result, options.plan, &plan, &bundle)) return result;
    if (plan.delivery.auth != null and options.auth_channel == null) {
        result.usage_refusal = true;
        try reject(&result, .ENOSTRPLAN, "", "opt-in publication requires nostr sign --auth-session", "use the explicit sign supervisor with the already-signed bundle");
        return result;
    }

    const relays = plan.delivery.relays;
    const timeout_ms = plan.delivery.timeout_ms;
    const retries = plan.delivery.retries;

    var plan_digest: [nostr.digest_hex_len]u8 = undefined;
    nostr.digestHex(options.plan, &plan_digest);
    var bundle_digest: [nostr.digest_hex_len]u8 = undefined;
    nostr.digestHex(options.bundle, &bundle_digest);

    var relay_outcomes: std.ArrayList(RelayOutcome) = .empty;
    defer relay_outcomes.deinit(arena);
    var retired: RetiredReplies = .{};
    defer retired.items.deinit(arena);
    if (plan.delivery.auth) |declaration| try retired.items.ensureTotalCapacity(arena, 2 * declaration.relays.len);

    for (relays) |relay_url| {
        relay_outcomes.append(arena, try publishToRelay(io, gpa, arena, &result, relay_url, bundle.articles, timeout_ms, retries, options.tls, options.auth_channel, if (plan.delivery.auth) |declaration| auth.contains(declaration.relays, relay_url) else false, .{ .plan_digest = &plan_digest, .bundle_digest = &bundle_digest, .nips_revision = auth.revision, .pubkey = bundle.signer.pubkey, .relays = if (plan.delivery.auth) |declaration| declaration.relays else &.{}, .timeout_ms = timeout_ms }, &retired)) catch |err| {
            // Out of memory mid-report is an I/O-class failure; the relay
            // loop itself never escapes other errors.
            return err;
        };
    }

    const classification = classify(relay_outcomes.items);
    diag.sortDiagnostics(result.diagnostics.items);
    result.classification = classification;
    result.report = try renderReport(gpa, &plan_digest, &bundle_digest, bundle.signer.pubkey, classification, relay_outcomes.items, plan.schema_version);
    return result;
}

fn classify(relays: []const RelayOutcome) Classification {
    var accepted_any = false;
    var timed_out_any = false;
    var all_accepted = true;
    for (relays) |relay| {
        if (relay.status == .timeout or std.mem.eql(u8, relay.auth_evidence.status, "timeout")) timed_out_any = true;
        var relay_accepted = true;
        for (relay.events) |event| {
            if (event.result == .accepted) accepted_any = true else relay_accepted = false;
            if (event.result == .timeout) timed_out_any = true;
        }
        if (relay.events.len == 0 or !relay_accepted) all_accepted = false;
    }
    if (relays.len > 0 and all_accepted) return .complete;
    if (accepted_any) return .partial;
    if (timed_out_any) return .incomplete;
    return .failed;
}

/// Used independently in each process before ready/begin and before sockets.
pub fn preflight(gpa: std.mem.Allocator, arena: std.mem.Allocator, plan_bytes: []const u8, bundle_bytes: []const u8) !PlanJson {
    const plan = try parsePlan(arena, plan_bytes);
    const bundle = try parseBundle(arena, bundle_bytes);
    var result: Result = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    defer result.deinit();
    if (!try verifyBundle(gpa, &result, plan_bytes, &plan, &bundle)) return error.InvalidBundle;
    return plan;
}

const AuthMessage = union(enum) {
    challenge: []const u8,
    ok: struct { id: []const u8, accepted: bool, reason: []const u8 },
    notice,
};

fn parseAuthMessage(gpa: std.mem.Allocator, arena: std.mem.Allocator, bytes: []const u8) !AuthMessage {
    try auth.checkJson(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return error.Malformed;
    const values = root.array.items;
    if (values.len < 2 or values[0] != .string) return error.Malformed;
    if (std.mem.eql(u8, values[0].string, "AUTH")) {
        if (values.len != 2 or values[1] != .string) return error.Malformed;
        try auth.challengeValid(values[1].string);
        return .{ .challenge = try arena.dupe(u8, values[1].string) };
    }
    if (std.mem.eql(u8, values[0].string, "NOTICE")) {
        if (values.len != 2 or values[1] != .string) return error.Malformed;
        return .notice;
    }
    if (std.mem.eql(u8, values[0].string, "OK")) {
        if (values.len != 4 or values[1] != .string or values[2] != .bool or values[3] != .string or !auth.hex(values[1].string, 64)) return error.Malformed;
        return .{ .ok = .{ .id = try arena.dupe(u8, values[1].string), .accepted = values[2].bool, .reason = rejectPrefix(values[3].string) } };
    }
    return error.Malformed;
}

fn readAuth(arena: std.mem.Allocator, client: *ws.Client) !AuthMessage {
    const message = client.readMessage() catch |err| switch (err) {
        error.EndOfStream => return error.Closed,
        error.ReadTimeout => return error.Timeout,
        error.OversizedMessage => return error.Oversized,
        else => return err,
    };
    return switch (message) {
        .close => error.Closed,
        .text => |bytes| parseAuthMessage(client.gpa, arena, bytes),
    };
}

fn rejectPrefix(reason: []const u8) []const u8 {
    if (startsWithIgnoreCase(reason, "auth-required:") or std.mem.eql(u8, reason, "auth-required")) return "auth-required";
    if (startsWithIgnoreCase(reason, "restricted:") or std.mem.eql(u8, reason, "restricted")) return "restricted";
    return "relay-rejected";
}

fn authFailure(evidence: *AuthEvidence, err: anyerror) void {
    evidence.status = switch (err) {
        error.Timeout, error.ReadTimeout, error.WriteTimeout => "timeout",
        error.Closed, error.EndOfStream => "closed",
        error.SignerRefused => "signer-error",
        else => "protocol-error",
    };
    evidence.reason = switch (err) {
        error.Timeout, error.ReadTimeout => if (std.mem.eql(u8, evidence.phase, "challenge")) "challenge-timeout" else if (std.mem.eql(u8, evidence.phase, "signer")) "signer-timeout" else "auth-ok-timeout",
        error.WriteTimeout => "auth-write-timeout",
        error.Closed, error.EndOfStream => "relay-closed",
        error.Oversized, error.OversizedMessage => "oversized",
        error.Replay => "replay",
        error.Stale => "stale",
        error.IdentityMismatch => "identity-mismatch",
        error.RelayMismatch => "relay-mismatch",
        error.EventIdMismatch => "event-id-mismatch",
        error.SignatureInvalid => "signature-invalid",
        error.UnexpectedOk => "unexpected-ok",
        error.ReplacementLimit => "replacement-limit",
        error.SignerRefused => "signer-refused",
        else => "malformed",
    };
    if (evidence.count > 0) evidence.exchanges[evidence.count - 1].result = evidence.status;
}

fn authRelayStatus(evidence: AuthEvidence) RelayStatus {
    if (std.mem.eql(u8, evidence.status, "timeout")) return .timeout;
    if (std.mem.eql(u8, evidence.status, "closed")) return .closed;
    if (std.mem.eql(u8, evidence.status, "rejected"))
        return if (std.mem.eql(u8, evidence.reason, "auth-required")) .auth_required else .rejected;
    return .failed;
}

const RetiredReplies = struct {
    items: std.ArrayList(auth.Correlation) = .empty,

    fn remember(self: *RetiredReplies, correlation: auth.Correlation) void {
        // Capacity is the unchanged two-request budget for each opted-in relay.
        self.items.appendAssumeCapacity(correlation);
    }

    fn consume(self: *RetiredReplies, correlation: auth.Correlation) bool {
        for (self.items.items, 0..) |old, i| {
            if (auth.equalCorrelation(old, correlation)) {
                _ = self.items.swapRemove(i);
                return true;
            }
        }
        return false;
    }
};

const Gate = struct {
    deadline: ?auth.Deadline = null,
    pending_challenge: ?[]const u8 = null,
    seen: [2][32]u8 = undefined,
    retired_id: ?[]const u8 = null,
    outstanding: ?auth.Correlation = null,
    retired: *RetiredReplies,
};

fn drainRetiredReply(gpa: std.mem.Allocator, channel: *ipc.Channel, retired: *RetiredReplies, deadline: auth.Deadline) !void {
    // The auth channel only exists where ipc.Channel.init can succeed; the
    // POSIX poll surface below must not analyze on other targets.
    if (comptime !ipc.supported) return error.UnsupportedPlatform;
    while (true) {
        var fds = [_]std.c.pollfd{.{ .fd = channel.input, .events = std.posix.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 0) < 0 or fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.ChannelLost;
        if (fds[0].revents & std.posix.POLL.IN == 0) return;
        const bytes = try channel.read(gpa, deadline);
        defer gpa.free(bytes);
        var response = try auth.parse(auth.Response, gpa, bytes, "response");
        defer response.deinit();
        if (retired.consume(response.value.correlation)) continue;
        return error.SessionInvalid;
    }
}

fn authenticate(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *ws.Client, channel: *ipc.Channel, policy: auth.Policy, correlation: *auth.Correlation, evidence: *AuthEvidence, gate_state: *Gate) !bool {
    if (comptime !ipc.supported) return error.UnsupportedPlatform;
    const message_limit = client.limits.max_message_bytes;
    const frame_limit = client.limits.max_frame_payload;
    defer {
        client.limits.max_message_bytes = message_limit;
        client.limits.max_frame_payload = frame_limit;
        // A relay-local failure cannot make its in-flight reply foreign to
        // the next relay. Only the exact retired correlation is discarded.
        if (gate_state.outstanding) |old| {
            gate_state.retired.remember(old);
            gate_state.outstanding = null;
        }
    }
    client.limits.max_message_bytes = auth.max_frame;
    client.limits.max_frame_payload = auth.max_frame;
    const first_deadline = auth.Deadline.after(io, policy.timeout_ms).clip(channel.ceiling.?);
    client.limits.deadline_ns = first_deadline.end;
    var challenge: []const u8 = gate_state.pending_challenge orelse "";
    while (challenge.len == 0) {
        _ = try first_deadline.remaining(io);
        switch (try readAuth(arena, client)) {
            .notice => continue,
            .ok => return error.UnexpectedOk,
            .challenge => |c| {
                challenge = c;
                break;
            },
        }
    }
    const deadline = gate_state.deadline orelse auth.Deadline.after(io, @min(3 * policy.timeout_ms, 60000)).clip(channel.ceiling.?);
    gate_state.deadline = deadline;
    gate_state.pending_challenge = null;
    client.limits.deadline_ns = deadline.end;
    var retired_id: ?[]const u8 = gate_state.retired_id;
    var active_id: ?[]const u8 = null;
    var auth_sent = false;
    var waiting_response = false;
    var response_deadline = deadline;
    var gate = false;
    var send_request = true;
    var ready_wire: ?[]u8 = null;
    defer if (ready_wire) |wire| gpa.free(wire);

    while (true) {
        _ = try deadline.remaining(io);
        if (send_request) {
            std.crypto.hash.sha2.Sha256.hash(challenge, &gate_state.seen[correlation.generation - 1], .{});
            channel.request += 1;
            correlation.request = channel.request;
            evidence.phase = "signer";
            evidence.signing_requests += 1;
            evidence.exchanges[evidence.count] = .{ .generation = correlation.generation };
            evidence.count += 1;
            try channel.send(gpa, auth.Request{ .correlation = correlation.*, .challenge = challenge }, auth.Deadline.after(io, policy.timeout_ms).clip(deadline));
            gate_state.outstanding = correlation.*;
            response_deadline = auth.Deadline.after(io, policy.timeout_ms).clip(deadline);
            waiting_response = true;
            send_request = false;
        }

        // Drain queued controls before considering a signer response or write.
        if (client.hasPending() or (!waiting_response and !gate)) {
            switch (try readAuth(arena, client)) {
                .notice => continue,
                .challenge => |replacement| {
                    var hash: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(replacement, &hash, .{});
                    for (gate_state.seen[0..correlation.generation]) |old| if (std.mem.eql(u8, &old, &hash)) return error.Replay;
                    if (correlation.generation == 2) return error.ReplacementLimit;
                    evidence.exchanges[evidence.count - 1].result = "superseded";
                    if (gate_state.outstanding) |old| {
                        gate_state.retired.remember(old);
                        gate_state.outstanding = null;
                    }
                    try channel.control(gpa, correlation.*, "cancel", policy.timeout_ms);
                    retired_id = active_id;
                    gate_state.retired_id = active_id;
                    if (ready_wire) |wire| gpa.free(wire);
                    ready_wire = null;
                    active_id = null;
                    auth_sent = false;
                    correlation.generation = 2;
                    challenge = replacement;
                    gate = false;
                    send_request = true;
                    continue;
                },
                .ok => |ok| {
                    if (retired_id) |old| if (std.mem.eql(u8, old, ok.id)) continue;
                    if (!auth_sent or active_id == null or !std.mem.eql(u8, active_id.?, ok.id)) return error.UnexpectedOk;
                    evidence.exchanges[evidence.count - 1].result = if (ok.accepted) "authenticated" else "rejected";
                    evidence.status = if (ok.accepted) "authenticated" else "rejected";
                    evidence.reason = if (ok.accepted) "" else rejectPrefix(ok.reason);
                    if (!ok.accepted) return false;
                    gate = true;
                    continue;
                },
            }
        }
        if (gate) {
            try drainRetiredReply(gpa, channel, gate_state.retired, deadline);
            return true;
        }
        if (ready_wire) |wire| {
            try drainRetiredReply(gpa, channel, gate_state.retired, deadline);
            _ = try deadline.remaining(io);
            evidence.phase = "auth-write";
            try client.sendText(wire);
            auth_sent = true;
            evidence.auth_sends += 1;
            evidence.phase = "auth-ok";
            gpa.free(wire);
            ready_wire = null;
            waiting_response = false;
            continue;
        }
        if (waiting_response) {
            _ = try response_deadline.remaining(io);
            var fds = [_]std.c.pollfd{.{ .fd = channel.input, .events = std.posix.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 0) < 0 or fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.ChannelLost;
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                const bytes = try channel.read(gpa, response_deadline);
                defer gpa.free(bytes);
                var response = try auth.parse(auth.Response, gpa, bytes, "response");
                defer response.deinit();
                if (gate_state.retired.consume(response.value.correlation)) continue;
                if (!auth.equalCorrelation(correlation.*, response.value.correlation)) return error.SessionInvalid;
                gate_state.outstanding = null;
                if (response.value.refusal != null) {
                    if (response.value.event != null or !std.mem.eql(u8, response.value.refusal.?, "signer-refused")) return error.SessionInvalid;
                    return error.SignerRefused;
                }
                const event = response.value.event orelse return error.SessionInvalid;
                try auth.verify(gpa, event, policy.pubkey, correlation.relay, challenge, Io.Timestamp.now(io, .real).toSeconds());
                _ = try deadline.remaining(io);
                // A replacement received while IPC was being assembled closes
                // the gate before AUTH. Keep the response only if still active.
                const wire = try std.json.Stringify.valueAlloc(gpa, .{ "AUTH", event }, .{});
                if (wire.len > auth.max_frame) {
                    gpa.free(wire);
                    return error.Oversized;
                }
                ready_wire = wire;
                active_id = try arena.dupe(u8, event.id);
                evidence.exchanges[evidence.count - 1].event_id = active_id;
                evidence.exchanges[evidence.count - 1].created_at = event.created_at;
                continue;
            }
            try (Io.Timeout{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(2) } }).sleep(io);
        }
    }
}

fn beforeArticle(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *ws.Client, channel: *ipc.Channel, policy: auth.Policy, correlation: *auth.Correlation, evidence: *AuthEvidence, gate: *Gate, attempts: usize) !bool {
    if (comptime !ipc.supported) return error.UnsupportedPlatform;
    try drainRetiredReply(gpa, channel, gate.retired, auth.Deadline.after(io, policy.timeout_ms).clip(channel.ceiling.?));
    while (client.hasPending()) {
        switch (try readAuth(arena, client)) {
            .notice => continue,
            .ok => |ok| {
                if (gate.retired_id) |id| if (std.mem.eql(u8, id, ok.id)) continue;
                return error.UnexpectedOk;
            },
            .challenge => |challenge| {
                if (attempts > 0) return error.ReplacementAfterEvent;
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(challenge, &hash, .{});
                for (gate.seen[0..correlation.generation]) |old| if (std.mem.eql(u8, &old, &hash)) return error.Replay;
                if (correlation.generation == 2) return error.ReplacementLimit;
                evidence.exchanges[evidence.count - 1].result = "superseded";
                gate.retired_id = evidence.exchanges[evidence.count - 1].event_id;
                try channel.control(gpa, correlation.*, "cancel", policy.timeout_ms);
                correlation.generation = 2;
                gate.pending_challenge = challenge;
                if (!try authenticate(io, gpa, arena, client, channel, policy, correlation, evidence, gate)) return false;
                client.limits.deadline_ns = channel.ceiling.?.end;
            },
        }
    }
    return true;
}

fn renderAuthEvidence(out: *std.ArrayList(u8), gpa: std.mem.Allocator, evidence: AuthEvidence, pubkey: []const u8) !void {
    try out.appendSlice(gpa, ",\n      \"auth\": {\"expected_pubkey\":");
    try json_out.writeString(out, gpa, pubkey);
    inline for (.{ "status", "reason", "phase" }) |field| {
        try out.appendSlice(gpa, ",\"" ++ field ++ "\":");
        try json_out.writeString(out, gpa, @field(evidence, field));
    }
    try out.appendSlice(gpa, ",\"signing_requests\":");
    try json_out.writeUsize(out, gpa, evidence.signing_requests);
    try out.appendSlice(gpa, ",\"auth_sends\":");
    try json_out.writeUsize(out, gpa, evidence.auth_sends);
    try out.appendSlice(gpa, ",\"exchanges\":[");
    for (evidence.exchanges[0..evidence.count], 0..) |exchange, i| {
        if (i != 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "{\"generation\":");
        try json_out.writeUsize(out, gpa, exchange.generation);
        try out.appendSlice(gpa, ",\"event_id\":");
        if (exchange.event_id) |id| try json_out.writeString(out, gpa, id) else try out.appendSlice(gpa, "null");
        try out.appendSlice(gpa, ",\"created_at\":");
        if (exchange.created_at) |time| try out.appendSlice(gpa, nostr.decimal(time).slice()) else try out.appendSlice(gpa, "null");
        try out.appendSlice(gpa, ",\"result\":");
        try json_out.writeString(out, gpa, exchange.result);
        try out.appendSlice(gpa, "}");
    }
    try out.appendSlice(gpa, "]}");
}

/// One full interaction with one relay: connect, handshake, then each event
/// in bundle order with `retries` resends of the identical event on timeout.
fn publishToRelay(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    result: *Result,
    relay_url: []const u8,
    articles: []const SignedArticle,
    timeout_ms: u32,
    retries: u8,
    tls: ws.TlsOptions,
    channel: ?*ipc.Channel,
    opted_in: bool,
    policy: auth.Policy,
    retired: *RetiredReplies,
) !RelayOutcome {
    // The array list and its items live in the run arena (freed with the
    // result); the items slice escapes into the RelayOutcome, so it must not
    // be deinit'd here.
    var events: std.ArrayList(EventOutcome) = .empty;
    try events.ensureTotalCapacity(arena, articles.len);

    var attempts: usize = 0;
    var status: RelayStatus = .accepted;
    var abort_relay = false;
    var evidence: AuthEvidence = .{};
    if (channel) |c| if (c.ceiling.?.remaining(io)) |_| {} else |_| {
        for (articles) |a| try events.append(arena, .{ .entity_id = a.entity_id, .event_id = a.event_id, .result = .not_attempted });
        if (opted_in) evidence.status = "timeout";
        evidence.reason = "session-timeout";
        evidence.phase = "session";
        return .{ .url = relay_url, .status = .timeout, .attempts = 0, .events = events.items, .auth_evidence = evidence };
    };

    var client = ws.Client.connect(io, gpa, relay_url, .{
        .handshake_timeout_ms = timeout_ms,
        .read_timeout_ms = timeout_ms,
        .tls = tls,
        .deadline_ns = if (channel) |c| c.ceiling.?.end else null,
    }) catch |err| {
        if (opted_in) {
            evidence.status = if (err == error.HandshakeTimeout) "timeout" else "protocol-error";
            evidence.reason = if (err == error.HandshakeTimeout) "challenge-timeout" else "malformed";
            evidence.phase = "connect";
            for (articles) |a| try events.append(arena, .{ .entity_id = a.entity_id, .event_id = a.event_id, .result = .not_attempted });
            try emitRelayDiagnostic(result, relay_url, evidence.reason, null);
            return .{ .url = relay_url, .status = if (err == error.HandshakeTimeout) .timeout else .failed, .attempts = 0, .events = events.items, .auth_evidence = evidence };
        }
        status = .failed;
        attempts = 1;
        try events.append(arena, .{ .entity_id = "", .event_id = "", .result = .failed, .message = @errorName(err) });
        try emitRelayDiagnostic(result, relay_url, "connect or handshake failed", err);
        return .{ .url = relay_url, .status = status, .attempts = attempts, .events = events.items };
    };
    defer client.deinit();

    var correlation: ?auth.Correlation = null;
    var gate: Gate = .{ .retired = retired };
    if (opted_in) {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const connection_hex = std.fmt.bytesToHex(nonce, .lower);
        const connection = try arena.dupe(u8, &connection_hex);
        correlation = .{ .plan_digest = policy.plan_digest, .bundle_digest = policy.bundle_digest, .nips_revision = auth.revision, .run = &channel.?.run, .connection = connection, .request = 0, .relay = relay_url, .generation = 1 };
        const outcome = authenticate(io, gpa, arena, &client, channel.?, policy, &correlation.?, &evidence, &gate) catch |err| {
            if (err == error.ChannelLost or err == error.SessionInvalid or err == error.Canceled) return err;
            authFailure(&evidence, err);
            try emitRelayDiagnostic(result, relay_url, evidence.reason, null);
            const gate_status = authRelayStatus(evidence);
            for (articles) |a| try events.append(arena, .{ .entity_id = a.entity_id, .event_id = a.event_id, .result = .not_attempted });
            if (correlation.?.request != 0) try channel.?.control(gpa, correlation.?, "retire", timeout_ms);
            return .{ .url = relay_url, .status = gate_status, .attempts = 0, .events = events.items, .auth_evidence = evidence };
        };
        if (!outcome) {
            const gate_status = authRelayStatus(evidence);
            for (articles) |a| try events.append(arena, .{ .entity_id = a.entity_id, .event_id = a.event_id, .result = .not_attempted });
            try emitRelayDiagnostic(result, relay_url, evidence.reason, null);
            try channel.?.control(gpa, correlation.?, "retire", timeout_ms);
            return .{ .url = relay_url, .status = gate_status, .attempts = 0, .events = events.items, .auth_evidence = evidence };
        }
        client.limits.max_message_bytes = 1024 * 1024;
        client.limits.max_frame_payload = 1024 * 1024;
        client.limits.deadline_ns = channel.?.ceiling.?.end;
    }

    for (articles) |article| {
        if (abort_relay) {
            try events.append(arena, .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .not_attempted, .message = "" });
            continue;
        }
        if (channel) |c| {
            if (c.ceiling.?.remaining(io)) |_| {} else |_| {
                evidence.status = "timeout";
                evidence.reason = "session-timeout";
                status = .timeout;
                abort_relay = true;
                try events.append(arena, .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .not_attempted });
                continue;
            }
        }
        if (opted_in) {
            const open = beforeArticle(io, gpa, arena, &client, channel.?, policy, &correlation.?, &evidence, &gate, attempts) catch |err| blk: {
                if (err == error.ChannelLost or err == error.SessionInvalid or err == error.Canceled) return err;
                authFailure(&evidence, err);
                if (err == error.ReplacementAfterEvent) evidence.reason = "replacement-after-event";
                break :blk false;
            };
            if (!open) {
                abort_relay = true;
                status = authRelayStatus(evidence);
                try emitRelayDiagnostic(result, relay_url, evidence.reason, null);
                try events.append(arena, .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .not_attempted });
                continue;
            }
        }
        var outcome = try sendEvent(gpa, arena, &client, relay_url, article, retries, result, &attempts, if (opted_in) &evidence else null);
        if (channel) |c| {
            if (c.ceiling.?.remaining(io)) |_| {} else |_| {
                if (opted_in) evidence.status = "timeout";
                evidence.reason = "session-timeout";
                evidence.phase = "session";
                if (outcome.result != .accepted and outcome.result != .not_attempted) outcome.result = .timeout;
                status = .timeout;
                abort_relay = true;
            }
        }
        switch (outcome.result) {
            .accepted => {},
            .rejected, .timeout, .failed, .auth_required, .closed, .wrong_id => {
                if (status == .accepted) status = switch (outcome.result) {
                    .rejected => .rejected,
                    .timeout => .timeout,
                    .failed => .failed,
                    .auth_required => .auth_required,
                    .closed => .closed,
                    .wrong_id => .wrong_id,
                    else => unreachable,
                };
            },
            .not_attempted => {},
        }
        // A relay that rejects with auth-required, names the wrong id, or
        // closes mid-send is not worth more events: the outcome is
        // definitive for this run. A per-event `rejected` still tries later
        // events on the same connection.
        if (outcome.result == .failed or outcome.result == .auth_required or outcome.result == .closed or outcome.result == .wrong_id or
            (opted_in and !std.mem.eql(u8, evidence.status, "authenticated"))) abort_relay = true;
        try events.append(arena, outcome);
    }
    if (correlation) |c| try channel.?.control(gpa, c, "retire", timeout_ms);
    return .{ .url = relay_url, .status = status, .attempts = attempts, .events = events.items, .auth_evidence = evidence };
}

fn sendEvent(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    client: *ws.Client,
    relay_url: []const u8,
    article: SignedArticle,
    retries: u8,
    result: *Result,
    attempts: *usize,
    auth_evidence: ?*AuthEvidence,
) !EventOutcome {
    const max_attempts: usize = @as(usize, retries) + 1;
    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (client.limits.deadline_ns) |end| {
            if (Io.Timestamp.now(client.io, .awake).nanoseconds >= end)
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = if (attempt == 0) .not_attempted else .timeout };
        }
        attempts.* += 1;
        const wire = try renderEventMessage(gpa, article);
        defer gpa.free(wire);
        client.sendText(wire) catch |err| {
            try emitRelayDiagnostic(result, relay_url, "could not send the event", err);
            return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .failed, .message = @errorName(err) };
        };
        const read = readUntilOk(gpa, arena, client, article.event.id, auth_evidence != null) catch |err| switch (err) {
            error.ReplacementAfterEvent => {
                auth_evidence.?.status = "protocol-error";
                auth_evidence.?.reason = "replacement-after-event";
                try emitRelayDiagnostic(result, relay_url, "replacement-after-event", null);
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .timeout };
            },
            error.AuthRequired => {
                if (auth_evidence) |e| {
                    e.status = "rejected";
                    e.reason = "auth-required";
                }
                try emitRelayDiagnostic(result, relay_url, "relay requires NIP-42 authentication, which v1 does not implement", null);
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .auth_required, .message = "auth-required" };
            },
            error.Closed => {
                try emitRelayDiagnostic(result, relay_url, "relay closed the connection before an OK", null);
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .closed, .message = "closed" };
            },
            error.Timeout => {
                if (attempt + 1 < max_attempts) continue;
                try emitRelayDiagnostic(result, relay_url, "no OK within the deadline", null);
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .timeout, .message = "" };
            },
            error.WrongId => {
                try emitRelayDiagnostic(result, relay_url, "relay OK named a different event id", null);
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .wrong_id, .message = "wrong-id" };
            },
            else => {
                try emitRelayDiagnostic(result, relay_url, "relay protocol error", err);
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .failed, .message = @errorName(err) };
            },
        };
        switch (read) {
            .ok => return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .accepted, .message = "" },
            .rejected => |reason| {
                try emitRelayDiagnostic(result, relay_url, "relay rejected the event", null);
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .rejected, .message = if (auth_evidence != null) rejectPrefix(reason) else reason };
            },
        }
    }
    unreachable;
}

const OkRead = union(enum) {
    ok,
    /// Arena-owned rejection reason from `["OK", id, false, reason]`.
    rejected: []const u8,
};

/// Read messages until the relay answers with `OK` for `wanted_id`, or the
/// read deadline fires. `NOTICE` is recorded and the wait continues (NOTICE
/// is never success). `AUTH` or an `auth-required:` OK yields
/// `error.AuthRequired`. An OK for another id is `error.WrongId`. A
/// malformed message fails closed.
fn readUntilOk(gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *ws.Client, wanted_id: []const u8, opted_in: bool) !OkRead {
    while (true) {
        // A relay that drops the connection without an OK is the same
        // definitive outcome as a Close frame: the event was not accepted.
        const message = client.readMessage() catch |err| {
            if (err == error.EndOfStream) return error.Closed;
            // A read deadline is the same retry-eligible outcome as a timeout.
            if (err == error.ReadTimeout) return error.Timeout;
            return err;
        };
        switch (message) {
            .close => return error.Closed,
            .text => |bytes| {
                const outcome = classifyMessage(gpa, arena, bytes, wanted_id) catch return error.Malformed;
                switch (outcome) {
                    .ok => return .ok,
                    .notice => continue,
                    .auth => return if (opted_in) error.ReplacementAfterEvent else error.AuthRequired,
                    .wrong_id => return error.WrongId,
                    .rejected => |reason| {
                        // The reason is arena-owned, so it outlives the parse.
                        if (startsWithIgnoreCase(reason, "auth-required:")) return error.AuthRequired;
                        return .{ .rejected = reason };
                    },
                }
            },
        }
    }
}

const MessageOutcome = union(enum) {
    ok,
    notice,
    auth,
    wrong_id,
    /// Arena-owned rejection reason from the relay's `OK` message.
    rejected: []const u8,
};

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn classifyMessage(gpa: std.mem.Allocator, arena: std.mem.Allocator, bytes: []const u8, wanted_id: []const u8) !MessageOutcome {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Malformed;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.Malformed;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .array) return error.Malformed;
    const array = root.array.items;
    if (array.len < 2) return error.Malformed;
    if (array[0] != .string) return error.Malformed;

    if (std.mem.eql(u8, array[0].string, "OK")) {
        if (array.len < 4) return error.Malformed;
        if (array[1] != .string or array[2] != .bool or array[3] != .string) return error.Malformed;
        if (!std.mem.eql(u8, array[1].string, wanted_id)) return .wrong_id;
        if (array[2].bool) return .ok;
        // The reason is dupe'd into the run arena: `parsed` dies here.
        return .{ .rejected = try arena.dupe(u8, array[3].string) };
    }
    if (std.mem.eql(u8, array[0].string, "NOTICE")) {
        if (array.len < 2 or array[1] != .string) return error.Malformed;
        return .notice;
    }
    if (std.mem.eql(u8, array[0].string, "AUTH")) {
        return .auth;
    }
    return error.Malformed;
}

fn emitRelayDiagnostic(result: *Result, relay_url: []const u8, reason: []const u8, err: ?anyerror) !void {
    const arena = result.arena.allocator();
    var message: std.ArrayList(u8) = .empty;
    errdefer message.deinit(arena);
    try message.appendSlice(arena, relay_url);
    try message.appendSlice(arena, ": ");
    try message.appendSlice(arena, reason);
    if (err) |e| {
        try message.appendSlice(arena, " (");
        try message.appendSlice(arena, @errorName(e));
        try message.appendSlice(arena, ")");
    }
    try result.diagnostics.append(result.gpa, .{
        .severity = .error_,
        .code = .ENOSTRRELAY,
        .message = message.items,
        .remediation = "check the relay's policy and connectivity, then re-run",
        .source_path = relay_url,
        .line = null,
        .column = null,
        .id = relay_url,
    });
}

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

fn planRemediation(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidPlanFormat => "re-run boris nostr plan; the artifact format is not a publication plan",
        error.InvalidPlanSchema => "re-run boris nostr plan; the artifact schema version is not supported",
        error.InvalidPlanKind => "re-run boris nostr plan; the protocol kind is not 30023",
        error.NoRelays => "the plan declares no relays; add relays to the profile's nostr section",
        else => "re-run boris nostr plan and publish its exact output",
    };
}

fn bundleRemediation(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidBundleFormat => "supply the exact bundle boris nostr sign produced",
        error.InvalidBundleSchema => "supply a signed bundle with a supported schema version",
        else => "supply the exact bundle boris nostr sign produced",
    };
}

// =============================================================================
// Wire messages and report (json_out emitter; formats nothing)
// =============================================================================

/// `["EVENT", {event}]` — the exact signed event object, every field already
/// verified, in NIP-01 field order.
pub fn renderEventMessage(gpa: std.mem.Allocator, article: SignedArticle) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "[\"EVENT\",{\"id\":");
    try json_out.writeString(&out, gpa, article.event.id);
    try out.appendSlice(gpa, ",\"pubkey\":");
    try json_out.writeString(&out, gpa, article.event.pubkey);
    try out.appendSlice(gpa, ",\"created_at\":");
    try out.appendSlice(gpa, nostr.decimal(article.event.created_at).slice());
    try out.appendSlice(gpa, ",\"kind\":");
    try json_out.writeUsize(&out, gpa, article.event.kind);
    try out.appendSlice(gpa, ",\"tags\":[");
    for (article.event.tags, 0..) |tag, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "[");
        for (tag, 0..) |value, j| {
            if (j > 0) try out.appendSlice(gpa, ",");
            try json_out.writeString(&out, gpa, value);
        }
        try out.appendSlice(gpa, "]");
    }
    try out.appendSlice(gpa, "],\"content\":");
    try json_out.writeString(&out, gpa, article.event.content);
    try out.appendSlice(gpa, ",\"sig\":");
    try json_out.writeString(&out, gpa, article.event.sig);
    try out.appendSlice(gpa, "}]");
    return out.toOwnedSlice(gpa);
}

fn renderReport(
    gpa: std.mem.Allocator,
    plan_digest: *const [nostr.digest_hex_len]u8,
    bundle_digest: *const [nostr.digest_hex_len]u8,
    pubkey: []const u8,
    classification: Classification,
    relays: []const RelayOutcome,
    artifact_version: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, artifact_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, artifact_version);
    try out.appendSlice(gpa, ",\n  \"plan\": {\n    \"format\": ");
    try json_out.writeString(&out, gpa, plan_mod.artifact_format);
    try out.appendSlice(gpa, ",\n    \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, artifact_version);
    try out.appendSlice(gpa, ",\n    \"digest\": ");
    try json_out.writeString(&out, gpa, plan_digest);
    try out.appendSlice(gpa, "\n  },\n  \"bundle\": {\n    \"format\": ");
    try json_out.writeString(&out, gpa, sign_mod.artifact_format);
    try out.appendSlice(gpa, ",\n    \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, artifact_version);
    try out.appendSlice(gpa, ",\n    \"digest\": ");
    try json_out.writeString(&out, gpa, bundle_digest);
    try out.appendSlice(gpa, "\n  },\n  \"signer\": {\n    \"pubkey\": ");
    try json_out.writeString(&out, gpa, pubkey);
    try out.appendSlice(gpa, "\n  },\n  \"classification\": ");
    try json_out.writeString(&out, gpa, classification.jsonName());
    try out.appendSlice(gpa, ",\n  \"relays\": [");
    for (relays, 0..) |relay, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n    {\n      \"url\": ");
        try json_out.writeString(&out, gpa, relay.url);
        try out.appendSlice(gpa, ",\n      \"outcome\": ");
        try json_out.writeString(&out, gpa, relay.status.jsonName());
        try out.appendSlice(gpa, ",\n      \"attempts\": ");
        try json_out.writeUsize(&out, gpa, relay.attempts);
        if (artifact_version == 2) try renderAuthEvidence(&out, gpa, relay.auth_evidence, pubkey);
        try out.appendSlice(gpa, ",\n      \"events\": [");
        for (relay.events, 0..) |event, j| {
            if (j > 0) try out.appendSlice(gpa, ",");
            try out.appendSlice(gpa, "\n        {\n          \"entity_id\": ");
            try json_out.writeString(&out, gpa, event.entity_id);
            try out.appendSlice(gpa, ",\n          \"event_id\": ");
            try json_out.writeString(&out, gpa, event.event_id);
            try out.appendSlice(gpa, ",\n          \"result\": ");
            try json_out.writeString(&out, gpa, event.result.jsonName());
            try out.appendSlice(gpa, ",\n          \"message\": ");
            try json_out.writeString(&out, gpa, event.message);
            try out.appendSlice(gpa, "\n        }");
        }
        if (relay.events.len > 0) try out.appendSlice(gpa, "\n      ");
        try out.appendSlice(gpa, "]\n    }");
    }
    if (relays.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "]\n}\n");
    return out.toOwnedSlice(gpa);
}

// =============================================================================
// Tests (pure logic; the socket matrix lives in nostr_publish_test.zig)
// =============================================================================

const testing = std.testing;

test "auth verification refuses a short expected pubkey before hex decoding" {
    const event: auth.Event = .{ .id = rep("0", 64), .pubkey = "00", .created_at = 0, .kind = 22242, .tags = &.{}, .content = "", .sig = rep("0", 128) };
    try testing.expectError(error.IdentityMismatch, auth.verify(testing.allocator, event, "00", "wss://r.example", "challenge", 0));
}

test "classify: complete, partial, failed, and incomplete are distinct" {
    const E = EventResult;
    const S = RelayStatus;

    const all_ok = [_]RelayOutcome{
        .{ .url = "a", .status = S.accepted, .attempts = 1, .events = &.{.{ .entity_id = "x", .event_id = "1", .result = E.accepted, .message = "" }} },
        .{ .url = "b", .status = S.accepted, .attempts = 1, .events = &.{.{ .entity_id = "x", .event_id = "1", .result = E.accepted, .message = "" }} },
    };
    try testing.expectEqual(Classification.complete, classify(&all_ok));

    const one_rejected = [_]RelayOutcome{
        .{ .url = "a", .status = S.accepted, .attempts = 1, .events = &.{.{ .entity_id = "x", .event_id = "1", .result = E.accepted, .message = "" }} },
        .{ .url = "b", .status = S.rejected, .attempts = 1, .events = &.{.{ .entity_id = "x", .event_id = "1", .result = E.rejected, .message = "blocked" }} },
    };
    try testing.expectEqual(Classification.partial, classify(&one_rejected));

    const all_rejected = [_]RelayOutcome{
        .{ .url = "a", .status = S.rejected, .attempts = 1, .events = &.{.{ .entity_id = "x", .event_id = "1", .result = E.rejected, .message = "blocked" }} },
    };
    try testing.expectEqual(Classification.failed, classify(&all_rejected));

    const timed_out = [_]RelayOutcome{
        .{ .url = "a", .status = S.timeout, .attempts = 2, .events = &.{.{ .entity_id = "x", .event_id = "1", .result = E.timeout, .message = "" }} },
    };
    try testing.expectEqual(Classification.incomplete, classify(&timed_out));

    // One relay accepted, one timed out → partial (not incomplete: some
    // relays did accept).
    const mixed = [_]RelayOutcome{
        .{ .url = "a", .status = S.accepted, .attempts = 1, .events = &.{.{ .entity_id = "x", .event_id = "1", .result = E.accepted, .message = "" }} },
        .{ .url = "b", .status = S.timeout, .attempts = 2, .events = &.{.{ .entity_id = "x", .event_id = "1", .result = E.timeout, .message = "" }} },
    };
    try testing.expectEqual(Classification.partial, classify(&mixed));
}

test "classify: a relay that accepted every event but one relay has zero events cannot be complete" {
    const S = RelayStatus;
    const no_events = [_]RelayOutcome{
        .{ .url = "a", .status = S.failed, .attempts = 1, .events = &.{} },
    };
    try testing.expectEqual(Classification.failed, classify(&no_events));
}

test "classifyMessage: OK true, OK false, NOTICE, AUTH, and garbage" {
    const a = testing.allocator;
    try testing.expectEqual(MessageOutcome.ok, try classifyMessage(a, a, "[\"OK\",\"abc\",true,\"\"]", "abc"));
    const rejected = try classifyMessage(a, a, "[\"OK\",\"abc\",false,\"blocked: spam\"]", "abc");
    defer a.free(rejected.rejected);
    try testing.expectEqualStrings("blocked: spam", rejected.rejected);
    try testing.expectEqual(MessageOutcome.notice, try classifyMessage(a, a, "[\"NOTICE\",\"hi\"]", "abc"));
    try testing.expectEqual(MessageOutcome.auth, try classifyMessage(a, a, "[\"AUTH\",\"challenge\"]", "abc"));
    try testing.expectEqual(MessageOutcome.wrong_id, try classifyMessage(a, a, "[\"OK\",\"other\",true,\"\"]", "abc"));
    try testing.expectError(error.Malformed, classifyMessage(a, a, "not json", "abc"));
    try testing.expectError(error.Malformed, classifyMessage(a, a, "[\"EVENT\"]", "abc"));
    try testing.expectError(error.Malformed, classifyMessage(a, a, "[\"OK\",\"abc\",true]", "abc"));
    try testing.expectError(error.Malformed, classifyMessage(a, a, "\xff\xfe garbage", "abc"));
}

test "startsWithIgnoreCase: auth-required prefix matching" {
    try testing.expect(startsWithIgnoreCase("auth-required: please authenticate", "auth-required:"));
    try testing.expect(startsWithIgnoreCase("AUTH-REQUIRED: please", "auth-required:"));
    try testing.expect(!startsWithIgnoreCase("blocked: no", "auth-required:"));
}

test "NIP-42 verifier refuses signer substitution, skew, invalid IDs and signatures" {
    const gpa = testing.allocator;
    var ctx = try keys.Context.init();
    defer ctx.deinit();
    const pair = try ctx.keyPairFromSecretKey(@as([31]u8, @splat(0)) ++ [_]u8{3});
    const pubkey = std.fmt.bytesToHex(pair.public_key, .lower);
    const bytes = try auth.sign(gpa, ctx, pair, &pubkey, "wss://relay.example:444/path", "challenge", 1000, @splat(0));
    defer gpa.free(bytes);
    var parsed = try std.json.parseFromSlice(auth.Event, gpa, bytes, .{});
    defer parsed.deinit();
    const event = parsed.value;
    try auth.verify(gpa, event, &pubkey, "wss://relay.example:444/path", "challenge", 1060);
    try testing.expectError(error.Stale, auth.verify(gpa, event, &pubkey, "wss://relay.example:444/path", "challenge", 1061));
    try testing.expectError(error.Stale, auth.verify(gpa, event, &pubkey, "wss://relay.example:444/path", "challenge", 939));
    try testing.expectError(error.IdentityMismatch, auth.verify(gpa, event, rep("0", 64), "wss://relay.example:444/path", "challenge", 1000));
    for ([_][]const u8{ "wss://relay.example:445/path", "wss://relay.example:444/other", "wss://other.example:444/path" }) |relay|
        try testing.expectError(error.RelayMismatch, auth.verify(gpa, event, &pubkey, relay, "challenge", 1000));
    try testing.expectError(error.Malformed, auth.verify(gpa, event, &pubkey, "wss://relay.example:444/path", "different", 1000));
    var bad = event;
    bad.kind = 30023;
    try testing.expectError(error.Malformed, auth.verify(gpa, bad, &pubkey, "wss://relay.example:444/path", "challenge", 1000));
    bad = event;
    bad.content = "article";
    try testing.expectError(error.Malformed, auth.verify(gpa, bad, &pubkey, "wss://relay.example:444/path", "challenge", 1000));
    bad = event;
    bad.tags = &.{ event.tags[1], event.tags[0] };
    try testing.expectError(error.Malformed, auth.verify(gpa, bad, &pubkey, "wss://relay.example:444/path", "challenge", 1000));
    bad = event;
    bad.id = rep("0", 64);
    try testing.expectError(error.EventIdMismatch, auth.verify(gpa, bad, &pubkey, "wss://relay.example:444/path", "challenge", 1000));
    bad = event;
    bad.sig = rep("0", 128);
    try testing.expectError(error.SignatureInvalid, auth.verify(gpa, bad, &pubkey, "wss://relay.example:444/path", "challenge", 1000));
}

test "NIP-42 signer policy limits generations, retirement, replay and correlation" {
    const policy: auth.Policy = .{ .plan_digest = rep("1", 64), .bundle_digest = rep("2", 64), .nips_revision = auth.revision, .pubkey = rep("3", 64), .relays = &.{"wss://relay.example"}, .timeout_ms = 100 };
    var request: auth.Request = .{ .correlation = .{ .plan_digest = policy.plan_digest, .bundle_digest = policy.bundle_digest, .nips_revision = auth.revision, .run = rep("a", 32), .connection = rep("b", 32), .request = 1, .relay = policy.relays[0], .generation = 1 }, .challenge = "first" };
    var budget: auth.Budget = .{};
    _ = try budget.admit(policy, rep("a", 32), request);
    try testing.expectError(error.SessionInvalid, budget.admit(policy, rep("a", 32), request));
    request.correlation.request = 2;
    request.correlation.generation = 2;
    try testing.expectError(error.Replay, budget.admit(policy, rep("a", 32), request));
    request.challenge = "second";
    var wrong = request;
    wrong.correlation.run = rep("c", 32);
    try testing.expectError(error.SessionInvalid, budget.admit(policy, rep("a", 32), wrong));
    wrong = request;
    wrong.correlation.connection = rep("d", 32);
    try testing.expectError(error.SessionInvalid, budget.admit(policy, rep("a", 32), wrong));
    wrong = request;
    wrong.correlation.relay = "wss://other.example";
    try testing.expectError(error.RelayMismatch, budget.admit(policy, rep("a", 32), wrong));
    _ = try budget.admit(policy, rep("a", 32), request);
    request.correlation.request = 3;
    request.correlation.generation = 3;
    try testing.expectError(error.ReplacementLimit, budget.admit(policy, rep("a", 32), request));
    budget.retired[0] = true;
    try testing.expectError(error.ReplacementLimit, budget.admit(policy, rep("a", 32), request));
    inline for (.{ "event", "digest", "kind", "content", "tags", "created_at" }) |field| {
        const arbitrary = "{\"format\":\"boris-nostr-auth-ipc\",\"version\":1,\"type\":\"sign\",\"correlation\":{},\"challenge\":\"x\",\"" ++ field ++ "\":0}";
        try testing.expectError(error.Malformed, auth.parse(auth.Request, testing.allocator, arbitrary, "sign"));
    }
}

const test_secret_key = "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef";
const test_pubkey = "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659";
const test_aux = @as([32]u8, @splat(0));
const test_created_at: i64 = 1705762000;

fn signedPair(gpa: std.mem.Allocator) !struct { plan: []u8, bundle: []u8 } {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tags = [_]nostr.Tag{
        .{ .name = "d", .value = "articles/vec" },
        .{ .name = "published_at", .value = "1705761000" },
    };
    var digest: [nostr.digest_hex_len]u8 = undefined;
    try nostr.intentionDigestHex(arena, &tags, "hi", &digest);

    var plan_buf: std.ArrayList(u8) = .empty;
    errdefer plan_buf.deinit(gpa);
    try plan_buf.appendSlice(gpa, "{\"format\":\"boris-nostr-publication-plan\",\"schema_version\":1,\"protocol\":{\"kind\":30023},\"author\":{\"expected_pubkey\":\"");
    try plan_buf.appendSlice(gpa, test_pubkey);
    try plan_buf.appendSlice(gpa, "\"},\"articles\":[{\"entity_id\":\"articles/vec\",\"kind\":30023,\"tags\":[[\"d\",\"articles/vec\"],[\"published_at\",\"1705761000\"]],\"content\":\"hi\",\"intention_digest\":\"");
    try plan_buf.appendSlice(gpa, &digest);
    try plan_buf.appendSlice(gpa, "\"}],\"delivery\":{\"relays\":[\"wss://127.0.0.1:1\"],\"timeout_ms\":100,\"retries\":0}}");
    const plan = try plan_buf.toOwnedSlice(gpa);

    var signed = try sign_mod.run(testing.io, gpa, .{
        .plan = plan,
        .key = test_secret_key,
        .created_at = test_created_at,
        .aux_rand = test_aux,
    });
    defer signed.deinit();
    if (signed.bundle == null) return error.TestUnexpectedResult;
    return .{ .plan = plan, .bundle = try gpa.dupe(u8, signed.bundle.?) };
}

test "publish: the report bundle digest is the sha-256 of the bundle bytes" {
    const gpa = testing.allocator;
    const pair = try signedPair(gpa);
    defer gpa.free(pair.plan);
    defer gpa.free(pair.bundle);

    var result = try run(testing.io, gpa, .{ .plan = pair.plan, .bundle = pair.bundle });
    defer result.deinit();
    try testing.expect(result.report != null);

    var plan_digest: [nostr.digest_hex_len]u8 = undefined;
    nostr.digestHex(pair.plan, &plan_digest);
    var bundle_digest: [nostr.digest_hex_len]u8 = undefined;
    nostr.digestHex(pair.bundle, &bundle_digest);
    try testing.expect(!std.mem.eql(u8, &plan_digest, &bundle_digest));

    var parsed = try std.json.parseFromSlice(struct {
        plan: struct { digest: []const u8 },
        bundle: struct { digest: []const u8 },
    }, gpa, result.report.?, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings(&plan_digest, parsed.value.plan.digest);
    try testing.expectEqualStrings(&bundle_digest, parsed.value.bundle.digest);
}

test "publish: an extra bundle article is refused before any socket opens" {
    const gpa = testing.allocator;
    const pair = try signedPair(gpa);
    defer gpa.free(pair.plan);
    defer gpa.free(pair.bundle);

    const extra = pair.bundle;
    const marker = "\"articles\": [";
    const idx = std.mem.indexOf(u8, extra, marker) orelse return error.TestUnexpectedResult;
    const insert_at = idx + marker.len;
    const first_end = std.mem.indexOfPos(u8, extra, insert_at, "\n    }") orelse return error.TestUnexpectedResult;
    const first = extra[insert_at .. first_end + 6];
    var padded_buf: std.ArrayList(u8) = .empty;
    defer padded_buf.deinit(gpa);
    try padded_buf.appendSlice(gpa, extra[0..insert_at]);
    try padded_buf.appendSlice(gpa, first);
    try padded_buf.appendSlice(gpa, ",");
    try padded_buf.appendSlice(gpa, extra[insert_at..]);
    const padded = padded_buf.items;

    var result = try run(testing.io, gpa, .{ .plan = pair.plan, .bundle = padded });
    defer result.deinit();
    try testing.expect(result.report == null);
    try testing.expect(result.diagnostics.items.len > 0);
    try testing.expectEqual(diag.Code.ENOSTRPLAN, result.diagnostics.items[0].code);
}
