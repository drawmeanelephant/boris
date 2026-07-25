const std = @import("std");

/// Broad file classification within configured evidence roots.
pub const FileKind = enum {
    zig_source,
    zig_test,
    source_dossier,
    contract,
    field_note,
    product_changelog,
    tool_changelog,
    documentation,

    pub fn asString(self: FileKind) []const u8 {
        return switch (self) {
            .zig_source => "zig_source",
            .zig_test => "zig_test",
            .source_dossier => "source_dossier",
            .contract => "contract",
            .field_note => "field_note",
            .product_changelog => "product_changelog",
            .tool_changelog => "tool_changelog",
            .documentation => "documentation",
        };
    }
};

/// Inventory record for a single file in the evidence set.
pub const Record = struct {
    path: []const u8,
    kind: FileKind,
    bytes: u64,
    sha256: [64]u8,
    has_dossier_marker: bool,
};

/// Region claim parsed from BORIS-SOURCE-DOC markers inside a dossier file.
pub const DossierClaim = struct {
    dossier_path: []const u8,
    source_path: []const u8,
    begin_line: u32,
    end_line: u32,
    is_valid: bool,
};

/// Structural condition between source files and dossier documents.
pub const RelationshipKind = enum {
    source_without_dossier,
    dossier_without_source,
    duplicate_dossier_claim,

    pub fn asString(self: RelationshipKind) []const u8 {
        return switch (self) {
            .source_without_dossier => "source_without_dossier",
            .dossier_without_source => "dossier_without_source",
            .duplicate_dossier_claim => "duplicate_dossier_claim",
        };
    }
};

/// Relationship between a source path and any associated dossier paths.
pub const Relationship = struct {
    kind: RelationshipKind,
    source_path: []const u8,
    dossier_paths: []const []const u8,
};

/// Diagnostic warning or error condition found during evidence scanning.
pub const Diagnostic = struct {
    code: []const u8,
    path: []const u8,
    line: u32 = 0,
    message: []const u8,
};

/// Complete deterministic inventory report container.
pub const InventoryReport = struct {
    format: []const u8 = "boris-docs-inventory-v0",
    records: []const Record,
    relationships: []const Relationship,
    diagnostics: []const Diagnostic,
    evidence_set_sha256: [64]u8,
};
