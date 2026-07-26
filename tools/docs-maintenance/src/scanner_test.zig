const std = @import("std");
const model = @import("model.zig");
const scanner = @import("scanner.zig");
const report = @import("report.zig");

const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: ListWriter, comptime format: []const u8, args: anytype) !void {
        const str = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(str);
        try self.list.appendSlice(self.allocator, str);
    }
};

test "valid repo scan & relationships" {
    const io = std.testing.io;
    var sc = scanner.Scanner.init(std.testing.allocator, .{
        .repo_root = "fixtures/valid_repo",
        .source_root = "src",
        .dossier_root = "docs/boris/src",
    });
    defer sc.deinit();

    const inv = try sc.scan(io);

    // Verification 1: Stable sorting by path
    try std.testing.expect(inv.records.len >= 3);
    for (inv.records[0 .. inv.records.len - 1], 0..) |rec, i| {
        const next_rec = inv.records[i + 1];
        try std.testing.expect(std.mem.order(u8, rec.path, next_rec.path) == .lt);
    }

    // Verification 2: Check alpha.zig has its dossier and beta.zig is the
    // only source without one. This catches claim-path lifetime regressions.
    var has_alpha_claim = false;
    var has_beta_no_dossier = false;
    var has_alpha_no_dossier = false;
    var has_alpha_dossier_without_source = false;
    for (inv.relationships) |rel| {
        if (rel.kind == .source_without_dossier and std.mem.eql(u8, rel.source_path, "src/beta.zig")) {
            has_beta_no_dossier = true;
        }
        if (rel.kind == .source_without_dossier and std.mem.eql(u8, rel.source_path, "src/alpha.zig")) {
            has_alpha_no_dossier = true;
        }
        if (rel.kind == .dossier_without_source and std.mem.eql(u8, rel.source_path, "src/alpha.zig")) {
            has_alpha_dossier_without_source = true;
        }
        if (rel.kind == .duplicate_dossier_claim and std.mem.eql(u8, rel.source_path, "src/alpha.zig")) {
            has_alpha_claim = true;
        }
    }
    try std.testing.expect(has_beta_no_dossier);
    try std.testing.expect(!has_alpha_no_dossier);
    try std.testing.expect(!has_alpha_dossier_without_source);
    try std.testing.expect(!has_alpha_claim);

    // Verification 3: SHA-256 evidence set digest is 64 hex chars
    try std.testing.expectEqual(@as(usize, 64), inv.evidence_set_sha256.len);
}

test "invalid repo marker diagnostics & multi-source claim rejection" {
    const io = std.testing.io;
    var sc = scanner.Scanner.init(std.testing.allocator, .{
        .repo_root = "fixtures/invalid_repo",
        .source_root = "src",
        .dossier_root = "docs/boris/src",
    });
    defer sc.deinit();

    const inv = try sc.scan(io);

    // Should detect EDOSSIER_MARKER and EMULTI_SOURCE_DOSSIER
    var has_mismatch = false;
    var has_unterminated = false;
    var has_multi = false;
    var has_traversal = false;

    for (inv.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "EDOSSIER_MARKER") and std.mem.indexOf(u8, d.message, "match") != null) {
            has_mismatch = true;
        }
        if (std.mem.eql(u8, d.code, "EDOSSIER_MARKER") and std.mem.indexOf(u8, d.message, "unterminated") != null) {
            has_unterminated = true;
        }
        if (std.mem.eql(u8, d.code, "EMULTI_SOURCE_DOSSIER")) {
            has_multi = true;
        }
        if (std.mem.eql(u8, d.code, "EDOSSIER_MARKER") and std.mem.indexOf(u8, d.message, "invalid or absolute") != null) {
            has_traversal = true;
        }
    }

    try std.testing.expect(has_mismatch);
    try std.testing.expect(has_unterminated);
    try std.testing.expect(has_multi);
    try std.testing.expect(has_traversal);
}

test "byte-identical report rendering across repeated runs" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var sc1 = scanner.Scanner.init(gpa, .{
        .repo_root = "fixtures/valid_repo",
        .source_root = "src",
        .dossier_root = "docs/boris/src",
    });
    defer sc1.deinit();
    const inv1 = try sc1.scan(io);

    var buf_json1: std.ArrayList(u8) = .empty;
    defer buf_json1.deinit(gpa);
    try report.writeJsonReport(ListWriter{ .list = &buf_json1, .allocator = gpa }, inv1);

    var buf_md1: std.ArrayList(u8) = .empty;
    defer buf_md1.deinit(gpa);
    try report.writeMarkdownSummary(ListWriter{ .list = &buf_md1, .allocator = gpa }, inv1);

    var sc2 = scanner.Scanner.init(gpa, .{
        .repo_root = "fixtures/valid_repo",
        .source_root = "src",
        .dossier_root = "docs/boris/src",
    });
    defer sc2.deinit();
    const inv2 = try sc2.scan(io);

    var buf_json2: std.ArrayList(u8) = .empty;
    defer buf_json2.deinit(gpa);
    try report.writeJsonReport(ListWriter{ .list = &buf_json2, .allocator = gpa }, inv2);

    var buf_md2: std.ArrayList(u8) = .empty;
    defer buf_md2.deinit(gpa);
    try report.writeMarkdownSummary(ListWriter{ .list = &buf_md2, .allocator = gpa }, inv2);

    // Byte-for-byte exact equality
    try std.testing.expectEqualSlices(u8, buf_json1.items, buf_json2.items);
    try std.testing.expectEqualSlices(u8, buf_md1.items, buf_md2.items);
}

test "evidence digest is invariant under classification rule changes" {
    // Record with fixed path, bytes, sha256
    const rec = model.Record{
        .path = "src/example.zig",
        .kind = .zig_source,
        .bytes = 100,
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".*,
        .has_dossier_marker = false,
    };

    const rec_reclassified = model.Record{
        .path = "src/example.zig",
        .kind = .zig_test, // changed kind
        .bytes = 100,
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".*,
        .has_dossier_marker = true, // changed marker flag
    };

    const digest1 = try scanner.computeEvidenceDigest(&.{rec});
    const digest2 = try scanner.computeEvidenceDigest(&.{rec_reclassified});

    try std.testing.expectEqualSlices(u8, &digest1, &digest2);
}
