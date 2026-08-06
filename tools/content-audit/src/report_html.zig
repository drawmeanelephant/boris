//! Static HTML report site for boris-content-audit.
//!
//! No JavaScript, no remote assets, no analytics, no network requests.
//! Accessible tables, simple institutional styling, links between pages,
//! canonical record ids as the stable identity. Works from `file://` and
//! GitHub Pages. This site is operational telemetry, not Boris content and
//! not archive canon.

const std = @import("std");
const util = @import("util.zig");
const audit_mod = @import("audit.zig");

pub const EmitOptions = struct {
    collections: []const []const u8 = &.{},
};

const Page = struct {
    name: []const u8,
    title: []const u8,
};

const pages = [_]Page{
    .{ .name = "index.html", .title = "Overview" },
    .{ .name = "coverage.html", .title = "Coverage" },
    .{ .name = "density.html", .title = "Density" },
    .{ .name = "alignment.html", .title = "Alignment" },
    .{ .name = "exceptions.html", .title = "Exceptions" },
    .{ .name = "changes.html", .title = "Changes" },
};

fn isSelected(opts: *const EmitOptions, collection: []const u8) bool {
    if (opts.collections.len == 0) return true;
    for (opts.collections) |c| {
        if (util.eql(c, collection)) return true;
    }
    return false;
}

fn nav(b: *std.ArrayList(u8), gpa: std.mem.Allocator, current: []const u8) !void {
    try b.appendSlice(gpa, "<nav aria-label=\"Report sections\"><ul>");
    for (pages) |p| {
        try b.appendSlice(gpa, "<li>");
        if (util.eql(p.name, current)) {
            try b.appendSlice(gpa, "<span aria-current=\"page\">");
            try util.appendHtmlEscaped(b, gpa, p.title);
            try b.appendSlice(gpa, "</span>");
        } else {
            try b.appendSlice(gpa, "<a href=\"");
            try b.appendSlice(gpa, p.name);
            try b.appendSlice(gpa, "\">");
            try util.appendHtmlEscaped(b, gpa, p.title);
            try b.appendSlice(gpa, "</a>");
        }
        try b.appendSlice(gpa, "</li>");
    }
    try b.appendSlice(gpa, "</ul></nav>");
}

fn pageHeader(b: *std.ArrayList(u8), gpa: std.mem.Allocator, current: []const u8, title: []const u8) !void {
    try b.appendSlice(gpa, "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">");
    try b.appendSlice(gpa, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
    try b.appendSlice(gpa, "<title>");
    try util.appendHtmlEscaped(b, gpa, title);
    try b.appendSlice(gpa, " — Poetry content audit</title>");
    try b.appendSlice(gpa, "<link rel=\"stylesheet\" href=\"audit.css\">");
    try b.appendSlice(gpa, "</head><body><header><h1>Poetry content audit</h1>");
    try nav(b, gpa, current);
    try b.appendSlice(gpa, "</header><main><h2>");
    try util.appendHtmlEscaped(b, gpa, title);
    try b.appendSlice(gpa, "</h2>");
}

fn pageFooter(b: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try b.appendSlice(gpa, "</main><footer><p>Operational telemetry only. Not publication output. The audit never writes to the source content tree.</p></footer></body></html>");
}

pub fn emitAll(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions, site_dir: std.Io.Dir, io: std.Io) !void {
    const index = try emitIndex(gpa, audit, opts);
    defer gpa.free(index);
    try writePage(io, site_dir, "index.html", index);

    const coverage = try emitCoverage(gpa, audit, opts);
    defer gpa.free(coverage);
    try writePage(io, site_dir, "coverage.html", coverage);

    const density = try emitDensity(gpa, audit, opts);
    defer gpa.free(density);
    try writePage(io, site_dir, "density.html", density);

    const alignment = try emitAlignment(gpa, audit, opts);
    defer gpa.free(alignment);
    try writePage(io, site_dir, "alignment.html", alignment);

    const exceptions = try emitExceptions(gpa, audit, opts);
    defer gpa.free(exceptions);
    try writePage(io, site_dir, "exceptions.html", exceptions);

    const changes = try emitChanges(gpa, audit, opts);
    defer gpa.free(changes);
    try writePage(io, site_dir, "changes.html", changes);

    try writePage(io, site_dir, "audit.css", css);
}

fn writePage(io: std.Io, dir: std.Io.Dir, rel: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = rel, .data = data });
}

fn emitIndex(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try pageHeader(&b, gpa, "index.html", "Overview");

    try b.appendSlice(gpa, "<section><table><caption>Run metadata</caption><tbody>");
    try b.print(gpa, "<tr><th scope=\"row\">Tool</th><td><code>{s}</code> (schema {d})</td></tr>", .{ util.format_id, util.report_schema_version });
    try b.print(gpa, "<tr><th scope=\"row\">Mode</th><td>poetry</td></tr>", .{});
    try b.print(gpa, "<tr><th scope=\"row\">Source root label</th><td><code>{s}</code></td></tr>", .{audit.source_root_label});
    if (audit.source_revision) |r| try b.print(gpa, "<tr><th scope=\"row\">Source revision</th><td><code>{s}</code></td></tr>", .{r});
    try b.print(gpa, "<tr><th scope=\"row\">Policy digest</th><td><code>{s}</code></td></tr>", .{audit.policy_digest});
    if (opts.collections.len > 0) {
        try b.appendSlice(gpa, "<tr><th scope=\"row\">Collection filter (scoped)</th><td>");
        for (opts.collections, 0..) |c, i| {
            if (i > 0) try b.appendSlice(gpa, ", ");
            try util.appendHtmlEscaped(&b, gpa, c);
        }
        try b.appendSlice(gpa, " — every total, verse total, coverage row, density figure, alignment count, exception, delta change, and per-record row on this site is restricted to these physical collections</td></tr>");
    } else {
        try b.appendSlice(gpa, "<tr><th scope=\"row\">Scope</th><td>all (whole tree)</td></tr>");
    }
    try b.appendSlice(gpa, "</tbody></table></section>");

    // Totals (scoped to the collection filter)
    var source_count: usize = 0;
    var poetry_count: usize = 0;
    var verse_units: usize = 0;
    var malformed_records: usize = 0;
    var scoped_exceptions: usize = 0;
    var scoped_records: usize = 0;
    for (audit.records) |rec| {
        if (!audit_mod.recordInScope(audit, &rec, opts.collections)) continue;
        scoped_records += 1;
        switch (rec.kind) {
            .source => source_count += 1,
            .poetry => poetry_count += 1,
            .other => {},
        }
        if (rec.malformed_reason != null or rec.unsupported_shape) malformed_records += 1;
        if (rec.verse) |v| verse_units += v.complete_count;
    }
    for (audit.exceptions) |e| {
        if (audit_mod.recordIdInScope(audit, e.record_id, opts.collections)) scoped_exceptions += 1;
    }
    try b.appendSlice(gpa, "<section><table><caption>Totals</caption><thead><tr><th scope=\"col\">Metric</th><th scope=\"col\">Value</th></tr></thead><tbody>");
    try b.print(gpa, "<tr><th scope=\"row\">Records discovered</th><td>{d}</td></tr>", .{scoped_records});
    try b.print(gpa, "<tr><th scope=\"row\">Source records</th><td>{d}</td></tr>", .{source_count});
    try b.print(gpa, "<tr><th scope=\"row\">Poetry records</th><td>{d}</td></tr>", .{poetry_count});
    try b.print(gpa, "<tr><th scope=\"row\">Verse units (complete)</th><td>{d}</td></tr>", .{verse_units});
    try b.print(gpa, "<tr><th scope=\"row\">Malformed records</th><td>{d}</td></tr>", .{malformed_records});
    try b.print(gpa, "<tr><th scope=\"row\">Exceptions</th><td>{d}</td></tr>", .{scoped_exceptions});
    if (audit.delta) |changes| try b.print(gpa, "<tr><th scope=\"row\">Delta changes</th><td>{d}</td></tr>", .{changes.len});
    try b.appendSlice(gpa, "</tbody></table></section>");

    // Coverage snapshot
    var exp: usize = 0;
    var substantive: usize = 0;
    var placeholder_only: usize = 0;
    var missing: usize = 0;
    for (audit.coverage_rows) |*row| {
        if (!isSelected(opts, row.collection)) continue;
        exp += row.expected;
        substantive += row.substantive();
        placeholder_only += row.placeholderOnly();
        missing += row.missing;
    }
    try b.appendSlice(gpa, "<section><table><caption>Coverage snapshot</caption><thead><tr><th scope=\"col\">Coverage</th><th scope=\"col\">Count</th></tr></thead><tbody>");
    try b.print(gpa, "<tr><th scope=\"row\">Expected pairs</th><td>{d}</td></tr>", .{exp});
    try b.print(gpa, "<tr><th scope=\"row\">Substantive</th><td>{d}</td></tr>", .{substantive});
    try b.print(gpa, "<tr><th scope=\"row\">Placeholder-only</th><td>{d}</td></tr>", .{placeholder_only});
    try b.print(gpa, "<tr><th scope=\"row\">Missing</th><td>{d}</td></tr>", .{missing});
    try b.appendSlice(gpa, "</tbody></table></section>");

    try b.appendSlice(gpa, "<p><a href=\"coverage.html\">Full coverage matrix</a> · <a href=\"density.html\">Density</a> · <a href=\"alignment.html\">Alignment</a> · <a href=\"exceptions.html\">Exceptions</a> · <a href=\"changes.html\">Changes</a></p>");
    try pageFooter(&b, gpa);
    return try b.toOwnedSlice(gpa);
}

fn emitCoverage(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try pageHeader(&b, gpa, "coverage.html", "Coverage");

    try b.appendSlice(gpa, "<section><table><caption>Coverage matrix by source collection and poetry type</caption><thead><tr><th scope=\"col\">Collection</th><th scope=\"col\">Type</th><th scope=\"col\">Expected</th><th scope=\"col\">Missing</th><th scope=\"col\">Empty</th><th scope=\"col\">Placeholder</th><th scope=\"col\">Substantive</th><th scope=\"col\">Ambiguous</th><th scope=\"col\">Malformed</th><th scope=\"col\">Structural</th></tr></thead><tbody>");
    for (audit.coverage_rows) |*row| {
        if (!isSelected(opts, row.collection)) continue;
        try b.print(gpa, "<tr><td><code>{s}</code></td><td>{s}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td></tr>", .{
            row.collection,          row.type_name,           row.expected,          row.missing,   row.present_empty,
            row.present_placeholder, row.present_substantive, row.ambiguous_mapping, row.malformed, row.structural(),
        });
    }
    try b.appendSlice(gpa, "</tbody></table></section>");

    try b.appendSlice(gpa, "<p>Structural coverage counts any present class; substantive coverage counts only substantive verse; a placeholder-shaped poem is never reported as substantive.</p>");
    try pageFooter(&b, gpa);
    return try b.toOwnedSlice(gpa);
}

fn emitDensity(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions) ![]u8 {
    const scoped_stats = try audit_mod.typeStatsScoped(audit, gpa, opts.collections);
    defer gpa.free(scoped_stats);
    const scoped_density = try audit_mod.typeDensitiesScoped(audit, gpa, scoped_stats, opts.collections);
    defer gpa.free(scoped_density);
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try pageHeader(&b, gpa, "density.html", "Density");

    for (scoped_density) |td| {
        try b.print(gpa, "<section><h3>{s}</h3>", .{td.type_name});
        if (audit.policy.density_bands.get(td.type_name)) |bands| {
            try b.appendSlice(gpa, "<p>Exact-count bands: ");
            for (bands, 0..) |n, i| {
                if (i > 0) try b.appendSlice(gpa, ", ");
                try b.print(gpa, "<code>{d}</code>", .{n});
            }
            try b.appendSlice(gpa, "</p>");
        }
        try b.appendSlice(gpa, "<table><caption>Distribution</caption><thead><tr><th scope=\"col\">Verse units</th><th scope=\"col\">Records</th></tr></thead><tbody>");
        for (td.distribution) |d| {
            try b.print(gpa, "<tr><td>{d}</td><td>{d}</td></tr>", .{ d.unit_count, d.record_count });
        }
        try b.appendSlice(gpa, "</tbody></table>");
        if (td.lowest.len > 0) {
            try b.print(gpa, "<p>Lowest ({d}): ", .{td.lowest_count});
            for (td.lowest, 0..) |id, i| {
                if (i > 0) try b.appendSlice(gpa, ", ");
                try b.print(gpa, "<code>{s}</code>", .{id});
            }
            try b.print(gpa, "</p><p>Highest ({d}): ", .{td.highest_count});
            for (td.highest, 0..) |id, i| {
                if (i > 0) try b.appendSlice(gpa, ", ");
                try b.print(gpa, "<code>{s}</code>", .{id});
            }
            try b.appendSlice(gpa, "</p>");
        }
        try b.appendSlice(gpa, "</section>");
    }
    try pageFooter(&b, gpa);
    return try b.toOwnedSlice(gpa);
}

fn emitAlignment(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try pageHeader(&b, gpa, "alignment.html", "Alignment");

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
    const names = [_][]const u8{ "mapped", "orphan", "ambiguous", "duplicate_mapping", "mapping_disagreement", "missing_target", "malformed_record", "dead_reference" };
    try b.appendSlice(gpa, "<section><table><caption>Poetry record alignment</caption><thead><tr><th scope=\"col\">Status</th><th scope=\"col\">Count</th></tr></thead><tbody>");
    for (names, 0..) |n, i| {
        try b.print(gpa, "<tr><th scope=\"row\">{s}</th><td>{d}</td></tr>", .{ n, am[i] });
    }
    try b.appendSlice(gpa, "</tbody></table></section>");

    try b.appendSlice(gpa, "<section><table><caption>Poetry records by status</caption><thead><tr><th scope=\"col\">Id</th><th scope=\"col\">Type</th><th scope=\"col\">Status</th><th scope=\"col\">Owner</th></tr></thead><tbody>");
    for (audit.records) |*rec| {
        if (rec.kind != .poetry) continue;
        if (!audit_mod.recordInScope(audit, rec, opts.collections)) continue;
        const a = rec.alignment orelse continue;
        try b.appendSlice(gpa, "<tr><td><code>");
        try util.appendHtmlEscaped(&b, gpa, rec.id orelse rec.source_path);
        try b.appendSlice(gpa, "</code></td><td>");
        try util.appendHtmlEscaped(&b, gpa, rec.poetry_type orelse "");
        try b.appendSlice(gpa, "</td><td>");
        try util.appendHtmlEscaped(&b, gpa, a.jsonName());
        try b.appendSlice(gpa, "</td><td>");
        if (rec.owner) |o| {
            try util.appendHtmlEscaped(&b, gpa, o);
        } else {
            try b.appendSlice(gpa, "—");
        }
        try b.appendSlice(gpa, "</td></tr>");
    }
    try b.appendSlice(gpa, "</tbody></table></section>");
    try pageFooter(&b, gpa);
    return try b.toOwnedSlice(gpa);
}

fn emitExceptions(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try pageHeader(&b, gpa, "exceptions.html", "Exceptions");

    try b.appendSlice(gpa, "<section><table><caption>Exceptions</caption><thead><tr><th scope=\"col\">Kind</th><th scope=\"col\">Severity</th><th scope=\"col\">Record</th><th scope=\"col\">Detail</th></tr></thead><tbody>");
    for (audit.exceptions) |e| {
        if (!audit_mod.recordIdInScope(audit, e.record_id, opts.collections)) continue;
        try b.appendSlice(gpa, "<tr><td><code>");
        try util.appendHtmlEscaped(&b, gpa, e.kind);
        try b.appendSlice(gpa, "</code></td><td>");
        try util.appendHtmlEscaped(&b, gpa, e.severity.jsonName());
        try b.appendSlice(gpa, "</td><td><code>");
        try util.appendHtmlEscaped(&b, gpa, e.record_id);
        try b.appendSlice(gpa, "</code></td><td>");
        try util.appendHtmlEscaped(&b, gpa, e.detail);
        try b.appendSlice(gpa, "</td></tr>");
    }
    try b.appendSlice(gpa, "</tbody></table></section>");
    try pageFooter(&b, gpa);
    return try b.toOwnedSlice(gpa);
}

fn emitChanges(gpa: std.mem.Allocator, audit: *const audit_mod.Audit, opts: *const EmitOptions) ![]u8 {
    _ = opts;
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try pageHeader(&b, gpa, "changes.html", "Changes");

    if (audit.delta) |changes| {
        if (changes.len == 0) {
            try b.appendSlice(gpa, "<p>No changes versus the previous report.</p>");
        } else {
            try b.appendSlice(gpa, "<section><table><caption>Changes vs previous report</caption><thead><tr><th scope=\"col\">Kind</th><th scope=\"col\">Record</th><th scope=\"col\">From</th><th scope=\"col\">To</th></tr></thead><tbody>");
            for (changes) |c| {
                try b.appendSlice(gpa, "<tr><td>");
                try util.appendHtmlEscaped(&b, gpa, c.kind);
                try b.appendSlice(gpa, "</td><td><code>");
                try util.appendHtmlEscaped(&b, gpa, c.record_id);
                try b.appendSlice(gpa, "</code></td><td>");
                try util.appendHtmlEscaped(&b, gpa, c.from);
                try b.appendSlice(gpa, "</td><td>");
                try util.appendHtmlEscaped(&b, gpa, c.to);
                try b.appendSlice(gpa, "</td></tr>");
            }
            try b.appendSlice(gpa, "</tbody></table></section>");
        }
    } else {
        try b.appendSlice(gpa, "<p>No previous report supplied; delta mode not run. Rerun with <code>--previous-report=&lt;report.json&gt;</code>.</p>");
    }
    try pageFooter(&b, gpa);
    return try b.toOwnedSlice(gpa);
}

const css =
    \\:root { color-scheme: light; }
    \\* { box-sizing: border-box; }
    \\body { margin: 0; font-family: system-ui, -apple-system, "Segoe UI", sans-serif; line-height: 1.5; color: #1c2733; background: #f6f8fa; }
    \\header { background: #14222e; color: #eef3f7; padding: 1rem 1.5rem; }
    \\header h1 { margin: 0 0 .5rem; font-size: 1.25rem; }
    \\nav ul { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: .25rem; }
    \\nav a, nav span { display: inline-block; padding: .3rem .7rem; border-radius: 4px; color: #cfe0ee; text-decoration: none; font-size: .9rem; }
    \\nav a:hover { background: #22384a; color: #fff; }
    \\nav span { background: #2c465c; color: #fff; }
    \\main { max-width: 72rem; margin: 0 auto; padding: 1.5rem; }
    \\h2 { border-bottom: 2px solid #d5dee6; padding-bottom: .4rem; margin-top: 1.2rem; }
    \\h3 { margin-top: 1.6rem; }
    \\section { margin: 1.4rem 0; }
    \\table { border-collapse: collapse; width: 100%; margin: .8rem 0; background: #fff; }
    \\caption { text-align: left; font-weight: 600; padding: .4rem .6rem; }
    \\th, td { border: 1px solid #d9e1e8; padding: .4rem .6rem; text-align: left; vertical-align: top; }
    \\thead th { background: #eef2f6; }
    \\tbody tr:nth-child(even) { background: #f8fafc; }
    \\code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .88em; background: #eef1f4; padding: 0 .2rem; border-radius: 3px; }
    \\footer { max-width: 72rem; margin: 2rem auto 0; padding: 1rem 1.5rem; border-top: 1px solid #d5dee6; color: #5a6b7a; font-size: .85rem; }
    \\a { color: #155e8a; }
    \\
;
