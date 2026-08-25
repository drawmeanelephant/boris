const std = @import("std");
const Io = std.Io;
const generator = @import("fixture_generator");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");
const publication_touches = @import("publication_touches.zig");
const publication_proof_pack = @import("publication_proof_pack.zig");
const artifact_inventory = @import("artifact_inventory.zig");

fn readPayload(io: Io, root: Io.Dir, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try root.openFile(io, path, .{});
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    return reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
}

fn fixtureAbsolute(io: Io, allocator: std.mem.Allocator, fixture_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, fixture_path });
}

fn pathExists(io: Io, root: Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

/// Run the full publication evidence chain (checks -> claims -> touches ->
/// proof pack) over a generated fixture, exactly as the coordinator does, and
/// return the committed `proof-pack.json` bytes.
fn deriveProofPack(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_path: []const u8,
    output_relative: []const u8,
) ![]u8 {
    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, output_relative });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);

    try publication_checks.writeAfterCommit(io, allocator, output, "default", .{});
    try publication_claims.writeAfterChecks(io, allocator, output, "default", .{});
    try publication_touches.writeAfterClaims(io, allocator, output, "default", .{});
    try publication_proof_pack.writeAfterTouches(io, allocator, output, "default", .{});
    return readPayload(io, output, allocator, publication_proof_pack.output_path);
}

/// Re-derive only the Proof Pack layer from already-committed evidence. Never
/// re-runs the checks or claims layers, so payload rewrites between calls
/// cannot change the evidence the pack is bound to.
fn deriveProofPackOnly(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_path: []const u8,
    output_relative: []const u8,
) ![]u8 {
    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, output_relative });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);

    try publication_proof_pack.writeAfterTouches(io, allocator, output, "default", .{});
    return readPayload(io, output, allocator, publication_proof_pack.output_path);
}

const ParsedReport = struct {
    parsed: std.json.Parsed(std.json.Value),
    root: std.json.ObjectMap,

    fn init(allocator: std.mem.Allocator, bytes: []const u8) !ParsedReport {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        errdefer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings(publication_proof_pack.report_format, root.get("format").?.string);
        try std.testing.expectEqual(@as(i64, publication_proof_pack.schema_version), root.get("schema_version").?.integer);
        try std.testing.expectEqualStrings("default", root.get("target").?.string);
        return .{ .parsed = parsed, .root = root };
    }

    fn deinit(self: *ParsedReport) void {
        self.parsed.deinit();
    }
};

fn nodeCount(root: std.json.ObjectMap) usize {
    return root.get("relationships").?.object.get("node_ids").?.array.items.len;
}

fn edgeCount(root: std.json.ObjectMap) usize {
    var total: usize = 0;
    for (root.get("relationships").?.object.get("groups").?.array.items) |group| {
        total += group.object.get("edges").?.array.items.len;
    }
    return total;
}

fn overallStatus(root: std.json.ObjectMap) []const u8 {
    return root.get("presentation").?.object.get("overall_status").?.string;
}

/// The exact committed bytes of the poisoned fixture's `proof-pack.json`
/// emitted by this first Proof Pack implementation (PR #299). The golden pins
/// the full report bytes and their SHA-256; a byte change is a breaking
/// presentation change and must be deliberate.
/// Re-pinned for #778: code-span word boundaries in `search-index.json`
/// (an inventoried artifact) shift every downstream evidence digest.
const poisoned_golden_sha256 = "5bd019e5e67b757a4e95abeb67b37450ce28dbf880b3b8a66a990271a244bec5";
const poisoned_golden_len: usize = 50427;

test "poisoned publication derives a deterministic Proof Pack with findings" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-proof-pack-poison",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    const barbs = [_][]const u8{ "html_missing_local_route", "artifact_digest_mismatch", "deployment_owned_extra" };
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &barbs,
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });

    const pack = try deriveProofPack(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(pack);
    var report = try ParsedReport.init(allocator, pack);
    defer report.deinit();
    const root = report.root;

    // A poisoned fixture must surface as attention-required with findings.
    try std.testing.expectEqualStrings("attention-required", overallStatus(root));
    const findings = root.get("findings").?.array.items;
    try std.testing.expect(findings.len > 0);
    // Relationship edge groups cover all six kinds with real edges.
    const groups = root.get("relationships").?.object.get("groups").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), groups.len);
    try std.testing.expect(edgeCount(root) > 0);
    try std.testing.expect(nodeCount(root) > 0);
}

test "clean republish derives a verified Proof Pack with no findings" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const clean_fixture = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-proof-pack-clean",
        .{tmp.sub_path},
    );
    defer allocator.free(clean_fixture);
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = clean_fixture,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = clean_fixture,
        .boris_path = "./zig-out/bin/boris",
    });
    try generator.republishCleanFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = clean_fixture,
        .boris_path = "./zig-out/bin/boris",
    });

    const pack = try deriveProofPack(io, allocator, clean_fixture, "results/republish-clean-output");
    defer allocator.free(pack);
    var report = try ParsedReport.init(allocator, pack);
    defer report.deinit();
    const root = report.root;
    try std.testing.expectEqualStrings("verified", overallStatus(root));
    try std.testing.expectEqual(@as(usize, 0), root.get("findings").?.array.items.len);
    // The fixed three checks, three claims, and six limitations always render.
    try std.testing.expectEqual(@as(usize, 3), root.get("checks").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), root.get("claims").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 6), root.get("limitations").?.array.items.len);
    // Summary presentation status agrees exactly with the model's status.
    try std.testing.expectEqualStrings(
        overallStatus(root),
        root.get("summary").?.object.get("overall_presentation_status").?.string,
    );
}

test "jobs 1 and 4 produce byte-identical proof packs; repeat runs are byte-identical" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-proof-pack-jobs",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
        .jobs = 1,
    });

    const pack_j1 = try deriveProofPack(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(pack_j1);
    const pack_j1_again = try deriveProofPack(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(pack_j1_again);
    try std.testing.expectEqualSlices(u8, pack_j1, pack_j1_again);

    const jobs4_fixture = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-proof-pack-jobs4",
        .{tmp.sub_path},
    );
    defer allocator.free(jobs4_fixture);
    var generated4 = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = jobs4_fixture,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated4.assignments);
        generated4.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = jobs4_fixture,
        .boris_path = "./zig-out/bin/boris",
        .jobs = 4,
    });
    const pack_j4 = try deriveProofPack(io, allocator, jobs4_fixture, "results/boris-output");
    defer allocator.free(pack_j4);
    try std.testing.expectEqualSlices(u8, pack_j1, pack_j4);
}

// The HTML's embedded `proof-pack-sha256` meta digest must be the SHA-256 of
// the exact committed `proof-pack.json` bytes.
test "HTML embeds a digest matching the exact committed JSON bytes" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-proof-pack-digest",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });

    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, "results/boris-output" });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);
    try publication_checks.writeAfterCommit(io, allocator, output, "default", .{});
    try publication_claims.writeAfterChecks(io, allocator, output, "default", .{});
    try publication_touches.writeAfterClaims(io, allocator, output, "default", .{});
    try publication_proof_pack.writeAfterTouches(io, allocator, output, "default", .{});

    const json_bytes = try readPayload(io, output, allocator, publication_proof_pack.output_path);
    defer allocator.free(json_bytes);
    const html_bytes = try readPayload(io, output, allocator, publication_proof_pack.index_output_path);
    defer allocator.free(html_bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, &hex) != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "<meta name=\"proof-pack-sha256\" content=\"") != null);
}

// Negative control: the Proof Pack layer must never reread publication
// payloads. Rewriting a committed payload byte-for-byte after a first
// derivation must leave the already-derived pack untouched; only the four
// evidence reports feed the presentation layer.
test "no payload reread: rewriting payload bytes leaves the prior Proof Pack untouched" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-proof-pack-no-payload-reread",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &.{},
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });

    const first = try deriveProofPack(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(first);

    // Corrupt the committed index.html payload between derivations. The Proof
    // Pack layer derives only from evidence bytes, so re-deriving it alone
    // (never re-running the checks layer, which legitimately audits payloads)
    // must produce byte-identical output.
    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, "results/boris-output" });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);
    const page = try readPayload(io, output, allocator, "index.html");
    defer allocator.free(page);
    const mutated = try std.mem.concat(allocator, u8, &.{ page, "\n<!-- tampered after publication -->" });
    defer allocator.free(mutated);
    try output.writeFile(io, .{ .sub_path = "index.html", .data = mutated });

    const second = try deriveProofPackOnly(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
}

test "proof pack golden emission is byte-stable against the committed golden" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-proof-pack-golden",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    const barbs = [_][]const u8{ "html_missing_local_route", "artifact_digest_mismatch", "deployment_owned_extra" };
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &barbs,
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });

    const pack = try deriveProofPack(io, allocator, fixture_path, "results/boris-output");
    defer allocator.free(pack);
    if (poisoned_golden_len == 0) return; // golden not yet pinned
    try std.testing.expectEqual(poisoned_golden_len, pack.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pack, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(poisoned_golden_sha256, &hex);
}

fn countHtmlNeedle(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |at| {
        count += 1;
        pos = at + needle.len;
    }
    return count;
}

fn htmlFixtureSection(allocator: std.mem.Allocator, html: []const u8, anchor: []const u8) ?[]const u8 {
    const start_marker = std.fmt.allocPrint(allocator, "<section id=\"{s}\">", .{anchor}) catch return null;
    defer allocator.free(start_marker);
    const start = std.mem.indexOf(u8, html, start_marker) orelse return null;
    const content_start = start + start_marker.len;
    const next = std.mem.indexOf(u8, html[content_start..], "<section id=\"") orelse
        return html[content_start..];
    return html[content_start .. content_start + next];
}

// The generated poisoned fixture's HTML must follow the reading order, keep
// every stable anchor and nav link, use <details> only for the artifact
// inventory and relationship areas, keep the six edge kinds with their
// explanations, expose closed <details> content in print, and stay free of
// scripts and remote resources. The JSON bytes are pinned separately by the
// golden test above.
test "poisoned fixture HTML presentation follows reading order with details, print disclosure, and no scripts" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/publication-proof-pack-html-presentation",
        .{tmp.sub_path},
    );
    defer allocator.free(fixture_path);
    const barbs = [_][]const u8{ "html_missing_local_route", "artifact_digest_mismatch", "deployment_owned_extra" };
    var generated = try generator.generate(.{
        .io = io,
        .allocator = allocator,
        .output_path = fixture_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "mild-poison-v1",
        .barb_names = &barbs,
    });
    defer {
        allocator.free(generated.assignments);
        generated.profile.deinit(allocator);
    }
    try generator.runFixture(.{
        .io = io,
        .allocator = allocator,
        .fixture_path = fixture_path,
        .boris_path = "./zig-out/bin/boris",
    });

    const absolute = try fixtureAbsolute(io, allocator, fixture_path);
    defer allocator.free(absolute);
    const output_absolute = try std.fs.path.join(allocator, &.{ absolute, "results/boris-output" });
    defer allocator.free(output_absolute);
    var output = try Io.Dir.openDirAbsolute(io, output_absolute, .{});
    defer output.close(io);
    try publication_checks.writeAfterCommit(io, allocator, output, "default", .{});
    try publication_claims.writeAfterChecks(io, allocator, output, "default", .{});
    try publication_touches.writeAfterClaims(io, allocator, output, "default", .{});
    try publication_proof_pack.writeAfterTouches(io, allocator, output, "default", .{});

    const json_bytes = try readPayload(io, output, allocator, publication_proof_pack.output_path);
    defer allocator.free(json_bytes);
    const html_bytes = try readPayload(io, output, allocator, publication_proof_pack.index_output_path);
    defer allocator.free(html_bytes);

    // The JSON presentation model bytes stay exactly unchanged (the golden
    // test pins the same digest); the HTML is a pure presentation layer.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(poisoned_golden_sha256, &hex);

    // Every stable anchor and nav link, in the required reading order.
    const order = [_][]const u8{
        "summary", "claims", "limitations", "findings", "checks", "artifacts", "relationships", "inputs",
    };
    for (order) |anchor| {
        const section_marker = try std.fmt.allocPrint(allocator, "<section id=\"{s}\">", .{anchor});
        defer allocator.free(section_marker);
        try std.testing.expectEqual(@as(usize, 1), countHtmlNeedle(html_bytes, section_marker));
        const href = try std.fmt.allocPrint(allocator, "href=\"#{s}\"", .{anchor});
        defer allocator.free(href);
        try std.testing.expect(std.mem.indexOf(u8, html_bytes, href) != null);
    }
    // Section order inside <main> matches the reading order.
    const main_start = std.mem.indexOf(u8, html_bytes, "<main>") orelse return error.MissingMain;
    var section_pos: usize = main_start;
    for (order) |anchor| {
        const section_marker = try std.fmt.allocPrint(allocator, "<section id=\"{s}\">", .{anchor});
        defer allocator.free(section_marker);
        const at = std.mem.indexOfPos(u8, html_bytes, section_pos, section_marker) orelse
            return error.MissingSection;
        try std.testing.expect(at >= section_pos);
        section_pos = at + section_marker.len;
    }

    // Claims, limitations, findings, checks, summary, and inputs stay fully
    // visible; only artifacts and relationships collapse behind <details>.
    const always_visible = [_][]const u8{ "summary", "claims", "limitations", "findings", "checks", "inputs" };
    for (always_visible) |anchor| {
        const section = htmlFixtureSection(allocator, html_bytes, anchor) orelse return error.MissingSection;
        try std.testing.expect(std.mem.indexOf(u8, section, "<details") == null);
    }
    const artifacts = htmlFixtureSection(allocator, html_bytes, "artifacts") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(usize, 1), countHtmlNeedle(artifacts, "<details>"));
    const relationships = htmlFixtureSection(allocator, html_bytes, "relationships") orelse return error.MissingSection;
    try std.testing.expectEqual(@as(usize, 7), countHtmlNeedle(relationships, "<details>"));

    // The six exact edge-kind strings and their explanations remain present.
    const kinds = [_][]const u8{
        "target-owns-artifact",
        "artifact-subject-of-check",
        "artifact-supports-check",
        "check-reported-finding",
        "check-supports-claim",
        "claim-limited-by",
    };
    const explanations = [_][]const u8{
        "The target includes this artifact inventory record.",
        "The artifact is part of the check's declared subject scope.",
        "The artifact is supporting evidence used by the check.",
        "The finding was reported by this check.",
        "The claim is bound to evidence from this check. This does not imply the check passed.",
        "The limitation restricts the scope of this claim.",
    };
    for (kinds) |kind| {
        try std.testing.expect(std.mem.indexOf(u8, html_bytes, kind) != null);
    }
    for (explanations) |explanation| {
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(allocator);
        for (explanation) |byte| switch (byte) {
            '&' => try escaped.appendSlice(allocator, "&amp;"),
            '<' => try escaped.appendSlice(allocator, "&lt;"),
            '>' => try escaped.appendSlice(allocator, "&gt;"),
            '"' => try escaped.appendSlice(allocator, "&quot;"),
            '\'' => try escaped.appendSlice(allocator, "&#39;"),
            else => try escaped.append(allocator, byte),
        };
        try std.testing.expect(std.mem.indexOf(u8, html_bytes, escaped.items) != null);
    }

    // No scripts and no remote resources.
    const forbidden = [_][]const u8{ "<script", "http://", "https://", "@import", "url(", "<img", "src=", "onerror", "onload" };
    for (forbidden) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, html_bytes, needle) == null);
    }

    // Print rules explicitly expose the content of closed <details> elements.
    const style_start = std.mem.indexOf(u8, html_bytes, "<style>") orelse return error.MissingStyle;
    const style_end = std.mem.indexOf(u8, html_bytes, "</style>") orelse return error.MissingStyleEnd;
    const css = html_bytes[style_start .. style_end + "</style>".len];
    const print_at = std.mem.indexOf(u8, css, "@media print") orelse return error.MissingPrintRule;
    const print_css = css[print_at..];
    try std.testing.expect(std.mem.indexOf(u8, print_css, "details::details-content") != null);
    try std.testing.expect(std.mem.indexOf(u8, print_css, "content-visibility: visible !important") != null);
    try std.testing.expect(std.mem.indexOf(u8, print_css, "details > :not(summary)") != null);
    try std.testing.expect(std.mem.indexOf(u8, print_css, "display: block !important") != null);
    try std.testing.expect(std.mem.indexOf(u8, print_css, ".table-wrap { overflow: visible; }") != null);
}
