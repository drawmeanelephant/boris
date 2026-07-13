//! Bounded fuzz / property tests for high-risk parsers and graph validation.
//!
//! ## Properties
//!
//! 1. **Frontmatter parser** never panics; on any byte input (bounded), returns
//!    or records diagnostics without crashing.
//! 2. **Component tokenizer** never panics on valid UTF-8 bodies; invalid UTF-8
//!    yields a clean error.
//! 3. **Apex** never accepts invalid pointer/length contracts (via
//!    `prepareMdForC` / `mapRenderResult`) and never crashes on bounded
//!    random payloads.
//! 4. **Graph topology**: random topologies — `graph.validate` agrees with an
//!    independent simple reference checker on error *categories*.
//!
//! ## Bounds & seeds
//!
//! | Constant | Default | Role |
//! |----------|---------|------|
//! | `default_seed` | `0xB0B15_F027` | Deterministic PRNG seed |
//! | `frontmatter_iters` | 256 | Frontmatter fuzz iterations |
//! | `component_iters` | 256 | Component fuzz iterations |
//! | `apex_iters` | 128 | Apex fuzz iterations |
//! | `graph_iters` | 200 | Random graph topologies |
//! | `max_input_bytes` | 512 | Max random payload size |
//! | `max_graph_nodes` | 12 | Max nodes per random graph |
//!
//! Override seed at the call site by editing `default_seed` or by using
//! `runFrontmatterFuzz(seed, iters)` from a future CLI wrapper. Tests use fixed
//! seeds so CI is reproducible.
//!
//! No concurrency. Resource use is O(iters × max_input_bytes).

const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const aside = @import("aside.zig");
const apex = @import("apex.zig");
const graph_mod = @import("graph.zig");
const diag = @import("diag.zig");

/// Deterministic default seed (document in test/README.md).
/// Deterministic default seed (`BORIS` + `FUZZ` as hex-ish mnemonic: B0B15 / FUZZ).
pub const default_seed: u64 = 0xB0B15_F027;

pub const frontmatter_iters: usize = 256;
pub const component_iters: usize = 256;
pub const apex_iters: usize = 128;
pub const graph_iters: usize = 200;
pub const max_input_bytes: usize = 512;
pub const max_graph_nodes: usize = 12;

// ---------------------------------------------------------------------------
// Frontmatter fuzz
// ---------------------------------------------------------------------------

/// Bounded frontmatter fuzz: never panics; allocator errors may surface as OOM.
pub fn runFrontmatterFuzz(seed: u64, iterations: usize) !void {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    var buf: [max_input_bytes]u8 = undefined;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = arena.reset(.free_all);
        diags.clearRetainingCapacity();
        const retain = arena.allocator();

        const n = random.intRangeAtMost(usize, 0, max_input_bytes);
        random.bytes(buf[0..n]);
        // Mix structured inputs every few iterations for higher signal.
        const payload: []const u8 = if (i % 5 == 0)
            structuredFrontmatter(random, &buf)
        else
            buf[0..n];

        // Content errors become diagnostics; only OOM should error out.
        _ = frontmatter.parse(payload, "fuzz.md", retain, gpa, &diags) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        // Diagnostics must be finite (bounded by grammar).
        try std.testing.expect(diags.items.len < 10_000);
    }
}

fn structuredFrontmatter(random: std.Random, buf: *[max_input_bytes]u8) []const u8 {
    // Produce mostly-valid shapes with occasional corruption.
    const templates = [_][]const u8{
        "---\ntitle: Hello\nparent: a/b\nstatus: draft\ntags: [x, y]\n---\nbody\n",
        "---\ntitle: \"Quoted: value\"\nid: guides/intro\n---\n",
        "---\nfoo: bar\n---\n",
        "---\ntags: [a, b, c\n---\n",
        "---\nstatus: nope\n---\n",
        "---\ntitle: X\n", // unclosed
        "",
        "no fence\n",
        "---\nparent: ..\n---\n",
    };
    const t = templates[random.intRangeLessThan(usize, 0, templates.len)];
    if (t.len > buf.len) return buf[0..0];
    @memcpy(buf[0..t.len], t);
    // Randomly flip a few bytes.
    if (t.len > 0 and random.boolean()) {
        const flips = random.intRangeAtMost(usize, 1, @min(4, t.len));
        var f: usize = 0;
        while (f < flips) : (f += 1) {
            const idx = random.intRangeLessThan(usize, 0, t.len);
            buf[idx] = random.int(u8);
        }
    }
    return buf[0..t.len];
}

test "fuzz: frontmatter parser bounded (deterministic seed)" {
    try runFrontmatterFuzz(default_seed, frontmatter_iters);
}

// ---------------------------------------------------------------------------
// Component tokenizer fuzz
// ---------------------------------------------------------------------------

pub fn runComponentFuzz(seed: u64, iterations: usize) !void {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(seed ^ 0xC0C0);
    const random = prng.random();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: [max_input_bytes]u8 = undefined;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = arena.reset(.free_all);
        const a = arena.allocator();

        const payload: []const u8 = if (i % 4 == 0)
            structuredComponent(random, &buf)
        else blk: {
            // Valid UTF-8 only for the free-form path (tokenizer requires it).
            const n = random.intRangeAtMost(usize, 0, max_input_bytes);
            fillValidUtf8(random, buf[0..n]);
            break :blk buf[0..n];
        };

        // Valid UTF-8: must not crash; may return diagnostics.
        const result = aside.tokenizeBody(payload, a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => {
                // Should not happen when we only emit valid UTF-8.
                try std.testing.expect(false);
                continue;
            },
        };
        _ = result;
    }

    // Explicit invalid UTF-8 path: clean error, no crash.
    const bad = [_]u8{ 0xFF, 0xFE, '<', 'A', 's', 'i', 'd', 'e', '>' };
    try std.testing.expectError(error.InvalidUtf8, aside.tokenizeBody(&bad, arena.allocator()));
}

fn fillValidUtf8(random: std.Random, buf: []u8) void {
    // ASCII + occasional multi-byte UTF-8 (2–3 byte sequences).
    var i: usize = 0;
    while (i < buf.len) {
        const choice = random.intRangeLessThan(u8, 0, 10);
        if (choice < 7) {
            // Printable ASCII or newline/space.
            const c = random.intRangeAtMost(u8, 32, 126);
            buf[i] = if (random.intRangeLessThan(u8, 0, 20) == 0) '\n' else c;
            i += 1;
        } else if (choice < 9 and i + 1 < buf.len) {
            // 2-byte: U+00A0..U+07FF simplified → C2-DF + 80-BF
            buf[i] = random.intRangeAtMost(u8, 0xC2, 0xDF);
            buf[i + 1] = random.intRangeAtMost(u8, 0x80, 0xBF);
            i += 2;
        } else if (i + 2 < buf.len) {
            // 3-byte: E0-EF with valid trailers (conservative).
            buf[i] = 0xE2;
            buf[i + 1] = random.intRangeAtMost(u8, 0x80, 0xBF);
            buf[i + 2] = random.intRangeAtMost(u8, 0x80, 0xBF);
            i += 3;
        } else {
            buf[i] = 'x';
            i += 1;
        }
    }
}

fn structuredComponent(random: std.Random, buf: *[max_input_bytes]u8) []const u8 {
    const templates = [_][]const u8{
        \\Hello
        \\
        \\<Aside kind="tip" id="a1">
        \\Body
        \\</Aside>
        \\
        ,
        \\<Aside kind="note">
        \\x
        \\</Aside>
        ,
        \\<Aside kind="danger" id="bad!">
        \\x
        \\</Aside>
        ,
        \\<Figure>
        \\nope
        \\</Figure>
        ,
        \\<Aside kind="tip">
        \\unterminated
        ,
        \\<Aside kind="tip"><Aside kind="note">
        \\nested
        \\</Aside>
        \\</Aside>
        ,
        \\plain text only
        ,
        \\<Aside kind="banana">
        \\x
        \\</Aside>
        ,
        \\mid-line </Aside> does not close
        \\
        \\<Aside kind="info" id="ok_1">
        \\ok
        \\</Aside>
        ,
    };
    const t = templates[random.intRangeLessThan(usize, 0, templates.len)];
    if (t.len > buf.len) return buf[0..0];
    @memcpy(buf[0..t.len], t);
    if (t.len > 2 and random.intRangeLessThan(u8, 0, 3) == 0) {
        buf[random.intRangeLessThan(usize, 0, t.len)] = random.int(u8) % 128; // keep ASCII-ish
    }
    return buf[0..t.len];
}

test "fuzz: component tokenizer bounded (deterministic seed)" {
    try runComponentFuzz(default_seed, component_iters);
}

// ---------------------------------------------------------------------------
// Apex fuzz — pointer/length contracts + no crash on bounded input
// ---------------------------------------------------------------------------

pub fn runApexFuzz(seed: u64, iterations: usize) !void {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(seed ^ 0xA9E5);
    const random = prng.random();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: [max_input_bytes]u8 = undefined;

    // Contract: empty uses non-null sentinel.
    {
        const prep = try apex.prepareMdForC(&.{});
        try std.testing.expect(@intFromPtr(prep.ptr) != 0);
        try std.testing.expectEqual(@as(usize, 0), prep.len);
    }

    // Contract: mapRenderResult never slices dirty error outputs.
    {
        var poison = [_]u8{ 0xDE, 0xAD };
        try std.testing.expectError(error.OutOfMemory, apex.mapRenderResult(2, &poison, 99));
        try std.testing.expectError(error.RenderFailed, apex.mapRenderResult(1, &poison, 99));
        try std.testing.expectError(error.RenderFailed, apex.mapRenderResult(0, null, 5));
    }

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = arena.reset(.free_all);
        const n = random.intRangeAtMost(usize, 0, max_input_bytes);
        // Apex is byte-oriented; random bytes are allowed.
        random.bytes(buf[0..n]);
        // Occasional structured markdown.
        const md: []const u8 = if (i % 3 == 0) blk: {
            const s = "# H\n\n**b** and *i*\n";
            @memcpy(buf[0..s.len], s);
            break :blk buf[0..s.len];
        } else buf[0..n];

        const prep = try apex.prepareMdForC(md);
        try std.testing.expect(@intFromPtr(prep.ptr) != 0);
        try std.testing.expectEqual(md.len, prep.len);

        // Render must not crash; OOM / RenderFailed are acceptable.
        _ = apex.render(md, &arena) catch |err| switch (err) {
            error.OutOfMemory, error.RenderFailed => {},
        };
    }
}

test "fuzz: apex bounded no-crash + pointer contracts (deterministic seed)" {
    try runApexFuzz(default_seed, apex_iters);
}

// ---------------------------------------------------------------------------
// Random graph topology vs independent reference checker
// ---------------------------------------------------------------------------

/// Independent reference view of topology problems (not the production DFS).
pub const RefProblems = struct {
    dup_id: bool = false,
    self_parent: bool = false,
    missing_parent: bool = false,
    not_trunk: bool = false,
    cycle: bool = false,

    pub fn any(self: RefProblems) bool {
        return self.dup_id or self.self_parent or self.missing_parent or self.not_trunk or self.cycle;
    }
};

/// Simple O(n²) reference checker — deliberately independent of `graph.zig`.
pub fn referenceCheck(nodes: []const graph_mod.Node) RefProblems {
    var p: RefProblems = .{};

    // Duplicate ids.
    for (nodes, 0..) |n, i| {
        for (nodes[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.id, n.id)) {
                p.dup_id = true;
                break;
            }
        }
    }

    // Index by id (first wins).
    // Self / missing / role.
    for (nodes) |n| {
        if (n.parent) |par| {
            if (std.mem.eql(u8, par, n.id)) {
                p.self_parent = true;
                continue;
            }
            var found = false;
            var parent_has_parent = false;
            for (nodes) |cand| {
                if (std.mem.eql(u8, cand.id, par)) {
                    found = true;
                    parent_has_parent = cand.parent != null;
                    break;
                }
            }
            if (!found) {
                p.missing_parent = true;
            } else if (parent_has_parent) {
                // Satellite-of-satellite: parent itself has a parent.
                p.not_trunk = true;
            }
        }
    }

    // Cycles along parent edges (ignore nodes with missing/self already broken).
    // Walk from each node; if we revisit a node in the current walk → cycle.
    for (nodes, 0..) |_, start| {
        var seen: [max_graph_nodes]bool = .{false} ** max_graph_nodes;
        var idx: ?usize = start;
        var steps: usize = 0;
        while (idx) |cur| : (steps += 1) {
            if (steps > nodes.len + 1) {
                p.cycle = true;
                break;
            }
            if (seen[cur]) {
                p.cycle = true;
                break;
            }
            seen[cur] = true;
            const par = nodes[cur].parent orelse break;
            if (std.mem.eql(u8, par, nodes[cur].id)) break; // self handled elsewhere
            idx = findId(nodes, par);
        }
    }

    return p;
}

fn findId(nodes: []const graph_mod.Node, id: []const u8) ?usize {
    for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, id)) return i;
    }
    return null;
}

fn productionProblems(diags: []const diag.Diagnostic) RefProblems {
    var p: RefProblems = .{};
    for (diags) |d| {
        switch (d.code) {
            .EDUPLICATEID => p.dup_id = true,
            .EPARENTSELF => p.self_parent = true,
            .EPARENTMISSING => p.missing_parent = true,
            .EPARENTNOTTRUNK => p.not_trunk = true,
            .EPARENTCYCLE => p.cycle = true,
            else => {},
        }
    }
    return p;
}

/// Generate a random parent graph into `nodes` (ids are static pool slices).
fn generateRandomGraph(
    random: std.Random,
    id_pool: []const []const u8,
    nodes: []graph_mod.Node,
    path_buf: [][]u8,
    gpa: std.mem.Allocator,
) !void {
    const n = nodes.len;
    // Optionally force duplicate ids.
    const force_dup = n >= 2 and random.intRangeLessThan(u8, 0, 8) == 0;

    for (nodes, 0..) |*node, i| {
        const id = if (force_dup and i == n - 1)
            id_pool[0]
        else
            id_pool[i];
        const path = try std.fmt.allocPrint(gpa, "p{d}.md", .{i});
        path_buf[i] = path;
        node.* = .{
            .id = id,
            .source_path = path,
            .title = null,
            .parent = null,
            .status = null,
            .tags = &.{},
            .role = .trunk,
        };
    }

    // Assign parents with various topologies.
    const mode = random.intRangeLessThan(u8, 0, 6);
    switch (mode) {
        0 => {
            // All trunks.
        },
        1 => {
            // Star: all children of node 0 (if unique ids).
            if (n >= 2 and !force_dup) {
                var i: usize = 1;
                while (i < n) : (i += 1) nodes[i].parent = nodes[0].id;
            }
        },
        2 => {
            // Chain 0←1←2←… (satellite-of-satellite for depth>1).
            if (n >= 2 and !force_dup) {
                var i: usize = 1;
                while (i < n) : (i += 1) nodes[i].parent = nodes[i - 1].id;
            }
        },
        3 => {
            // Two-node cycle.
            if (n >= 2 and !force_dup) {
                nodes[0].parent = nodes[1].id;
                nodes[1].parent = nodes[0].id;
            }
        },
        4 => {
            // Self parent on one node.
            if (n >= 1) nodes[random.intRangeLessThan(usize, 0, n)].parent = nodes[0].id; // may fixup
            const si = random.intRangeLessThan(usize, 0, n);
            nodes[si].parent = nodes[si].id;
        },
        else => {
            // Missing parent + random edges.
            if (n >= 1) {
                nodes[random.intRangeLessThan(usize, 0, n)].parent = "does-not-exist";
            }
            if (n >= 2 and !force_dup and random.boolean()) {
                nodes[1].parent = nodes[0].id;
            }
        },
    }
}

pub fn runGraphTopologyFuzz(seed: u64, iterations: usize) !void {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6BA9);
    const random = prng.random();

    // Stable id pool (static strings — no allocation).
    const id_pool = [_][]const u8{
        "n0", "n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8", "n9", "n10", "n11",
    };

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const n = random.intRangeAtMost(usize, 1, max_graph_nodes);
        var nodes: [max_graph_nodes]graph_mod.Node = undefined;
        var path_storage: [max_graph_nodes][]u8 = undefined;
        // Free paths after each iter.
        defer {
            var j: usize = 0;
            while (j < n) : (j += 1) gpa.free(path_storage[j]);
        }

        try generateRandomGraph(random, id_pool[0..], nodes[0..n], path_storage[0..n], gpa);

        const ref = referenceCheck(nodes[0..n]);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const retain = arena.allocator();
        var diags: std.ArrayList(diag.Diagnostic) = .empty;
        defer diags.deinit(gpa);

        // Full validate (dups + topology) — mutates role/parent_index.
        // Work on a copy so reference and production see the same parents/ids.
        var work: [max_graph_nodes]graph_mod.Node = undefined;
        @memcpy(work[0..n], nodes[0..n]);
        try graph_mod.validate(gpa, retain, work[0..n], &diags);
        const prod = productionProblems(diags.items);

        // Agreement on categories. Note: production may report multiple codes;
        // reference is independent. Each flag that is true on one side must be
        // true on the other when the scenario is "pure" — but mixed scenarios
        // (cycle + not_trunk) can both fire. We require bidirectional inclusion
        // of the *primary* structural faults we model.
        try std.testing.expectEqual(ref.dup_id, prod.dup_id);
        try std.testing.expectEqual(ref.self_parent, prod.self_parent);
        try std.testing.expectEqual(ref.missing_parent, prod.missing_parent);

        // not_trunk: production reports E_PARENT_NOT_TRUNK when parent has a parent.
        // Cycles that are also chains may interact; require: if ref.not_trunk and
        // not a pure cycle-only two-node swap, prod should see not_trunk OR cycle.
        if (ref.not_trunk and !ref.cycle) {
            try std.testing.expect(prod.not_trunk);
        }
        if (prod.not_trunk) {
            try std.testing.expect(ref.not_trunk or ref.cycle);
        }

        // Cycles: when ref detects a cycle (and no dups that obscure indexing),
        // production should report E_PARENT_CYCLE unless satellite-of-satellite
        // short-circuits parent_index for multi-hop (still should see not_trunk).
        if (ref.cycle and !ref.dup_id) {
            try std.testing.expect(prod.cycle or prod.not_trunk or prod.self_parent);
        }
        if (prod.cycle) {
            try std.testing.expect(ref.cycle or ref.not_trunk);
        }

        // Healthy star/all-trunk graphs: both sides clean.
        if (!ref.any()) {
            try std.testing.expect(!prod.any());
            try std.testing.expectEqual(@as(usize, 0), diag.countErrors(diags.items));
        }
    }
}

test "fuzz: random graph topology agrees with reference checker" {
    try runGraphTopologyFuzz(default_seed, graph_iters);
}

test "fuzz: reference checker known cases" {
    // Valid trunk + satellite.
    {
        var nodes = [_]graph_mod.Node{
            .{ .id = "t", .source_path = "t.md" },
            .{ .id = "s", .source_path = "s.md", .parent = "t" },
        };
        const p = referenceCheck(&nodes);
        try std.testing.expect(!p.any());
    }
    // Self.
    {
        var nodes = [_]graph_mod.Node{
            .{ .id = "a", .source_path = "a.md", .parent = "a" },
        };
        try std.testing.expect(referenceCheck(&nodes).self_parent);
    }
    // Missing.
    {
        var nodes = [_]graph_mod.Node{
            .{ .id = "a", .source_path = "a.md", .parent = "nope" },
        };
        try std.testing.expect(referenceCheck(&nodes).missing_parent);
    }
    // Cycle.
    {
        var nodes = [_]graph_mod.Node{
            .{ .id = "a", .source_path = "a.md", .parent = "b" },
            .{ .id = "b", .source_path = "b.md", .parent = "a" },
        };
        try std.testing.expect(referenceCheck(&nodes).cycle);
    }
    // Satellite of satellite.
    {
        var nodes = [_]graph_mod.Node{
            .{ .id = "t", .source_path = "t.md" },
            .{ .id = "m", .source_path = "m.md", .parent = "t" },
            .{ .id = "l", .source_path = "l.md", .parent = "m" },
        };
        try std.testing.expect(referenceCheck(&nodes).not_trunk);
    }
    // Dup.
    {
        var nodes = [_]graph_mod.Node{
            .{ .id = "a", .source_path = "a.md" },
            .{ .id = "a", .source_path = "b.md" },
        };
        try std.testing.expect(referenceCheck(&nodes).dup_id);
    }
}

test "fuzz: seeds are stable documented constants" {
    try std.testing.expect(default_seed == 0xB0B15_F027);
    try std.testing.expect(frontmatter_iters > 0);
    try std.testing.expect(max_input_bytes <= 4096);
    try std.testing.expect(max_graph_nodes <= 32);
}
