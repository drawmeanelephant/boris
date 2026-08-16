//! Host session store: user-scoped, 0600, atomic replace, process-safe lock.
//!
//! Each authorized session is persisted as one JSON document named by the hex
//! encoding of its DID (`session-<hex>.json`) inside a 0700 root directory.
//! Writes go through an unnamed temporary file plus atomic rename so a crash
//! never leaves a half-written session. A dedicated lock file serializes
//! mutations across processes (the advisory lock is released by the OS when
//! the process dies, so a crashed holder cannot wedge the store).
//!
//! Secrets (access token, refresh token, DPoP key seed) are written only into
//! the 0600 session document. On remove, the document is securely zeroed
//! before unlink. Nothing here ever prints or logs token material.

const std = @import("std");
const authorization = @import("atproto_authorization.zig");
const json_out = @import("json_out.zig");

pub const Error = authorization.Error || std.mem.Allocator.Error || error{
    StoreCorrupt,
    StoreExists,
    StoreFull,
    StoreIo,
    StoreLocked,
    StoreNotFound,
    StorePermissionDenied,
    StoreUnexpected,
};

const file_prefix = "session-";
const lock_name = "lock";
const max_session_document_bytes = 64 * 1024;
const max_did_bytes = 2048;

/// Map any host I/O error to the closed store error set, keyed by error name
/// so generic call sites do not depend on the exact error sets of each vtable
/// operation.
fn mapError(err: anytype) Error {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, name, "AccessDenied") or
        std.mem.eql(u8, name, "PermissionDenied") or
        std.mem.eql(u8, name, "ReadOnlyFileSystem") or
        std.mem.eql(u8, name, "SymLinkLoop")) return error.StorePermissionDenied;
    if (std.mem.eql(u8, name, "FileNotFound") or
        std.mem.eql(u8, name, "NotDir") or
        std.mem.eql(u8, name, "Streaming")) return error.StoreNotFound;
    if (std.mem.eql(u8, name, "PathAlreadyExists")) return error.StoreExists;
    if (std.mem.eql(u8, name, "NoSpaceLeft") or
        std.mem.eql(u8, name, "DiskQuota") or
        std.mem.eql(u8, name, "FileTooBig") or
        std.mem.eql(u8, name, "LinkQuotaExceeded")) return error.StoreFull;
    if (std.mem.eql(u8, name, "WouldBlock") or
        std.mem.eql(u8, name, "Locked") or
        std.mem.eql(u8, name, "FileBusy") or
        std.mem.eql(u8, name, "FileLocksUnsupported")) return error.StoreLocked;
    return error.StoreIo;
}

fn appendHex(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    const digits = "0123456789abcdef";
    for (bytes) |byte| {
        try buf.append(gpa, digits[byte >> 4]);
        try buf.append(gpa, digits[byte & 15]);
    }
}

fn decodeHex(allocator: std.mem.Allocator, hex: []const u8) Error![]u8 {
    if (hex.len % 2 != 0) return error.StoreCorrupt;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    var index: usize = 0;
    while (index < hex.len) : (index += 2) {
        out[index / 2] = (try nibbleOf(hex[index]) << 4) | try nibbleOf(hex[index + 1]);
    }
    return out;
}

fn nibbleOf(digit: u8) Error!u8 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'a'...'f' => digit - 'a' + 10,
        'A'...'F' => digit - 'A' + 10,
        else => error.StoreCorrupt,
    };
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,

    /// Create (if needed) the 0700 root and open it. `root_path` must be
    /// absolute; the directory is created with owner-only permissions.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) Error!Store {
        if (!std.fs.path.isAbsolute(root_path)) return error.StoreUnexpected;
        const cwd = std.Io.Dir.cwd();
        _ = cwd.createDirPathStatus(io, root_path, std.Io.File.Permissions.fromMode(0o700)) catch |err| return mapError(err);
        const dir = std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true }) catch |err| return mapError(err);
        return .{ .allocator = allocator, .io = io, .dir = dir };
    }

    /// Open a store rooted at `sub_path` inside an already-open parent
    /// directory (used by tests; the root is created owner-only).
    pub fn openIn(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, sub_path: []const u8) Error!Store {
        _ = parent.createDirPathStatus(io, sub_path, std.Io.File.Permissions.fromMode(0o700)) catch |err| return mapError(err);
        const dir = parent.openDir(io, sub_path, .{ .iterate = true }) catch |err| return mapError(err);
        return .{ .allocator = allocator, .io = io, .dir = dir };
    }

    pub fn deinit(self: *Store) void {
        self.dir.close(self.io);
        self.* = undefined;
    }

    fn fileNameForDid(self: *Store, did: []const u8) Error![]u8 {
        if (did.len == 0 or did.len > max_did_bytes) return error.StoreUnexpected;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, file_prefix);
        try appendHex(&buf, self.allocator, did);
        try buf.appendSlice(self.allocator, ".json");
        return buf.toOwnedSlice(self.allocator);
    }

    fn didFromFileName(self: *Store, name: []const u8) Error!?[]u8 {
        if (!std.mem.startsWith(u8, name, file_prefix) or !std.mem.endsWith(u8, name, ".json")) return null;
        const hex = name[file_prefix.len .. name.len - ".json".len];
        if (hex.len == 0 or hex.len % 2 != 0) return null;
        return decodeHex(self.allocator, hex) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    /// Acquire the exclusive process-safe lock, held for the returned guard's
    /// lifetime. The lock is released by the OS if the process dies, so a
    /// crashed holder cannot wedge the store.
    pub fn lock(self: *Store) Error!LockGuard {
        const file = self.dir.createFile(self.io, lock_name, .{
            .lock = .exclusive,
            .truncate = false,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| return mapError(err);
        return .{ .store = self, .file = file };
    }

    pub const LockGuard = struct {
        store: *Store,
        file: std.Io.File,

        pub fn release(self: *LockGuard) void {
            self.file.unlock(self.store.io);
            self.file.close(self.store.io);
            self.* = undefined;
        }
    };

    /// Persist a session under the given DID, atomically replacing any
    /// previous document for that DID.
    pub fn save(self: *Store, did: []const u8, session: *const authorization.AuthorizedSession) Error!void {
        const file_name = try self.fileNameForDid(did);
        defer self.allocator.free(file_name);
        const bytes = try sessionToWireBytes(self.allocator, session);
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }

        var atomic = self.dir.createFileAtomic(self.io, file_name, .{
            .replace = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| return mapError(err);
        defer atomic.deinit(self.io);
        var write_buffer: [4096]u8 = undefined;
        var file_writer = atomic.file.writer(self.io, &write_buffer);
        file_writer.interface.writeAll(bytes) catch |err| return mapError(err);
        file_writer.interface.flush() catch |err| return mapError(err);
        atomic.replace(self.io) catch |err| return mapError(err);
    }

    /// Load the session for `did`. Returns `null` when no session exists.
    pub fn load(self: *Store, did: []const u8) Error!?authorization.AuthorizedSession {
        const file_name = try self.fileNameForDid(did);
        defer self.allocator.free(file_name);
        var read_buffer: [16 * 1024]u8 = undefined;
        const file = self.dir.openFile(self.io, file_name, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return mapError(err),
        };
        defer file.close(self.io);
        var file_reader = file.reader(self.io, &read_buffer);
        const bytes = file_reader.interface.allocRemaining(self.allocator, .limited(max_session_document_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.StoreCorrupt,
            error.OutOfMemory => return error.OutOfMemory,
            else => return mapError(err),
        };
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        return try sessionFromWireBytes(self.allocator, bytes);
    }

    /// Delete the session for `did`, securely zeroing the document first.
    /// Returns whether a document existed.
    pub fn remove(self: *Store, did: []const u8) Error!bool {
        const file_name = try self.fileNameForDid(did);
        defer self.allocator.free(file_name);
        var read_buffer: [16 * 1024]u8 = undefined;
        var file = self.dir.openFile(self.io, file_name, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return mapError(err),
        };
        defer file.close(self.io);
        var file_reader = file.reader(self.io, &read_buffer);
        const bytes = file_reader.interface.allocRemaining(self.allocator, .limited(max_session_document_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.StoreCorrupt,
            error.OutOfMemory => return error.OutOfMemory,
            else => return mapError(err),
        };
        std.crypto.secureZero(u8, bytes);
        self.allocator.free(bytes);
        self.dir.deleteFile(self.io, file_name) catch |err| return mapError(err);
        return true;
    }

    /// Enumerate stored DIDs (sorted). The returned slice owns both the array
    /// and each DID string; free with `deinitDidList`.
    pub fn list(self: *Store) Error![]const []u8 {
        var result: std.ArrayList([]u8) = .empty;
        errdefer {
            for (result.items) |item| self.allocator.free(item);
            result.deinit(self.allocator);
        }
        var iterator = self.dir.iterate();
        while (iterator.next(self.io) catch |err| return mapError(err)) |entry| {
            if (entry.kind != .file) continue;
            if (try self.didFromFileName(entry.name)) |did| {
                try result.append(self.allocator, did);
            }
        }
        std.mem.sort([]u8, result.items, {}, lessThan);
        return result.toOwnedSlice(self.allocator);
    }

    fn lessThan(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    pub fn deinitDidList(self: *Store, items: []const []u8) void {
        for (items) |item| self.allocator.free(item);
        self.allocator.free(items);
    }
};

/// Serialize an authorized session to the on-disk JSON document. Secret
/// material (tokens, nonce, key seed) is hex-encoded but never logged; the
/// caller must zero and free the returned bytes after writing.
pub fn sessionToWireBytes(allocator: std.mem.Allocator, session: *const authorization.AuthorizedSession) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "format", .value = "boris-session-v1" },
        .{ .name = "did", .value = session.account.did.slice() },
        .{ .name = "pds_origin", .value = session.account.pds_origin.slice() },
        .{ .name = "authorization_server_origin", .value = session.account.authorization_server_origin.slice() },
        .{ .name = "authorization_endpoint", .value = session.account.authorization_endpoint.slice() },
        .{ .name = "token_endpoint", .value = session.account.token_endpoint.slice() },
        .{ .name = "pushed_authorization_request_endpoint", .value = session.account.pushed_authorization_request_endpoint.slice() },
        .{ .name = "client_id", .value = session.client_id.slice() },
        .{ .name = "scope", .value = session.scope.slice() },
        .{ .name = "access_token", .value = session.access_token.slice() },
        .{ .name = "authorization_server_nonce", .value = session.authorization_server_nonce.slice() },
    };
    for (fields) |field| {
        try json_out.indent(&buf, allocator, 1);
        try json_out.writeString(&buf, allocator, field.name);
        try buf.appendSlice(allocator, ": ");
        try json_out.writeString(&buf, allocator, field.value);
        try buf.appendSlice(allocator, ",\n");
    }

    try json_out.indent(&buf, allocator, 1);
    try json_out.writeString(&buf, allocator, "verified_handle");
    try buf.appendSlice(allocator, ": ");
    if (session.account.verified_handle) |handle| {
        try json_out.writeString(&buf, allocator, handle.slice());
    } else {
        try json_out.writeNull(&buf, allocator);
    }
    try buf.appendSlice(allocator, ",\n");

    try json_out.indent(&buf, allocator, 1);
    try json_out.writeString(&buf, allocator, "refresh_token");
    try buf.appendSlice(allocator, ": ");
    if (session.refresh_token) |token| {
        try json_out.writeString(&buf, allocator, token.slice());
    } else {
        try json_out.writeNull(&buf, allocator);
    }
    try buf.appendSlice(allocator, ",\n");

    try json_out.indent(&buf, allocator, 1);
    try json_out.writeString(&buf, allocator, "key_seed_hex");
    try buf.appendSlice(allocator, ": \"");
    try appendHex(&buf, allocator, &session.key_seed);
    try buf.appendSlice(allocator, "\",\n");

    try json_out.indent(&buf, allocator, 1);
    try json_out.writeString(&buf, allocator, "access_token_expires_in");
    try buf.appendSlice(allocator, ": ");
    try json_out.writeUsize(&buf, allocator, session.access_token_expires_in);
    try buf.appendSlice(allocator, ",\n");

    try json_out.indent(&buf, allocator, 1);
    try json_out.writeString(&buf, allocator, "access_token_obtained_at_seconds");
    try buf.appendSlice(allocator, ": ");
    try json_out.writeUsize(&buf, allocator, session.access_token_obtained_at_seconds);
    try buf.appendSlice(allocator, "\n");

    try buf.appendSlice(allocator, "}\n");
    return buf.toOwnedSlice(allocator);
}

/// Rebuild an owned, revalidated session from a wire document. Every field is
/// parsed and checked by `sessionFromWire`, so a tampered or corrupt document
/// fails closed.
pub fn sessionFromWireBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!authorization.AuthorizedSession {
    if (bytes.len == 0 or bytes.len > max_session_document_bytes) return error.StoreCorrupt;
    const Parsed = struct {
        format: []const u8,
        did: []const u8,
        pds_origin: []const u8,
        authorization_server_origin: []const u8,
        authorization_endpoint: []const u8,
        token_endpoint: []const u8,
        pushed_authorization_request_endpoint: []const u8,
        verified_handle: ?[]const u8 = null,
        client_id: []const u8,
        scope: []const u8,
        access_token: []const u8,
        refresh_token: ?[]const u8 = null,
        key_seed_hex: []const u8,
        authorization_server_nonce: []const u8,
        access_token_expires_in: u64,
        access_token_obtained_at_seconds: u64 = 0,
    };
    var parsed = std.json.parseFromSlice(Parsed, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .max_value_len = max_session_document_bytes,
        .allocate = .alloc_always,
    }) catch return error.StoreCorrupt;
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.format, "boris-session-v1")) return error.StoreCorrupt;
    const key_seed = decodeHex(allocator, value.key_seed_hex) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StoreCorrupt,
    };
    defer {
        std.crypto.secureZero(u8, key_seed);
        allocator.free(key_seed);
    }
    return authorization.sessionFromWire(allocator, .{
        .did = value.did,
        .pds_origin = value.pds_origin,
        .authorization_server_origin = value.authorization_server_origin,
        .authorization_endpoint = value.authorization_endpoint,
        .token_endpoint = value.token_endpoint,
        .pushed_authorization_request_endpoint = value.pushed_authorization_request_endpoint,
        .verified_handle = value.verified_handle,
        .client_id = value.client_id,
        .scope = value.scope,
        .access_token = value.access_token,
        .refresh_token = value.refresh_token,
        .key_seed = key_seed,
        .authorization_server_nonce = value.authorization_server_nonce,
        .access_token_expires_in = value.access_token_expires_in,
        .access_token_obtained_at_seconds = value.access_token_obtained_at_seconds,
    });
}

const test_did = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";

fn makeTestSession(allocator: std.mem.Allocator) !authorization.AuthorizedSession {
    const key_seed: [32]u8 = @splat(7);
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
        .access_token = "access-token",
        .refresh_token = "refresh-token",
        .key_seed = &key_seed,
        .authorization_server_nonce = "nonce-1",
        .access_token_expires_in = 3600,
        .access_token_obtained_at_seconds = 1_700_000_000,
    });
}

test "store saves, loads, lists, and removes sessions with no leaks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.openIn(gpa, io, tmp.dir, "sessions");
    defer store.deinit();

    var session = try makeTestSession(gpa);
    defer session.deinit();
    try store.save(test_did, &session);

    var loaded = (try store.load(test_did)) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    try std.testing.expectEqualStrings("access-token", loaded.access_token.slice());
    try std.testing.expectEqualStrings("refresh-token", loaded.refresh_token.?.slice());
    try std.testing.expectEqualStrings(test_did, loaded.account.did.slice());
    try std.testing.expectEqual(@as(u64, 3600), loaded.access_token_expires_in);

    const listed = try store.list();
    defer store.deinitDidList(listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings(test_did, listed[0]);

    try std.testing.expect(try store.remove(test_did));
    try std.testing.expect(!(try store.remove(test_did)));
    try std.testing.expect((try store.load(test_did)) == null);
    const after = try store.list();
    defer store.deinitDidList(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "tampered session documents fail closed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.openIn(gpa, io, tmp.dir, "sessions");
    defer store.deinit();

    var session = try makeTestSession(gpa);
    defer session.deinit();
    try store.save(test_did, &session);

    const file_name = try store.fileNameForDid(test_did);
    defer gpa.free(file_name);
    const raw = try store.dir.readFileAlloc(io, file_name, gpa, .limited(max_session_document_bytes));
    defer gpa.free(raw);
    const tampered = try std.mem.replaceOwned(u8, gpa, raw, "access-token", "bad token");
    defer gpa.free(tampered);
    try store.dir.writeFile(io, .{ .sub_path = file_name, .data = tampered, .flags = .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) } });

    try std.testing.expectError(error.InvalidSessionWire, store.load(test_did));
}

test "lock acquires and store survives a second open" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.openIn(gpa, io, tmp.dir, "sessions");
    defer store.deinit();
    var guard = try store.lock();
    defer guard.release();

    var second = try Store.openIn(gpa, io, tmp.dir, "sessions");
    defer second.deinit();
    var session = try makeTestSession(gpa);
    defer session.deinit();
    try second.save(test_did, &session);
    try std.testing.expect((try second.load(test_did)) != null);
}
