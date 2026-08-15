//! Standard.site web-facing verification emission (#475).
//!
//! Turns the offline projection's deterministic verification surfaces into the
//! web-facing artifacts a normal Boris build emits with no network or OAuth:
//! per-document `<link rel="site.standard.document">` head tags (plus the
//! optional `site.standard.publication` discovery hint), the
//! `/.well-known/site.standard.publication` file for root/custom-domain
//! sites, the exact-bytes sideband artifact for base-path deployments that
//! cannot serve the domain-root path, and a deterministic machine-readable
//! report distinguishing `emitted`, `limited`, and `not verified`.
//!
//! Absence is never silently claimed: a page counts as `emitted` only when its
//! selected layout actually contains the compiler-owned `{{head}}` slot and the
//! link bytes were placed there; a base-path build records `limited` instead of
//! writing an unservable decoy. This module performs no DNS, HTTP, clock, or
//! credential work and never fetches the deployed site.

const std = @import("std");
const Io = std.Io;
const json_out = @import("json_out.zig");
const standard_site = @import("standard_site.zig");

pub const report_format = "boris-standard-site-verification";
pub const report_schema_version: u32 = 1;

/// Post-commit evidence artifact reporting per-document and well-known status.
pub const report_output_path = "_boris/proof/standard-site.json";
/// Sideband artifact holding the exact required bytes for base-path sites.
pub const sideband_output_path = "_boris/proof/standard-site-well-known.txt";
/// Ownership marker recording whether the current dist's well-known file was
/// compiler-emitted, so a later base-path (limited) build can remove its own
/// decoy without ever deleting a user-managed file.
pub const ownership_path = "_boris/proof/standard-site.owner";

pub const Error = std.mem.Allocator.Error || error{
    StandardSitePathMismatch,
    StandardSiteProjectionStale,
    WellKnownOwnershipCorrupt,
};

/// Compile-side bundle of the committed projection and its derived surfaces.
/// Both pointed-to values are caller-owned and outlive the compile run.
pub const VerificationContext = struct {
    surfaces: *const standard_site.VerificationSurfaces,
    projection: *const standard_site.Projection,
};

pub const DocumentStatus = enum { emitted, not_verified };
pub const WellKnownStatus = enum { emitted, limited };

pub const DocumentEmission = struct {
    entity_id: []u8,
    at_uri: []u8,
    status: DocumentStatus,

    pub fn deinit(self: DocumentEmission, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
        allocator.free(self.at_uri);
    }
};

pub const WellKnownEmission = struct {
    status: WellKnownStatus,
    /// Project-relative path of the emitted well-known file (emitted only).
    project_path: ?[]u8,
    /// Exact public URL an indexer probes (always present).
    required_public_url: []u8,
    /// Sideband artifact path holding the exact required bytes (limited only).
    sideband_path: ?[]u8,

    pub fn deinit(self: WellKnownEmission, allocator: std.mem.Allocator) void {
        if (self.project_path) |path| allocator.free(path);
        allocator.free(self.required_public_url);
        if (self.sideband_path) |path| allocator.free(path);
    }
};

/// Minimal page identity the compile layer passes in for path validation.
pub const PagePath = struct {
    entity_id: []const u8,
    output_path: []const u8,
};

/// Prior-build ownership marker from the committed target.
pub const PriorOwnership = struct {
    present: bool = false,
    emitted: bool = false,
};

// ---------------------------------------------------------------------------
// document head links
// ---------------------------------------------------------------------------

/// AT-URI for the eligible document matching `entity_id`, or null when the
/// page has no document record (ineligible: draft, missing date, filtered,
/// unsupported).
pub fn documentAtUri(gpa: std.mem.Allocator, surfaces: *const standard_site.VerificationSurfaces, entity_id: []const u8) ?[]const u8 {
    var wanted: std.ArrayList(u8) = .empty;
    defer wanted.deinit(gpa);
    wanted.appendSlice(gpa, "/") catch return null;
    wanted.appendSlice(gpa, entity_id) catch return null;
    for (surfaces.document_links) |link| {
        if (std.mem.eql(u8, link.page, wanted.items)) return link.href;
    }
    return null;
}

/// Head-only fragment for one page: the `site.standard.document` link plus the
/// `site.standard.publication` discovery hint. Empty exactly when the page is
/// ineligible (no document record). The bytes are the only compiler-owned head
/// content; layouts opt in via `{{head}}`, so document AT-URIs can never leak
/// into the body.
pub fn documentHeadFragment(
    allocator: std.mem.Allocator,
    surfaces: *const standard_site.VerificationSurfaces,
    entity_id: []const u8,
) ![]u8 {
    const at_uri = documentAtUri(allocator, surfaces, entity_id) orelse return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "  <link rel=\"site.standard.document\" href=\"");
    try out.appendSlice(allocator, at_uri);
    try out.appendSlice(allocator, "\">\n  <link rel=\"site.standard.publication\" href=\"");
    try out.appendSlice(allocator, surfaces.well_known.content);
    try out.appendSlice(allocator, "\">\n");
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// projection validation
// ---------------------------------------------------------------------------

/// Cross-check the offline projection against the live page set, then exercise
/// the exact well-known bytes (mirrors the sitemap in-memory rule check; the
/// publish path writes them). Every planned document record must resolve to
/// the same canonical URL as the rendered page: `document.path ==
/// page.output_path`, matched on the compiler-owned entity id. A document with
/// no live page is a stale projection and fails closed.
pub fn validateProjection(
    gpa: std.mem.Allocator,
    ctx: *const VerificationContext,
    pages: []const PagePath,
) Error!void {
    for (ctx.projection.documents) |document| {
        var matched = false;
        for (pages) |page| {
            if (!std.mem.eql(u8, page.entity_id, document.entity_id)) continue;
            matched = true;
            // The record's `path` is the target-root-relative public path with
            // a leading slash; the rendered page's output path is relative.
            // Together with the projection's origin/base_path they resolve to
            // the same canonical URL, so they must agree exactly.
            if (document.path.len != page.output_path.len + 1 or
                document.path[0] != '/' or
                !std.mem.eql(u8, document.path[1..], page.output_path))
            {
                return error.StandardSitePathMismatch;
            }
            break;
        }
        if (!matched) return error.StandardSiteProjectionStale;
    }
    const bytes = try wellKnownBytes(gpa, ctx.surfaces);
    gpa.free(bytes);
}

// ---------------------------------------------------------------------------
// well-known emission
// ---------------------------------------------------------------------------

/// The exact bytes the well-known file must serve: the publication AT-URI.
pub fn wellKnownBytes(gpa: std.mem.Allocator, surfaces: *const standard_site.VerificationSurfaces) ![]u8 {
    return gpa.dupe(u8, surfaces.well_known.content);
}

/// Stage the well-known file (root/custom-domain sites) or the exact-bytes
/// sideband artifact (base-path deployments). Never writes a plausible-but-
/// incorrect public file: a project-site tree that cannot serve the domain
/// root records `limited` with the required public URL instead.
pub fn writeWellKnownOverlay(
    io: Io,
    gpa: std.mem.Allocator,
    stage_dir: Io.Dir,
    surfaces: *const standard_site.VerificationSurfaces,
) !WellKnownEmission {
    const w = &surfaces.well_known;
    if (w.emittable) {
        try writeFileAtomic(io, stage_dir, w.project_path.?, w.content);
        return .{
            .status = .emitted,
            .project_path = try gpa.dupe(u8, w.project_path.?),
            .required_public_url = try gpa.dupe(u8, w.required_public_url),
            .sideband_path = null,
        };
    }
    try writeFileAtomic(io, stage_dir, sideband_output_path, w.content);
    return .{
        .status = .limited,
        .project_path = null,
        .required_public_url = try gpa.dupe(u8, w.required_public_url),
        .sideband_path = try gpa.dupe(u8, sideband_output_path),
    };
}

/// Record whether this build emitted the well-known file. A later limited
/// build reads this marker to remove only the decoy it emitted itself.
pub fn stageOwnership(io: Io, stage_dir: Io.Dir, emitted: bool) !void {
    const bytes = if (emitted) "emitted\n" else "limited\n";
    try writeFileAtomic(io, stage_dir, ownership_path, bytes);
}

/// Read the prior-build ownership marker from the committed target. A missing
/// marker means no compiler-emitted well-known file exists; a corrupt marker
/// fails closed rather than guessing.
pub fn readPriorOwnership(io: Io, gpa: std.mem.Allocator, dist_dir: Io.Dir) !PriorOwnership {
    const bytes = readFileAlloc(io, dist_dir, ownership_path, gpa) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer gpa.free(bytes);
    if (std.mem.eql(u8, bytes, "emitted\n")) return .{ .present = true, .emitted = true };
    if (std.mem.eql(u8, bytes, "limited\n")) return .{ .present = true, .emitted = false };
    return error.WellKnownOwnershipCorrupt;
}

// ---------------------------------------------------------------------------
// report artifact
// ---------------------------------------------------------------------------

/// Render the deterministic machine-readable verification report. Fixed JSON
/// key order, LF endings, no timestamps or host data. The returned bytes are
/// allocator-owned and always end in one LF.
pub fn renderReport(
    gpa: std.mem.Allocator,
    well_known: *const WellKnownEmission,
    documents: []const DocumentEmission,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, report_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, report_schema_version);
    try out.appendSlice(gpa, ",\n  \"well_known\": {\n    \"status\": ");
    try json_out.writeString(&out, gpa, wellKnownStatusName(well_known.status));
    try out.appendSlice(gpa, ",\n    \"path\": ");
    if (well_known.project_path) |path| {
        try json_out.writeString(&out, gpa, path);
    } else {
        try json_out.writeNull(&out, gpa);
    }
    try out.appendSlice(gpa, ",\n    \"required_public_url\": ");
    try json_out.writeString(&out, gpa, well_known.required_public_url);
    try out.appendSlice(gpa, ",\n    \"sideband_path\": ");
    if (well_known.sideband_path) |path| {
        try json_out.writeString(&out, gpa, path);
    } else {
        try json_out.writeNull(&out, gpa);
    }
    try out.appendSlice(gpa, "\n  },\n  \"documents\": [");
    for (documents, 0..) |document, index| {
        if (index > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "\n    {\n      \"entity_id\": ");
        try json_out.writeString(&out, gpa, document.entity_id);
        try out.appendSlice(gpa, ",\n      \"at_uri\": ");
        try json_out.writeString(&out, gpa, document.at_uri);
        try out.appendSlice(gpa, ",\n      \"status\": ");
        try json_out.writeString(&out, gpa, documentStatusName(document.status));
        try out.appendSlice(gpa, "\n    }");
    }
    if (documents.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "]\n}\n");
    return out.toOwnedSlice(gpa);
}

/// Atomically write the report artifact into the committed target.
pub fn writeReport(io: Io, dist_dir: Io.Dir, json: []const u8) !void {
    try writeFileAtomic(io, dist_dir, report_output_path, json);
}

fn wellKnownStatusName(status: WellKnownStatus) []const u8 {
    return switch (status) {
        .emitted => "emitted",
        .limited => "limited",
    };
}

fn documentStatusName(status: DocumentStatus) []const u8 {
    return switch (status) {
        .emitted => "emitted",
        .not_verified => "not_verified",
    };
}

// ---------------------------------------------------------------------------
// shared I/O helpers
// ---------------------------------------------------------------------------

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn writeFileAtomic(io: Io, dir: Io.Dir, path: []const u8, data: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    try atomic.replace(io);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const TestCtx = struct {
    config: standard_site.TargetConfig,
    projection: standard_site.Projection,
    surfaces: standard_site.VerificationSurfaces,

    fn deinit(self: *TestCtx) void {
        const gpa = std.testing.allocator;
        gpa.free(self.surfaces.well_known.content);
        gpa.free(self.surfaces.well_known.required_public_url);
        if (self.surfaces.well_known.project_path) |path| gpa.free(path);
        for (self.surfaces.document_links) |link| {
            gpa.free(link.page);
            gpa.free(link.href);
        }
        gpa.free(self.surfaces.document_links);
        self.projection.deinit(gpa);
        self.config.deinit(gpa);
    }
};

fn buildTestCtx(
    base_url: []const u8,
    origin: []const u8,
    base_path: []const u8,
    pages: []const standard_site.PageInput,
) !TestCtx {
    const gpa = std.testing.allocator;
    var config: standard_site.TargetConfig = .{
        .location = try standard_site.parseLocation(gpa, base_url, origin, base_path),
        .did = try gpa.dupe(u8, "did:plc:testtesttesttesttest"),
    };
    errdefer config.deinit(gpa);
    var projection = try standard_site.project(gpa, .{
        .config = &config,
        .site_title = "Fixture Site",
        .pages = pages,
    });
    errdefer projection.deinit(gpa);
    const surfaces = try standard_site.verificationSurfaces(gpa, &config, &projection);
    errdefer gpa.free(surfaces.well_known.content);
    errdefer gpa.free(surfaces.well_known.required_public_url);
    return .{ .config = config, .projection = projection, .surfaces = surfaces };
}

test "document head fragment emits exact links only for eligible pages" {
    const gpa = std.testing.allocator;
    var ctx = try buildTestCtx(
        "https://example.com",
        "https://example.com",
        "",
        &.{
            .{ .entity_id = "index", .output_path = "index.html", .title = "Home", .status = .published, .published_at = "2026-08-15T00:00:00Z" },
            .{ .entity_id = "guides/caf\u{e9}", .output_path = "guides/caf\u{e9}.html", .title = "Caf\u{e9}", .status = .published, .published_at = "2026-08-15T00:00:00Z" },
            .{ .entity_id = "draft-page", .output_path = "draft-page.html", .title = "Draft", .status = .draft },
        },
    );
    defer ctx.deinit();

    const index_link = try documentHeadFragment(gpa, &ctx.surfaces, "index");
    defer gpa.free(index_link);
    try std.testing.expect(std.mem.startsWith(u8, index_link, "  <link rel=\"site.standard.document\" href=\"at://"));
    try std.testing.expect(std.mem.indexOf(u8, index_link, "site.standard.document") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_link, "site.standard.publication") != null);
    // The exact document AT-URI appears in the head fragment.
    const index_at_uri = ctx.surfaces.document_links[0].href;
    try std.testing.expect(std.mem.indexOf(u8, index_link, index_at_uri) != null);
    try std.testing.expectEqualStrings(ctx.surfaces.well_known.content, ctx.projection.publication.at_uri);

    // Unicode entity ids survive rkey encoding and link out as AT-URIs.
    const unicode_link = try documentHeadFragment(gpa, &ctx.surfaces, "guides/caf\u{e9}");
    defer gpa.free(unicode_link);
    try std.testing.expect(unicode_link.len > 0);

    // Ineligible pages receive no document link at all.
    const draft_link = try documentHeadFragment(gpa, &ctx.surfaces, "draft-page");
    defer gpa.free(draft_link);
    try std.testing.expectEqual(@as(usize, 0), draft_link.len);
}

test "well-known overlay emits for root sites and sideband-limits for base paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage");

    var root = try buildTestCtx(
        "https://example.com",
        "https://example.com",
        "",
        &.{
            .{ .entity_id = "index", .output_path = "index.html", .title = "Home", .status = .published, .published_at = "2026-08-15T00:00:00Z" },
        },
    );
    defer root.deinit();
    var stage = try tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);

    const emitted = try writeWellKnownOverlay(io, gpa, stage, &root.surfaces);
    defer emitted.deinit(gpa);
    try std.testing.expectEqual(WellKnownStatus.emitted, emitted.status);
    try std.testing.expectEqualStrings(".well-known/site.standard.publication", emitted.project_path.?);
    const bytes = try stage.readFileAlloc(io, ".well-known/site.standard.publication", gpa, .unlimited);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings(root.surfaces.well_known.content, bytes);
}

test "base-path deployment records limited with exact sideband bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage");

    var project = try buildTestCtx(
        "https://example.com/projects/site",
        "https://example.com",
        "/projects/site",
        &.{
            .{ .entity_id = "index", .output_path = "index.html", .title = "Home", .status = .published, .published_at = "2026-08-15T00:00:00Z" },
        },
    );
    defer project.deinit();
    var stage = try tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);

    const limited = try writeWellKnownOverlay(io, gpa, stage, &project.surfaces);
    defer limited.deinit(gpa);
    try std.testing.expectEqual(WellKnownStatus.limited, limited.status);
    try std.testing.expect(limited.project_path == null);
    try std.testing.expectEqualStrings(
        "https://example.com/.well-known/site.standard.publication",
        limited.required_public_url,
    );
    // The exact required bytes exist only as a sideband artifact, never as a
    // plausible public `.well-known` file.
    try std.testing.expectError(error.FileNotFound, stage.statFile(io, ".well-known/site.standard.publication", .{}));
    const sideband = try stage.readFileAlloc(io, sideband_output_path, gpa, .unlimited);
    defer gpa.free(sideband);
    try std.testing.expectEqualStrings(project.surfaces.well_known.content, sideband);
}

test "ownership marker round-trips and rejects corruption" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage");
    var stage = try tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);

    try stageOwnership(io, stage, true);
    var prior = try readPriorOwnership(io, gpa, stage);
    try std.testing.expect(prior.present);
    try std.testing.expect(prior.emitted);

    try stageOwnership(io, stage, false);
    prior = try readPriorOwnership(io, gpa, stage);
    try std.testing.expect(prior.present);
    try std.testing.expect(!prior.emitted);

    try stage.writeFile(io, .{ .sub_path = ownership_path, .data = "garbage" });
    try std.testing.expectError(error.WellKnownOwnershipCorrupt, readPriorOwnership(io, gpa, stage));
    stage.deleteFile(io, ownership_path) catch {};
    prior = try readPriorOwnership(io, gpa, stage);
    try std.testing.expect(!prior.present);
}

test "validation fails closed on stale projections and path mismatches" {
    const gpa = std.testing.allocator;
    var ctx = try buildTestCtx(
        "https://example.com",
        "https://example.com",
        "",
        &.{
            .{ .entity_id = "index", .output_path = "index.html", .title = "Home", .status = .published, .published_at = "2026-08-15T00:00:00Z" },
            .{ .entity_id = "guide", .output_path = "guide.html", .title = "Guide", .status = .published, .published_at = "2026-08-15T00:00:00Z" },
        },
    );
    defer ctx.deinit();

    const vctx: VerificationContext = .{ .surfaces = &ctx.surfaces, .projection = &ctx.projection };
    const good = [_]PagePath{
        .{ .entity_id = "index", .output_path = "index.html" },
        .{ .entity_id = "guide", .output_path = "guide.html" },
    };
    try validateProjection(gpa, &vctx, &good);

    const mismatched = [_]PagePath{
        .{ .entity_id = "index", .output_path = "index.html" },
        .{ .entity_id = "guide", .output_path = "renamed.html" },
    };
    try std.testing.expectError(error.StandardSitePathMismatch, validateProjection(gpa, &vctx, &mismatched));

    const stale = [_]PagePath{
        .{ .entity_id = "index", .output_path = "index.html" },
    };
    try std.testing.expectError(error.StandardSiteProjectionStale, validateProjection(gpa, &vctx, &stale));
}

test "report distinguishes emitted, limited, and not verified deterministically" {
    const gpa = std.testing.allocator;
    const emitted_doc = [_]DocumentEmission{
        .{ .entity_id = try gpa.dupe(u8, "index"), .at_uri = try gpa.dupe(u8, "at://did:plc:test/site.standard.document/index"), .status = .emitted },
        .{ .entity_id = try gpa.dupe(u8, "guide"), .at_uri = try gpa.dupe(u8, "at://did:plc:test/site.standard.document/guide"), .status = .not_verified },
    };
    defer for (emitted_doc) |d| d.deinit(gpa);
    const wke = WellKnownEmission{
        .status = .emitted,
        .project_path = try gpa.dupe(u8, standard_site.well_known_path),
        .required_public_url = try gpa.dupe(u8, "https://example.com/.well-known/site.standard.publication"),
        .sideband_path = null,
    };
    defer wke.deinit(gpa);

    const first = try renderReport(gpa, &wke, &emitted_doc);
    defer gpa.free(first);
    const second = try renderReport(gpa, &wke, &emitted_doc);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"emitted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"not_verified\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, first, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, first, report_output_path) == null);
}
