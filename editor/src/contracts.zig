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
    html_build_report,
    manifest,
    graph,
    documentation_intelligence,
    publication_plan,
    proof_pack,
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

pub const Diagnostic = struct {
    severity: Severity,
    code: []const u8,
    message: []const u8,
    remediation: []const u8,
    source_path: ?[]const u8,
    line: ?u32,
    column: ?u32,
    id: ?[]const u8,
};

pub const EndpointType = enum { page, source };

pub const AnalysisFinding = struct {
    code: []const u8,
    endpoint_type: EndpointType,
    value: []const u8,
    count: u32,
    source_path: ?[]const u8,
    line: ?u32,
    column: ?u32,
};

pub const Endpoint = struct {
    endpoint_type: EndpointType,
    value: []const u8,
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
    const diagnostic_views = try extractDiagnostics(allocator, &document);
    allocator.free(diagnostic_views);
    return withVersion(document, version);
}

pub fn readHtmlBuildReport(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .html_build_report);
    errdefer document.deinit();
    try expectString(&document, "schemaVersion", "html-build-report-0.2.0");
    try requireString(&document, "compilerId");
    try requireBool(&document, "ok");
    try requireString(&document, "contentRoot");
    try requireString(&document, "outDir");
    try requireInteger(&document, "errorCount");
    try requireArray(&document, "diagnostics");
    const diagnostic_views = try extractDiagnostics(allocator, &document);
    allocator.free(diagnostic_views);
    return withVersion(document, "html-build-report-0.2.0");
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
    const diagnostic_views = try extractDiagnostics(allocator, &document);
    allocator.free(diagnostic_views);
    const finding_views = try extractFindings(allocator, &document);
    allocator.free(finding_views);
    const impact_views = try extractImpact(allocator, &document);
    allocator.free(impact_views);
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

pub const ProofSummaryView = struct {
    target: []const u8,
    overall_presentation_status: []const u8,
    artifacts_total: u32,
    checks_total: u32,
    findings_total: u32,
    claims_total: u32,
};

pub fn readProofPack(allocator: std.mem.Allocator, bytes: []const u8) Error!Document {
    var document = try parseObject(allocator, bytes, .proof_pack);
    errdefer document.deinit();
    try expectString(&document, "format", "boris-publication-proof-pack");
    try expectInteger(&document, "schema_version", 1);
    try requireString(&document, "target");
    try requireObject(&document, "summary");
    _ = try extractProofSummary(&document);
    return withVersion(document, "1");
}

pub fn extractProofSummary(document: *const Document) Error!ProofSummaryView {
    if (document.kind != .proof_pack) return error.InvalidField;
    const target = try objectString(rootObject(document), "target");
    const summary_value = rootObject(document).get("summary") orelse return error.MissingField;
    if (summary_value != .object) return error.InvalidField;
    const summary = &summary_value.object;
    const status = try objectString(summary, "overall_presentation_status");
    return .{
        .target = target,
        .overall_presentation_status = status,
        .artifacts_total = try nestedTotal(summary, "artifacts"),
        .checks_total = try nestedTotal(summary, "checks"),
        .findings_total = try nestedTotal(summary, "findings"),
        .claims_total = try nestedTotal(summary, "claims"),
    };
}

fn nestedTotal(object: *const std.json.ObjectMap, key: []const u8) Error!u32 {
    const value = object.get(key) orelse return error.MissingField;
    if (value != .object) return error.InvalidField;
    return objectU32(&value.object, "total");
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

pub fn extractDiagnostics(allocator: std.mem.Allocator, document: *const Document) Error![]Diagnostic {
    if (document.kind != .build_report and document.kind != .html_build_report and document.kind != .documentation_intelligence) return error.InvalidField;
    const value = rootObject(document).get("diagnostics") orelse return error.MissingField;
    if (value != .array) return error.InvalidField;
    const result = allocator.alloc(Diagnostic, value.array.items.len) catch return error.InvalidField;
    errdefer allocator.free(result);
    for (value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidDiagnostic;
        const object = &item.object;
        const severity_text = try objectString(object, "severity");
        const severity = std.meta.stringToEnum(Severity, severity_text) orelse return error.InvalidDiagnostic;
        const code = try objectString(object, "code");
        if (code.len == 0) return error.InvalidDiagnostic;
        result[index] = .{
            .severity = severity,
            .code = code,
            .message = try objectString(object, "message"),
            .remediation = try objectString(object, "remediation"),
            .source_path = try objectOptionalString(object, "sourcePath"),
            .line = try objectOptionalU32(object, "line"),
            .column = try objectOptionalU32(object, "column"),
            .id = try objectOptionalString(object, "id"),
        };
    }
    return result;
}

pub fn extractFindings(allocator: std.mem.Allocator, document: *const Document) Error![]AnalysisFinding {
    if (document.kind != .documentation_intelligence) return error.InvalidField;
    const value = rootObject(document).get("findings") orelse return error.MissingField;
    if (value != .array) return error.InvalidField;
    const result = allocator.alloc(AnalysisFinding, value.array.items.len) catch return error.InvalidField;
    errdefer allocator.free(result);
    for (value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidField;
        const object = &item.object;
        const endpoint_text = try objectString(object, "type");
        const endpoint_type = std.meta.stringToEnum(EndpointType, endpoint_text) orelse return error.InvalidField;
        result[index] = .{
            .code = try objectString(object, "code"),
            .endpoint_type = endpoint_type,
            .value = try objectString(object, "value"),
            .count = try objectU32(object, "count"),
            .source_path = try objectOptionalString(object, "sourcePath"),
            .line = try objectOptionalU32(object, "line"),
            .column = try objectOptionalU32(object, "column"),
        };
    }
    return result;
}

pub fn extractImpact(allocator: std.mem.Allocator, document: *const Document) Error![]Endpoint {
    if (document.kind != .documentation_intelligence) return error.InvalidField;
    const value = rootObject(document).get("impact") orelse return error.MissingField;
    if (value == .null) return allocator.alloc(Endpoint, 0) catch return error.InvalidField;
    if (value != .array) return error.InvalidField;
    const result = allocator.alloc(Endpoint, value.array.items.len) catch return error.InvalidField;
    errdefer allocator.free(result);
    for (value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidField;
        const object = &item.object;
        const endpoint_text = try objectString(object, "type");
        result[index] = .{
            .endpoint_type = std.meta.stringToEnum(EndpointType, endpoint_text) orelse return error.InvalidField,
            .value = try objectString(object, "value"),
        };
    }
    return result;
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
            if (source_len == 0 or line == 0 or column == 0 or !looksLikeSourcePath(locus[0..source_len])) return null;
            return .{
                .source_path = locus[0..source_len],
                .line = line,
                .column = column,
                .message = message,
            };
        }
    }
    if (!looksLikeSourcePath(locus)) return null;
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

fn objectString(object: *const std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    if (value != .string) return error.InvalidField;
    return value.string;
}

fn objectOptionalString(object: *const std.json.ObjectMap, key: []const u8) Error!?[]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidField,
    };
}

fn objectU32(object: *const std.json.ObjectMap, key: []const u8) Error!u32 {
    const value = object.get(key) orelse return error.MissingField;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.InvalidField;
    return @intCast(value.integer);
}

fn objectOptionalU32(object: *const std.json.ObjectMap, key: []const u8) Error!?u32 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .null => null,
        .integer => |number| if (number < 0 or number > std.math.maxInt(u32)) error.InvalidField else @intCast(number),
        else => error.InvalidField,
    };
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

/// The `ok` field of an html-build-report document: true when the build or
/// validation cycle completed without failures. The long-lived validation
/// daemon (#652) derives its per-cycle failure class from this field — the
/// daemon process itself stays alive across recoverable content failures, so
/// the report is the only per-cycle outcome signal.
pub fn htmlReportOk(document: *const Document) Error!bool {
    const value = rootObject(document).get("ok") orelse return error.MissingField;
    if (value != .bool) return error.InvalidField;
    return value.bool;
}

fn requireArray(document: *const Document, key: []const u8) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .array) return error.InvalidField;
}

fn requireInteger(document: *const Document, key: []const u8) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .integer) return error.InvalidField;
}

fn requireObject(document: *const Document, key: []const u8) Error!void {
    const value = rootObject(document).get(key) orelse return error.MissingField;
    if (value != .object) return error.InvalidField;
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
}

test "HTML-path report adapter accepts html-build-report-0.2.0" {
    const allocator = std.testing.allocator;
    var report = try readHtmlBuildReport(allocator,
        \\{"schemaVersion":"html-build-report-0.2.0","compilerId":"boris/0.8.1","ok":true,"contentRoot":"content","outDir":"dist","errorCount":0,"diagnostics":[]}
    );
    defer report.deinit();
    try std.testing.expectEqual(.html_build_report, report.kind);
    try std.testing.expectEqualStrings("html-build-report-0.2.0", report.version);
    // The optional proofPack section (#741) passes through untouched.
    var with_proof = try readHtmlBuildReport(allocator,
        \\{"schemaVersion":"html-build-report-0.2.0","compilerId":"boris/0.8.1","ok":true,"contentRoot":"content","outDir":"dist","errorCount":0,"diagnostics":[],"proofPack":{"path":"_boris/proof/checks.json","allPassed":false,"checks":[{"id":"rendered-search","status":"failed"}]}}
    );
    defer with_proof.deinit();
    const proof = with_proof.parsed.value.object.get("proofPack").?.object;
    try std.testing.expectEqual(false, proof.get("allPassed").?.bool);
    // The retired 0.1.0 version is no longer accepted.
    try std.testing.expectError(error.UnknownFormat, readHtmlBuildReport(allocator,
        \\{"schemaVersion":"html-build-report-0.1.0","compilerId":"boris/0.8.1","ok":true,"contentRoot":"content","outDir":"dist","errorCount":0,"diagnostics":[]}
    ));

    try std.testing.expectError(error.UnsupportedSchemaVersion, readGraph(allocator,
        \\{"schemaVersion":"9.0.0","frozen":true,"nodes":[],"edges":[],"reverseIndex":[],"nav":[]}
    ));
}

test "proof pack adapter accepts schema 1 and rejects unknown formats" {
    const allocator = std.testing.allocator;
    var good = try readProofPack(allocator,
        \\{"format":"boris-publication-proof-pack","schema_version":1,"target":"public","summary":{"artifacts":{"total":2},"checks":{"total":3},"findings":{"total":0},"claims":{"total":3},"overall_presentation_status":"verified"}}
    );
    defer good.deinit();
    try std.testing.expectEqual(.proof_pack, good.kind);
    const view = try extractProofSummary(&good);
    try std.testing.expectEqualStrings("verified", view.overall_presentation_status);
    try std.testing.expectEqual(@as(u32, 2), view.artifacts_total);

    try std.testing.expectError(error.UnknownFormat, readProofPack(allocator,
        \\{"format":"boris-publication-plan","schema_version":1,"target":"public","summary":{"artifacts":{"total":0},"checks":{"total":3},"findings":{"total":0},"claims":{"total":3},"overall_presentation_status":"verified"}}
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
