//! Policy file model for boris-content-audit.
//!
//! The policy is an optional, versioned JSON document that defines the
//! editorial expectations the audit measures. Nothing in the policy mutates
//! source content; it only selects and labels observations.
//!
//! Schema (schema_version 1):
//! ```json
//! {
//!   "schema_version": 1,
//!   "eligible_collections": { "<collection>": ["<poetry-type>", ...] },
//!   "poetry_collections": { "<collection>": "<poetry-type>" },
//!   "excluded_statuses": ["draft"],
//!   "excluded_ids": [],
//!   "placeholder": {
//!     "exact_lines": ["Awaiting context"],
//!     "title_prefixes": ["Stub:"],
//!     "case_sensitive": false
//!   },
//!   "density_bands": { "<poetry-type>": [1, 5, 8] },
//!   "exact_mappings": { "<poetry-id>": "<source-id>" },
//!   "mapping_relation_kinds": ["relates_to"]
//! }
//! ```
//!
//! A policy is malformed (exit 4) when it is not valid JSON, uses an
//! unsupported schema_version, or violates the structural rules below.

const std = @import("std");
const util = @import("util.zig");

pub const supported_schema_version: u32 = 1;

pub const PlaceholderPolicy = struct {
    exact_lines: []const []const u8 = &.{},
    title_prefixes: []const []const u8 = &.{},
    case_sensitive: bool = false,
};

pub const Policy = struct {
    schema_version: u32 = supported_schema_version,
    eligible_collections: std.StringHashMapUnmanaged([]const []const u8) = .{},
    poetry_collections: std.StringHashMapUnmanaged([]const u8) = .{},
    excluded_statuses: []const []const u8 = &.{},
    excluded_ids: []const []const u8 = &.{},
    placeholder: PlaceholderPolicy = .{},
    density_bands: std.StringHashMapUnmanaged([]const u32) = .{},
    exact_mappings: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Relation kinds that count as poetry-ownership evidence (default: relates_to).
    mapping_relation_kinds: []const []const u8 = &.{},

    pub fn deinit(self: *Policy, gpa: std.mem.Allocator) void {
        var eit = self.eligible_collections.iterator();
        while (eit.next()) |e| gpa.free(e.value_ptr.*);
        self.eligible_collections.deinit(gpa);
        self.poetry_collections.deinit(gpa);
        self.density_bands.deinit(gpa);
        self.exact_mappings.deinit(gpa);
    }

    pub fn defaultRelationKinds(self: *const Policy) []const []const u8 {
        return if (self.mapping_relation_kinds.len > 0) self.mapping_relation_kinds else &.{"relates_to"};
    }

    pub fn poetryTypeOfCollection(self: *const Policy, collection: []const u8) ?[]const u8 {
        return self.poetry_collections.get(collection);
    }

    pub fn expectedTypesForCollection(self: *const Policy, collection: []const u8) ?[]const []const u8 {
        return self.eligible_collections.get(collection);
    }

    pub fn isEligibleSourceCollection(self: *const Policy, collection: []const u8) bool {
        return self.eligible_collections.contains(collection);
    }

    pub fn isPoetryCollection(self: *const Policy, collection: []const u8) bool {
        return self.poetry_collections.contains(collection);
    }

    pub fn isExcludedStatus(self: *const Policy, status: ?[]const u8) bool {
        const s = status orelse return false;
        for (self.excluded_statuses) |ex| {
            if (util.eql(s, ex)) return true;
        }
        return false;
    }

    pub fn isExcludedId(self: *const Policy, id: []const u8) bool {
        for (self.excluded_ids) |ex| {
            if (util.eql(id, ex)) return true;
        }
        return false;
    }

    pub fn exactMappingOwner(self: *const Policy, poetry_id: []const u8) ?[]const u8 {
        return self.exact_mappings.get(poetry_id);
    }

    pub fn relationKindCounts(self: *const Policy, kind: []const u8) bool {
        const kinds = self.defaultRelationKinds();
        for (kinds) |k| {
            if (util.eql(k, kind)) return true;
        }
        return false;
    }
};

pub const PolicyError = error{
    InvalidJson,
    MissingSchemaVersion,
    UnsupportedSchemaVersion,
    InvalidShape,
    OutOfMemory,
};

fn getString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(v: std.json.Value, key: []const u8) ?bool {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .bool => |b| b,
        else => null,
    };
}

fn collectStrings(gpa: std.mem.Allocator, v: std.json.Value) PolicyError![]const []const u8 {
    if (v != .array) return error.InvalidShape;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (v.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.InvalidShape;
        try out.append(gpa, item.string);
    }
    return try out.toOwnedSlice(gpa);
}

/// Parse a policy from raw JSON bytes. On success the returned policy owns
/// references into `json_bytes`, so the caller must keep both alive; pass a
/// retain allocator that owns both when that matters.
pub fn parse(gpa: std.mem.Allocator, json_bytes: []const u8) PolicyError!Policy {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidShape;

    var policy: Policy = .{};
    errdefer policy.deinit(gpa);

    // schema_version must equal 1 exactly: omitted or zero versions are never
    // accepted as schema 1.
    const sv = root.object.get("schema_version") orelse return error.MissingSchemaVersion;
    if (sv != .integer or sv.integer != supported_schema_version) return error.UnsupportedSchemaVersion;
    policy.schema_version = @intCast(sv.integer);

    if (root.object.get("eligible_collections")) |ec| {
        if (ec != .object) return error.InvalidShape;
        var it = ec.object.iterator();
        while (it.next()) |entry| {
            const types = try collectStrings(gpa, entry.value_ptr.*);
            try policy.eligible_collections.put(gpa, entry.key_ptr.*, types);
        }
    }

    if (root.object.get("poetry_collections")) |pc| {
        if (pc != .object) return error.InvalidShape;
        var it = pc.object.iterator();
        while (it.next()) |entry| {
            const t = getString(entry.value_ptr.*, "") orelse blk: {
                // poetry_collections values are plain strings, not objects
                if (entry.value_ptr.* == .string and entry.value_ptr.*.string.len > 0) {
                    break :blk entry.value_ptr.*.string;
                }
                return error.InvalidShape;
            };
            try policy.poetry_collections.put(gpa, entry.key_ptr.*, t);
        }
    }

    if (root.object.get("excluded_statuses")) |es| {
        policy.excluded_statuses = try collectStrings(gpa, es);
    }
    if (root.object.get("excluded_ids")) |ei| {
        policy.excluded_ids = try collectStrings(gpa, ei);
    }

    if (root.object.get("placeholder")) |ph| {
        if (ph != .object) return error.InvalidShape;
        if (ph.object.get("exact_lines")) |el| {
            policy.placeholder.exact_lines = try collectStrings(gpa, el);
        }
        if (ph.object.get("title_prefixes")) |tp| {
            policy.placeholder.title_prefixes = try collectStrings(gpa, tp);
        }
        if (getBool(ph, "case_sensitive")) |cs| {
            policy.placeholder.case_sensitive = cs;
        }
    }

    if (root.object.get("density_bands")) |db| {
        if (db != .object) return error.InvalidShape;
        var it = db.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .array) return error.InvalidShape;
            var counts: std.ArrayList(u32) = .empty;
            errdefer counts.deinit(gpa);
            var prev: ?u32 = null;
            for (entry.value_ptr.*.array.items) |item| {
                // Reject anything outside the u32 range up front: @intCast
                // would trap in Debug/ReleaseSafe builds or silently truncate
                // in unchecked builds, instead of surfacing exit 4.
                if (item != .integer or item.integer < 0 or item.integer > std.math.maxInt(u32)) return error.InvalidShape;
                const n: u32 = @intCast(item.integer);
                if (n == 0) return error.InvalidShape;
                if (prev) |p| {
                    if (n <= p) return error.InvalidShape; // must be strictly ascending
                }
                prev = n;
                try counts.append(gpa, n);
            }
            try policy.density_bands.put(gpa, entry.key_ptr.*, try counts.toOwnedSlice(gpa));
        }
    }

    if (root.object.get("exact_mappings")) |em| {
        if (em != .object) return error.InvalidShape;
        var it = em.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string or entry.value_ptr.*.string.len == 0) return error.InvalidShape;
            if (entry.key_ptr.*.len == 0) return error.InvalidShape;
            try policy.exact_mappings.put(gpa, entry.key_ptr.*, entry.value_ptr.*.string);
        }
    }

    if (root.object.get("mapping_relation_kinds")) |mrk| {
        policy.mapping_relation_kinds = try collectStrings(gpa, mrk);
    }

    return policy;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "policy example shape parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "eligible_collections": {
        \\    "lorelog": ["aphorism", "haiku", "limerick"],
        \\    "mascots": ["aphorism", "haiku", "limerick"]
        \\  },
        \\  "poetry_collections": {
        \\    "aphorisms": "aphorism",
        \\    "haikus": "haiku",
        \\    "limericks": "limerick"
        \\  },
        \\  "excluded_statuses": ["draft"],
        \\  "excluded_ids": [],
        \\  "placeholder": {
        \\    "exact_lines": ["Awaiting context"],
        \\    "title_prefixes": ["Stub:"],
        \\    "case_sensitive": false
        \\  },
        \\  "density_bands": {
        \\    "aphorism": [1, 5, 8],
        \\    "haiku": [1, 3, 5],
        \\    "limerick": [1, 5, 10]
        \\  },
        \\  "exact_mappings": {}
        \\}
    ;
    var policy = try parse(a, json);
    try std.testing.expectEqual(policy.schema_version, 1);
    try std.testing.expectEqualStrings("haiku", policy.poetryTypeOfCollection("haikus").?);
    try std.testing.expect(policy.isPoetryCollection("aphorisms"));
    try std.testing.expect(policy.isEligibleSourceCollection("lorelog"));
    try std.testing.expect(!policy.isPoetryCollection("lorelog"));
    try std.testing.expect(policy.isExcludedStatus("draft"));
    try std.testing.expect(!policy.isExcludedStatus("published"));
    try std.testing.expectEqual(policy.placeholder.exact_lines.len, 1);
    try std.testing.expectEqual(policy.placeholder.title_prefixes.len, 1);
    try std.testing.expectEqual(policy.density_bands.get("haiku").?.len, 3);
}

test "unsupported schema version rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"schema_version\": 99}";
    try std.testing.expectError(error.UnsupportedSchemaVersion, parse(a, json));
}

test "schema version omitted is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"eligible_collections\": {}}";
    try std.testing.expectError(error.MissingSchemaVersion, parse(a, json));
}

test "schema version zero is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"schema_version\": 0}";
    try std.testing.expectError(error.UnsupportedSchemaVersion, parse(a, json));
}

test "schema version two is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"schema_version\": 2}";
    try std.testing.expectError(error.UnsupportedSchemaVersion, parse(a, json));
}

test "invalid json rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidJson, parse(a, "not json"));
}

test "density bands must be ascending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"schema_version\":1,\"density_bands\":{\"haiku\":[3,1]}}";
    try std.testing.expectError(error.InvalidShape, parse(a, json));
    // Oversized band value (above u32 max): rejected, must not trap or truncate.
    const jsonbig = "{\"schema_version\":1,\"density_bands\":{\"haiku\":[4294967296]}}";
    try std.testing.expectError(error.InvalidShape, parse(a, jsonbig));
}

test "density band at u32 max boundary is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"schema_version\":1,\"density_bands\":{\"haiku\":[4294967295]}}";
    var p = try parse(a, json);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), p.density_bands.get("haiku").?[0]);
}
