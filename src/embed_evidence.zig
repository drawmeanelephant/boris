//! In-memory publication evidence for `compileBundle` (#301 M6).
//!
//! Builds the target-local chain (artifacts → checks → claims → touches)
//! from sink records. Memory adapters do not open a host directory.
//! Proof Pack presentation is not emitted.

const std = @import("std");
const artifact_inventory = @import("artifact_inventory.zig");
const artifact_sink = @import("artifact_sink.zig");
const publication_checks = @import("publication_checks.zig");
const publication_claims = @import("publication_claims.zig");
const publication_touches = @import("publication_touches.zig");
const search_index = @import("search_index.zig");
const source_provider = @import("source_provider.zig");

pub const target_name = "default";

const ir_artifact_names = [_][]const u8{
    "manifest.json",
    "graph.json",
    "completion.json",
    "build-report.json",
};

fn isReserved(path: []const u8) bool {
    for (artifact_inventory.reserved_paths) |reserved| {
        if (std.mem.eql(u8, path, reserved)) return true;
    }
    return false;
}

fn isIrArtifact(path: []const u8) bool {
    for (ir_artifact_names) |name| {
        if (std.mem.eql(u8, path, name)) return true;
    }
    return false;
}

fn isThemeAssetPath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/assets/") != null or std.mem.startsWith(u8, path, "assets/");
}

fn classify(path: []const u8) ?artifact_inventory.Kind {
    if (isReserved(path) or isIrArtifact(path)) return null;
    if (std.mem.eql(u8, path, search_index.output_path)) return .rendered_search;
    if (source_provider.isUnderAssetsTree(path)) return .content_asset;
    if (isThemeAssetPath(path)) return .theme_asset;
    if (std.mem.endsWith(u8, path, ".html")) return .html_page;
    return null;
}

fn formatVersion(kind: artifact_inventory.Kind) ?[]const u8 {
    return switch (kind) {
        .rendered_search, .sitemap, .rss, .llms => "1",
        else => null,
    };
}

/// Emit artifacts/checks/claims/touches into `sink` from the payload records
/// already present there. Failed callers must not invoke this.
pub fn emit(gpa: std.mem.Allocator, sink: *artifact_sink.Memory) !void {
    var specs: std.ArrayList(artifact_inventory.PayloadSpec) = .empty;
    defer specs.deinit(gpa);
    var check_payloads: std.ArrayList(publication_checks.Payload) = .empty;
    defer check_payloads.deinit(gpa);

    for (sink.items()) |rec| {
        const kind = classify(rec.path) orelse continue;
        try specs.append(gpa, .{
            .spec = .{
                .path = rec.path,
                .kind = kind,
                .producer = kind.producerName(),
                .required = true,
                .format_version = formatVersion(kind),
            },
            .bytes = rec.bytes,
        });
        try check_payloads.append(gpa, .{ .path = rec.path, .bytes = rec.bytes });
    }

    var inventory = try artifact_inventory.collectFromPayloads(gpa, target_name, specs.items);
    defer inventory.deinit();
    const artifacts_json = try artifact_inventory.render(gpa, &inventory);
    defer gpa.free(artifacts_json);
    try sink.emit(artifact_inventory.output_path, artifact_sink.json_media_type, artifacts_json);

    const checks_json = try publication_checks.renderFromPayloads(
        gpa,
        target_name,
        artifacts_json,
        check_payloads.items,
    );
    defer gpa.free(checks_json);
    try sink.emit(publication_checks.output_path, artifact_sink.json_media_type, checks_json);

    const claims_json = try publication_claims.renderFromBytes(
        gpa,
        target_name,
        artifacts_json,
        checks_json,
    );
    defer gpa.free(claims_json);
    try sink.emit(publication_claims.output_path, artifact_sink.json_media_type, claims_json);

    const touches_json = try publication_touches.renderFromBytes(
        gpa,
        target_name,
        artifacts_json,
        checks_json,
        claims_json,
    );
    defer gpa.free(touches_json);
    try sink.emit(publication_touches.output_path, artifact_sink.json_media_type, touches_json);
}
