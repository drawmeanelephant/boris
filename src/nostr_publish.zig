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
//! exists.
//!
//! ## Idempotence
//!
//! A retry resends the **identical event** — same id, same signature, same
//! bytes — which relays deduplicate by id, so resends are safe by
//! construction. There is no automatic NIP-09 deletion: removing a local
//! file mutates nothing remotely.

const std = @import("std");
const diag = @import("diag.zig");
const json_out = @import("json_out.zig");
const keys = @import("nostr_keys.zig");
const nostr = @import("nostr.zig");
const plan_mod = @import("nostr_plan.zig");
const sign_mod = @import("nostr_sign.zig");
const ws = @import("ws_client.zig");

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

    pub fn deinit(self: *Result) void {
        if (self.report) |bytes| self.gpa.free(bytes);
        self.diagnostics.deinit(self.gpa);
        self.arena.deinit();
    }
};

// =============================================================================
// Artifact shapes (parsed from plan / signed bundle JSON)
// =============================================================================

const PlanJson = struct {
    format: []const u8,
    schema_version: u32,
    protocol: struct { kind: u32 = 0 },
    author: struct { expected_pubkey: []const u8 = "" },
    delivery: struct {
        relays: []const []const u8 = &.{},
        timeout_ms: u32 = nostr.default_timeout_ms,
        retries: u8 = 0,
    },
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

    pub fn jsonName(self: EventResult) []const u8 {
        return switch (self) {
            .failed => "error",
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

    pub fn jsonName(self: RelayStatus) []const u8 {
        return switch (self) {
            .failed => "error",
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
};

// =============================================================================
// Verification (fail closed before any socket opens)
// =============================================================================

fn parsePlan(arena: std.mem.Allocator, bytes: []const u8) !PlanJson {
    const parsed = try std.json.parseFromSlice(PlanJson, arena, bytes, .{ .ignore_unknown_fields = true });
    const plan = parsed.value;
    if (!std.mem.eql(u8, plan.format, plan_mod.artifact_format)) return error.InvalidPlanFormat;
    if (plan.schema_version != plan_mod.schema_version) return error.InvalidPlanSchema;
    if (plan.protocol.kind != nostr.kind_long_form) return error.InvalidPlanKind;
    if (plan.delivery.relays.len == 0) return error.NoRelays;
    return plan;
}

fn parseBundle(arena: std.mem.Allocator, bytes: []const u8) !BundleJson {
    const parsed = try std.json.parseFromSlice(BundleJson, arena, bytes, .{ .ignore_unknown_fields = true });
    const bundle = parsed.value;
    if (!std.mem.eql(u8, bundle.format, sign_mod.artifact_format)) return error.InvalidBundleFormat;
    if (bundle.schema_version != sign_mod.schema_version) return error.InvalidBundleSchema;
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

    const relays = plan.delivery.relays;
    const timeout_ms = plan.delivery.timeout_ms;
    const retries = plan.delivery.retries;

    var plan_digest: [nostr.digest_hex_len]u8 = undefined;
    nostr.digestHex(options.plan, &plan_digest);

    var relay_outcomes: std.ArrayList(RelayOutcome) = .empty;
    defer relay_outcomes.deinit(arena);

    for (relays) |relay_url| {
        relay_outcomes.append(arena, try publishToRelay(io, gpa, arena, &result, relay_url, bundle.articles, timeout_ms, retries, options.tls)) catch |err| {
            // Out of memory mid-report is an I/O-class failure; the relay
            // loop itself never escapes other errors.
            return err;
        };
    }

    const classification = classify(relay_outcomes.items);
    diag.sortDiagnostics(result.diagnostics.items);
    result.classification = classification;
    result.report = try renderReport(gpa, &plan_digest, bundle.plan.digest, bundle.signer.pubkey, classification, relay_outcomes.items);
    return result;
}

fn classify(relays: []const RelayOutcome) Classification {
    var accepted_any = false;
    var timed_out_any = false;
    var all_accepted = true;
    for (relays) |relay| {
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
) !RelayOutcome {
    // The array list and its items live in the run arena (freed with the
    // result); the items slice escapes into the RelayOutcome, so it must not
    // be deinit'd here.
    var events: std.ArrayList(EventOutcome) = .empty;
    try events.ensureTotalCapacity(arena, articles.len);

    var attempts: usize = 0;
    var status: RelayStatus = .accepted;
    var abort_relay = false;

    var client = ws.Client.connect(io, gpa, relay_url, .{
        .handshake_timeout_ms = timeout_ms,
        .read_timeout_ms = timeout_ms,
        .tls = tls,
    }) catch |err| {
        status = .failed;
        attempts = 1;
        try events.append(arena, .{ .entity_id = "", .event_id = "", .result = .failed, .message = @errorName(err) });
        try emitRelayDiagnostic(result, relay_url, "connect or handshake failed", err);
        return .{ .url = relay_url, .status = status, .attempts = attempts, .events = events.items };
    };
    defer client.deinit();

    for (articles) |article| {
        if (abort_relay) {
            try events.append(arena, .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .not_attempted, .message = "" });
            continue;
        }
        const outcome = try sendEvent(gpa, arena, &client, relay_url, article, retries, result, &attempts);
        switch (outcome.result) {
            .accepted => {},
            .rejected, .timeout, .failed, .auth_required, .closed => {
                if (status == .accepted) status = switch (outcome.result) {
                    .rejected => .rejected,
                    .timeout => .timeout,
                    .failed => .failed,
                    .auth_required => .auth_required,
                    .closed => .closed,
                    else => unreachable,
                };
            },
            .not_attempted => {},
        }
        // A relay that rejects with auth-required, or closes mid-send, is
        // not worth more events: the outcome is definitive for this run.
        if (outcome.result == .failed or outcome.result == .auth_required or outcome.result == .closed) abort_relay = true;
        try events.append(arena, outcome);
    }
    return .{ .url = relay_url, .status = status, .attempts = attempts, .events = events.items };
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
) !EventOutcome {
    const max_attempts: usize = @as(usize, retries) + 1;
    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        attempts.* += 1;
        const wire = try renderEventMessage(gpa, article);
        defer gpa.free(wire);
        client.sendText(wire) catch |err| {
            try emitRelayDiagnostic(result, relay_url, "could not send the event", err);
            return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .failed, .message = @errorName(err) };
        };
        _ = readUntilOk(gpa, arena, client, article.event.id) catch |err| switch (err) {
            error.AuthRequired => {
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
            else => {
                try emitRelayDiagnostic(result, relay_url, "relay protocol error", err);
                return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .failed, .message = @errorName(err) };
            },
        };
        return .{ .entity_id = article.entity_id, .event_id = article.event_id, .result = .accepted, .message = "" };
    }
    unreachable;
}

const OkRead = enum { ok };

/// Read messages until the relay answers with `OK` for `wanted_id`, or the
/// read deadline fires. `NOTICE` is recorded and the wait continues (NOTICE
/// is never success). `AUTH` or an `auth-required:` OK yields
/// `error.AuthRequired`. A malformed message or an OK for another id fails
/// closed.
fn readUntilOk(gpa: std.mem.Allocator, arena: std.mem.Allocator, client: *ws.Client, wanted_id: []const u8) !OkRead {
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
                    .auth => return error.AuthRequired,
                    .wrong_id => return error.Malformed,
                    .rejected => |reason| {
                        // The reason is arena-owned, so it outlives the parse.
                        if (startsWithIgnoreCase(reason, "auth-required:")) return error.AuthRequired;
                        return error.Rejected;
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
fn renderEventMessage(gpa: std.mem.Allocator, article: SignedArticle) ![]u8 {
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
    bundle_digest: []const u8,
    pubkey: []const u8,
    classification: Classification,
    relays: []const RelayOutcome,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, artifact_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"plan\": {\n    \"format\": ");
    try json_out.writeString(&out, gpa, plan_mod.artifact_format);
    try out.appendSlice(gpa, ",\n    \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, plan_mod.schema_version);
    try out.appendSlice(gpa, ",\n    \"digest\": ");
    try json_out.writeString(&out, gpa, plan_digest);
    try out.appendSlice(gpa, "\n  },\n  \"bundle\": {\n    \"format\": ");
    try json_out.writeString(&out, gpa, sign_mod.artifact_format);
    try out.appendSlice(gpa, ",\n    \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, sign_mod.schema_version);
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
