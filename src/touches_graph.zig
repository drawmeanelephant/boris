//! Graph helpers extracted from publication_touches for QM-3.
//! Pure helpers with no IO; keeps diminish largest prod fn size without circular imports.

const std = @import("std");

pub const NodeKind = enum { target, artifact, check, finding, claim, limitation };
pub const EdgeKind = enum {
    target_owns_artifact,
    artifact_subject_of_check,
    artifact_supports_check,
    check_reported_finding,
    check_supports_claim,
    claim_limited_by,

    pub fn name(self: EdgeKind) []const u8 {
        return switch (self) {
            .target_owns_artifact => "target-owns-artifact",
            .artifact_subject_of_check => "artifact-subject-of-check",
            .artifact_supports_check => "artifact-supports-check",
            .check_reported_finding => "check-reported-finding",
            .check_supports_claim => "check-supports-claim",
            .claim_limited_by => "claim-limited-by",
        };
    }
};

pub const Node = struct { kind: NodeKind, id: []const u8 };
pub const Edge = struct { kind: EdgeKind, from: []const u8, to: []const u8 };

pub fn edgePermits(edge: Edge, from_kind: NodeKind, to_kind: NodeKind) bool {
    return switch (edge.kind) {
        .target_owns_artifact => from_kind == .target and to_kind == .artifact,
        .artifact_subject_of_check => from_kind == .artifact and to_kind == .check,
        .artifact_supports_check => from_kind == .artifact and to_kind == .check,
        .check_reported_finding => from_kind == .check and to_kind == .finding,
        .check_supports_claim => from_kind == .check and to_kind == .claim,
        .claim_limited_by => from_kind == .claim and to_kind == .limitation,
    };
}

pub fn findingNodeId(gpa: std.mem.Allocator, check_id: []const u8, ordinal: usize) ![]u8 {
    var buffer: [64]u8 = undefined;
    const ordinal_text = std.fmt.bufPrint(&buffer, "{d}", .{ordinal}) catch return error.OutOfMemory;
    return std.mem.concat(gpa, u8, &.{ "finding:", check_id, ":", ordinal_text });
}

pub fn findingNodeIdGrammar(id: []const u8, checkIndexOfNode: *const fn ([]const u8) ?usize) bool {
    const prefix = "finding:";
    if (!std.mem.startsWith(u8, id, prefix)) return false;
    const rest = id[prefix.len..];
    const last_colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return false;
    const check_id = rest[0..last_colon];
    const ordinal_text = rest[last_colon + 1 ..];
    if (checkIndexOfNode(check_id) == null) return false;
    if (ordinal_text.len == 0) return false;
    for (ordinal_text) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

pub fn validNodeId(
    gpa: std.mem.Allocator,
    node: Node,
    expected_target: []const u8,
    checkIndexOf: *const fn ([]const u8) ?usize,
    claimIndexOf: *const fn ([]const u8) ?usize,
    limitationIndexOf: *const fn ([]const u8) ?usize,
) bool {
    _ = gpa;
    _ = expected_target;
    return switch (node.kind) {
        .target => std.mem.eql(u8, node.id, "target"),
        .check => checkIndexOf(node.id) != null,
        .claim => claimIndexOf(node.id) != null,
        .limitation => limitationIndexOf(node.id) != null,
        .finding => findingNodeIdGrammar(node.id, checkIndexOf),
        .artifact => std.mem.startsWith(u8, node.id, "artifact:") and node.id.len > "artifact:".len,
    };
}
