//! Read-only publication profile listing and Proof Pack presentation.
//!
//! The host discovers existing profile files and forwards a validated
//! `proof-pack.json` summary. It does not invent profiles, run deploys, or
//! treat local evidence as deployment verification.

const std = @import("std");
const Io = std.Io;
const contracts = @import("contracts.zig");

const max_profile_bytes = 262_144;
const max_proof_bytes = 32 * 1024 * 1024;
const max_profiles = 32;

pub const Profile = struct {
    path: []const u8,
};

pub const ProofSummary = struct {
    path: []const u8,
    html_path: ?[]const u8,
    target: []const u8,
    schema_version: []const u8,
    overall_presentation_status: []const u8,
    artifacts_total: u32,
    checks_total: u32,
    findings_total: u32,
    claims_total: u32,
};

pub fn render(allocator: std.mem.Allocator, io: Io, project_root: []const u8) ![]u8 {
    const profiles = try listProfiles(allocator, io, project_root);
    const proof = readProof(allocator, io, project_root) catch |err| switch (err) {
        error.UnsupportedArtifact => return std.json.Stringify.valueAlloc(allocator, .{
            .profiles = profiles,
            .proof = null,
            .proof_status = "unsupported",
        }, .{}),
        else => |other| return other,
    };
    return std.json.Stringify.valueAlloc(allocator, .{
        .profiles = profiles,
        .proof = proof,
        .proof_status = if (proof != null) "ready" else "absent",
    }, .{});
}

pub fn listProfiles(allocator: std.mem.Allocator, io: Io, project_root: []const u8) ![]Profile {
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);

    var profiles: std.ArrayList(Profile) = .empty;
    errdefer profiles.deinit(allocator);
    var saw_boris_json = false;

    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (profiles.items.len >= max_profiles) break;
        if (std.mem.eql(u8, entry.name, "boris.json")) saw_boris_json = true;
        if (isPublicationProfile(allocator, io, root, entry.name)) {
            try profiles.append(allocator, .{ .path = try allocator.dupe(u8, entry.name) });
        }
    }

    if (!saw_boris_json and isFile(io, root, "boris.json")) {
        try profiles.append(allocator, .{ .path = try allocator.dupe(u8, "boris.json") });
    }

    std.mem.sort(Profile, profiles.items, {}, struct {
        fn lessThan(_: void, a: Profile, b: Profile) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return profiles.toOwnedSlice(allocator);
}

fn isPublicationProfile(allocator: std.mem.Allocator, io: Io, root: Io.Dir, name: []const u8) bool {
    var file = root.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    if (stat.kind != .file or stat.size == 0 or stat.size > max_profile_bytes) return false;
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_profile_bytes)) catch return false;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const format = parsed.value.object.get("format") orelse return false;
    const version = parsed.value.object.get("schema_version") orelse return false;
    return format == .string and std.mem.eql(u8, format.string, "boris-publication-profile") and
        version == .integer and version.integer == 1;
}

fn readProof(allocator: std.mem.Allocator, io: Io, project_root: []const u8) !?ProofSummary {
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    var proof_dir = root.openDir(io, "dist/_boris/proof", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer proof_dir.close(io);
    var file = proof_dir.openFile(io, "proof-pack.json", .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |other| return other,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const bytes = try reader.interface.allocRemaining(allocator, .limited(max_proof_bytes));
    var document = contracts.readProofPack(allocator, bytes) catch return error.UnsupportedArtifact;
    defer document.deinit();
    const view = try contracts.extractProofSummary(&document);
    const html_exists = isFile(io, proof_dir, "index.html");
    return .{
        .path = "dist/_boris/proof/proof-pack.json",
        .html_path = if (html_exists) "dist/_boris/proof/index.html" else null,
        .target = try allocator.dupe(u8, view.target),
        .schema_version = try allocator.dupe(u8, document.version),
        .overall_presentation_status = try allocator.dupe(u8, view.overall_presentation_status),
        .artifacts_total = view.artifacts_total,
        .checks_total = view.checks_total,
        .findings_total = view.findings_total,
        .claims_total = view.claims_total,
    };
}

fn isFile(io: Io, dir: Io.Dir, path: []const u8) bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

test "root JSON files with the publication-profile format are listed" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "boris.json", .data =
        \\{"format":"boris-publication-profile","schema_version":1,"input":"content"}
    });
    try temp.dir.writeFile(io, .{ .sub_path = "standard-site.json", .data =
        \\{"format":"boris-publication-profile","schema_version":1,"input":"content","publication":{"target":"standard-site"}}
    });
    try temp.dir.writeFile(io, .{ .sub_path = "notes.json", .data = "{\"hello\":true}\n" });
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);

    const profiles = try listProfiles(allocator, io, path);
    defer {
        for (profiles) |profile| allocator.free(profile.path);
        allocator.free(profiles);
    }
    try std.testing.expectEqual(@as(usize, 2), profiles.len);
    try std.testing.expectEqualStrings("boris.json", profiles[0].path);
    try std.testing.expectEqualStrings("standard-site.json", profiles[1].path);
}

test "conventional boris.json is listed even when it is not yet a profile" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "boris.json", .data = "{}\n" });
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);

    const profiles = try listProfiles(allocator, io, path);
    defer {
        for (profiles) |profile| allocator.free(profile.path);
        allocator.free(profiles);
    }
    try std.testing.expectEqual(@as(usize, 1), profiles.len);
    try std.testing.expectEqualStrings("boris.json", profiles[0].path);
}

test "proof pack summary is the validated artifact, not an editor rewrite" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "dist/_boris/proof");
    try temp.dir.writeFile(io, .{ .sub_path = "dist/_boris/proof/proof-pack.json", .data =
        \\{"format":"boris-publication-proof-pack","schema_version":1,"target":"public","summary":{"artifacts":{"total":2},"checks":{"total":3},"findings":{"total":0},"claims":{"total":3},"overall_presentation_status":"verified"}}
    });
    try temp.dir.writeFile(io, .{ .sub_path = "dist/_boris/proof/index.html", .data = "<html></html>\n" });
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);

    const bytes = try render(allocator, io, path);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const proof = parsed.value.object.get("proof").?.object;
    try std.testing.expectEqualStrings("dist/_boris/proof/proof-pack.json", proof.get("path").?.string);
    try std.testing.expectEqualStrings("dist/_boris/proof/index.html", proof.get("html_path").?.string);
    try std.testing.expectEqualStrings("public", proof.get("target").?.string);
    try std.testing.expectEqualStrings("verified", proof.get("overall_presentation_status").?.string);
    try std.testing.expectEqual(@as(i64, 2), proof.get("artifacts_total").?.integer);
    try std.testing.expectEqualStrings("ready", parsed.value.object.get("proof_status").?.string);
}

test "stale Proof Pack does not drop profile listing" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "boris.json", .data =
        \\{"format":"boris-publication-profile","schema_version":1,"input":"content"}
    });
    try temp.dir.createDirPath(io, "dist/_boris/proof");
    try temp.dir.writeFile(io, .{ .sub_path = "dist/_boris/proof/proof-pack.json", .data = "{\"format\":\"not-a-proof-pack\"}\n" });
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);

    const bytes = try render(allocator, io, path);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("unsupported", parsed.value.object.get("proof_status").?.string);
    try std.testing.expect(parsed.value.object.get("proof").? == .null);
    try std.testing.expectEqualStrings("boris.json", parsed.value.object.get("profiles").?.array.items[0].object.get("path").?.string);
}
