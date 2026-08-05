//! Markdown report emitter for boris-content-audit.
//!
//! Sections:
//!   1. Executive summary
//!   2. Coverage matrix
//!   3. Structural versus substantive coverage
//!   4. Totals by poetry type
//!   5. Density distribution
//!   6. Lowest-density and highest-density records
//!   7. Placeholder-only records
//!   8. Orphaned poetry
//!   9. Ambiguous and conflicting mappings
//!  10. Missing expected poetry
//!  11. Change summary (when --previous-report is supplied)
//!  12. Reproduction command

const std = @import("std");
const util = @import("util.zig");
const audit_mod = @import("audit.zig");

pub const EmitOptions = struct {
    collections: []const []const u8 = &.{},
    reproduction: []const u8 = "",
};

fn isSelected(opts: *const EmitOptions, collection: []const u8) bool {
    if (opts.collections.len == 0) return true;
    for (opts.collections) |c| {
        if (util.eql(c, collection)) return true;
    }
    return false;
}

pub fn emit(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);

    // 1. Executive summary
    try b.appendSlice(gpa, "# Poetry content audit\n\n");
    try b.print(gpa, "- Tool: `{s}` (schema {d})\n", .{ util.format_id, util.report_schema_version });
    try b.print(gpa, "- Mode: `poetry`\n", .{});
    try b.print(gpa, "- Source root label: `{s}` (content-root relative; absolute host paths never emitted)\n", .{audit.source_root_label});
    if (audit.source_revision) |r| try b.print(gpa, "- Source revision: `{s}`\n", .{r});
    try b.print(gpa, "- Policy digest: `{s}`\n", .{audit.policy_digest});
    if (opts.collections.len > 0) {
        try b.appendSlice(gpa, "- Collection filter: ");
        for (opts.collections, 0..) |c, i| {
            if (i > 0) try b.appendSlice(gpa, ", ");
            try b.appendSlice(gpa, c);
        }
        try b.appendSlice(gpa, "\n");
    }
    try b.appendSlice(gpa, "- This is **operational telemetry**. It is not publication output, does not\n  alter Boris graph semantics, never writes to the source content tree, and a\n  missing poem is not a compiler error.\n\n");

    var source_count: usize = 0;
    var poetry_count: usize = 0;
    var verse_units: usize = 0;
    var malformed_records: usize = 0;
    for (audit.records) |rec| {
        switch (rec.kind) {
            .source => source_count += 1,
            .poetry => poetry_count += 1,
            .other => {},
        }
        if (rec.malformed_reason != null) malformed_records += 1;
        if (rec.verse) |v| verse_units += v.complete_count;
    }
    try b.appendSlice(gpa, "## 1. Executive summary\n\n");
    try b.print(gpa, "| Metric | Value |\n|---|---:|\n", .{});
    try b.print(gpa, "| Records discovered | {d} |\n", .{audit.records.len});
    try b.print(gpa, "| Source records | {d} |\n", .{source_count});
    try b.print(gpa, "| Poetry records | {d} |\n", .{poetry_count});
    try b.print(gpa, "| Verse units (complete) | {d} |\n", .{verse_units});
    try b.print(gpa, "| Malformed records | {d} |\n", .{malformed_records});
    try b.print(gpa, "| Exceptions | {d} |\n", .{audit.exceptions.len});
    if (audit.delta) |changes| {
        try b.print(gpa, "| Delta changes vs previous report | {d} |\n", .{changes.len});
    }
    try b.appendSlice(gpa, "\n");

    // 2. Coverage matrix
    try b.appendSlice(gpa, "## 2. Coverage matrix\n\n");
    try b.appendSlice(gpa, "Classes: `missing`, `present_empty`, `present_placeholder`, `present_substantive`, `ambiguous_mapping`, `malformed`. Structural coverage counts records with any present class; substantive coverage counts only substantive verse; placeholder-only coverage counts only placeholder-shaped poems.\n\n");
    try b.appendSlice(gpa, "| Collection | Type | Expected | Missing | Empty | Placeholder | Substantive | Ambiguous | Malformed | Structural | Substantive % |\n|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|\n");
    for (audit.coverage_rows) |*row| {
        if (!isSelected(opts, row.collection)) continue;
        const pct: f64 = if (row.expected > 0) @as(f64, @floatFromInt(row.substantive())) / @as(f64, @floatFromInt(row.expected)) * 100.0 else 0.0;
        try b.print(gpa, "| {s} | {s} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d:.1}% |\n", .{
            row.collection,          row.type_name,           row.expected,          row.missing,   row.present_empty,
            row.present_placeholder, row.present_substantive, row.ambiguous_mapping, row.malformed, row.structural(),
            pct,
        });
    }
    try b.appendSlice(gpa, "\n");

    // 3. Structural versus substantive
    try b.appendSlice(gpa, "## 3. Structural versus substantive coverage\n\n");
    var exp: usize = 0;
    var structural: usize = 0;
    var substantive: usize = 0;
    var placeholder_only: usize = 0;
    var missing: usize = 0;
    for (audit.coverage_rows) |*row| {
        if (!isSelected(opts, row.collection)) continue;
        exp += row.expected;
        structural += row.structural();
        substantive += row.substantive();
        placeholder_only += row.placeholderOnly();
        missing += row.missing;
    }
    const sp: f64 = if (exp > 0) @as(f64, @floatFromInt(structural)) / @as(f64, @floatFromInt(exp)) * 100.0 else 0.0;
    const sup: f64 = if (exp > 0) @as(f64, @floatFromInt(substantive)) / @as(f64, @floatFromInt(exp)) * 100.0 else 0.0;
    const pp: f64 = if (exp > 0) @as(f64, @floatFromInt(placeholder_only)) / @as(f64, @floatFromInt(exp)) * 100.0 else 0.0;
    const mp: f64 = if (exp > 0) @as(f64, @floatFromInt(missing)) / @as(f64, @floatFromInt(exp)) * 100.0 else 0.0;
    try b.print(gpa, "| Coverage | Count | % of expected |\n|---|---:|---:|\n", .{});
    try b.print(gpa, "| Expected pairs | {d} | 100.0% |\n", .{exp});
    try b.print(gpa, "| Structural (any present) | {d} | {d:.1}% |\n", .{ structural, sp });
    try b.print(gpa, "| Substantive | {d} | {d:.1}% |\n", .{ substantive, sup });
    try b.print(gpa, "| Placeholder-only | {d} | {d:.1}% |\n", .{ placeholder_only, pp });
    try b.print(gpa, "| Missing | {d} | {d:.1}% |\n\n", .{ missing, mp });
    try b.appendSlice(gpa, "A placeholder-shaped poem is never reported as substantive verse.\n\n");

    // 4. Totals by poetry type
    try b.appendSlice(gpa, "## 4. Totals by poetry type\n\n");
    try b.appendSlice(gpa, "| Type | Records | Verse units | Placeholder units | Substantive units | Malformed units |\n|---|---:|---:|---:|---:|---:|\n");
    for (audit.type_stats) |st| {
        try b.print(gpa, "| {s} | {d} | {d} | {d} | {d} | {d} |\n", .{ st.type_name, st.records, st.verse_units, st.placeholder_units, st.substantive_units, st.malformed_units });
    }
    try b.appendSlice(gpa, "\n");

    // 5. Density distribution
    try b.appendSlice(gpa, "## 5. Density distribution\n\n");
    for (audit.type_densities) |td| {
        try b.print(gpa, "### {s}\n\n", .{td.type_name});
        if (audit.policy.density_bands.get(td.type_name)) |bands| {
            try b.appendSlice(gpa, "Policy exact-count bands: `");
            for (bands, 0..) |n, i| {
                if (i > 0) try b.appendSlice(gpa, ", ");
                try b.print(gpa, "{d}", .{n});
            }
            try b.appendSlice(gpa, "`\n\n");
        } else {
            try b.appendSlice(gpa, "No exact-count bands defined for this type.\n\n");
        }
        try b.appendSlice(gpa, "| Verse units | Records |\n|---:|---:|\n");
        for (td.distribution) |d| {
            try b.print(gpa, "| {d} | {d} |\n", .{ d.unit_count, d.record_count });
        }
        try b.appendSlice(gpa, "\n");
    }

    // 6. Lowest/highest density records
    try b.appendSlice(gpa, "## 6. Lowest-density and highest-density records\n\n");
    for (audit.type_densities) |td| {
        if (td.lowest.len == 0) continue;
        try b.print(gpa, "### {s}\n\n", .{td.type_name});
        try b.print(gpa, "Lowest ({d} units): ", .{td.lowest_count});
        try appendIdList(&b, gpa, td.lowest);
        try b.appendSlice(gpa, "\n\n");
        try b.print(gpa, "Highest ({d} units): ", .{td.highest_count});
        try appendIdList(&b, gpa, td.highest);
        try b.appendSlice(gpa, "\n\n");
    }

    // 7. Placeholder-only records
    try b.appendSlice(gpa, "## 7. Placeholder-only records\n\n");
    var ph_found = false;
    for (audit.records) |*rec| {
        if (rec.kind != .poetry) continue;
        if (!isSelected(opts, rec.collection)) continue;
        const v = rec.verse orelse continue;
        if (v.complete_count > 0 and v.substantive_count == 0) {
            ph_found = true;
            try b.print(gpa, "- `{s}` ({s}): {d} placeholder unit(s)\n", .{ rec.id orelse rec.source_path, rec.poetry_type.?, v.complete_count });
        }
    }
    if (!ph_found) try b.appendSlice(gpa, "None.\n");
    try b.appendSlice(gpa, "\n");

    // 8. Orphaned poetry
    try b.appendSlice(gpa, "## 8. Orphaned poetry\n\n");
    var orph_found = false;
    for (audit.records) |*rec| {
        if (rec.kind != .poetry) continue;
        if (!isSelected(opts, rec.collection)) continue;
        if (rec.alignment == .orphan) {
            orph_found = true;
            try b.print(gpa, "- `{s}` ({s})\n", .{ rec.id orelse rec.source_path, rec.poetry_type.? });
        }
    }
    if (!orph_found) try b.appendSlice(gpa, "None.\n");
    try b.appendSlice(gpa, "\n");

    // 9. Ambiguous and conflicting mappings
    try b.appendSlice(gpa, "## 9. Ambiguous and conflicting mappings\n\n");
    var amb_found = false;
    for (audit.records) |*rec| {
        if (rec.kind != .poetry) continue;
        if (!isSelected(opts, rec.collection)) continue;
        if (rec.alignment == .ambiguous or rec.alignment == .duplicate_mapping or rec.alignment == .mapping_disagreement) {
            amb_found = true;
            try b.print(gpa, "- `{s}`: {s}", .{ rec.id orelse rec.source_path, rec.alignment.?.jsonName() });
            if (rec.claims.len > 0) {
                try b.appendSlice(gpa, " (claimed by ");
                for (rec.claims, 0..) |c, i| {
                    if (i > 0) try b.appendSlice(gpa, ", ");
                    try b.print(gpa, "`{s}` via {s}", .{ c.owner_id, c.evidence.jsonName() });
                }
                try b.appendSlice(gpa, ")");
            }
            try b.appendSlice(gpa, "\n");
        }
    }
    if (!amb_found) try b.appendSlice(gpa, "None.\n");
    try b.appendSlice(gpa, "\n");

    // 10. Missing expected poetry
    try b.appendSlice(gpa, "## 10. Missing expected poetry\n\n");
    var miss_found = false;
    for (audit.records) |*rec| {
        if (rec.kind != .source) continue;
        if (!isSelected(opts, rec.collection)) continue;
        for (rec.coverage_types, rec.coverage_classes) |t, cls| {
            if (cls == .missing) {
                miss_found = true;
                try b.print(gpa, "- `{s}` is missing a `{s}`\n", .{ rec.id orelse rec.source_path, t });
            }
        }
    }
    if (!miss_found) try b.appendSlice(gpa, "None.\n");
    try b.appendSlice(gpa, "\n");

    // 11. Change summary
    try b.appendSlice(gpa, "## 11. Change summary\n\n");
    if (audit.delta) |changes| {
        if (changes.len == 0) {
            try b.appendSlice(gpa, "No changes versus the previous report.\n\n");
        } else {
            try b.appendSlice(gpa, "| Kind | Record | From | To |\n|---|---|---|---|\n");
            for (changes) |c| {
                try b.print(gpa, "| {s} | `{s}` | {s} | {s} |\n", .{ c.kind, c.record_id, c.from, c.to });
            }
            try b.appendSlice(gpa, "\n");
        }
    } else {
        try b.appendSlice(gpa, "No previous report supplied; delta mode not run. Rerun with `--previous-report=<report.json>` to compare.\n\n");
    }

    // 12. Reproduction
    try b.appendSlice(gpa, "## 12. Reproduction command\n\n");
    if (opts.reproduction.len > 0) {
        try b.appendSlice(gpa, "```\n");
        try b.appendSlice(gpa, opts.reproduction);
        try b.appendSlice(gpa, "\n```\n\n");
    } else {
        try b.appendSlice(gpa, "Re-run the audit with the same flags used to produce this report; see the tool README.\n\n");
    }

    try b.appendSlice(gpa, "---\n*Generated by `boris-content-audit` — read-only telemetry. Source content was not modified.*\n");
    return try b.toOwnedSlice(gpa);
}

fn appendIdList(b: *std.ArrayList(u8), gpa: std.mem.Allocator, ids: []const []const u8) !void {
    for (ids, 0..) |id, i| {
        if (i > 0) try b.appendSlice(gpa, ", ");
        try b.print(gpa, "`{s}`", .{id});
    }
}
