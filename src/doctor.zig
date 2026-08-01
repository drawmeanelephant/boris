//! Internal Boris Doctor v1 Slice 1 publication-snapshot analyzer.
//!
//! This module has no CLI and performs no publication writes. Callers supply
//! exact rendered bytes plus the intended output manifest; results are owned,
//! deterministic facts about that snapshot.

const std = @import("std");
const html_scan = @import("html_scan.zig");
const identity = @import("identity.zig");
const json_out = @import("json_out.zig");
const route_resolver = @import("route_resolver.zig");
const search_index = @import("search_index.zig");

pub const Code = enum {
    ARTIFACT_MISSING,
    ARTIFACT_SIZE_MISMATCH,
    ARTIFACT_DIGEST_MISMATCH,
    HTML_PAGE_MISSING,
    HTML_MALFORMED,
    HTML_URL_MALFORMED,
    HTML_LOCAL_ROUTE_MISSING,
    HTML_LOCAL_ROUTE_ESCAPE,
    HTML_FRAGMENT_MISSING,
    HTML_DUPLICATE_ID,
    SEARCH_MISSING,
    SEARCH_MALFORMED,
    SEARCH_DOCUMENT_MISSING,
    SEARCH_DOCUMENT_STALE,
    SEARCH_CONTENT_MISMATCH,
};

pub const Domain = enum { rendered_html, artifact };
pub const Severity = enum { @"error", warning, info };
pub const Confidence = enum { certain, high, limited };
pub const Owner = enum { content, theme, publication, configuration, unknown };
pub const Fixability = enum {
    source_edit,
    layout_edit,
    configuration_edit,
    regenerate,
    not_actionable,
};
pub const CoverageStatus = enum {
    checked,
    not_configured,
    not_in_scope,
    incomplete,
};

pub const Location = struct {
    path: []const u8,
    line: u32,
    column: u32,
};

pub const Subject = struct {
    kind: []const u8,
    id: []const u8,
    target: ?[]const u8,
};

pub const Evidence = struct {
    observed: []const u8,
    expected: []const u8,
    related: []const []const u8,
};

pub const Finding = struct {
    code: Code,
    domain: Domain,
    severity: Severity,
    confidence: Confidence,
    owner: Owner,
    subject: Subject,
    source_location: ?Location,
    output_location: ?Location,
    configuration_location: ?Location,
    evidence: Evidence,
    remediation: []const u8,
    fixability: Fixability,
};

pub const Coverage = struct {
    check: []const u8,
    domain: Domain,
    status: CoverageStatus,
    subjects: usize,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    findings: []Finding,
    coverage: []Coverage,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PageInput = struct {
    path: []const u8,
    html: []const u8,
};

pub const SearchInput = union(enum) {
    not_configured,
    selected_missing,
    selected: []const u8,
};

pub const TargetInput = struct {
    target_name: []const u8,
    /// HTML documents selected for structural inspection. Extra deployment
    /// pages may be present here without becoming Boris-owned.
    pages: []const PageInput,
    /// Canonical pages Boris is expected to own.
    expected_page_paths: []const []const u8,
    /// Complete intended page/asset manifest used for route membership.
    intended_route_paths: []const []const u8,
    /// Exact page set used to re-derive the rendered-search artifact.
    search_page_paths: []const []const u8 = &.{},
    search: SearchInput = .not_configured,
};

pub const TargetFilePlan = struct {
    target_name: []const u8,
    /// Explicit HTML paths selected for inspection. The caller, not Doctor,
    /// owns publication discovery policy.
    page_paths: []const []const u8,
    expected_page_paths: []const []const u8,
    intended_route_paths: []const []const u8,
    search_page_paths: []const []const u8 = &.{},
    search_selected: bool = false,
};

pub const Error = std.mem.Allocator.Error || error{
    UnsafeSnapshotPath,
    DuplicateSnapshotPath,
};

pub const FindingSpec = struct {
    code: Code,
    owner: Owner,
    subject_kind: []const u8,
    subject_id: []const u8,
    target: []const u8,
    output_location: ?Location = null,
    observed: []const u8,
    expected: []const u8,
    related: []const []const u8 = &.{},
    fixability: ?Fixability = null,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    findings: std.ArrayList(Finding) = .empty,

    fn append(self: *Builder, spec: FindingSpec) !void {
        const a = self.allocator;
        const related = try a.alloc([]const u8, spec.related.len);
        for (spec.related, 0..) |item, i| related[i] = try a.dupe(u8, item);
        std.mem.sort([]const u8, related, {}, lessString);
        var related_len: usize = 0;
        for (related) |item| {
            if (related_len == 0 or !std.mem.eql(u8, related[related_len - 1], item)) {
                related[related_len] = item;
                related_len += 1;
            }
        }

        try self.findings.append(a, .{
            .code = spec.code,
            .domain = domainFor(spec.code),
            .severity = severityFor(spec.code),
            .confidence = .certain,
            .owner = spec.owner,
            .subject = .{
                .kind = try a.dupe(u8, spec.subject_kind),
                .id = try a.dupe(u8, spec.subject_id),
                .target = try a.dupe(u8, spec.target),
            },
            .source_location = null,
            .output_location = if (spec.output_location) |output_loc| .{
                .path = try a.dupe(u8, output_loc.path),
                .line = output_loc.line,
                .column = output_loc.column,
            } else null,
            .configuration_location = null,
            .evidence = .{
                .observed = try a.dupe(u8, spec.observed),
                .expected = try a.dupe(u8, spec.expected),
                .related = related[0..related_len],
            },
            .remediation = try a.dupe(u8, remediationFor(spec.code)),
            .fixability = spec.fixability orelse fixabilityFor(spec.code, spec.owner),
        });
    }
};

/// Append one finding using the canonical Doctor finding construction rules.
/// Publication evidence uses this narrow seam for artifact-integrity findings
/// so it cannot grow a second finding vocabulary or field model.
pub fn appendFinding(
    findings: *std.ArrayList(Finding),
    allocator: std.mem.Allocator,
    spec: FindingSpec,
) !void {
    var builder: Builder = .{ .allocator = allocator };
    try builder.append(spec);
    defer builder.findings.deinit(allocator);
    try findings.append(allocator, builder.findings.items[0]);
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn domainFor(code: Code) Domain {
    return switch (code) {
        .ARTIFACT_MISSING,
        .ARTIFACT_SIZE_MISMATCH,
        .ARTIFACT_DIGEST_MISMATCH,
        .SEARCH_MISSING,
        .SEARCH_MALFORMED,
        .SEARCH_DOCUMENT_MISSING,
        .SEARCH_DOCUMENT_STALE,
        .SEARCH_CONTENT_MISMATCH,
        => .artifact,
        else => .rendered_html,
    };
}

fn severityFor(code: Code) Severity {
    return switch (code) {
        .HTML_DUPLICATE_ID => .warning,
        else => .@"error",
    };
}

fn fixabilityFor(code: Code, owner: Owner) Fixability {
    return switch (code) {
        .ARTIFACT_MISSING,
        .ARTIFACT_SIZE_MISMATCH,
        .ARTIFACT_DIGEST_MISMATCH,
        => .regenerate,
        .HTML_MALFORMED,
        .HTML_URL_MALFORMED,
        .HTML_LOCAL_ROUTE_MISSING,
        .HTML_LOCAL_ROUTE_ESCAPE,
        .HTML_FRAGMENT_MISSING,
        .HTML_DUPLICATE_ID,
        => switch (owner) {
            .content => .source_edit,
            .theme => .layout_edit,
            else => .not_actionable,
        },
        .HTML_PAGE_MISSING,
        .SEARCH_MISSING,
        .SEARCH_MALFORMED,
        .SEARCH_DOCUMENT_MISSING,
        .SEARCH_DOCUMENT_STALE,
        .SEARCH_CONTENT_MISMATCH,
        => .regenerate,
    };
}

fn remediationFor(code: Code) []const u8 {
    return switch (code) {
        .ARTIFACT_MISSING,
        .ARTIFACT_SIZE_MISMATCH,
        .ARTIFACT_DIGEST_MISMATCH,
        => "Regenerate the selected publication target.",
        .HTML_PAGE_MISSING => "Regenerate the selected publication target.",
        .HTML_MALFORMED => "Correct the rendered source or layout structure, then regenerate.",
        .HTML_URL_MALFORMED => "Replace the malformed rendered URL with a valid local reference.",
        .HTML_LOCAL_ROUTE_MISSING => "Point the rendered reference at an intended publication route.",
        .HTML_LOCAL_ROUTE_ESCAPE => "Keep the rendered reference within the publication root.",
        .HTML_FRAGMENT_MISSING => "Point the rendered reference at an id present on the target page.",
        .HTML_DUPLICATE_ID => "Give each rendered element a unique id; do not rely on an ambiguous fragment.",
        .SEARCH_MISSING => "Regenerate the selected rendered-search artifact.",
        .SEARCH_MALFORMED => "Regenerate a valid rendered-search v1 artifact.",
        .SEARCH_DOCUMENT_MISSING,
        .SEARCH_DOCUMENT_STALE,
        .SEARCH_CONTENT_MISMATCH,
        => "Regenerate rendered search from the exact selected HTML bytes.",
    };
}

fn safeSnapshotPath(gpa: std.mem.Allocator, path: []const u8) Error!void {
    const canonical = identity.canonicalize(gpa, path) catch return error.UnsafeSnapshotPath;
    defer gpa.free(canonical);
    if (!std.mem.eql(u8, path, canonical)) return error.UnsafeSnapshotPath;
}

fn pageId(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return path[0 .. path.len - 5];
    return path;
}

fn appendCodepoint(out: *std.ArrayList(u8), a: std.mem.Allocator, cp: u32) !void {
    if (cp <= 0x7f) return out.append(a, @intCast(cp));
    if (cp <= 0x7ff) {
        try out.append(a, @intCast(0xc0 | (cp >> 6)));
        return out.append(a, @intCast(0x80 | (cp & 0x3f)));
    }
    if (cp <= 0xffff) {
        try out.append(a, @intCast(0xe0 | (cp >> 12)));
        try out.append(a, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        return out.append(a, @intCast(0x80 | (cp & 0x3f)));
    }
    if (cp <= 0x10ffff) {
        try out.append(a, @intCast(0xf0 | (cp >> 18)));
        try out.append(a, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try out.append(a, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        return out.append(a, @intCast(0x80 | (cp & 0x3f)));
    }
}

fn appendEntity(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    entity: []const u8,
) !bool {
    const pairs = .{
        .{ "amp", '&' },
        .{ "lt", '<' },
        .{ "gt", '>' },
        .{ "quot", '"' },
        .{ "apos", '\'' },
        .{ "nbsp", ' ' },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, entity, pair[0])) {
            try out.append(a, pair[1]);
            return true;
        }
    }
    if (entity.len > 1 and entity[0] == '#') {
        var base: u8 = 10;
        var digits = entity[1..];
        if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X')) {
            base = 16;
            digits = digits[1..];
        }
        const cp = std.fmt.parseInt(u32, digits, base) catch return false;
        try appendCodepoint(out, a, cp);
        return true;
    }
    return false;
}

fn decodeEntities(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ';')) |semi| {
                if (try appendEntity(&out, a, text[i + 1 .. semi])) {
                    i = semi + 1;
                    continue;
                }
            }
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

const IdOccurrence = struct {
    value: []const u8,
    offset: usize,
    owner: Owner,
};

const Reference = struct {
    target: []const u8,
    attribute: []const u8,
    offset: usize,
    owner: Owner,
};

const PageState = struct {
    page: PageInput,
    valid: bool = true,
    intended: bool = false,
    root: ?html_scan.Range = null,
    ids: std.ArrayList(IdOccurrence) = .empty,
    references: std.ArrayList(Reference) = .empty,
};

fn uniqueSearchRoot(html: []const u8) ?html_scan.Range {
    var count: usize = 0;
    var root: ?html_scan.Range = null;
    var i: usize = 0;
    while (i < html.len) {
        const start = std.mem.indexOfScalarPos(u8, html, i, '<') orelse break;
        const tag = html_scan.tagAt(html, start) orelse {
            i = start + 1;
            continue;
        };
        if (!tag.closing and !tag.self_closing and
            std.ascii.eqlIgnoreCase(tag.name, "main") and
            html_scan.hasAttr(html[start .. tag.end + 1], "data-boris-search-root"))
        {
            count += 1;
            root = html_scan.matchingRange(html, start, tag.name);
        }
        if (!tag.closing and !tag.self_closing and html_scan.isRawTextElement(tag.name)) {
            i = html_scan.rawTextEnd(html, tag.end + 1, tag.name) orelse html.len;
        } else {
            i = tag.end + 1;
        }
    }
    if (count != 1) return null;
    return root;
}

fn ownerAt(root: ?html_scan.Range, offset: usize) Owner {
    const range = root orelse return .unknown;
    if (offset >= range.start and offset < range.end) return .content;
    return .theme;
}

fn scanPage(a: std.mem.Allocator, state: *PageState) !void {
    const html = state.page.html;
    state.root = uniqueSearchRoot(html);
    var i: usize = 0;
    while (i < html.len) {
        const start = std.mem.indexOfScalarPos(u8, html, i, '<') orelse break;
        const tag = html_scan.tagAt(html, start) orelse {
            i = start + 1;
            continue;
        };
        if (std.mem.eql(u8, tag.name, "!comment")) {
            i = tag.end + 1;
            continue;
        }
        if (!tag.closing and !tag.self_closing and html_scan.isRawTextElement(tag.name)) {
            i = html_scan.rawTextEnd(html, tag.end + 1, tag.name) orelse html.len;
            continue;
        }
        if (tag.closing) {
            i = tag.end + 1;
            continue;
        }

        const tag_bytes = html[start .. tag.end + 1];
        var attributes = html_scan.AttrIter.init(tag_bytes);
        while (attributes.next()) |attribute| {
            const value = attribute.value orelse continue;
            if (std.ascii.eqlIgnoreCase(attribute.name, "id")) {
                const decoded = try decodeEntities(a, value);
                if (decoded.len != 0) {
                    try state.ids.append(a, .{
                        .value = decoded,
                        .offset = start,
                        .owner = ownerAt(state.root, start),
                    });
                }
            } else if (std.ascii.eqlIgnoreCase(attribute.name, "href") or
                std.ascii.eqlIgnoreCase(attribute.name, "src"))
            {
                try state.references.append(a, .{
                    .target = try a.dupe(u8, value),
                    .attribute = try a.dupe(u8, attribute.name),
                    .offset = start,
                    .owner = ownerAt(state.root, start),
                });
            }
        }
        i = tag.end + 1;
    }
}

fn pageInputLess(_: void, left: PageInput, right: PageInput) bool {
    return lessString({}, left.path, right.path);
}

fn idOccurrenceLess(_: void, left: IdOccurrence, right: IdOccurrence) bool {
    const order = std.mem.order(u8, left.value, right.value);
    if (order != .eq) return order == .lt;
    return left.offset < right.offset;
}

fn location(path: []const u8, html: []const u8, offset: usize) Location {
    const point = html_scan.lineColumn(html, offset);
    return .{ .path = path, .line = point.line, .column = point.column };
}

fn duplicateIdFindings(builder: *Builder, state: *PageState, target_name: []const u8) !void {
    std.mem.sort(IdOccurrence, state.ids.items, {}, idOccurrenceLess);
    var i: usize = 0;
    while (i < state.ids.items.len) {
        var end = i + 1;
        while (end < state.ids.items.len and
            std.mem.eql(u8, state.ids.items[i].value, state.ids.items[end].value))
        {
            end += 1;
        }
        if (end - i > 1) {
            const first = state.ids.items[i];
            var owner = first.owner;
            var related: std.ArrayList([]const u8) = .empty;
            for (state.ids.items[i..end]) |occurrence| {
                if (occurrence.owner != owner) owner = .unknown;
                const point = html_scan.lineColumn(state.page.html, occurrence.offset);
                try related.append(
                    builder.allocator,
                    try std.fmt.allocPrint(
                        builder.allocator,
                        "{s}:{d}:{d}",
                        .{ state.page.path, point.line, point.column },
                    ),
                );
            }
            const observed = try std.fmt.allocPrint(
                builder.allocator,
                "id=\"{s}\" occurs {d} times",
                .{ first.value, end - i },
            );
            try builder.append(.{
                .code = .HTML_DUPLICATE_ID,
                .owner = owner,
                .subject_kind = "page",
                .subject_id = pageId(state.page.path),
                .target = target_name,
                .output_location = location(state.page.path, state.page.html, first.offset),
                .observed = observed,
                .expected = "one rendered element for each non-empty id",
                .related = related.items,
                .fixability = if (owner == .unknown) .not_actionable else null,
            });
        }
        i = end;
    }
}

fn stateForPath(
    states: []PageState,
    index: *const std.StringHashMapUnmanaged(usize),
    path: []const u8,
) ?*PageState {
    const state_index = index.get(path) orelse return null;
    return &states[state_index];
}

fn isLiteralMarkdownTarget(target: []const u8) bool {
    const path = route_resolver.stripQuery(route_resolver.stripFragment(target));
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx");
}

fn appendUrlFinding(
    builder: *Builder,
    state: *const PageState,
    target_name: []const u8,
    reference: Reference,
    code: Code,
    expected: []const u8,
) !void {
    const observed = try std.fmt.allocPrint(
        builder.allocator,
        "{s}=\"{s}\"",
        .{ reference.attribute, reference.target },
    );
    try builder.append(.{
        .code = code,
        .owner = reference.owner,
        .subject_kind = "page",
        .subject_id = pageId(state.page.path),
        .target = target_name,
        .output_location = location(state.page.path, state.page.html, reference.offset),
        .observed = observed,
        .expected = expected,
    });
}

fn auditReferences(
    builder: *Builder,
    states: []PageState,
    page_index: *const std.StringHashMapUnmanaged(usize),
    intended: *const std.StringHashMapUnmanaged(void),
    state: *const PageState,
    target_name: []const u8,
) !void {
    // Deployment-owned extra pages are inspected structurally, but without an
    // ownership manifest Doctor cannot judge their route graph.
    if (!state.intended) return;

    for (state.references.items) |reference| {
        const decoded_target = try decodeEntities(builder.allocator, reference.target);
        if (route_resolver.isExternalOrEmpty(decoded_target)) continue;
        if (isLiteralMarkdownTarget(decoded_target)) continue;
        route_resolver.validatePercentEscapes(decoded_target) catch {
            try appendUrlFinding(
                builder,
                state,
                target_name,
                reference,
                .HTML_URL_MALFORMED,
                "valid percent escapes in the rendered URL",
            );
            continue;
        };

        const resolution = route_resolver.resolveWithinRootChecked(
            builder.allocator,
            state.page.path,
            decoded_target,
        ) catch |err| switch (err) {
            error.MalformedPercentEscape => {
                try appendUrlFinding(
                    builder,
                    state,
                    target_name,
                    reference,
                    .HTML_URL_MALFORMED,
                    "valid percent escapes in the rendered URL",
                );
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        switch (resolution) {
            .escapes_root => {
                try appendUrlFinding(
                    builder,
                    state,
                    target_name,
                    reference,
                    .HTML_LOCAL_ROUTE_ESCAPE,
                    "a rendered route contained by the publication root",
                );
                continue;
            },
            .path => |resolved| {
                if (!intended.contains(resolved)) {
                    try appendUrlFinding(
                        builder,
                        state,
                        target_name,
                        reference,
                        .HTML_LOCAL_ROUTE_MISSING,
                        "a route in the intended publication manifest",
                    );
                    continue;
                }

                const raw_fragment = route_resolver.fragment(decoded_target) orelse continue;
                if (raw_fragment.len == 0 or !std.mem.endsWith(u8, resolved, ".html")) continue;
                const decoded_fragment = route_resolver.decodeFragment(
                    builder.allocator,
                    raw_fragment,
                ) catch |err| switch (err) {
                    error.MalformedPercentEscape => {
                        try appendUrlFinding(
                            builder,
                            state,
                            target_name,
                            reference,
                            .HTML_URL_MALFORMED,
                            "valid percent escapes in the rendered fragment",
                        );
                        continue;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                const target_state = stateForPath(states, page_index, resolved) orelse continue;
                if (!target_state.valid) continue;
                var found = false;
                for (target_state.ids.items) |occurrence| {
                    if (std.mem.eql(u8, occurrence.value, decoded_fragment)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try appendUrlFinding(
                        builder,
                        state,
                        target_name,
                        reference,
                        .HTML_FRAGMENT_MISSING,
                        "a fragment matching a rendered id on the target page",
                    );
                }
            },
        }
    }
}

fn findingLess(_: void, left: Finding, right: Finding) bool {
    const severity_order = std.math.order(
        @intFromEnum(left.severity),
        @intFromEnum(right.severity),
    );
    if (severity_order != .eq) return severity_order == .lt;
    const domain_order = std.math.order(@intFromEnum(left.domain), @intFromEnum(right.domain));
    if (domain_order != .eq) return domain_order == .lt;

    if (left.subject.target == null and right.subject.target != null) return false;
    if (left.subject.target != null and right.subject.target == null) return true;
    if (left.subject.target) |left_target| {
        const target_order = std.mem.order(u8, left_target, right.subject.target.?);
        if (target_order != .eq) return target_order == .lt;
    }
    const kind_order = std.mem.order(u8, left.subject.kind, right.subject.kind);
    if (kind_order != .eq) return kind_order == .lt;
    const id_order = std.mem.order(u8, left.subject.id, right.subject.id);
    if (id_order != .eq) return id_order == .lt;

    const left_output = left.output_location orelse Location{ .path = "", .line = 0, .column = 0 };
    const right_output = right.output_location orelse Location{ .path = "", .line = 0, .column = 0 };
    const path_order = std.mem.order(u8, left_output.path, right_output.path);
    if (path_order != .eq) return path_order == .lt;
    if (left_output.line != right_output.line) return left_output.line < right_output.line;
    if (left_output.column != right_output.column) return left_output.column < right_output.column;
    const code_order = std.mem.order(u8, @tagName(left.code), @tagName(right.code));
    if (code_order != .eq) return code_order == .lt;
    return std.mem.order(u8, left.evidence.observed, right.evidence.observed) == .lt;
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn valueArray(value: std.json.Value) ?[]std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => null,
    };
}

fn valueString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn valueInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn validSearchSection(value: std.json.Value) bool {
    const object = valueObject(value) orelse return false;
    const level = valueInteger(object.get("level") orelse return false) orelse return false;
    if (level < 0 or level > 6) return false;
    inline for (.{ "heading", "fragment", "text", "code" }) |field| {
        if (valueString(object.get(field) orelse return false) == null) return false;
    }
    return true;
}

fn validSearchDocument(value: std.json.Value) bool {
    const object = valueObject(value) orelse return false;
    const path = valueString(object.get("path") orelse return false) orelse return false;
    if (!std.mem.endsWith(u8, path, ".html")) return false;
    if (valueString(object.get("title") orelse return false) == null) return false;
    const sections = valueArray(object.get("sections") orelse return false) orelse return false;
    for (sections) |section| if (!validSearchSection(section)) return false;
    return true;
}

fn searchDocumentMatches(value: std.json.Value, expected: search_index.Document) bool {
    const object = valueObject(value) orelse return false;
    const path = valueString(object.get("path").?) orelse return false;
    const title = valueString(object.get("title").?) orelse return false;
    if (!std.mem.eql(u8, path, expected.path) or !std.mem.eql(u8, title, expected.title)) {
        return false;
    }
    const sections = valueArray(object.get("sections").?) orelse return false;
    if (sections.len != expected.sections.len) return false;
    for (sections, expected.sections) |actual_value, wanted| {
        const actual = valueObject(actual_value) orelse return false;
        const level = valueInteger(actual.get("level").?) orelse return false;
        if (level != wanted.level) return false;
        inline for (.{ "heading", "fragment", "text", "code" }) |field| {
            const actual_text = valueString(actual.get(field).?) orelse return false;
            const wanted_text = @field(wanted, field);
            if (!std.mem.eql(u8, actual_text, wanted_text)) return false;
        }
    }
    return true;
}

fn appendSearchFinding(
    builder: *Builder,
    target_name: []const u8,
    code: Code,
    subject_id: []const u8,
    observed: []const u8,
    expected: []const u8,
) !void {
    try builder.append(.{
        .code = code,
        .owner = .publication,
        .subject_kind = "artifact",
        .subject_id = subject_id,
        .target = target_name,
        .output_location = .{ .path = search_index.output_path, .line = 1, .column = 1 },
        .observed = observed,
        .expected = expected,
    });
}

fn searchMalformed(
    builder: *Builder,
    target_name: []const u8,
    observed: []const u8,
) !void {
    try appendSearchFinding(
        builder,
        target_name,
        .SEARCH_MALFORMED,
        search_index.output_path,
        observed,
        "a valid boris-rendered-search-index schema version 1 artifact",
    );
}

fn auditSearch(
    builder: *Builder,
    input: TargetInput,
    states: []PageState,
    page_index: *const std.StringHashMapUnmanaged(usize),
) !CoverageStatus {
    const bytes = switch (input.search) {
        .not_configured => return .not_configured,
        .selected_missing => {
            try appendSearchFinding(
                builder,
                input.target_name,
                .SEARCH_MISSING,
                search_index.output_path,
                "selected rendered-search artifact is missing",
                search_index.output_path,
            );
            return .incomplete;
        },
        .selected => |selected| selected,
    };

    var parsed = std.json.parseFromSlice(std.json.Value, builder.allocator, bytes, .{}) catch {
        try searchMalformed(builder, input.target_name, "rendered-search bytes are not valid JSON");
        return .incomplete;
    };
    defer parsed.deinit();
    const root = valueObject(parsed.value) orelse {
        try searchMalformed(builder, input.target_name, "rendered-search root is not an object");
        return .incomplete;
    };
    const actual_format = valueString(root.get("format") orelse {
        try searchMalformed(builder, input.target_name, "rendered-search format is missing");
        return .incomplete;
    }) orelse {
        try searchMalformed(builder, input.target_name, "rendered-search format has the wrong type");
        return .incomplete;
    };
    const actual_version = valueInteger(root.get("schema_version") orelse {
        try searchMalformed(builder, input.target_name, "rendered-search schema_version is missing");
        return .incomplete;
    }) orelse {
        try searchMalformed(builder, input.target_name, "rendered-search schema_version has the wrong type");
        return .incomplete;
    };
    if (!std.mem.eql(u8, actual_format, search_index.format) or
        actual_version != search_index.schema_version)
    {
        try searchMalformed(builder, input.target_name, "rendered-search format or schema version is incompatible");
        return .incomplete;
    }
    const actual_documents = valueArray(root.get("documents") orelse {
        try searchMalformed(builder, input.target_name, "rendered-search documents are missing");
        return .incomplete;
    }) orelse {
        try searchMalformed(builder, input.target_name, "rendered-search documents have the wrong type");
        return .incomplete;
    };

    var actual_index: std.StringHashMapUnmanaged(usize) = .{};
    for (actual_documents, 0..) |document, i| {
        if (!validSearchDocument(document)) {
            try searchMalformed(builder, input.target_name, "rendered-search document shape is invalid");
            return .incomplete;
        }
        const path = valueString(valueObject(document).?.get("path").?).?;
        safeSnapshotPath(builder.allocator, path) catch {
            try searchMalformed(builder, input.target_name, "rendered-search document path is unsafe");
            return .incomplete;
        };
        const result = try actual_index.getOrPut(builder.allocator, path);
        if (result.found_existing) {
            try searchMalformed(builder, input.target_name, "rendered-search document path is duplicated");
            return .incomplete;
        }
        result.value_ptr.* = i;
    }

    const expected_paths = try builder.allocator.alloc([]const u8, input.search_page_paths.len);
    @memcpy(expected_paths, input.search_page_paths);
    std.mem.sort([]const u8, expected_paths, {}, lessString);

    var status: CoverageStatus = .checked;
    var expected_set: std.StringHashMapUnmanaged(void) = .{};
    for (expected_paths) |path| {
        safeSnapshotPath(builder.allocator, path) catch return error.UnsafeSnapshotPath;
        const put = try expected_set.getOrPut(builder.allocator, path);
        if (put.found_existing) return error.DuplicateSnapshotPath;
        put.value_ptr.* = {};

        const state = stateForPath(states, page_index, path) orelse {
            try appendSearchFinding(
                builder,
                input.target_name,
                .SEARCH_DOCUMENT_MISSING,
                path,
                "expected rendered page is unavailable for search comparison",
                path,
            );
            status = .incomplete;
            continue;
        };
        if (!state.valid) {
            status = .incomplete;
            continue;
        }
        const actual_i = actual_index.get(path) orelse {
            try appendSearchFinding(
                builder,
                input.target_name,
                .SEARCH_DOCUMENT_MISSING,
                path,
                "rendered-search document is absent",
                path,
            );
            continue;
        };
        const expected = search_index.indexHtml(
            builder.allocator,
            path,
            state.page.html,
            false,
        ) catch {
            try appendSearchFinding(
                builder,
                input.target_name,
                .SEARCH_CONTENT_MISMATCH,
                path,
                "selected HTML cannot be re-indexed completely",
                "search content derived from exact final HTML bytes",
            );
            status = .incomplete;
            continue;
        };
        if (!searchDocumentMatches(actual_documents[actual_i], expected)) {
            try appendSearchFinding(
                builder,
                input.target_name,
                .SEARCH_CONTENT_MISMATCH,
                path,
                "stored search document differs from an exact in-memory re-index",
                "search content derived from exact final HTML bytes",
            );
        }

        const actual_object = valueObject(actual_documents[actual_i]).?;
        const sections = valueArray(actual_object.get("sections").?).?;
        for (sections) |section_value| {
            const section = valueObject(section_value).?;
            const fragment_value = valueString(section.get("fragment").?).?;
            if (fragment_value.len == 0) continue;
            var found = false;
            for (state.ids.items) |occurrence| {
                if (std.mem.eql(u8, occurrence.value, fragment_value)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const observed = try std.fmt.allocPrint(
                    builder.allocator,
                    "stored fragment \"{s}\" does not resolve on {s}",
                    .{ fragment_value, path },
                );
                try appendSearchFinding(
                    builder,
                    input.target_name,
                    .SEARCH_CONTENT_MISMATCH,
                    path,
                    observed,
                    "every non-empty stored fragment matches a rendered id",
                );
            }
        }
    }

    if (actual_documents.len == expected_paths.len) {
        var same_set = true;
        for (actual_documents) |document| {
            const path = valueString(valueObject(document).?.get("path").?).?;
            if (!expected_set.contains(path)) {
                same_set = false;
                break;
            }
        }
        if (same_set) {
            for (actual_documents, expected_paths) |document, expected_path| {
                const actual_path = valueString(valueObject(document).?.get("path").?).?;
                if (!std.mem.eql(u8, actual_path, expected_path)) {
                    try appendSearchFinding(
                        builder,
                        input.target_name,
                        .SEARCH_CONTENT_MISMATCH,
                        search_index.output_path,
                        "rendered-search document order is not canonical",
                        "documents sorted by bytewise canonical path",
                    );
                    break;
                }
            }
        }
    }

    for (actual_documents) |document| {
        const path = valueString(valueObject(document).?.get("path").?).?;
        if (!expected_set.contains(path)) {
            try appendSearchFinding(
                builder,
                input.target_name,
                .SEARCH_DOCUMENT_STALE,
                path,
                "rendered-search contains a document outside the selected page set",
                "only selected rendered pages",
            );
        }
    }
    return status;
}

pub fn analyzeTarget(gpa: std.mem.Allocator, input: TargetInput) Error!Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var builder: Builder = .{ .allocator = a };

    const sorted_pages = try a.alloc(PageInput, input.pages.len);
    @memcpy(sorted_pages, input.pages);
    std.mem.sort(PageInput, sorted_pages, {}, pageInputLess);

    var states = try a.alloc(PageState, sorted_pages.len);
    var page_index: std.StringHashMapUnmanaged(usize) = .{};
    for (sorted_pages, 0..) |page, i| {
        try safeSnapshotPath(a, page.path);
        if (!std.mem.endsWith(u8, page.path, ".html")) return error.UnsafeSnapshotPath;
        const result = try page_index.getOrPut(a, page.path);
        if (result.found_existing) return error.DuplicateSnapshotPath;
        result.value_ptr.* = i;
        states[i] = .{ .page = page };
    }

    var intended: std.StringHashMapUnmanaged(void) = .{};
    for (input.intended_route_paths) |path| {
        try safeSnapshotPath(a, path);
        try intended.put(a, path, {});
    }
    for (input.expected_page_paths) |path| {
        try safeSnapshotPath(a, path);
        try intended.put(a, path, {});
    }
    for (states) |*state| state.intended = intended.contains(state.page.path);

    var html_status: CoverageStatus = .checked;
    var missing_expected_pages: usize = 0;
    for (input.expected_page_paths) |path| {
        if (!page_index.contains(path)) {
            missing_expected_pages += 1;
            try builder.append(.{
                .code = .HTML_PAGE_MISSING,
                .owner = .publication,
                .subject_kind = "page",
                .subject_id = pageId(path),
                .target = input.target_name,
                .observed = "expected rendered page is missing",
                .expected = path,
            });
            html_status = .incomplete;
        }
    }

    for (states) |*state| {
        if (html_scan.validate(state.page.html)) |malformed| {
            state.valid = false;
            const observed = try std.fmt.allocPrint(
                a,
                "{s} at byte offset {d}",
                .{ @tagName(malformed.kind), malformed.offset },
            );
            try builder.append(.{
                .code = .HTML_MALFORMED,
                .owner = .unknown,
                .subject_kind = "page",
                .subject_id = pageId(state.page.path),
                .target = input.target_name,
                .output_location = location(state.page.path, state.page.html, malformed.offset),
                .observed = observed,
                .expected = "bounded rendered HTML structures",
                .fixability = .not_actionable,
            });
            html_status = .incomplete;
            continue;
        }
        try scanPage(a, state);
        try duplicateIdFindings(&builder, state, input.target_name);
    }
    for (states) |*state| {
        if (!state.valid) continue;
        try auditReferences(&builder, states, &page_index, &intended, state, input.target_name);
    }

    const search_status = try auditSearch(&builder, input, states, &page_index);
    std.mem.sort(Finding, builder.findings.items, {}, findingLess);

    const coverage = try a.alloc(Coverage, 2);
    coverage[0] = .{
        .check = try a.dupe(u8, "rendered_html"),
        .domain = .rendered_html,
        .status = html_status,
        .subjects = states.len + missing_expected_pages,
    };
    coverage[1] = .{
        .check = try a.dupe(u8, "artifact.search"),
        .domain = .artifact,
        .status = search_status,
        .subjects = input.search_page_paths.len,
    };

    return .{
        .arena = arena,
        .findings = try builder.findings.toOwnedSlice(a),
        .coverage = coverage,
    };
}

fn readFileNoFollow(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    try safeSnapshotPath(gpa, path);
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');
    var current_dir = root;
    var owned_dir: ?std.Io.Dir = null;
    defer if (owned_dir) |dir| dir.close(io);

    if (last_slash) |last| {
        var segments = std.mem.splitScalar(u8, path[0..last], '/');
        while (segments.next()) |segment| {
            const stat = try current_dir.statFile(io, segment, .{ .follow_symlinks = false });
            if (stat.kind == .sym_link) return error.UnsafeSnapshotPath;
            const next_dir = try current_dir.openDir(io, segment, .{ .follow_symlinks = false });
            if (owned_dir) |dir| dir.close(io);
            owned_dir = next_dir;
            current_dir = next_dir;
        }
    }

    const basename = if (last_slash) |last| path[last + 1 ..] else path;
    const stat = try current_dir.statFile(io, basename, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link or stat.kind != .file) return error.UnsafeSnapshotPath;
    var file = try current_dir.openFile(io, basename, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(64 * 1024 * 1024));
}

/// Read an explicitly selected target snapshot through no-follow handles and
/// analyze it without writing the target or any source tree.
pub fn inspectTarget(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    plan: TargetFilePlan,
) !Report {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    var pages: std.ArrayList(PageInput) = .empty;
    for (plan.page_paths) |path| {
        try safeSnapshotPath(a, path);
        const bytes = readFileNoFollow(io, root, a, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try pages.append(a, .{ .path = try a.dupe(u8, path), .html = bytes });
    }

    var search: SearchInput = .not_configured;
    if (plan.search_selected) {
        const bytes = readFileNoFollow(io, root, a, search_index.output_path) catch |err| switch (err) {
            error.FileNotFound => {
                search = .selected_missing;
                return analyzeTarget(gpa, .{
                    .target_name = plan.target_name,
                    .pages = pages.items,
                    .expected_page_paths = plan.expected_page_paths,
                    .intended_route_paths = plan.intended_route_paths,
                    .search_page_paths = plan.search_page_paths,
                    .search = search,
                });
            },
            else => return err,
        };
        search = .{ .selected = bytes };
    }

    return analyzeTarget(gpa, .{
        .target_name = plan.target_name,
        .pages = pages.items,
        .expected_page_paths = plan.expected_page_paths,
        .intended_route_paths = plan.intended_route_paths,
        .search_page_paths = plan.search_page_paths,
        .search = search,
    });
}

fn appendJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    try json_out.writeString(out, a, value);
}

fn appendUnsigned(out: *std.ArrayList(u8), a: std.mem.Allocator, value: usize) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try out.appendSlice(a, text);
}

fn appendLocation(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    value: ?Location,
) !void {
    const point = value orelse {
        try out.appendSlice(a, "null");
        return;
    };
    try out.appendSlice(a, "{\"path\":");
    try appendJsonString(out, a, point.path);
    try out.appendSlice(a, ",\"line\":");
    try appendUnsigned(out, a, point.line);
    try out.appendSlice(a, ",\"column\":");
    try appendUnsigned(out, a, point.column);
    try out.append(a, '}');
}

/// Write one finding with the exact field names and meanings used by the
/// Doctor normalized representation. Publication checks deliberately reuse
/// this serializer for their root finding array.
pub fn writeFindingJson(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    finding: Finding,
) !void {
    try out.appendSlice(a, "{\"code\":");
    try appendJsonString(out, a, @tagName(finding.code));
    try out.appendSlice(a, ",\"domain\":");
    try appendJsonString(out, a, @tagName(finding.domain));
    try out.appendSlice(a, ",\"severity\":");
    try appendJsonString(out, a, @tagName(finding.severity));
    try out.appendSlice(a, ",\"confidence\":");
    try appendJsonString(out, a, @tagName(finding.confidence));
    try out.appendSlice(a, ",\"owner\":");
    try appendJsonString(out, a, @tagName(finding.owner));
    try out.appendSlice(a, ",\"subject\":{\"kind\":");
    try appendJsonString(out, a, finding.subject.kind);
    try out.appendSlice(a, ",\"id\":");
    try appendJsonString(out, a, finding.subject.id);
    try out.appendSlice(a, ",\"target\":");
    if (finding.subject.target) |target| {
        try appendJsonString(out, a, target);
    } else {
        try out.appendSlice(a, "null");
    }
    try out.appendSlice(a, "},\"source_location\":");
    try appendLocation(out, a, finding.source_location);
    try out.appendSlice(a, ",\"output_location\":");
    try appendLocation(out, a, finding.output_location);
    try out.appendSlice(a, ",\"configuration_location\":");
    try appendLocation(out, a, finding.configuration_location);
    try out.appendSlice(a, ",\"evidence\":{\"observed\":");
    try appendJsonString(out, a, finding.evidence.observed);
    try out.appendSlice(a, ",\"expected\":");
    try appendJsonString(out, a, finding.evidence.expected);
    try out.appendSlice(a, ",\"related\":[");
    for (finding.evidence.related, 0..) |related, related_i| {
        if (related_i > 0) try out.append(a, ',');
        try appendJsonString(out, a, related);
    }
    try out.appendSlice(a, "]},\"remediation\":");
    try appendJsonString(out, a, finding.remediation);
    try out.appendSlice(a, ",\"fixability\":");
    try appendJsonString(out, a, @tagName(finding.fixability));
    try out.append(a, '}');
}

/// Internal canonical serialization used by Slice 1 goldens and repeat-run
/// tests. This is not the future public Doctor report renderer or schema.
pub fn writeNormalizedJson(gpa: std.mem.Allocator, report: Report) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"coverage\":[");
    for (report.coverage, 0..) |coverage, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"check\":");
        try appendJsonString(&out, gpa, coverage.check);
        try out.appendSlice(gpa, ",\"domain\":");
        try appendJsonString(&out, gpa, @tagName(coverage.domain));
        try out.appendSlice(gpa, ",\"status\":");
        try appendJsonString(&out, gpa, @tagName(coverage.status));
        try out.appendSlice(gpa, ",\"subjects\":");
        try appendUnsigned(&out, gpa, coverage.subjects);
        try out.append(gpa, '}');
    }
    try out.appendSlice(gpa, "],\"findings\":[");
    for (report.findings, 0..) |finding, i| {
        if (i > 0) try out.append(gpa, ',');
        try writeFindingJson(&out, gpa, finding);
    }
    try out.appendSlice(gpa, "]}\n");
    return out.toOwnedSlice(gpa);
}

fn countCode(report: Report, code: Code) usize {
    var count: usize = 0;
    for (report.findings) |finding| if (finding.code == code) {
        count += 1;
    };
    return count;
}

test "rendered analyzer checks routes fragments ids and ownership without judging extra HTML stale" {
    const pages = [_]PageInput{
        .{ .path = "guides/start.html", .html =
        \\<html><body>
        \\<a href="../index.html#present">root</a>
        \\<a href="../index.html#absent">missing cross-page</a>
        \\<a href="?view=all#missing">missing same-page</a>
        \\<a href="../gone.html">gone</a>
        \\<a href="../../escape.html">escape</a>
        \\<main data-boris-search-root>
        \\  <h1 id="present">Start</h1>
        \\  <div id="dup"></div><span id="dup"></span>
        \\  <h2 id="heading-dup">One</h2><h3 id="heading-dup">Two</h3>
        \\</main>
        \\</body></html>
        },
        .{
            .path = "index.html",
            .html = "<main data-boris-search-root><h1 id=present>Home</h1></main>",
        },
        .{
            .path = "404.html",
            .html = "<main><h1 id=not-found>Not found</h1></main>",
        },
        .{
            .path = "verification.html",
            .html = "<meta name=verification content=ok>",
        },
        .{
            .path = "retained-landing.html",
            .html = "<main><h1 id=retained>Retained landing</h1></main>",
        },
    };
    const expected = [_][]const u8{ "guides/start.html", "index.html" };
    var report = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
    });
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 1), countCode(report, .HTML_LOCAL_ROUTE_MISSING));
    try std.testing.expectEqual(@as(usize, 1), countCode(report, .HTML_LOCAL_ROUTE_ESCAPE));
    try std.testing.expectEqual(@as(usize, 2), countCode(report, .HTML_FRAGMENT_MISSING));
    try std.testing.expectEqual(@as(usize, 2), countCode(report, .HTML_DUPLICATE_ID));
    for (report.findings) |finding| {
        try std.testing.expect(!std.mem.eql(u8, @tagName(finding.code), "HTML_PAGE_STALE"));
    }
}

test "malformed HTML variants make rendered coverage incomplete" {
    const paths = [_][]const u8{
        "test/fixtures/doctor-slice-1/hostile/unterminated-tag.html",
        "test/fixtures/doctor-slice-1/hostile/unterminated-comment.html",
        "test/fixtures/doctor-slice-1/hostile/unterminated-quote.html",
        "test/fixtures/doctor-slice-1/hostile/unterminated-raw-text.html",
    };
    for (paths) |path| {
        const html = try readFileNoFollow(
            std.testing.io,
            std.Io.Dir.cwd(),
            std.testing.allocator,
            path,
        );
        defer std.testing.allocator.free(html);
        const pages = [_]PageInput{.{ .path = "index.html", .html = html }};
        const expected = [_][]const u8{"index.html"};
        var report = try analyzeTarget(std.testing.allocator, .{
            .target_name = "public",
            .pages = &pages,
            .expected_page_paths = &expected,
            .intended_route_paths = &expected,
        });
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 1), countCode(report, .HTML_MALFORMED));
        try std.testing.expectEqual(CoverageStatus.incomplete, report.coverage[0].status);
    }
}

test "focused rendered fixture checks nested links while leaving deployment HTML unowned" {
    const fixture_paths = [_][]const u8{
        "test/fixtures/doctor-slice-1/site/index.html",
        "test/fixtures/doctor-slice-1/site/guides/reference.html",
        "test/fixtures/doctor-slice-1/site/404.html",
        "test/fixtures/doctor-slice-1/site/verification.html",
        "test/fixtures/doctor-slice-1/site/retained-landing.html",
    };
    var fixture_bytes: [fixture_paths.len][]u8 = undefined;
    for (fixture_paths, 0..) |path, i| {
        fixture_bytes[i] = try readFileNoFollow(
            std.testing.io,
            std.Io.Dir.cwd(),
            std.testing.allocator,
            path,
        );
    }
    defer for (fixture_bytes) |bytes| std.testing.allocator.free(bytes);
    const pages = [_]PageInput{
        .{
            .path = "index.html",
            .html = fixture_bytes[0],
        },
        .{
            .path = "guides/reference.html",
            .html = fixture_bytes[1],
        },
        .{
            .path = "404.html",
            .html = fixture_bytes[2],
        },
        .{
            .path = "verification.html",
            .html = fixture_bytes[3],
        },
        .{
            .path = "retained-landing.html",
            .html = fixture_bytes[4],
        },
    };
    const expected = [_][]const u8{ "guides/reference.html", "index.html" };
    var report = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.findings.len);
    try std.testing.expectEqual(CoverageStatus.checked, report.coverage[0].status);
}

test "entity-equivalent duplicate ids spanning content and theme are unknown" {
    const pages = [_]PageInput{.{ .path = "index.html", .html =
        \\<html><body><div id="a&amp;b"></div>
        \\<main data-boris-search-root><h1 id="a&#38;b">Title</h1></main>
        \\</body></html>
    }};
    const expected = [_][]const u8{"index.html"};
    var report = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.findings.len);
    try std.testing.expectEqual(Code.HTML_DUPLICATE_ID, report.findings[0].code);
    try std.testing.expectEqual(Owner.unknown, report.findings[0].owner);
    try std.testing.expectEqual(Fixability.not_actionable, report.findings[0].fixability);
    try std.testing.expectEqual(@as(usize, 2), report.findings[0].evidence.related.len);
}

test "URL variants are local and remote schemes never perform work" {
    const pages = [_]PageInput{
        .{ .path = "nested/start.html", .html =
        \\<main data-boris-search-root>
        \\<h1 id="café">Start</h1>
        \\<a href='../index.html#root'>single</a>
        \\<img src=../asset.png>
        \\<img src="../asset.png">
        \\<a href="/index.html#root">root relative</a>
        \\<a href="?x=1#caf%C3%A9">query</a>
        \\<a href="#missing">hash</a>
        \\<a href="%2e%2e%2findex.html#root">encoded slash</a>
        \\<a href="%252e%252e/index.html">double encoded</a>
        \\<a href="%252e%252e/%252e%252e/escape.html">double encoded escape</a>
        \\<a href="bad%2">bad</a>
        \\<a href="https://unreachable.invalid/x">remote</a>
        \\<a href="//unreachable.invalid/x">remote</a>
        \\<a href="ftp://unreachable.invalid/x">remote</a>
        \\<!-- <a href="../../comment"> -->
        \\<script>const x = '<a href="../../script">';</script>
        \\</main>
        },
        .{ .path = "index.html", .html = "<main data-boris-search-root><h1 id=root>Root</h1></main>" },
    };
    const expected = [_][]const u8{ "index.html", "nested/start.html" };
    const intended = [_][]const u8{ "asset.png", "index.html", "nested/start.html" };
    var report = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &intended,
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), countCode(report, .HTML_URL_MALFORMED));
    try std.testing.expectEqual(@as(usize, 1), countCode(report, .HTML_FRAGMENT_MISSING));
    try std.testing.expectEqual(@as(usize, 1), countCode(report, .HTML_LOCAL_ROUTE_ESCAPE));
}

test "search comparison reports missing malformed stale missing and changed documents" {
    const pages = [_]PageInput{
        .{ .path = "index.html", .html = "<main data-boris-search-root><h1 id=home>Home</h1><p>Hello.</p></main>" },
        .{ .path = "guide.html", .html = "<main data-boris-search-root><h1 id=guide>Guide</h1></main>" },
    };
    const expected = [_][]const u8{ "guide.html", "index.html" };

    var missing = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
        .search_page_paths = &expected,
        .search = .selected_missing,
    });
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 1), countCode(missing, .SEARCH_MISSING));
    try std.testing.expectEqual(CoverageStatus.incomplete, missing.coverage[1].status);

    var malformed = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
        .search_page_paths = &expected,
        .search = .{ .selected = "{\"format\":\"wrong\"}" },
    });
    defer malformed.deinit();
    try std.testing.expectEqual(@as(usize, 1), countCode(malformed, .SEARCH_MALFORMED));

    const stale_and_changed =
        \\{
        \\  "format": "boris-rendered-search-index",
        \\  "schema_version": 1,
        \\  "documents": [
        \\    {"path":"index.html","title":"Wrong","sections":[]},
        \\    {"path":"old.html","title":"Old","sections":[]}
        \\  ]
        \\}
    ;
    var mismatch = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
        .search_page_paths = &expected,
        .search = .{ .selected = stale_and_changed },
    });
    defer mismatch.deinit();
    try std.testing.expectEqual(@as(usize, 1), countCode(mismatch, .SEARCH_DOCUMENT_MISSING));
    try std.testing.expectEqual(@as(usize, 1), countCode(mismatch, .SEARCH_DOCUMENT_STALE));
    try std.testing.expectEqual(@as(usize, 1), countCode(mismatch, .SEARCH_CONTENT_MISMATCH));

    const stale_fragment =
        \\{
        \\  "format": "boris-rendered-search-index",
        \\  "schema_version": 1,
        \\  "documents": [
        \\    {
        \\      "path": "index.html",
        \\      "title": "Home",
        \\      "sections": [
        \\        {"level": 1, "heading": "Home", "fragment": "stale", "text": "Hello.", "code": ""}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    const index_only = [_][]const u8{"index.html"};
    var fragment = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
        .search_page_paths = &index_only,
        .search = .{ .selected = stale_fragment },
    });
    defer fragment.deinit();
    try std.testing.expectEqual(@as(usize, 2), countCode(fragment, .SEARCH_CONTENT_MISMATCH));

    const index_document = try search_index.indexHtml(
        std.testing.allocator,
        "index.html",
        pages[0].html,
        false,
    );
    defer search_index.freeDocument(std.testing.allocator, index_document);
    const guide_document = try search_index.indexHtml(
        std.testing.allocator,
        "guide.html",
        pages[1].html,
        false,
    );
    defer search_index.freeDocument(std.testing.allocator, guide_document);
    const reversed_documents = [_]search_index.Document{ index_document, guide_document };
    const reversed_bytes = try search_index.writeJson(std.testing.allocator, &reversed_documents);
    defer std.testing.allocator.free(reversed_bytes);
    var reversed = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &pages,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
        .search_page_paths = &expected,
        .search = .{ .selected = reversed_bytes },
    });
    defer reversed.deinit();
    try std.testing.expectEqual(@as(usize, 1), countCode(reversed, .SEARCH_CONTENT_MISMATCH));
}

test "filesystem inspection is no-follow and leaves target bytes unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const html = "<main data-boris-search-root><h1 id=home>Home</h1><p>Hello.</p></main>";
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = html });
    try tmp.dir.createDirPath(io, "_boris/search");
    const document = try search_index.indexHtml(gpa, "index.html", html, false);
    defer search_index.freeDocument(gpa, document);
    const documents = [_]search_index.Document{document};
    const search_bytes = try search_index.writeJson(gpa, &documents);
    defer gpa.free(search_bytes);
    try tmp.dir.writeFile(io, .{
        .sub_path = search_index.output_path,
        .data = search_bytes,
    });

    const before_html = try readFileNoFollow(io, tmp.dir, gpa, "index.html");
    defer gpa.free(before_html);
    const before_search = try readFileNoFollow(io, tmp.dir, gpa, search_index.output_path);
    defer gpa.free(before_search);
    const paths = [_][]const u8{"index.html"};
    var report = try inspectTarget(io, gpa, tmp.dir, .{
        .target_name = "public",
        .page_paths = &paths,
        .expected_page_paths = &paths,
        .intended_route_paths = &paths,
        .search_page_paths = &paths,
        .search_selected = true,
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.findings.len);
    try std.testing.expectEqual(CoverageStatus.checked, report.coverage[0].status);
    try std.testing.expectEqual(CoverageStatus.checked, report.coverage[1].status);

    const after_html = try readFileNoFollow(io, tmp.dir, gpa, "index.html");
    defer gpa.free(after_html);
    const after_search = try readFileNoFollow(io, tmp.dir, gpa, search_index.output_path);
    defer gpa.free(after_search);
    try std.testing.expectEqualStrings(before_html, after_html);
    try std.testing.expectEqualStrings(before_search, after_search);
}

test "filesystem inspection rejects escape and symlink paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const escape = [_][]const u8{"../outside.html"};
    try std.testing.expectError(error.UnsafeSnapshotPath, inspectTarget(io, gpa, tmp.dir, .{
        .target_name = "public",
        .page_paths = &escape,
        .expected_page_paths = &.{},
        .intended_route_paths = &.{},
    }));

    if (@import("builtin").os.tag == .windows) return;
    try tmp.dir.writeFile(io, .{ .sub_path = "real.html", .data = "<main>real</main>" });
    tmp.dir.symLink(io, "real.html", "alias.html", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };
    const alias = [_][]const u8{"alias.html"};
    try std.testing.expectError(error.UnsafeSnapshotPath, inspectTarget(io, gpa, tmp.dir, .{
        .target_name = "public",
        .page_paths = &alias,
        .expected_page_paths = &alias,
        .intended_route_paths = &alias,
    }));
}

test "shuffled snapshot inputs normalize to the same finding order" {
    const page_a = PageInput{
        .path = "a.html",
        .html = "<main data-boris-search-root><h1 id=x>A</h1><a href=missing.html>x</a></main>",
    };
    const page_b = PageInput{
        .path = "b.html",
        .html = "<main data-boris-search-root><h1 id=x>B</h1><a href=gone.html>x</a></main>",
    };
    const first = [_]PageInput{ page_b, page_a };
    const second = [_]PageInput{ page_a, page_b };
    const expected = [_][]const u8{ "b.html", "a.html" };
    var a_report = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &first,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
    });
    defer a_report.deinit();
    var b_report = try analyzeTarget(std.testing.allocator, .{
        .target_name = "public",
        .pages = &second,
        .expected_page_paths = &expected,
        .intended_route_paths = &expected,
    });
    defer b_report.deinit();
    const a_bytes = try writeNormalizedJson(std.testing.allocator, a_report);
    defer std.testing.allocator.free(a_bytes);
    const b_bytes = try writeNormalizedJson(std.testing.allocator, b_report);
    defer std.testing.allocator.free(b_bytes);
    try std.testing.expectEqualStrings(a_bytes, b_bytes);
    try std.testing.expectEqual(a_report.findings.len, b_report.findings.len);
    for (a_report.findings, b_report.findings) |left, right| {
        try std.testing.expectEqual(left.code, right.code);
        try std.testing.expectEqualStrings(left.subject.id, right.subject.id);
        try std.testing.expectEqualStrings(left.evidence.observed, right.evidence.observed);
    }
}
