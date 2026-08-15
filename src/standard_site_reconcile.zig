//! Reconcile a committed Standard.site plan against the authenticated PDS and
//! emit honest intended-vs-observed publish evidence.
//!
//! The reconciler consumes the offline projection plan (the intended state),
//! an authorized XRPC session bound to the account PDS, and an explicit prune
//! authority. Before any mutation it verifies the session DID, PDS origin,
//! collection names, rkeys, and plan digest all match the committed plan;
//! any mismatch fails closed with zero writes. It then fetches each remote
//! record, classifies the intended operation, writes only when needed (zero
//! writes for unchanged records), uses compare-and-swap where the protocol
//! provides a safe boundary, and treats ambiguous timeouts as unverified
//! until a confirming read observes the intended value.
//!
//! Secrets never enter the evidence: no access token, refresh token, DPoP
//! private material, authorization code, raw proof, or secret response
//! header. Intended state and observed remote state are separate claims.

const std = @import("std");
const json_out = @import("json_out.zig");
const standard_site = @import("standard_site.zig");
const xrpc = @import("atproto_xrpc.zig");
const transport = @import("atproto_transport.zig");
const identity = @import("atproto_identity.zig");
const oauth = @import("atproto_oauth.zig");
const authorization = @import("atproto_authorization.zig");

pub const evidence_format = "boris-standard-site-evidence";
pub const evidence_schema_version: u32 = 1;

/// Outcome vocabulary: what the reconciler actually did, per record.
pub const Outcome = enum {
    created,
    updated,
    unchanged,
    failed,
    skipped_orphan,
    pruned,

    fn name(self: Outcome) []const u8 {
        return switch (self) {
            .created => "created",
            .updated => "updated",
            .unchanged => "unchanged",
            .failed => "failed",
            .skipped_orphan => "skipped_orphan",
            .pruned => "pruned",
        };
    }
};

/// How an outcome was verified. `write_response` trusts the mutation response;
/// `confirming_read` required a post-mutation read (ambiguous timeout that
/// actually landed); `observed` is a read-only classification (unchanged);
/// `not_verified` means the operation failed or could not be confirmed.
pub const Verification = enum {
    write_response,
    confirming_read,
    observed,
    not_verified,

    fn name(self: Verification) []const u8 {
        return switch (self) {
            .write_response => "write_response",
            .confirming_read => "confirming_read",
            .observed => "observed",
            .not_verified => "not_verified",
        };
    }
};

/// Intended state from the committed plan. Records carry `intent` from the
/// plan and `outcome`/`observed_*` from the remote PDS as separate claims.
pub const Intent = enum {
    create,
    update,
    unchanged,
    skip,

    fn name(self: Intent) []const u8 {
        return switch (self) {
            .create => "create",
            .update => "update",
            .unchanged => "unchanged",
            .skip => "skip",
        };
    }
};

pub const Error = standard_site.Error || xrpc.Error || error{
    PlanDigestMismatch,
    SessionDidMismatch,
    SessionPdsMismatch,
    CollectionMismatch,
    RkeyMismatch,
    PruneWithoutAuthority,
    ConflictingRecord,
    RejectedRecord,
    AmbiguousWrite,
};

/// Caller-provided binding facts (source commit and pins) so the evidence
/// ties the observed remote state to the exact local inputs.
pub const Bindings = struct {
    source_commit: []const u8,
    boris_pin: []const u8,
    oliver_pin: []const u8,
};

/// Per-record evidence. All strings are allocator-owned.
pub const RecordEvidence = struct {
    at_uri: []u8,
    rkey: []u8,
    intent: Intent,
    outcome: Outcome,
    verification: Verification,
    /// Lowercase hex SHA-256 of the intended payload bytes.
    intended_payload_sha256: [64]u8,
    observed_cid: ?[]u8,
    observed_at: []u8,
    failure: ?[]u8,

    fn deinit(self: *RecordEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.at_uri);
        allocator.free(self.rkey);
        if (self.observed_cid) |cid| allocator.free(cid);
        allocator.free(self.observed_at);
        if (self.failure) |failure| allocator.free(failure);
        self.* = undefined;
    }
};

/// The full evidence artifact in memory, ready for deterministic rendering.
pub const Evidence = struct {
    did: []u8,
    pds_origin: []u8,
    plan_sha256: [64]u8,
    bindings: Bindings,
    records: []RecordEvidence,
    /// True when every intended record reached its target state or was
    /// honestly skipped; any failure makes the whole publish nonzero.
    overall_passed: bool,

    pub fn deinit(self: *Evidence, allocator: std.mem.Allocator) void {
        allocator.free(self.did);
        allocator.free(self.pds_origin);
        for (self.records) |*record| record.deinit(allocator);
        allocator.free(self.records);
        self.* = undefined;
    }
};

/// Lowercase hex SHA-256 of arbitrary bytes; used for the plan digest and
/// intended-payload digests.
pub fn sha256HexLower(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        const hex = "0123456789abcdef";
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 15];
    }
    return out;
}

/// Deep JSON equality between a fetched remote record `value` and the
/// intended payload bytes, key-order-insensitive at every object level.
/// The PDS may reorder keys; the reconciler compares canonical values, never
/// local digests or hand-rolled CIDs.
fn jsonValueEqualsRemote(allocator: std.mem.Allocator, value: std.json.Value, intended_payload: []const u8) !bool {
    if (intended_payload.len == 0) return false;
    var intended = std.json.parseFromSlice(std.json.Value, allocator, intended_payload, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = 16 * 1024,
        .allocate = .alloc_always,
    }) catch return false;
    defer intended.deinit();
    return jsonValuesEqual(value, intended.value);
}

fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |av| return b == .bool and b.bool == av,
        .integer => |av| return b == .integer and b.integer == av,
        .float => |av| return b == .float and b.float == av,
        .number_string => |av| return b == .number_string and std.mem.eql(u8, av, b.number_string),
        .string => |av| return b == .string and std.mem.eql(u8, av, b.string),
        .array => |av| {
            if (b != .array or b.array.items.len != av.items.len) return false;
            for (av.items, b.array.items) |x, y| if (!jsonValuesEqual(x, y)) return false;
            return true;
        },
        .object => |av| {
            if (b != .object or b.object.count() != av.count()) return false;
            var it = av.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse return false;
                if (!jsonValuesEqual(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}

/// Parse and validate the committed plan inputs against the authorized
/// session. Fails closed before any mutation.
fn verifyPreconditions(
    gpa: std.mem.Allocator,
    session: *xrpc.SessionClient,
    plan: []const u8,
    expected_plan_sha256: [64]u8,
) Error!void {
    if (!std.mem.eql(u8, &sha256HexLower(plan), &expected_plan_sha256)) return error.PlanDigestMismatch;

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, plan, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = 16 * 1024,
        .allocate = .alloc_always,
    }) catch return error.PlanDigestMismatch;
    defer parsed.deinit();
    const root = parsed.value.object;

    const did_text = root.get("inputs").?.object.get("did").?;
    if (did_text != .string) return error.PlanDigestMismatch;
    if (!std.mem.eql(u8, did_text.string, session.binding.did.slice())) return error.SessionDidMismatch;

    const pds_text = root.get("inputs").?.object.get("pds_origin").?;
    if (pds_text != .string) return error.SessionPdsMismatch;
    if (!std.mem.eql(u8, pds_text.string, session.binding.pds_origin.slice())) return error.SessionPdsMismatch;

    const publication = root.get("publication").?.object;
    const pub_type = publication.get("type").?;
    if (pub_type != .string or !std.mem.eql(u8, pub_type.string, standard_site.publication_collection)) return error.CollectionMismatch;
    const pub_rkey = publication.get("rkey").?;
    if (pub_rkey != .string or !std.mem.eql(u8, pub_rkey.string, standard_site.default_publication_rkey)) return error.RkeyMismatch;

    if (root.get("documents")) |documents| {
        for (documents.array.items) |document| {
            const doc_type = document.object.get("type").?;
            if (doc_type != .string or !std.mem.eql(u8, doc_type.string, standard_site.document_collection)) return error.CollectionMismatch;
            const rkey = document.object.get("rkey").?;
            if (rkey != .string or rkey.string.len == 0 or rkey.string.len > xrpc.max_rkey_bytes) return error.RkeyMismatch;
        }
    }
}

/// One reconciliation pass against the committed plan. Consumes the offline
/// projection (`standard_site.Projection`) — the intended state — plus the
/// rendered plan artifact bytes and its digest, the authorized session, and
/// explicit prune authority. Returns the evidence artifact (owned).
pub fn reconcile(
    gpa: std.mem.Allocator,
    config: *const standard_site.TargetConfig,
    projection: *const standard_site.Projection,
    plan: []const u8,
    expected_plan_sha256: [64]u8,
    session: *xrpc.SessionClient,
    prune: bool,
    bindings: Bindings,
    observed_at: []const u8,
) Error!Evidence {
    try verifyPreconditions(gpa, session, plan, expected_plan_sha256);

    var records: std.ArrayList(RecordEvidence) = .empty;
    errdefer {
        for (records.items) |*record| record.deinit(gpa);
        records.deinit(gpa);
    }
    var overall_passed = true;

    // Publication record first: documents reference its AT-URI, so a failed
    // publication write makes the whole plan non-verifiable and fails the
    // overall result. Document records are independent of each other: a
    // failure on one must not block the rest, but any failure fails overall.
    var pub_outcome = try reconcileRecord(
        gpa,
        session,
        standard_site.publication_collection,
        standard_site.default_publication_rkey,
        projection.publication.payload,
        observed_at,
    );
    var pub_owned = true;
    errdefer if (pub_owned) pub_outcome.deinit(gpa);
    if (pub_outcome.outcome == .failed) overall_passed = false;
    try records.append(gpa, pub_outcome);
    pub_owned = false;

    for (projection.documents) |document| {
        var outcome = try reconcileRecord(
            gpa,
            session,
            standard_site.document_collection,
            document.rkey,
            document.payload,
            observed_at,
        );
        var owned = true;
        errdefer if (owned) outcome.deinit(gpa);
        if (outcome.outcome == .failed) overall_passed = false;
        try records.append(gpa, outcome);
        owned = false;
    }

    // Orphans: records that exist remotely for pages absent from the plan.
    // Without explicit prune authority we never delete; we skip and record.
    if (prune) {
        for (projection.exclusions) |exclusion| {
            const rkey = try standard_site.entityRkey(gpa, exclusion.entity_id);
            defer gpa.free(rkey);
            var orphan = try reconcileOrphan(gpa, session, rkey, observed_at);
            var owned = true;
            errdefer if (owned) orphan.deinit(gpa);
            if (orphan.outcome == .failed) overall_passed = false;
            try records.append(gpa, orphan);
            owned = false;
        }
    }

    return .{
        .did = try gpa.dupe(u8, config.did),
        .pds_origin = try gpa.dupe(u8, session.binding.pds_origin.slice()),
        .plan_sha256 = expected_plan_sha256,
        .bindings = bindings,
        .records = try records.toOwnedSlice(gpa),
        .overall_passed = overall_passed,
    };
}

/// Reconcile one intended record: fetch, classify, write only on drift, and
/// never claim a timeout as success without a confirming read.
fn reconcileRecord(
    gpa: std.mem.Allocator,
    session: *xrpc.SessionClient,
    collection: []const u8,
    rkey: []const u8,
    intended_payload: []const u8,
    observed_at: []const u8,
) Error!RecordEvidence {
    const at_uri = try xrpc.buildAtUri(gpa, session.binding.did.slice(), collection, rkey);
    errdefer gpa.free(at_uri);
    const rkey_owned = try gpa.dupe(u8, rkey);
    errdefer gpa.free(rkey_owned);
    const observed_at_owned = try gpa.dupe(u8, observed_at);
    errdefer gpa.free(observed_at_owned);

    var fetch = session.getRecord(gpa, collection, rkey) catch |err| {
        return failedEvidence(gpa, at_uri, rkey_owned, observed_at_owned, .unchanged, err);
    };
    defer switch (fetch) {
        .found => |*response| response.deinit(),
        .not_found => {},
    };

    switch (fetch) {
        .not_found => {
            var put = session.putRecord(gpa, collection, rkey, intended_payload, null) catch |err| {
                // Ambiguous write failure: only a confirming read can
                // distinguish a landed write from a rejection.
                return confirmAfterWriteFailure(gpa, session, collection, rkey, intended_payload, at_uri, rkey_owned, observed_at_owned, .create, err);
            };
            defer put.deinit();
            return .{
                .at_uri = at_uri,
                .rkey = rkey_owned,
                .intent = .create,
                .outcome = .created,
                .verification = .write_response,
                .intended_payload_sha256 = sha256HexLower(intended_payload),
                .observed_cid = try gpa.dupe(u8, put.cid),
                .observed_at = observed_at_owned,
                .failure = null,
            };
        },
        .found => |*response| {
            // The XRPC client keeps the whole getRecord body in `value`; the
            // record itself is its nested `value` member.
            const remote_value = response.value.value.object.get("value") orelse return error.InvalidResponse;
            const matches = try jsonValueEqualsRemote(gpa, remote_value, intended_payload);
            if (matches) {
                return .{
                    .at_uri = at_uri,
                    .rkey = rkey_owned,
                    .intent = .unchanged,
                    .outcome = .unchanged,
                    .verification = .observed,
                    .intended_payload_sha256 = sha256HexLower(intended_payload),
                    .observed_cid = if (response.cid) |cid| try gpa.dupe(u8, cid) else null,
                    .observed_at = observed_at_owned,
                    .failure = null,
                };
            }
            // Remote differs: intended update with compare-and-swap on the
            // observed CID so a concurrent writer cannot silently win.
            var put = session.putRecord(gpa, collection, rkey, intended_payload, response.cid) catch |err| {
                return confirmAfterWriteFailure(gpa, session, collection, rkey, intended_payload, at_uri, rkey_owned, observed_at_owned, .update, err);
            };
            defer put.deinit();
            return .{
                .at_uri = at_uri,
                .rkey = rkey_owned,
                .intent = .update,
                .outcome = .updated,
                .verification = .write_response,
                .intended_payload_sha256 = sha256HexLower(intended_payload),
                .observed_cid = try gpa.dupe(u8, put.cid),
                .observed_at = observed_at_owned,
                .failure = null,
            };
        },
    }
}

/// After a write failure, read the record back. If the intended value is now
/// present, the write landed (ambiguous timeout) — report success only with
/// `confirming_read`. Otherwise report the exact failure.
fn confirmAfterWriteFailure(
    gpa: std.mem.Allocator,
    session: *xrpc.SessionClient,
    collection: []const u8,
    rkey: []const u8,
    intended_payload: []const u8,
    at_uri: []u8,
    rkey_owned: []u8,
    observed_at_owned: []u8,
    intent: Intent,
    failure: Error,
) Error!RecordEvidence {
    var confirm = session.getRecord(gpa, collection, rkey) catch {
        return failedEvidence(gpa, at_uri, rkey_owned, observed_at_owned, intent, failure);
    };
    defer switch (confirm) {
        .found => |*response| response.deinit(),
        .not_found => {},
    };
    const found = switch (confirm) {
        .found => |*response| response,
        .not_found => return failedEvidence(gpa, at_uri, rkey_owned, observed_at_owned, intent, failure),
    };
    const remote_value = found.value.value.object.get("value") orelse return error.InvalidResponse;
    if (try jsonValueEqualsRemote(gpa, remote_value, intended_payload)) {
        // The write landed despite the ambiguous response. Only a confirming
        // read distinguishes this from a rejection; never claim success from
        // the failed response alone.
        const outcome: Outcome = if (intent == .create) .created else .updated;
        return .{
            .at_uri = at_uri,
            .rkey = rkey_owned,
            .intent = intent,
            .outcome = outcome,
            .verification = .confirming_read,
            .intended_payload_sha256 = sha256HexLower(intended_payload),
            .observed_cid = if (found.cid) |cid| try gpa.dupe(u8, cid) else null,
            .observed_at = observed_at_owned,
            .failure = null,
        };
    }
    return failedEvidence(gpa, at_uri, rkey_owned, observed_at_owned, intent, failure);
}

/// Reconcile an orphaned remote record: skip by default, or delete under
/// explicit prune authority. A missing local page never deletes a remote
/// record without prune.
fn reconcileOrphan(
    gpa: std.mem.Allocator,
    session: *xrpc.SessionClient,
    rkey: []const u8,
    observed_at: []const u8,
) Error!RecordEvidence {
    const at_uri = try xrpc.buildAtUri(gpa, session.binding.did.slice(), standard_site.document_collection, rkey);
    errdefer gpa.free(at_uri);
    const rkey_owned = try gpa.dupe(u8, rkey);
    errdefer gpa.free(rkey_owned);
    const observed_at_owned = try gpa.dupe(u8, observed_at);
    errdefer gpa.free(observed_at_owned);

    var fetch = session.getRecord(gpa, standard_site.document_collection, rkey) catch |err| {
        return failedEvidence(gpa, at_uri, rkey_owned, observed_at_owned, .skip, err);
    };
    defer switch (fetch) {
        .found => |*response| response.deinit(),
        .not_found => {},
    };
    switch (fetch) {
        .not_found => return failedEvidence(gpa, at_uri, rkey_owned, observed_at_owned, .skip, error.RejectedRecord),
        .found => |*response| {
            const cid = if (response.cid) |value| try gpa.dupe(u8, value) else null;
            errdefer if (cid) |value| gpa.free(value);
            var deleted = session.deleteRecord(gpa, standard_site.document_collection, rkey, response.cid) catch |err| {
                return failedEvidence(gpa, at_uri, rkey_owned, observed_at_owned, .skip, err);
            };
            defer deleted.deinit();
            return .{
                .at_uri = at_uri,
                .rkey = rkey_owned,
                .intent = .skip,
                .outcome = .pruned,
                .verification = .write_response,
                .intended_payload_sha256 = [_]u8{0} ** 64,
                .observed_cid = cid,
                .observed_at = observed_at_owned,
                .failure = null,
            };
        },
    }
}

fn failedEvidence(
    gpa: std.mem.Allocator,
    at_uri: []u8,
    rkey: []u8,
    observed_at: []u8,
    intent: Intent,
    failure: Error,
) Error!RecordEvidence {
    return .{
        .at_uri = at_uri,
        .rkey = rkey,
        .intent = intent,
        .outcome = .failed,
        .verification = .not_verified,
        .intended_payload_sha256 = [_]u8{0} ** 64,
        .observed_cid = null,
        .observed_at = observed_at,
        .failure = try gpa.dupe(u8, @errorName(failure)),
    };
}

// ---------------------------------------------------------------------------
// evidence artifact rendering
// ---------------------------------------------------------------------------

/// Deterministic machine-readable evidence artifact. Fixed JSON key order, LF
/// endings, no timestamps beyond the injected observation time, and never any
/// secret material. The returned bytes are allocator-owned and end in one LF.
pub fn renderEvidence(gpa: std.mem.Allocator, evidence: *const Evidence) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, evidence_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, evidence_schema_version);
    try out.appendSlice(gpa, ",\n  \"identity\": {\n    \"did\": ");
    try json_out.writeString(&out, gpa, evidence.did);
    try out.appendSlice(gpa, ",\n    \"pds_origin\": ");
    try json_out.writeString(&out, gpa, evidence.pds_origin);
    try out.appendSlice(gpa, "\n  },\n  \"bindings\": {\n    \"source_commit\": ");
    try json_out.writeString(&out, gpa, evidence.bindings.source_commit);
    try out.appendSlice(gpa, ",\n    \"boris_pin\": ");
    try json_out.writeString(&out, gpa, evidence.bindings.boris_pin);
    try out.appendSlice(gpa, ",\n    \"oliver_pin\": ");
    try json_out.writeString(&out, gpa, evidence.bindings.oliver_pin);
    try out.appendSlice(gpa, ",\n    \"plan_sha256\": \"");
    for (evidence.plan_sha256) |byte| try out.append(gpa, byte);
    try out.appendSlice(gpa, "\"\n  },\n  \"records\": [");
    for (evidence.records, 0..) |record, index| {
        if (index > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "\n    {\n      \"at_uri\": ");
        try json_out.writeString(&out, gpa, record.at_uri);
        try out.appendSlice(gpa, ",\n      \"rkey\": ");
        try json_out.writeString(&out, gpa, record.rkey);
        try out.appendSlice(gpa, ",\n      \"intent\": ");
        try json_out.writeString(&out, gpa, record.intent.name());
        try out.appendSlice(gpa, ",\n      \"outcome\": ");
        try json_out.writeString(&out, gpa, record.outcome.name());
        try out.appendSlice(gpa, ",\n      \"verification\": ");
        try json_out.writeString(&out, gpa, record.verification.name());
        try out.appendSlice(gpa, ",\n      \"intended_payload_sha256\": \"");
        for (record.intended_payload_sha256) |byte| try out.append(gpa, byte);
        try out.appendSlice(gpa, "\",\n      \"observed_cid\": ");
        if (record.observed_cid) |cid| {
            try json_out.writeString(&out, gpa, cid);
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, ",\n      \"observed_at\": ");
        try json_out.writeString(&out, gpa, record.observed_at);
        try out.appendSlice(gpa, ",\n      \"failure\": ");
        if (record.failure) |failure| {
            try json_out.writeString(&out, gpa, failure);
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, "\n    }");
    }
    if (evidence.records.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "],\n  \"overall\": ");
    try json_out.writeString(&out, gpa, if (evidence.overall_passed) "passed" else "failed");
    try out.appendSlice(gpa, "\n}\n");
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const test_did_text = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const test_pds = "https://pds.example.com";
const test_cid = "bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4";

/// Deterministic offline PDS double. Stores records keyed by
/// `collection/rkey`, serves getRecord/putRecord/deleteRecord, and can be
/// scripted to reject, conflict, or time out writes so the reconciler's
/// failure classification is exercised without the network. Tracks request
/// counts so tests can assert zero writes for unchanged state.
const MockPds = struct {
    const Stored = struct {
        cid: []u8,
        /// Raw JSON object bytes of the record value, as stored.
        record: []u8,
    };

    allocator: std.mem.Allocator,
    records: std.StringHashMap(Stored),
    puts: usize = 0,
    deletes: usize = 0,
    gets: usize = 0,
    /// When set, the next putRecord fails with a transport error.
    fail_next_put: bool = false,
    /// When set, the next putRecord stores the record then fails with a
    /// transport error: an ambiguous write that actually landed.
    ambiguous_next_put: bool = false,
    /// When set, putRecord for this exact rkey returns 409 (conflict) and
    /// stores nothing. Used to exercise swap conflicts on a specific record.
    conflict_rkey: ?[]const u8 = null,
    /// When set, putRecord returns 400 (rejection) and stores nothing.
    reject_next_put: bool = false,
    /// Reject every put after this many successful puts (partial failure).
    reject_after: ?usize = null,
    /// When set, the next deleteRecord fails with a transport error.
    fail_next_delete: bool = false,
    /// When set, getRecord returns an error (network failure).
    fail_next_get: bool = false,

    fn init(allocator: std.mem.Allocator) MockPds {
        return .{ .allocator = allocator, .records = std.StringHashMap(Stored).init(allocator) };
    }

    fn deinit(self: *MockPds) void {
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.cid);
            self.allocator.free(entry.value_ptr.record);
        }
        self.records.deinit();
        self.* = undefined;
    }

    fn client(self: *MockPds) transport.Client {
        return .{ .context = self, .request_fn = request };
    }

    fn store(
        self: *MockPds,
        collection: []const u8,
        rkey: []const u8,
        record: []const u8,
        cid: []const u8,
    ) !void {
        const key = try mockKey(self.allocator, collection, rkey);
        errdefer self.allocator.free(key);
        const cid_owned = try self.allocator.dupe(u8, cid);
        errdefer self.allocator.free(cid_owned);
        const record_owned = try self.allocator.dupe(u8, record);
        errdefer self.allocator.free(record_owned);
        const gop = try self.records.getOrPut(key);
        if (gop.found_existing) {
            // Replace in place: free the prior key and values so an update
            // (e.g. seed then reconcile) never leaks the stale copies.
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.cid);
            self.allocator.free(gop.value_ptr.record);
        }
        gop.key_ptr.* = key;
        gop.value_ptr.* = .{ .cid = cid_owned, .record = record_owned };
    }

    /// Preseed a record so a fresh run observes it as existing.
    fn seed(self: *MockPds, collection: []const u8, rkey: []const u8, record: []const u8) !void {
        try self.store(collection, rkey, record, test_cid);
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: transport.Request,
    ) transport.Error!transport.Response {
        const self: *MockPds = @ptrCast(@alignCast(context));
        if (value.redirect_policy != .forbid) return error.UnexpectedRequest;

        var nonce_buf: [32]u8 = undefined;
        const nonce = std.fmt.bufPrint(&nonce_buf, "pds-nonce-{d}", .{self.gets + self.puts + self.deletes + 1}) catch unreachable;
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "dpop-nonce", .value = nonce },
        };

        if (std.mem.indexOf(u8, value.url, "/com.atproto.repo.getRecord?") != null) {
            self.gets += 1;
            if (self.fail_next_get) {
                self.fail_next_get = false;
                return error.Timeout;
            }
            const collection = queryParam(value.url, "collection") orelse return error.UnexpectedRequest;
            const rkey = queryParam(value.url, "rkey") orelse return error.UnexpectedRequest;
            const key = try mockKey(allocator, collection, rkey);
            defer allocator.free(key);
            if (self.records.get(key)) |stored| {
                const body = try mockGetBody(allocator, collection, rkey, stored.cid, stored.record);
                defer allocator.free(body);
                return transport.Response.initCopy(allocator, 200, &headers, body, value.limits);
            }
            const body = "{\"error\":\"RecordNotFound\"}";
            return transport.Response.initCopy(allocator, 400, &headers, body, value.limits);
        }

        if (std.mem.indexOf(u8, value.url, "/com.atproto.repo.putRecord") != null) {
            self.puts += 1;
            if (self.fail_next_put) {
                self.fail_next_put = false;
                return error.Timeout;
            }
            const collection = bodyField(value.body, "collection") orelse return error.UnexpectedRequest;
            const rkey = bodyField(value.body, "rkey") orelse return error.UnexpectedRequest;
            const record = recordField(value.body) orelse return error.UnexpectedRequest;
            const key = try mockKey(allocator, collection, rkey);
            defer allocator.free(key);

            if (self.reject_next_put) {
                self.reject_next_put = false;
                const body = "{\"error\":\"InvalidRecord\"}";
                return transport.Response.initCopy(allocator, 400, &headers, body, value.limits);
            }
            if (self.reject_after) |threshold| if (self.puts > threshold) {
                self.reject_after = null;
                const body = "{\"error\":\"InvalidRecord\"}";
                return transport.Response.initCopy(allocator, 400, &headers, body, value.limits);
            };
            if (self.conflict_rkey) |conflict| if (std.mem.eql(u8, conflict, rkey)) {
                const body = "{\"error\":\"SwapRecord\"}";
                return transport.Response.initCopy(allocator, 409, &headers, body, value.limits);
            };

            // Simulate compare-and-swap: an update must present the stored CID.
            if (self.records.get(key)) |stored| {
                const swap = bodyField(value.body, "swapRecord");
                if (swap == null or !std.mem.eql(u8, swap.?, stored.cid)) {
                    const body = "{\"error\":\"SwapRecord\"}";
                    return transport.Response.initCopy(allocator, 409, &headers, body, value.limits);
                }
            }

            var next_cid_buf: [64]u8 = undefined;
            const next_cid = std.fmt.bufPrint(&next_cid_buf, "bafyreicid{d:0>3}0000000000000000000000000000000000000000", .{self.puts}) catch unreachable;
            try self.store(collection, rkey, record, next_cid);
            if (self.ambiguous_next_put) {
                self.ambiguous_next_put = false;
                return error.Timeout;
            }
            const body = try mockPutBody(allocator, collection, rkey, next_cid);
            defer allocator.free(body);
            return transport.Response.initCopy(allocator, 200, &headers, body, value.limits);
        }

        if (std.mem.indexOf(u8, value.url, "/com.atproto.repo.deleteRecord") != null) {
            self.deletes += 1;
            if (self.fail_next_delete) {
                self.fail_next_delete = false;
                return error.Timeout;
            }
            const collection = bodyField(value.body, "collection") orelse return error.UnexpectedRequest;
            const rkey = bodyField(value.body, "rkey") orelse return error.UnexpectedRequest;
            const key = try mockKey(allocator, collection, rkey);
            defer allocator.free(key);
            if (self.records.get(key)) |stored| {
                const swap = bodyField(value.body, "swapRecord");
                if (swap == null or !std.mem.eql(u8, swap.?, stored.cid)) {
                    const body = "{\"error\":\"SwapRecord\"}";
                    return transport.Response.initCopy(allocator, 409, &headers, body, value.limits);
                }
                // Free the map-owned copies on delete so the mock never leaks
                // the pruned record's key, cid, or bytes.
                if (self.records.fetchRemove(key)) |removed| {
                    self.allocator.free(removed.key);
                    self.allocator.free(removed.value.cid);
                    self.allocator.free(removed.value.record);
                }
            } else {
                _ = self.records.remove(key);
            }
            const body = "{\"commit\":\"bafyreicidcommit\"}";
            return transport.Response.initCopy(allocator, 200, &headers, body, value.limits);
        }

        return error.UnexpectedRequest;
    }
};

/// `collection/rkey` store key, ArrayList-built (no allocPrint in an emitter).
fn mockKey(allocator: std.mem.Allocator, collection: []const u8, rkey: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, collection);
    try out.append(allocator, '/');
    try out.appendSlice(allocator, rkey);
    return out.toOwnedSlice(allocator);
}

/// getRecord 200 body, ArrayList-built.
fn mockGetBody(allocator: std.mem.Allocator, collection: []const u8, rkey: []const u8, cid: []const u8, record: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"uri\":\"at://");
    try out.appendSlice(allocator, test_did_text);
    try out.appendSlice(allocator, "/");
    try out.appendSlice(allocator, collection);
    try out.appendSlice(allocator, "/");
    try out.appendSlice(allocator, rkey);
    try out.appendSlice(allocator, "\",\"cid\":\"");
    try out.appendSlice(allocator, cid);
    try out.appendSlice(allocator, "\",\"value\":");
    try out.appendSlice(allocator, record);
    try out.appendSlice(allocator, ",\"validationStatus\":\"valid\"}");
    return out.toOwnedSlice(allocator);
}

/// putRecord 200 body, ArrayList-built.
fn mockPutBody(allocator: std.mem.Allocator, collection: []const u8, rkey: []const u8, cid: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"uri\":\"at://");
    try out.appendSlice(allocator, test_did_text);
    try out.appendSlice(allocator, "/");
    try out.appendSlice(allocator, collection);
    try out.appendSlice(allocator, "/");
    try out.appendSlice(allocator, rkey);
    try out.appendSlice(allocator, "\",\"cid\":\"");
    try out.appendSlice(allocator, cid);
    try out.appendSlice(allocator, "\",\"validationStatus\":\"valid\"}");
    return out.toOwnedSlice(allocator);
}

fn queryParam(url: []const u8, name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, url, name) orelse return null;
    const value_start = start + name.len;
    if (value_start >= url.len or url[value_start] != '=') return null;
    const value_end = std.mem.indexOfScalarPos(u8, url, value_start + 1, '&') orelse url.len;
    return url[value_start + 1 .. value_end];
}

/// Pull a top-level string field out of a JSON request body. Fields of
/// interest (`collection`, `rkey`, `swapRecord`) are flat quoted strings; the
/// mock only needs these, and escapes are not expected in test values.
fn bodyField(body: []const u8, name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, name) orelse return null;
    // Expect exactly `"name":"value"`: closing quote of the key, colon,
    // optional whitespace, opening quote of the value.
    var cursor = start + name.len;
    if (cursor >= body.len or body[cursor] != '"') return null;
    cursor += 1;
    if (cursor >= body.len or body[cursor] != ':') return null;
    cursor += 1;
    while (cursor < body.len and body[cursor] == ' ') cursor += 1;
    if (cursor >= body.len or body[cursor] != '"') return null;
    cursor += 1;
    const value_start = cursor;
    while (cursor < body.len and body[cursor] != '"') {
        if (body[cursor] == '\\') cursor += 1;
        cursor += 1;
    }
    if (cursor >= body.len) return null;
    return body[value_start..cursor];
}

/// Extract the raw record object bytes from a putRecord body. The body is
/// `{"repo":…,"collection":…,"rkey":…[,"swapRecord":…],"record":{…}}`, so the
/// record object is the slice from the first `{` after `"record":` to the
/// last `}`. Stored raw so the mock round-trips the exact record bytes.
fn recordField(body: []const u8) ?[]const u8 {
    const marker = "\"record\":";
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    var cursor = start + marker.len;
    while (cursor < body.len and body[cursor] == ' ') cursor += 1;
    if (cursor >= body.len or body[cursor] != '{') return null;
    const object_start = cursor;
    var depth: usize = 0;
    var in_string = false;
    while (cursor < body.len) : (cursor += 1) {
        const byte = body[cursor];
        if (in_string) {
            if (byte == '\\') {
                cursor += 1;
            } else if (byte == '"') {
                in_string = false;
            }
        } else switch (byte) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return body[object_start .. cursor + 1];
            },
            else => {},
        }
    }
    return null;
}

const TestProofSource = struct {
    next_value: u8 = 1,

    fn source(self: *TestProofSource) authorization.ProofSource {
        return .{ .context = self, .next_fn = next };
    }

    fn next(context: *anyopaque) authorization.Error!authorization.ProofMaterial {
        const self: *TestProofSource = @ptrCast(@alignCast(context));
        const value = self.next_value;
        self.next_value +%= 1;
        return .{
            .issued_at = 1_700_000_000 + @as(u64, value),
            .jti_entropy = @splat(value),
            .signing_noise = @splat(value),
        };
    }
};

fn testBinding() !xrpc.SessionBinding {
    return .{
        .did = try identity.Did.parse(test_did_text),
        .pds_origin = try identity.Origin.parse(test_pds),
        .key_pair = try oauth.keyPairFromEntropy(@splat(7)),
        .access_token = "access-token",
    };
}



/// Build a config with a pds binding, project two pages, and render the plan.
const TestSetup = struct {
    config: standard_site.TargetConfig,
    projection: standard_site.Projection,
    surfaces: standard_site.VerificationSurfaces,
    plan: []u8,
    digest: [64]u8,
    page_inputs: [3]standard_site.PageInput,

    fn init(gpa: std.mem.Allocator) !TestSetup {
        var config: standard_site.TargetConfig = .{
            .location = try standard_site.parseLocation(gpa, "https://example.com", "https://example.com", ""),
            .did = try gpa.dupe(u8, test_did_text),
            .pds_origin = try gpa.dupe(u8, test_pds),
        };
        errdefer config.deinit(gpa);
        const page_inputs = [3]standard_site.PageInput{
            .{ .entity_id = "guides/intro", .output_path = "guides/intro.html", .title = "Intro", .status = .published, .published_at = "2024-01-20T14:30:00Z", .summary = "The intro", .tags = &.{ "guide", "zig" } },
            .{ .entity_id = "reference/api", .output_path = "reference/api.html", .title = "API", .status = .published, .published_at = "2024-02-01T09:00:00Z", .summary = "The API" },
            // A draft: excluded from the projection, so its deterministic rkey
            // (`old:page`) is the orphan surface exercised by the prune test.
            .{ .entity_id = "old/page", .output_path = "old/page.html", .title = "Old", .status = .draft },
        };
        var projection = try standard_site.project(gpa, .{
            .config = &config,
            .site_title = "Boris",
            .pages = &page_inputs,
        });
        errdefer projection.deinit(gpa);
        const surfaces = try standard_site.verificationSurfaces(gpa, &config, &projection);
        errdefer {
            gpa.free(surfaces.well_known.content);
            if (surfaces.well_known.project_path) |path| gpa.free(path);
            gpa.free(surfaces.well_known.required_public_url);
            for (surfaces.document_links) |link| {
                gpa.free(link.page);
                gpa.free(link.href);
            }
            gpa.free(surfaces.document_links);
        }
        const plan = try standard_site.renderPlan(gpa, &config, &projection, &surfaces);
        errdefer gpa.free(plan);
        return .{
            .config = config,
            .projection = projection,
            .surfaces = surfaces,
            .plan = plan,
            .digest = sha256HexLower(plan),
            .page_inputs = page_inputs,
        };
    }

    fn deinit(self: *TestSetup, gpa: std.mem.Allocator) void {
        gpa.free(self.plan);
        gpa.free(self.surfaces.well_known.content);
        if (self.surfaces.well_known.project_path) |path| gpa.free(path);
        gpa.free(self.surfaces.well_known.required_public_url);
        for (self.surfaces.document_links) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        gpa.free(self.surfaces.document_links);
        self.projection.deinit(gpa);
        self.config.deinit(gpa);
        self.* = undefined;
    }
};

const test_observed_at = "2026-08-15T00:00:00.000Z";
const test_bindings = Bindings{
    .source_commit = "0123456789abcdef",
    .boris_pin = "boris@1.2.3",
    .oliver_pin = "oliver@42cf472",
};

fn runReconcile(
    gpa: std.mem.Allocator,
    setup: *const TestSetup,
    mock: *MockPds,
    prune: bool,
) !Evidence {
    var proofs = TestProofSource{};
    var client = xrpc.SessionClient.init(try testBinding(), mock.client(), proofs.source());
    return reconcile(
        gpa,
        &setup.config,
        &setup.projection,
        setup.plan,
        setup.digest,
        &client,
        prune,
        test_bindings,
        test_observed_at,
    );
}

test "fresh PDS: publication and documents are created with exact payloads" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();

    var evidence = try runReconcile(gpa, &setup, &mock, false);
    defer evidence.deinit(gpa);

    try std.testing.expect(evidence.overall_passed);
    try std.testing.expectEqual(@as(usize, 3), evidence.records.len);
    try std.testing.expectEqual(@as(usize, 3), mock.puts);
    try std.testing.expectEqual(@as(usize, 0), mock.deletes);

    // Publication first, then documents, each created with a write response.
    try std.testing.expectEqual(Outcome.created, evidence.records[0].outcome);
    try std.testing.expectEqual(Intent.create, evidence.records[0].intent);
    try std.testing.expectEqual(Verification.write_response, evidence.records[0].verification);
    try std.testing.expectEqualStrings(
        "at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self",
        evidence.records[0].at_uri,
    );
    try std.testing.expectEqual(Outcome.created, evidence.records[1].outcome);
    try std.testing.expectEqualStrings("guides:intro", evidence.records[1].rkey);
    try std.testing.expectEqual(Outcome.created, evidence.records[2].outcome);
    try std.testing.expectEqualStrings("reference:api", evidence.records[2].rkey);

    // The stored record bytes match the intended payload exactly.
    const stored = mock.records.get("site.standard.publication/self").?;
    try std.testing.expectEqualStrings(setup.projection.publication.payload, stored.record);

    // Evidence binds identity, plan digest, and the source pins, and the
    // intended payload digest is recorded per record.
    try std.testing.expectEqualStrings(test_did_text, evidence.did);
    try std.testing.expectEqualStrings(test_pds, evidence.pds_origin);
    try std.testing.expectEqualStrings(&setup.digest, &evidence.plan_sha256);
    try std.testing.expectEqualStrings(
        &setup.projection.publication.payload_sha256,
        &evidence.records[0].intended_payload_sha256,
    );
}

test "re-running against unchanged remote state performs zero writes" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();

    var first = try runReconcile(gpa, &setup, &mock, false);
    defer first.deinit(gpa);
    try std.testing.expect(first.overall_passed);
    try std.testing.expectEqual(@as(usize, 3), mock.puts);

    // A second run observes the records created by the first and must not
    // write a single byte.
    var second = try runReconcile(gpa, &setup, &mock, false);
    defer second.deinit(gpa);
    try std.testing.expect(second.overall_passed);
    try std.testing.expectEqual(@as(usize, 3), mock.puts);
    try std.testing.expectEqual(@as(usize, 6), mock.gets);
    for (second.records) |record| {
        try std.testing.expectEqual(Outcome.unchanged, record.outcome);
        try std.testing.expectEqual(Verification.observed, record.verification);
    }
}

test "remote drift triggers an update with compare-and-swap on the observed CID" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    // Remote has an older title; the reconciler must update it.
    try mock.seed(
        "site.standard.document",
        "guides:intro",
        "{\"site\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self\",\"title\":\"Old Intro\",\"publishedAt\":\"2024-01-20T14:30:00.000Z\",\"path\":\"/guides/intro.html\",\"description\":\"The intro\"}",
    );

    var evidence = try runReconcile(gpa, &setup, &mock, false);
    defer evidence.deinit(gpa);

    try std.testing.expect(evidence.overall_passed);
    // Publication and the API document are created; the intro is updated.
    try std.testing.expectEqual(@as(usize, 3), mock.puts);
    const intro = for (evidence.records) |record| {
        if (std.mem.eql(u8, record.rkey, "guides:intro")) break &record;
    } else unreachable;
    try std.testing.expectEqual(Intent.update, intro.intent);
    try std.testing.expectEqual(Outcome.updated, intro.outcome);
    try std.testing.expectEqual(Verification.write_response, intro.verification);
}

test "swap conflict fails closed and never overwrites the remote value" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    // Remote holds a different record than intended; the swap will mismatch.
    try mock.seed(
        "site.standard.document",
        "guides:intro",
        "{\"site\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self\",\"title\":\"Concurrent\",\"publishedAt\":\"2024-03-01T00:00:00.000Z\",\"path\":\"/guides/intro.html\"}",
    );
    mock.conflict_rkey = "guides:intro";

    var evidence = try runReconcile(gpa, &setup, &mock, false);
    defer evidence.deinit(gpa);

    try std.testing.expect(!evidence.overall_passed);
    const intro = for (evidence.records) |record| {
        if (std.mem.eql(u8, record.rkey, "guides:intro")) break &record;
    } else unreachable;
    try std.testing.expectEqual(Outcome.failed, intro.outcome);
    try std.testing.expectEqual(Verification.not_verified, intro.verification);
    try std.testing.expect(intro.failure != null);
    // The remote value is untouched.
    const stored = mock.records.get("site.standard.document/guides:intro").?;
    try std.testing.expect(std.mem.indexOf(u8, stored.record, "Concurrent") != null);
}

test "rejection leaves no record and records the exact failure" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    mock.reject_next_put = true;

    var evidence = try runReconcile(gpa, &setup, &mock, false);
    defer evidence.deinit(gpa);

    try std.testing.expect(!evidence.overall_passed);
    const publication = &evidence.records[0];
    try std.testing.expectEqual(Outcome.failed, publication.outcome);
    try std.testing.expectEqualStrings("InvalidStatus", publication.failure.?);
    try std.testing.expect(mock.records.get("site.standard.publication/self") == null);
}

test "ambiguous write timeout is never success without a confirming read" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    // The put actually lands server-side, but the response is lost. Only the
    // confirming read may report success — with confirming_read verification.
    mock.ambiguous_next_put = true;

    var evidence = try runReconcile(gpa, &setup, &mock, false);
    defer evidence.deinit(gpa);

    try std.testing.expect(evidence.overall_passed);
    try std.testing.expectEqual(Outcome.created, evidence.records[0].outcome);
    try std.testing.expectEqual(Verification.confirming_read, evidence.records[0].verification);
    // getRecord happened: initial probe + confirming read + two document reads.
    try std.testing.expectEqual(@as(usize, 4), mock.gets);
}

test "a write timeout that did not land reports failed, never success" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    // The put never lands; the confirming read sees nothing.
    mock.fail_next_put = true;

    var evidence = try runReconcile(gpa, &setup, &mock, false);
    defer evidence.deinit(gpa);

    try std.testing.expect(!evidence.overall_passed);
    try std.testing.expectEqual(Outcome.failed, evidence.records[0].outcome);
    try std.testing.expectEqual(Verification.not_verified, evidence.records[0].verification);
    try std.testing.expectEqualStrings("Timeout", evidence.records[0].failure.?);
}

test "partial failure: one rejected document fails overall but others still write" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    // The publication and the second document succeed; the first document
    // write is rejected. The run must continue and report nonzero overall.
    mock.reject_next_put = false;
    // Reject the first document put (publication put is first, then docs).
    mock.reject_after = 1;

    var evidence = try runReconcile(gpa, &setup, &mock, false);
    defer evidence.deinit(gpa);

    try std.testing.expect(!evidence.overall_passed);
    try std.testing.expectEqual(Outcome.created, evidence.records[0].outcome);
    try std.testing.expectEqual(Outcome.failed, evidence.records[1].outcome);
    try std.testing.expectEqual(Outcome.created, evidence.records[2].outcome);
    try std.testing.expectEqual(@as(usize, 3), mock.puts);
}

test "orphans are skipped without prune and pruned only with explicit authority" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    // A remote record exists for an entity that is now a draft (excluded).
    try mock.seed(
        "site.standard.document",
        "old:page",
        "{\"site\":\"at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/site.standard.publication/self\",\"title\":\"Old\",\"publishedAt\":\"2024-01-01T00:00:00.000Z\",\"path\":\"/old/page.html\"}",
    );

    // Without prune authority the orphan is skipped; nothing is deleted.
    var skipped = try runReconcile(gpa, &setup, &mock, false);
    defer skipped.deinit(gpa);
    try std.testing.expect(skipped.overall_passed);
    try std.testing.expectEqual(@as(usize, 0), mock.deletes);

    // With explicit prune the orphan is deleted with a swap on its CID.
    var pruned = try runReconcile(gpa, &setup, &mock, true);
    defer pruned.deinit(gpa);
    try std.testing.expect(pruned.overall_passed);
    try std.testing.expectEqual(@as(usize, 1), mock.deletes);
    try std.testing.expect(mock.records.get("site.standard.document/old:page") == null);
}

test "session DID mismatch fails closed before any request" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var binding = try testBinding();
    // Mutate the DID to a different account.
    binding.did = try identity.Did.parse("did:plc:otherxxxxxxxxxxxxxxxxxxx");
    var client = xrpc.SessionClient.init(binding, mock.client(), proofs.source());

    try std.testing.expectError(error.SessionDidMismatch, reconcile(
        gpa,
        &setup.config,
        &setup.projection,
        setup.plan,
        setup.digest,
        &client,
        false,
        test_bindings,
        test_observed_at,
    ));
    try std.testing.expectEqual(@as(usize, 0), mock.gets);
    try std.testing.expectEqual(@as(usize, 0), mock.puts);
    try std.testing.expectEqual(@as(usize, 0), mock.deletes);
}

test "session PDS mismatch fails closed before any request" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var binding = try testBinding();
    binding.pds_origin = try identity.Origin.parse("https://other-pds.example.com");
    var client = xrpc.SessionClient.init(binding, mock.client(), proofs.source());

    try std.testing.expectError(error.SessionPdsMismatch, reconcile(
        gpa,
        &setup.config,
        &setup.projection,
        setup.plan,
        setup.digest,
        &client,
        false,
        test_bindings,
        test_observed_at,
    ));
    try std.testing.expectEqual(@as(usize, 0), mock.gets);
}

test "plan digest mismatch fails closed before any request" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();
    var proofs = TestProofSource{};
    var client = xrpc.SessionClient.init(try testBinding(), mock.client(), proofs.source());

    var wrong_digest = setup.digest;
    wrong_digest[0] = if (wrong_digest[0] == '0') '1' else '0';
    try std.testing.expectError(error.PlanDigestMismatch, reconcile(
        gpa,
        &setup.config,
        &setup.projection,
        setup.plan,
        wrong_digest,
        &client,
        false,
        test_bindings,
        test_observed_at,
    ));
    try std.testing.expectEqual(@as(usize, 0), mock.gets);
}

test "evidence renders deterministically with intended and observed as separate claims" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockPds.init(gpa);
    defer mock.deinit();

    var evidence = try runReconcile(gpa, &setup, &mock, false);
    defer evidence.deinit(gpa);
    const rendered = try renderEvidence(gpa, &evidence);
    defer gpa.free(rendered);
    const rendered_again = try renderEvidence(gpa, &evidence);
    defer gpa.free(rendered_again);
    try std.testing.expectEqualStrings(rendered, rendered_again);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"format\": \"boris-standard-site-evidence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"intent\": \"create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"outcome\": \"created\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"verification\": \"write_response\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"overall\": \"passed\"") != null);

    // Secrets never enter the evidence.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "access_token") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "refresh") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "proof") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "secret") == null);
}
