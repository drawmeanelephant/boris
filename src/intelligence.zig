//! Deterministic, read-only graph analysis for Documentation Intelligence.
//!
//! This module deliberately has no CLI, filesystem, HTML, IR, or RAG policy.
//! Callers adapt the frozen pipeline graph into these small value types, then
//! render the returned report in a separately owned product surface.

const std = @import("std");
const rss_date = @import("rss_date.zig");

pub const EndpointType = enum {
    page,
    source,
    /// Findings that describe the whole corpus rather than one node carry
    /// this endpoint type. Edges and impact results never use it.
    graph,
};

pub const Endpoint = struct {
    type: EndpointType,
    value: []const u8,

    pub fn less(a: Endpoint, b: Endpoint) bool {
        if (a.type != b.type) return @backingInt(a.type) < @backingInt(b.type);
        return std.mem.order(u8, a.value, b.value) == .lt;
    }

    pub fn eql(a: Endpoint, b: Endpoint) bool {
        return a.type == b.type and std.mem.eql(u8, a.value, b.value);
    }
};

pub const Page = struct {
    id: []const u8,
    parent: ?[]const u8 = null,
    /// Content-root source path (e.g. `"guides/a.md"`). Incoming `include`
    /// edges name this path, so pages without it can never be
    /// include-consumed (#739). Optional for graph-only callers.
    source_path: ?[]const u8 = null,
    /// Frontmatter `status` (`"draft"`, `"published"`, `"archived"`), if set.
    status: ?[]const u8 = null,
    /// Frontmatter `published_at` (`YYYY-MM-DDTHH:MM:SSZ`), if set.
    published_at: ?[]const u8 = null,
};

pub const Edge = struct {
    from: Endpoint,
    to: Endpoint,
    kind: []const u8,
};

pub const FindingCode = enum {
    unreferenced_page,
    fan_in_hotspot,
    unlinked_page,
    flat_graph,
    zero_includes,
    zero_relations,
    draft_page,
    stale_page,
};

/// `flat_graph` fires only once a corpus is large enough for the missing
/// structure to be a signal rather than a stub site (#1023).
pub const flat_graph_min_pages: usize = 2;

/// Corpus-level advisory findings name the whole graph rather than a single
/// endpoint; the value is a fixed token so the report stays deterministic.
pub const corpus_endpoint = Endpoint{ .type = .graph, .value = "corpus" };

pub const Finding = struct {
    code: FindingCode,
    endpoint: Endpoint,
    count: usize = 0,
};

pub const EdgeKindCounts = struct {
    parent: usize = 0,
    include: usize = 0,
    reference: usize = 0,
};

pub const DirectionEdgeCounts = struct {
    pages: EdgeKindCounts = .{},
    sources: EdgeKindCounts = .{},
};

pub const EdgeCounts = struct {
    incoming: DirectionEdgeCounts = .{},
    outgoing: DirectionEdgeCounts = .{},
};

pub const Summary = struct {
    pages: usize = 0,
    roots: usize = 0,
    satellites: usize = 0,
    source_endpoints: usize = 0,
    edge_counts: EdgeCounts = .{},
    unreferenced_pages: usize = 0,
    hotspots: usize = 0,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    summary: Summary,
    findings: std.ArrayList(Finding) = .empty,
    impact: std.ArrayList(Endpoint) = .empty,

    pub fn deinit(self: *Report) void {
        self.findings.deinit(self.allocator);
        self.impact.deinit(self.allocator);
    }
};

pub const FreshnessPolicy = struct {
    /// Explicit UTC reference date (`--as-of YYYY-MM-DD`). Never wall-clock.
    as_of: rss_date.Date,
    /// Maximum allowed age in UTC calendar days (`--max-age-days N`). Pages
    /// strictly older than this threshold emit `stale_page`.
    max_age_days: u32,
};

pub const Options = struct {
    /// A target with this many incoming edges is reported as a hotspot.
    fan_in_threshold: usize = 0,
    /// If set, return transitive incoming dependents for this endpoint.
    impact: ?Endpoint = null,
    /// If set, emit `stale_page` for pages whose `published_at` UTC calendar
    /// date predates `as_of` by strictly more than `max_age_days` (#1163).
    freshness: ?FreshnessPolicy = null,
};

/// Analyze a frozen page/edge snapshot. Inputs remain caller-owned; the report
/// owns only its result arrays and is safe to render after inputs are released
/// only when the caller's endpoint strings outlive the report.
pub fn analyze(
    allocator: std.mem.Allocator,
    pages: []const Page,
    edges: []const Edge,
    options: Options,
) !Report {
    var report = Report{ .allocator = allocator, .summary = .{} };
    errdefer report.deinit();

    report.summary.pages = pages.len;
    for (pages) |page| {
        if (page.parent) |_| {
            report.summary.satellites += 1;
        } else {
            report.summary.roots += 1;
        }
    }

    var known_sources: std.StringHashMapUnmanaged(void) = .empty;
    defer known_sources.deinit(allocator);
    var incoming: std.ArrayList(Incoming) = .empty;
    defer incoming.deinit(allocator);

    for (edges) |edge| {
        const target_index = findIncoming(incoming.items, edge.to);
        if (target_index) |index| {
            incoming.items[index].count += 1;
        } else {
            try incoming.append(allocator, .{ .endpoint = edge.to, .count = 1 });
        }
        if (edge.to.type == .source) {
            const gop = try known_sources.getOrPut(allocator, edge.to.value);
            if (!gop.found_existing) gop.value_ptr.* = {};
        }
        switch (edge.to.type) {
            .page => bumpKind(&report.summary.edge_counts.incoming.pages, edge.kind),
            .source => bumpKind(&report.summary.edge_counts.incoming.sources, edge.kind),
            // Edges never carry corpus endpoints; the type exists for
            // corpus-level findings only.
            .graph => {},
        }
        switch (edge.from.type) {
            .page => bumpKind(&report.summary.edge_counts.outgoing.pages, edge.kind),
            .source => bumpKind(&report.summary.edge_counts.outgoing.sources, edge.kind),
            .graph => {},
        }
    }
    report.summary.source_endpoints = known_sources.count();

    // A page is unreferenced only when no inbound use points to it. Parent
    // edges are navigation structure and do not count. Include composition
    // does count (#739): a fragment consumed by other pages through
    // `{{include}}` is in active use even though no `reference` edge exists,
    // and flagging it as unreferenced was a false positive.
    for (pages) |page| {
        const endpoint = Endpoint{ .type = .page, .value = page.id };
        var has_reference = false;
        for (edges) |edge| {
            const kind_is_reference = edge.kind.len == 9 and std.mem.eql(u8, edge.kind, "reference");
            if (kind_is_reference and edge.to.type == .page and Endpoint.eql(edge.to, endpoint)) {
                has_reference = true;
                break;
            }
            const kind_is_include = edge.kind.len == 7 and std.mem.eql(u8, edge.kind, "include");
            if (kind_is_include and edge.to.type == .source and page.source_path != null and
                std.mem.eql(u8, edge.to.value, page.source_path.?))
            {
                has_reference = true;
                break;
            }
        }
        if (!has_reference) {
            report.summary.unreferenced_pages += 1;
            try report.findings.append(allocator, .{
                .code = .unreferenced_page,
                .endpoint = endpoint,
            });
        }
    }

    // Advisory findings (#1023): facts about a valid-but-flat corpus. A page
    // is unlinked when no edge touches its node in either direction and no
    // include composes its source file — a stronger condition than
    // unreferenced, which only weighs inbound use.
    for (pages) |page| {
        const endpoint = Endpoint{ .type = .page, .value = page.id };
        var linked = false;
        for (edges) |edge| {
            if (Endpoint.eql(edge.from, endpoint) or Endpoint.eql(edge.to, endpoint)) {
                linked = true;
                break;
            }
            const kind_is_include = edge.kind.len == 7 and std.mem.eql(u8, edge.kind, "include");
            if (kind_is_include and edge.to.type == .source and page.source_path != null and
                std.mem.eql(u8, edge.to.value, page.source_path.?))
            {
                linked = true;
                break;
            }
        }
        if (!linked) {
            try report.findings.append(allocator, .{
                .code = .unlinked_page,
                .endpoint = endpoint,
            });
        }
    }

    // Corpus-level advisories. Every edge contributes exactly one incoming
    // count, so the incoming totals measure the closed kind set.
    const inc = report.summary.edge_counts.incoming;
    const include_edges = inc.pages.include + inc.sources.include;
    const reference_edges = inc.pages.reference + inc.sources.reference;
    const parent_edges = inc.pages.parent + inc.sources.parent;
    const total_edges = parent_edges + include_edges + reference_edges;
    if (pages.len > 0) {
        if (include_edges == 0) {
            try report.findings.append(allocator, .{
                .code = .zero_includes,
                .endpoint = corpus_endpoint,
            });
        }
        if (reference_edges == 0) {
            try report.findings.append(allocator, .{
                .code = .zero_relations,
                .endpoint = corpus_endpoint,
            });
        }
        if (pages.len >= flat_graph_min_pages and total_edges == 0) {
            try report.findings.append(allocator, .{
                .code = .flat_graph,
                .endpoint = corpus_endpoint,
                .count = pages.len,
            });
        }
    }

    // Freshness advisory (#1163): surface pages still marked `status: draft`
    // without flagging published, archived, or unset status.
    for (pages) |page| {
        if (page.status) |status| {
            if (std.mem.eql(u8, status, "draft")) {
                try report.findings.append(allocator, .{
                    .code = .draft_page,
                    .endpoint = .{ .type = .page, .value = page.id },
                });
            }
        }
    }

    // Age-based freshness advisory (#1163): surface pages whose `published_at`
    // UTC calendar date predates the caller-declared `--as-of` reference date
    // by strictly more than `max_age_days`. Never consults the wall clock.
    if (options.freshness) |freshness| {
        const as_of_day = rss_date.daysFromCivil(freshness.as_of);
        for (pages) |page| {
            const published_at = page.published_at orelse continue;
            const ts = rss_date.parse(published_at) catch continue;
            const published_day = rss_date.daysFromCivil(.{
                .year = ts.year,
                .month = ts.month,
                .day = ts.day,
            });
            const age_days_signed = as_of_day - published_day;
            if (age_days_signed <= 0) continue;
            const age_days: usize = @intCast(age_days_signed);
            if (age_days > freshness.max_age_days) {
                try report.findings.append(allocator, .{
                    .code = .stale_page,
                    .endpoint = .{ .type = .page, .value = page.id },
                    .count = age_days,
                });
            }
        }
    }

    if (options.fan_in_threshold > 0) {
        for (incoming.items) |entry| {
            if (entry.count >= options.fan_in_threshold) {
                report.summary.hotspots += 1;
                try report.findings.append(allocator, .{
                    .code = .fan_in_hotspot,
                    .endpoint = entry.endpoint,
                    .count = entry.count,
                });
            }
        }
    }

    std.mem.sort(Finding, report.findings.items, {}, lessFinding);
    if (options.impact) |root| {
        try collectImpact(allocator, edges, root, &report.impact);
        std.mem.sort(Endpoint, report.impact.items, {}, lessEndpoint);
    }
    return report;
}

const Incoming = struct { endpoint: Endpoint, count: usize };

/// The kind set is closed by the contract (`parent`, `include`, `reference`);
/// any other kind is a caller bug and counts as nothing.
fn bumpKind(counts: *EdgeKindCounts, kind: []const u8) void {
    if (std.mem.eql(u8, kind, "parent")) {
        counts.parent += 1;
    } else if (std.mem.eql(u8, kind, "include")) {
        counts.include += 1;
    } else if (std.mem.eql(u8, kind, "reference")) {
        counts.reference += 1;
    }
}

fn findIncoming(items: []const Incoming, endpoint: Endpoint) ?usize {
    for (items, 0..) |item, index| {
        if (Endpoint.eql(item.endpoint, endpoint)) return index;
    }
    return null;
}

fn collectImpact(
    allocator: std.mem.Allocator,
    edges: []const Edge,
    root: Endpoint,
    output: *std.ArrayList(Endpoint),
) !void {
    var seen: std.ArrayList(Endpoint) = .empty;
    defer seen.deinit(allocator);
    try seen.append(allocator, root);

    var cursor: usize = 0;
    while (cursor < seen.items.len) : (cursor += 1) {
        const target = seen.items[cursor];
        for (edges) |edge| {
            if (!Endpoint.eql(edge.to, target)) continue;
            if (Endpoint.eql(edge.from, root) or !containsEndpoint(seen.items, edge.from)) {
                if (!containsEndpoint(seen.items, edge.from)) try seen.append(allocator, edge.from);
            }
        }
    }

    for (seen.items) |endpoint| {
        if (!Endpoint.eql(endpoint, root)) try output.append(allocator, endpoint);
    }
}

fn containsEndpoint(items: []const Endpoint, endpoint: Endpoint) bool {
    for (items) |item| if (Endpoint.eql(item, endpoint)) return true;
    return false;
}

fn lessEndpoint(_: void, a: Endpoint, b: Endpoint) bool {
    return Endpoint.less(a, b);
}

fn lessFinding(_: void, a: Finding, b: Finding) bool {
    if (a.endpoint.eql(b.endpoint)) return @backingInt(a.code) < @backingInt(b.code);
    return Endpoint.less(a.endpoint, b.endpoint);
}

test "analysis distinguishes parent edges from reference edges" {
    const pages = [_]Page{
        .{ .id = "index" },
        .{ .id = "guide", .parent = "index" },
    };
    const edges = [_]Edge{
        .{ .from = .{ .type = .page, .value = "guide" }, .to = .{ .type = .page, .value = "index" }, .kind = "parent" },
    };
    var report = try analyze(std.testing.allocator, &pages, &edges, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.summary.unreferenced_pages);
}

test "summary counts incoming and outgoing edges by kind and endpoint class" {
    const pages = [_]Page{
        .{ .id = "index" },
        .{ .id = "guide", .parent = "index" },
    };
    const edges = [_]Edge{
        .{ .from = .{ .type = .page, .value = "guide" }, .to = .{ .type = .page, .value = "index" }, .kind = "parent" },
        .{ .from = .{ .type = .page, .value = "index" }, .to = .{ .type = .page, .value = "guide" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "index" }, .to = .{ .type = .source, .value = "_includes/x.md" }, .kind = "include" },
        .{ .from = .{ .type = .page, .value = "guide" }, .to = .{ .type = .source, .value = "_includes/x.md" }, .kind = "include" },
    };
    var report = try analyze(std.testing.allocator, &pages, &edges, .{});
    defer report.deinit();
    const counts = report.summary.edge_counts;
    try std.testing.expectEqual(@as(usize, 1), counts.incoming.pages.parent);
    try std.testing.expectEqual(@as(usize, 1), counts.incoming.pages.reference);
    try std.testing.expectEqual(@as(usize, 0), counts.incoming.pages.include);
    try std.testing.expectEqual(@as(usize, 0), counts.incoming.sources.parent);
    try std.testing.expectEqual(@as(usize, 2), counts.incoming.sources.include);
    try std.testing.expectEqual(@as(usize, 0), counts.incoming.sources.reference);
    try std.testing.expectEqual(@as(usize, 1), counts.outgoing.pages.parent);
    try std.testing.expectEqual(@as(usize, 2), counts.outgoing.pages.include);
    try std.testing.expectEqual(@as(usize, 1), counts.outgoing.pages.reference);
    try std.testing.expectEqual(@as(usize, 0), counts.outgoing.sources.parent);
    try std.testing.expectEqual(@as(usize, 0), counts.outgoing.sources.include);
    try std.testing.expectEqual(@as(usize, 0), counts.outgoing.sources.reference);
}

test "include composition counts as inbound use, not as unreferenced (#739)" {
    const pages = [_]Page{
        .{ .id = "index" },
        .{ .id = "_includes/exit-codes", .source_path = "_includes/exit-codes.md" },
        .{ .id = "orphan", .source_path = null },
    };
    const edges = [_]Edge{
        // index composes the fragment; nothing references either by wiki-link.
        .{ .from = .{ .type = .page, .value = "index" }, .to = .{ .type = .source, .value = "_includes/exit-codes.md" }, .kind = "include" },
        // A same-valued parent edge must not suppress the finding.
        .{ .from = .{ .type = .page, .value = "x" }, .to = .{ .type = .page, .value = "orphan" }, .kind = "parent" },
    };
    var report = try analyze(std.testing.allocator, &pages, &edges, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.summary.unreferenced_pages);
    // The include-consumed fragment is absent; `index` and `orphan` remain.
    var saw_fragment_finding = false;
    for (report.findings.items) |f| {
        if (std.mem.eql(u8, f.endpoint.value, "_includes/exit-codes")) saw_fragment_finding = true;
    }
    try std.testing.expect(!saw_fragment_finding);
}

test "analysis sorts findings and computes multi-hop impact" {
    const pages = [_]Page{
        .{ .id = "a" },
        .{ .id = "b" },
        .{ .id = "c" },
    };
    const edges = [_]Edge{
        .{ .from = .{ .type = .page, .value = "c" }, .to = .{ .type = .page, .value = "b" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "b" }, .to = .{ .type = .page, .value = "a" }, .kind = "reference" },
    };
    var report = try analyze(std.testing.allocator, &pages, &edges, .{
        .impact = .{ .type = .page, .value = "a" },
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.impact.items.len);
    try std.testing.expectEqualStrings("b", report.impact.items[0].value);
    try std.testing.expectEqualStrings("c", report.impact.items[1].value);
}

test "analysis reports source fan-in hotspots" {
    const edges = [_]Edge{
        .{ .from = .{ .type = .page, .value = "a" }, .to = .{ .type = .source, .value = "includes/x.md" }, .kind = "include" },
        .{ .from = .{ .type = .page, .value = "b" }, .to = .{ .type = .source, .value = "includes/x.md" }, .kind = "include" },
    };
    var report = try analyze(std.testing.allocator, &.{}, &edges, .{ .fan_in_threshold = 2 });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.summary.source_endpoints);
    try std.testing.expectEqual(@as(usize, 1), report.summary.hotspots);
    try std.testing.expectEqual(@as(usize, 2), report.findings.items[0].count);
}

fn countFindings(report: *const Report, code: FindingCode) usize {
    var n: usize = 0;
    for (report.findings.items) |f| {
        if (f.code == code) n += 1;
    }
    return n;
}

test "advisory findings: flat corpus reports flat_graph, unlinked, and zero-feature nudges" {
    const pages = [_]Page{
        .{ .id = "a" },
        .{ .id = "b" },
        .{ .id = "c" },
    };
    var report = try analyze(std.testing.allocator, &pages, &.{}, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 3), countFindings(&report, .unlinked_page));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .flat_graph));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .zero_includes));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .zero_relations));
    for (report.findings.items) |f| {
        if (f.code == .flat_graph or f.code == .zero_includes or f.code == .zero_relations) {
            try std.testing.expectEqual(EndpointType.graph, f.endpoint.type);
            try std.testing.expectEqualStrings("corpus", f.endpoint.value);
        }
        if (f.code == .flat_graph) try std.testing.expectEqual(@as(usize, 3), f.count);
    }
}

test "advisory findings: single page below the flat_graph minimum still reports zero-feature nudges" {
    const pages = [_]Page{
        .{ .id = "solo" },
    };
    var report = try analyze(std.testing.allocator, &pages, &.{}, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), countFindings(&report, .flat_graph));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .unlinked_page));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .zero_includes));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .zero_relations));
}

test "advisory findings: empty corpus reports no advisories" {
    var report = try analyze(std.testing.allocator, &.{}, &.{}, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.findings.items.len);
}

test "advisory findings: unlinked_page is stronger than unreferenced_page" {
    // `hub` has only an outgoing reference: unreferenced (no inbound use) but
    // not unlinked. `stray` touches nothing: both findings fire.
    const pages = [_]Page{
        .{ .id = "hub" },
        .{ .id = "stray" },
        .{ .id = "target" },
    };
    const edges = [_]Edge{
        .{ .from = .{ .type = .page, .value = "hub" }, .to = .{ .type = .page, .value = "target" }, .kind = "reference" },
    };
    var report = try analyze(std.testing.allocator, &pages, &edges, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .unlinked_page));
    try std.testing.expectEqual(@as(usize, 2), countFindings(&report, .unreferenced_page));
    try std.testing.expectEqual(@as(usize, 0), countFindings(&report, .flat_graph));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .zero_includes));
    try std.testing.expectEqual(@as(usize, 0), countFindings(&report, .zero_relations));
    for (report.findings.items) |f| {
        if (f.code == .unlinked_page) try std.testing.expectEqualStrings("stray", f.endpoint.value);
    }
}

test "advisory findings: include consumption links a page without a wiki-link" {
    const pages = [_]Page{
        .{ .id = "index" },
        .{ .id = "_includes/f", .source_path = "_includes/f.md" },
    };
    const edges = [_]Edge{
        .{ .from = .{ .type = .page, .value = "index" }, .to = .{ .type = .source, .value = "_includes/f.md" }, .kind = "include" },
    };
    var report = try analyze(std.testing.allocator, &pages, &edges, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), countFindings(&report, .unlinked_page));
    try std.testing.expectEqual(@as(usize, 0), countFindings(&report, .zero_includes));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&report, .zero_relations));
}

test "advisory findings: draft_page fires only for status draft and sorts deterministically (#1163)" {
    const pages = [_]Page{
        .{ .id = "zeta", .status = "draft" },
        .{ .id = "alpha", .status = "published" },
        .{ .id = "beta", .status = "archived" },
        .{ .id = "gamma", .status = null },
        .{ .id = "delta", .status = "draft" },
    };
    const edges = [_]Edge{
        .{ .from = .{ .type = .page, .value = "alpha" }, .to = .{ .type = .page, .value = "beta" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "alpha" }, .to = .{ .type = .page, .value = "gamma" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "alpha" }, .to = .{ .type = .page, .value = "delta" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "alpha" }, .to = .{ .type = .source, .value = "includes/s.md" }, .kind = "include" },
    };
    var report = try analyze(std.testing.allocator, &pages, &edges, .{});
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), countFindings(&report, .draft_page));
    // Expected deterministic order:
    // 0: alpha -> unreferenced_page
    // 1: delta -> draft_page (referenced by alpha, so only draft_page)
    // 2: zeta  -> unreferenced_page
    // 3: zeta  -> unlinked_page
    // 4: zeta  -> draft_page
    try std.testing.expectEqual(@as(usize, 5), report.findings.items.len);
    try std.testing.expectEqual(FindingCode.unreferenced_page, report.findings.items[0].code);
    try std.testing.expectEqualStrings("alpha", report.findings.items[0].endpoint.value);
    try std.testing.expectEqual(FindingCode.draft_page, report.findings.items[1].code);
    try std.testing.expectEqual(EndpointType.page, report.findings.items[1].endpoint.type);
    try std.testing.expectEqualStrings("delta", report.findings.items[1].endpoint.value);
    try std.testing.expectEqual(@as(usize, 0), report.findings.items[1].count);
    try std.testing.expectEqual(FindingCode.unreferenced_page, report.findings.items[2].code);
    try std.testing.expectEqualStrings("zeta", report.findings.items[2].endpoint.value);
    try std.testing.expectEqual(FindingCode.unlinked_page, report.findings.items[3].code);
    try std.testing.expectEqualStrings("zeta", report.findings.items[3].endpoint.value);
    try std.testing.expectEqual(FindingCode.draft_page, report.findings.items[4].code);
    try std.testing.expectEqualStrings("zeta", report.findings.items[4].endpoint.value);
    try std.testing.expectEqual(@as(usize, 0), report.findings.items[4].count);
}

test "advisory findings: stale_page honors exact day boundary, leap years, undated, and future dates (#1163)" {
    const pages = [_]Page{
        .{ .id = "old", .published_at = "2026-03-02T23:59:59Z" },
        .{ .id = "boundary", .published_at = "2026-03-03T00:00:00Z" },
        .{ .id = "fresh", .published_at = "2026-05-15T12:00:00Z" },
        .{ .id = "future", .published_at = "2026-07-01T00:00:00Z" },
        .{ .id = "undated", .published_at = null },
        .{ .id = "draft-old", .status = "draft", .published_at = "2025-12-31T12:00:00Z" },
    };
    const edges = [_]Edge{
        .{ .from = .{ .type = .page, .value = "undated" }, .to = .{ .type = .page, .value = "old" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "undated" }, .to = .{ .type = .page, .value = "boundary" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "undated" }, .to = .{ .type = .page, .value = "fresh" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "undated" }, .to = .{ .type = .page, .value = "future" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "undated" }, .to = .{ .type = .page, .value = "draft-old" }, .kind = "reference" },
        .{ .from = .{ .type = .page, .value = "undated" }, .to = .{ .type = .source, .value = "includes/s.md" }, .kind = "include" },
    };

    // Without freshness policy, no stale_page findings are emitted.
    var no_policy = try analyze(std.testing.allocator, &pages, &edges, .{});
    defer no_policy.deinit();
    try std.testing.expectEqual(@as(usize, 0), countFindings(&no_policy, .stale_page));
    try std.testing.expectEqual(@as(usize, 1), countFindings(&no_policy, .draft_page));

    // With --as-of 2026-06-01 --max-age-days 90:
    // - old (91 days) -> stale_page (count 91)
    // - boundary (90 days) -> not stale
    // - fresh (17 days), future (-30 days), undated -> not stale
    // - draft-old (152 days, status draft) -> both draft_page and stale_page (count 152)
    var report = try analyze(std.testing.allocator, &pages, &edges, .{
        .freshness = .{
            .as_of = try rss_date.parseDate("2026-06-01"),
            .max_age_days = 90,
        },
    });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), countFindings(&report, .stale_page));
    // Expected deterministic order:
    // 0: draft-old -> draft_page (0)
    // 1: draft-old -> stale_page (152)
    // 2: old       -> stale_page (91)
    // 3: undated   -> unreferenced_page (0)
    try std.testing.expectEqual(@as(usize, 4), report.findings.items.len);
    try std.testing.expectEqual(FindingCode.draft_page, report.findings.items[0].code);
    try std.testing.expectEqualStrings("draft-old", report.findings.items[0].endpoint.value);
    try std.testing.expectEqual(FindingCode.stale_page, report.findings.items[1].code);
    try std.testing.expectEqualStrings("draft-old", report.findings.items[1].endpoint.value);
    try std.testing.expectEqual(@as(usize, 152), report.findings.items[1].count);
    try std.testing.expectEqual(FindingCode.stale_page, report.findings.items[2].code);
    try std.testing.expectEqualStrings("old", report.findings.items[2].endpoint.value);
    try std.testing.expectEqual(@as(usize, 91), report.findings.items[2].count);
    try std.testing.expectEqual(FindingCode.unreferenced_page, report.findings.items[3].code);
    try std.testing.expectEqualStrings("undated", report.findings.items[3].endpoint.value);

    // Leap year vs non-leap year crossing + max_age_days = 0.
    const leap_pages = [_]Page{
        .{ .id = "leap", .published_at = "2024-02-28T00:00:00Z" },
    };
    var leap_exact = try analyze(std.testing.allocator, &leap_pages, &.{}, .{
        .freshness = .{ .as_of = try rss_date.parseDate("2024-03-01"), .max_age_days = 2 },
    });
    defer leap_exact.deinit();
    try std.testing.expectEqual(@as(usize, 0), countFindings(&leap_exact, .stale_page));

    var leap_stale = try analyze(std.testing.allocator, &leap_pages, &.{}, .{
        .freshness = .{ .as_of = try rss_date.parseDate("2024-03-01"), .max_age_days = 1 },
    });
    defer leap_stale.deinit();
    try std.testing.expectEqual(@as(usize, 1), countFindings(&leap_stale, .stale_page));
    for (leap_stale.findings.items) |f| {
        if (f.code == .stale_page) try std.testing.expectEqual(@as(usize, 2), f.count);
    }

    const same_day_pages = [_]Page{
        .{ .id = "today", .published_at = "2026-06-01T00:00:00Z" },
        .{ .id = "yesterday", .published_at = "2026-05-31T23:59:59Z" },
    };
    var zero_max = try analyze(std.testing.allocator, &same_day_pages, &.{}, .{
        .freshness = .{ .as_of = try rss_date.parseDate("2026-06-01"), .max_age_days = 0 },
    });
    defer zero_max.deinit();
    try std.testing.expectEqual(@as(usize, 1), countFindings(&zero_max, .stale_page));
    for (zero_max.findings.items) |f| {
        if (f.code == .stale_page) {
            try std.testing.expectEqualStrings("yesterday", f.endpoint.value);
            try std.testing.expectEqual(@as(usize, 1), f.count);
        }
    }
}
