//! Compatibility re-exports for path/identity helpers.
//!
//! **Canonical implementation lives in `identity.zig`.** New code must import
//! `identity` and use `identity.canonicalEntityId` as the single derivation
//! entry. This module exists so experimental stages still compile against the
//! historical import path.

const identity = @import("identity.zig");

pub const max_entity_id_bytes = identity.max_entity_id_bytes;
pub const PathError = identity.PathError;
pub const ContentKind = identity.ContentKind;

pub const isPageFile = identity.isPageFile;
pub const isMarkdownFile = identity.isPageFile;
pub const pageExtensionLen = identity.pageExtensionLen;
pub const contentKind = identity.contentKind;
pub const canonicalize = identity.canonicalize;
pub const validateEntityId = identity.validateEntityId;
pub const stemFromSourcePath = identity.stemFromSourcePath;
pub const normalizeEntityId = identity.normalizeEntityId;
pub const canonicalEntityId = identity.canonicalEntityId;
pub const entityIdFromSource = identity.canonicalEntityId;
pub const idFromSourcePath = identity.stemFromSourcePath;
pub const safeOutputRelativePath = identity.safeOutputRelativePath;
pub const htmlOutputPath = identity.htmlOutputPath;
pub const ragPagePath = identity.ragPagePath;
pub const pathsDifferOnlyInCase = identity.pathsDifferOnlyInCase;
pub const relativeHref = identity.relativeHref;
