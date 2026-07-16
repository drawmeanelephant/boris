//! Deterministic, read-only graph analysis for Documentation Intelligence.
//!
//! This module deliberately has no CLI, filesystem, HTML, IR, or RAG policy.
//! Callers adapt the frozen pipeline graph into these small value types, then
//! render the returned report in a separately owned product surface.

const std = @import("std");

pub const EndpointType = enum {
    page,
    source,
};

pub const Endpoint = struct {
    type: EndpointType,
    value: []const u8,

    pub fn less(a: Endpoint, b: Endpoint) bool {
        if (a.type != b.type) return @intFromEnum(a.type) < @intFromEnum(b.type);
        return std.mem.order(u8, a.value, b.value) == .lt;
    }

    pub fn eql(a: Endpoint, b: Endpoint) bool {
        return a.type == b.type and std.mem.eql(u8, a.value, b.value);
    }
};

pub const Page = struct {
    id: []const u8,
    parent: ?[]const u8 = null,
};

pub const Edge = struct {
    from: Endpoint,
    to: Endpoint,
    kind: []const u8,
};

pub const FindingCode = enum {
    unreferenced_page,
    fan_in_hotspot,
};

pub const Finding = struct {
    code: FindingCode,
    endpoint: Endpoint,
    count: usize = 0,
};

pub const Summary = struct {
    pages: usize = 0,
    roots: usize = 0,
    satellites: usize = 0,
    source_endpoints: usize = 0,
    unreferenced_pages: usize = 0,
    hotspots: usize = 0,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    summary: Summary,
    findings: std.ArrayListUnmanaged(Finding) = .empty,
    impact: std.ArrayListUnmanaged(Endpoint) = .empty,

    pub fn deinit(self: *Report) void {
        self.findings.deinit(self.allocator);
        self.impact.deinit(self.allocator);
    }
};

pub const Options = struct {
    /// A target with this many incoming edges is reported as a hotspot.
    fan_in_threshold: usize = 0,
    /// If set, return transitive incoming dependents for this endpoint.
    impact: ?Endpoint = null,
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
    var incoming: std.ArrayListUnmanaged(Incoming) = .empty;
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
    }
    report.summary.source_endpoints = known_sources.count();

    // A page is unreferenced only when no incoming reference edge points to it.
    // Parent edges are navigation structure and do not count as references.
    for (pages) |page| {
        const endpoint = Endpoint{ .type = .page, .value = page.id };
        var has_reference = false;
        for (edges) |edge| {
            if (edge.kind.len == 9 and std.mem.eql(u8, edge.kind, "reference") and
                Endpoint.eql(edge.to, endpoint))
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
    output: *std.ArrayListUnmanaged(Endpoint),
) !void {
    var seen: std.ArrayListUnmanaged(Endpoint) = .empty;
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
    if (a.endpoint.eql(b.endpoint)) return @intFromEnum(a.code) < @intFromEnum(b.code);
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
