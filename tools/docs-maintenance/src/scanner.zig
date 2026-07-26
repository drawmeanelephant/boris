const std = @import("std");
const Io = std.Io;
const model = @import("model.zig");

pub const ScanOptions = struct {
    repo_root: []const u8,
    source_root: []const u8 = "src",
    dossier_root: []const u8 = "docs/boris/src",
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    options: ScanOptions,

    records: std.ArrayListUnmanaged(model.Record),
    relationships: std.ArrayListUnmanaged(model.Relationship),
    diagnostics: std.ArrayListUnmanaged(model.Diagnostic),
    claims: std.ArrayListUnmanaged(model.DossierClaim),

    pub fn init(allocator: std.mem.Allocator, options: ScanOptions) Scanner {
        return .{
            .allocator = allocator,
            .options = options,
            .records = .empty,
            .relationships = .empty,
            .diagnostics = .empty,
            .claims = .empty,
        };
    }

    pub fn deinit(self: *Scanner) void {
        for (self.records.items) |r| {
            self.allocator.free(r.path);
        }
        self.records.deinit(self.allocator);

        for (self.relationships.items) |rel| {
            self.allocator.free(rel.source_path);
            for (rel.dossier_paths) |dp| {
                self.allocator.free(dp);
            }
            self.allocator.free(rel.dossier_paths);
        }
        self.relationships.deinit(self.allocator);

        for (self.diagnostics.items) |d| {
            self.allocator.free(d.code);
            self.allocator.free(d.path);
            self.allocator.free(d.message);
        }
        self.diagnostics.deinit(self.allocator);

        for (self.claims.items) |c| {
            self.allocator.free(c.dossier_path);
            self.allocator.free(c.source_path);
        }
        self.claims.deinit(self.allocator);
    }

    pub fn scan(self: *Scanner, io: Io) !model.InventoryReport {
        const cwd_dir = Io.Dir.cwd();
        var root_dir = cwd_dir.openDir(io, self.options.repo_root, .{ .iterate = true }) catch {
            return error.RepoNotFound;
        };
        defer root_dir.close(io);

        // 1. Scan explicit evidence roots
        try self.scanEvidenceRoots(io, &root_dir);

        // 2. Sort records by path (lexicographical byte order)
        std.mem.sort(model.Record, self.records.items, {}, recordLessThan);

        // 3. Process claims and build mechanical relationships
        try self.deriveRelationships();

        // 4. Sort relationships and diagnostics
        std.mem.sort(model.Relationship, self.relationships.items, {}, relationshipLessThan);
        std.mem.sort(model.Diagnostic, self.diagnostics.items, {}, diagnosticLessThan);

        // 5. Compute pure evidence-set digest
        const evidence_digest = try computeEvidenceDigest(self.records.items);

        return model.InventoryReport{
            .records = self.records.items,
            .relationships = self.relationships.items,
            .diagnostics = self.diagnostics.items,
            .evidence_set_sha256 = evidence_digest,
        };
    }

    fn scanEvidenceRoots(self: *Scanner, io: Io, root_dir: *Io.Dir) !void {
        var targets: std.ArrayListUnmanaged([]const u8) = .empty;
        defer targets.deinit(self.allocator);

        try targets.append(self.allocator, self.options.source_root);
        try targets.append(self.allocator, self.options.dossier_root);
        try targets.append(self.allocator, "docs/contracts");
        try targets.append(self.allocator, "docs/field-notes");
        try targets.append(self.allocator, "docs");
        try targets.append(self.allocator, "content");
        try targets.append(self.allocator, "tools");

        // Scan root CHANGELOG.md explicitly if it exists
        self.scanSingleFileIfExists(io, root_dir, "CHANGELOG.md", .product_changelog) catch {};

        var visited_paths = std.StringHashMap(void).init(self.allocator);
        defer {
            var key_it = visited_paths.keyIterator();
            while (key_it.next()) |k| {
                self.allocator.free(k.*);
            }
            visited_paths.deinit();
        }

        for (targets.items) |target_rel| {
            const stat = root_dir.statFile(io, target_rel, .{}) catch continue;
            if (stat.kind == .directory) {
                try self.walkDirectory(io, root_dir, target_rel, &visited_paths);
            } else if (stat.kind == .file) {
                if (!visited_paths.contains(target_rel)) {
                    try visited_paths.put(try self.allocator.dupe(u8, target_rel), {});
                    const kind = classifyFile(target_rel, self.options);
                    if (kind) |k| {
                        try self.inspectAndRecordFile(io, root_dir, target_rel, k);
                    }
                }
            }
        }
    }

    fn scanSingleFileIfExists(self: *Scanner, io: Io, root_dir: *Io.Dir, rel_path: []const u8, kind: model.FileKind) !void {
        _ = root_dir.statFile(io, rel_path, .{}) catch return;
        try self.inspectAndRecordFile(io, root_dir, rel_path, kind);
    }

    fn walkDirectory(
        self: *Scanner,
        io: Io,
        root_dir: *Io.Dir,
        dir_rel: []const u8,
        visited_paths: *std.StringHashMap(void),
    ) !void {
        var sub_dir = root_dir.openDir(io, dir_rel, .{ .iterate = true }) catch return;
        defer sub_dir.close(io);

        var iter = sub_dir.iterate();
        while (iter.next(io) catch return) |entry| {
            if (isExcludedDirOrFile(entry.name)) continue;

            const child_rel = try std.fs.path.join(self.allocator, &.{ dir_rel, entry.name });
            defer self.allocator.free(child_rel);

            const norm_child_rel = try normalizePathSeparators(self.allocator, child_rel);
            defer self.allocator.free(norm_child_rel);

            if (entry.kind == .sym_link) {
                try self.addDiagnostic("WSYMLINK_SKIPPED", norm_child_rel, 0, "Skipped symlink entry");
                continue;
            }

            if (entry.kind == .directory) {
                try self.walkDirectory(io, root_dir, norm_child_rel, visited_paths);
            } else if (entry.kind == .file) {
                if (visited_paths.contains(norm_child_rel)) continue;

                const kind = classifyFile(norm_child_rel, self.options);
                if (kind) |k| {
                    try visited_paths.put(try self.allocator.dupe(u8, norm_child_rel), {});
                    try self.inspectAndRecordFile(io, root_dir, norm_child_rel, k);
                }
            }
        }
    }

    fn inspectAndRecordFile(self: *Scanner, io: Io, root_dir: *Io.Dir, rel_path: []const u8, kind: model.FileKind) !void {
        var file = root_dir.openFile(io, rel_path, .{}) catch return;
        defer file.close(io);

        var reader = file.reader(io, &.{});
        const content = reader.interface.allocRemaining(self.allocator, .unlimited) catch return;
        defer self.allocator.free(content);

        // Compute SHA-256
        var sha_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &sha_bytes, .{});
        const sha_hex = std.fmt.bytesToHex(sha_bytes, .lower);

        // Parse markers if document or dossier
        const has_marker = if (kind == .source_dossier or kind == .documentation)
            try self.parseDossierMarkers(rel_path, content)
        else
            false;

        try self.records.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, rel_path),
            .kind = kind,
            .bytes = content.len,
            .sha256 = sha_hex,
            .has_dossier_marker = has_marker,
        });
    }

    fn parseDossierMarkers(self: *Scanner, dossier_path: []const u8, content: []const u8) !bool {
        var has_any_marker = false;
        var active_begin_path: ?[]const u8 = null;
        var active_begin_line: u32 = 0;

        var claims_in_file: std.ArrayListUnmanaged(model.DossierClaim) = .empty;
        defer {
            for (claims_in_file.items) |claim| {
                self.allocator.free(claim.source_path);
            }
            claims_in_file.deinit(self.allocator);
        }

        var distinct_claimed_sources = std.StringHashMap(void).init(self.allocator);
        defer {
            var key_it = distinct_claimed_sources.keyIterator();
            while (key_it.next()) |key| {
                self.allocator.free(key.*);
            }
            distinct_claimed_sources.deinit();
        }

        var line_num: u32 = 1;
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        while (line_iter.next()) |raw_line| : (line_num += 1) {
            const line = std.mem.trim(u8, raw_line, " \t\r");

            if (std.mem.startsWith(u8, line, "<!-- BORIS-SOURCE-DOC BEGIN")) {
                has_any_marker = true;
                if (active_begin_path != null) {
                    try self.addDiagnostic("EDOSSIER_MARKER", dossier_path, line_num, "nested dossier marker region rejected");
                    continue;
                }

                const attr_path = extractPathAttribute(line);
                if (attr_path == null) {
                    try self.addDiagnostic("EDOSSIER_MARKER", dossier_path, line_num, "malformed begin marker path attribute");
                    continue;
                }

                const src_path = attr_path.?;
                if (!isValidRelativePath(src_path)) {
                    try self.addDiagnostic("EDOSSIER_MARKER", dossier_path, line_num, "invalid or absolute path in begin marker");
                    continue;
                }

                active_begin_path = try self.allocator.dupe(u8, src_path);
                active_begin_line = line_num;
            } else if (std.mem.startsWith(u8, line, "<!-- BORIS-SOURCE-DOC END")) {
                has_any_marker = true;
                if (active_begin_path == null) {
                    try self.addDiagnostic("EDOSSIER_MARKER", dossier_path, line_num, "orphan end marker without begin marker");
                    continue;
                }

                const begin_path = active_begin_path.?;
                defer self.allocator.free(begin_path);
                active_begin_path = null;

                const attr_path = extractPathAttribute(line);
                const end_path = attr_path orelse "";

                if (end_path.len > 0 and !std.mem.eql(u8, begin_path, end_path)) {
                    try self.addDiagnostic("EDOSSIER_MARKER", dossier_path, line_num, "begin and end marker paths do not match");
                    continue;
                }

                var is_duplicate = false;
                for (claims_in_file.items) |existing| {
                    if (std.mem.eql(u8, existing.source_path, begin_path)) {
                        is_duplicate = true;
                        break;
                    }
                }

                if (is_duplicate) {
                    try self.addDiagnostic("EDOSSIER_MARKER", dossier_path, line_num, "duplicate region for same source path in dossier");
                    continue;
                }

                var claim_source: ?[]u8 = try self.allocator.dupe(u8, begin_path);
                errdefer if (claim_source) |owned| self.allocator.free(owned);

                try claims_in_file.append(self.allocator, .{
                    .dossier_path = dossier_path,
                    .source_path = claim_source.?,
                    .begin_line = active_begin_line,
                    .end_line = line_num,
                    .is_valid = true,
                });
                claim_source = null;

                // StringHashMap stores the key slice; retain an owned copy
                // because the active marker path is freed below.
                var distinct_source: ?[]u8 = try self.allocator.dupe(u8, begin_path);
                errdefer if (distinct_source) |owned| self.allocator.free(owned);
                try distinct_claimed_sources.put(distinct_source.?, {});
                distinct_source = null;
            }
        }

        if (active_begin_path) |begin_path| {
            defer self.allocator.free(begin_path);
            try self.addDiagnostic("EDOSSIER_MARKER", dossier_path, active_begin_line, "unterminated dossier marker region");
        }

        if (distinct_claimed_sources.count() > 1) {
            try self.addDiagnostic("EMULTI_SOURCE_DOSSIER", dossier_path, 0, "dossier file claims multiple distinct source paths");
            for (claims_in_file.items) |*claim| {
                claim.is_valid = false;
            }
        }

        for (claims_in_file.items) |claim| {
            if (claim.is_valid) {
                var claim_dossier_path: ?[]u8 = try self.allocator.dupe(u8, claim.dossier_path);
                errdefer if (claim_dossier_path) |owned| self.allocator.free(owned);

                var claim_source_path: ?[]u8 = try self.allocator.dupe(u8, claim.source_path);
                errdefer if (claim_source_path) |owned| self.allocator.free(owned);

                try self.claims.append(self.allocator, .{
                    .dossier_path = claim_dossier_path.?,
                    .source_path = claim_source_path.?,
                    .begin_line = claim.begin_line,
                    .end_line = claim.end_line,
                    .is_valid = true,
                });
                claim_dossier_path = null;
                claim_source_path = null;
            }
        }

        return has_any_marker;
    }

    fn deriveRelationships(self: *Scanner) !void {
        var claim_map = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(self.allocator);
        defer {
            var it = claim_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            claim_map.deinit();
        }

        for (self.claims.items) |c| {
            if (!c.is_valid) continue;
            var gop = try claim_map.getOrPut(c.source_path);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, c.source_path);
                gop.value_ptr.* = .empty;
            }
            var exists = false;
            for (gop.value_ptr.items) |dp| {
                if (std.mem.eql(u8, dp, c.dossier_path)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                try gop.value_ptr.append(self.allocator, c.dossier_path);
            }
        }

        var known_records = std.StringHashMap(void).init(self.allocator);
        defer known_records.deinit();
        for (self.records.items) |r| {
            try known_records.put(r.path, {});
        }

        for (self.records.items) |r| {
            if (r.kind == .zig_source) {
                if (!claim_map.contains(r.path)) {
                    try self.relationships.append(self.allocator, .{
                        .kind = .source_without_dossier,
                        .source_path = try self.allocator.dupe(u8, r.path),
                        .dossier_paths = &.{},
                    });
                }
            }
        }

        var claim_it = claim_map.iterator();
        while (claim_it.next()) |entry| {
            const src_path = entry.key_ptr.*;
            const dossier_list = entry.value_ptr.items;

            if (!known_records.contains(src_path)) {
                var d_paths: std.ArrayListUnmanaged([]const u8) = .empty;
                for (dossier_list) |dp| {
                    try d_paths.append(self.allocator, try self.allocator.dupe(u8, dp));
                }
                std.mem.sort([]const u8, d_paths.items, {}, stringLessThan);

                try self.relationships.append(self.allocator, .{
                    .kind = .dossier_without_source,
                    .source_path = try self.allocator.dupe(u8, src_path),
                    .dossier_paths = try d_paths.toOwnedSlice(self.allocator),
                });
            }

            if (dossier_list.len > 1) {
                var d_paths: std.ArrayListUnmanaged([]const u8) = .empty;
                for (dossier_list) |dp| {
                    try d_paths.append(self.allocator, try self.allocator.dupe(u8, dp));
                }
                std.mem.sort([]const u8, d_paths.items, {}, stringLessThan);

                try self.relationships.append(self.allocator, .{
                    .kind = .duplicate_dossier_claim,
                    .source_path = try self.allocator.dupe(u8, src_path),
                    .dossier_paths = try d_paths.toOwnedSlice(self.allocator),
                });
            }
        }
    }

    fn addDiagnostic(self: *Scanner, code: []const u8, path: []const u8, line: u32, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .code = try self.allocator.dupe(u8, code),
            .path = try self.allocator.dupe(u8, path),
            .line = line,
            .message = try self.allocator.dupe(u8, message),
        });
    }
};

pub fn computeEvidenceDigest(sorted_records: []const model.Record) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    const domain_tag = "boris-docs-evidence-set-v0\x00";
    hasher.update(domain_tag);

    var count_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_bytes, sorted_records.len, .big);
    hasher.update(&count_bytes);

    for (sorted_records) |r| {
        var path_len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &path_len_bytes, @intCast(r.path.len), .big);
        hasher.update(&path_len_bytes);
        hasher.update(r.path);

        var size_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &size_bytes, r.bytes, .big);
        hasher.update(&size_bytes);

        var raw_sha: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw_sha, &r.sha256) catch {};
        hasher.update(&raw_sha);
    }

    var final_digest: [32]u8 = undefined;
    hasher.final(&final_digest);

    return std.fmt.bytesToHex(final_digest, .lower);
}

fn isExcludedDirOrFile(name: []const u8) bool {
    const exclusions = [_][]const u8{
        ".git",
        ".zig-cache",
        "zig-cache",
        "zig-out",
        "dist",
        "rag",
        "source-rag",
        "test-output",
        ".boris-cache",
        ".DS_Store",
    };
    for (exclusions) |ex| {
        if (std.mem.eql(u8, name, ex)) return true;
    }
    return false;
}

fn classifyFile(rel_path: []const u8, options: ScanOptions) ?model.FileKind {
    if (std.mem.eql(u8, rel_path, "CHANGELOG.md")) return .product_changelog;
    if (std.mem.startsWith(u8, rel_path, "tools/") and std.mem.endsWith(u8, rel_path, "/CHANGELOG.md")) return .tool_changelog;

    if (std.mem.startsWith(u8, rel_path, options.source_root)) {
        if (std.mem.endsWith(u8, rel_path, ".zig")) {
            if (std.mem.endsWith(u8, rel_path, "_test.zig")) return .zig_test;
            return .zig_source;
        }
    }

    if (std.mem.startsWith(u8, rel_path, options.dossier_root)) {
        if (std.mem.endsWith(u8, rel_path, ".md")) return .source_dossier;
    }

    if (std.mem.startsWith(u8, rel_path, "docs/contracts")) {
        if (std.mem.endsWith(u8, rel_path, ".md")) return .contract;
    }

    if (std.mem.startsWith(u8, rel_path, "docs/field-notes")) {
        if (std.mem.endsWith(u8, rel_path, ".md")) return .field_note;
    }

    if (std.mem.startsWith(u8, rel_path, "docs/") or std.mem.startsWith(u8, rel_path, "content/")) {
        if (std.mem.endsWith(u8, rel_path, ".md")) return .documentation;
    }

    return null;
}

fn extractPathAttribute(line: []const u8) ?[]const u8 {
    const key = "path=\"";
    const idx = std.mem.indexOf(u8, line, key) orelse return null;
    const start = idx + key.len;
    const end = std.mem.indexOfPos(u8, line, start, "\"") orelse return null;
    return line[start..end];
}

fn isValidRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.startsWith(u8, path, "/")) return false;
    if (path.len >= 2 and path[1] == ':') return false;

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |segment| {
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn normalizePathSeparators(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dup = try allocator.dupe(u8, path);
    for (dup) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return dup;
}

fn recordLessThan(_: void, lhs: model.Record, rhs: model.Record) bool {
    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
}

fn relationshipLessThan(_: void, lhs: model.Relationship, rhs: model.Relationship) bool {
    const k_ord = std.mem.order(u8, lhs.kind.asString(), rhs.kind.asString());
    if (k_ord != .eq) return k_ord == .lt;
    return std.mem.order(u8, lhs.source_path, rhs.source_path) == .lt;
}

fn diagnosticLessThan(_: void, lhs: model.Diagnostic, rhs: model.Diagnostic) bool {
    const p_ord = std.mem.order(u8, lhs.path, rhs.path);
    if (p_ord != .eq) return p_ord == .lt;
    if (lhs.line != rhs.line) return lhs.line < rhs.line;
    const c_ord = std.mem.order(u8, lhs.code, rhs.code);
    if (c_ord != .eq) return c_ord == .lt;
    return std.mem.order(u8, lhs.message, rhs.message) == .lt;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn dossierMarkerAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var sc = Scanner.init(allocator, .{
        .repo_root = ".",
        .source_root = "src",
        .dossier_root = "docs/boris/src",
    });
    defer sc.deinit();

    _ = try sc.parseDossierMarkers(
        "docs/boris/src/alpha/surface.md",
        "<!-- BORIS-SOURCE-DOC BEGIN path=\"src/alpha.zig\" -->\n" ++
            "Alpha module documentation details.\n" ++
            "<!-- BORIS-SOURCE-DOC END path=\"src/alpha.zig\" -->\n",
    );
}

test "dossier marker ownership survives allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        dossierMarkerAllocationFailureCase,
        .{},
    );
}
