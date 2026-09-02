//! One-shot Standard.site publish orchestration: identity discovery, the
//! profile-PDS binding gate, interactive OAuth authorization, and the
//! reconciliation pass, composed into a single deterministic command.
//!
//! This module owns the ordering and the fail-closed gates, not the host
//! capabilities: the caller injects the bounded transport, the DPoP proof
//! source, the interactive authorize entry (real browser for the CLI,
//! scripted flow in tests), and a wall clock. The committed-plan gate is a
//! pure byte comparison so drift can never reach the network, and the human
//! summary is built only from the evidence artifact — never from the session —
//! so no access token, refresh token, DPoP key, authorization code, or proof
//! can leak into command output.
//!
//! Secrets never enter the evidence either (see the reconciliation contract);
//! the redaction tests prove both surfaces stay clean end to end.

const std = @import("std");
const json_out = @import("json_out.zig");
const standard_site = @import("standard_site.zig");
const reconcile = @import("standard_site_reconcile.zig");
const identity = @import("atproto_identity.zig");
const authorization = @import("atproto_authorization.zig");
const interactive = @import("atproto_interactive_std.zig");
const password = @import("atproto_password.zig");
const session_std = @import("atproto_session_std.zig");
const transport = @import("atproto_transport.zig");
const xrpc = @import("atproto_xrpc.zig");

pub const Error = identity.Error || authorization.Error || password.Error || xrpc.Error || reconcile.Error || interactive.Error || session_std.Error || error{
    InvalidWallClock,
    PdsOriginMismatch,
    PlanDrift,
    SessionAuthorityChanged,
};

/// The Oliver rendering dependency pin recorded in the evidence bindings.
/// Must match the revision in build.zig.zon (enforced by the zon test below);
/// the upgrade procedure lives in docs/contracts/oliver-renderer.md.
pub const oliver_pin = "oliver@d74249415975d652654e521b7abea40c85b13255";

/// A session acquired for one publish/smoke run: either the DPoP-bound OAuth
/// session or the Bearer app-password session. Both carry the DID + PDS origin
/// needed for the authority gate; only the OAuth form binds an authorization
/// server.
pub const AcquiredSession = union(enum) {
    oauth: authorization.AuthorizedSession,
    app_password: password.AppPasswordSession,

    pub fn deinit(self: *AcquiredSession) void {
        switch (self.*) {
            .oauth => |*session| session.deinit(),
            .app_password => |*session| session.deinit(),
        }
    }
};

/// When the profile omits `pds`, publish binds to the PDS discovered from
/// the DID document. When the profile sets `pds`, it must match that origin
/// after HTTPS origin parse (ASCII-lowercased so an uppercase host is not a
/// false mismatch).
fn bindProfilePds(profile_pds: ?[]const u8, discovered: []const u8) Error!void {
    const raw = profile_pds orelse return;
    var lowered: [identity.max_origin_bytes]u8 = undefined;
    if (raw.len == 0 or raw.len > lowered.len) return error.PdsOriginMismatch;
    for (raw, 0..) |byte, index| lowered[index] = std.ascii.toLower(byte);
    const parsed = identity.Origin.parse(lowered[0..raw.len]) catch return error.PdsOriginMismatch;
    if (std.mem.eql(u8, parsed.slice(), discovered)) return;
    return error.PdsOriginMismatch;
}

/// Whether an acquired session's identity facts match fresh discovery. The
/// OAuth form also pins the authorization server; the app-password form has no
/// authorization server, so only DID + PDS are bound.
pub fn sessionMatchesAccount(session: *const AcquiredSession, account: identity.DiscoveredAccount) bool {
    return switch (session.*) {
        .oauth => |*s| std.mem.eql(u8, s.account.did.slice(), account.did.slice()) and
            std.mem.eql(u8, s.account.pds_origin.slice(), account.pds_origin.slice()) and
            std.mem.eql(u8, s.account.authorization_server_origin.slice(), account.authorization_server_origin.slice()),
        .app_password => |*s| std.mem.eql(u8, s.did.slice(), account.did.slice()) and
            std.mem.eql(u8, s.pds_origin.slice(), account.pds_origin.slice()),
    };
}

/// Build the XRPC record client for an acquired session (DPoP for OAuth,
/// Bearer for app-password).
pub fn sessionClient(session: *const AcquiredSession, transport_client: transport.Client, proofs: authorization.ProofSource) xrpc.SessionClient {
    return switch (session.*) {
        .oauth => |*s| xrpc.SessionClient.fromAuthorizedSession(s, transport_client, proofs),
        .app_password => |*s| xrpc.SessionClient.fromBearerSession(s.did, s.pds_origin, s.access_token.slice(), transport_client),
    };
}

/// Host capabilities for one publish invocation. Tests inject a scripted
/// transport, a deterministic proof source, a session-provider callback, and
/// a fixed clock; the CLI injects the native adapters. The session provider
/// returns an owned session — freshly authorized (one-shot login) or loaded
/// and refreshed from the persistent store — and publish verifies its
/// authority facts against the discovery result before any mutation.
pub const Runtime = struct {
    io: std.Io,
    client: transport.Client,
    proofs: authorization.ProofSource,
    session_ctx: *anyopaque,
    session_fn: *const fn (
        ctx: *anyopaque,
        std.mem.Allocator,
        std.Io,
        transport.Client,
        identity.DiscoveredAccount,
    ) Error!AcquiredSession,
    /// Epoch seconds for the evidence observation timestamp.
    now_fn: *const fn (std.Io) i64,
};

/// Native wall clock for the evidence observation timestamp (UTC epoch
/// seconds). `std.testing.io` supports the real clock, so tests may use it.
pub fn wallClockSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Fail closed when the committed plan bytes differ from the freshly rendered
/// plan. The evidence binds the exact committed plan digest; drift would mean
/// publishing records whose payloads were never reviewed, so it must never
/// reach the network.
pub fn validatePlanMatches(rendered: []const u8, committed: []const u8) Error!void {
    if (!std.mem.eql(u8, rendered, committed)) return error.PlanDrift;
}

/// One publish pass. Ordering is fixed:
///
/// 1. Resolve the configured DID and discover PDS, Resource Server, and
///    Authorization Server metadata (read-only GETs).
/// 2. Verify the DID document's PDS equals the profile-bound PDS before any
///    authorization — a mismatch fails closed with zero authorization.
/// 3. Obtain a session (fresh interactive login, or loaded/refreshed from the
///    persistent store) and verify its authority facts — DID, PDS, and
///    authorization server — match the discovery result. A stored session
///    bound to a different authority fails closed without touching the
///    network.
/// 4. Reconcile: precondition verification (plan digest, session DID, PDS,
///    collections, rkeys) runs before any mutation; per-record writes follow.
///
/// Returns the evidence artifact (owned by the caller via `deinit`).
pub fn publish(
    gpa: std.mem.Allocator,
    runtime: *const Runtime,
    config: *const standard_site.TargetConfig,
    projection: *const standard_site.Projection,
    plan: []const u8,
    expected_plan_sha256: [64]u8,
    prune: bool,
    bindings: reconcile.Bindings,
) Error!reconcile.Evidence {
    var account = try identity.discover(gpa, runtime.client, config.did);

    try bindProfilePds(config.pds_origin, account.pds_origin.slice());

    var session = try runtime.session_fn(runtime.session_ctx, gpa, runtime.io, runtime.client, account);
    defer session.deinit();

    // A persisted session is bound to the authority facts recorded at login;
    // if the account has since moved PDS (or authorization server, for OAuth),
    // the stored session is no longer safe to reuse and must never touch the
    // network.
    if (!sessionMatchesAccount(&session, account)) return error.SessionAuthorityChanged;

    var client = sessionClient(&session, runtime.client, runtime.proofs);

    const seconds = runtime.now_fn(runtime.io);
    if (seconds < 0) return error.InvalidWallClock;
    const observed_at = try formatObservedAt(gpa, seconds);
    defer gpa.free(observed_at);

    return reconcile.reconcile(
        gpa,
        config,
        projection,
        plan,
        expected_plan_sha256,
        &client,
        prune,
        bindings,
        observed_at,
    );
}

/// Concise redacted human summary of a finished publish, built only from the
/// evidence artifact. It names the identity, the bound plan digest, the
/// per-outcome record counts, and the overall result — never any secret.
pub fn renderHumanSummary(gpa: std.mem.Allocator, evidence: *const reconcile.Evidence) Error![]u8 {
    var created: usize = 0;
    var updated: usize = 0;
    var unchanged: usize = 0;
    var pruned: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    for (evidence.records) |record| {
        switch (record.outcome) {
            .created => created += 1,
            .updated => updated += 1,
            .unchanged => unchanged += 1,
            .pruned => pruned += 1,
            .skipped_orphan => skipped += 1,
            .failed => failed += 1,
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "Standard.site publish: identity ");
    try json_out.writeString(&out, gpa, evidence.did);
    try out.appendSlice(gpa, " via ");
    try json_out.writeString(&out, gpa, evidence.pds_origin);
    try out.appendSlice(gpa, "\nStandard.site publish: plan sha256 ");
    for (evidence.plan_sha256) |byte| try out.append(gpa, byte);
    try out.appendSlice(gpa, "\nStandard.site publish: ");
    try appendUsize(&out, gpa, evidence.records.len);
    try out.appendSlice(gpa, " record(s): ");
    try appendCount(&out, gpa, created, "created");
    try appendCount(&out, gpa, updated, "updated");
    try appendCount(&out, gpa, unchanged, "unchanged");
    try appendCount(&out, gpa, pruned, "pruned");
    try appendCount(&out, gpa, skipped, "skipped");
    try appendCount(&out, gpa, failed, "failed");
    try out.appendSlice(gpa, "\nStandard.site publish: overall ");
    try out.appendSlice(gpa, if (evidence.overall_passed) "passed" else "failed");
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

fn appendCount(out: *std.ArrayList(u8), gpa: std.mem.Allocator, count: usize, label: []const u8) Error!void {
    if (count == 0) return;
    try appendUsize(out, gpa, count);
    try out.append(gpa, ' ');
    try out.appendSlice(gpa, label);
    try out.appendSlice(gpa, ", ");
}

fn appendUsize(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: usize) Error!void {
    if (value == 0) {
        try out.append(gpa, '0');
        return;
    }
    var buffer: [20]u8 = undefined;
    var index: usize = buffer.len;
    var remaining = value;
    while (remaining != 0) {
        index -= 1;
        buffer[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
    try out.appendSlice(gpa, buffer[index..]);
}

/// `YYYY-MM-DDTHH:MM:SS.000Z` UTC from epoch seconds — the atproto datetime
/// form the reconciliation contract injects as the observation time.
fn formatObservedAt(gpa: std.mem.Allocator, seconds: i64) Error![]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const epoch_day = epoch.getEpochDay();
    const day_seconds = epoch.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendYear(&out, gpa, year_day.year);
    try out.append(gpa, '-');
    try appendTwo(&out, gpa, @intFromEnum(month_day.month));
    try out.append(gpa, '-');
    try appendTwo(&out, gpa, @as(u8, @intCast(month_day.day_index)) + 1);
    try out.append(gpa, 'T');
    try appendTwo(&out, gpa, @intCast(day_seconds.getHoursIntoDay()));
    try out.append(gpa, ':');
    try appendTwo(&out, gpa, @intCast(day_seconds.getMinutesIntoHour()));
    try out.append(gpa, ':');
    try appendTwo(&out, gpa, @intCast(day_seconds.getSecondsIntoMinute()));
    try out.appendSlice(gpa, ".000Z");
    return out.toOwnedSlice(gpa);
}

fn appendYear(out: *std.ArrayList(u8), gpa: std.mem.Allocator, year: u16) Error!void {
    try appendTwo(out, gpa, @intCast(year / 100));
    try appendTwo(out, gpa, @intCast(year % 100));
}

fn appendTwo(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u8) Error!void {
    try out.append(gpa, '0' + value / 10);
    try out.append(gpa, '0' + value % 10);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const test_did_text = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const test_pds = "https://pds.example.com";
const test_auth = "https://auth.example.com";
const test_oid = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const test_cid = "bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4";

const test_bindings = reconcile.Bindings{
    .source_commit = "0123456789abcdef",
    .boris_pin = "boris@0.8.2",
    .oliver_pin = oliver_pin,
};

/// Scripted offline host: discovery metadata, PAR/token exchange, and a
/// stateful PDS. Every XRPC response carries a DPoP nonce (the XRPC client
/// requires one on every response).
const MockHost = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// PDS the DID document declares; override for the binding-mismatch test.
    declared_pds: []const u8 = test_pds,
    /// When set, putRecord for this document rkey returns a 400 so the
    /// partial-failure path can be exercised end to end.
    reject_rkey: ?[]const u8 = null,
    records: std.StringHashMapUnmanaged(StoredRecord) = .empty,
    proofs: TestProofSource = .{},
    par_calls: usize = 0,
    token_calls: usize = 0,
    gets: usize = 0,
    puts: usize = 0,
    deletes: usize = 0,

    const StoredRecord = struct {
        cid: []const u8,
        value: []const u8,
    };

    fn init(gpa: std.mem.Allocator) MockHost {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *MockHost) void {
        // All map storage is arena-owned; the arena frees the keys and values.
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
            if (std.mem.eql(u8, url, "https://plc.directory/" ++ test_oid)) {
                return self.json(allocator, value, 200, .did_document, "application/did+ld+json");
            }
            if (hasPath(url, self.declared_pds, "/.well-known/oauth-protected-resource")) {
                return self.json(allocator, value, 200, .resource_metadata, "application/json");
            }
            if (std.mem.eql(u8, url, test_auth ++ "/.well-known/oauth-authorization-server")) {
                return self.json(allocator, value, 200, .authorization_metadata, "application/json");
            }
            if (std.mem.startsWith(u8, url, self.declared_pds) and
                std.mem.indexOf(u8, url, "/xrpc/com.atproto.repo.getRecord?") != null)
            {
                self.gets += 1;
                return self.getRecord(allocator, value, url);
            }
            return error.UnexpectedRequest;
        }

        if (value.method == .post) {
            if (std.mem.eql(u8, url, test_auth ++ "/par")) {
                if (!hasDpop(value.headers)) return error.UnexpectedRequest;
                self.par_calls += 1;
                const headers = [_]transport.Header{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "dpop-nonce", .value = if (self.par_calls == 1) "par-nonce-1" else "par-nonce-2" },
                };
                if (self.par_calls == 1) {
                    return self.respond(allocator, value, 400, &headers, "{\"error\":\"use_dpop_nonce\"}");
                }
                return self.respond(allocator, value, 201, &headers, "{\"request_uri\":\"urn:ietf:params:oauth:request_uri:abc\",\"expires_in\":90}");
            }
            if (std.mem.eql(u8, url, test_auth ++ "/token")) {
                if (!hasDpop(value.headers)) return error.UnexpectedRequest;
                self.token_calls += 1;
                const headers = [_]transport.Header{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "dpop-nonce", .value = if (self.token_calls == 1) "token-nonce-1" else "token-nonce-2" },
                };
                if (self.token_calls == 1) {
                    return self.respond(allocator, value, 400, &headers, "{\"error\":\"use_dpop_nonce\"}");
                }
                return self.respond(allocator, value, 200, &headers, "{\"access_token\":\"ACCESS-TOKEN-SECRET\",\"token_type\":\"DPoP\",\"sub\":\"" ++ test_oid ++ "\",\"scope\":\"atproto repo:site.standard.document repo:site.standard.publication\",\"expires_in\":3600}");
            }
            if (hasPath(url, self.declared_pds, "/xrpc/com.atproto.repo.putRecord")) {
                if (!hasDpop(value.headers)) return error.UnexpectedRequest;
                self.puts += 1;
                return self.putRecord(allocator, value, value.body);
            }
            if (hasPath(url, self.declared_pds, "/xrpc/com.atproto.repo.deleteRecord")) {
                if (!hasDpop(value.headers)) return error.UnexpectedRequest;
                self.deletes += 1;
                return self.deleteRecord(allocator, value, value.body);
            }
            return error.UnexpectedRequest;
        }
        return error.UnexpectedRequest;
    }

    fn hasPath(url: []const u8, pds: []const u8, path: []const u8) bool {
        return std.mem.startsWith(u8, url, pds) and std.mem.endsWith(u8, url, path);
    }

    fn getRecord(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, url: []const u8) transport.Error!transport.Response {
        const collection = queryField(url, "collection") orelse return error.UnexpectedRequest;
        const rkey = queryField(url, "rkey") orelse return error.UnexpectedRequest;
        const key = recordKey(self.arena.allocator(), collection, rkey) catch return error.OutOfMemory;
        const stored = self.records.get(key) orelse {
            const headers = [_]transport.Header{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "dpop-nonce", .value = "xrpc-nonce-1" },
            };
            return self.respond(allocator, value, 400, &headers, "{\"error\":\"RecordNotFound\",\"message\":\"not found\"}");
        };
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.arena.allocator());
        body.appendSlice(self.arena.allocator(), "{\"uri\":\"at://") catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), test_oid) catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), "/") catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), collection) catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), "/") catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), rkey) catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), "\",\"cid\":\"") catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), stored.cid) catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), "\",\"value\":") catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), stored.value) catch return error.OutOfMemory;
        body.appendSlice(self.arena.allocator(), "}") catch return error.OutOfMemory;
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "dpop-nonce", .value = "xrpc-nonce-1" },
        };
        return self.respond(allocator, value, 200, &headers, body.items);
    }

    fn putRecord(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, body: []const u8) transport.Error!transport.Response {
        const collection = fieldValue(body, "collection") orelse return error.UnexpectedRequest;
        const rkey = fieldValue(body, "rkey") orelse return error.UnexpectedRequest;
        if (self.reject_rkey) |rejected| {
            if (std.mem.eql(u8, rkey, rejected)) {
                const headers = [_]transport.Header{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "dpop-nonce", .value = "xrpc-nonce-1" },
                };
                return self.respond(allocator, value, 400, &headers, "{\"error\":\"InvalidSwap\",\"message\":\"rejected\"}");
            }
        }
        const record_json = recordValue(body) orelse return error.UnexpectedRequest;
        const arena = self.arena.allocator();
        const key = recordKey(arena, collection, rkey) catch return error.OutOfMemory;
        self.records.put(arena, key, .{ .cid = test_cid, .value = arena.dupe(u8, record_json) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(arena);
        response_body.appendSlice(arena, "{\"uri\":\"at://") catch return error.OutOfMemory;
        response_body.appendSlice(arena, test_oid) catch return error.OutOfMemory;
        response_body.appendSlice(arena, "/") catch return error.OutOfMemory;
        response_body.appendSlice(arena, collection) catch return error.OutOfMemory;
        response_body.appendSlice(arena, "/") catch return error.OutOfMemory;
        response_body.appendSlice(arena, rkey) catch return error.OutOfMemory;
        response_body.appendSlice(arena, "\",\"cid\":\"") catch return error.OutOfMemory;
        response_body.appendSlice(arena, test_cid) catch return error.OutOfMemory;
        response_body.appendSlice(arena, "\"}") catch return error.OutOfMemory;
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "dpop-nonce", .value = "xrpc-nonce-1" },
        };
        return self.respond(allocator, value, 200, &headers, response_body.items);
    }

    fn deleteRecord(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, body: []const u8) transport.Error!transport.Response {
        const collection = fieldValue(body, "collection") orelse return error.UnexpectedRequest;
        const rkey = fieldValue(body, "rkey") orelse return error.UnexpectedRequest;
        const key = recordKey(self.arena.allocator(), collection, rkey) catch return error.OutOfMemory;
        _ = self.records.fetchRemove(key);
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "dpop-nonce", .value = "xrpc-nonce-1" },
        };
        return self.respond(allocator, value, 200, &headers, "{}");
    }

    const JsonKind = enum { did_document, resource_metadata, authorization_metadata };

    fn json(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, status: u16, kind: JsonKind, content_type: []const u8) transport.Error!transport.Response {
        const arena = self.arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(arena);
        switch (kind) {
            .did_document => {
                body.appendSlice(arena, "{\"id\":\"") catch return error.OutOfMemory;
                body.appendSlice(arena, test_oid) catch return error.OutOfMemory;
                body.appendSlice(arena, "\",\"alsoKnownAs\":[],\"service\":[{\"id\":\"#atproto_pds\",\"type\":\"AtprotoPersonalDataServer\",\"serviceEndpoint\":\"") catch return error.OutOfMemory;
                body.appendSlice(arena, self.declared_pds) catch return error.OutOfMemory;
                body.appendSlice(arena, "\"}]}") catch return error.OutOfMemory;
            },
            .resource_metadata => {
                body.appendSlice(arena, "{\"resource\":\"") catch return error.OutOfMemory;
                body.appendSlice(arena, self.declared_pds) catch return error.OutOfMemory;
                body.appendSlice(arena, "\",\"authorization_servers\":[\"") catch return error.OutOfMemory;
                body.appendSlice(arena, test_auth) catch return error.OutOfMemory;
                body.appendSlice(arena, "\"]}") catch return error.OutOfMemory;
            },
            .authorization_metadata => {
                body.appendSlice(arena, "{\"issuer\":\"") catch return error.OutOfMemory;
                body.appendSlice(arena, test_auth) catch return error.OutOfMemory;
                body.appendSlice(arena, "\",\"authorization_endpoint\":\"") catch return error.OutOfMemory;
                body.appendSlice(arena, test_auth) catch return error.OutOfMemory;
                body.appendSlice(arena, "/authorize\",\"token_endpoint\":\"") catch return error.OutOfMemory;
                body.appendSlice(arena, test_auth) catch return error.OutOfMemory;
                body.appendSlice(arena, "/token\",\"pushed_authorization_request_endpoint\":\"") catch return error.OutOfMemory;
                body.appendSlice(arena, test_auth) catch return error.OutOfMemory;
                body.appendSlice(arena, "/par\",\"scopes_supported\":[\"atproto\"],\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"],\"code_challenge_methods_supported\":[\"S256\"],\"token_endpoint_auth_methods_supported\":[\"none\",\"private_key_jwt\"],\"token_endpoint_auth_signing_alg_values_supported\":[\"ES256\"],\"dpop_signing_alg_values_supported\":[\"ES256\"],\"authorization_response_iss_parameter_supported\":true,\"require_pushed_authorization_requests\":true,\"client_id_metadata_document_supported\":true,\"require_request_uri_registration\":true}") catch return error.OutOfMemory;
            },
        }
        const headers = [_]transport.Header{.{ .name = "content-type", .value = content_type }};
        return self.respond(allocator, value, status, &headers, body.items);
    }

    fn respond(self: *MockHost, allocator: std.mem.Allocator, value: transport.Request, status: u16, headers: []const transport.Header, body: []const u8) transport.Error!transport.Response {
        _ = self;
        return transport.Response.initCopy(allocator, status, headers, body, value.limits);
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

/// The `record` member of a putRecord body is always the final JSON value.
fn recordValue(body: []const u8) ?[]const u8 {
    const marker = "\"record\":";
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    if (start + marker.len >= body.len) return null;
    return body[start + marker.len .. body.len - 1];
}

/// Extract a quoted JSON string field value (`"name":"..."`).
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
        if (std.ascii.eqlIgnoreCase(header.name, "dpop") and header.value.len > 0) return true;
    }
    return false;
}

var test_deny_authorization: bool = false;

/// Drives the real one-shot PAR/callback/token flow through the injected
/// transport, skipping only the loopback listener and browser launch.
fn testAuthorize(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: transport.Client,
    account: identity.DiscoveredAccount,
    mock: *MockHost,
) Error!authorization.AuthorizedSession {
    _ = mock;
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
    if (test_deny_authorization) {
        try target.appendSlice(gpa, "&error=access_denied");
        try pending.acceptCallback(target.items);
        return error.AuthorizationDenied;
    }
    try target.appendSlice(gpa, "&code=auth-code");
    try pending.acceptCallback(target.items);
    return pending.exchange(gpa, client, proofs.source());
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

fn testConfig(gpa: std.mem.Allocator, pds: []const u8) !standard_site.TargetConfig {
    return .{
        .location = try standard_site.parseLocation(gpa, "https://example.com", "https://example.com", ""),
        .did = try gpa.dupe(u8, test_did_text),
        .pds_origin = try gpa.dupe(u8, pds),
    };
}

const TestSetup = struct {
    config: standard_site.TargetConfig,
    projection: standard_site.Projection,
    surfaces: standard_site.VerificationSurfaces,
    plan: []u8,
    digest: [64]u8,

    fn init(gpa: std.mem.Allocator) !TestSetup {
        var config = try testConfig(gpa, test_pds);
        errdefer config.deinit(gpa);
        const pages = [_]standard_site.PageInput{
            .{ .entity_id = "guides/intro", .output_path = "guides/intro.html", .title = "Intro", .status = .published, .published_at = "2024-01-20T14:30:00Z", .summary = "The intro", .tags = &.{ "guide", "zig" } },
            .{ .entity_id = "reference/api", .output_path = "reference/api.html", .title = "API", .status = .published, .published_at = "2024-02-01T09:00:00Z", .summary = "The API" },
            .{ .entity_id = "old/page", .output_path = "old/page.html", .title = "Old", .status = .draft },
        };
        var projection = try standard_site.project(gpa, .{
            .config = &config,
            .site_title = "Boris",
            .pages = &pages,
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
            .digest = reconcile.sha256HexLower(plan),
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

fn provideTestSession(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    client: transport.Client,
    account: identity.DiscoveredAccount,
) Error!AcquiredSession {
    const mock: *MockHost = @ptrCast(@alignCast(ctx));
    return .{ .oauth = try testAuthorize(allocator, io, client, account, mock) };
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

fn fixedNow(_: std.Io) i64 {
    return 1_700_000_000;
}

test "observed_at formats ISO-8601 UTC with fixed milliseconds" {
    const gpa = std.testing.allocator;
    const text = try formatObservedAt(gpa, 1_700_000_000);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.000Z", text);
}

test "committed plan gate rejects any drift byte-for-byte" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    try validatePlanMatches(setup.plan, setup.plan);
    var drifted = try gpa.dupe(u8, setup.plan);
    defer gpa.free(drifted);
    if (drifted.len == 0) return error.TestUnexpectedResult;
    drifted[0] = 'X';
    try std.testing.expectError(error.PlanDrift, validatePlanMatches(setup.plan, drifted));
}

test "publish resolves identity, authorizes once, and reconciles all records offline" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var evidence = try publish(
        gpa,
        &runtime,
        &setup.config,
        &setup.projection,
        setup.plan,
        setup.digest,
        false,
        test_bindings,
    );
    defer evidence.deinit(gpa);

    try std.testing.expect(evidence.overall_passed);
    try std.testing.expectEqual(@as(usize, 3), evidence.records.len);
    try std.testing.expectEqual(@as(usize, 2), mock.par_calls);
    try std.testing.expectEqual(@as(usize, 2), mock.token_calls);
    try std.testing.expectEqual(@as(usize, 3), mock.puts);
    try std.testing.expectEqual(@as(usize, 0), mock.deletes);
    for (evidence.records) |record| {
        try std.testing.expectEqual(reconcile.Outcome.created, record.outcome);
        try std.testing.expectEqual(reconcile.Verification.write_response, record.verification);
    }
    try std.testing.expectEqualStrings(test_did_text, evidence.did);
    try std.testing.expectEqualStrings(test_pds, evidence.pds_origin);
}

test "publish is idempotent: a second pass performs zero writes" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var first = try publish(gpa, &runtime, &setup.config, &setup.projection, setup.plan, setup.digest, false, test_bindings);
    defer first.deinit(gpa);
    try std.testing.expect(first.overall_passed);

    var second = try publish(gpa, &runtime, &setup.config, &setup.projection, setup.plan, setup.digest, false, test_bindings);
    defer second.deinit(gpa);
    try std.testing.expect(second.overall_passed);
    try std.testing.expectEqual(@as(usize, 3), mock.puts);
    for (second.records) |record| {
        try std.testing.expectEqual(reconcile.Outcome.unchanged, record.outcome);
    }
}

test "PDS binding mismatch fails closed before any authorization" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockHost.init(gpa);
    mock.declared_pds = "https://other.example.com";
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    try std.testing.expectError(error.PdsOriginMismatch, publish(
        gpa,
        &runtime,
        &setup.config,
        &setup.projection,
        setup.plan,
        setup.digest,
        false,
        test_bindings,
    ));
    try std.testing.expectEqual(@as(usize, 0), mock.par_calls);
    try std.testing.expectEqual(@as(usize, 0), mock.token_calls);
    try std.testing.expectEqual(@as(usize, 0), mock.puts);
}

test "omitted profile pds binds to the discovered origin" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    if (setup.config.pds_origin) |previous| gpa.free(previous);
    setup.config.pds_origin = null;
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var evidence = try publish(gpa, &runtime, &setup.config, &setup.projection, setup.plan, setup.digest, false, test_bindings);
    defer evidence.deinit(gpa);
    try std.testing.expect(evidence.overall_passed);
    try std.testing.expectEqualStrings(test_pds, evidence.pds_origin);
}

test "profile pds host is compared after ASCII lowercasing" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    if (setup.config.pds_origin) |previous| gpa.free(previous);
    setup.config.pds_origin = try gpa.dupe(u8, "https://PDS.EXAMPLE.COM");
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var evidence = try publish(gpa, &runtime, &setup.config, &setup.projection, setup.plan, setup.digest, false, test_bindings);
    defer evidence.deinit(gpa);
    try std.testing.expect(evidence.overall_passed);
}

test "a rejected record fails overall but the rest still publish, with evidence" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockHost.init(gpa);
    mock.reject_rkey = "reference:api";
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var evidence = try publish(gpa, &runtime, &setup.config, &setup.projection, setup.plan, setup.digest, false, test_bindings);
    defer evidence.deinit(gpa);

    try std.testing.expect(!evidence.overall_passed);
    try std.testing.expectEqual(@as(usize, 3), evidence.records.len);
    var created: usize = 0;
    var failed: usize = 0;
    for (evidence.records) |record| {
        switch (record.outcome) {
            .created => created += 1,
            .failed => failed += 1,
            else => {},
        }
        if (record.failure) |failure| try std.testing.expectEqualStrings("InvalidStatus", failure);
    }
    try std.testing.expectEqual(@as(usize, 2), created);
    try std.testing.expectEqual(@as(usize, 1), failed);
    // The evidence is still renderable so the operator sees what landed.
    const rendered = try reconcile.renderEvidence(gpa, &evidence);
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"overall\": \"failed\"") != null);
}

test "authorization denial surfaces as AuthorizationDenied with zero writes" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    test_deny_authorization = true;
    defer test_deny_authorization = false;
    const runtime = testRuntime(std.testing.io, &mock);

    try std.testing.expectError(error.AuthorizationDenied, publish(
        gpa,
        &runtime,
        &setup.config,
        &setup.projection,
        setup.plan,
        setup.digest,
        false,
        test_bindings,
    ));
    try std.testing.expectEqual(@as(usize, 0), mock.puts);
}

test "evidence and human summary never leak session secrets" {
    const gpa = std.testing.allocator;
    var setup = try TestSetup.init(gpa);
    defer setup.deinit(gpa);
    var mock = MockHost.init(gpa);
    defer mock.deinit();
    const runtime = testRuntime(std.testing.io, &mock);

    var evidence = try publish(gpa, &runtime, &setup.config, &setup.projection, setup.plan, setup.digest, false, test_bindings);
    defer evidence.deinit(gpa);

    const rendered_evidence = try reconcile.renderEvidence(gpa, &evidence);
    defer gpa.free(rendered_evidence);
    const summary = try renderHumanSummary(gpa, &evidence);
    defer gpa.free(summary);

    const secrets = [_][]const u8{ "ACCESS-TOKEN-SECRET", "DPoP", "par-nonce", "token-nonce", "xrpc-nonce", "auth-code" };
    for (secrets) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, rendered_evidence, secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, summary, secret) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, summary, "overall passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "3 record(s)") != null);
}

test "oliver pin matches the revision pinned in build.zig.zon" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const zon = try std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", gpa, .unlimited);
    defer gpa.free(zon);
    const url_prefix = "https://github.com/drawmeanelephant/oliver/archive/";
    const url_start = std.mem.indexOf(u8, zon, url_prefix) orelse return error.TestUnexpectedResult;
    const sha_start = url_start + url_prefix.len;
    const sha_end = std.mem.indexOfPos(u8, zon, sha_start, ".tar.gz") orelse return error.TestUnexpectedResult;
    const revision = zon[sha_start..sha_end];
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    try expected.appendSlice(gpa, "oliver@");
    try expected.appendSlice(gpa, revision);
    try std.testing.expectEqualStrings(expected.items, oliver_pin);
}
