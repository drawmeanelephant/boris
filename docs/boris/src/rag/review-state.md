---
title: "`src/rag.zig` review state"
id: docs/boris/src/rag/review-state
parent: docs/boris/src/rag
status: draft
tags: [boris, zig, source-reference, review-state, rag]
---

# `src/rag.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

> This section contains observations for future development only. No code changes are proposed here.

- Remove or replace the dead `exportBodyForRag`, `prepareContentBody`, `countAtxH1` helpers and the dead local buffer construction in `exportGraphDocs` and `exportIndex` to eliminate confusion about which code path is authoritative for body normalization.
- Add a unit test for `normalizeRelPath` covering mixed separators, leading `./`, and double slashes.
- Add an integration test or negative test that exercises the `publishCorpus` error branches (`error.RagPublishSwapFailed`, cross-volume copy fallback) using a mock or by simulating rename failure.
- Add a RAG-specific test for I/O failure during compile (unreadable content root) to complement the IR-path test in `src/pipeline.zig`.
- Consider whether the `exportBodyForRag` dead code should be promoted to a shared path (in `src/rag_emit.zig`) or deleted entirely, and document the decision in `docs/contracts/rag-export.md`.
