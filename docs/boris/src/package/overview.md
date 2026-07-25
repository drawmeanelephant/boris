---
title: "`src/package.zig` overview"
id: docs/boris/src/package
status: draft
tags: [boris, zig, source-reference, package]
---

# `src/package.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/package/surface-and-execution|Surface and execution]]
* [[docs/boris/src/package/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/package/review-state|Review state]]

## Executive summary

`src/package.zig` is the **review-package** subsystem of Boris. Its purpose is to collect the compiler's intermediate-representation (IR) outputs and an optional Retrieval-Augmented Generation (RAG) corpus into a single deterministic tar archive, then publish that archive under a stable filename inside a configurable `packages/` directory. The file serves three distinct roles simultaneously: a reusable library module (exported `run`, `freeResult`, `renderVersionJson`), the `main` entry point of the `boris-package` CLI binary, and the host of its own integration test suite.

The system boundary it protects is the **publish step**: the moment at which validated, in-memory IR and RAG artifacts cross from a transient staging tree into a durable, named archive that a downstream consumer or review workflow can read. Because a naive delete-before-write strategy would destroy an existing good archive when a subsequent build fails mid-way, `package.zig` implements a **move-aside install protocol** for the final archive: it writes a `.{name}.tmp` file completely, moves any existing archive to `.{name}.prev`, then renames the temp into the final position, restoring `.prev` on any rename failure. The stage directory itself is cleaned unconditionally on both success and content-validation failure.

The file is executed as a test binary (by `zig build test` or an equivalent step) and as a standalone CLI (`boris-package`). Its tests do not use any mock or hostile substitution for `pipeline.run` or `rag.run`; they exercise the live pipeline against real fixture content trees. Therefore confidence provided is high for the **integration path** — archive membership, determinism, atomic-install safety, content-failure isolation, and CLI flag parsing — but the tests make no effort to simulate filesystem-level fault injection beyond the single deliberate `test_fail_before_archive_install` injection point.

What the file does not prove: behaviour under concurrent archive readers during the swap window; cross-volume rename safety (explicitly disclaimed in a doc-comment); correctness of the underlying IR or RAG content (delegated entirely to `pipeline.run` and `rag.run`); correctness of SHA256 computation for very large files; behaviour if the `packages/` directory is on a filesystem that silently reorders writes.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module + CLI binary entry point + integration test host |
| Conceptual domain | Archive packaging, deterministic publish, CLI argument parsing |
| Build or test root | Compiled as both a library (imported by the CLI build step) and as the root of the `boris-package` executable; tests live inline |
| Production runtime dependency | Yes — `pipeline.zig`, `rag.zig`, `json_out.zig`, `std.crypto.hash.sha2.Sha256`, `std.tar.Writer` |
| Expected execution command | `zig build test` (for the test suite); `boris-package [--input DIR] [--packages-dir DIR] [--archive NAME] [--with-rag|--no-rag] [--quiet]` (CLI) |
| Main collaborators | `src/pipeline.zig` (IR compile + `FailureKind`), `src/rag.zig` (RAG export + `catalog_format`, `catalog_schema_version`), `src/json_out.zig` (JSON string/integer helpers) |
| Documentation depth warranted | High — governs the publish safety contract and the only stable machine-readable versioning artifact (`MACHINE-READABLE-VERSION.json`) |

## Role in the Boris architecture

`src/package.zig` sits at the outermost layer of the build pipeline, after both IR and RAG emission are complete. It does not participate in content parsing, graph validation, or HTML rendering; those concerns belong entirely to `pipeline.zig` and `rag.zig`.

Relative to the **product binary** (`boris` or the primary CLI), `package.zig` provides an entirely independent delivery mechanism. It does not alter `pipeline.run` behaviour, the `schemaVersion` of the IR, or the HTML output path. It calls `pipeline.run` and `rag.run` as opaque black boxes, consuming only their `Result`/`RagResult` structures and the files those functions write to the stage directory.

Relative to `src/apex.zig` and the ApexMarkdown integration: `package.zig` has **no direct dependency** on Apex. It operates on already-compiled IR JSON files on disk; Apex is consumed only inside `pipeline.run` (on the HTML rendering path, which this file explicitly excludes from its scope via the `//! Does **not** change compiler semantics, schemaVersion, or the HTML path` note).

Relative to the **normal test suite**: the tests in this file are integration tests that invoke the full `run` function against the same fixture content trees used by `pipeline.zig` and `rag.zig` tests. They share the real filesystem via `std.testing.io` and the real allocator. There is no stubbing of sub-systems.

Relative to **specialized ABI validation**: this file is entirely Zig-only. It exercises no C ABI boundary.

The module is **not linked into the production `boris` binary** in any way that would cause its `main` function to execute; it is compiled as a separate executable (`boris-package`) and as a test target.
