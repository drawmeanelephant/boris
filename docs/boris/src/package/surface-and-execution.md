---
title: "`src/package.zig` surface and execution"
id: docs/boris/src/package/surface-and-execution
parent: docs/boris/src/package
status: draft
tags: [boris, zig, source-reference, surface, package]
---

# `src/package.zig` surface and execution

## Threat model

`package.zig`'s threat model concerns **publish safety**, not hostile ABI inputs. The adversarial scenarios it guards against are operational faults during the install step, not malicious inputs. The relevant categories are as follows.

**Archive destruction on mid-install failure.** A previous version of a publish protocol that deleted the live archive before writing a replacement would destroy the only good copy if the write or rename failed. The move-aside protocol (write temp fully → rename live to `.prev` → rename temp to final → delete `.prev`) addresses this. The `test_fail_before_archive_install` flag in `Options` provides a direct injection point to verify this property: it causes the function to return `error.TestInjectedArchiveInstallFailure` after the temp is fully written and closed but before the rename. The test "package: failed install preserves previous archive" uses this injection.

**Stage leftover noise on content-validation failure.** If `pipeline.run` returns `ok = false`, the function must not leave a partially-written stage directory that could confuse a retry. The `errdefer cwd.deleteTree(io, stage_rel)` and explicit `cwd.deleteTree(io, stage_rel)` calls on the early-return path handle this.

**SHA256SUMS including itself.** The `renderSha256Sums` function explicitly skips the file named `checksums_filename` when iterating over payload files to hash. This prevents a self-referential checksum. The property is structural (a guarded `continue`) rather than tested directly.

**Non-deterministic tar byte content from host entropy.** The archive uses `mtime = 0` and `mode = 0o644` for every entry, a fixed `archive_root` prefix, and a lexicographically sorted `all_paths` slice. These choices eliminate the most common sources of non-determinism. The "dual-run same host produces identical tar bytes" test directly verifies byte identity.

**Path separator non-portability in tar entry names.** `normalizeRelPath` strips leading separators and collapses consecutive separators, translating `\` to `/`. This is a structural normalization; portability across OS-specific path forms is not exhaustively tested.

**Duplicate or stale temp/prev files from a previously interrupted install.** At the start of `writeTarFromStage`, both `.{name}.tmp` and `.{name}.prev` are deleted with `catch {}` (best-effort). This prevents a leftover from an earlier crash from interfering. The test "package: second success replaces via move-aside without leftover prev" confirms no residue after a clean second run.

**Content-validation failure categories not tested.** The file tests `FailureKind.content` via the `missing-parent` fixture. I/O-class failures from `pipeline.run` or `rag.run` returning errors are not tested with injected I/O faults; those paths propagate naturally as Zig errors.

**Untested categories:** concurrent archive readers; cross-volume rename failure (explicitly disclaimed in the doc-comment on `writeTarFromStage`); very large archives exceeding the 64 KiB write buffer; filesystem errors during the `collectFilePaths` walk after stage construction.
