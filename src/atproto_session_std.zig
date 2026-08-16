//! Host session lifecycle: user-scoped root resolution, load, refresh,
//! rotate-or-die persistence, list, and logout.
//!
//! `acquire` loads a stored session, refreshes it early when its access token
//! is close to expiry, and persists the rotated session with a single atomic
//! replace while holding the store's process-safe lock. Rotation is
//! fail-closed: a successful refresh whose rotation cannot be persisted never
//! leaves the stale single-use refresh token behind, and an ambiguous network
//! failure drops the stored document so the operator re-authorizes instead of
//! burning the token again. No secrets are printed or logged here.

const std = @import("std");
const authorization = @import("atproto_authorization.zig");
const store_mod = @import("atproto_session_store.zig");
const transport = @import("atproto_transport.zig");

pub const Error = authorization.Error || store_mod.Error || error{
    HomeUnavailable,
    NoSession,
    RefreshAmbiguous,
};

/// Refresh before the access token is this close to expiry, so a publish run
/// never presents a token that the PDS may reject mid-flight.
pub const refresh_early_skew_seconds: u64 = 5 * 60;

pub const Sessions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: store_mod.Store,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) Error!Sessions {
        return .{
            .allocator = allocator,
            .io = io,
            .store = try store_mod.Store.open(allocator, io, root_path),
        };
    }

    /// Open a sessions root inside an already-open parent directory (tests).
    pub fn openIn(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, sub_path: []const u8) Error!Sessions {
        return .{
            .allocator = allocator,
            .io = io,
            .store = try store_mod.Store.openIn(allocator, io, parent, sub_path),
        };
    }

    pub fn deinit(self: *Sessions) void {
        self.store.deinit();
        self.* = undefined;
    }

    /// Resolve the user-scoped session root. An explicit override wins;
    /// otherwise `$HOME/.local/share/boris/sessions` (macOS/Linux).
    pub fn userRoot(allocator: std.mem.Allocator, environ: std.process.Environ.Map, override_path: ?[]const u8) Error![]u8 {
        if (override_path) |path| return allocator.dupe(u8, path);
        const home = environ.get("HOME") orelse return error.HomeUnavailable;
        return std.fs.path.join(allocator, &.{ home, ".local", "share", "boris", "sessions" });
    }

    /// Whether the stored access token is still usable without a refresh.
    /// An unknown obtained-at time is treated as expired so a refresh decides.
    fn usable(session: *const authorization.AuthorizedSession, now_seconds: u64) bool {
        if (session.access_token_obtained_at_seconds == 0) return false;
        if (session.access_token_expires_in <= refresh_early_skew_seconds) return false;
        const expires_at = session.access_token_obtained_at_seconds +| session.access_token_expires_in;
        return now_seconds +| refresh_early_skew_seconds < expires_at;
    }

    /// Load and (if needed) refresh the session for `did`. The returned
    /// session is owned by the caller. Fail-closed rotation is described in
    /// the module comment; a persisted rotation is never lost.
    pub fn acquire(
        self: *Sessions,
        did: []const u8,
        client: transport.Client,
        proofs: authorization.ProofSource,
        now_seconds: u64,
    ) Error!authorization.AuthorizedSession {
        var guard = try self.store.lock();
        defer guard.release();
        var stored = (try self.store.load(did)) orelse return error.NoSession;
        if (usable(&stored, now_seconds)) return stored;

        var refreshed = try self.rotateOrDie(did, &stored, client, proofs);
        refreshed.markObtained(now_seconds);
        errdefer refreshed.deinit();
        try self.store.save(did, &refreshed);
        return refreshed;
    }

    /// Persist a freshly authorized session for `did`, replacing any previous
    /// document. The caller sets the obtained-at time via `markObtained`.
    pub fn storeNew(self: *Sessions, did: []const u8, session: *const authorization.AuthorizedSession) Error!void {
        var guard = try self.store.lock();
        defer guard.release();
        try self.store.save(did, session);
    }

    pub fn has(self: *Sessions, did: []const u8) Error!bool {
        return (try self.store.load(did)) != null;
    }

    /// Remove the stored session for `did` (secure erase). Returns whether a
    /// document existed.
    pub fn remove(self: *Sessions, did: []const u8) Error!bool {
        var guard = try self.store.lock();
        defer guard.release();
        return self.store.remove(did);
    }

    pub fn list(self: *Sessions) Error![]const []u8 {
        return self.store.list();
    }

    pub fn deinitList(self: *Sessions, items: []const []u8) void {
        self.store.deinitDidList(items);
    }

    /// Rotate a stored session, or die. See the module comment for the
    /// fail-closed rules: a definitive rejection or an ambiguous failure both
    /// remove the stale document so the operator re-authorizes cleanly.
    fn rotateOrDie(
        self: *Sessions,
        did: []const u8,
        stored: *const authorization.AuthorizedSession,
        client: transport.Client,
        proofs: authorization.ProofSource,
    ) Error!authorization.AuthorizedSession {
        const refreshed = authorization.refresh(self.allocator, client, stored, proofs) catch |err| switch (err) {
            error.SessionRevoked, error.NoRefreshToken => {
                // The refresh token is definitively dead (revoked or absent).
                _ = try self.store.remove(did);
                return err;
            },
            error.OutOfMemory => return err,
            else => {
                // Ambiguous: the request may have reached the server and the
                // single-use refresh token may already be consumed. Fail
                // closed: drop the stale document and require re-authorization.
                _ = self.store.remove(did) catch {};
                return error.RefreshAmbiguous;
            },
        };
        // rotate-or-die: the old stored refresh token is single-use and has
        // been consumed. If the rotation cannot be persisted, never leave the
        // stale document behind to burn again on the next run.
        errdefer _ = self.store.remove(did) catch {};
        try self.store.save(did, &refreshed);
        return refreshed;
    }
};

const test_did = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";

const TestProof = struct {
    issued_at: u64,

    fn source(self: *const TestProof) authorization.ProofSource {
        return .{ .context = @constCast(self), .next_fn = next };
    }

    fn next(context: *anyopaque) authorization.Error!authorization.ProofMaterial {
        const self: *const TestProof = @ptrCast(@alignCast(context));
        return .{ .issued_at = self.issued_at, .jti_entropy = @splat(1), .signing_noise = @splat(2) };
    }
};

const RejectClient = struct {
    fn client(self: *RejectClient) transport.Client {
        return .{ .context = self, .request_fn = request };
    }

    fn request(_: *anyopaque, allocator: std.mem.Allocator, value: transport.Request) transport.Error!transport.Response {
        _ = allocator;
        _ = value;
        return error.UnexpectedRequest;
    }
};

const RefreshServingMock = struct {
    call: usize = 0,
    status: u16,
    nonce: []const u8,
    body: []const u8,
    fail_with: ?transport.Error = null,

    fn client(self: *RefreshServingMock) transport.Client {
        return .{ .context = self, .request_fn = request };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        value: transport.Request,
    ) transport.Error!transport.Response {
        const self: *RefreshServingMock = @ptrCast(@alignCast(context));
        if (self.fail_with) |failure| {
            self.fail_with = null;
            return failure;
        }
        if (self.call >= 1 or value.method != .post or
            !std.mem.eql(u8, value.url, "https://auth.example.com/token") or
            std.mem.indexOf(u8, value.body, "grant_type=refresh_token") == null)
        {
            return error.UnexpectedRequest;
        }
        self.call += 1;
        const headers = [_]transport.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "dpop-nonce", .value = self.nonce },
        };
        return transport.Response.initCopy(allocator, self.status, &headers, self.body, value.limits);
    }
};

fn makeStoredSession(allocator: std.mem.Allocator, obtained_at: u64) !authorization.AuthorizedSession {
    const key_seed: [32]u8 = @splat(9);
    return authorization.sessionFromWire(allocator, .{
        .did = test_did,
        .pds_origin = "https://pds.example.com",
        .authorization_server_origin = "https://auth.example.com",
        .authorization_endpoint = "https://auth.example.com/authorize",
        .token_endpoint = "https://auth.example.com/token",
        .pushed_authorization_request_endpoint = "https://auth.example.com/par",
        .verified_handle = null,
        .client_id = "http://localhost?redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Foauth%2Fcallback&scope=atproto%20include%3Asite.standard.authFull",
        .scope = "atproto include:site.standard.authFull",
        .access_token = "old-access",
        .refresh_token = "old-refresh",
        .key_seed = &key_seed,
        .authorization_server_nonce = "nonce-1",
        .access_token_expires_in = 3600,
        .access_token_obtained_at_seconds = obtained_at,
    });
}

const refresh_response = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"token_type\":\"DPoP\",\"sub\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"scope\":\"atproto include:site.standard.authFull\",\"expires_in\":7200}";

test "acquire reuses a fresh stored session without touching the network" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions = try Sessions.openIn(gpa, io, tmp.dir, "sessions");
    defer sessions.deinit();

    var session = try makeStoredSession(gpa, 1_700_000_000);
    session.markObtained(1_700_000_000);
    defer session.deinit();
    try sessions.storeNew(test_did, &session);

    var mock = RefreshServingMock{ .status = 200, .nonce = "n", .body = refresh_response };
    const now: u64 = 1_700_000_100; // 100s later, 3500s before expiry
    var proof = TestProof{ .issued_at = now };
    var acquired = try sessions.acquire(test_did, mock.client(), proof.source(), now);
    defer acquired.deinit();
    try std.testing.expectEqual(@as(usize, 0), mock.call); // no refresh
    try std.testing.expectEqualStrings("old-access", acquired.access_token.slice());
}

test "acquire refreshes an expired stored session and persists the rotation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions = try Sessions.openIn(gpa, io, tmp.dir, "sessions");
    defer sessions.deinit();

    var session = try makeStoredSession(gpa, 1_700_000_000);
    session.markObtained(1_700_000_000);
    defer session.deinit();
    try sessions.storeNew(test_did, &session);

    var mock = RefreshServingMock{ .status = 200, .nonce = "n", .body = refresh_response };
    const now: u64 = 1_700_010_000; // beyond 3600s expiry
    var proof = TestProof{ .issued_at = now };
    var acquired = try sessions.acquire(test_did, mock.client(), proof.source(), now);
    defer acquired.deinit();
    try std.testing.expectEqual(@as(usize, 1), mock.call);
    try std.testing.expectEqualStrings("new-access", acquired.access_token.slice());
    try std.testing.expectEqual(now, acquired.access_token_obtained_at_seconds);

    // The rotation was persisted: a second acquire sees the fresh token.
    var second_proof = TestProof{ .issued_at = now + 1 };
    var second = try sessions.acquire(test_did, mock.client(), second_proof.source(), now + 1);
    defer second.deinit();
    try std.testing.expectEqualStrings("new-access", second.access_token.slice());
}

test "acquire removes a revoked stored session and errors" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions = try Sessions.openIn(gpa, io, tmp.dir, "sessions");
    defer sessions.deinit();

    var session = try makeStoredSession(gpa, 1_700_000_000);
    session.markObtained(1_700_000_000);
    defer session.deinit();
    try sessions.storeNew(test_did, &session);

    var mock = RefreshServingMock{ .status = 400, .nonce = "n", .body = "{\"error\":\"invalid_grant\"}" };
    var proof = TestProof{ .issued_at = 1_700_010_000 };
    try std.testing.expectError(error.SessionRevoked, sessions.acquire(test_did, mock.client(), proof.source(), 1_700_010_000));
    try std.testing.expect(!(try sessions.has(test_did))); // stale document removed
}

test "acquire drops the document on ambiguous refresh and reports RefreshAmbiguous" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions = try Sessions.openIn(gpa, io, tmp.dir, "sessions");
    defer sessions.deinit();

    var session = try makeStoredSession(gpa, 1_700_000_000);
    session.markObtained(1_700_000_000);
    defer session.deinit();
    try sessions.storeNew(test_did, &session);

    var mock = RefreshServingMock{ .status = 0, .nonce = "", .body = "", .fail_with = error.Timeout };
    var proof = TestProof{ .issued_at = 1_700_010_000 };
    try std.testing.expectError(error.RefreshAmbiguous, sessions.acquire(test_did, mock.client(), proof.source(), 1_700_010_000));
    try std.testing.expect(!(try sessions.has(test_did)));
}

test "acquire reports NoSession when nothing is stored" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions = try Sessions.openIn(gpa, io, tmp.dir, "sessions");
    defer sessions.deinit();
    var reject = RejectClient{};
    var proof = TestProof{ .issued_at = 1_700_000_000 };
    try std.testing.expectError(error.NoSession, sessions.acquire(test_did, reject.client(), proof.source(), 1_700_000_000));
}

test "userRoot honors override and derives from HOME" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");
    const derived = try Sessions.userRoot(gpa, environ, null);
    defer gpa.free(derived);
    try std.testing.expectEqualStrings("/home/tester/.local/share/boris/sessions", derived);
    const overridden = try Sessions.userRoot(gpa, environ, "/tmp/custom-sessions");
    defer gpa.free(overridden);
    try std.testing.expectEqualStrings("/tmp/custom-sessions", overridden);
}

test "storeNew replaces an existing session document" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions = try Sessions.openIn(gpa, io, tmp.dir, "sessions");
    defer sessions.deinit();

    var first = try makeStoredSession(gpa, 1_700_000_000);
    defer first.deinit();
    first.markObtained(1_700_000_000);
    try sessions.storeNew(test_did, &first);

    var second = try makeStoredSession(gpa, 1_700_000_000);
    defer second.deinit();
    second.markObtained(1_700_000_000);
    try sessions.storeNew(test_did, &second);

    const listed = try sessions.list();
    defer sessions.deinitList(listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings(test_did, listed[0]);
}
