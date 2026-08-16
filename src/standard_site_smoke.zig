//! Standard.site live interoperability smoke: a manual, opt-in, bounded gate
//! that proves discovery, OAuth, XRPC writes, readback, and cleanup against a
//! real PDS without making public-network availability part of unit CI.
//!
//! The module owns the ordering and the fail-closed gates, not the host
//! capabilities: the caller injects the bounded transport, the DPoP proof
//! source, the session provider (persistent store then interactive browser,
//! exactly as publish uses), and a wall clock. Every created record uses a
//! unique `boris-smoke-<…>` namespace and is read back before success is
//! claimed; cleanup deletes only the two rkeys created by this run, so it can
//! never prune unrelated records. Indexer observation is recorded but is never
//! part of the pass/fail decision.
//!
//! The live path is reachable only through `boris standard-site smoke`; no
//! test or CI step invokes it. The offline tests below drive a scripted
//! discovery + OAuth + PDS double, so the ordinary offline matrix stays
//! authoritative.

const std = @import("std");
const json_out = @import("json_out.zig");
const identity = @import("atproto_identity.zig");
const authorization = @import("atproto_authorization.zig");
const transport = @import("atproto_transport.zig");
const xrpc = @import("atproto_xrpc.zig");
const publish = @import("standard_site_publish.zig");

pub const collection_publication = "site.standard.publication";
pub const collection_document = "site.standard.document";
pub const well_known_suffix = ".well-known/site.standard.publication";

/// Error surface. The session provider is shared with `standard_site_publish`,
/// so its error set is carried verbatim; the smoke adds its own precondition
/// and configuration failures.
pub const Error = publish.Error || error{
    InvalidWallClock,
    NamespaceCollision,
    InvalidNamespace,
    InvalidSiteUrl,
    InvalidIndexerOrigin,
};

/// The specification revisions this smoke exercises. These are the recorded
/// retrieval dates of the ATProto and Standard.site contracts in
/// `docs/contracts/atproto-oauth.md`; the smoke result names them so a release
/// or PR can state exactly which spec baseline was tested.
pub const spec_baseline = [_][]const u8{
    "AT Protocol DID — retrieved 2026-08-14",
    "AT Protocol OAuth — retrieved 2026-08-15",
    "AT Protocol Handle — retrieved 2026-08-14",
    "AT Protocol HTTP API/XRPC — retrieved 2026-08-14",
    "RFC 9728 (OAuth 2.0 Protected Resource Metadata), April 2025",
    "RFC 9449 (OAuth 2.0 Demonstrating Proof of Possession), September 2023",
    "Standard.site permission contract — retrieved 2026-08-15",
};

/// Host capabilities for one smoke invocation. Identical in shape to the
/// publish runtime so the CLI reuses the same session provider.
pub const Runtime = struct {
    io: std.Io,
    client: transport.Client,
    proofs: authorization.ProofSource,
    session_ctx: *anyopaque,
    session_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        client: transport.Client,
        account: identity.DiscoveredAccount,
    ) Error!publish.AcquiredSession,
    /// Epoch seconds; used to derive the unique run namespace.
    now_fn: *const fn (std.Io) i64,
};

/// Operator inputs. Everything is a flag; no credential, account, or origin is
/// hard-coded.
pub const Config = struct {
    did: []const u8,
    /// Optional operator-provided namespace prefix for the test rkeys. When
    /// absent, the namespace is derived from the wall clock.
    namespace: ?[]const u8 = null,
    /// Optional stable fixture site origin whose served well-known verification
    /// surface is checked (`https://<origin>/.well-known/site.standard.publication`).
    site_url: ?[]const u8 = null,
    /// Optional indexer/AppView origin observed non-normatively after cleanup
    /// eligibility. Its lag or failure never affects the overall result.
    indexer_origin: ?[]const u8 = null,
    boris_pin: []const u8,
    oliver_pin: []const u8,
};

pub const StepStatus = enum { passed, failed, skipped, observed, lagged };

/// One created record's write outcome.
pub const WriteStep = struct {
    rkey: []u8,
    at_uri: ?[]u8,
    cid: ?[]u8,
    status: StepStatus,
    failure: ?[]u8,

    fn deinit(self: *WriteStep, gpa: std.mem.Allocator) void {
        gpa.free(self.rkey);
        if (self.at_uri) |value| gpa.free(value);
        if (self.cid) |value| gpa.free(value);
        if (self.failure) |value| gpa.free(value);
        self.* = undefined;
    }
};

/// One record's readback outcome. The XRPC client already validates the bound
/// AT-URI and CID shape; these flags record the smoke's own identity and value
/// comparison so the result is explicit about what was verified.
pub const ReadbackStep = struct {
    status: StepStatus,
    at_uri_matches: bool,
    value_matches: bool,
    cid_present: bool,
    cid: ?[]u8,
    failure: ?[]u8,

    fn deinit(self: *ReadbackStep, gpa: std.mem.Allocator) void {
        if (self.cid) |value| gpa.free(value);
        if (self.failure) |value| gpa.free(value);
        self.* = undefined;
    }
};

/// A bounded optional check: verification surface or indexer observation.
pub const OptionalCheck = struct {
    status: StepStatus,
    note: []u8,

    fn deinit(self: *OptionalCheck, gpa: std.mem.Allocator) void {
        gpa.free(self.note);
        self.* = undefined;
    }
};

/// The complete smoke outcome, rendered deterministically. All strings are
/// allocator-owned; nothing here is a secret (no token, proof, or nonce).
pub const SmokeResult = struct {
    namespace: []u8,
    did: []u8,
    pds_origin: []u8,
    authorization_server_origin: []u8,
    boris_pin: []u8,
    oliver_pin: []u8,
    publication: WriteStep,
    document: WriteStep,
    readback_publication: ReadbackStep,
    readback_document: ReadbackStep,
    surface: OptionalCheck,
    indexer: OptionalCheck,
    cleanup_status: StepStatus,
    cleaned_publication: bool,
    cleaned_document: bool,
    overall_passed: bool,

    pub fn deinit(self: *SmokeResult, gpa: std.mem.Allocator) void {
        gpa.free(self.namespace);
        gpa.free(self.did);
        gpa.free(self.pds_origin);
        gpa.free(self.authorization_server_origin);
        gpa.free(self.boris_pin);
        gpa.free(self.oliver_pin);
        self.publication.deinit(gpa);
        self.document.deinit(gpa);
        self.readback_publication.deinit(gpa);
        self.readback_document.deinit(gpa);
        self.surface.deinit(gpa);
        self.indexer.deinit(gpa);
        self.* = undefined;
    }
};

/// One smoke pass. Ordering is fixed:
///
/// 1. Resolve the configured DID and discover PDS, Resource Server, and
///    Authorization Server metadata (read-only GETs).
/// 2. Obtain a session (stored then interactive) and verify its DID, PDS, and
///    authorization server match the discovery result — a mismatch fails
///    closed before any write.
/// 3. Derive a unique namespace and refuse to continue if either target rkey
///    already exists, so a previous run is never overwritten.
/// 4. Write a test publication + document pair, read both back, and verify
///    identity, CID presence, and record values.
/// 5. Optionally check the served verification surface and observe an indexer
///    (both recorded, indexer non-normative).
/// 6. Delete exactly the two created rkeys and record what was cleaned.
///
/// Discovery and authorization failures abort with an error (the CLI maps them
/// to exit codes); per-phase write/readback/cleanup outcomes are recorded in
/// the returned result so cleanup still runs after a partial write.
pub fn smoke(gpa: std.mem.Allocator, runtime: *const Runtime, config: *const Config) Error!SmokeResult {
    var account = try identity.discover(gpa, runtime.client, config.did);

    var session = try runtime.session_fn(runtime.session_ctx, gpa, runtime.io, runtime.client, account);
    defer session.deinit();

    // A persisted session is bound to the authority facts recorded at login;
    // if the account has since moved PDS (or authorization server, for OAuth),
    // the stored session is no longer safe to reuse and must never touch the
    // network.
    if (!publish.sessionMatchesAccount(&session, account)) return error.SessionAuthorityChanged;

    const seconds = runtime.now_fn(runtime.io);
    if (seconds < 0) return error.InvalidWallClock;

    const namespace = try buildNamespace(gpa, config.namespace, seconds);
    errdefer gpa.free(namespace);
    const publication_rkey = try joinParts(gpa, &.{ namespace, "-publication" });
    defer gpa.free(publication_rkey);
    const document_rkey = try joinParts(gpa, &.{ namespace, "-document" });
    defer gpa.free(document_rkey);
    xrpc.validateRkey(publication_rkey) catch return error.InvalidNamespace;
    xrpc.validateRkey(document_rkey) catch return error.InvalidNamespace;

    const did = account.did.slice();
    const publication_at_uri = try xrpc.buildAtUri(gpa, did, collection_publication, publication_rkey);
    defer gpa.free(publication_at_uri);
    const document_at_uri = try xrpc.buildAtUri(gpa, did, collection_document, document_rkey);
    defer gpa.free(document_at_uri);

    var client = publish.sessionClient(&session, runtime.client, runtime.proofs);

    // Fail closed if the unique namespace already exists, so a re-run can
    // never overwrite records it did not create.
    const publication_precheck = try client.getRecord(gpa, collection_publication, publication_rkey);
    switch (publication_precheck) {
        .found => |response| {
            var found = response;
            found.deinit();
            return error.NamespaceCollision;
        },
        .not_found => {},
    }
    const document_precheck = try client.getRecord(gpa, collection_document, document_rkey);
    switch (document_precheck) {
        .found => |response| {
            var found = response;
            found.deinit();
            return error.NamespaceCollision;
        },
        .not_found => {},
    }

    const publication_record = try gpa.dupe(u8, "{\"url\":\"https://example.com/\",\"name\":\"boris-live-smoke\",\"preferences\":{\"showInDiscover\":false}}");
    defer gpa.free(publication_record);
    const document_record = try buildDocumentRecord(gpa, publication_at_uri);
    defer gpa.free(document_record);

    var publication = try writeOne(gpa, &client, collection_publication, publication_rkey, publication_record);
    errdefer publication.deinit(gpa);
    var document = try writeOne(gpa, &client, collection_document, document_rkey, document_record);
    errdefer document.deinit(gpa);

    var readback_publication = try readbackOne(gpa, &client, collection_publication, publication_rkey, publication_at_uri, publication_record, publication.status);
    errdefer readback_publication.deinit(gpa);
    var readback_document = try readbackOne(gpa, &client, collection_document, document_rkey, document_at_uri, document_record, document.status);
    errdefer readback_document.deinit(gpa);

    var surface = try checkSurface(gpa, runtime, config.site_url);
    errdefer surface.deinit(gpa);
    var indexer = try observeIndexer(gpa, runtime, config.indexer_origin, did, collection_document, document_rkey, document_at_uri);
    errdefer indexer.deinit(gpa);

    var cleanup = Cleanup{ .publication = false, .document = false };
    var cleanup_failed = false;
    if (publication.status == .passed) {
        if (client.deleteRecord(gpa, collection_publication, publication_rkey, null)) |result| {
            var delete_result = result;
            delete_result.deinit();
            cleanup.publication = true;
        } else |_| {
            cleanup_failed = true;
        }
    }
    if (document.status == .passed) {
        if (client.deleteRecord(gpa, collection_document, document_rkey, null)) |result| {
            var delete_result = result;
            delete_result.deinit();
            cleanup.document = true;
        } else |_| {
            cleanup_failed = true;
        }
    }
    var cleanup_status: StepStatus = .passed;
    if (cleanup_failed) {
        cleanup_status = .failed;
    } else if (publication.status != .passed and document.status != .passed) {
        cleanup_status = .skipped;
    }

    const overall = publication.status == .passed and
        document.status == .passed and
        readback_publication.status == .passed and
        readback_document.status == .passed and
        (surface.status == .skipped or surface.status == .passed) and
        cleanup_status == .passed;

    return .{
        .namespace = namespace,
        .did = try gpa.dupe(u8, did),
        .pds_origin = try gpa.dupe(u8, account.pds_origin.slice()),
        .authorization_server_origin = try gpa.dupe(u8, account.authorization_server_origin.slice()),
        .boris_pin = try gpa.dupe(u8, config.boris_pin),
        .oliver_pin = try gpa.dupe(u8, config.oliver_pin),
        .publication = publication,
        .document = document,
        .readback_publication = readback_publication,
        .readback_document = readback_document,
        .surface = surface,
        .indexer = indexer,
        .cleanup_status = cleanup_status,
        .cleaned_publication = cleanup.publication,
        .cleaned_document = cleanup.document,
        .overall_passed = overall,
    };
}

const Cleanup = struct {
    publication: bool,
    document: bool,
};

fn buildNamespace(gpa: std.mem.Allocator, configured: ?[]const u8, seconds: i64) Error![]u8 {
    if (configured) |namespace| {
        if (namespace.len == 0 or namespace.len > xrpc.max_rkey_bytes) return error.InvalidNamespace;
        return gpa.dupe(u8, namespace);
    }
    const value: u64 = @intCast(seconds);
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "boris-smoke-{d}", .{value}) catch unreachable;
    return gpa.dupe(u8, text);
}

/// Concatenate already-safe byte slices into one owned buffer. No formatting,
/// so no value is ever re-encoded; each part is either a validated identifier,
/// a constant, or an escaped string from json_out.
fn joinParts(gpa: std.mem.Allocator, parts: []const []const u8) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (parts) |part| try buf.appendSlice(gpa, part);
    return buf.toOwnedSlice(gpa);
}

/// Build the test document record payload through json_out so the AT-URI is
/// escaped like every other JSON string value.
fn buildDocumentRecord(gpa: std.mem.Allocator, at_uri: []const u8) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\"site\":");
    try json_out.writeString(&buf, gpa, at_uri);
    try buf.appendSlice(gpa, ",\"title\":\"boris-live-smoke\",\"publishedAt\":\"2024-01-20T14:30:00.000Z\",\"path\":\"/boris-smoke.html\"}");
    return buf.toOwnedSlice(gpa);
}

fn writeOne(
    gpa: std.mem.Allocator,
    client: *xrpc.SessionClient,
    collection: []const u8,
    rkey: []const u8,
    record: []const u8,
) Error!WriteStep {
    var result = client.putRecord(gpa, collection, rkey, record, null) catch |err| {
        return .{
            .rkey = try gpa.dupe(u8, rkey),
            .at_uri = null,
            .cid = null,
            .status = .failed,
            .failure = try gpa.dupe(u8, @errorName(err)),
        };
    };
    defer result.deinit();
    return .{
        .rkey = try gpa.dupe(u8, rkey),
        .at_uri = try gpa.dupe(u8, result.uri),
        .cid = try gpa.dupe(u8, result.cid),
        .status = .passed,
        .failure = null,
    };
}

fn readbackOne(
    gpa: std.mem.Allocator,
    client: *xrpc.SessionClient,
    collection: []const u8,
    rkey: []const u8,
    at_uri: []const u8,
    record: []const u8,
    write_status: StepStatus,
) Error!ReadbackStep {
    if (write_status != .passed) {
        return .{
            .status = .skipped,
            .at_uri_matches = false,
            .value_matches = false,
            .cid_present = false,
            .cid = null,
            .failure = try gpa.dupe(u8, "record was not written"),
        };
    }
    const result = client.getRecord(gpa, collection, rkey) catch |err| {
        return .{
            .status = .failed,
            .at_uri_matches = false,
            .value_matches = false,
            .cid_present = false,
            .cid = null,
            .failure = try gpa.dupe(u8, @errorName(err)),
        };
    };
    var found = switch (result) {
        .found => |response| response,
        .not_found => {
            return .{
                .status = .failed,
                .at_uri_matches = false,
                .value_matches = false,
                .cid_present = false,
                .cid = null,
                .failure = try gpa.dupe(u8, "record not found on readback"),
            };
        },
    };
    defer found.deinit();

    const at_uri_matches = std.mem.eql(u8, found.uri, at_uri);
    const value_matches = try remoteValueMatches(gpa, found.value.value, record);
    const cid_present = found.cid != null;
    const cid = if (found.cid) |cid| try gpa.dupe(u8, cid) else null;
    const passed = at_uri_matches and value_matches and cid_present;
    return .{
        .status = if (passed) .passed else .failed,
        .at_uri_matches = at_uri_matches,
        .value_matches = value_matches,
        .cid_present = cid_present,
        .cid = cid,
        .failure = if (passed) null else try gpa.dupe(u8, "readback mismatch"),
    };
}

/// Compare the fetched record value against the intended payload bytes,
/// key-order-insensitive, using only the `value` member of the getRecord
/// response.
fn remoteValueMatches(gpa: std.mem.Allocator, root: std.json.Value, intended_payload: []const u8) Error!bool {
    if (root != .object) return false;
    const record_value = root.object.get("value") orelse return false;
    if (intended_payload.len == 0) return false;
    var intended = std.json.parseFromSlice(std.json.Value, gpa, intended_payload, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = 16 * 1024,
        .allocate = .alloc_always,
    }) catch return false;
    defer intended.deinit();
    return jsonValuesEqual(record_value, intended.value);
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

fn checkSurface(gpa: std.mem.Allocator, runtime: *const Runtime, site_url: ?[]const u8) Error!OptionalCheck {
    const configured = site_url orelse return .{ .status = .skipped, .note = try gpa.dupe(u8, "no --surface-url configured") };
    const origin = identity.Origin.parse(configured) catch return error.InvalidSiteUrl;
    const url = try joinParts(gpa, &.{ origin.slice(), "/", well_known_suffix });
    defer gpa.free(url);

    var response = runtime.client.request(gpa, .{
        .method = .get,
        .url = url,
        .headers = &.{.{ .name = "accept", .value = "text/plain" }},
        .body = "",
        .redirect_policy = .forbid,
        .limits = .{ .max_body_bytes = 4096 },
    }) catch |err| {
        return .{ .status = .failed, .note = try joinParts(gpa, &.{ "well-known fetch failed: ", @errorName(err) }) };
    };
    defer response.deinit();
    if (response.status != 200) {
        var note: std.ArrayList(u8) = .empty;
        errdefer note.deinit(gpa);
        try note.appendSlice(gpa, "well-known returned status ");
        try json_out.writeUsize(&note, gpa, response.status);
        return .{ .status = .failed, .note = try note.toOwnedSlice(gpa) };
    }
    const body = std.mem.trim(u8, response.body, " \t\r\n");
    if (!std.mem.startsWith(u8, body, "at://") or
        std.mem.indexOf(u8, body, "/site.standard.publication/self") == null)
    {
        return .{ .status = .failed, .note = try gpa.dupe(u8, "well-known body is not a publication AT-URI") };
    }
    return .{ .status = .passed, .note = try joinParts(gpa, &.{ "served publication AT-URI ", body }) };
}

fn observeIndexer(
    gpa: std.mem.Allocator,
    runtime: *const Runtime,
    indexer_origin: ?[]const u8,
    did: []const u8,
    collection: []const u8,
    rkey: []const u8,
    at_uri: []const u8,
) Error!OptionalCheck {
    const configured = indexer_origin orelse return .{ .status = .skipped, .note = try gpa.dupe(u8, "no --indexer configured") };
    const origin = identity.Origin.parse(configured) catch return error.InvalidIndexerOrigin;
    const url = try joinParts(gpa, &.{ origin.slice(), "/xrpc/com.atproto.repo.getRecord?repo=", did, "&collection=", collection, "&rkey=", rkey });
    defer gpa.free(url);

    var response = runtime.client.request(gpa, .{
        .method = .get,
        .url = url,
        .headers = &.{.{ .name = "accept", .value = "application/json" }},
        .body = "",
        .redirect_policy = .forbid,
        .limits = .{ .max_body_bytes = xrpc.max_response_body_bytes },
    }) catch |err| {
        return .{ .status = .failed, .note = try joinParts(gpa, &.{ "indexer fetch failed: ", @errorName(err) }) };
    };
    defer response.deinit();
    if (response.status != 200) {
        var note: std.ArrayList(u8) = .empty;
        errdefer note.deinit(gpa);
        try note.appendSlice(gpa, "indexer has not indexed ");
        try note.appendSlice(gpa, at_uri);
        try note.appendSlice(gpa, " yet (status ");
        try json_out.writeUsize(&note, gpa, response.status);
        try note.appendSlice(gpa, ")");
        return .{ .status = .lagged, .note = try note.toOwnedSlice(gpa) };
    }
    // Non-normative: presence on the indexer is reported, never a success
    // requirement.
    return .{ .status = .observed, .note = try joinParts(gpa, &.{ "indexer observed ", at_uri }) };
}

/// Deterministic machine-readable result (`boris-live-smoke-result`, schema
/// v1). No secret ever appears here: only identity facts, the run namespace,
/// record identities, CIDs, and phase outcomes.
pub fn renderResult(gpa: std.mem.Allocator, result: *const SmokeResult) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try json_out.writeString(&buf, gpa, "schema");
    try buf.appendSlice(gpa, ": ");
    try json_out.writeString(&buf, gpa, "boris-live-smoke-result");
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try json_out.writeString(&buf, gpa, "schemaVersion");
    try buf.appendSlice(gpa, ": ");
    try json_out.writeUsize(&buf, gpa, 1);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try json_out.writeString(&buf, gpa, "overall");
    try buf.appendSlice(gpa, ": ");
    try json_out.writeString(&buf, gpa, if (result.overall_passed) "passed" else "failed");
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try json_out.writeString(&buf, gpa, "namespace");
    try buf.appendSlice(gpa, ": ");
    try json_out.writeString(&buf, gpa, result.namespace);
    try buf.appendSlice(gpa, ",\n");

    try writeField(&buf, gpa, 1, "client");
    try buf.appendSlice(gpa, "{\n");
    try writeStringField(&buf, gpa, 2, "boris", result.boris_pin);
    try buf.appendSlice(gpa, ",\n");
    try writeStringField(&buf, gpa, 2, "oliver", result.oliver_pin);
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "},\n");

    try writeField(&buf, gpa, 1, "server");
    try buf.appendSlice(gpa, "{\n");
    try writeStringField(&buf, gpa, 2, "did", result.did);
    try buf.appendSlice(gpa, ",\n");
    try writeStringField(&buf, gpa, 2, "pds", result.pds_origin);
    try buf.appendSlice(gpa, ",\n");
    try writeStringField(&buf, gpa, 2, "authorizationServer", result.authorization_server_origin);
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "},\n");

    try writeField(&buf, gpa, 1, "spec");
    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 2);
    try json_out.writeString(&buf, gpa, "baseline");
    try buf.appendSlice(gpa, ": [\n");
    for (spec_baseline, 0..) |revision, i| {
        try json_out.indent(&buf, gpa, 3);
        try json_out.writeString(&buf, gpa, revision);
        try buf.appendSlice(gpa, if (i + 1 < spec_baseline.len) ",\n" else "\n");
    }
    try json_out.indent(&buf, gpa, 2);
    try buf.appendSlice(gpa, "]\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "},\n");

    try writeField(&buf, gpa, 1, "phases");
    try buf.appendSlice(gpa, "{\n");
    try writeStringField(&buf, gpa, 2, "discovery", "passed");
    try buf.appendSlice(gpa, ",\n");
    try writeStringField(&buf, gpa, 2, "authorization", "passed");
    try buf.appendSlice(gpa, ",\n");

    try writeField(&buf, gpa, 2, "write");
    try buf.appendSlice(gpa, "{\n");
    try writeRecordStep(&buf, gpa, 3, "publication", &result.publication);
    try buf.appendSlice(gpa, ",\n");
    try writeRecordStep(&buf, gpa, 3, "document", &result.document);
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(&buf, gpa, 2);
    try buf.appendSlice(gpa, "},\n");

    try writeField(&buf, gpa, 2, "readback");
    try buf.appendSlice(gpa, "{\n");
    try writeReadbackStep(&buf, gpa, 3, "publication", &result.readback_publication);
    try buf.appendSlice(gpa, ",\n");
    try writeReadbackStep(&buf, gpa, 3, "document", &result.readback_document);
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(&buf, gpa, 2);
    try buf.appendSlice(gpa, "},\n");

    try writeOptionalField(&buf, gpa, 2, "verificationSurface", &result.surface);
    try buf.appendSlice(gpa, ",\n");
    try writeOptionalField(&buf, gpa, 2, "indexer", &result.indexer);
    try buf.appendSlice(gpa, ",\n");

    try writeField(&buf, gpa, 2, "cleanup");
    try buf.appendSlice(gpa, "{\n");
    try writeStringField(&buf, gpa, 3, "status", statusName(result.cleanup_status));
    try buf.appendSlice(gpa, ",\n");
    try writeBoolField(&buf, gpa, 3, "cleanedPublication", result.cleaned_publication);
    try buf.appendSlice(gpa, ",\n");
    try writeBoolField(&buf, gpa, 3, "cleanedDocument", result.cleaned_document);
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(&buf, gpa, 2);
    try buf.appendSlice(gpa, "}\n");

    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "}\n");
    try buf.appendSlice(gpa, "}\n");
    return buf.toOwnedSlice(gpa);
}

fn statusName(status: StepStatus) []const u8 {
    return switch (status) {
        .passed => "passed",
        .failed => "failed",
        .skipped => "skipped",
        .observed => "observed",
        .lagged => "lagged",
    };
}

fn writeField(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize, name: []const u8) Error!void {
    try json_out.indent(buf, gpa, level);
    try json_out.writeString(buf, gpa, name);
    try buf.appendSlice(gpa, ": ");
}

fn writeStringField(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize, name: []const u8, value: []const u8) Error!void {
    try writeField(buf, gpa, level, name);
    try json_out.writeString(buf, gpa, value);
}

fn writeBoolField(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize, name: []const u8, value: bool) Error!void {
    try writeField(buf, gpa, level, name);
    try json_out.writeBool(buf, gpa, value);
}

fn writeRecordStep(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize, name: []const u8, step: *const WriteStep) Error!void {
    try writeField(buf, gpa, level, name);
    try buf.appendSlice(gpa, "{\n");
    try writeStringField(buf, gpa, level + 1, "status", statusName(step.status));
    try buf.appendSlice(gpa, ",\n");
    try writeStringField(buf, gpa, level + 1, "rkey", step.rkey);
    if (step.at_uri) |at_uri| {
        try buf.appendSlice(gpa, ",\n");
        try writeStringField(buf, gpa, level + 1, "atUri", at_uri);
    }
    if (step.cid) |cid| {
        try buf.appendSlice(gpa, ",\n");
        try writeStringField(buf, gpa, level + 1, "cid", cid);
    }
    if (step.failure) |failure| {
        try buf.appendSlice(gpa, ",\n");
        try writeStringField(buf, gpa, level + 1, "failure", failure);
    }
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(buf, gpa, level);
    try buf.appendSlice(gpa, "}");
}

fn writeReadbackStep(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize, name: []const u8, step: *const ReadbackStep) Error!void {
    try writeField(buf, gpa, level, name);
    try buf.appendSlice(gpa, "{\n");
    try writeStringField(buf, gpa, level + 1, "status", statusName(step.status));
    try buf.appendSlice(gpa, ",\n");
    try writeBoolField(buf, gpa, level + 1, "atUriMatches", step.at_uri_matches);
    try buf.appendSlice(gpa, ",\n");
    try writeBoolField(buf, gpa, level + 1, "valueMatches", step.value_matches);
    try buf.appendSlice(gpa, ",\n");
    try writeBoolField(buf, gpa, level + 1, "cidPresent", step.cid_present);
    if (step.cid) |cid| {
        try buf.appendSlice(gpa, ",\n");
        try writeStringField(buf, gpa, level + 1, "cid", cid);
    }
    if (step.failure) |failure| {
        try buf.appendSlice(gpa, ",\n");
        try writeStringField(buf, gpa, level + 1, "failure", failure);
    }
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(buf, gpa, level);
    try buf.appendSlice(gpa, "}");
}

fn writeOptionalField(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize, name: []const u8, check: *const OptionalCheck) Error!void {
    try writeField(buf, gpa, level, name);
    try buf.appendSlice(gpa, "{\n");
    try writeStringField(buf, gpa, level + 1, "status", statusName(check.status));
    try buf.appendSlice(gpa, ",\n");
    try writeStringField(buf, gpa, level + 1, "note", check.note);
    try buf.appendSlice(gpa, "\n");
    try json_out.indent(buf, gpa, level);
    try buf.appendSlice(gpa, "}");
}

/// Concise redacted human summary for stderr. Never includes tokens, proofs,
/// or nonces.
pub fn renderHumanSummary(gpa: std.mem.Allocator, result: *const SmokeResult) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "standard-site smoke: ");
    const verdict: []const u8 = if (result.overall_passed) "passed" else "failed";
    try buf.appendSlice(gpa, verdict);
    try buf.appendSlice(gpa, " (namespace ");
    try buf.appendSlice(gpa, result.namespace);
    try buf.appendSlice(gpa, ", DID ");
    try buf.appendSlice(gpa, result.did);
    try buf.appendSlice(gpa, " via ");
    try buf.appendSlice(gpa, result.pds_origin);
    try buf.appendSlice(gpa, ")\n");
    return buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const test_did_text = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const test_pds = "https://pds.example.com";
const test_auth = "https://auth.example.com";
const test_cid = "bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4";

const test_config = Config{
    .did = test_did_text,
    .boris_pin = "boris@0.8.1",
    .oliver_pin = publish.oliver_pin,
};

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

fn fixedNow(_: std.Io) i64 {
    return 1_700_000_000;
}

/// Scripted offline host: discovery metadata, one-shot PAR/token exchange, and
/// a stateful PDS with getRecord/putRecord/deleteRecord plus a well-known and
/// indexer surface. Every XRPC response carries a DPoP nonce.
const MockHost = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    records: std.StringHashMapUnmanaged(StoredRecord) = .empty,
    proofs: TestProofSource = .{},
    par_calls: usize = 0,
    token_calls: usize = 0,
    gets: usize = 0,
    puts: usize = 0,
    deletes: usize = 0,
    /// When set, the document putRecord returns this error payload instead of
    /// storing the record, exercising partial-write + cleanup.
    reject_document_put: bool = false,
    /// When set, the document readback returns a wrong title, exercising the
    /// value-mismatch path.
    corrupt_document_readback: bool = false,
    /// When set, the document deleteRecord fails, exercising cleanup failure.
    fail_document_delete: bool = false,

    const StoredRecord = struct {
        cid: []const u8,
        value: []const u8,
    };

    fn init(gpa: std.mem.Allocator) MockHost {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *MockHost) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn client(self: *MockHost) transport.Client {
        return .{ .context = self, .request_fn = perform };
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, value: transport.Request) transport.Error!transport.Response {
        const self: *MockHost = @ptrCast(@alignCast(context));
        const url = value.url;

        if (value.method == .get) {
            if (std.mem.eql(u8, url, "https://plc.directory/" ++ test_did_text)) {
                return self.didDocument(allocator, value);
            }
            if (std.mem.eql(u8, url, test_pds ++ "/.well-known/oauth-protected-resource")) {
                return self.respond(allocator, value, 200, "application/json", "{\"resource\":\"" ++ test_pds ++ "\",\"authorization_servers\":[\"" ++ test_auth ++ "\"]}");
            }
            if (std.mem.eql(u8, url, test_auth ++ "/.well-known/oauth-authorization-server")) {
                return self.respond(allocator, value, 200, "application/json", "{\"issuer\":\"" ++ test_auth ++ "\",\"authorization_endpoint\":\"" ++ test_auth ++ "/authorize\",\"token_endpoint\":\"" ++ test_auth ++ "/token\",\"pushed_authorization_request_endpoint\":\"" ++ test_auth ++ "/par\",\"scopes_supported\":[\"atproto\"],\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"],\"code_challenge_methods_supported\":[\"S256\"],\"token_endpoint_auth_methods_supported\":[\"none\",\"private_key_jwt\"],\"token_endpoint_auth_signing_alg_values_supported\":[\"ES256\"],\"dpop_signing_alg_values_supported\":[\"ES256\"],\"authorization_response_iss_parameter_supported\":true,\"require_pushed_authorization_requests\":true,\"client_id_metadata_document_supported\":true,\"require_request_uri_registration\":true}");
            }
            if (std.mem.eql(u8, url, "https://example.com/" ++ well_known_suffix)) {
                return self.respond(allocator, value, 200, "text/plain", "at://" ++ test_did_text ++ "/site.standard.publication/self");
            }
            if (std.mem.startsWith(u8, url, "https://indexer.example.com/xrpc/com.atproto.repo.getRecord?")) {
                return self.respond(allocator, value, 200, "application/json", "{\"uri\":\"at://" ++ test_did_text ++ "/site.standard.document/boris-smoke-1700000000-document\",\"value\":{\"title\":\"boris-live-smoke\"}}");
            }
            if (std.mem.startsWith(u8, url, test_pds ++ "/xrpc/com.atproto.repo.getRecord?")) {
                self.gets += 1;
                return self.getRecord(allocator, value, url);
            }
            return error.UnexpectedRequest;
        }

        if (value.method == .post) {
            if (std.mem.eql(u8, url, test_auth ++ "/par")) {
                if (!hasDpop(value.headers)) return error.UnexpectedRequest;
                self.par_calls += 1;
                if (self.par_calls == 1) {
                    return self.respond(allocator, value, 400, "application/json", "{\"error\":\"use_dpop_nonce\"}");
                }
                return self.respond(allocator, value, 201, "application/json", "{\"request_uri\":\"urn:ietf:params:oauth:request_uri:abc\",\"expires_in\":90}");
            }
            if (std.mem.eql(u8, url, test_auth ++ "/token")) {
                if (!hasDpop(value.headers)) return error.UnexpectedRequest;
                self.token_calls += 1;
                if (self.token_calls == 1) {
                    return self.respond(allocator, value, 400, "application/json", "{\"error\":\"use_dpop_nonce\"}");
                }
                return self.respond(allocator, value, 200, "application/json", "{\"access_token\":\"ACCESS-TOKEN-SECRET\",\"token_type\":\"DPoP\",\"sub\":\"" ++ test_did_text ++ "\",\"scope\":\"atproto include:site.standard.authFull\",\"expires_in\":3600}");
            }
            if (std.mem.endsWith(u8, url, "/xrpc/com.atproto.repo.putRecord")) {
                if (!hasDpop(value.headers)) return error.UnexpectedRequest;
                self.puts += 1;
                return self.putRecord(allocator, value, value.body);
            }
            if (std.mem.endsWith(u8, url, "/xrpc/com.atproto.repo.deleteRecord")) {
                if (!hasDpop(value.headers)) return error.UnexpectedRequest;
                self.deletes += 1;
                return self.deleteRecord(allocator, value, value.body);
            }
            return error.UnexpectedRequest;
        }
        return error.UnexpectedRequest;
    }

    fn didDocument(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request) transport.Error!transport.Response {
        return self.respond(allocator, value, 200, "application/did+ld+json", "{\"id\":\"" ++ test_did_text ++ "\",\"alsoKnownAs\":[],\"service\":[{\"id\":\"#atproto_pds\",\"type\":\"AtprotoPersonalDataServer\",\"serviceEndpoint\":\"" ++ test_pds ++ "\"}]}");
    }

    fn getRecord(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, url: []const u8) transport.Error!transport.Response {
        const collection = queryField(url, "collection") orelse return error.UnexpectedRequest;
        const rkey = queryField(url, "rkey") orelse return error.UnexpectedRequest;
        const arena = self.arena.allocator();
        const key = recordKey(arena, collection, rkey) catch return error.OutOfMemory;
        const stored = self.records.get(key) orelse {
            return self.respond(allocator, value, 400, "application/json", "{\"error\":\"RecordNotFound\",\"message\":\"not found\"}");
        };
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(arena);
        body.appendSlice(arena, "{\"uri\":\"at://") catch return error.OutOfMemory;
        body.appendSlice(arena, test_did_text) catch return error.OutOfMemory;
        body.appendSlice(arena, "/") catch return error.OutOfMemory;
        body.appendSlice(arena, collection) catch return error.OutOfMemory;
        body.appendSlice(arena, "/") catch return error.OutOfMemory;
        body.appendSlice(arena, rkey) catch return error.OutOfMemory;
        body.appendSlice(arena, "\",\"cid\":\"") catch return error.OutOfMemory;
        body.appendSlice(arena, stored.cid) catch return error.OutOfMemory;
        body.appendSlice(arena, "\",\"value\":") catch return error.OutOfMemory;
        body.appendSlice(arena, stored.value) catch return error.OutOfMemory;
        body.appendSlice(arena, "}") catch return error.OutOfMemory;
        return self.respond(allocator, value, 200, "application/json", body.items);
    }

    fn putRecord(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, body: []const u8) transport.Error!transport.Response {
        const collection = fieldValue(body, "collection") orelse return error.UnexpectedRequest;
        const rkey = fieldValue(body, "rkey") orelse return error.UnexpectedRequest;
        if (self.reject_document_put and std.mem.eql(u8, rkey, "boris-smoke-1700000000-document")) {
            return self.respond(allocator, value, 400, "application/json", "{\"error\":\"InvalidRecord\",\"message\":\"rejected\"}");
        }
        const record_json = recordValue(body) orelse return error.UnexpectedRequest;
        const arena = self.arena.allocator();
        const key = recordKey(arena, collection, rkey) catch return error.OutOfMemory;
        var stored_value = arena.dupe(u8, record_json) catch return error.OutOfMemory;
        if (self.corrupt_document_readback and std.mem.eql(u8, rkey, "boris-smoke-1700000000-document")) {
            stored_value = arena.dupe(u8, "{\"site\":\"at://" ++ test_did_text ++ "/site.standard.publication/boris-smoke-1700000000-publication\",\"title\":\"CORRUPTED\",\"publishedAt\":\"2024-01-20T14:30:00.000Z\",\"path\":\"/boris-smoke.html\"}") catch return error.OutOfMemory;
        }
        self.records.put(arena, key, .{ .cid = test_cid, .value = stored_value }) catch return error.OutOfMemory;
        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(arena);
        response_body.appendSlice(arena, "{\"uri\":\"at://") catch return error.OutOfMemory;
        response_body.appendSlice(arena, test_did_text) catch return error.OutOfMemory;
        response_body.appendSlice(arena, "/") catch return error.OutOfMemory;
        response_body.appendSlice(arena, collection) catch return error.OutOfMemory;
        response_body.appendSlice(arena, "/") catch return error.OutOfMemory;
        response_body.appendSlice(arena, rkey) catch return error.OutOfMemory;
        response_body.appendSlice(arena, "\",\"cid\":\"") catch return error.OutOfMemory;
        response_body.appendSlice(arena, test_cid) catch return error.OutOfMemory;
        response_body.appendSlice(arena, "\"}") catch return error.OutOfMemory;
        return self.respond(allocator, value, 200, "application/json", response_body.items);
    }

    fn deleteRecord(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, body: []const u8) transport.Error!transport.Response {
        const collection = fieldValue(body, "collection") orelse return error.UnexpectedRequest;
        const rkey = fieldValue(body, "rkey") orelse return error.UnexpectedRequest;
        if (self.fail_document_delete and std.mem.eql(u8, rkey, "boris-smoke-1700000000-document")) {
            return self.respond(allocator, value, 500, "application/json", "{\"error\":\"InternalServerError\"}");
        }
        const key = recordKey(self.arena.allocator(), collection, rkey) catch return error.OutOfMemory;
        _ = self.records.fetchRemove(key);
        return self.respond(allocator, value, 200, "application/json", "{}");
    }

    fn respond(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, status: u16, content_type: []const u8, body: []const u8) transport.Error!transport.Response {
        _ = self;
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "dpop-nonce", .value = "xrpc-nonce-1" },
        };
        return transport.Response.initCopy(allocator, status, &headers, body, value.limits);
    }
};

fn recordKey(arena: std.mem.Allocator, collection: []const u8, rkey: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try out.appendSlice(arena, collection);
    try out.append(arena, '/');
    try out.appendSlice(arena, rkey);
    return out.toOwnedSlice(arena);
}

fn recordValue(body: []const u8) ?[]const u8 {
    const marker = "\"record\":";
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    if (start + marker.len >= body.len) return null;
    return body[start + marker.len .. body.len - 1];
}

fn fieldValue(body: []const u8, name: []const u8) ?[]const u8 {
    var quoted: [64]u8 = undefined;
    if (name.len + 4 > quoted.len) return null;
    quoted[0] = '"';
    @memcpy(quoted[1 .. 1 + name.len], name);
    quoted[1 + name.len] = '"';
    quoted[2 + name.len] = ':';
    quoted[3 + name.len] = '"';
    const start = std.mem.indexOf(u8, body, quoted[0 .. 4 + name.len]) orelse return null;
    const value_start = start + 4 + name.len;
    var end = value_start;
    while (end < body.len and body[end] != '"') : (end += 1) {}
    if (end >= body.len or end == value_start) return null;
    return body[value_start..end];
}

fn queryField(url: []const u8, name: []const u8) ?[]const u8 {
    const question = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, url[question + 1 ..], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], name)) return pair[equals + 1 ..];
    }
    return null;
}

fn hasDpop(headers: []const transport.Header) bool {
    for (headers) |header| {
        // PAR and token exchange carry the proof in the `dpop` header; the
        // XRPC client binds its proof into the `authorization: DPoP …` header.
        if (std.ascii.eqlIgnoreCase(header.name, "dpop") and header.value.len > 0) return true;
        if (std.ascii.eqlIgnoreCase(header.name, "authorization") and std.mem.startsWith(u8, header.value, "DPoP ")) return true;
    }
    return false;
}

/// Drives the one-shot PAR/callback/token flow through the injected transport,
/// skipping only the loopback listener and browser launch.
fn testAuthorize(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: transport.Client,
    account: identity.DiscoveredAccount,
) Error!authorization.AuthorizedSession {
    _ = io;
    const entropy: authorization.SessionEntropy = .{
        .key_seed = @splat(1),
        .pkce = @splat(2),
        .state = @splat(3),
    };
    var proofs = TestProofSource{};
    var pending = try authorization.begin(
        gpa,
        client,
        account,
        "http://127.0.0.1:49152/oauth/callback",
        entropy,
        proofs.source(),
    );
    defer pending.deinit();

    var target: std.ArrayList(u8) = .empty;
    defer target.deinit(gpa);
    try target.appendSlice(gpa, "/oauth/callback?state=");
    try target.appendSlice(gpa, &pending.state);
    try target.appendSlice(gpa, "&iss=");
    try target.appendSlice(gpa, test_auth);
    try target.appendSlice(gpa, "&code=auth-code");
    try pending.acceptCallback(target.items);
    return pending.exchange(gpa, client, proofs.source());
}

fn provideTestSession(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    client: transport.Client,
    account: identity.DiscoveredAccount,
) Error!publish.AcquiredSession {
    const mock: *MockHost = @ptrCast(@alignCast(ctx));
    _ = mock;
    return .{ .oauth = try testAuthorize(allocator, io, client, account) };
}

fn testRuntime(io: std.Io, mock: *MockHost) Runtime {
    return .{
        .io = io,
        .client = mock.client(),
        .proofs = mock.proofs.source(),
        .session_ctx = mock,
        .session_fn = provideTestSession,
        .now_fn = fixedNow,
    };
}

test "smoke writes, reads back, and cleans up a unique namespace offline" {
    const gpa = std.testing.allocator;
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var result = try smoke(gpa, &runtime, &test_config);
    defer result.deinit(gpa);

    try std.testing.expect(result.overall_passed);
    try std.testing.expectEqualStrings("boris-smoke-1700000000", result.namespace);
    try std.testing.expectEqual(StepStatus.passed, result.publication.status);
    try std.testing.expectEqual(StepStatus.passed, result.document.status);
    try std.testing.expectEqual(StepStatus.passed, result.readback_publication.status);
    try std.testing.expectEqual(StepStatus.passed, result.readback_document.status);
    try std.testing.expect(result.readback_publication.value_matches);
    try std.testing.expect(result.readback_document.value_matches);
    try std.testing.expect(result.readback_publication.at_uri_matches);
    try std.testing.expectEqual(StepStatus.passed, result.cleanup_status);
    try std.testing.expect(result.cleaned_publication);
    try std.testing.expect(result.cleaned_document);
    try std.testing.expectEqual(@as(usize, 2), mock.puts);
    try std.testing.expectEqual(@as(usize, 2), mock.deletes);
    // No stored records remain after cleanup.
    try std.testing.expectEqual(@as(usize, 0), mock.records.count());
}

test "smoke result renders deterministically and never leaks session secrets" {
    const gpa = std.testing.allocator;
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var result = try smoke(gpa, &runtime, &test_config);
    defer result.deinit(gpa);

    const rendered = try renderResult(gpa, &result);
    defer gpa.free(rendered);
    const summary = try renderHumanSummary(gpa, &result);
    defer gpa.free(summary);

    const secrets = [_][]const u8{ "ACCESS-TOKEN-SECRET", "DPoP", "xrpc-nonce", "auth-code" };
    for (secrets) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, rendered, secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, summary, secret) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"overall\": \"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"schema\": \"boris-live-smoke-result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"baseline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "passed") != null);
}

test "partial write still reads back and cleans up, reporting failure" {
    const gpa = std.testing.allocator;
    var mock = MockHost.init(gpa);
    mock.reject_document_put = true;
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var result = try smoke(gpa, &runtime, &test_config);
    defer result.deinit(gpa);

    try std.testing.expect(!result.overall_passed);
    try std.testing.expectEqual(StepStatus.passed, result.publication.status);
    try std.testing.expectEqual(StepStatus.failed, result.document.status);
    try std.testing.expectEqual(StepStatus.skipped, result.readback_document.status);
    try std.testing.expectEqual(StepStatus.passed, result.cleanup_status);
    try std.testing.expect(result.cleaned_publication);
    try std.testing.expect(!result.cleaned_document);
}

test "readback value mismatch fails overall" {
    const gpa = std.testing.allocator;
    var mock = MockHost.init(gpa);
    mock.corrupt_document_readback = true;
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var result = try smoke(gpa, &runtime, &test_config);
    defer result.deinit(gpa);

    try std.testing.expect(!result.overall_passed);
    try std.testing.expectEqual(StepStatus.failed, result.readback_document.status);
    try std.testing.expect(!result.readback_document.value_matches);
    // Cleanup still removes both created records.
    try std.testing.expectEqual(StepStatus.passed, result.cleanup_status);
}

test "cleanup failure leaves the record behind and fails overall" {
    const gpa = std.testing.allocator;
    var mock = MockHost.init(gpa);
    mock.fail_document_delete = true;
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var result = try smoke(gpa, &runtime, &test_config);
    defer result.deinit(gpa);

    try std.testing.expect(!result.overall_passed);
    try std.testing.expectEqual(StepStatus.failed, result.cleanup_status);
    try std.testing.expect(result.cleaned_publication);
    try std.testing.expect(!result.cleaned_document);
}

test "optional verification surface and indexer are recorded but indexer never gates" {
    const gpa = std.testing.allocator;
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    var config = test_config;
    config.site_url = "https://example.com";
    config.indexer_origin = "https://indexer.example.com";
    const runtime = testRuntime(std.testing.io, &mock);

    var result = try smoke(gpa, &runtime, &config);
    defer result.deinit(gpa);

    try std.testing.expect(result.overall_passed);
    try std.testing.expectEqual(StepStatus.passed, result.surface.status);
    try std.testing.expectEqual(StepStatus.observed, result.indexer.status);
}

test "namespace collision fails closed before any write" {
    const gpa = std.testing.allocator;
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    // First run creates and cleans up, leaving the rkeys free again.
    var first = try smoke(gpa, &runtime, &test_config);
    first.deinit(gpa);
    mock.puts = 0;

    // Pre-seed the exact publication rkey of the next run.
    const arena = mock.arena.allocator();
    const key = recordKey(arena, collection_publication, "boris-smoke-1700000000-publication") catch unreachable;
    mock.records.put(arena, key, .{ .cid = test_cid, .value = "{}" }) catch unreachable;

    try std.testing.expectError(error.NamespaceCollision, smoke(gpa, &runtime, &test_config));
    try std.testing.expectEqual(@as(usize, 0), mock.puts);
}
