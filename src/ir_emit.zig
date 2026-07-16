//! Pure, deterministic JSON artifact renderers for frozen Boris IR data.
//! This module borrows its input and intentionally does not import pipeline.
const std = @import("std");
const graph_mod = @import("graph.zig");
const json_out = @import("json_out.zig");

pub const VersionInfo = struct {
    schema_version: []const u8,
    compiler_id: []const u8,
    semantic_schema_version: []const u8,
    semantic_compiler_id: []const u8,
};

fn hasSemanticRelations(result: anytype) bool {
    for (result.pages.items) |page| if (page.semantic_relations.len > 0) return true;
    return false;
}

fn artifactSchemaVersion(result: anytype, versions: VersionInfo) []const u8 {
    return if (hasSemanticRelations(result)) versions.semantic_schema_version else versions.schema_version;
}

fn artifactCompilerId(result: anytype, versions: VersionInfo) []const u8 {
    return if (hasSemanticRelations(result)) versions.semantic_compiler_id else versions.compiler_id;
}

fn endpointLess(a: anytype, b: @TypeOf(a)) bool {
    const type_order = std.mem.order(u8, a.type.name(), b.type.name());
    if (type_order != .eq) return type_order == .lt;
    return std.mem.order(u8, a.value, b.value) == .lt;
}

fn endpointEql(a: anytype, b: @TypeOf(a)) bool {
    return a.type == b.type and std.mem.eql(u8, a.value, b.value);
}

fn writeOptionalString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: ?[]const u8) !void {
    if (s) |v| {
        try json_out.writeString(buf, gpa, v);
    } else {
        try json_out.writeNull(buf, gpa);
    }
}

pub fn renderManifest(gpa: std.mem.Allocator, result: anytype, versions: VersionInfo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"schemaVersion\": ");
    try json_out.writeString(&buf, gpa, artifactSchemaVersion(result, versions));
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"compiler\": ");
    try json_out.writeString(&buf, gpa, artifactCompilerId(result, versions));
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"contentRoot\": ");
    try json_out.writeString(&buf, gpa, result.content_root);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"pageCount\": ");
    try json_out.writeUsize(&buf, gpa, result.pages.items.len);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"pages\": [\n");

    for (result.pages.items, 0..) |p, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"index\": ");
        try json_out.writeUsize(&buf, gpa, p.index);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"id\": ");
        try json_out.writeString(&buf, gpa, p.id);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"sourcePath\": ");
        try json_out.writeString(&buf, gpa, p.source_path);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"role\": ");
        try json_out.writeString(&buf, gpa, p.role.name());
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"parent\": ");
        try writeOptionalString(&buf, gpa, p.parent);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"title\": ");
        try writeOptionalString(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"status\": ");
        try writeOptionalString(&buf, gpa, p.status);
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < result.pages.items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }

    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "]\n}\n");
    return try buf.toOwnedSlice(gpa);
}

fn writeU32Array(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const u32) !void {
    try buf.append(gpa, '[');
    for (values, 0..) |v, i| {
        if (i > 0) try buf.appendSlice(gpa, ", ");
        try json_out.writeUsize(buf, gpa, v);
    }
    try buf.append(gpa, ']');
}

fn writeEndpoint(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, endpoint: anytype, indent_level: usize) !void {
    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(buf, gpa, indent_level + 1);
    try buf.appendSlice(gpa, "\"type\": ");
    try json_out.writeString(buf, gpa, endpoint.type.name());
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(buf, gpa, indent_level + 1);
    try buf.appendSlice(gpa, "\"value\": ");
    try json_out.writeString(buf, gpa, endpoint.value);
    try buf.append(gpa, '\n');
    try json_out.indent(buf, gpa, indent_level);
    try buf.append(gpa, '}');
}

pub fn renderGraph(gpa: std.mem.Allocator, result: anytype, versions: VersionInfo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    // Nav is derived only from the frozen node list (parent_index / role).
    // Not published when validation failed (caller does not write graph.json).
    const nav = try graph_mod.buildNav(gpa, result.pages.items);
    defer graph_mod.freeNav(gpa, nav);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"schemaVersion\": ");
    try json_out.writeString(&buf, gpa, artifactSchemaVersion(result, versions));
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"frozen\": ");
    try json_out.writeBool(&buf, gpa, result.graph_frozen);
    try buf.appendSlice(gpa, ",\n");

    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"nodes\": [\n");
    for (result.pages.items, 0..) |p, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"index\": ");
        try json_out.writeUsize(&buf, gpa, p.index);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"id\": ");
        try json_out.writeString(&buf, gpa, p.id);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"sourcePath\": ");
        try json_out.writeString(&buf, gpa, p.source_path);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"role\": ");
        try json_out.writeString(&buf, gpa, p.role.name());
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"parent\": ");
        try writeOptionalString(&buf, gpa, p.parent);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"parentIndex\": ");
        try json_out.writeOptionalU32(&buf, gpa, p.parent_index);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"title\": ");
        try writeOptionalString(&buf, gpa, p.title);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"status\": ");
        try writeOptionalString(&buf, gpa, p.status);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"tags\": [");
        for (p.tags, 0..) |t, ti| {
            if (ti > 0) try buf.appendSlice(gpa, ", ");
            try json_out.writeString(&buf, gpa, t);
        }
        try buf.appendSlice(gpa, "],\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"bodyOffset\": ");
        try json_out.writeUsize(&buf, gpa, p.body_offset);
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < result.pages.items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "],\n");

    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"edges\": [\n");
    for (result.edges.items, 0..) |e, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"from\": ");
        try writeEndpoint(&buf, gpa, e.from, 3);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"to\": ");
        try writeEndpoint(&buf, gpa, e.to, 3);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"kind\": ");
        try json_out.writeString(&buf, gpa, e.kind);
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < result.edges.items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "],\n");

    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"reverseIndex\": [\n");
    for (result.reverse_index.items, 0..) |entry, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"target\": ");
        try writeEndpoint(&buf, gpa, entry.target, 3);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"incomingEdges\": ");
        try writeU32Array(&buf, gpa, entry.incoming_edges);
        try buf.append(gpa, '\n');
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < result.reverse_index.items.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "],\n");

    // Key order after reverseIndex: nav (derived, id-sorted parallel to nodes).
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"nav\": [\n");
    for (nav, 0..) |entry, i| {
        try json_out.indent(&buf, gpa, 2);
        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"index\": ");
        try json_out.writeUsize(&buf, gpa, entry.index);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"id\": ");
        try json_out.writeString(&buf, gpa, entry.id);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"breadcrumb\": ");
        try writeU32Array(&buf, gpa, entry.breadcrumb);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"children\": ");
        try writeU32Array(&buf, gpa, entry.children);
        try buf.appendSlice(gpa, ",\n");
        try json_out.indent(&buf, gpa, 3);
        try buf.appendSlice(gpa, "\"siblings\": ");
        try writeU32Array(&buf, gpa, entry.siblings);
        try buf.appendSlice(gpa, "\n");
        try json_out.indent(&buf, gpa, 2);
        try buf.append(gpa, '}');
        if (i + 1 < nav.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try json_out.indent(&buf, gpa, 1);
    if (!hasSemanticRelations(result)) {
        try buf.appendSlice(gpa, "]\n}\n");
    } else {
        try buf.appendSlice(gpa, "],\n");
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "\"relations\": [\n");

        const Endpoint = @TypeOf(result.edges.items[0].from);
        const SemanticEdge = struct { from: Endpoint, to: Endpoint, kind: []const u8 };
        var semantic_edges: std.ArrayList(SemanticEdge) = .empty;
        defer semantic_edges.deinit(gpa);
        for (result.pages.items) |page| {
            for (page.semantic_relations) |relation| {
                try semantic_edges.append(gpa, .{
                    .from = .{ .type = .page, .value = page.id },
                    .to = .{ .type = .page, .value = relation.target },
                    .kind = relation.kind.name(),
                });
            }
        }
        std.sort.block(SemanticEdge, semantic_edges.items, {}, struct {
            fn lessThan(_: void, a: SemanticEdge, b: SemanticEdge) bool {
                if (!endpointEql(a.from, b.from)) return endpointLess(a.from, b.from);
                if (!endpointEql(a.to, b.to)) return endpointLess(a.to, b.to);
                return std.mem.order(u8, a.kind, b.kind) == .lt;
            }
        }.lessThan);
        for (semantic_edges.items, 0..) |edge, i| {
            try json_out.indent(&buf, gpa, 2);
            try buf.appendSlice(gpa, "{\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"from\": ");
            try writeEndpoint(&buf, gpa, edge.from, 3);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"to\": ");
            try writeEndpoint(&buf, gpa, edge.to, 3);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"kind\": ");
            try json_out.writeString(&buf, gpa, edge.kind);
            try buf.appendSlice(gpa, "\n");
            try json_out.indent(&buf, gpa, 2);
            try buf.append(gpa, '}');
            if (i + 1 < semantic_edges.items.len) try buf.append(gpa, ',');
            try buf.append(gpa, '\n');
        }
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "]\n}\n");
    }

    return try buf.toOwnedSlice(gpa);
}

pub fn renderBuildReport(gpa: std.mem.Allocator, result: anytype, versions: VersionInfo) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"schemaVersion\": ");
    try json_out.writeString(&buf, gpa, artifactSchemaVersion(result, versions));
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"ok\": ");
    try json_out.writeBool(&buf, gpa, result.ok);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"contentRoot\": ");
    try json_out.writeString(&buf, gpa, result.content_root);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"outDir\": ");
    try json_out.writeString(&buf, gpa, result.out_dir);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"pageCount\": ");
    try json_out.writeUsize(&buf, gpa, result.pages.items.len);
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"errorCount\": ");
    try json_out.writeUsize(&buf, gpa, result.errorCount());
    try buf.appendSlice(gpa, ",\n");
    try json_out.indent(&buf, gpa, 1);
    try buf.appendSlice(gpa, "\"diagnostics\": ");
    if (result.diagnostics.items.len == 0) {
        try buf.appendSlice(gpa, "[]\n");
    } else {
        try buf.appendSlice(gpa, "[\n");
        for (result.diagnostics.items, 0..) |d, i| {
            try json_out.indent(&buf, gpa, 2);
            try buf.appendSlice(gpa, "{\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"severity\": ");
            try json_out.writeString(&buf, gpa, d.severity.jsonName());
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"code\": ");
            try json_out.writeString(&buf, gpa, d.code.name());
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"message\": ");
            try json_out.writeString(&buf, gpa, d.message);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"remediation\": ");
            try json_out.writeString(&buf, gpa, d.remediation);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"sourcePath\": ");
            if (d.source_path.len == 0)
                try json_out.writeNull(&buf, gpa)
            else
                try json_out.writeString(&buf, gpa, d.source_path);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"line\": ");
            try json_out.writeOptionalU32(&buf, gpa, d.line);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"column\": ");
            try json_out.writeOptionalU32(&buf, gpa, d.column);
            try buf.appendSlice(gpa, ",\n");
            try json_out.indent(&buf, gpa, 3);
            try buf.appendSlice(gpa, "\"id\": ");
            if (d.id.len == 0)
                try json_out.writeNull(&buf, gpa)
            else
                try json_out.writeString(&buf, gpa, d.id);
            try buf.appendSlice(gpa, "\n");
            try json_out.indent(&buf, gpa, 2);
            try buf.append(gpa, '}');
            if (i + 1 < result.diagnostics.items.len) try buf.append(gpa, ',');
            try buf.append(gpa, '\n');
        }
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "]\n");
    }
    try buf.appendSlice(gpa, "}\n");
    return try buf.toOwnedSlice(gpa);
}
