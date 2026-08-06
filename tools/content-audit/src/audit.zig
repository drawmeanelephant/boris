//! Core audit model for boris-content-audit (poetry mode).
//!
//! Identity and mapping are built exclusively from explicit current-Boris
//! graph evidence:
//!   1. a poetry record whose canonical `parent` is a source record,
//!   2. an explicit semantic relation (default kind `relates_to`) between a
//!      source record and a poetry record in either direction,
//!   3. a policy-supplied exact mapping table keyed by canonical IDs.
//!
//! Precedence and disagreement:
//!   - The policy exact mapping is evidence, not a silent override. All three
//!     evidence kinds are collected independently.
//!   - When all evidence names exactly one source record, the record is
//!     `mapped` and every evidence kind is recorded.
//!   - When evidence names two or more distinct source records via the same
//!     evidence kind, the record is `duplicate_mapping`.
//!   - When evidence names two or more distinct source records via different
//!     evidence kinds (parent vs relation vs policy), the record is
//!     `mapping_disagreement`.
//!   - `ambiguous` is the umbrella status for both contested forms; the
//!     specific flavor is reported alongside it.
//!   - One poetry record is never silently assigned to multiple sources.
//!
//! Forbidden resolution (never used): filename matching, punctuation
//! stripping, case-insensitive path aliasing, title similarity, numeric
//! prefix guessing, and reverse relationships invented by the audit.

const std = @import("std");
const util = @import("util.zig");
const frontmatter = @import("frontmatter.zig");
const policy_mod = @import("policy.zig");
const verse = @import("verse.zig");

pub const RecordKind = enum {
    source,
    poetry,
    other,

    pub fn jsonName(self: RecordKind) []const u8 {
        return switch (self) {
            .source => "source",
            .poetry => "poetry",
            .other => "other",
        };
    }
};

pub const MalformedReason = enum {
    invalid_utf8,
    bom_rejected,
    oversized,
    unclosed_frontmatter,
    malformed_field,
    duplicate_key,
    missing_id,
    invalid_status,

    pub fn jsonName(self: MalformedReason) []const u8 {
        return switch (self) {
            .invalid_utf8 => "invalid_utf8",
            .bom_rejected => "bom_rejected",
            .oversized => "oversized",
            .unclosed_frontmatter => "unclosed_frontmatter",
            .malformed_field => "malformed_field",
            .duplicate_key => "duplicate_key",
            .missing_id => "missing_id",
            .invalid_status => "invalid_status",
        };
    }
};

/// Alignment status of a poetry record (dead_reference is the source-side
/// analog and is counted separately).
pub const AlignmentStatus = enum {
    mapped,
    orphan,
    ambiguous,
    duplicate_mapping,
    mapping_disagreement,
    missing_target,
    malformed_record,

    pub fn jsonName(self: AlignmentStatus) []const u8 {
        return switch (self) {
            .mapped => "mapped",
            .orphan => "orphan",
            .ambiguous => "ambiguous",
            .duplicate_mapping => "duplicate_mapping",
            .mapping_disagreement => "mapping_disagreement",
            .missing_target => "missing_target",
            .malformed_record => "malformed_record",
        };
    }
};

pub const CoverageClass = enum {
    missing,
    present_empty,
    present_placeholder,
    present_substantive,
    ambiguous_mapping,
    malformed,

    pub fn jsonName(self: CoverageClass) []const u8 {
        return switch (self) {
            .missing => "missing",
            .present_empty => "present_empty",
            .present_placeholder => "present_placeholder",
            .present_substantive => "present_substantive",
            .ambiguous_mapping => "ambiguous_mapping",
            .malformed => "malformed",
        };
    }
};

pub const EvidenceKind = enum {
    parent,
    relation,
    policy,

    pub fn jsonName(self: EvidenceKind) []const u8 {
        return switch (self) {
            .parent => "parent",
            .relation => "relation",
            .policy => "policy",
        };
    }
};

pub const Claim = struct {
    owner_id: []const u8,
    evidence: EvidenceKind,
};

pub const Severity = enum {
    structural,
    finding,
    info,

    pub fn jsonName(self: Severity) []const u8 {
        return switch (self) {
            .structural => "structural",
            .finding => "finding",
            .info => "info",
        };
    }
};

pub const Exception = struct {
    kind: []const u8,
    severity: Severity,
    record_id: []const u8,
    detail: []const u8,
};

pub const Record = struct {
    id: ?[]const u8 = null,
    collection: []const u8,
    source_path: []const u8,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    status: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    relations: []const frontmatter.Relation = &.{},
    unknown_keys: []const []const u8 = &.{},
    kind: RecordKind = .other,
    poetry_type: ?[]const u8 = null,
    malformed_reason: ?MalformedReason = null,
    verse: ?verse.Result = null,
    excluded: bool = false,
    /// Ownership claims (poetry records only).
    claims: []Claim = &.{},
    /// Resolved alignment status (poetry records).
    alignment: ?AlignmentStatus = null,
    /// Resolved owner (mapped poetry records).
    owner: ?[]const u8 = null,
    /// Coverage per expected poetry type (source records): parallel arrays.
    coverage_types: []const []const u8 = &.{},
    coverage_classes: []CoverageClass = &.{},
    /// Source record has at least one dead relation target.
    has_dead_reference: bool = false,
    /// Poetry record whose type has no registered verse shape: never analyzed
    /// as paragraph units, never granted substantive coverage.
    unsupported_shape: bool = false,
};

pub const TypeStats = struct {
    type_name: []const u8,
    records: usize = 0,
    verse_units: usize = 0,
    placeholder_units: usize = 0,
    substantive_units: usize = 0,
    malformed_units: usize = 0,
    in_band_records: usize = 0,
    out_of_band_records: usize = 0,
};

pub const DensityEntry = struct {
    unit_count: usize,
    record_count: usize,
};

pub const TypeDensity = struct {
    type_name: []const u8,
    distribution: []DensityEntry = &.{},
    in_band_records: usize = 0,
    out_of_band_records: usize = 0,
    lowest: [][]const u8 = &.{}, // record ids
    highest: [][]const u8 = &.{},
    lowest_count: usize = 0,
    highest_count: usize = 0,
};

pub const CoverageRow = struct {
    collection: []const u8,
    type_name: []const u8,
    expected: usize = 0,
    present_empty: usize = 0,
    present_placeholder: usize = 0,
    present_substantive: usize = 0,
    missing: usize = 0,
    ambiguous_mapping: usize = 0,
    malformed: usize = 0,

    pub fn structural(self: *const CoverageRow) usize {
        return self.present_empty + self.present_placeholder + self.present_substantive;
    }
    pub fn substantive(self: *const CoverageRow) usize {
        return self.present_substantive;
    }
    pub fn placeholderOnly(self: *const CoverageRow) usize {
        return self.present_placeholder;
    }
    pub fn missingCount(self: *const CoverageRow) usize {
        return self.missing;
    }
};

pub const DeltaChange = struct {
    /// added_record | removed_record | coverage_changed | verse_changed |
    /// mapping_changed | placeholder_to_substantive | newly_orphaned |
    /// newly_resolved
    kind: []const u8,
    record_id: []const u8,
    type_name: []const u8 = "",
    from: []const u8 = "",
    to: []const u8 = "",
};

pub const Audit = struct {
    records: []Record,
    /// canonical id -> record indexes (records without id are not indexed)
    index: std.StringHashMapUnmanaged([]usize) = .{},
    policy: policy_mod.Policy,
    policy_digest: []const u8,
    source_root_label: []const u8,
    source_revision: ?[]const u8,
    exceptions: []Exception = &.{},
    /// sorted canonical ids (for report ordering)
    sorted_ids: [][]const u8 = &.{},
    /// coverage rows keyed by "collection\u{0}type"
    coverage_rows: []CoverageRow = &.{},
    type_stats: []TypeStats = &.{},
    type_densities: []TypeDensity = &.{},
    excluded_count: usize = 0,
    delta: ?[]DeltaChange = null,
    previous_policy_digest: ?[]const u8 = null,
    previous_report_schema: ?u32 = null,
};

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

pub const DiscoveryError = error{
    ContentRootSymlink,
    OutputPathSymlink,
    ContentRootMissing,
    OutputInsideContentRoot,
    ContentRootInsideOutput,
    UnreadableContent,
    OutOfMemory,
};

const walk_ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out_rel: ?[]const u8, // root-relative output path ("" if not under root)
};

fn collectEntryNames(ctx: *const walk_ctx, dir: std.Io.Dir, names: *std.ArrayList([]const u8)) !void {
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind == .sym_link) continue; // symlinks skipped, never followed
        if (entry.kind == .directory) {
            if (util.isSkippedDirName(entry.name)) continue;
        }
        try names.append(ctx.gpa, try ctx.gpa.dupe(u8, entry.name));
    }
    util.sortStrings(ctx.gpa, names.items);
}

fn walkDir(ctx: *const walk_ctx, dir: std.Io.Dir, rel: []const u8, out: *std.ArrayList([]const u8)) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    try collectEntryNames(ctx, dir, &names);
    for (names.items) |name| {
        const child_rel = if (rel.len == 0) try ctx.gpa.dupe(u8, name) else try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ rel, name });
        if (ctx.out_rel) |out_rel| {
            if (util.eql(out_rel, child_rel)) continue;
        }
        // Directories open successfully; files do not.
        var child = dir.openDir(ctx.io, name, .{}) catch {
            if (std.mem.endsWith(u8, name, ".md")) {
                try out.append(ctx.gpa, child_rel);
            }
            continue;
        };
        defer child.close(ctx.io);
        try walkDir(ctx, child, child_rel, out);
    }
}

/// Discover `.md` files under the content root. Sorted, symlinks skipped,
/// generated/cache dirs skipped, and the explicit output dir skipped when it
/// would otherwise fall inside the walked tree (defense in depth; overlap is
/// refused earlier at the CLI layer).
pub fn discoverFiles(
    io: std.Io,
    gpa: std.mem.Allocator,
    root_dir: std.Io.Dir,
    content_root: []const u8,
    content_abs: []const u8,
    out_abs: ?[]const u8,
) DiscoveryError![][]const u8 {
    if (util.hasSymlinkComponent(io, root_dir, content_root)) return error.ContentRootSymlink;
    var content_dir = root_dir.openDir(io, content_root, .{}) catch return error.ContentRootMissing;
    defer content_dir.close(io);

    // Content-root-relative output path, when the output lives under content.
    var out_rel: ?[]const u8 = null;
    if (out_abs) |o| {
        if (std.mem.startsWith(u8, o, content_abs)) {
            var rest = o[content_abs.len..];
            while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
            if (rest.len > 0) out_rel = rest;
        }
    }

    const ctx = walk_ctx{ .gpa = gpa, .io = io, .out_rel = out_rel };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    walkDir(&ctx, content_dir, "", &out) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnreadableContent,
        }
    };
    return try out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Building the audit
// ---------------------------------------------------------------------------

pub const RunOptions = struct {
    root_dir: []const u8,
    content_root: []const u8,
    out_dir: []const u8,
    /// Lexical absolute path of the content root (for overlap/skip checks).
    content_root_abs: []const u8 = "",
    /// Lexical absolute path of the output dir.
    out_abs: ?[]const u8 = null,
    policy: ?policy_mod.Policy = null,
    policy_digest: []const u8 = "",
    previous_report_bytes: ?[]const u8 = null,
    source_revision: ?[]const u8 = null,
    quiet: bool = false,
};

fn readFileAlloc(io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

/// Read a source file with a bounded `max_source_bytes + 1` allocation: an
/// arbitrarily large file is never loaded into memory before it is classified
/// as oversized. Mirrors the product reader (src/source_io.zig).
fn readFileBounded(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    allocator: std.mem.Allocator,
) !struct { bytes: []u8, oversized: bool } {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.SourceTooLarge;
    var reader = file.reader(io, &.{});
    if (size <= frontmatter.max_source_bytes) {
        const bytes = try reader.interface.readAlloc(allocator, size);
        return .{ .bytes = bytes, .oversized = false };
    }
    const prefix = try allocator.alloc(u8, frontmatter.max_source_bytes + 1);
    errdefer allocator.free(prefix);
    try reader.interface.readSliceAll(prefix);
    return .{ .bytes = prefix, .oversized = true };
}

fn collectionOfPath(rel: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, rel, '/')) |slash| return rel[0..slash];
    return rel;
}

fn sortedPair(a: []const u8, b: []const u8) struct { a: []const u8, b: []const u8 } {
    if (std.mem.order(u8, a, b) == .lt) return .{ .a = a, .b = b };
    return .{ .a = b, .b = a };
}

fn buildIndex(gpa: std.mem.Allocator, records: []Record) !std.StringHashMapUnmanaged([]usize) {
    var index: std.StringHashMapUnmanaged([]usize) = .{};
    errdefer index.deinit(gpa);
    for (records, 0..) |rec, i| {
        const id = rec.id orelse continue;
        const list = index.get(id) orelse &.{};
        const new_list = try gpa.alloc(usize, list.len + 1);
        @memcpy(new_list[0..list.len], list);
        new_list[list.len] = i;
        try index.put(gpa, id, new_list);
    }
    return index;
}

/// Build the full audit. Runs entirely in an arena-backed `gpa`.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    root_dir_handle: std.Io.Dir,
    options: RunOptions,
) !Audit {
    var audit: Audit = .{
        .records = &.{},
        .policy = options.policy orelse policy_mod.Policy{},
        .policy_digest = options.policy_digest,
        .source_root_label = options.content_root,
        .source_revision = options.source_revision,
    };
    // When no policy was supplied, digest of the empty policy.
    if (audit.policy_digest.len == 0) {
        audit.policy_digest = try util.sha256Hex(gpa, "{}");
    }

    // Collection overlap sanity: a collection cannot be both source and poetry.
    var pc_it = audit.policy.poetry_collections.iterator();
    while (pc_it.next()) |pc| {
        if (audit.policy.eligible_collections.contains(pc.key_ptr.*)) {
            try addException(&audit, gpa, .{
                .kind = "collection_role_overlap",
                .severity = .structural,
                .record_id = pc.key_ptr.*,
                .detail = "collection is listed in both eligible_collections and poetry_collections",
            });
        }
    }

    const files = try discoverFiles(io, gpa, root_dir_handle, options.content_root, options.content_root_abs, options.out_abs);
    var records: std.ArrayList(Record) = .empty;
    errdefer records.deinit(gpa);

    for (files) |rel| {
        const file_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ options.content_root, rel });
        const read = readFileBounded(io, root_dir_handle, file_path, gpa) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try addException(&audit, gpa, .{
                .kind = "unreadable_file",
                .severity = .structural,
                .record_id = rel,
                .detail = "could not read file",
            });
            continue;
        };
        try appendRecord(io, gpa, &audit, &records, rel, read.bytes, read.oversized);
    }

    audit.records = try records.toOwnedSlice(gpa);
    try finalize(&audit, gpa);
    return audit;
}

fn appendRecord(
    io: std.Io,
    gpa: std.mem.Allocator,
    audit: *Audit,
    records: *std.ArrayList(Record),
    rel: []const u8,
    bytes: []const u8,
    oversized: bool,
) !void {
    _ = io;
    const collection = collectionOfPath(rel);
    var rec: Record = .{
        .collection = collection,
        .source_path = rel,
    };

    if (oversized) {
        rec.malformed_reason = .oversized;
    }

    const parsed_fm = frontmatter.parse(gpa, bytes) catch return error.OutOfMemory;
    switch (parsed_fm) {
        .ok => |p| {
            rec.title = p.title;
            rec.parent = p.parent;
            rec.status = p.status;
            rec.tags = p.tags;
            rec.relations = p.relations;
            rec.unknown_keys = p.unknown_keys;
            rec.id = p.id;
            if (rec.id == null) {
                rec.malformed_reason = .missing_id;
            }
            // Verse analysis for poetry-collection records.
            if (audit.policy.poetryTypeOfCollection(collection)) |ptype| {
                rec.kind = .poetry;
                rec.poetry_type = ptype;
                if (rec.malformed_reason == null) {
                    if (!verse.isRegisteredShape(ptype)) {
                        // Unsupported shape policy (docs/poetry-shapes.md): an
                        // unregistered type is never analyzed as paragraph
                        // units, never grants substantive coverage, and is
                        // classified as an unsupported/malformed shape.
                        rec.unsupported_shape = true;
                        rec.verse = null;
                        try addException(audit, gpa, .{
                            .kind = "unregistered_poetry_shape",
                            .severity = .structural,
                            .record_id = rel,
                            .detail = try std.fmt.allocPrint(gpa, "poetry type '{s}' has no registered shape; its verse is not analyzed and it is classified as an unsupported shape", .{ptype}),
                        });
                    } else {
                        const shape = verse.shapeForType(ptype);
                        rec.verse = verse.analyze(gpa, bytes[p.body_offset..], shape, audit.policy.placeholder, p.title) catch null;
                    }
                }
            } else if (audit.policy.isEligibleSourceCollection(collection)) {
                rec.kind = .source;
            }
            // Legacy fields are reportable but never canonical.
            for (p.unknown_keys) |k| {
                try addException(audit, gpa, .{
                    .kind = "legacy_field",
                    .severity = .info,
                    .record_id = rel,
                    .detail = try std.fmt.allocPrint(gpa, "unknown/legacy frontmatter key '{s}' reported, not used as truth", .{k}),
                });
            }
        },
        .err => |issue| {
            rec.malformed_reason = switch (issue) {
                .invalid_utf8 => .invalid_utf8,
                .bom_rejected => .bom_rejected,
                .oversized => .oversized,
                .frontmatter_too_large => .oversized,
                .unclosed_frontmatter => .unclosed_frontmatter,
                .malformed_field => .malformed_field,
                .duplicate_key => .duplicate_key,
                .invalid_status => .invalid_status,
                .too_many_fields, .too_many_tags, .tag_too_long, .summary_too_long, .invalid_entity_id, .unsupported_form => .malformed_field,
            };
            rec.id = null;
        },
    }

    try records.append(gpa, rec);
}

fn addException(audit: *Audit, gpa: std.mem.Allocator, e: Exception) !void {
    var list = std.ArrayList(Exception).fromOwnedSlice(audit.exceptions);
    try list.append(gpa, e);
    audit.exceptions = try list.toOwnedSlice(gpa);
}

fn recordLess(_: void, a: Record, b: Record) bool {
    const ai = a.id orelse "";
    const bi = b.id orelse "";
    const o = std.mem.order(u8, ai, bi);
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, a.source_path, b.source_path) == .lt;
}

fn finalize(audit: *Audit, gpa: std.mem.Allocator) !void {
    // Sort records by canonical id (missing-id records sort first deterministically).
    std.mem.sort(Record, audit.records, {}, recordLess);

    audit.index = try buildIndex(gpa, audit.records);
    errdefer audit.index.deinit(gpa);

    // Duplicate canonical ids are structural failures.
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(gpa);
    var first_indexes: std.StringHashMapUnmanaged(usize) = .{};
    defer first_indexes.deinit(gpa);
    for (audit.records, 0..) |rec, i| {
        const id = rec.id orelse continue;
        if (seen.contains(id)) {
            try addException(audit, gpa, .{
                .kind = "duplicate_id",
                .severity = .structural,
                .record_id = id,
                .detail = try std.fmt.allocPrint(gpa, "canonical id '{s}' appears more than once (paths include '{s}')", .{ id, audit.records[first_indexes.get(id).?].source_path }),
            });
        } else {
            try seen.put(gpa, id, {});
            try first_indexes.put(gpa, id, i);
        }
    }

    // Malformed records are structural failures (malformed frontmatter,
    // invalid UTF-8, missing identity, oversized files).
    for (audit.records) |*rec| {
        if (rec.malformed_reason) |reason| {
            try addException(audit, gpa, .{
                .kind = "malformed_record",
                .severity = .structural,
                .record_id = rec.id orelse rec.source_path,
                .detail = try std.fmt.allocPrint(gpa, "malformed record: {s}", .{reason.jsonName()}),
            });
        }
    }

    // Per-record exclusions.
    for (audit.records) |*rec| {
        if (rec.id) |id| {
            if (audit.policy.isExcludedId(id)) rec.excluded = true;
        }
        if (rec.status) |st| {
            if (audit.policy.isExcludedStatus(st)) rec.excluded = true;
        }
        if (rec.excluded) audit.excluded_count += 1;
    }

    // Resolve alignment + coverage.
    try resolveMappings(audit, gpa);
    try computeCoverage(audit, gpa);
    try computeTypeStats(audit, gpa);
    try computeDensity(audit, gpa);
    try sortExceptions(audit, gpa);

    // Sorted canonical ids.
    var ids: std.ArrayList([]const u8) = .empty;
    for (audit.records) |rec| {
        if (rec.id) |id| try ids.append(gpa, id);
    }
    util.sortStrings(gpa, ids.items);
    audit.sorted_ids = try ids.toOwnedSlice(gpa);
}

fn sortExceptions(audit: *Audit, gpa: std.mem.Allocator) !void {
    _ = gpa;
    std.mem.sort(Exception, audit.exceptions, {}, struct {
        fn less(_: void, a: Exception, b: Exception) bool {
            const ka = a.kind;
            const kb = b.kind;
            const ko = std.mem.order(u8, ka, kb);
            if (ko != .eq) return ko == .lt;
            const ro = std.mem.order(u8, a.record_id, b.record_id);
            if (ro != .eq) return ro == .lt;
            return std.mem.order(u8, a.detail, b.detail) == .lt;
        }
    }.less);
}

// ---------------------------------------------------------------------------
// Mapping resolution
// ---------------------------------------------------------------------------

/// Validate the complete policy mapping table, key side and owner side:
///   - the poetry-id key must exist and be a poetry record (else stale key),
///   - the owner must exist (else missing target),
///   - the owner must be a source record (else impossible mapping),
///   - the owner must be in an eligible source collection.
/// Every violation is a structural finding, never a silent orphan.
fn validatePolicyMappingTable(audit: *Audit, gpa: std.mem.Allocator) !void {
    var it = audit.policy.exact_mappings.iterator();
    while (it.next()) |e| {
        const poetry_key = e.key_ptr.*;
        const owner = e.value_ptr.*;
        const key_hits = audit.index.get(poetry_key);
        if (key_hits == null) {
            try addException(audit, gpa, .{
                .kind = "stale_exact_mapping_key",
                .severity = .structural,
                .record_id = poetry_key,
                .detail = "policy exact_mappings key names a poetry id that does not exist in the canonical index",
            });
        } else {
            var is_poetry = false;
            for (key_hits.?) |i| {
                if (audit.records[i].kind == .poetry) is_poetry = true;
            }
            if (!is_poetry) {
                try addException(audit, gpa, .{
                    .kind = "mapping_key_not_poetry",
                    .severity = .structural,
                    .record_id = poetry_key,
                    .detail = "policy exact_mappings key does not resolve to a poetry record",
                });
            }
        }
        const owner_hits = audit.index.get(owner);
        if (owner_hits == null) {
            try addException(audit, gpa, .{
                .kind = "missing_policy_target",
                .severity = .structural,
                .record_id = poetry_key,
                .detail = try std.fmt.allocPrint(gpa, "policy exact_mappings target '{s}' does not exist in the canonical index", .{owner}),
            });
        } else {
            var source_hits: usize = 0;
            var first_source: ?usize = null;
            for (owner_hits.?) |i| {
                if (audit.records[i].kind == .source) {
                    source_hits += 1;
                    if (first_source == null) first_source = i;
                }
            }
            if (source_hits == 0) {
                try addException(audit, gpa, .{
                    .kind = "mapping_target_not_source",
                    .severity = .structural,
                    .record_id = poetry_key,
                    .detail = try std.fmt.allocPrint(gpa, "policy exact_mappings target '{s}' exists but is not a source record", .{owner}),
                });
            } else if (!audit.policy.isEligibleSourceCollection(audit.records[first_source.?].collection)) {
                try addException(audit, gpa, .{
                    .kind = "mapping_target_ineligible",
                    .severity = .structural,
                    .record_id = poetry_key,
                    .detail = try std.fmt.allocPrint(gpa, "policy exact_mappings target '{s}' is a source record but its collection is not an eligible source collection", .{owner}),
                });
            }
        }
    }
}

fn resolveMappings(audit: *Audit, gpa: std.mem.Allocator) !void {
    // 0. Validate the complete policy mapping table.
    try validatePolicyMappingTable(audit, gpa);

    // 1. Reverse relation map: target id -> source record indexes claiming it.
    //    Built from eligible source records' relations only (mapping kinds).
    var rel_claims: std.StringHashMapUnmanaged([]usize) = .{};
    defer rel_claims.deinit(gpa);
    for (audit.records, 0..) |*rec, i| {
        if (rec.kind != .source) continue;
        if (rec.excluded) continue;
        for (rec.relations) |rel| {
            if (!audit.policy.relationKindCounts(rel.kind)) continue;
            const list = rel_claims.get(rel.target) orelse &.{};
            const new_list = try gpa.alloc(usize, list.len + 1);
            @memcpy(new_list[0..list.len], list);
            new_list[list.len] = i;
            try rel_claims.put(gpa, rel.target, new_list);
            // Dead reference check: target not in the canonical index.
            if (audit.index.get(rel.target) == null) {
                rec.has_dead_reference = true;
                try addException(audit, gpa, .{
                    .kind = "dead_reference",
                    .severity = .structural,
                    .record_id = rec.id orelse rec.source_path,
                    .detail = try std.fmt.allocPrint(gpa, "relation '{s}={s}' targets a record not present in the canonical index", .{ rel.kind, rel.target }),
                });
            }
        }
    }

    // 2. For each poetry record: collect ALL evidence independently. A dead
    //    or impossible evidence target records a structural exception but must
    //    not erase valid parent/relation/policy evidence.
    for (audit.records) |*rec| {
        if (rec.kind != .poetry) continue;
        if (rec.excluded) continue;
        if (rec.malformed_reason != null) {
            rec.alignment = .malformed_record;
            continue;
        }
        // Unsupported-shape records still collect claims so coverage can
        // attribute the record to its source as malformed; their verse is
        // never counted and their alignment stays malformed_record.
        const unsupported = rec.unsupported_shape;
        const id = rec.id.?;

        var claims: std.ArrayList(Claim) = .empty;
        errdefer claims.deinit(gpa);
        var dead_evidence = false;

        // Evidence 1: parent edge to a source record. A parent naming the
        // record's own poetry collection is a collection grouping (e.g.
        // `parent: haikus`), not a graph edge to a source.
        if (rec.parent) |parent_id| {
            if (!util.eql(parent_id, rec.collection)) {
                const hits = audit.index.get(parent_id);
                if (hits == null) {
                    dead_evidence = true;
                    try addException(audit, gpa, .{
                        .kind = "missing_target",
                        .severity = .structural,
                        .record_id = id,
                        .detail = try std.fmt.allocPrint(gpa, "parent '{s}' does not exist in the canonical index", .{parent_id}),
                    });
                } else {
                    var source_hits: usize = 0;
                    var source_idx: usize = 0;
                    for (hits.?) |i| {
                        if (audit.records[i].kind == .source) {
                            source_hits += 1;
                            source_idx = i;
                        }
                    }
                    if (source_hits == 1) {
                        try claims.append(gpa, .{ .owner_id = audit.records[source_idx].id.?, .evidence = .parent });
                    } else if (source_hits > 1) {
                        dead_evidence = true;
                        try addException(audit, gpa, .{
                            .kind = "duplicate_id",
                            .severity = .structural,
                            .record_id = id,
                            .detail = "parent resolves to multiple source records with the same canonical id",
                        });
                    } else {
                        // Existing target that is not a source record: an
                        // impossible mapping, structural, never a silent orphan.
                        dead_evidence = true;
                        try addException(audit, gpa, .{
                            .kind = "mapping_target_not_source",
                            .severity = .structural,
                            .record_id = id,
                            .detail = try std.fmt.allocPrint(gpa, "parent '{s}' exists but is not a source record", .{parent_id}),
                        });
                    }
                }
            }
        }

        // Evidence 2a: relations from this poetry record.
        for (rec.relations) |rel| {
            if (!audit.policy.relationKindCounts(rel.kind)) continue;
            const hits = audit.index.get(rel.target);
            if (hits == null) {
                dead_evidence = true;
                try addException(audit, gpa, .{
                    .kind = "missing_target",
                    .severity = .structural,
                    .record_id = id,
                    .detail = try std.fmt.allocPrint(gpa, "relation '{s}={s}' targets a record not present in the canonical index", .{ rel.kind, rel.target }),
                });
                continue;
            }
            var found_source = false;
            for (hits.?) |i| {
                if (audit.records[i].kind == .source) {
                    try claims.append(gpa, .{ .owner_id = audit.records[i].id.?, .evidence = .relation });
                    found_source = true;
                }
            }
            if (!found_source) {
                dead_evidence = true;
                try addException(audit, gpa, .{
                    .kind = "mapping_target_not_source",
                    .severity = .structural,
                    .record_id = id,
                    .detail = try std.fmt.allocPrint(gpa, "relation '{s}={s}' target exists but is not a source record", .{ rel.kind, rel.target }),
                });
            }
        }

        // Evidence 2b: source records referencing this poetry record.
        if (rel_claims.get(id)) |claimers| {
            for (claimers) |i| {
                try claims.append(gpa, .{ .owner_id = audit.records[i].id.?, .evidence = .relation });
            }
        }

        // Evidence 3: policy exact mapping for this poetry id. Violations of
        // the policy table (stale key, missing target, non-source target) are
        // already reported once by validatePolicyMappingTable against the
        // poetry key; here we only consume the mapping for claims. A target
        // that is missing or not a source still marks the evidence dead so the
        // record cannot resolve from it, but no duplicate exception is emitted.
        if (audit.policy.exactMappingOwner(id)) |owner| {
            const hits = audit.index.get(owner);
            if (hits == null) {
                dead_evidence = true;
            } else {
                var found = false;
                for (hits.?) |i| {
                    if (audit.records[i].kind == .source) {
                        try claims.append(gpa, .{ .owner_id = audit.records[i].id.?, .evidence = .policy });
                        found = true;
                    }
                }
                if (!found) dead_evidence = true;
            }
        }

        if (unsupported) {
            rec.alignment = .malformed_record;
            rec.claims = try gpa.dupe(Claim, claims.items);
            continue;
        }

        // Resolution: valid evidence decides the alignment; dead evidence is
        // a structural exception that still fails the structural gate.
        if (claims.items.len == 0) {
            rec.alignment = if (dead_evidence) .missing_target else .orphan;
        } else {
            try resolveOwner(audit, gpa, rec, claims.items);
        }
    }
}

fn resolveOwner(audit: *Audit, gpa: std.mem.Allocator, rec: *Record, claims: []const Claim) !void {
    // Distinct owners, and the set of evidence kinds per owner.
    var owners: std.ArrayList([]const u8) = .empty;
    defer owners.deinit(gpa);
    var owner_kinds: std.ArrayList(EvidenceKind) = .empty;
    defer owner_kinds.deinit(gpa);
    for (claims) |c| {
        var found = false;
        for (owners.items, 0..) |o, oi| {
            if (util.eql(o, c.owner_id)) {
                try owner_kinds.append(gpa, c.evidence);
                found = true;
                break;
            }
            _ = oi;
        }
        if (!found) {
            try owners.append(gpa, c.owner_id);
            try owner_kinds.append(gpa, c.evidence);
        }
    }

    if (owners.items.len == 1) {
        rec.alignment = .mapped;
        rec.owner = owners.items[0];
        rec.claims = try gpa.dupe(Claim, claims);
        return;
    }

    // Contested: the machine-readable flavor is set on the record itself
    // (duplicate_mapping when the same evidence kind names several owners,
    // mapping_disagreement when different evidence kinds disagree), so the
    // alignment counts and the per-record output always agree.
    var distinct_kinds: usize = 0;
    var kinds_seen: [3]bool = .{ false, false, false };
    for (owner_kinds.items) |k| {
        const ki: usize = switch (k) {
            .parent => 0,
            .relation => 1,
            .policy => 2,
        };
        if (!kinds_seen[ki]) {
            kinds_seen[ki] = true;
            distinct_kinds += 1;
        }
    }
    const flavor: AlignmentStatus = if (distinct_kinds == 1) .duplicate_mapping else .mapping_disagreement;
    rec.alignment = flavor;
    rec.claims = try gpa.dupe(Claim, claims);
    var detail: std.ArrayList(u8) = .empty;
    for (owners.items, 0..) |o, oi| {
        if (oi > 0) try detail.appendSlice(gpa, ", ");
        try detail.appendSlice(gpa, o);
    }
    try addException(audit, gpa, .{
        .kind = flavor.jsonName(),
        .severity = .structural,
        .record_id = rec.id.?,
        .detail = try std.fmt.allocPrint(gpa, "poetry record is claimed by multiple source records: {s}", .{try detail.toOwnedSlice(gpa)}),
    });
}

// ---------------------------------------------------------------------------
// Coverage model
// ---------------------------------------------------------------------------

fn computeCoverage(audit: *Audit, gpa: std.mem.Allocator) !void {
    // Build a map from poetry record id -> record index for mapped/contest records.
    var poetry_by_type: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .{};
    defer {
        var it = poetry_by_type.iterator();
        while (it.next()) |e| e.value_ptr.deinit(gpa);
        poetry_by_type.deinit(gpa);
    }
    for (audit.records, 0..) |rec, i| {
        if (rec.kind != .poetry or rec.excluded) continue;
        const t = rec.poetry_type.?;
        var list = poetry_by_type.get(t) orelse std.ArrayList(usize).empty;
        try list.append(gpa, i);
        try poetry_by_type.put(gpa, t, list);
    }

    for (audit.records) |*rec| {
        if (rec.kind != .source or rec.excluded) continue;
        if (rec.id == null or rec.malformed_reason != null) continue;
        const expected = audit.policy.expectedTypesForCollection(rec.collection) orelse continue;
        const id = rec.id.?;
        var types: std.ArrayList([]const u8) = .empty;
        var classes: std.ArrayList(CoverageClass) = .empty;
        for (expected) |t| {
            try types.append(gpa, t);
            // Candidates: poetry records of type t claiming this source.
            var best: ?usize = null;
            var mapped_candidates: usize = 0;
            var contested = false;
            var unsupported_claim = false;
            if (poetry_by_type.get(t)) |list| {
                for (list.items) |pi| {
                    const p = audit.records[pi];
                    if (p.claims.len == 0) continue;
                    var claims_this = false;
                    for (p.claims) |c| {
                        if (util.eql(c.owner_id, id)) {
                            claims_this = true;
                            break;
                        }
                    }
                    if (!claims_this) continue;
                    if (p.alignment == .mapped) {
                        mapped_candidates += 1;
                        if (best == null) best = pi;
                    } else if (p.unsupported_shape) {
                        // An unsupported-shape record claiming this source:
                        // coverage is malformed, never substantive.
                        unsupported_claim = true;
                    } else {
                        contested = true;
                    }
                }
            }
            if (mapped_candidates > 1) {
                // Multiple poetry records of the same type mapped to the same
                // source record: a structural duplicate-coverage finding. The
                // first record is never selected as the answer.
                try addException(audit, gpa, .{
                    .kind = "duplicate_coverage",
                    .severity = .structural,
                    .record_id = id,
                    .detail = try std.fmt.allocPrint(gpa, "multiple {s} poetry records are mapped to this source record", .{t}),
                });
                try classes.append(gpa, .ambiguous_mapping);
            } else if (best) |pi| {
                const p = audit.records[pi];
                const cls = coverageClassForRecord(&p);
                try classes.append(gpa, cls);
            } else if (unsupported_claim) {
                try classes.append(gpa, .malformed);
            } else if (contested) {
                try classes.append(gpa, .ambiguous_mapping);
            } else {
                try classes.append(gpa, .missing);
            }
        }
        rec.coverage_types = try types.toOwnedSlice(gpa);
        rec.coverage_classes = try classes.toOwnedSlice(gpa);
    }

    // Aggregate rows keyed by collection+type.
    var row_map: std.StringHashMapUnmanaged(usize) = .{};
    defer row_map.deinit(gpa);
    var rows: std.ArrayList(CoverageRow) = .empty;
    // Pre-create rows for every eligible collection x type.
    var ec_it = audit.policy.eligible_collections.iterator();
    while (ec_it.next()) |ec| {
        const types = ec.value_ptr.*;
        for (types) |t| {
            const key = try std.fmt.allocPrint(gpa, "{s}\u{0}{s}", .{ ec.key_ptr.*, t });
            try rows.append(gpa, .{ .collection = ec.key_ptr.*, .type_name = t });
            try row_map.put(gpa, key, rows.items.len - 1);
        }
    }
    // Fill.
    for (audit.records) |rec| {
        if (rec.kind != .source or rec.excluded) continue;
        for (rec.coverage_types, rec.coverage_classes) |t, cls| {
            const key = try std.fmt.allocPrint(gpa, "{s}\u{0}{s}", .{ rec.collection, t });
            const ri = row_map.get(key) orelse continue;
            rows.items[ri].expected += 1;
            switch (cls) {
                .missing => rows.items[ri].missing += 1,
                .present_empty => rows.items[ri].present_empty += 1,
                .present_placeholder => rows.items[ri].present_placeholder += 1,
                .present_substantive => rows.items[ri].present_substantive += 1,
                .ambiguous_mapping => rows.items[ri].ambiguous_mapping += 1,
                .malformed => rows.items[ri].malformed += 1,
            }
        }
    }
    std.mem.sort(CoverageRow, rows.items, {}, struct {
        fn less(_: void, a: CoverageRow, b: CoverageRow) bool {
            const ko = std.mem.order(u8, a.collection, b.collection);
            if (ko != .eq) return ko == .lt;
            return std.mem.order(u8, a.type_name, b.type_name) == .lt;
        }
    }.less);
    audit.coverage_rows = try rows.toOwnedSlice(gpa);
}

fn coverageClassForRecord(p: *const Record) CoverageClass {
    if (p.malformed_reason != null) return .malformed;
    const v = p.verse orelse return .malformed;
    if (v.complete_count == 0) {
        if (v.malformed_count > 0) return .malformed;
        return .present_empty;
    }
    if (v.substantive_count > 0) return .present_substantive;
    return .present_placeholder;
}

/// Deterministic "type:class,type:class" summary of a source record's
/// coverage, used identically by report.json and delta comparison.
pub fn coverageSummary(gpa: std.mem.Allocator, rec: *const Record) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (rec.coverage_types, rec.coverage_classes) |t, cls| {
        if (buf.items.len > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, t);
        try buf.append(gpa, ':');
        try buf.appendSlice(gpa, cls.jsonName());
    }
    return try buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Type totals + density
// ---------------------------------------------------------------------------

fn computeTypeStats(audit: *Audit, gpa: std.mem.Allocator) !void {
    audit.type_stats = try buildTypeStats(audit, gpa, &.{});
}

/// Type totals within a collection scope. `filter` empty means the whole tree.
pub fn typeStatsScoped(audit: *const Audit, gpa: std.mem.Allocator, filter: []const []const u8) ![]TypeStats {
    return buildTypeStats(audit, gpa, filter);
}

fn buildTypeStats(audit: *const Audit, gpa: std.mem.Allocator, filter: []const []const u8) ![]TypeStats {
    // Distinct types across poetry records and coverage expectations.
    var names: std.StringHashMapUnmanaged(void) = .{};
    defer names.deinit(gpa);
    var pc_it = audit.policy.poetry_collections.iterator();
    while (pc_it.next()) |pc| try names.put(gpa, pc.value_ptr.*, {});
    var ec_it = audit.policy.eligible_collections.iterator();
    while (ec_it.next()) |ec| {
        for (ec.value_ptr.*) |t| try names.put(gpa, t, {});
    }
    var name_list: std.ArrayList([]const u8) = .empty;
    var it = names.iterator();
    while (it.next()) |e| try name_list.append(gpa, e.key_ptr.*);
    util.sortStrings(gpa, name_list.items);

    var stats: std.ArrayList(TypeStats) = .empty;
    for (name_list.items) |t| {
        var s: TypeStats = .{ .type_name = t };
        for (audit.records) |rec| {
            if (rec.kind != .poetry or rec.excluded) continue;
            if (!recordInScope(audit, &rec, filter)) continue;
            if (rec.malformed_reason != null) continue; // no verse analyzed
            if (!util.eql(rec.poetry_type.?, t)) continue;
            s.records += 1;
            if (rec.unsupported_shape) {
                // Unsupported shapes never grant units; each such record is
                // reported as one malformed/unsupported unit.
                s.malformed_units += 1;
                continue;
            }
            if (rec.verse) |v| {
                s.verse_units += v.complete_count;
                s.placeholder_units += v.placeholder_count;
                s.substantive_units += v.substantive_count;
                s.malformed_units += v.malformed_count;
            }
        }
        try stats.append(gpa, s);
    }
    return try stats.toOwnedSlice(gpa);
}

fn computeDensity(audit: *Audit, gpa: std.mem.Allocator) !void {
    audit.type_densities = try buildDensity(audit, gpa, audit.type_stats, &.{});
}

/// Density within a collection scope. `filter` empty means the whole tree.
pub fn typeDensitiesScoped(audit: *const Audit, gpa: std.mem.Allocator, type_stats: []const TypeStats, filter: []const []const u8) ![]TypeDensity {
    return buildDensity(audit, gpa, type_stats, filter);
}

fn buildDensity(audit: *const Audit, gpa: std.mem.Allocator, type_stats: []const TypeStats, filter: []const []const u8) ![]TypeDensity {
    const DensityRec = struct { id: []const u8, count: usize };
    var densities: std.ArrayList(TypeDensity) = .empty;
    for (type_stats) |st| {
        var td: TypeDensity = .{ .type_name = st.type_name };
        // Records of this type with their unit counts.
        var counts: std.ArrayList(DensityRec) = .empty;
        defer counts.deinit(gpa);
        for (audit.records) |rec| {
            if (rec.kind != .poetry or rec.excluded) continue;
            if (!recordInScope(audit, &rec, filter)) continue;
            if (rec.malformed_reason != null or rec.unsupported_shape) continue; // no id/verse; reported as structural
            if (!util.eql(rec.poetry_type.?, st.type_name)) continue;
            const n = if (rec.verse) |v| v.complete_count else 0;
            try counts.append(gpa, .{ .id = rec.id.?, .count = n });
        }
        std.mem.sort(DensityRec, counts.items, {}, struct {
            fn less(_: void, a: DensityRec, b: DensityRec) bool {
                if (a.count != b.count) return a.count < b.count;
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.less);

        // Distribution count -> records.
        var dist: std.ArrayList(DensityEntry) = .empty;
        const band_set = audit.policy.density_bands.get(st.type_name);
        var i: usize = 0;
        while (i < counts.items.len) {
            var j = i;
            while (j < counts.items.len and counts.items[j].count == counts.items[i].count) j += 1;
            try dist.append(gpa, .{ .unit_count = counts.items[i].count, .record_count = j - i });
            const in_band = if (band_set) |bs| blk: {
                var inb = false;
                for (bs) |n| {
                    if (n == counts.items[i].count) {
                        inb = true;
                        break;
                    }
                }
                break :blk inb;
            } else false;
            if (in_band) {
                td.in_band_records += j - i;
            } else {
                td.out_of_band_records += j - i;
            }
            i = j;
        }
        td.distribution = try dist.toOwnedSlice(gpa);

        if (counts.items.len > 0) {
            td.lowest_count = counts.items[0].count;
            td.highest_count = counts.items[counts.items.len - 1].count;
            var lo: std.ArrayList([]const u8) = .empty;
            for (counts.items) |c| {
                if (c.count == td.lowest_count) try lo.append(gpa, c.id);
            }
            var hi: std.ArrayList([]const u8) = .empty;
            for (counts.items) |c| {
                if (c.count == td.highest_count) try hi.append(gpa, c.id);
            }
            td.lowest = try lo.toOwnedSlice(gpa);
            td.highest = try hi.toOwnedSlice(gpa);
        }
        try densities.append(gpa, td);
    }
    return try densities.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Collection scope
// ---------------------------------------------------------------------------

/// Physical-collection membership: an empty filter selects everything, and a
/// non-empty filter selects records whose own physical collection (the first
/// path component under the content root) is listed.
fn physicalInScope(collection: []const u8, filter: []const []const u8) bool {
    if (filter.len == 0) return true;
    for (filter) |c| {
        if (util.eql(c, collection)) return true;
    }
    return false;
}

/// True when the record belongs to the selected scope. `--collection` names
/// **eligible source collections**: a source record is in scope when its
/// physical collection is selected; a poetry record is in scope when any of
/// its resolved owner claims resolve to a source record in a selected
/// collection (this is what keeps a mapped poem visible in its source's
/// report). Unmapped poetry falls back to physical-collection membership.
/// Every section of a filtered report uses exactly this rule, so totals,
/// verse totals, coverage, density, alignment, exceptions, deltas, per-record
/// output, and exit-code findings always describe the same population.
pub fn recordInScope(audit: *const Audit, rec: *const Record, filter: []const []const u8) bool {
    if (filter.len == 0) return true;
    if (rec.kind == .poetry) {
        for (rec.claims) |c| {
            if (audit.index.get(c.owner_id)) |hits| {
                for (hits) |i| {
                    if (audit.records[i].kind == .source and physicalInScope(audit.records[i].collection, filter)) return true;
                }
            }
        }
    }
    return physicalInScope(rec.collection, filter);
}

/// Map an exception's `record_id` (a canonical id or a content-root-relative
/// path) back to its record so exceptions can be scoped by the same rule.
pub fn recordIdInScope(audit: *const Audit, record_id: []const u8, filter: []const []const u8) bool {
    if (filter.len == 0) return true;
    if (audit.index.get(record_id)) |hits| {
        if (hits.len > 0 and recordInScope(audit, &audit.records[hits[0]], filter)) return true;
    }
    return physicalInScope(collectionOfPath(record_id), filter);
}

// ---------------------------------------------------------------------------
// Delta mode
// ---------------------------------------------------------------------------

pub const DeltaError = error{
    MalformedPreviousReport,
    UnsupportedFormatId,
    UnsupportedSchemaVersion,
    ModeMismatch,
    SourceRootMismatch,
    MissingPolicyDigest,
    PolicyIdentityMismatch,
    CollectionFilterMismatch,
    OutOfMemory,
};

/// Strict delta compatibility: a previous report is only comparable when it
/// carries the exact format id, the exact supported schema version, the same
/// mode, the same source-root label, an identical policy digest, and the same
/// collection-filter semantics. Missing compatibility fields are rejected,
/// never treated as optional; filtered and unfiltered populations are never
/// compared as though they were the same.
pub fn compareDelta(audit: *Audit, gpa: std.mem.Allocator, previous: std.json.Value, current_filter: []const []const u8) DeltaError!void {
    if (previous != .object) return error.MalformedPreviousReport;

    const format_id = jsonGetString(previous, "format_id") orelse return error.MalformedPreviousReport;
    if (!util.eql(format_id, util.format_id)) return error.UnsupportedFormatId;

    const schema = previous.object.get("schema_version") orelse return error.MalformedPreviousReport;
    if (schema != .integer or schema.integer != util.report_schema_version) return error.UnsupportedSchemaVersion;
    audit.previous_report_schema = @intCast(schema.integer);

    const mode = jsonGetString(previous, "mode") orelse return error.MalformedPreviousReport;
    if (!util.eql(mode, "poetry")) return error.ModeMismatch;

    const prev_root = jsonGetString(previous, "source_root_label") orelse return error.MalformedPreviousReport;
    if (!util.eql(prev_root, audit.source_root_label)) return error.SourceRootMismatch;

    const prev_digest = jsonGetString(previous, "policy_digest") orelse return error.MissingPolicyDigest;
    if (!util.eql(prev_digest, audit.policy_digest)) return error.PolicyIdentityMismatch;
    audit.previous_policy_digest = prev_digest;

    const prev_filter = previous.object.get("collection_filter") orelse return error.MalformedPreviousReport;
    if (prev_filter != .array) return error.MalformedPreviousReport;
    if (prev_filter.array.items.len != current_filter.len) return error.CollectionFilterMismatch;
    // Compare as sets: the collection_filter is a selection semantics, not an
    // ordered argument list, so `--collection=a --collection=b` and
    // `--collection=b --collection=a` are the same population.
    var prev_names: std.ArrayList([]const u8) = .empty;
    defer prev_names.deinit(gpa);
    for (prev_filter.array.items) |item| {
        if (item != .string) return error.MalformedPreviousReport;
        try prev_names.append(gpa, item.string);
    }
    util.sortStrings(gpa, prev_names.items);
    var cur_names: std.ArrayList([]const u8) = .empty;
    defer cur_names.deinit(gpa);
    for (current_filter) |c| try cur_names.append(gpa, c);
    util.sortStrings(gpa, cur_names.items);
    for (prev_names.items, 0..) |p, i| {
        if (!util.eql(p, cur_names.items[i])) return error.CollectionFilterMismatch;
    }

    const prev_records = if (previous.object.get("records")) |r| switch (r) {
        .array => |a| a.items,
        else => return error.MalformedPreviousReport,
    } else return error.MalformedPreviousReport;

    var prev_map: std.StringHashMapUnmanaged(struct { coverage: []const u8, verse: usize, alignment: []const u8, placeholder: usize, substantive: usize }) = .{};
    defer prev_map.deinit(gpa);
    for (prev_records) |rv| {
        const id = jsonGetString(rv, "id") orelse continue;
        const cov = jsonGetString(rv, "coverage") orelse "";
        const align_status = jsonGetString(rv, "alignment") orelse "";
        const verse_n = jsonGetInteger(rv, "verse_units") orelse 0;
        const ph = jsonGetInteger(rv, "placeholder_units") orelse 0;
        const sub = jsonGetInteger(rv, "substantive_units") orelse 0;
        try prev_map.put(gpa, id, .{ .coverage = cov, .verse = verse_n, .alignment = align_status, .placeholder = ph, .substantive = sub });
    }

    var changes: std.ArrayList(DeltaChange) = .empty;
    var prev_seen: std.StringHashMapUnmanaged(void) = .{};
    defer prev_seen.deinit(gpa);

    // Only the filtered population is compared; the previous report is from
    // the same filtered population by construction (filter identity enforced
    // above), so out-of-scope current records are never misread as added.
    for (audit.records) |rec| {
        if (!recordInScope(audit, &rec, current_filter)) continue;
        const id = rec.id orelse continue;
        if (prev_map.get(id)) |p| {
            try prev_seen.put(gpa, id, {});
            // coverage changed (source records: any expected type class changed)
            if (rec.kind == .source) {
                const cur = try coverageSummary(gpa, &rec);
                if (!util.eql(p.coverage, cur)) {
                    try changes.append(gpa, .{ .kind = "coverage_changed", .record_id = id, .from = p.coverage, .to = cur });
                }
            } else if (rec.kind == .poetry) {
                if (p.alignment.len > 0 and rec.alignment != null and !util.eql(p.alignment, rec.alignment.?.jsonName())) {
                    const from = p.alignment;
                    const to = rec.alignment.?.jsonName();
                    if (util.eql(from, "orphan")) {
                        try changes.append(gpa, .{ .kind = "newly_resolved", .record_id = id, .from = from, .to = to });
                    } else if (util.eql(to, "orphan")) {
                        try changes.append(gpa, .{ .kind = "newly_orphaned", .record_id = id, .from = from, .to = to });
                    } else {
                        try changes.append(gpa, .{ .kind = "mapping_changed", .record_id = id, .from = from, .to = to });
                    }
                }
                const cur_verse = if (rec.verse) |v| v.complete_count else 0;
                if (p.verse != cur_verse) {
                    try changes.append(gpa, .{ .kind = "verse_changed", .record_id = id, .from = try std.fmt.allocPrint(gpa, "{d}", .{p.verse}), .to = try std.fmt.allocPrint(gpa, "{d}", .{cur_verse}) });
                }
                const cur_sub = if (rec.verse) |v| v.substantive_count else 0;
                if (p.placeholder > 0 and p.substantive == 0 and cur_sub > 0) {
                    try changes.append(gpa, .{ .kind = "placeholder_to_substantive", .record_id = id });
                }
            }
        } else {
            try changes.append(gpa, .{ .kind = "added_record", .record_id = id });
        }
    }
    var pit = prev_map.iterator();
    while (pit.next()) |e| {
        if (!prev_seen.contains(e.key_ptr.*)) {
            try changes.append(gpa, .{ .kind = "removed_record", .record_id = e.key_ptr.* });
        }
    }
    std.mem.sort(DeltaChange, changes.items, {}, struct {
        fn less(_: void, a: DeltaChange, b: DeltaChange) bool {
            const ko = std.mem.order(u8, a.kind, b.kind);
            if (ko != .eq) return ko == .lt;
            return std.mem.order(u8, a.record_id, b.record_id) == .lt;
        }
    }.less);
    audit.delta = try changes.toOwnedSlice(gpa);
}

fn jsonGetString(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn jsonGetInteger(v: std.json.Value, key: []const u8) ?usize {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return switch (f) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}
