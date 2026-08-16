//! Deterministic inventory of Boris-owned payload files in one HTML target.
//!
//! The inventory is collected from producer-owned paths and the exact staged
//! or cached bytes that the target transaction will commit. It never crawls a
//! target directory to discover artifacts, and it never inventories itself.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");
const image_dimensions = @import("image_dimensions.zig");
const json_out = @import("json_out.zig");

pub const output_path = "_boris/proof/artifacts.json";
/// Reserved evidence path. It is kept out of the inventory so the later
/// checks report cannot become one of its own committed subjects.
pub const checks_output_path = "_boris/proof/checks.json";
/// Reserved evidence path for the claims-and-limitations report. It is kept
/// out of the inventory so the claims report cannot become a committed
/// subject, and out of the checks parser so checks never treat it as a
/// Boris-owned payload.
pub const claims_output_path = "_boris/proof/claims.json";
/// Reserved downstream evidence path for the Touch Atlas report. It is kept
/// out of the inventory so the atlas cannot become a committed subject, and
/// out of the checks/claims parsers so they never treat it as a Boris-owned
/// payload.
pub const touches_output_path = "_boris/proof/touches.json";
/// Reserved downstream presentation path for the Proof Pack model. It is kept
/// out of the inventory so the model cannot become a committed subject, and
/// out of the checks/claims/touches parsers so they never treat it as a
/// Boris-owned payload.
pub const proof_pack_output_path = "_boris/proof/proof-pack.json";
/// Reserved downstream presentation path for the Proof Pack static page. It is
/// kept out of the inventory so the page cannot become a committed subject or
/// masquerade as a Boris-owned payload.
pub const proof_index_output_path = "_boris/proof/index.html";
/// Reserved temporary paths used by the first-slice Proof Pack generation
/// transaction. A user-produced artifact must never overwrite or masquerade as
/// Proof Pack output, its temporary siblings, or its recovery files.
pub const proof_pack_tmp_path = "_boris/proof/proof-pack.json.tmp";
pub const proof_index_tmp_path = "_boris/proof/index.html.tmp";
pub const proof_pack_prev_path = "_boris/proof/proof-pack.json.prev";
pub const proof_index_prev_path = "_boris/proof/index.html.prev";
pub const artifact_format = "boris-publication-artifacts";
pub const schema_version: usize = 1;

pub const Kind = enum {
    html_page,
    theme_asset,
    content_asset,
    rendered_search,
    sitemap,
    rss,
    llms,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .html_page => "html-page",
            .theme_asset => "theme-asset",
            .content_asset => "content-asset",
            .rendered_search => "rendered-search",
            .sitemap => "sitemap",
            .rss => "rss",
            .llms => "llms",
        };
    }

    pub fn producerName(self: Kind) []const u8 {
        return switch (self) {
            .html_page => "html-render",
            .theme_asset => "theme-assets",
            .content_asset => "content-assets",
            .rendered_search => "rendered-search",
            .sitemap => "sitemap",
            .rss => "rss",
            .llms => "llms",
        };
    }

    pub fn parse(value: []const u8) ?Kind {
        inline for (.{
            .{ "html-page", Kind.html_page },
            .{ "theme-asset", Kind.theme_asset },
            .{ "content-asset", Kind.content_asset },
            .{ "rendered-search", Kind.rendered_search },
            .{ "sitemap", Kind.sitemap },
            .{ "rss", Kind.rss },
            .{ "llms", Kind.llms },
        }) |entry| {
            if (std.mem.eql(u8, value, entry[0])) return entry[1];
        }
        return null;
    }
};

pub const Status = enum {
    committed,
    omitted_by_plan,
    not_applicable,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .committed => "committed",
            .omitted_by_plan => "omitted-by-plan",
            .not_applicable => "not-applicable",
        };
    }

    pub fn parse(value: []const u8) ?Status {
        inline for (.{
            .{ "committed", Status.committed },
            .{ "omitted-by-plan", Status.omitted_by_plan },
            .{ "not-applicable", Status.not_applicable },
        }) |entry| {
            if (std.mem.eql(u8, value, entry[0])) return entry[1];
        }
        return null;
    }
};

/// Producer-owned declaration used during collection. `allow_live` is true
/// only for cached HTML pages; generated projections and copied assets must be
/// present in the new stage so an old file cannot masquerade as new output.
pub const Spec = struct {
    path: []const u8,
    kind: Kind,
    producer: []const u8,
    required: bool = true,
    format_version: ?[]const u8 = null,
    allow_live: bool = false,
};

/// Explicit author-facing semantics for asset kinds (#396). Theme-owned
/// `assets/` files are static: copied verbatim, never processed. Content-local
/// `.assets/` trees are content-references: copied byte-for-byte but owned by
/// page content and pointed at by rewritten Markdown destinations. Generated
/// projections and rendered pages are not assets and carry null semantics.
pub const AssetSemantics = enum {
    static,
    content_reference,

    pub fn name(self: AssetSemantics) []const u8 {
        return switch (self) {
            .static => "static",
            .content_reference => "content-reference",
        };
    }

    pub fn parse(value: []const u8) ?AssetSemantics {
        if (std.mem.eql(u8, value, "static")) return .static;
        if (std.mem.eql(u8, value, "content-reference")) return .content_reference;
        return null;
    }
};

pub const Record = struct {
    path: []const u8,
    kind: Kind,
    producer: []const u8,
    required: bool,
    status: Status,
    bytes: usize,
    sha256: [64]u8,
    format_version: ?[]const u8,
    /// Pixel dimensions for image assets "where determinable" (see
    /// image_dimensions.zig); null for non-images, unsupported formats, and
    /// malformed headers.
    dimensions: ?image_dimensions.Dimensions = null,
    /// Explicit static/content-reference semantics for asset kinds; null for
    /// non-asset records.
    semantics: ?AssetSemantics = null,
};

pub const Inventory = struct {
    gpa: std.mem.Allocator,
    target: []const u8,
    records: []Record,
    owns_strings: bool = false,

    pub fn deinit(self: *Inventory) void {
        if (self.owns_strings) {
            self.gpa.free(self.target);
            for (self.records) |record| {
                self.gpa.free(record.path);
                self.gpa.free(record.producer);
                if (record.format_version) |version| self.gpa.free(version);
            }
        }
        self.gpa.free(self.records);
        self.* = undefined;
    }
};

fn pathPrefix(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or
        (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/');
}

fn pathsOverlap(left: []const u8, right: []const u8) bool {
    return pathPrefix(left, right) or pathPrefix(right, left);
}

/// Every producer-reserved target-relative path: evidence reports plus the
/// Proof Pack presentation pair and its temporary/recovery siblings. A
/// user-produced artifact colliding with any of these is rejected by the
/// inventory parser, the collector, and the renderer.
pub const reserved_paths = [_][]const u8{
    output_path,
    checks_output_path,
    claims_output_path,
    touches_output_path,
    proof_pack_output_path,
    proof_index_output_path,
    proof_pack_tmp_path,
    proof_index_tmp_path,
    proof_pack_prev_path,
    proof_index_prev_path,
};

fn isReservedPath(path: []const u8) bool {
    for (reserved_paths) |reserved| {
        if (pathsOverlap(path, reserved)) return true;
    }
    return false;
}

/// Validate a target-relative payload path without consulting the filesystem.
pub fn validateRelativePath(path: []const u8) bool {
    if (path.len == 0 or !std.unicode.utf8ValidateSlice(path)) return false;
    if (std.fs.path.isAbsolute(path) or path[0] == '/' or path[path.len - 1] == '/') return false;
    if (path.len >= 2 and path[1] == ':') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Reject a producer-owned path that would collide with the inventory file.
/// This keeps the self-reference rule structural rather than relying on the
/// current set of producer kinds.
pub fn rejectOutputCollision(path: []const u8, owned_paths: []const []const u8) !void {
    if (!validateRelativePath(path)) return error.InvalidArtifactPath;
    for (owned_paths) |owned| {
        if (pathsOverlap(path, owned)) return error.InventoryPathCollision;
    }
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

fn readOverlay(
    io: Io,
    staged_dir: Io.Dir,
    live_dir: Io.Dir,
    gpa: std.mem.Allocator,
    spec: Spec,
) ![]u8 {
    if (readFileAlloc(io, staged_dir, spec.path, gpa)) |bytes| {
        return bytes;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (!spec.allow_live) return error.ArtifactMissing;
    return readFileAlloc(io, live_dir, spec.path, gpa) catch |err| switch (err) {
        error.FileNotFound => error.ArtifactMissing,
        else => err,
    };
}

pub fn recordLess(_: void, left: Record, right: Record) bool {
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    return std.mem.order(u8, left.kind.name(), right.kind.name()) == .lt;
}

pub const ParseError = std.mem.Allocator.Error || error{
    InvalidInventory,
    InvalidInventoryFormat,
    UnsupportedInventoryVersion,
    InventoryTargetMismatch,
    InvalidInventoryPath,
    DuplicateInventoryPath,
    NonCanonicalInventoryOrder,
};

fn jsonTokenText(token: std.json.Token) ?[]const u8 {
    return switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        .number => |value| value,
        .allocated_number => |value| value,
        else => null,
    };
}

fn freeJsonToken(gpa: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |value| gpa.free(value),
        .allocated_number => |value| gpa.free(value),
        else => {},
    }
}

fn nextJsonToken(reader: *std.json.Reader) ParseError!std.json.Token {
    return reader.next() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInventory,
    };
}

fn nextJsonAllocToken(
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    max_value_len: usize,
) ParseError!std.json.Token {
    return reader.nextAllocMax(gpa, .alloc_if_needed, max_value_len) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInventory,
    };
}

fn readJsonString(gpa: std.mem.Allocator, reader: *std.json.Reader) ParseError![]u8 {
    const token = reader.nextAllocMax(gpa, .alloc_always, 4 * 1024 * 1024) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidInventory,
        };
    };
    switch (token) {
        .allocated_string => |value| return value,
        .string => |value| return gpa.dupe(u8, value),
        else => {
            freeJsonToken(gpa, token);
            return error.InvalidInventory;
        },
    }
}

fn readJsonInteger(gpa: std.mem.Allocator, reader: *std.json.Reader) ParseError!u64 {
    const token = try nextJsonAllocToken(gpa, reader, 64);
    defer freeJsonToken(gpa, token);
    const value = jsonTokenText(token) orelse return error.InvalidInventory;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidInventory;
}

fn readJsonBool(reader: *std.json.Reader) ParseError!bool {
    return switch (try nextJsonToken(reader)) {
        .true => true,
        .false => false,
        else => error.InvalidInventory,
    };
}

fn freeRecord(gpa: std.mem.Allocator, record: Record) void {
    gpa.free(record.path);
    gpa.free(record.producer);
    if (record.format_version) |version| gpa.free(version);
}

fn parseRecordStreamAfterBegin(gpa: std.mem.Allocator, reader: *std.json.Reader) ParseError!Record {
    var record: Record = undefined;
    record.path = &.{};
    record.producer = &.{};
    record.format_version = null;
    // Extended fields (#396) are optional-on-parse so v1 fixtures written
    // before them round-trip with null; `undefined` would leave them garbage.
    record.dimensions = null;
    record.semantics = null;
    errdefer freeRecord(gpa, record);

    var have_path = false;
    var have_kind = false;
    var have_producer = false;
    var have_required = false;
    var have_status = false;
    var have_bytes = false;
    var have_sha256 = false;
    var have_format_version = false;
    var have_dimensions = false;
    var have_semantics = false;

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidInventory;

        if (std.mem.eql(u8, key, "path")) {
            if (have_path) return error.InvalidInventory;
            record.path = try readJsonString(gpa, reader);
            have_path = true;
        } else if (std.mem.eql(u8, key, "kind")) {
            if (have_kind) return error.InvalidInventory;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            record.kind = Kind.parse(value) orelse return error.InvalidInventory;
            have_kind = true;
        } else if (std.mem.eql(u8, key, "producer")) {
            if (have_producer) return error.InvalidInventory;
            record.producer = try readJsonString(gpa, reader);
            have_producer = true;
        } else if (std.mem.eql(u8, key, "required")) {
            if (have_required) return error.InvalidInventory;
            record.required = try readJsonBool(reader);
            have_required = true;
        } else if (std.mem.eql(u8, key, "status")) {
            if (have_status) return error.InvalidInventory;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            record.status = Status.parse(value) orelse return error.InvalidInventory;
            have_status = true;
        } else if (std.mem.eql(u8, key, "bytes")) {
            if (have_bytes) return error.InvalidInventory;
            const value = try readJsonInteger(gpa, reader);
            if (value > std.math.maxInt(usize)) return error.InvalidInventory;
            record.bytes = @intCast(value);
            have_bytes = true;
        } else if (std.mem.eql(u8, key, "sha256")) {
            if (have_sha256) return error.InvalidInventory;
            const value = try readJsonString(gpa, reader);
            defer gpa.free(value);
            if (!validDigest(value)) return error.InvalidInventory;
            @memcpy(&record.sha256, value);
            have_sha256 = true;
        } else if (std.mem.eql(u8, key, "format_version")) {
            if (have_format_version) return error.InvalidInventory;
            const token = try nextJsonAllocToken(gpa, reader, 4096);
            defer freeJsonToken(gpa, token);
            switch (token) {
                .null => record.format_version = null,
                .string => |value| {
                    if (value.len == 0) return error.InvalidInventory;
                    record.format_version = try gpa.dupe(u8, value);
                },
                .allocated_string => |value| {
                    if (value.len == 0) return error.InvalidInventory;
                    record.format_version = try gpa.dupe(u8, value);
                },
                else => return error.InvalidInventory,
            }
            have_format_version = true;
        } else if (std.mem.eql(u8, key, "dimensions")) {
            if (have_dimensions) return error.InvalidInventory;
            const token = try nextJsonAllocToken(gpa, reader, 4096);
            defer freeJsonToken(gpa, token);
            switch (token) {
                .null => record.dimensions = null,
                .object_begin => {
                    var width: ?u32 = null;
                    var height: ?u32 = null;
                    while (true) {
                        const dim_key_token = try nextJsonAllocToken(gpa, reader, 4096);
                        switch (dim_key_token) {
                            .object_end => break,
                            else => {},
                        }
                        defer freeJsonToken(gpa, dim_key_token);
                        const dim_key = jsonTokenText(dim_key_token) orelse return error.InvalidInventory;
                        if (std.mem.eql(u8, dim_key, "width")) {
                            if (width != null) return error.InvalidInventory;
                            const value = try readJsonInteger(gpa, reader);
                            if (value == 0 or value > std.math.maxInt(u32)) return error.InvalidInventory;
                            width = @intCast(value);
                        } else if (std.mem.eql(u8, dim_key, "height")) {
                            if (height != null) return error.InvalidInventory;
                            const value = try readJsonInteger(gpa, reader);
                            if (value == 0 or value > std.math.maxInt(u32)) return error.InvalidInventory;
                            height = @intCast(value);
                        } else {
                            return error.InvalidInventory;
                        }
                    }
                    if (width == null or height == null) return error.InvalidInventory;
                    record.dimensions = .{ .width = width.?, .height = height.? };
                },
                else => return error.InvalidInventory,
            }
            have_dimensions = true;
        } else if (std.mem.eql(u8, key, "semantics")) {
            if (have_semantics) return error.InvalidInventory;
            const token = try nextJsonAllocToken(gpa, reader, 4096);
            defer freeJsonToken(gpa, token);
            switch (token) {
                .null => record.semantics = null,
                .string => |value| {
                    record.semantics = AssetSemantics.parse(value) orelse return error.InvalidInventory;
                },
                .allocated_string => |value| {
                    defer gpa.free(value);
                    record.semantics = AssetSemantics.parse(value) orelse return error.InvalidInventory;
                },
                else => return error.InvalidInventory,
            }
            have_semantics = true;
        } else {
            return error.InvalidInventory;
        }
    }

    if (!have_path) return error.InvalidInventory;
    if (!validateRelativePath(record.path) or isReservedPath(record.path))
        return error.InvalidInventoryPath;
    if (!have_kind or !have_producer or !have_required or !have_status or !have_bytes or
        !have_sha256 or !have_format_version) return error.InvalidInventory;
    if (!std.mem.eql(u8, record.producer, record.kind.producerName())) return error.InvalidInventory;
    return record;
}

/// Strictly parse an inventory from a streaming JSON reader. The parser keeps
/// only canonical record metadata and never builds a generic JSON DOM.
pub fn parseStream(
    gpa: std.mem.Allocator,
    input: *std.Io.Reader,
    expected_target: []const u8,
) ParseError!Inventory {
    if (expected_target.len == 0) return error.InvalidInventory;
    var reader = std.json.Reader.init(gpa, input);
    defer reader.deinit();

    switch (try nextJsonToken(&reader)) {
        .object_begin => {},
        else => return error.InvalidInventory,
    }

    var have_format = false;
    var have_version = false;
    var have_target = false;
    var have_artifacts = false;
    var target: []u8 = &.{};
    errdefer if (target.len != 0) gpa.free(target);
    var records: std.ArrayList(Record) = .empty;
    errdefer {
        for (records.items) |record| freeRecord(gpa, record);
        records.deinit(gpa);
    }

    while (true) {
        const key_token = try nextJsonAllocToken(gpa, &reader, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(gpa, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidInventory;

        if (std.mem.eql(u8, key, "format")) {
            if (have_format) return error.InvalidInventory;
            const value = try readJsonString(gpa, &reader);
            defer gpa.free(value);
            if (!std.mem.eql(u8, value, artifact_format)) return error.InvalidInventoryFormat;
            have_format = true;
        } else if (std.mem.eql(u8, key, "schema_version")) {
            if (have_version) return error.InvalidInventory;
            if (try readJsonInteger(gpa, &reader) != schema_version) return error.UnsupportedInventoryVersion;
            have_version = true;
        } else if (std.mem.eql(u8, key, "target")) {
            if (have_target) return error.InvalidInventory;
            target = try readJsonString(gpa, &reader);
            if (target.len == 0) return error.InvalidInventory;
            if (!std.mem.eql(u8, target, expected_target)) return error.InventoryTargetMismatch;
            have_target = true;
        } else if (std.mem.eql(u8, key, "artifacts")) {
            if (have_artifacts) return error.InvalidInventory;
            have_artifacts = true;
            switch (try nextJsonToken(&reader)) {
                .array_begin => {},
                else => return error.InvalidInventory,
            }
            while (true) {
                switch (try nextJsonToken(&reader)) {
                    .array_end => break,
                    .object_begin => {
                        const record = try parseRecordStreamAfterBegin(gpa, &reader);
                        errdefer freeRecord(gpa, record);
                        try records.append(gpa, record);
                    },
                    else => return error.InvalidInventory,
                }
            }
        } else {
            return error.InvalidInventory;
        }
    }

    if (!have_format or !have_version or !have_target or !have_artifacts) return error.InvalidInventory;
    if (try nextJsonToken(&reader) != .end_of_document) return error.InvalidInventory;
    for (records.items, 0..) |record, index| {
        if (index == 0) continue;
        const previous = records.items[index - 1];
        if (std.mem.eql(u8, record.path, previous.path)) return error.DuplicateInventoryPath;
        if (recordLess({}, record, previous)) return error.NonCanonicalInventoryOrder;
    }

    return .{
        .gpa = gpa,
        .target = target,
        .records = try records.toOwnedSlice(gpa),
        .owns_strings = true,
    };
}

fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

/// Strictly parse the canonical target-local inventory used by publication
/// checks. The returned strings are owned by the returned Inventory.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, expected_target: []const u8) ParseError!Inventory {
    var input = std.Io.Reader.fixed(bytes);
    return parseStream(gpa, &input, expected_target);
}

fn expectStringArray(value: std.json.Value, expected: []const []const u8) !void {
    const items = value.array.items;
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, 0..) |want, index| {
        try std.testing.expectEqualStrings(want, items[index].string);
    }
}

pub fn collect(
    io: Io,
    gpa: std.mem.Allocator,
    staged_dir: Io.Dir,
    live_dir: Io.Dir,
    target: []const u8,
    specs: []const Spec,
) !Inventory {
    if (target.len == 0) return error.InvalidTarget;

    var records = try gpa.alloc(Record, specs.len);
    var filled: usize = 0;
    errdefer gpa.free(records);

    for (specs) |spec| {
        if (!validateRelativePath(spec.path)) return error.InvalidArtifactPath;
        if (isReservedPath(spec.path)) {
            return error.InventoryPathCollision;
        }
        if (!std.mem.eql(u8, spec.producer, spec.kind.producerName())) return error.InvalidArtifactProducer;
        if (spec.format_version) |version| if (version.len == 0) return error.InvalidFormatVersion;

        const bytes = try readOverlay(io, staged_dir, live_dir, gpa, spec);
        defer gpa.free(bytes);
        const digest = cache.hexDigest(cache.hashBytes(bytes));
        records[filled] = .{
            .path = spec.path,
            .kind = spec.kind,
            .producer = spec.producer,
            .required = spec.required,
            .status = .committed,
            .bytes = bytes.len,
            .sha256 = digest,
            .format_version = spec.format_version,
            .dimensions = image_dimensions.dimensions(spec.path, bytes),
            .semantics = switch (spec.kind) {
                .theme_asset => .static,
                .content_asset => .content_reference,
                else => null,
            },
        };
        filled += 1;
    }

    std.mem.sort(Record, records, {}, recordLess);
    if (records.len > 1) {
        for (records[1..], records[0 .. records.len - 1]) |current, previous| {
            if (std.mem.eql(u8, current.path, previous.path)) return error.DuplicateArtifactPath;
        }
    }

    return .{ .gpa = gpa, .target = target, .records = records };
}

/// Collect an inventory from already-committed payload bytes. Paths, producers,
/// and format versions are borrowed from `items`; the caller must keep those
/// slices alive until `Inventory.deinit`.
pub const PayloadSpec = struct {
    spec: Spec,
    bytes: []const u8,
};

pub fn collectFromPayloads(
    gpa: std.mem.Allocator,
    target: []const u8,
    items: []const PayloadSpec,
) !Inventory {
    if (target.len == 0) return error.InvalidTarget;

    var records = try gpa.alloc(Record, items.len);
    var filled: usize = 0;
    errdefer gpa.free(records);

    for (items) |item| {
        const spec = item.spec;
        if (!validateRelativePath(spec.path)) return error.InvalidArtifactPath;
        if (isReservedPath(spec.path)) return error.InventoryPathCollision;
        if (!std.mem.eql(u8, spec.producer, spec.kind.producerName())) return error.InvalidArtifactProducer;
        if (spec.format_version) |version| if (version.len == 0) return error.InvalidFormatVersion;

        const digest = cache.hexDigest(cache.hashBytes(item.bytes));
        records[filled] = .{
            .path = spec.path,
            .kind = spec.kind,
            .producer = spec.producer,
            .required = spec.required,
            .status = .committed,
            .bytes = item.bytes.len,
            .sha256 = digest,
            .format_version = spec.format_version,
            .dimensions = image_dimensions.dimensions(spec.path, item.bytes),
            .semantics = switch (spec.kind) {
                .theme_asset => .static,
                .content_asset => .content_reference,
                else => null,
            },
        };
        filled += 1;
    }

    std.mem.sort(Record, records, {}, recordLess);
    if (records.len > 1) {
        for (records[1..], records[0 .. records.len - 1]) |current, previous| {
            if (std.mem.eql(u8, current.path, previous.path)) return error.DuplicateArtifactPath;
        }
    }

    return .{ .gpa = gpa, .target = target, .records = records };
}

pub fn render(gpa: std.mem.Allocator, inventory: *const Inventory) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, artifact_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"target\": ");
    try json_out.writeString(&out, gpa, inventory.target);
    try out.appendSlice(gpa, ",\n  \"artifacts\": [");

    for (inventory.records, 0..) |record, index| {
        if (!validateRelativePath(record.path) or isReservedPath(record.path)) return error.InvalidInventoryPath;
        if (!std.mem.eql(u8, record.producer, record.kind.producerName())) return error.InvalidArtifactProducer;
        if (record.format_version) |version| if (version.len == 0) return error.InvalidFormatVersion;
        if (index == 0) {
            try out.appendSlice(gpa, "\n");
        } else {
            try out.appendSlice(gpa, ",\n");
        }
        try out.appendSlice(gpa, "    {\n      \"path\": ");
        try json_out.writeString(&out, gpa, record.path);
        try out.appendSlice(gpa, ",\n      \"kind\": ");
        try json_out.writeString(&out, gpa, record.kind.name());
        try out.appendSlice(gpa, ",\n      \"producer\": ");
        try json_out.writeString(&out, gpa, record.producer);
        try out.appendSlice(gpa, ",\n      \"required\": ");
        try json_out.writeBool(&out, gpa, record.required);
        try out.appendSlice(gpa, ",\n      \"status\": ");
        try json_out.writeString(&out, gpa, record.status.name());
        try out.appendSlice(gpa, ",\n      \"bytes\": ");
        try json_out.writeUsize(&out, gpa, record.bytes);
        try out.appendSlice(gpa, ",\n      \"sha256\": ");
        try json_out.writeString(&out, gpa, &record.sha256);
        try out.appendSlice(gpa, ",\n      \"format_version\": ");
        if (record.format_version) |version| {
            try json_out.writeString(&out, gpa, version);
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, ",\n      \"dimensions\": ");
        if (record.dimensions) |d| {
            try out.appendSlice(gpa, "{\n        \"width\": ");
            try json_out.writeUsize(&out, gpa, d.width);
            try out.appendSlice(gpa, ",\n        \"height\": ");
            try json_out.writeUsize(&out, gpa, d.height);
            try out.appendSlice(gpa, "\n      }");
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, ",\n      \"semantics\": ");
        if (record.semantics) |semantics| {
            try json_out.writeString(&out, gpa, semantics.name());
        } else {
            try json_out.writeNull(&out, gpa);
        }
        try out.appendSlice(gpa, "\n    }");
    }

    if (inventory.records.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "]\n}\n");
    return try out.toOwnedSlice(gpa);
}

/// Collect and atomically stage the inventory. The inventory is deliberately
/// staged before the caller commits the target tree, so an inventory failure
/// leaves the prior target and prior inventory untouched.
pub fn writeOverlay(
    io: Io,
    gpa: std.mem.Allocator,
    staged_dir: Io.Dir,
    live_dir: Io.Dir,
    target: []const u8,
    specs: []const Spec,
) !void {
    var inventory = try collect(io, gpa, staged_dir, live_dir, target, specs);
    defer inventory.deinit();
    const bytes = try render(gpa, &inventory);
    defer gpa.free(bytes);

    var atomic = try staged_dir.createFileAtomic(io, output_path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.replace(io);
}

test "inventory collects exact overlay bytes, sorts paths, and emits stable digests" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "stage/assets");
    try tmp.dir.createDirPath(io, "live");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/z.html", .data = "new page" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/assets/site.css", .data = "css" });
    try tmp.dir.writeFile(io, .{ .sub_path = "live/a.html", .data = "cached page" });

    var stage = try tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);
    var live = try tmp.dir.openDir(io, "live", .{ .iterate = true });
    defer live.close(io);

    const specs = [_]Spec{
        .{ .path = "z.html", .kind = .html_page, .producer = "html-render", .allow_live = true },
        .{ .path = "a.html", .kind = .html_page, .producer = "html-render", .allow_live = true },
        .{ .path = "assets/site.css", .kind = .theme_asset, .producer = "theme-assets" },
    };
    var inventory = try collect(io, gpa, stage, live, "public", &specs);
    defer inventory.deinit();
    try std.testing.expectEqual(@as(usize, 3), inventory.records.len);
    try std.testing.expectEqualStrings("a.html", inventory.records[0].path);
    try std.testing.expectEqualStrings("assets/site.css", inventory.records[1].path);
    try std.testing.expectEqualStrings("z.html", inventory.records[2].path);
    try std.testing.expectEqual(@as(usize, "cached page".len), inventory.records[0].bytes);
    try std.testing.expectEqualStrings(
        "73f623d2c631e3d6d675c6d2ed9a05801bafeb77e522f16122b86e47b13ce4ec",
        &inventory.records[0].sha256,
    );

    const first = try render(gpa, &inventory);
    defer gpa.free(first);
    const second = try render(gpa, &inventory);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, output_path) == null);
}

test "collectFromPayloads matches overlay collection for the same bytes" {
    const gpa = std.testing.allocator;
    const items = [_]PayloadSpec{
        .{ .spec = .{ .path = "z.html", .kind = .html_page, .producer = "html-render" }, .bytes = "new page" },
        .{ .spec = .{ .path = "a.html", .kind = .html_page, .producer = "html-render" }, .bytes = "cached page" },
        .{ .spec = .{ .path = "assets/site.css", .kind = .theme_asset, .producer = "theme-assets" }, .bytes = "css" },
    };
    var inventory = try collectFromPayloads(gpa, "public", &items);
    defer inventory.deinit();
    try std.testing.expectEqual(@as(usize, 3), inventory.records.len);
    try std.testing.expectEqualStrings("a.html", inventory.records[0].path);
    try std.testing.expectEqualStrings("assets/site.css", inventory.records[1].path);
    try std.testing.expectEqualStrings("z.html", inventory.records[2].path);
    try std.testing.expectEqualStrings(
        "73f623d2c631e3d6d675c6d2ed9a05801bafeb77e522f16122b86e47b13ce4ec",
        &inventory.records[0].sha256,
    );
}

test "generated projections are staged-only and missing paths fail closed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage");
    try tmp.dir.createDirPath(io, "live");
    try tmp.dir.writeFile(io, .{ .sub_path = "live/rss.xml", .data = "stale" });
    var stage = try tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);
    var live = try tmp.dir.openDir(io, "live", .{ .iterate = true });
    defer live.close(io);

    try std.testing.expectError(error.ArtifactMissing, collect(io, gpa, stage, live, "public", &.{
        .{ .path = "rss.xml", .kind = .rss, .producer = "rss" },
    }));
    try stage.writeFile(io, .{ .sub_path = "rss.xml", .data = "new feed" });
    try stage.writeFile(io, .{ .sub_path = "llms.txt", .data = "new map" });
    var selected = try collect(io, gpa, stage, live, "public", &.{
        .{ .path = "rss.xml", .kind = .rss, .producer = "rss", .format_version = "2.0" },
        .{ .path = "llms.txt", .kind = .llms, .producer = "llms", .format_version = "1" },
    });
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 2), selected.records.len);
    try std.testing.expectEqual(Kind.llms, selected.records[0].kind);
    try std.testing.expectEqual(Kind.rss, selected.records[1].kind);
    try std.testing.expectError(error.InvalidArtifactPath, collect(io, gpa, stage, live, "public", &.{
        .{ .path = "../escape.html", .kind = .html_page, .producer = "html-render", .allow_live = true },
    }));
    try std.testing.expectError(error.InventoryPathCollision, collect(io, gpa, stage, live, "public", &.{
        .{ .path = output_path, .kind = .rss, .producer = "rss" },
    }));
    try std.testing.expectError(error.InventoryPathCollision, collect(io, gpa, stage, live, "public", &.{
        .{ .path = claims_output_path, .kind = .rss, .producer = "rss" },
    }));
}

test "asset records carry dimensions and explicit semantics (#396)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "stage/assets");
    try tmp.dir.createDirPath(io, "stage/pages/guide.assets");
    try tmp.dir.createDirPath(io, "live");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/z.html", .data = "new page" });

    // Synthetic 24-byte PNG header: 320x200.
    var png_bytes: [24]u8 = undefined;
    @memcpy(png_bytes[0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(png_bytes[8..12], &[_]u8{ 0, 0, 0, 13 });
    @memcpy(png_bytes[12..16], "IHDR");
    png_bytes[16] = 0;
    png_bytes[17] = 0;
    png_bytes[18] = 1;
    png_bytes[19] = 0x40;
    png_bytes[20] = 0;
    png_bytes[21] = 0;
    png_bytes[22] = 0;
    png_bytes[23] = 0xC8;

    try tmp.dir.writeFile(io, .{ .sub_path = "stage/assets/logo.png", .data = &png_bytes });
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/assets/site.css", .data = "css" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/pages/guide.assets/diagram.svg", .data = "<svg width='120' height='80'></svg>" });

    var stage = try tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);
    var live = try tmp.dir.openDir(io, "live", .{ .iterate = true });
    defer live.close(io);

    var inventory = try collect(io, gpa, stage, live, "public", &.{
        .{ .path = "z.html", .kind = .html_page, .producer = "html-render", .allow_live = true },
        .{ .path = "assets/logo.png", .kind = .theme_asset, .producer = "theme-assets" },
        .{ .path = "assets/site.css", .kind = .theme_asset, .producer = "theme-assets" },
        .{ .path = "pages/guide.assets/diagram.svg", .kind = .content_asset, .producer = "content-assets" },
    });
    defer inventory.deinit();

    try std.testing.expectEqual(@as(usize, 4), inventory.records.len);
    // Records are sorted by path: assets/logo.png, assets/site.css, pages/..., z.html.
    const logo = inventory.records[0];
    try std.testing.expectEqualStrings("assets/logo.png", logo.path);
    try std.testing.expectEqual(@as(u32, 320), logo.dimensions.?.width);
    try std.testing.expectEqual(@as(u32, 200), logo.dimensions.?.height);
    try std.testing.expectEqual(AssetSemantics.static, logo.semantics.?);
    const css = inventory.records[1];
    try std.testing.expect(css.dimensions == null);
    try std.testing.expectEqual(AssetSemantics.static, css.semantics.?);
    const svg = inventory.records[2];
    try std.testing.expectEqualStrings("pages/guide.assets/diagram.svg", svg.path);
    try std.testing.expectEqual(@as(u32, 120), svg.dimensions.?.width);
    try std.testing.expectEqual(@as(u32, 80), svg.dimensions.?.height);
    try std.testing.expectEqual(AssetSemantics.content_reference, svg.semantics.?);
    const page = inventory.records[3];
    try std.testing.expect(page.dimensions == null);
    try std.testing.expect(page.semantics == null);

    // Render/parse round-trip preserves the extended fields.
    const rendered = try render(gpa, &inventory);
    defer gpa.free(rendered);
    var parsed = try parse(gpa, rendered, "public");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.records.len);
    try std.testing.expectEqual(@as(u32, 320), parsed.records[0].dimensions.?.width);
    try std.testing.expectEqual(AssetSemantics.static, parsed.records[0].semantics.?);
    try std.testing.expectEqual(AssetSemantics.content_reference, parsed.records[2].semantics.?);
    try std.testing.expect(parsed.records[3].dimensions == null);

    // Absent extended fields parse as null (v1 fixture compatibility):
    // inventories written before #396 have no dimensions/semantics keys.
    // (Built with appends rather than allocPrint — this module is on the
    // json_out emitter tier, which bans raw formatting calls everywhere.)
    const digest = cache.hexDigest(cache.hashBytes("page"));
    var legacy: std.ArrayList(u8) = .empty;
    defer legacy.deinit(gpa);
    try legacy.appendSlice(gpa, "{\n  \"format\": \"");
    try legacy.appendSlice(gpa, artifact_format);
    try legacy.appendSlice(gpa, "\",\n  \"schema_version\": 1,\n  \"target\": \"public\",\n  \"artifacts\": [\n    {\n      \"path\": \"index.html\",\n      \"kind\": \"html-page\",\n      \"producer\": \"html-render\",\n      \"required\": true,\n      \"status\": \"committed\",\n      \"bytes\": 4,\n      \"sha256\": \"");
    try legacy.appendSlice(gpa, &digest);
    try legacy.appendSlice(gpa, "\",\n      \"format_version\": null\n    }\n  ]\n}\n");
    var legacy_inventory = try parse(gpa, legacy.items, "public");
    defer legacy_inventory.deinit();
    try std.testing.expectEqual(@as(usize, 1), legacy_inventory.records.len);
    try std.testing.expect(legacy_inventory.records[0].dimensions == null);
    try std.testing.expect(legacy_inventory.records[0].semantics == null);
}

test "inventory JSON has the fixed schema field set" {
    const gpa = std.testing.allocator;
    const digest = cache.hexDigest(cache.hashBytes("page"));
    var inventory = Inventory{
        .gpa = gpa,
        .target = "public",
        .records = try gpa.dupe(Record, &.{.{
            .path = "index.html",
            .kind = .html_page,
            .producer = "html-render",
            .required = true,
            .status = .committed,
            .bytes = 4,
            .sha256 = digest,
            .format_version = null,
        }}),
    };
    defer inventory.deinit();
    const bytes = try render(gpa, &inventory);
    defer gpa.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(artifact_format, root.get("format").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("schema_version").?.integer);
    const item = root.get("artifacts").?.array.items[0].object;
    try std.testing.expect(item.get("path") != null);
    try std.testing.expect(item.get("kind") != null);
    try std.testing.expect(item.get("producer") != null);
    try std.testing.expect(item.get("required") != null);
    try std.testing.expect(item.get("status") != null);
    try std.testing.expect(item.get("bytes") != null);
    try std.testing.expect(item.get("sha256") != null);
    try std.testing.expect(item.get("format_version") != null);
    try std.testing.expect(item.get("dimensions") != null);
    try std.testing.expect(item.get("semantics") != null);
    try std.testing.expect(item.get("dimensions").? == .null);
    try std.testing.expect(item.get("semantics").? == .null);
}

test "published artifact schema matches the fixed runtime vocabulary" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const schema_bytes = try readFileAlloc(
        io,
        Io.Dir.cwd(),
        "docs/contracts/schemas/publication-artifacts-1.schema.json",
        gpa,
    );
    defer gpa.free(schema_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", root.get("$schema").?.string);
    try std.testing.expectEqualStrings(artifact_format, root.get("properties").?.object.get("format").?.object.get("const").?.string);
    try std.testing.expectEqual(@as(i64, schema_version), root.get("properties").?.object.get("schema_version").?.object.get("const").?.integer);
    try expectStringArray(root.get("required").?, &[_][]const u8{ "format", "schema_version", "target", "artifacts" });

    const defs = root.get("$defs").?.object;
    const artifact = defs.get("artifact").?.object;
    try std.testing.expect(artifact.get("additionalProperties").?.bool == false);
    // The extended fields (#396) are additive-optional: v1 fixtures written
    // before them parse unchanged (absent == null), while the renderer always
    // emits them. `required` therefore stays the original eight.
    try expectStringArray(artifact.get("required").?, &[_][]const u8{
        "path",
        "kind",
        "producer",
        "required",
        "status",
        "bytes",
        "sha256",
        "format_version",
    });
    const properties = artifact.get("properties").?.object;
    try std.testing.expectEqual(@as(usize, 10), properties.count());
    for ([_][]const u8{
        "path",
        "kind",
        "producer",
        "required",
        "status",
        "bytes",
        "sha256",
        "format_version",
        "dimensions",
        "semantics",
    }) |field| try std.testing.expect(properties.get(field) != null);
    try expectStringArray(properties.get("kind").?.object.get("enum").?, &[_][]const u8{
        "html-page",
        "theme-asset",
        "content-asset",
        "rendered-search",
        "sitemap",
        "rss",
        "llms",
    });
    try expectStringArray(properties.get("producer").?.object.get("enum").?, &[_][]const u8{
        "html-render",
        "theme-assets",
        "content-assets",
        "rendered-search",
        "sitemap",
        "rss",
        "llms",
    });
    try expectStringArray(properties.get("status").?.object.get("enum").?, &[_][]const u8{
        "committed",
        "omitted-by-plan",
        "not-applicable",
    });
}
