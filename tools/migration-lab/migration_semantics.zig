//! Shared migration-report vocabulary. Boris core remains the authority for
//! parsing; migration labs use these names to keep review reports aligned.

const std = @import("std");

pub const boris_frontmatter_keys = [_][]const u8{
    "id",
    "title",
    "parent",
    "status",
    "tags",
    "relations",
    "published_at",
    "summary",
};

pub const FieldDisposition = enum {
    supported_direct,
    supported_normalized,
    identity_source,
    parent_candidate,
    relation_candidate,
    body_candidate,
    sidecar_only,
    platform_residue,
    manual_review,

    pub fn name(self: FieldDisposition) []const u8 {
        return @tagName(self);
    }
};

pub const ParentDecision = enum {
    parent,
    relation,
    review,
    none,

    pub fn name(self: ParentDecision) []const u8 {
        return @tagName(self);
    }
};

pub const ProposedEntityKind = enum {
    source_record,
    generated_trunk,
    generated_index,
    custom_route,
    alias,

    pub fn name(self: ProposedEntityKind) []const u8 {
        return @tagName(self);
    }
};

pub const MdxComponentClass = enum {
    known_card_wrapper,
    dynamic_query_component,
    manual_review,

    pub fn name(self: MdxComponentClass) []const u8 {
        return @tagName(self);
    }
};

pub fn isBorisKey(key: []const u8) bool {
    for (boris_frontmatter_keys) |known| if (std.mem.eql(u8, known, key)) return true;
    return false;
}

pub fn dispositionForKey(key: []const u8) FieldDisposition {
    if (std.mem.eql(u8, key, "id")) return .identity_source;
    if (std.mem.eql(u8, key, "parent")) return .parent_candidate;
    if (std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "status") or
        std.mem.eql(u8, key, "tags") or std.mem.eql(u8, key, "published_at") or
        std.mem.eql(u8, key, "summary")) return .supported_direct;
    if (std.mem.eql(u8, key, "parentEntry") or std.mem.eql(u8, key, "parent_entry")) return .parent_candidate;
    if (std.mem.eql(u8, key, "caseNumber") or std.mem.eql(u8, key, "artifactId") or
        std.mem.eql(u8, key, "mascotId") or std.mem.eql(u8, key, "slug")) return .identity_source;
    if (std.mem.startsWith(u8, key, "related") or std.mem.eql(u8, key, "mascotRef") or
        std.mem.eql(u8, key, "haikuLog") or std.mem.eql(u8, key, "limerickLog")) return .relation_candidate;
    if (std.mem.eql(u8, key, "description") or std.mem.eql(u8, key, "severity") or
        std.mem.eql(u8, key, "resolution")) return .body_candidate;
    if (std.mem.eql(u8, key, "updatedAt") or std.mem.eql(u8, key, "date") or
        std.mem.eql(u8, key, "createdAt")) return .sidecar_only;
    if (std.mem.eql(u8, key, "tableOfContents") or std.mem.eql(u8, key, "layout") or
        std.mem.eql(u8, key, "draft")) return .platform_residue;
    return .manual_review;
}

test "legacy parent aliases remain review planning candidates" {
    try std.testing.expectEqual(FieldDisposition.parent_candidate, dispositionForKey("parentEntry"));
    try std.testing.expectEqual(FieldDisposition.parent_candidate, dispositionForKey("parent_entry"));
    try std.testing.expect(!isBorisKey("parentEntry"));
    try std.testing.expect(!isBorisKey("parent_entry"));
}
