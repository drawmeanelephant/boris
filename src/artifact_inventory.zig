//! Deterministic inventory of Boris-owned payload files in one HTML target.
//!
//! The inventory is collected from producer-owned paths and the exact staged
//! or cached bytes that the target transaction will commit. It never crawls a
//! target directory to discover artifacts, and it never inventories itself.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");
const json_out = @import("json_out.zig");

pub const output_path = "_boris/proof/artifacts.json";
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

pub const Record = struct {
    path: []const u8,
    kind: Kind,
    producer: []const u8,
    required: bool,
    status: Status,
    bytes: usize,
    sha256: [64]u8,
    format_version: ?[]const u8,
};

pub const Inventory = struct {
    gpa: std.mem.Allocator,
    target: []const u8,
    records: []Record,

    pub fn deinit(self: *Inventory) void {
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

fn recordLess(_: void, left: Record, right: Record) bool {
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    return std.mem.order(u8, left.kind.name(), right.kind.name()) == .lt;
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
        if (pathsOverlap(spec.path, output_path)) return error.InventoryPathCollision;
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
    try std.testing.expectEqual(@as(usize, 8), properties.count());
    for ([_][]const u8{
        "path",
        "kind",
        "producer",
        "required",
        "status",
        "bytes",
        "sha256",
        "format_version",
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
