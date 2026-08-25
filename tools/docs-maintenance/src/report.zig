const std = @import("std");
const model = @import("model.zig");

pub fn writeJsonReport(writer: anytype, report: model.InventoryReport) !void {
    try writer.writeAll("{\n");
    try writer.writeAll("  \"format\": \"boris-docs-inventory-v0\",\n");

    // records
    try writer.writeAll("  \"records\": [\n");
    for (report.records, 0..) |rec, i| {
        try writer.print(
            \\    {{
            \\      "path": "{s}",
            \\      "kind": "{s}",
            \\      "bytes": {d},
            \\      "sha256": "{s}",
            \\      "has_dossier_marker": {}
            \\    }}
        , .{
            rec.path,
            rec.kind.asString(),
            rec.bytes,
            rec.sha256,
            rec.has_dossier_marker,
        });
        if (i + 1 < report.records.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("  ],\n");

    // relationships
    try writer.writeAll("  \"relationships\": [\n");
    for (report.relationships, 0..) |rel, i| {
        try writer.print(
            \\    {{
            \\      "kind": "{s}",
            \\      "source_path": "{s}",
            \\      "dossier_paths": [
        , .{ rel.kind.asString(), rel.source_path });
        for (rel.dossier_paths, 0..) |dp, j| {
            try writer.print("\"{s}\"", .{dp});
            if (j + 1 < rel.dossier_paths.len) {
                try writer.writeAll(", ");
            }
        }
        try writer.writeAll("]\n    }");
        if (i + 1 < report.relationships.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("  ],\n");

    // diagnostics
    try writer.writeAll("  \"diagnostics\": [\n");
    for (report.diagnostics, 0..) |diag, i| {
        try writer.print(
            \\    {{
            \\      "code": "{s}",
            \\      "path": "{s}",
            \\      "line": {d},
            \\      "message": "{s}"
            \\    }}
        , .{ diag.code, diag.path, diag.line, diag.message });
        if (i + 1 < report.diagnostics.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("  ],\n");

    // evidence_set_sha256
    try writer.print("  \"evidence_set_sha256\": \"{s}\"\n", .{report.evidence_set_sha256});
    try writer.writeAll("}\n");
}

pub fn writeMarkdownSummary(writer: anytype, report: model.InventoryReport) !void {
    try writer.writeAll("# Documentation Maintenance Inventory Summary\n\n");

    // Category Counts
    var count_sources: usize = 0;
    var count_tests: usize = 0;
    var count_dossiers: usize = 0;
    var count_contracts: usize = 0;
    var count_notes: usize = 0;
    var count_changelogs: usize = 0;
    var count_docs: usize = 0;

    for (report.records) |r| {
        switch (r.kind) {
            .zig_source => count_sources += 1,
            .zig_test => count_tests += 1,
            .source_dossier => count_dossiers += 1,
            .contract => count_contracts += 1,
            .field_note => count_notes += 1,
            .product_changelog, .tool_changelog => count_changelogs += 1,
            .documentation => count_docs += 1,
        }
    }

    var count_no_dossier: usize = 0;
    var count_no_source: usize = 0;
    var count_duplicate: usize = 0;

    for (report.relationships) |rel| {
        switch (rel.kind) {
            .source_without_dossier => count_no_dossier += 1,
            .dossier_without_source => count_no_source += 1,
            .duplicate_dossier_claim => count_duplicate += 1,
        }
    }

    try writer.writeAll("## Inventory Totals\n\n");
    try writer.writeAll("| Category | Count |\n");
    try writer.writeAll("| :-- | :-- |\n");
    try writer.print("| Total files in evidence set | {d} |\n", .{report.records.len});
    try writer.print("| Zig sources (`zig_source`) | {d} |\n", .{count_sources});
    try writer.print("| Zig tests (`zig_test`) | {d} |\n", .{count_tests});
    try writer.print("| Source dossiers (`source_dossier`) | {d} |\n", .{count_dossiers});
    try writer.print("| Contracts (`contract`) | {d} |\n", .{count_contracts});
    try writer.print("| Field notes (`field_note`) | {d} |\n", .{count_notes});
    try writer.print("| Changelogs | {d} |\n", .{count_changelogs});
    try writer.print("| General documentation | {d} |\n", .{count_docs});
    try writer.print("| Sources without dossier (`source_without_dossier`) | {d} |\n", .{count_no_dossier});
    try writer.print("| Dossiers without source (`dossier_without_source`) | {d} |\n", .{count_no_source});
    try writer.print("| Duplicate claims (`duplicate_dossier_claim`) | {d} |\n", .{count_duplicate});
    try writer.print("| Total diagnostics | {d} |\n\n", .{report.diagnostics.len});

    try writer.writeAll("## Evidence Set Digest\n\n");
    try writer.print("`evidence_set_sha256`: `{s}`\n\n", .{report.evidence_set_sha256});

    // Structural Relationships Detail Table
    try writer.writeAll("## Structural Relationships\n\n");
    if (report.relationships.len == 0) {
        try writer.writeAll("No structural conditions recorded.\n\n");
    } else {
        try writer.writeAll("| Condition Kind | Source Path | Dossier Paths |\n");
        try writer.writeAll("| :-- | :-- | :-- |\n");
        for (report.relationships) |rel| {
            try writer.print("| `{s}` | `{s}` | ", .{ rel.kind.asString(), rel.source_path });
            if (rel.dossier_paths.len == 0) {
                try writer.writeAll("*(none)* |\n");
            } else {
                for (rel.dossier_paths, 0..) |dp, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try writer.print("`{s}`", .{dp});
                }
                try writer.writeAll(" |\n");
            }
        }
        try writer.writeAll("\n");
    }

    // Diagnostics Detail Table
    try writer.writeAll("## Diagnostics\n\n");
    if (report.diagnostics.len == 0) {
        try writer.writeAll("No diagnostics recorded.\n\n");
    } else {
        try writer.writeAll("| Code | File Path | Line | Message |\n");
        try writer.writeAll("| :-- | :-- | :-- | :-- |\n");
        for (report.diagnostics) |d| {
            try writer.print("| `{s}` | `{s}` | {d} | {s} |\n", .{ d.code, d.path, d.line, d.message });
        }
        try writer.writeAll("\n");
    }
}
