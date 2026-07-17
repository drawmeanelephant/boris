//! Narrow, reversible Filed.fyi migration proof.  This intentionally knows only
//! the observed Astro collection layout: src/content/docs/changelog/* (one
//! record) and src/content/docs/releases/* (three records). It never imports
//! Boris core.
//!
//! Parent-key normalization (Filed adapter only):
//!   parentEntry  → parent
//!   parent_entry → parent
//! Product Boris still rejects those legacy keys as unknown (EFRONTMATTER).

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-filed-fyi-migration-lab";
pub const schema_version: u32 = 2;
pub const tool_version = "0.1.1";

pub const RunOptions = struct {
    source_root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

const Collection = enum { changelog, releases };

/// Outcome of the Filed-only parent key rewrite stage.
pub const ParentNormStatus = enum {
    /// No parent / parentEntry / parent_entry in source frontmatter.
    missing,
    /// Source already had only canonical `parent` (safe value preserved).
    identity,
    /// At least one legacy key rewrote to a single safe `parent` value.
    normalized,
    /// Multiple parent-key spellings with differing values — never auto-pick.
    conflict,
    /// Empty, oversize, traversal, or otherwise unsafe parent value.
    invalid,
};

pub const ParentKeyOccurrence = struct {
    key: []const u8,
    value: []const u8,
    /// 1-based line number in the source file (opening `---` is line 1).
    line: usize,
};

pub const ParentNormalization = struct {
    status: ParentNormStatus,
    /// Safe canonical parent entity id when status is identity or normalized.
    emitted_parent: ?[]const u8 = null,
    original_keys: []const ParentKeyOccurrence = &.{},
    reason: ?[]const u8 = null,
};

const Record = struct {
    collection: Collection,
    source_path: []const u8,
    output_path: []const u8,
    id: []const u8,
    title: []const u8,
    raw_frontmatter: []const u8,
    unmapped_frontmatter_fields: []const []const u8,
    body: []const u8,
    stripped_blocks: []const StrippedBlock,
    parent_norm: ParentNormalization,
};

const StrippedBlock = struct { line: usize, category: []const u8 };

fn collectionName(c: Collection) []const u8 {
    return switch (c) {
        .changelog => "changelog",
        .releases => "releases",
    };
}

fn isMarkdown(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or std.mem.endsWith(u8, name, ".mdx");
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn isParentKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "parent") or
        std.mem.eql(u8, key, "parentEntry") or
        std.mem.eql(u8, key, "parent_entry");
}

fn stripScalarQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return value[1 .. value.len - 1];
    }
    return value;
}

/// Local mirror of Boris entity-id shape rules (no product import).
/// Parent values must be plain entity ids, never paths with `..` or spaces.
pub fn isSafeParentId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255) return false;
    if (id[0] == '/') return false;
    if (id[id.len - 1] == '/' or id[id.len - 1] == '\\') return false;
    var i: usize = 0;
    while (i < id.len) {
        const start = i;
        while (i < id.len and id[i] != '/' and id[i] != '\\') : (i += 1) {}
        if (i < id.len and id[i] == '\\') return false;
        const seg = id[start..i];
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        for (seg) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
        }
        if (i < id.len) i += 1;
    }
    return true;
}

fn statusName(s: ParentNormStatus) []const u8 {
    return switch (s) {
        .missing => "missing",
        .identity => "identity",
        .normalized => "normalized",
        .conflict => "conflict",
        .invalid => "invalid",
    };
}

/// Deterministic parent-key normalization for Filed migration only.
/// Does not invent parents from directory names. Preserves value bytes exactly
/// when the rewrite is safe. Never chooses among conflicting values.
pub fn normalizeParentKeys(
    allocator: std.mem.Allocator,
    frontmatter: []const u8,
    /// File line number of the first frontmatter field line (usually 2).
    first_field_line: usize,
) !ParentNormalization {
    var occurrences: std.ArrayList(ParentKeyOccurrence) = .empty;
    errdefer occurrences.deinit(allocator);

    var pos: usize = 0;
    var line_no: usize = first_field_line;
    while (pos < frontmatter.len) {
        const line_end = std.mem.indexOfScalarPos(u8, frontmatter, pos, '\n') orelse frontmatter.len;
        const line = frontmatter[pos..line_end];
        // Skip empty and indented lines (nested YAML is not interpreted).
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const key = trim(line[0..colon]);
                const raw_value = trim(line[colon + 1 ..]);
                if (isParentKey(key)) {
                    const value = stripScalarQuotes(raw_value);
                    try occurrences.append(allocator, .{
                        .key = try allocator.dupe(u8, key),
                        .value = try allocator.dupe(u8, value),
                        .line = line_no,
                    });
                }
            }
        }
        pos = if (line_end == frontmatter.len) frontmatter.len else line_end + 1;
        line_no += 1;
    }

    const owned = try occurrences.toOwnedSlice(allocator);
    if (owned.len == 0) {
        return .{ .status = .missing, .emitted_parent = null, .original_keys = owned, .reason = null };
    }

    // Validate each occurrence; any unsafe value → invalid (do not rewrite).
    for (owned) |occ| {
        if (occ.value.len == 0) {
            return .{
                .status = .invalid,
                .emitted_parent = null,
                .original_keys = owned,
                .reason = "empty_parent_value",
            };
        }
        if (std.mem.eql(u8, occ.value, "|") or std.mem.eql(u8, occ.value, ">") or
            std.mem.eql(u8, occ.value, ">-") or std.mem.eql(u8, occ.value, "|-"))
        {
            return .{
                .status = .invalid,
                .emitted_parent = null,
                .original_keys = owned,
                .reason = "block_scalar_parent_value",
            };
        }
        if (!isSafeParentId(occ.value)) {
            return .{
                .status = .invalid,
                .emitted_parent = null,
                .original_keys = owned,
                .reason = "unsafe_parent_value",
            };
        }
    }

    // Conflict: distinct safe values across any parent-key spellings.
    const first_value = owned[0].value;
    for (owned[1..]) |occ| {
        if (!std.mem.eql(u8, occ.value, first_value)) {
            return .{
                .status = .conflict,
                .emitted_parent = null,
                .original_keys = owned,
                .reason = "conflicting_parent_values",
            };
        }
    }

    // Identical values (possibly mixed spellings) → single canonical parent.
    var saw_legacy = false;
    var saw_canonical = false;
    for (owned) |occ| {
        if (std.mem.eql(u8, occ.key, "parent")) saw_canonical = true else saw_legacy = true;
    }

    const status: ParentNormStatus = if (saw_legacy) .normalized else .identity;
    return .{
        .status = status,
        .emitted_parent = try allocator.dupe(u8, first_value),
        .original_keys = owned,
        .reason = null,
    };
}

const ParsedSource = struct {
    title: []const u8,
    frontmatter: []const u8,
    body: []const u8,
    unmapped_fields: []const []const u8,
    parent_norm: ParentNormalization,
};

fn parseSource(allocator: std.mem.Allocator, raw: []const u8, fallback_title: []const u8) !ParsedSource {
    if (!std.mem.startsWith(u8, raw, "---\n")) {
        return .{
            .title = fallback_title,
            .frontmatter = "",
            .body = raw,
            .unmapped_fields = &.{},
            .parent_norm = .{ .status = .missing },
        };
    }
    const end_start = std.mem.indexOfPos(u8, raw, 4, "\n---\n") orelse {
        return .{
            .title = fallback_title,
            .frontmatter = raw,
            .body = "",
            .unmapped_fields = &.{},
            .parent_norm = .{ .status = .missing },
        };
    };
    const frontmatter = raw[4..end_start];
    var title: []const u8 = fallback_title;
    var unmapped: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (pos < frontmatter.len) {
        const line_end = std.mem.indexOfScalarPos(u8, frontmatter, pos, '\n') orelse frontmatter.len;
        const line = frontmatter[pos..line_end];
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const key = trim(line[0..colon]);
                var value = trim(line[colon + 1 ..]);
                // title is mapped; parent* keys are handled by normalizeParentKeys.
                // All other keys remain visible as review/unmapped items.
                if (std.mem.eql(u8, key, "title")) {
                    value = stripScalarQuotes(value);
                    if (value.len > 0) title = try allocator.dupe(u8, value);
                } else if (!isParentKey(key)) {
                    try unmapped.append(allocator, try allocator.dupe(u8, key));
                }
            }
        }
        pos = if (line_end == frontmatter.len) frontmatter.len else line_end + 1;
    }
    // Opening fence is line 1; first field line is 2 when present.
    const parent_norm = try normalizeParentKeys(allocator, frontmatter, 2);
    return .{
        .title = title,
        .frontmatter = frontmatter,
        .body = raw[end_start + "\n---\n".len ..],
        .unmapped_fields = try unmapped.toOwnedSlice(allocator),
        .parent_norm = parent_norm,
    };
}

fn categoryForBlockStart(line: []const u8) ?[]const u8 {
    const s = trim(line);
    const starts = [_]struct { prefix: []const u8, category: []const u8 }{
        .{ .prefix = ":::agent", .category = "agent_fence" },
        .{ .prefix = ":::directive", .category = "directive_fence" },
        .{ .prefix = ":::instruction", .category = "instruction_fence" },
        .{ .prefix = ":::prompt", .category = "prompt_fence" },
        .{ .prefix = "```agent", .category = "agent_code_fence" },
        .{ .prefix = "```directive", .category = "directive_code_fence" },
        .{ .prefix = "```instruction", .category = "instruction_code_fence" },
        .{ .prefix = "<Agent", .category = "agent_tag" },
        .{ .prefix = "<Directive", .category = "directive_tag" },
        .{ .prefix = "<Instruction", .category = "instruction_tag" },
    };
    for (starts) |entry| if (std.mem.startsWith(u8, s, entry.prefix)) return entry.category;
    return null;
}

fn isBlockEnd(line: []const u8, category: []const u8) bool {
    const s = trim(line);
    if (std.mem.endsWith(u8, category, "fence")) return std.mem.eql(u8, s, ":::") or std.mem.eql(u8, s, "```");
    return std.mem.startsWith(u8, s, "</");
}

/// The contents of only clearly delimited instruction-shaped blocks are never
/// parsed, copied, or used as control flow.
fn stripUntrustedBlocks(a: std.mem.Allocator, body: []const u8) !struct { body: []const u8, blocks: []const StrippedBlock } {
    var out: std.ArrayList(u8) = .empty;
    var blocks: std.ArrayList(StrippedBlock) = .empty;
    var pos: usize = 0;
    var line_no: usize = 1;
    var active: ?[]const u8 = null;
    while (pos < body.len) {
        const end = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        const line = body[pos..end];
        const has_newline = end < body.len;
        if (active) |category| {
            if (isBlockEnd(line, category)) active = null;
        } else if (categoryForBlockStart(line)) |category| {
            try blocks.append(a, .{ .line = line_no, .category = category });
            active = category;
        } else {
            try out.appendSlice(a, line);
            if (has_newline) try out.append(a, '\n');
        }
        pos = if (has_newline) end + 1 else end;
        line_no += 1;
    }
    return .{ .body = try out.toOwnedSlice(a), .blocks = try blocks.toOwnedSlice(a) };
}

fn slugAlloc(allocator: std.mem.Allocator, source_name: []const u8) ![]u8 {
    const stem = if (std.mem.endsWith(u8, source_name, ".mdx"))
        source_name[0 .. source_name.len - 4]
    else
        source_name[0 .. source_name.len - 3];
    var out: std.ArrayList(u8) = .empty;
    var dash = false;
    for (stem) |c| {
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            try out.append(allocator, lower);
            dash = false;
        } else if (!dash and out.items.len > 0) {
            try out.append(allocator, '-');
            dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') out.items.len -= 1;
    if (out.items.len == 0) return error.InvalidSourceName;
    return try out.toOwnedSlice(allocator);
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeFile(io: Io, root: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try root.createDirPath(io, parent);
    try root.writeFile(io, .{ .sub_path = path, .data = data });
}

fn appendJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn appendUsize(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: usize) !void {
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{value}));
}

/// Decides the `parent:` value written into generated closed frontmatter.
/// Safe normalized/identity values win. Missing parent keys keep the first-slice
/// collection Trunk as converter-owned structure (not directory invention by
/// the normalizer). Conflict/invalid never silently pick a source value.
fn decidedParent(r: Record) ?[]const u8 {
    return switch (r.parent_norm.status) {
        .identity, .normalized => r.parent_norm.emitted_parent,
        .missing => collectionName(r.collection),
        .conflict, .invalid => null,
    };
}

fn emitPage(a: std.mem.Allocator, r: Record) ![]u8 {
    const parent = decidedParent(r);
    if (parent) |p| {
        return try std.fmt.allocPrint(a,
            \\---
            \\id: {s}
            \\title: {s}
            \\parent: {s}
            \\status: published
            \\tags: [filed, {s}]
            \\---
            \\<!-- boris-migration-provenance
            \\  format: {s}
            \\  source_path: {s}
            \\  tool_version: {s}
            \\  parent_normalization: {s}
            \\-->
            \\{s}
        , .{ r.id, r.title, p, collectionName(r.collection), format_id, r.source_path, tool_version, statusName(r.parent_norm.status), r.body });
    }
    return try std.fmt.allocPrint(a,
        \\---
        \\id: {s}
        \\title: {s}
        \\status: published
        \\tags: [filed, {s}]
        \\---
        \\<!-- boris-migration-provenance
        \\  format: {s}
        \\  source_path: {s}
        \\  tool_version: {s}
        \\  parent_normalization: {s}
        \\-->
        \\{s}
    , .{ r.id, r.title, collectionName(r.collection), format_id, r.source_path, tool_version, statusName(r.parent_norm.status), r.body });
}

fn emitIndex(a: std.mem.Allocator, collection: Collection) ![]u8 {
    const name = collectionName(collection);
    const title = if (collection == .changelog) "Changelog" else "Releases";
    return try std.fmt.allocPrint(a,
        \\---
        \\id: {s}
        \\title: {s}
        \\status: published
        \\tags: [filed, collection]
        \\---
        \\
        \\Migrated Filed.fyi {s} collection index.
        \\
    , .{ name, title, name });
}

fn collectCollection(io: Io, a: std.mem.Allocator, root: Io.Dir, collection: Collection, out: *std.ArrayList(Record)) !void {
    const name = collectionName(collection);
    const source_dir = try std.fmt.allocPrint(a, "src/content/docs/{s}", .{name});
    var dir = try root.openDir(io, source_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isMarkdown(entry.name)) continue;
        const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ source_dir, entry.name });
        const raw = try readFileAlloc(io, root, rel, a);
        const fallback = try slugAlloc(a, entry.name);
        const parsed = try parseSource(a, raw, fallback);
        const stripped = try stripUntrustedBlocks(a, parsed.body);
        const slug = try slugAlloc(a, entry.name);
        const id = try std.fmt.allocPrint(a, "{s}/{s}", .{ name, slug });
        const output = try std.fmt.allocPrint(a, "content/{s}/{s}.md", .{ name, slug });
        try out.append(a, .{
            .collection = collection,
            .source_path = rel,
            .output_path = output,
            .id = id,
            .title = parsed.title,
            .raw_frontmatter = parsed.frontmatter,
            .unmapped_frontmatter_fields = parsed.unmapped_fields,
            .body = stripped.body,
            .stripped_blocks = stripped.blocks,
            .parent_norm = parsed.parent_norm,
        });
    }
}

fn appendParentNormJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: ParentNormalization) !void {
    try buf.appendSlice(a, "{ \"status\": ");
    try appendJson(buf, a, statusName(n.status));
    try buf.appendSlice(a, ", \"emitted_parent\": ");
    if (n.emitted_parent) |p| try appendJson(buf, a, p) else try buf.appendSlice(a, "null");
    try buf.appendSlice(a, ", \"reason\": ");
    if (n.reason) |r| try appendJson(buf, a, r) else try buf.appendSlice(a, "null");
    try buf.appendSlice(a, ", \"original_keys\": [");
    for (n.original_keys, 0..) |occ, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "{ \"key\": ");
        try appendJson(buf, a, occ.key);
        try buf.appendSlice(a, ", \"value\": ");
        try appendJson(buf, a, occ.value);
        try buf.appendSlice(a, ", \"line\": ");
        try appendUsize(buf, a, occ.line);
        try buf.appendSlice(a, " }");
    }
    try buf.appendSlice(a, "] }");
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: RunOptions) !void {
    // Keep the source root read-only even when a caller supplies relative paths.
    if (std.mem.eql(u8, opts.source_root_dir, opts.out_dir) or
        (opts.out_dir.len > opts.source_root_dir.len and
            std.mem.startsWith(u8, opts.out_dir, opts.source_root_dir) and
            (opts.out_dir[opts.source_root_dir.len] == '/' or opts.out_dir[opts.source_root_dir.len] == '\\')))
        return error.OutputInsideSource;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var source = try Io.Dir.cwd().openDir(io, opts.source_root_dir, .{ .iterate = true });
    defer source.close(io);
    var records: std.ArrayList(Record) = .empty;
    try collectCollection(io, a, source, .changelog, &records);
    const changelog_count = records.items.len;
    try collectCollection(io, a, source, .releases, &records);
    if (changelog_count != 1 or records.items.len - changelog_count != 3) return error.UnexpectedCollectionCardinality;
    std.mem.sort(Record, records.items, {}, struct {
        fn less(_: void, x: Record, y: Record) bool {
            return std.mem.order(u8, x.source_path, y.source_path) == .lt;
        }
    }.less);

    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var out = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out.close(io);
    for ([_]Collection{ .changelog, .releases }) |c| {
        const index_path = try std.fmt.allocPrint(a, "content/{s}/index.md", .{collectionName(c)});
        try writeFile(io, out, index_path, try emitIndex(a, c));
    }
    for (records.items) |r| try writeFile(io, out, r.output_path, try emitPage(a, r));

    var parent_counts = [_]usize{0} ** 5; // missing, identity, normalized, conflict, invalid
    for (records.items) |r| {
        parent_counts[@intFromEnum(r.parent_norm.status)] += 1;
    }

    var manifest: std.ArrayList(u8) = .empty;
    try manifest.appendSlice(a, "{\n  \"format\": \"boris-filed-fyi-provenance\",\n  \"schema_version\": 2,\n  \"records\": [\n");
    var report: std.ArrayList(u8) = .empty;
    try report.appendSlice(a, "{\n  \"format\": \"boris-filed-fyi-migration-lab\",\n  \"schema_version\": 2,\n  \"tool_version\": ");
    try appendJson(&report, a, tool_version);
    try report.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&report, a, opts.source_root_dir);
    try report.appendSlice(a, ",\n  \"converted_records\": 4,\n  \"parent_normalization\": {\n    \"missing\": ");
    try appendUsize(&report, a, parent_counts[@intFromEnum(ParentNormStatus.missing)]);
    try report.appendSlice(a, ",\n    \"identity\": ");
    try appendUsize(&report, a, parent_counts[@intFromEnum(ParentNormStatus.identity)]);
    try report.appendSlice(a, ",\n    \"normalized\": ");
    try appendUsize(&report, a, parent_counts[@intFromEnum(ParentNormStatus.normalized)]);
    try report.appendSlice(a, ",\n    \"conflict\": ");
    try appendUsize(&report, a, parent_counts[@intFromEnum(ParentNormStatus.conflict)]);
    try report.appendSlice(a, ",\n    \"invalid\": ");
    try appendUsize(&report, a, parent_counts[@intFromEnum(ParentNormStatus.invalid)]);
    try report.appendSlice(a, "\n  },\n  \"unmapped_frontmatter\": [\n");

    var unmapped_count: usize = 0;
    var stripped_count: usize = 0;
    for (records.items, 0..) |r, i| {
        try manifest.appendSlice(a, "    { \"collection\": ");
        try appendJson(&manifest, a, collectionName(r.collection));
        try manifest.appendSlice(a, ", \"source_path\": ");
        try appendJson(&manifest, a, r.source_path);
        try manifest.appendSlice(a, ", \"output_path\": ");
        try appendJson(&manifest, a, r.output_path);
        try manifest.appendSlice(a, ", \"raw_frontmatter\": ");
        try appendJson(&manifest, a, r.raw_frontmatter);
        try manifest.appendSlice(a, ", \"unmapped_frontmatter_fields\": [");
        for (r.unmapped_frontmatter_fields, 0..) |field, field_index| {
            if (field_index > 0) try manifest.appendSlice(a, ", ");
            try appendJson(&manifest, a, field);
        }
        try manifest.appendSlice(a, "], \"parent_normalization\": ");
        try appendParentNormJson(&manifest, a, r.parent_norm);
        try manifest.appendSlice(a, " }");
        if (i + 1 < records.items.len) try manifest.append(a, ',');
        try manifest.append(a, '\n');

        if (r.unmapped_frontmatter_fields.len > 0) {
            if (unmapped_count > 0) try report.appendSlice(a, ",\n");
            try report.appendSlice(a, "    { \"source_path\": ");
            try appendJson(&report, a, r.source_path);
            try report.appendSlice(a, ", \"fields\": [");
            for (r.unmapped_frontmatter_fields, 0..) |field, field_index| {
                if (field_index > 0) try report.appendSlice(a, ", ");
                try appendJson(&report, a, field);
            }
            try report.appendSlice(a, "] }");
            unmapped_count += 1;
        }
    }
    try manifest.appendSlice(a, "  ]\n}\n");

    try report.appendSlice(a, "\n  ],\n  \"parent_review\": [\n");
    var parent_review_count: usize = 0;
    for (records.items) |r| {
        if (r.parent_norm.status != .conflict and r.parent_norm.status != .invalid) continue;
        if (parent_review_count > 0) try report.appendSlice(a, ",\n");
        try report.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&report, a, r.source_path);
        try report.appendSlice(a, ", \"status\": ");
        try appendJson(&report, a, statusName(r.parent_norm.status));
        try report.appendSlice(a, ", \"reason\": ");
        if (r.parent_norm.reason) |reason| try appendJson(&report, a, reason) else try report.appendSlice(a, "null");
        try report.appendSlice(a, ", \"original_keys\": [");
        for (r.parent_norm.original_keys, 0..) |occ, oi| {
            if (oi > 0) try report.appendSlice(a, ", ");
            try report.appendSlice(a, "{ \"key\": ");
            try appendJson(&report, a, occ.key);
            try report.appendSlice(a, ", \"value\": ");
            try appendJson(&report, a, occ.value);
            try report.appendSlice(a, ", \"line\": ");
            try appendUsize(&report, a, occ.line);
            try report.appendSlice(a, " }");
        }
        try report.appendSlice(a, "] }");
        parent_review_count += 1;
    }
    try report.appendSlice(a, "\n  ],\n  \"stripped_embedded_blocks\": [\n");
    for (records.items) |r| for (r.stripped_blocks) |block| {
        if (stripped_count > 0) try report.appendSlice(a, ",\n");
        try report.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&report, a, r.source_path);
        try report.appendSlice(a, ", \"line\": ");
        try appendUsize(&report, a, block.line);
        try report.appendSlice(a, ", \"category\": ");
        try appendJson(&report, a, block.category);
        try report.appendSlice(a, ", \"stripped\": true }");
        stripped_count += 1;
    };
    try report.appendSlice(a, "\n  ]\n}\n");

    var md: std.ArrayList(u8) = .empty;
    try md.appendSlice(a,
        \\# Filed.fyi → Boris first-slice report
        \\
        \\Converted exactly one `changelog` record and three `releases` records. Source remains read-only.
        \\
        \\## Parent key normalization
        \\
        \\Filed-only rewrite of legacy structural parent keys (`parentEntry`, `parent_entry`) to canonical `parent`. Product Boris still rejects those aliases as unknown keys. Explicit values are preserved exactly when safe; conflicts and unsafe values are human-review and never auto-picked. Missing parent keys keep the first-slice collection Trunk as converter-owned structure (not invented by the normalizer from directory names).
        \\
        \\| Status | Count |
        \\|--------|------:|
        \\
    );
    try md.appendSlice(a, "| `missing` | ");
    try appendUsize(&md, a, parent_counts[@intFromEnum(ParentNormStatus.missing)]);
    try md.appendSlice(a, " |\n| `identity` | ");
    try appendUsize(&md, a, parent_counts[@intFromEnum(ParentNormStatus.identity)]);
    try md.appendSlice(a, " |\n| `normalized` | ");
    try appendUsize(&md, a, parent_counts[@intFromEnum(ParentNormStatus.normalized)]);
    try md.appendSlice(a, " |\n| `conflict` | ");
    try appendUsize(&md, a, parent_counts[@intFromEnum(ParentNormStatus.conflict)]);
    try md.appendSlice(a, " |\n| `invalid` | ");
    try appendUsize(&md, a, parent_counts[@intFromEnum(ParentNormStatus.invalid)]);
    try md.appendSlice(a, " |\n\n### Parent review\n\n");
    if (parent_review_count == 0) {
        try md.appendSlice(a, "None.\n");
    } else {
        for (records.items) |r| {
            if (r.parent_norm.status != .conflict and r.parent_norm.status != .invalid) continue;
            try md.appendSlice(a, "- `");
            try md.appendSlice(a, r.source_path);
            try md.appendSlice(a, "` — status `");
            try md.appendSlice(a, statusName(r.parent_norm.status));
            try md.appendSlice(a, "`");
            if (r.parent_norm.reason) |reason| {
                try md.appendSlice(a, ", reason `");
                try md.appendSlice(a, reason);
                try md.appendSlice(a, "`");
            }
            try md.appendSlice(a, "\n");
            for (r.parent_norm.original_keys) |occ| {
                try md.appendSlice(a, "  - line ");
                try appendUsize(&md, a, occ.line);
                try md.appendSlice(a, ": `");
                try md.appendSlice(a, occ.key);
                try md.appendSlice(a, ": ");
                try md.appendSlice(a, occ.value);
                try md.appendSlice(a, "`\n");
            }
        }
    }
    try md.appendSlice(a, "\n## Unmapped frontmatter\n\nOnly source `title` is mapped into generated Boris frontmatter. Legacy parent keys are normalized (above) rather than listed as unmapped. Every other source frontmatter key is retained raw in `provenance_manifest.json` and listed below; no source meaning is interpreted.\n\n");
    if (unmapped_count == 0) {
        try md.appendSlice(a, "None.\n");
    } else {
        for (records.items) |r| {
            if (r.unmapped_frontmatter_fields.len == 0) continue;
            try md.appendSlice(a, "- `");
            try md.appendSlice(a, r.source_path);
            try md.appendSlice(a, "` — ");
            for (r.unmapped_frontmatter_fields, 0..) |field, field_index| {
                if (field_index > 0) try md.appendSlice(a, ", ");
                try md.appendSlice(a, "`");
                try md.appendSlice(a, field);
                try md.appendSlice(a, "`");
            }
            try md.appendSlice(a, "\n");
        }
    }
    try md.appendSlice(a, "\n## Stripped embedded blocks\n\n");
    if (stripped_count == 0) {
        try md.appendSlice(a, "None.\n");
    } else {
        for (records.items) |r| for (r.stripped_blocks) |block| {
            try md.appendSlice(a, "- `");
            try md.appendSlice(a, r.source_path);
            try md.appendSlice(a, "` — line ");
            try appendUsize(&md, a, block.line);
            try md.appendSlice(a, ", category `");
            try md.appendSlice(a, block.category);
            try md.appendSlice(a, "`, stripped: true\n");
        };
    }

    try writeFile(io, out, "provenance_manifest.json", manifest.items);
    try writeFile(io, out, "report.json", report.items);
    try writeFile(io, out, "REPORT.md", md.items);
    if (!opts.quiet) std.debug.print("filed-migration-lab: wrote {s}/content/, provenance_manifest.json, report.json, REPORT.md\n", .{opts.out_dir});
}

// ---------------------------------------------------------------------------
// Unit tests — pure parent normalization
// ---------------------------------------------------------------------------

test "parent normalize: parentEntry only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "title: X\nparentEntry: releases\n", 2);
    try std.testing.expect(n.status == .normalized);
    try std.testing.expectEqualStrings("releases", n.emitted_parent.?);
    try std.testing.expectEqual(@as(usize, 1), n.original_keys.len);
    try std.testing.expectEqualStrings("parentEntry", n.original_keys[0].key);
    try std.testing.expectEqual(@as(usize, 3), n.original_keys[0].line);
}

test "parent normalize: parent_entry only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parent_entry: changelog\n", 2);
    try std.testing.expect(n.status == .normalized);
    try std.testing.expectEqualStrings("changelog", n.emitted_parent.?);
    try std.testing.expectEqualStrings("parent_entry", n.original_keys[0].key);
}

test "parent normalize: canonical parent only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parent: releases\n", 2);
    try std.testing.expect(n.status == .identity);
    try std.testing.expectEqualStrings("releases", n.emitted_parent.?);
}

test "parent normalize: both legacy and canonical same value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parent: releases\nparentEntry: releases\n", 2);
    try std.testing.expect(n.status == .normalized);
    try std.testing.expectEqualStrings("releases", n.emitted_parent.?);
    try std.testing.expectEqual(@as(usize, 2), n.original_keys.len);
}

test "parent normalize: parentEntry and parent_entry same value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parentEntry: guides\nparent_entry: guides\n", 2);
    try std.testing.expect(n.status == .normalized);
    try std.testing.expectEqualStrings("guides", n.emitted_parent.?);
}

test "parent normalize: conflicting parent values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parent: releases\nparentEntry: changelog\n", 2);
    try std.testing.expect(n.status == .conflict);
    try std.testing.expect(n.emitted_parent == null);
    try std.testing.expectEqualStrings("conflicting_parent_values", n.reason.?);
}

test "parent normalize: missing parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "title: Only Title\ncaseNumber: X\n", 2);
    try std.testing.expect(n.status == .missing);
    try std.testing.expect(n.emitted_parent == null);
    try std.testing.expectEqual(@as(usize, 0), n.original_keys.len);
}

test "parent normalize: empty value is invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parentEntry:\n", 2);
    try std.testing.expect(n.status == .invalid);
    try std.testing.expectEqualStrings("empty_parent_value", n.reason.?);
}

test "parent normalize: traversal value is invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parentEntry: ../outside\n", 2);
    try std.testing.expect(n.status == .invalid);
    try std.testing.expectEqualStrings("unsafe_parent_value", n.reason.?);
}

test "parent normalize: absolute and spaced values are invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n1 = try normalizeParentKeys(a, "parent: /abs/path\n", 2);
    try std.testing.expect(n1.status == .invalid);
    const n2 = try normalizeParentKeys(a, "parent_entry: has space\n", 2);
    try std.testing.expect(n2.status == .invalid);
}

test "parent normalize: block scalar marker is invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parentEntry: >\n", 2);
    try std.testing.expect(n.status == .invalid);
    try std.testing.expectEqualStrings("block_scalar_parent_value", n.reason.?);
}

test "parent normalize: quoted value preserved without quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeParentKeys(a, "parentEntry: \"releases\"\n", 2);
    try std.testing.expect(n.status == .normalized);
    try std.testing.expectEqualStrings("releases", n.emitted_parent.?);
}

test "isSafeParentId rejects hostile shapes" {
    try std.testing.expect(isSafeParentId("releases"));
    try std.testing.expect(isSafeParentId("guides/intro"));
    try std.testing.expect(!isSafeParentId(""));
    try std.testing.expect(!isSafeParentId("../x"));
    try std.testing.expect(!isSafeParentId("/abs"));
    try std.testing.expect(!isSafeParentId("a b"));
}

// ---------------------------------------------------------------------------
// Fixture tests
// ---------------------------------------------------------------------------

test "fixture: mini-filed deterministic, source immutable, missing parent uses collection" {
    const io = std.testing.io;
    const a = "fixtures/.test-filed-a";
    const b = "fixtures/.test-filed-b";
    Io.Dir.cwd().deleteTree(io, a) catch {};
    Io.Dir.cwd().deleteTree(io, b) catch {};
    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/mini-filed", .{});
    defer fixture.close(io);
    const before = try readFileAlloc(io, fixture, "src/content/docs/releases/v0.1.1-trust-surface-residue.md", std.testing.allocator);
    defer std.testing.allocator.free(before);
    try run(io, std.testing.allocator, .{ .source_root_dir = "fixtures/mini-filed", .out_dir = a, .quiet = true });
    try run(io, std.testing.allocator, .{ .source_root_dir = "fixtures/mini-filed", .out_dir = b, .quiet = true });
    var ao = try Io.Dir.cwd().openDir(io, a, .{});
    defer ao.close(io);
    var bo = try Io.Dir.cwd().openDir(io, b, .{});
    defer bo.close(io);
    const ma = try readFileAlloc(io, ao, "provenance_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(ma);
    const mb = try readFileAlloc(io, bo, "provenance_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(mb);
    try std.testing.expectEqualStrings(ma, mb);
    try std.testing.expect(std.mem.indexOf(u8, ma, "relatedEntries") != null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "\"status\": \"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ma, "parent_normalization") != null);
    const report = try readFileAlloc(io, ao, "report.json", std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "caseNumber") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "relatedEntries") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "directive_fence") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"stripped\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"schema_version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "parent_normalization") != null);
    const page = try readFileAlloc(io, ao, "content/releases/v0-1-1-trust-surface-residue.md", std.testing.allocator);
    defer std.testing.allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "parent: releases") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "parentEntry") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "fixture-payload") == null);
    const after = try readFileAlloc(io, fixture, "src/content/docs/releases/v0.1.1-trust-surface-residue.md", std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    Io.Dir.cwd().deleteTree(io, a) catch {};
    Io.Dir.cwd().deleteTree(io, b) catch {};
}

test "fixture: filed-parent-normalize matrix, immutability, determinism" {
    const io = std.testing.io;
    const out_a = "fixtures/.test-filed-parent-a";
    const out_b = "fixtures/.test-filed-parent-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/filed-parent-normalize", .{});
    defer fixture.close(io);
    const src_rel = "src/content/docs/releases/parent-entry-snake.md";
    const before = try readFileAlloc(io, fixture, src_rel, std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{ .source_root_dir = "fixtures/filed-parent-normalize", .out_dir = out_a, .quiet = true });
    try run(io, std.testing.allocator, .{ .source_root_dir = "fixtures/filed-parent-normalize", .out_dir = out_b, .quiet = true });

    var ao = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer ao.close(io);
    var bo = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer bo.close(io);

    // Byte-for-byte determinism across all primary artifacts.
    for ([_][]const u8{ "provenance_manifest.json", "report.json", "REPORT.md", "content/changelog/parent-entry-camel.md", "content/releases/parent-entry-snake.md", "content/releases/parent-canonical.md", "content/releases/parent-both-same.md" }) |path| {
        const xa = try readFileAlloc(io, ao, path, std.testing.allocator);
        defer std.testing.allocator.free(xa);
        const xb = try readFileAlloc(io, bo, path, std.testing.allocator);
        defer std.testing.allocator.free(xb);
        try std.testing.expectEqualStrings(xa, xb);
    }

    const prov = try readFileAlloc(io, ao, "provenance_manifest.json", std.testing.allocator);
    defer std.testing.allocator.free(prov);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"status\": \"normalized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"status\": \"identity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "parentEntry") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "parent_entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"emitted_parent\": \"changelog\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prov, "\"emitted_parent\": \"releases\"") != null);

    // parentEntry only → parent: changelog (closed FM must not re-emit legacy key)
    const camel = try readFileAlloc(io, ao, "content/changelog/parent-entry-camel.md", std.testing.allocator);
    defer std.testing.allocator.free(camel);
    try std.testing.expect(std.mem.indexOf(u8, camel, "parent: changelog") != null);
    try std.testing.expect(std.mem.indexOf(u8, camel, "parent_normalization: normalized") != null);
    try std.testing.expect(std.mem.indexOf(u8, camel, "\nparentEntry:") == null);

    // parent_entry only → parent: releases
    const snake = try readFileAlloc(io, ao, "content/releases/parent-entry-snake.md", std.testing.allocator);
    defer std.testing.allocator.free(snake);
    try std.testing.expect(std.mem.indexOf(u8, snake, "parent: releases") != null);
    try std.testing.expect(std.mem.indexOf(u8, snake, "\nparent_entry:") == null);

    // canonical parent only
    const canon = try readFileAlloc(io, ao, "content/releases/parent-canonical.md", std.testing.allocator);
    defer std.testing.allocator.free(canon);
    try std.testing.expect(std.mem.indexOf(u8, canon, "parent: releases") != null);
    try std.testing.expect(std.mem.indexOf(u8, canon, "parent_normalization: identity") != null);

    // both same value
    const both = try readFileAlloc(io, ao, "content/releases/parent-both-same.md", std.testing.allocator);
    defer std.testing.allocator.free(both);
    try std.testing.expect(std.mem.indexOf(u8, both, "parent: releases") != null);
    try std.testing.expect(std.mem.indexOf(u8, both, "\nparentEntry:") == null);
    try std.testing.expect(std.mem.indexOf(u8, both, "parent_normalization: normalized") != null);

    // Unknown keys remain review items (not silently dropped).
    const report = try readFileAlloc(io, ao, "report.json", std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "caseNumber") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"normalized\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"identity\": 1") != null);

    // Source immutability
    const after = try readFileAlloc(io, fixture, src_rel, std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
}

test "fixture: filed-parent-conflict-invalid review, no silent pick, source immutable" {
    const io = std.testing.io;
    const out = "fixtures/.test-filed-parent-conflict";
    Io.Dir.cwd().deleteTree(io, out) catch {};
    var fixture = try Io.Dir.cwd().openDir(io, "fixtures/filed-parent-conflict", .{});
    defer fixture.close(io);
    const src_rel = "src/content/docs/releases/parent-conflict.md";
    const before = try readFileAlloc(io, fixture, src_rel, std.testing.allocator);
    defer std.testing.allocator.free(before);

    try run(io, std.testing.allocator, .{ .source_root_dir = "fixtures/filed-parent-conflict", .out_dir = out, .quiet = true });

    var odir = try Io.Dir.cwd().openDir(io, out, .{});
    defer odir.close(io);
    const report = try readFileAlloc(io, odir, "report.json", std.testing.allocator);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"conflict\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"invalid\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "conflicting_parent_values") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "parent_review") != null);
    // Unknown keys still listed
    try std.testing.expect(std.mem.indexOf(u8, report, "caseNumber") != null);

    const conflict_page = try readFileAlloc(io, odir, "content/releases/parent-conflict.md", std.testing.allocator);
    defer std.testing.allocator.free(conflict_page);
    // Must not silently choose either conflicting value as parent.
    try std.testing.expect(std.mem.indexOf(u8, conflict_page, "parent: releases") == null);
    try std.testing.expect(std.mem.indexOf(u8, conflict_page, "parent: changelog") == null);
    try std.testing.expect(std.mem.indexOf(u8, conflict_page, "parent_normalization: conflict") != null);

    const bad_page = try readFileAlloc(io, odir, "content/releases/parent-unsafe.md", std.testing.allocator);
    defer std.testing.allocator.free(bad_page);
    try std.testing.expect(std.mem.indexOf(u8, bad_page, "parent: ../outside") == null);
    try std.testing.expect(std.mem.indexOf(u8, bad_page, "parent_normalization: invalid") != null);

    const after = try readFileAlloc(io, fixture, src_rel, std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    Io.Dir.cwd().deleteTree(io, out) catch {};
}

test "compile: representative normalized Filed output with product Boris when available" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    // Lab tests run with cwd = tools/migration-lab/. Product binary is at repo root.
    const lab_out = "fixtures/.test-filed-parent-compile";
    Io.Dir.cwd().deleteTree(io, lab_out) catch {};
    try run(io, gpa, .{ .source_root_dir = "fixtures/filed-parent-normalize", .out_dir = lab_out, .quiet = true });

    const boris_from_root = "zig-out/bin/boris";
    const layout_from_root = "layouts/main.html";
    // Paths relative to repository root (cwd for the product process).
    const content_from_root = "tools/migration-lab/fixtures/.test-filed-parent-compile/content";
    const html_from_root = "test-output/filed-parent-normalize-html";

    Io.Dir.cwd().access(io, "../../zig-out/bin/boris", .{}) catch {
        Io.Dir.cwd().deleteTree(io, lab_out) catch {};
        return; // product binary not built yet — skip compile smoke
    };
    Io.Dir.cwd().access(io, "../../layouts/main.html", .{}) catch {
        Io.Dir.cwd().deleteTree(io, lab_out) catch {};
        return;
    };

    Io.Dir.cwd().deleteTree(io, "../../test-output/filed-parent-normalize-html") catch {};
    try Io.Dir.cwd().createDirPath(io, "../../test-output");

    const argv = [_][]const u8{
        boris_from_root,
        "--input",
        content_from_root,
        "--html-dir",
        html_from_root,
        "--html-layout",
        layout_from_root,
        "--quiet",
    };
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = "../.." },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        Io.Dir.cwd().deleteTree(io, lab_out) catch {};
        return;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("boris compile failed code={d} stderr={s} stdout={s}\n", .{ code, result.stderr, result.stdout });
    }
    try std.testing.expectEqual(@as(u8, 0), code);

    Io.Dir.cwd().deleteTree(io, lab_out) catch {};
    Io.Dir.cwd().deleteTree(io, "../../test-output/filed-parent-normalize-html") catch {};
}
