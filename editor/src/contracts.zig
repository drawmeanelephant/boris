//! Version negotiation for compiler-owned Boris artifacts.
//!
//! This module validates only the published discriminator/version boundary and
//! keeps the parsed JSON available to consumers. Boris and its JSON Schemas
//! remain authoritative for the document's meaning and full shape.

const std = @import("std");

pub const Error = error{
    InvalidJson,
    InvalidRoot,
    MissingField,
    InvalidField,
    UnknownFormat,
    UnsupportedSchemaVersion,
    InvalidDiagnostic,
};

pub const Kind = enum {
    completion,
    build_report,
    manifest,
    graph,
    documentation_intelligence,
    publication_plan,
    frontmatter_schema,
};

pub const Document = struct {
    kind: Kind,
    version: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Document) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const Severity = enum { @"error", warning, info };

pub const TextDiagnostic = struct {
    severity: Severity,
    code: []const u8,
    source_path: ?[]const u8,
    line: ?u32,
    column: ?u32,
    message: []const u8,
};

pub const supported_ir_versions = [_][]const u8{ "0.2.0", "0.3.0", "0.4.0" };

pub fn readCompletion(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .completion);
    errdefer document.deinit();
    try expectString(&document, "format", "boris-completion-index");
    try expectInteger(&document, "schema_version", 1);
    try requireString(&document, "compiler_id");
    try requireBool(&document, "frozen");
    try requireArray(&document, "entities");
    try requireArray(&document, "relation_kinds");
    try requireArray(&document, "parent_targets");
    try requireArray(&document, "layout_slots");
    return withVersion(document, "1");
}

pub fn readBuildReport(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .build_report);
    errdefer document.deinit();
    const version = try supportedIrVersion(&document);
    try requireBool(&document, "ok");
    try requireString(&document, "contentRoot");
    try requireString(&document, "outDir");
    try requireInteger(&document, "pageCount");
    try requireInteger(&document, "errorCount");
    try requireArray(&document, "diagnostics");
    return withVersion(document, version);
}

pub fn readManifest(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .manifest);
    errdefer document.deinit();
    const version = try supportedIrVersion(&document);
    try requireString(&document, "compiler");
    try requireString(&document, "contentRoot");
    try requireInteger(&document, "pageCount");
    try requireArray(&document, "pages");
    return withVersion(document, version);
}

pub fn readGraph(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .graph);
    errdefer document.deinit();
    const version = try supportedIrVersion(&document);
    try requireBool(&document, "frozen");
    try requireArray(&document, "nodes");
    try requireArray(&document, "edges");
    try requireArray(&document, "reverseIndex");
    try requireArray(&document, "nav");
    return withVersion(document, version);
}

pub fn readDocumentationIntelligence(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .documentation_intelligence);
    errdefer document.deinit();
    try expectString(&document, "format", "boris-documentation-intelligence");
    try expectString(&document, "schemaVersion", "0.2.0");
    try requireString(&document, "compiler");
    try requireArray(&document, "nodes");
    try requireArray(&document, "edges");
    try requireArray(&document, "findings");
    try requireArray(&document, "diagnostics");
    return withVersion(document, "0.2.0");
}

pub fn readPublicationPlan(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .publication_plan);
    errdefer document.deinit();
    try expectString(&document, "format", "boris-publication-plan");
    try expectInteger(&document, "schema_version", 1);
    try requireString(&document, "input");
    try requireString(&document, "input_format");
    try requireArray(&document, "targets");
    return withVersion(document, "1");
}

pub fn readFrontmatterSchema(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .frontmatter_schema);
    errdefer document.deinit();
    try expectString(&document, "$schema", "https://json-schema.org/draft/2020-12/schema");
    try expectString(&document, "title", "Boris frontmatter grammar (schema v1)");
    const additional = rootObject(&document).get("additionalProperties") orelse return error.MissingField;
    if (additional != .bool or additional.bool) return error.InvalidField;
    return withVersion(document, "1");
}

pub fn parseTextDiagnostic(line_bytes: []const u8) Error!TextDiagnostic {
    const input = std.mem.trimEnd(u8, line_bytes, "\r\n");
    const first = std.mem.indexOf(u8, input, ": ") orelse return error.InvalidDiagnostic;
    const severity = std.meta.stringToEnum(Severity, input[0..first]) orelse return error.InvalidDiagnostic;
    const after_severity = input[first + 2 ..];
    const second = std.mem.indexOf(u8, after_severity, ": ") orelse return error.InvalidDiagnostic;
    const code = after_severity[0..second];
    if (code.len < 2 or code[0] != 'E') return error.InvalidDiagnostic;
    const tail = after_severity[second + 2 ..];

    if (parseLocatedTail(tail)) |located| {
        return .{
            .severity = severity,
            .code = code,
            .source_path = located.source_path,
            .line = located.line,
            .column = located.column,
            .message = located.message,
        };
    }

    return .{
        .severity = severity,
        .code = code,
        .source_path = null,
        .line = null,
        .column = null,
        .message = tail,
    };
}

const LocatedTail = struct {
    source_path: []const u8,
    line: ?u32,
    column: ?u32,
    message: []const u8,
};

fn parseLocatedTail(tail: []const u8) ?LocatedTail {
    const message_separator = std.mem.indexOf(u8, tail, ": ") orelse return null;
    const locus = tail[0..message_separator];
    const message = tail[message_separator + 2 ..];
    if (!looksLikeSourcePath(locus)) return null;

    var pieces = std.mem.splitBackwardsScalar(u8, locus, ':');
    const last = pieces.first();
    const maybe_column = std.fmt.parseInt(u32, last, 10) catch null;
    if (maybe_column) |column| {
        const second_last = pieces.next() orelse return .{
            .source_path = locus,
            .line = null,
            .column = null,
            .message = message,
        };
        const maybe_line = std.fmt.parseInt(u32, second_last, 10) catch null;
        if (maybe_line) |line| {
            const source_len = locus.len - last.len - second_last.len - 2;
            if (source_len == 0 or line == 0 or column == 0) return null;
            return .{
                .source_path = locus[0..source_len],
                .line = line,
                .column = column,
                .message = message,
            };
        }
    }
    return .{
        .source_path = locus,
        .line = null,
        .column = null,
        .message = message,
    };
}

fn looksLikeSourcePath(value: []const u8) bool {
    return std.mem.endsWith(u8, value, ".md") or
        std.mem.endsWith(u8, value, ".mdx") or
        std.mem.endsWith(u8, value, ".textile") or
        std.mem.endsWith(u8, value, ".cook") or
        std.mem.indexOfScalar(u8, value, '/') != null;
}

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8, kind: Kind) Error!Document {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidJson;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRoot;
    return .{ .kind = kind, .version = "", .parsed = parsed };
}

fn withVersion(document: Document, version: []const u8) Document {
    var result = document;
    result.version = version;
    return result;
}

fn rootObject(document: *const Document) *const std.json.ObjectMap {
    return &document.parsed.value.object;
}

fn supportedIrVersion(document: *const Document) Error![]const u8 {
    const value = rootObject(document).get("schemaVersion") orelse return error.MissingField;
    if (value != .string) return error.InvalidField;
    for (supported_ir_versions) |supported| {
        if (std.mem.eql(u8, value.string, supported)) return supported;
    }
    return error.UnsupportedSchemaVersion;
}

fn requireString(document: *const Document, key: []const u8) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .string) return error.InvalidField;
}

fn requireBool(document: *const Document, key: []const u8) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .bool) return error.InvalidField;
}

fn requireArray(document: *const Document, key: []const u8) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .array) return error.InvalidField;
}

fn requireInteger(document: *const Document, key: []const u8) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .integer) return error.InvalidField;
}

fn expectString(document: *const Document, key: []const u8, expected: []const u8) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .string) return error.InvalidField;
    if (!std.mem.eql(u8, value.string, expected)) return error.UnknownFormat;
}

fn expectInteger(document: *const Document, key: []const u8, expected: i64) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .integer) return error.InvalidField;
    if (value.integer != expected) return error.UnsupportedSchemaVersion;
}

test "completion adapter accepts schema 1 and rejects unknown versions" {
    const allocator = std.testing.allocator;
    var good = try readCompletion(allocator,
        \\{"format":"boris-completion-index","schema_version":1,"compiler_id":"boris/0.8.1+cooklang","frozen":true,"entities":[],"relation_kinds":[],"parent_targets":[],"layout_slots":[]}
    );
    defer good.deinit();
    try std.testing.expectEqual(.completion, good.kind);
    try std.testing.expectEqualStrings("1", good.version);

    try std.testing.expectError(error.UnsupportedSchemaVersion, readCompletion(allocator,
        \\{"format":"boris-completion-index","schema_version":2,"compiler_id":"boris/9","frozen":true,"entities":[],"relation_kinds":[],"parent_targets":[],"layout_slots":[]}
    ));
}

test "IR adapters negotiate base and conditional facet versions" {
    const allocator = std.testing.allocator;
    var graph = try readGraph(allocator,
        \\{"schemaVersion":"0.4.0","frozen":true,"nodes":[],"edges":[],"reverseIndex":[],"nav":[]}
    );
    defer graph.deinit();
    try std.testing.expectEqualStrings("0.4.0", graph.version);

    try std.testing.expectError(error.UnsupportedSchemaVersion, readGraph(allocator,
        \\{"schemaVersion":"9.0.0","frozen":true,"nodes":[],"edges":[],"reverseIndex":[],"nav":[]}
    ));
}

test "stderr adapter preserves documented locations and plain messages" {
    const located = try parseTextDiagnostic("error: EFRONTMATTER: guides/bad.md:2:1: unknown key \"category\"\n");
    try std.testing.expectEqual(.@"error", located.severity);
    try std.testing.expectEqualStrings("EFRONTMATTER", located.code);
    try std.testing.expectEqualStrings("guides/bad.md", located.source_path.?);
    try std.testing.expectEqual(@as(u32, 2), located.line.?);
    try std.testing.expectEqual(@as(u32, 1), located.column.?);

    const plain = try parseTextDiagnostic("error: EIO: content root is missing");
    try std.testing.expect(plain.source_path == null);
    try std.testing.expectEqualStrings("content root is missing", plain.message);
}
