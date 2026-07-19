//! Theme materialization laboratory — consume a theme-archaeology ledger and
//! write only the static Boris theme pieces that the ledger proves are safe.
//!
//! This is deliberately report-first. It never executes Astro, JavaScript,
//! MDX, PHP, or a theme build system, and it never modifies the source tree.

const std = @import("std");
const Io = std.Io;
const archaeology = @import("theme_archaeology.zig");

pub const format_id = "boris-theme-materialize-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const Options = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    ledger_path: []const u8,
    quiet: bool = false,
};

const Action = struct {
    source_path: []const u8,
    destination: []const u8,
    category: []const u8,
    decision: []const u8,
    status: []const u8,
    detail: []const u8,
    sha256: []const u8 = "",
};

fn jsonString(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(key) orelse return "";
    return switch (item) {
        .string => |s| s,
        else => "",
    };
}

fn hasSegmentTraversal(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (hasSegmentTraversal(path)) return false;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) return false;
    }
    return true;
}

fn startsWithDecision(decision: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, decision, expected);
}

fn markerPath(proposed: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, proposed, marker) orelse return null;
    const rest = proposed[start..];
    var end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == ' ' or c == ')' or c == '\n' or c == '\r') {
            end = i;
            break;
        }
    }
    if (end == 0) return null;
    return rest[0..end];
}

fn appendJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) !void {
    try buf.append(a, '"');
    for (value) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => {
            if (c < 0x20) {
                var escaped: [6]u8 = undefined;
                const text = std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(a, text);
            } else try buf.append(a, c);
        },
    };
    try buf.append(a, '"');
}

fn ensureParent(io: Io, root: Io.Dir, rel: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

fn writeBytes(io: Io, root: Io.Dir, rel: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel);
    try root.writeFile(io, .{ .sub_path = rel, .data = data });
}

fn readFile(io: Io, root: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
    var file = try root.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(a, .unlimited);
}

fn emitLayout(a: std.mem.Allocator, css_path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <title>{{title}}</title>
    );
    try buf.append(a, '\n');
    if (css_path.len > 0) {
        try buf.appendSlice(a, "  <link rel=\"stylesheet\" href=\"{{asset-url ");
        try buf.appendSlice(a, css_path);
        try buf.appendSlice(a, "}}\">\n");
    }
    try buf.appendSlice(a,
        \\</head>
        \\<body>
        \\  <header><nav aria-label="Primary">{{nav}}</nav></header>
        \\  <div class="breadcrumb">{{breadcrumb}}</div>
        \\  <main>
        \\    <article>{{content}}</article>
        \\    <aside class="toc" aria-label="On this page">{{toc}}</aside>
        \\  </main>
        \\  <section class="children">{{children}}</section>
        \\  <footer>{{footer}}</footer>
        \\</body>
        \\</html>
        \\
    );
    return try buf.toOwnedSlice(a);
}

fn emitManifest(a: std.mem.Allocator, source_root: []const u8, actions: []const Action) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&buf, a, format_id);
    try buf.appendSlice(a, ",\n  \"schema_version\": 1,\n  \"tool_version\": ");
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&buf, a, source_root);
    try buf.appendSlice(a, ",\n  \"actions\": [\n");
    for (actions, 0..) |action, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, action.source_path);
        try buf.appendSlice(a, ", \"destination\": ");
        try appendJson(&buf, a, action.destination);
        try buf.appendSlice(a, ", \"category\": ");
        try appendJson(&buf, a, action.category);
        try buf.appendSlice(a, ", \"decision\": ");
        try appendJson(&buf, a, action.decision);
        try buf.appendSlice(a, ", \"status\": ");
        try appendJson(&buf, a, action.status);
        try buf.appendSlice(a, ", \"detail\": ");
        try appendJson(&buf, a, action.detail);
        try buf.appendSlice(a, ", \"sha256\": ");
        if (action.sha256.len > 0) try appendJson(&buf, a, action.sha256) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, " }");
        if (i + 1 < actions.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReport(a: std.mem.Allocator, actions: []const Action) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a,
        \\# Theme Materialize Report
        \\
        \\This report is deterministic and records every ledger row. Only
        \\proven `preserve` static assets and closed `adapt` layout rows are
        \\materialized. Review and drop rows remain human decisions.
        \\
        \\| Source | Decision | Status | Destination | Detail |
        \\|---|---|---|---|---|
    );
    for (actions) |action| {
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, action.source_path);
        try buf.appendSlice(a, "` | `");
        try buf.appendSlice(a, action.decision);
        try buf.appendSlice(a, "` | `");
        try buf.appendSlice(a, action.status);
        try buf.appendSlice(a, "` | `");
        try buf.appendSlice(a, action.destination);
        try buf.appendSlice(a, "` | ");
        try buf.appendSlice(a, action.detail);
        try buf.appendSlice(a, " |\n");
    }
    return try buf.toOwnedSlice(a);
}

fn emitProvenance(a: std.mem.Allocator, root: []const u8, actions: []const Action) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "# Theme Provenance\n\nSource root: `");
    try buf.appendSlice(a, root);
    try buf.appendSlice(a, "`\n\n| Source | Destination | SHA-256 |\n|---|---|---|\n");
    for (actions) |action| {
        if (!std.mem.eql(u8, action.status, "copied")) continue;
        try buf.appendSlice(a, "| `");
        try buf.appendSlice(a, action.source_path);
        try buf.appendSlice(a, "` | `");
        try buf.appendSlice(a, action.destination);
        try buf.appendSlice(a, "` | `");
        try buf.appendSlice(a, action.sha256);
        try buf.appendSlice(a, "` |\n");
    }
    return try buf.toOwnedSlice(a);
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !void {
    try archaeology.refuseOutputInsideSource(opts.root_dir, opts.out_dir);
    if (!isSafeRelativePath(opts.ledger_path) and opts.ledger_path[0] != '/') return error.UnsafePath;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var source = Io.Dir.cwd().openDir(io, opts.root_dir, .{}) catch return error.SourceNotFound;
    defer source.close(io);
    const ledger_bytes = readFile(io, Io.Dir.cwd(), opts.ledger_path, a) catch return error.LedgerNotFound;
    var parsed = std.json.parseFromSlice(std.json.Value, a, ledger_bytes, .{}) catch return error.InvalidLedger;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidLedger;
    const entries = parsed.value.object.get("entries") orelse return error.InvalidLedger;
    if (entries != .array) return error.InvalidLedger;

    try Io.Dir.cwd().createDirPath(io, opts.out_dir);
    var output = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer output.close(io);
    try output.createDirPath(io, "theme/assets");
    try output.createDirPath(io, "theme/layouts");

    var actions: std.ArrayList(Action) = .empty;
    var destinations: std.ArrayList([]const u8) = .empty;
    var css_path: []const u8 = "";
    var layout_written = false;

    // The archaeology ledger is sorted by source path, not by action. Select
    // the first proven stylesheet before emitting a layout so output does not
    // depend on whether the layout row happens to precede the CSS row.
    for (entries.array.items) |entry| {
        if (!std.mem.eql(u8, jsonString(entry, "category"), "css") or
            !std.mem.eql(u8, jsonString(entry, "decision"), "preserve")) continue;
        if (markerPath(jsonString(entry, "proposed_boris_equivalent"), "theme/assets/")) |candidate| {
            if (isSafeRelativePath(candidate)) {
                css_path = if (std.mem.startsWith(u8, candidate, "theme/")) candidate["theme/".len..] else candidate;
                break;
            }
        }
    }

    for (entries.array.items) |entry| {
        const source_path = jsonString(entry, "source_path");
        const category = jsonString(entry, "category");
        const decision = jsonString(entry, "decision");
        const proposed = jsonString(entry, "proposed_boris_equivalent");
        const recorded_sha = jsonString(entry, "sha256");

        var action = Action{ .source_path = source_path, .destination = "", .category = category, .decision = decision, .status = "skipped", .detail = "reviewed by materialize policy", .sha256 = recorded_sha };
        if (!isSafeRelativePath(source_path)) {
            action.status = "refused";
            action.detail = "unsafe source path";
            try actions.append(a, action);
            continue;
        }

        if (startsWithDecision(decision, "preserve") and
            (std.mem.eql(u8, category, "css") or std.mem.eql(u8, category, "font") or std.mem.eql(u8, category, "image")))
        {
            const destination = markerPath(proposed, "theme/assets/") orelse {
                action.status = "refused";
                action.detail = "preserve asset has no safe theme/assets destination";
                try actions.append(a, action);
                continue;
            };
            if (!isSafeRelativePath(destination)) {
                action.status = "refused";
                action.detail = "unsafe materialized destination";
                try actions.append(a, action);
                continue;
            }
            var duplicate = false;
            for (destinations.items) |existing| {
                if (std.mem.eql(u8, existing, destination)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                action.status = "refused";
                action.detail = "duplicate destination";
                try actions.append(a, action);
                continue;
            }
            const bytes = readFile(io, source, source_path, a) catch {
                action.status = "refused";
                action.detail = "source file unavailable";
                try actions.append(a, action);
                continue;
            };
            const actual_sha = try archaeology.sha256Hex(a, bytes);
            if (recorded_sha.len > 0 and !std.mem.eql(u8, recorded_sha, actual_sha)) {
                action.status = "refused";
                action.detail = "source bytes do not match ledger sha256";
                action.sha256 = actual_sha;
                try actions.append(a, action);
                continue;
            }
            try writeBytes(io, output, destination, bytes);
            action.destination = destination;
            action.status = "copied";
            action.detail = "preserve asset copied byte-for-byte";
            action.sha256 = actual_sha;
            try destinations.append(a, destination);
            if (css_path.len == 0 and std.mem.eql(u8, category, "css")) css_path = destination;
            try actions.append(a, action);
            continue;
        }

        if (std.mem.eql(u8, category, "license") and startsWithDecision(decision, "preserve")) {
            const destination = "theme/LICENSE";
            const bytes = readFile(io, source, source_path, a) catch {
                action.status = "refused";
                action.detail = "license file unavailable";
                try actions.append(a, action);
                continue;
            };
            const actual_sha = try archaeology.sha256Hex(a, bytes);
            try writeBytes(io, output, destination, bytes);
            action.destination = destination;
            action.status = "copied";
            action.detail = "license preserved";
            action.sha256 = actual_sha;
            try actions.append(a, action);
            continue;
        }

        if (std.mem.eql(u8, category, "layout") and startsWithDecision(decision, "adapt")) {
            if (layout_written) {
                action.status = "refused";
                action.detail = "multiple layout rows cannot silently overwrite main.html";
                try actions.append(a, action);
                continue;
            }
            const layout = try emitLayout(a, css_path);
            try writeBytes(io, output, "theme/layouts/main.html", layout);
            action.destination = "theme/layouts/main.html";
            action.status = "generated";
            action.detail = "closed static Boris slot shell; source layout was not executed";
            layout_written = true;
            try actions.append(a, action);
            continue;
        }

        try actions.append(a, action);
    }

    try writeBytes(io, output, "materialize-manifest.json", try emitManifest(a, opts.root_dir, actions.items));
    try writeBytes(io, output, "MATERIALIZE-REPORT.md", try emitReport(a, actions.items));
    try writeBytes(io, output, "PROVENANCE.md", try emitProvenance(a, opts.root_dir, actions.items));

    if (!opts.quiet) std.debug.print("theme-materialize-lab: wrote {s}/theme and reports ({d} ledger rows)\n", .{ opts.out_dir, actions.items.len });
}

test "theme materialize mini fixture is deterministic and source preserving" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-theme-astro";
    const arch = "fixtures/.tmp-theme-materialize-arch";
    const out_a = "fixtures/.tmp-theme-materialize-a";
    const out_b = "fixtures/.tmp-theme-materialize-b";
    Io.Dir.cwd().deleteTree(io, arch) catch {};
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    defer {
        Io.Dir.cwd().deleteTree(io, arch) catch {};
        Io.Dir.cwd().deleteTree(io, out_a) catch {};
        Io.Dir.cwd().deleteTree(io, out_b) catch {};
    }

    try archaeology.run(io, gpa, .{ .root_dir = root, .out_dir = arch, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .ledger_path = arch ++ "/adaptation_ledger.json", .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .ledger_path = arch ++ "/adaptation_ledger.json", .out_dir = out_b, .quiet = true });

    const names = [_][]const u8{ "materialize-manifest.json", "MATERIALIZE-REPORT.md", "PROVENANCE.md", "theme/layouts/main.html", "theme/assets/css/tokens.css", "theme/assets/fonts/site.woff2", "theme/assets/images/logo.svg", "theme/assets/hero.png", "theme/LICENSE" };
    for (names) |name| {
        var da = try Io.Dir.cwd().openDir(io, out_a, .{});
        defer da.close(io);
        const aa = try readFile(io, da, name, gpa);
        defer gpa.free(aa);
        var db = try Io.Dir.cwd().openDir(io, out_b, .{});
        defer db.close(io);
        const bb = try readFile(io, db, name, gpa);
        defer gpa.free(bb);
        try std.testing.expectEqualStrings(aa, bb);
    }
    var layout_dir = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer layout_dir.close(io);
    const layout = try readFile(io, layout_dir, "theme/layouts/main.html", gpa);
    defer gpa.free(layout);
    try std.testing.expect(std.mem.indexOf(u8, layout, "{{content}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout, "{{asset-url") != null);
}

test "theme materialize refuses unsafe ledger paths" {
    try std.testing.expect(!isSafeRelativePath("../escape.css"));
    try std.testing.expect(!isSafeRelativePath("css/..\\escape.css"));
    try std.testing.expect(!isSafeRelativePath("/absolute.css"));
    try std.testing.expect(isSafeRelativePath("public/css/site.css"));
}
