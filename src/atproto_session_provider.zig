//! Protected ATProto session provider protocol (version 1).
//!
//! A trusted launcher connects Boris to its OS keychain broker with private,
//! bidirectional pipes. Newline-delimited JSON is framed and bounded; every
//! response must echo the request id, operation, DID, and per-process instance.
//! Session documents cross only this channel as bounded base64. This module
//! never opens files, reads environment variables, or writes diagnostics.

const std = @import("std");
const authorization = @import("atproto_authorization.zig");
const password = @import("atproto_password.zig");
const store = @import("atproto_session_store.zig");
const transport = @import("atproto_transport.zig");
const session_std = @import("atproto_session_std.zig");

pub const protocol_name = "boris-session-provider";
pub const protocol_version = 1;
pub const max_frame_bytes = 128 * 1024;
pub const max_secret_bytes = 1024;

pub const Error = session_std.Error || error{
    ProviderMalformed,
    ProviderClosed,
    ProviderDenied,
    ProviderUnavailable,
};

pub const Channel = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, []u8) Channel.Error!usize,
    write_fn: *const fn (*anyopaque, []const u8) Channel.Error!void,

    pub const Error = error{ ReadFailed, WriteFailed };
};

const Flavor = enum { oauth, @"app-password" };

const Response = struct {
    protocol: []const u8,
    version: u32,
    kind: []const u8,
    instance: []const u8,
    id: ?u64 = null,
    operation: ?[]const u8 = null,
    did: ?[]const u8 = null,
    status: ?[]const u8 = null,
    found: ?bool = null,
    flavor: ?Flavor = null,
    session: ?[]const u8 = null,
    removed: ?bool = null,
    app_password: ?[]const u8 = null,
    entries: ?[]const PublicEntry = null,
};

const PublicEntry = struct {
    did: []const u8,
    flavor: Flavor,
    pds_origin: []const u8,
};

pub const Provider = struct {
    allocator: std.mem.Allocator,
    channel: Channel,
    instance: []const u8,
    next_id: u64 = 1,

    pub fn connect(allocator: std.mem.Allocator, channel: Channel, instance: []const u8) Error!Provider {
        if (instance.len == 0 or instance.len > 128) return error.ProviderMalformed;
        const owned_instance = allocator.dupe(u8, instance) catch return error.OutOfMemory;
        errdefer allocator.free(owned_instance);
        var self = Provider{ .allocator = allocator, .channel = channel, .instance = owned_instance };
        try self.send(.{
            .protocol = protocol_name,
            .version = protocol_version,
            .kind = "hello",
            .instance = instance,
        });
        const bytes = try self.readFrame();
        defer {
            std.crypto.secureZero(u8, bytes);
            allocator.free(bytes);
        }
        var parsed = std.json.parseFromSlice(Response, allocator, bytes, .{
            .max_value_len = max_frame_bytes,
            .allocate = .alloc_always,
        }) catch return error.ProviderMalformed;
        defer parsed.deinit();
        const r = parsed.value;
        if (!std.mem.eql(u8, r.protocol, protocol_name) or r.version != protocol_version or
            !std.mem.eql(u8, r.kind, "hello") or !std.mem.eql(u8, r.instance, instance)) return error.ProviderMalformed;
        return self;
    }

    pub fn deinit(self: *Provider) void {
        self.allocator.free(self.instance);
        self.* = undefined;
    }

    fn send(self: *Provider, value: anytype) Error!void {
        const json = std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, json);
            self.allocator.free(json);
        }
        if (json.len + 1 > max_frame_bytes) return error.ProviderMalformed;
        self.channel.write_fn(self.channel.context, json) catch return error.ProviderUnavailable;
        self.channel.write_fn(self.channel.context, "\n") catch return error.ProviderUnavailable;
    }

    fn readFrame(self: *Provider) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer {
            std.crypto.secureZero(u8, out.items);
            out.deinit(self.allocator);
        }
        var one: [1]u8 = undefined;
        while (out.items.len < max_frame_bytes) {
            const count = self.channel.read_fn(self.channel.context, &one) catch return error.ProviderUnavailable;
            if (count == 0) return error.ProviderClosed;
            if (count != 1) return error.ProviderMalformed;
            if (one[0] == '\n') {
                if (out.items.len == 0) return error.ProviderMalformed;
                return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            }
            if (one[0] == '\r' or one[0] == 0) return error.ProviderMalformed;
            out.append(self.allocator, one[0]) catch return error.OutOfMemory;
        }
        return error.ProviderMalformed;
    }

    fn transact(self: *Provider, operation: []const u8, did: ?[]const u8, session: ?[]const u8, flavor: ?Flavor) Error![]u8 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (id == 0) return error.ProviderMalformed;
        if (session) |bytes| {
            try self.send(.{ .protocol = protocol_name, .version = protocol_version, .kind = "request", .id = id, .operation = operation, .did = did, .instance = self.instance, .flavor = flavor.?, .session = bytes });
        } else {
            try self.send(.{ .protocol = protocol_name, .version = protocol_version, .kind = "request", .id = id, .operation = operation, .did = did, .instance = self.instance, .flavor = flavor });
        }
        const bytes = try self.readFrame();
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        var parsed = std.json.parseFromSlice(Response, self.allocator, bytes, .{
            .max_value_len = max_frame_bytes,
            .allocate = .alloc_always,
        }) catch return error.ProviderMalformed;
        defer parsed.deinit();
        const r = parsed.value;
        if (!std.mem.eql(u8, r.protocol, protocol_name) or r.version != protocol_version or
            !std.mem.eql(u8, r.kind, "response") or !std.mem.eql(u8, r.instance, self.instance) or
            r.id == null or r.id.? != id or r.operation == null or !std.mem.eql(u8, r.operation.?, operation) or
            r.status == null) return error.ProviderMalformed;
        if (did) |expected| {
            if (r.did == null or !std.mem.eql(u8, r.did.?, expected)) return error.ProviderMalformed;
        } else if (r.did != null) return error.ProviderMalformed;
        if (std.mem.eql(u8, r.status.?, "denied")) return error.ProviderDenied;
        if (!std.mem.eql(u8, r.status.?, "ok") and !std.mem.eql(u8, r.status.?, "not_found")) return error.ProviderMalformed;
        if (std.mem.eql(u8, operation, "load")) {
            if (std.mem.eql(u8, r.status.?, "not_found")) {
                if (r.session != null or r.found == null or r.found.?) return error.ProviderMalformed;
                return self.allocator.dupe(u8, "") catch return error.OutOfMemory;
            }
            if (r.found == null or !r.found.? or r.flavor == null or r.flavor.? != flavor.?) return error.ProviderMalformed;
            const value = r.session orelse return error.ProviderMalformed;
            return self.allocator.dupe(u8, value) catch return error.OutOfMemory;
        }
        if (std.mem.eql(u8, operation, "app-password")) {
            if (!std.mem.eql(u8, r.status.?, "ok")) return error.ProviderMalformed;
            const value = r.app_password orelse return error.ProviderMalformed;
            return self.allocator.dupe(u8, value) catch return error.OutOfMemory;
        }
        return error.ProviderMalformed;
    }

    fn transactMeta(self: *Provider, operation: []const u8, did: []const u8, session: ?[]const u8, flavor: ?Flavor) Error!struct { status: []u8, removed: bool, response_flavor: ?Flavor } {
        const id = self.next_id;
        self.next_id +%= 1;
        if (id == 0) return error.ProviderMalformed;
        if (session) |bytes| {
            try self.send(.{ .protocol = protocol_name, .version = protocol_version, .kind = "request", .id = id, .operation = operation, .did = did, .instance = self.instance, .flavor = flavor.?, .session = bytes });
        } else {
            try self.send(.{ .protocol = protocol_name, .version = protocol_version, .kind = "request", .id = id, .operation = operation, .did = did, .instance = self.instance, .flavor = flavor });
        }
        const bytes = try self.readFrame();
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        var parsed = std.json.parseFromSlice(Response, self.allocator, bytes, .{ .max_value_len = max_frame_bytes, .allocate = .alloc_always }) catch return error.ProviderMalformed;
        defer parsed.deinit();
        const r = parsed.value;
        if (!std.mem.eql(u8, r.protocol, protocol_name) or r.version != protocol_version or !std.mem.eql(u8, r.kind, "response") or
            !std.mem.eql(u8, r.instance, self.instance) or r.id == null or r.id.? != id or r.operation == null or
            !std.mem.eql(u8, r.operation.?, operation) or r.did == null or !std.mem.eql(u8, r.did.?, did) or r.status == null) return error.ProviderMalformed;
        if (std.mem.eql(u8, r.status.?, "denied")) return error.ProviderDenied;
        if (std.mem.eql(u8, operation, "remove") and r.removed == null) return error.ProviderMalformed;
        return .{
            .status = self.allocator.dupe(u8, r.status.?) catch return error.OutOfMemory,
            .removed = r.removed orelse false,
            .response_flavor = r.flavor,
        };
    }

    fn loadPassword(self: *Provider, did: []const u8) Error!?password.AppPasswordSession {
        const encoded = try self.transact("load", did, null, .@"app-password");
        defer {
            std.crypto.secureZero(u8, encoded);
            self.allocator.free(encoded);
        }
        if (encoded.len == 0) return null;
        const session = decodePassword(self.allocator, encoded) catch |err| switch (err) {
            error.WrongDocumentType => return error.WrongDocumentType,
            else => return err,
        };
        if (!std.mem.eql(u8, session.did.slice(), did)) {
            var mutable = session;
            mutable.deinit();
            return error.ProviderMalformed;
        }
        return session;
    }

    fn loadOAuth(self: *Provider, did: []const u8) Error!?authorization.AuthorizedSession {
        const encoded = try self.transact("load", did, null, .oauth);
        defer {
            std.crypto.secureZero(u8, encoded);
            self.allocator.free(encoded);
        }
        if (encoded.len == 0) return null;
        const session = try decodeOAuth(self.allocator, encoded);
        if (!std.mem.eql(u8, session.account.did.slice(), did)) {
            var mutable = session;
            mutable.deinit();
            return error.ProviderMalformed;
        }
        return session;
    }

    pub fn storeNew(self: *Provider, did: []const u8, session: *const authorization.AuthorizedSession) Error!void {
        if (!std.mem.eql(u8, did, session.account.did.slice())) return error.ProviderMalformed;
        const wire = try store.sessionToWireBytes(self.allocator, session);
        defer {
            std.crypto.secureZero(u8, wire);
            self.allocator.free(wire);
        }
        const encoded = try encode(self.allocator, wire);
        defer {
            std.crypto.secureZero(u8, encoded);
            self.allocator.free(encoded);
        }
        const meta = try self.transactMeta("save", did, encoded, .oauth);
        defer self.allocator.free(meta.status);
        if (!std.mem.eql(u8, meta.status, "ok")) return error.ProviderMalformed;
    }

    pub fn storeNewPassword(self: *Provider, did: []const u8, session: *const password.AppPasswordSession) Error!void {
        if (!std.mem.eql(u8, did, session.did.slice())) return error.ProviderMalformed;
        const wire = try store.passwordToWireBytes(self.allocator, session);
        defer {
            std.crypto.secureZero(u8, wire);
            self.allocator.free(wire);
        }
        const encoded = try encode(self.allocator, wire);
        defer {
            std.crypto.secureZero(u8, encoded);
            self.allocator.free(encoded);
        }
        const meta = try self.transactMeta("save", did, encoded, .@"app-password");
        defer self.allocator.free(meta.status);
        if (!std.mem.eql(u8, meta.status, "ok")) return error.ProviderMalformed;
    }

    pub fn hasDocument(self: *Provider, did: []const u8) Error!bool {
        const entries = try self.listEntries();
        defer self.deinitListEntries(entries);
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.did, did)) return true;
        }
        return false;
    }

    pub fn listEntries(self: *Provider) Error![]store.ListedSession {
        const id = self.next_id;
        self.next_id +%= 1;
        if (id == 0) return error.ProviderMalformed;
        try self.send(.{ .protocol = protocol_name, .version = protocol_version, .kind = "request", .id = id, .operation = "list", .did = null, .instance = self.instance });
        const bytes = try self.readFrame();
        defer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        var parsed = std.json.parseFromSlice(Response, self.allocator, bytes, .{ .max_value_len = max_frame_bytes, .allocate = .alloc_always }) catch return error.ProviderMalformed;
        defer parsed.deinit();
        const r = parsed.value;
        if (!std.mem.eql(u8, r.protocol, protocol_name) or r.version != protocol_version or !std.mem.eql(u8, r.kind, "response") or
            !std.mem.eql(u8, r.instance, self.instance) or r.id == null or r.id.? != id or r.operation == null or
            !std.mem.eql(u8, r.operation.?, "list") or r.did != null or r.status == null or !std.mem.eql(u8, r.status.?, "ok")) return error.ProviderMalformed;
        const source = r.entries orelse return error.ProviderMalformed;
        if (source.len > 1024) return error.ProviderMalformed;
        const result = self.allocator.alloc(store.ListedSession, source.len) catch return error.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |entry| {
                self.allocator.free(entry.did);
                self.allocator.free(entry.pds_origin);
            }
            self.allocator.free(result);
        }
        for (source, 0..) |entry, index| {
            result[index] = .{
                .did = self.allocator.dupe(u8, entry.did) catch return error.OutOfMemory,
                .flavor = if (entry.flavor == .oauth) .oauth else .app_password,
                .pds_origin = self.allocator.dupe(u8, entry.pds_origin) catch return error.OutOfMemory,
            };
            initialized += 1;
        }
        return result;
    }

    pub fn deinitListEntries(self: *Provider, entries: []store.ListedSession) void {
        for (entries) |entry| {
            self.allocator.free(entry.did);
            self.allocator.free(entry.pds_origin);
        }
        self.allocator.free(entries);
    }
    pub fn remove(self: *Provider, did: []const u8) Error!bool {
        const meta = try self.transactMeta("remove", did, null, null);
        defer self.allocator.free(meta.status);
        if (!std.mem.eql(u8, meta.status, "ok") and !std.mem.eql(u8, meta.status, "not_found")) return error.ProviderMalformed;
        return meta.removed;
    }

    pub fn readAppPassword(self: *Provider, did: []const u8) Error![]u8 {
        const secret = try self.transact("app-password", did, null, null);
        errdefer {
            std.crypto.secureZero(u8, secret);
            self.allocator.free(secret);
        }
        if (secret.len == 0 or secret.len > max_secret_bytes or std.mem.indexOfAny(u8, secret, "\r\n") != null) return error.ProviderMalformed;
        return secret;
    }

    pub fn acquirePassword(self: *Provider, did: []const u8, client: transport.Client, now_seconds: u64) Error!password.AppPasswordSession {
        var stored = (try self.loadPassword(did)) orelse return error.NoSession;
        if (usablePassword(&stored, now_seconds)) return stored;
        defer stored.deinit();
        var refreshed = password.refresh(self.allocator, client, &stored) catch |err| switch (err) {
            error.SessionRevoked => {
                _ = try self.remove(did);
                return error.SessionRevoked;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                _ = self.remove(did) catch {};
                return error.RefreshAmbiguous;
            },
        };
        refreshed.markObtained(now_seconds);
        errdefer refreshed.deinit();
        // A successful single-use rotation must reach the keychain before the
        // new session can be used. Never retain the stale broker copy.
        errdefer _ = self.remove(did) catch {};
        try self.storeNewPassword(did, &refreshed);
        return refreshed;
    }

    pub fn acquire(self: *Provider, did: []const u8, client: transport.Client, proofs: authorization.ProofSource, now_seconds: u64) Error!authorization.AuthorizedSession {
        var stored = (try self.loadOAuth(did)) orelse return error.NoSession;
        if (usable(&stored, now_seconds)) return stored;
        defer stored.deinit();
        var refreshed = authorization.refresh(self.allocator, client, &stored, proofs) catch |err| switch (err) {
            error.SessionRevoked, error.NoRefreshToken => {
                _ = try self.remove(did);
                return err;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                _ = self.remove(did) catch {};
                return error.RefreshAmbiguous;
            },
        };
        refreshed.markObtained(now_seconds);
        errdefer refreshed.deinit();
        errdefer _ = self.remove(did) catch {};
        try self.storeNew(did, &refreshed);
        return refreshed;
    }
};

fn encode(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    const result = allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len)) catch return error.OutOfMemory;
    _ = std.base64.standard.Encoder.encode(result, bytes);
    return result;
}

fn decode(allocator: std.mem.Allocator, encoded: []const u8) Error![]u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.ProviderMalformed;
    if (size == 0 or size > 64 * 1024) return error.ProviderMalformed;
    const result = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(result);
    std.base64.standard.Decoder.decode(result, encoded) catch return error.ProviderMalformed;
    return result;
}

fn decodePassword(allocator: std.mem.Allocator, encoded: []const u8) Error!password.AppPasswordSession {
    const wire = try decode(allocator, encoded);
    defer {
        std.crypto.secureZero(u8, wire);
        allocator.free(wire);
    }
    return store.passwordFromWireBytes(allocator, wire) catch |err| switch (err) {
        error.WrongDocumentType => return error.WrongDocumentType,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProviderMalformed,
    };
}

fn decodeOAuth(allocator: std.mem.Allocator, encoded: []const u8) Error!authorization.AuthorizedSession {
    const wire = try decode(allocator, encoded);
    defer {
        std.crypto.secureZero(u8, wire);
        allocator.free(wire);
    }
    return store.sessionFromWireBytes(allocator, wire) catch |err| switch (err) {
        error.WrongDocumentType => return error.WrongDocumentType,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProviderMalformed,
    };
}

fn usable(session: *const authorization.AuthorizedSession, now: u64) bool {
    if (session.access_token_obtained_at_seconds == 0 or session.access_token_expires_in <= session_std.refresh_early_skew_seconds) return false;
    return now +| session_std.refresh_early_skew_seconds < session.access_token_obtained_at_seconds +| session.access_token_expires_in;
}

fn usablePassword(session: *const password.AppPasswordSession, now: u64) bool {
    if (session.access_token_obtained_at_seconds == 0 or session.access_token_expires_in <= session_std.refresh_early_skew_seconds) return false;
    return now +| session_std.refresh_early_skew_seconds < session.access_token_obtained_at_seconds +| session.access_token_expires_in;
}
