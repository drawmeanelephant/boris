//! Canonical JSON report emitter for boris-content-audit.
//!
//! Byte-deterministic: fixed field order, sorted arrays, no host paths, no
//! timestamps, no random ids. Absolute filesystem paths are never emitted;
//! records carry content-root-relative source paths and canonical ids.

const std = @import("std");
const util = @import("util.zig");
const audit_mod = @import("audit.zig");

pub const EmitOptions = struct {
    format: []const u8 = "all", // json | markdown | html | all
    collections: []const []const u8 = &.{},
};

fn isSelected(opts: *const EmitOptions, collection: []const u8) bool {
    if (opts.collections.len == 0) return true;
    for (opts.collections) |c| {
        if (util.eql(c, collection)) return true;
    }
    return false;
}

fn appendCoverageObject(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    row: *const audit_mod.CoverageRow,
) !void {
    try buf.appendSlice(gpa, "{\"collection\": ");
    try util.appendJsonString(buf, gpa, row.collection);
    try buf.appendSlice(gpa, ", \"type\": ");
    try util.appendJsonString(buf, gpa, row.type_name);
    try buf.appendSlice(gpa, ", \"expected\": ");
    try util.appendJsonNumber(buf, gpa, row.expected);
    try buf.appendSlice(gpa, ", \"present_empty\": ");
    try util.appendJsonNumber(buf, gpa, row.present_empty);
    try buf.appendSlice(gpa, ", \"present_placeholder\": ");
    try util.appendJsonNumber(buf, gpa, row.present_placeholder);
    try buf.appendSlice(gpa, ", \"present_substantive\": ");
    try util.appendJsonNumber(buf, gpa, row.present_substantive);
    try buf.appendSlice(gpa, ", \"missing\": ");
    try util.appendJsonNumber(buf, gpa, row.missing);
    try buf.appendSlice(gpa, ", \"ambiguous_mapping\": ");
    try util.appendJsonNumber(buf, gpa, row.ambiguous_mapping);
    try buf.appendSlice(gpa, ", \"malformed\": ");
    try util.appendJsonNumber(buf, gpa, row.malformed);
    try buf.appendSlice(gpa, ", \"structural\": ");
    try util.appendJsonNumber(buf, gpa, row.structural());
    try buf.appendSlice(gpa, ", \"substantive\": ");
    try util.appendJsonNumber(buf, gpa, row.substantive());
    try buf.appendSlice(gpa, ", \"placeholder_only\": ");
    try util.appendJsonNumber(buf, gpa, row.placeholderOnly());
    try buf.appendSlice(gpa, ", \"missing_coverage\": ");
    try util.appendJsonNumber(buf, gpa, row.missingCount());
    try buf.appendSlice(gpa, "}");
}

fn evidenceList(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, rec: *const audit_mod.Record) !void {
    // Distinct evidence kinds in canonical order: parent, relation, policy.
    var kinds: [3]bool = .{ false, false, false };
    for (rec.claims) |c| {
        switch (c.evidence) {
            .parent => kinds[0] = true,
            .relation => kinds[1] = true,
            .policy => kinds[2] = true,
        }
    }
    var first = true;
    try buf.append(gpa, '[');
    const names = [_][]const u8{ "parent", "relation", "policy" };
    for (kinds, 0..) |present, i| {
        if (!present) continue;
        if (!first) try buf.appendSlice(gpa, ", ");
        try util.appendJsonString(buf, gpa, names[i]);
        first = false;
    }
    try buf.appendSlice(gpa, "]");
}

fn appendRecordObject(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    rec: *const audit_mod.Record,
    audit: *const audit_mod.Audit,
) !void {
    try buf.appendSlice(gpa, "{\"id\": ");
    if (rec.id) |id| {
        try util.appendJsonString(buf, gpa, id);
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ", \"kind\": ");
    try util.appendJsonString(buf, gpa, rec.kind.jsonName());
    try buf.appendSlice(gpa, ", \"collection\": ");
    try util.appendJsonString(buf, gpa, rec.collection);
    try buf.appendSlice(gpa, ", \"source_path\": ");
    try util.appendJsonString(buf, gpa, rec.source_path);
    try buf.appendSlice(gpa, ", \"status\": ");
    if (rec.status) |s| {
        try util.appendJsonString(buf, gpa, s);
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ", \"poetry_type\": ");
    if (rec.poetry_type) |t| {
        try util.appendJsonString(buf, gpa, t);
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ", \"alignment\": ");
    if (rec.alignment) |a| {
        try util.appendJsonString(buf, gpa, a.jsonName());
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ", \"owner\": ");
    if (rec.owner) |o| {
        try util.appendJsonString(buf, gpa, o);
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ", \"evidence\": ");
    try evidenceList(buf, gpa, rec);
    try buf.appendSlice(gpa, ", \"verse_units\": ");
    try util.appendJsonNumber(buf, gpa, if (rec.verse) |v| v.complete_count else 0);
    try buf.appendSlice(gpa, ", \"placeholder_units\": ");
    try util.appendJsonNumber(buf, gpa, if (rec.verse) |v| v.placeholder_count else 0);
    try buf.appendSlice(gpa, ", \"substantive_units\": ");
    try util.appendJsonNumber(buf, gpa, if (rec.verse) |v| v.substantive_count else 0);
    try buf.appendSlice(gpa, ", \"malformed_units\": ");
    try util.appendJsonNumber(buf, gpa, if (rec.verse) |v| v.malformed_count else 0);
    try buf.appendSlice(gpa, ", \"density_in_band\": ");
    try util.appendJsonBool(buf, gpa, recDensityInBand(audit, rec));
    try buf.appendSlice(gpa, ", \"coverage\": ");
    if (rec.kind == .source) {
        const cov = try audit_mod.coverageSummary(gpa, rec);
        try util.appendJsonString(buf, gpa, cov);
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, "}");
}

fn recDensityInBand(audit: *const audit_mod.Audit, rec: *const audit_mod.Record) bool {
    if (rec.kind != .poetry) return false;
    const t = rec.poetry_type orelse return false;
    const bands = audit.policy.density_bands.get(t) orelse return false;
    const n = if (rec.verse) |v| v.complete_count else 0;
    for (bands) |b| {
        if (b == n) return true;
    }
    return false;
}

pub fn emit(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");
    try buf.appendSlice(gpa, "  \"format_id\": ");
    try util.appendJsonString(&buf, gpa, util.format_id);
    try buf.appendSlice(gpa, ",\n  \"schema_version\": ");
    try buf.print(gpa, "{d}", .{util.report_schema_version});
    try buf.appendSlice(gpa, ",\n  \"tool_version\": ");
    try util.appendJsonString(&buf, gpa, util.tool_version);
    try buf.appendSlice(gpa, ",\n  \"mode\": \"poetry\",\n  \"source_root_label\": ");
    try util.appendJsonString(&buf, gpa, audit.source_root_label);
    try buf.appendSlice(gpa, ",\n  \"source_revision\": ");
    if (audit.source_revision) |r| {
        try util.appendJsonString(&buf, gpa, r);
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ",\n  \"policy_digest\": ");
    try util.appendJsonString(&buf, gpa, audit.policy_digest);
    try buf.appendSlice(gpa, ",\n  \"collection_filter\": ");
    if (opts.collections.len == 0) {
        try buf.appendSlice(gpa, "[]");
    } else {
        try buf.append(gpa, '[');
        for (opts.collections, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(gpa, ", ");
            try util.appendJsonString(&buf, gpa, c);
        }
        try buf.appendSlice(gpa, "]");
    }
    // Explicit scope labeling: a filtered report never mixes filtered rows
    // beside global totals. Every section below is scoped to the selected
    // physical collections.
    try buf.appendSlice(gpa, ",\n  \"scope\": ");
    if (opts.collections.len == 0) {
        try buf.appendSlice(gpa, "{\"type\": \"all\", \"totals\": \"global\"}");
    } else {
        try buf.append(gpa, '{');
        try buf.appendSlice(gpa, "\"type\": \"source_collection_and_mapped_poetry\", \"collections\": [");
        for (opts.collections, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(gpa, ", ");
            try util.appendJsonString(&buf, gpa, c);
        }
        try buf.appendSlice(gpa, "], \"totals\": \"scoped\", \"note\": \"every total, verse total, coverage row, density figure, alignment count, exception, delta change, and per-record row in this report is restricted to the selected source collections and their mapped poetry\"}");
    }

    // Totals (every counter is scoped to the collection filter)
    var source_count: usize = 0;
    var poetry_count: usize = 0;
    var other_count: usize = 0;
    var orphan_count: usize = 0;
    var mapped_count: usize = 0;
    var ambiguous_count: usize = 0;
    var malformed_records: usize = 0;
    var dead_refs: usize = 0;
    var discovered_count: usize = 0;
    var scoped_excluded: usize = 0;
    for (audit.records) |rec| {
        if (!audit_mod.recordInScope(audit, &rec, opts.collections)) continue;
        discovered_count += 1;
        if (rec.excluded) scoped_excluded += 1;
        switch (rec.kind) {
            .source => source_count += 1,
            .poetry => poetry_count += 1,
            .other => other_count += 1,
        }
        if (rec.alignment) |a| {
            switch (a) {
                .orphan => orphan_count += 1,
                .mapped => mapped_count += 1,
                .ambiguous, .duplicate_mapping, .mapping_disagreement => ambiguous_count += 1,
                .missing_target => {},
                .malformed_record => malformed_records += 1,
            }
        } else if (rec.malformed_reason != null or rec.unsupported_shape) {
            malformed_records += 1;
        }
        if (rec.has_dead_reference) dead_refs += 1;
    }
    try buf.appendSlice(gpa, ",\n  \"totals\": {\n    \"records_discovered\": ");
    try util.appendJsonNumber(&buf, gpa, discovered_count);
    try buf.appendSlice(gpa, ",\n    \"source_records\": ");
    try util.appendJsonNumber(&buf, gpa, source_count);
    try buf.appendSlice(gpa, ",\n    \"poetry_records\": ");
    try util.appendJsonNumber(&buf, gpa, poetry_count);
    try buf.appendSlice(gpa, ",\n    \"other_records\": ");
    try util.appendJsonNumber(&buf, gpa, other_count);
    try buf.appendSlice(gpa, ",\n    \"excluded_records\": ");
    try util.appendJsonNumber(&buf, gpa, scoped_excluded);
    try buf.appendSlice(gpa, ",\n    \"mapped_poetry\": ");
    try util.appendJsonNumber(&buf, gpa, mapped_count);
    try buf.appendSlice(gpa, ",\n    \"orphan_poetry\": ");
    try util.appendJsonNumber(&buf, gpa, orphan_count);
    try buf.appendSlice(gpa, ",\n    \"ambiguous_poetry\": ");
    try util.appendJsonNumber(&buf, gpa, ambiguous_count);
    try buf.appendSlice(gpa, ",\n    \"malformed_records\": ");
    try util.appendJsonNumber(&buf, gpa, malformed_records);
    try buf.appendSlice(gpa, ",\n    \"dead_references\": ");
    try util.appendJsonNumber(&buf, gpa, dead_refs);
    try buf.appendSlice(gpa, "\n  }");

    // Verse totals by type (scoped to the collection filter)
    const scoped_stats = try audit_mod.typeStatsScoped(audit, gpa, opts.collections);
    defer gpa.free(scoped_stats);
    try buf.appendSlice(gpa, ",\n  \"verse_totals\": [");
    for (scoped_stats, 0..) |st, i| {
        if (i > 0) try buf.appendSlice(gpa, ",");
        try buf.appendSlice(gpa, "\n    {\"type\": ");
        try util.appendJsonString(&buf, gpa, st.type_name);
        try buf.appendSlice(gpa, ", \"records\": ");
        try util.appendJsonNumber(&buf, gpa, st.records);
        try buf.appendSlice(gpa, ", \"verse_units\": ");
        try util.appendJsonNumber(&buf, gpa, st.verse_units);
        try buf.appendSlice(gpa, ", \"placeholder_units\": ");
        try util.appendJsonNumber(&buf, gpa, st.placeholder_units);
        try buf.appendSlice(gpa, ", \"substantive_units\": ");
        try util.appendJsonNumber(&buf, gpa, st.substantive_units);
        try buf.appendSlice(gpa, ", \"malformed_units\": ");
        try util.appendJsonNumber(&buf, gpa, st.malformed_units);
        try buf.appendSlice(gpa, "}");
    }
    try buf.appendSlice(gpa, "\n  ]");

    // Coverage overall
    var cov: audit_mod.CoverageRow = .{ .collection = "*", .type_name = "*" };
    for (audit.coverage_rows) |*row| {
        if (!isSelected(opts, row.collection)) continue;
        cov.expected += row.expected;
        cov.present_empty += row.present_empty;
        cov.present_placeholder += row.present_placeholder;
        cov.present_substantive += row.present_substantive;
        cov.missing += row.missing;
        cov.ambiguous_mapping += row.ambiguous_mapping;
        cov.malformed += row.malformed;
    }
    try buf.appendSlice(gpa, ",\n  \"coverage_overall\": ");
    try appendCoverageObject(&buf, gpa, &cov);

    // Coverage by collection
    try buf.appendSlice(gpa, ",\n  \"coverage_by_collection\": [");
    var first = true;
    for (audit.coverage_rows) |*row| {
        if (!isSelected(opts, row.collection)) continue;
        if (!first) try buf.appendSlice(gpa, ",");
        first = false;
        try buf.appendSlice(gpa, "\n    ");
        try appendCoverageObject(&buf, gpa, row);
    }
    try buf.appendSlice(gpa, "\n  ]");

    // Coverage by type
    try buf.appendSlice(gpa, ",\n  \"coverage_by_type\": [");
    var type_rows: std.ArrayList(audit_mod.CoverageRow) = .empty;
    defer type_rows.deinit(gpa);
    for (audit.type_stats) |st| {
        var tr: audit_mod.CoverageRow = .{ .collection = "*", .type_name = st.type_name };
        for (audit.coverage_rows) |*row| {
            if (!isSelected(opts, row.collection)) continue;
            if (!util.eql(row.type_name, st.type_name)) continue;
            tr.expected += row.expected;
            tr.present_empty += row.present_empty;
            tr.present_placeholder += row.present_placeholder;
            tr.present_substantive += row.present_substantive;
            tr.missing += row.missing;
            tr.ambiguous_mapping += row.ambiguous_mapping;
            tr.malformed += row.malformed;
        }
        try type_rows.append(gpa, tr);
    }
    for (type_rows.items, 0..) |*tr, i| {
        if (i > 0) try buf.appendSlice(gpa, ",");
        try buf.appendSlice(gpa, "\n    ");
        try appendCoverageObject(&buf, gpa, tr);
    }
    try buf.appendSlice(gpa, "\n  ]");

    // Density (scoped to the collection filter)
    const scoped_density = try audit_mod.typeDensitiesScoped(audit, gpa, scoped_stats, opts.collections);
    defer gpa.free(scoped_density);
    try buf.appendSlice(gpa, ",\n  \"density\": [");
    for (scoped_density, 0..) |td, i| {
        if (i > 0) try buf.appendSlice(gpa, ",");
        try buf.appendSlice(gpa, "\n    {\"type\": ");
        try util.appendJsonString(&buf, gpa, td.type_name);
        try buf.appendSlice(gpa, ", \"distribution\": [");
        for (td.distribution, 0..) |d, di| {
            if (di > 0) try buf.appendSlice(gpa, ", ");
            try buf.print(gpa, "{{\"unit_count\": {d}, \"record_count\": {d}}}", .{ d.unit_count, d.record_count });
        }
        try buf.appendSlice(gpa, "], \"in_band_records\": ");
        try util.appendJsonNumber(&buf, gpa, td.in_band_records);
        try buf.appendSlice(gpa, ", \"out_of_band_records\": ");
        try util.appendJsonNumber(&buf, gpa, td.out_of_band_records);
        try buf.appendSlice(gpa, ", \"lowest_count\": ");
        try util.appendJsonNumber(&buf, gpa, td.lowest_count);
        try buf.appendSlice(gpa, ", \"lowest\": ");
        try appendIdArray(&buf, gpa, td.lowest);
        try buf.appendSlice(gpa, ", \"highest_count\": ");
        try util.appendJsonNumber(&buf, gpa, td.highest_count);
        try buf.appendSlice(gpa, ", \"highest\": ");
        try appendIdArray(&buf, gpa, td.highest);
        try buf.appendSlice(gpa, "}");
    }
    try buf.appendSlice(gpa, "\n  ]");

    // Alignment counts
    var am: [8]usize = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    for (audit.records) |rec| {
        if (!audit_mod.recordInScope(audit, &rec, opts.collections)) continue;
        if (rec.alignment) |a| {
            const idx: usize = switch (a) {
                .mapped => 0,
                .orphan => 1,
                .ambiguous => 2,
                .duplicate_mapping => 3,
                .mapping_disagreement => 4,
                .missing_target => 5,
                .malformed_record => 6,
            };
            am[idx] += 1;
        }
        if (rec.has_dead_reference) am[7] += 1;
    }
    const align_names = [_][]const u8{ "mapped", "orphan", "ambiguous", "duplicate_mapping", "mapping_disagreement", "missing_target", "malformed_record", "dead_reference" };
    try buf.appendSlice(gpa, ",\n  \"alignment\": {\"counts\": {");
    for (align_names, 0..) |n, i| {
        if (i > 0) try buf.appendSlice(gpa, ", ");
        try util.appendJsonString(&buf, gpa, n);
        try buf.appendSlice(gpa, ": ");
        try util.appendJsonNumber(&buf, gpa, am[i]);
    }
    try buf.appendSlice(gpa, "}, \"records\": [");
    var a_first = true;
    for (audit.records) |*rec| {
        if (rec.kind != .poetry) continue;
        if (!audit_mod.recordInScope(audit, rec, opts.collections)) continue;
        const a = rec.alignment orelse continue;
        if (!a_first) try buf.appendSlice(gpa, ",");
        a_first = false;
        try buf.appendSlice(gpa, "\n      {\"id\": ");
        try util.appendJsonString(&buf, gpa, rec.id orelse rec.source_path);
        try buf.appendSlice(gpa, ", \"status\": ");
        try util.appendJsonString(&buf, gpa, a.jsonName());
        try buf.appendSlice(gpa, ", \"owner\": ");
        if (rec.owner) |o| {
            try util.appendJsonString(&buf, gpa, o);
        } else {
            try buf.appendSlice(gpa, "null");
        }
        try buf.appendSlice(gpa, "}");
    }
    try buf.appendSlice(gpa, "\n    ]}");

    // Exceptions (scoped to the collection filter)
    try buf.appendSlice(gpa, ",\n  \"exceptions\": [");
    var e_first = true;
    for (audit.exceptions) |e| {
        if (!audit_mod.recordIdInScope(audit, e.record_id, opts.collections)) continue;
        if (!e_first) try buf.appendSlice(gpa, ",");
        e_first = false;
        try buf.appendSlice(gpa, "\n    {\"kind\": ");
        try util.appendJsonString(&buf, gpa, e.kind);
        try buf.appendSlice(gpa, ", \"severity\": ");
        try util.appendJsonString(&buf, gpa, e.severity.jsonName());
        try buf.appendSlice(gpa, ", \"record_id\": ");
        try util.appendJsonString(&buf, gpa, e.record_id);
        try buf.appendSlice(gpa, ", \"detail\": ");
        try util.appendJsonString(&buf, gpa, e.detail);
        try buf.appendSlice(gpa, "}");
    }
    try buf.appendSlice(gpa, "\n  ]");

    // Per-record results (sorted by canonical id already)
    try buf.appendSlice(gpa, ",\n  \"records\": [");
    var r_first = true;
    for (audit.records) |*rec| {
        if (!audit_mod.recordInScope(audit, rec, opts.collections)) continue;
        if (!r_first) try buf.appendSlice(gpa, ",");
        r_first = false;
        try buf.appendSlice(gpa, "\n    ");
        try appendRecordObject(&buf, gpa, rec, audit);
    }
    try buf.appendSlice(gpa, "\n  ]");

    // Delta
    if (audit.delta) |changes| {
        try buf.appendSlice(gpa, ",\n  \"delta\": {\"present\": true, \"previous_schema_version\": ");
        if (audit.previous_report_schema) |s| {
            try buf.print(gpa, "{d}", .{s});
        } else {
            try buf.appendSlice(gpa, "null");
        }
        try buf.appendSlice(gpa, ", \"previous_policy_digest\": ");
        if (audit.previous_policy_digest) |d| {
            try util.appendJsonString(&buf, gpa, d);
        } else {
            try buf.appendSlice(gpa, "null");
        }
        try buf.appendSlice(gpa, ", \"changes\": [");
        for (changes, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(gpa, ",");
            try buf.appendSlice(gpa, "\n      {\"kind\": ");
            try util.appendJsonString(&buf, gpa, c.kind);
            try buf.appendSlice(gpa, ", \"record_id\": ");
            try util.appendJsonString(&buf, gpa, c.record_id);
            if (c.type_name.len > 0) {
                try buf.appendSlice(gpa, ", \"type\": ");
                try util.appendJsonString(&buf, gpa, c.type_name);
            }
            if (c.from.len > 0 or c.to.len > 0) {
                try buf.appendSlice(gpa, ", \"from\": ");
                try util.appendJsonString(&buf, gpa, c.from);
                try buf.appendSlice(gpa, ", \"to\": ");
                try util.appendJsonString(&buf, gpa, c.to);
            }
            try buf.appendSlice(gpa, "}");
        }
        try buf.appendSlice(gpa, "\n    ]}");
    } else {
        try buf.appendSlice(gpa, ",\n  \"delta\": null");
    }

    try buf.appendSlice(gpa, "\n}\n");
    return try buf.toOwnedSlice(gpa);
}

fn appendIdArray(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, ids: []const []const u8) !void {
    try buf.append(gpa, '[');
    for (ids, 0..) |id, i| {
        if (i > 0) try buf.appendSlice(gpa, ", ");
        try util.appendJsonString(buf, gpa, id);
    }
    try buf.appendSlice(gpa, "]");
}
