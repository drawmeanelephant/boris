---
title: "`src/aside.zig` overview"
id: docs/boris/src/aside
status: draft
tags: [boris, zig, source-reference, aside]
---

# `src/aside.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/aside/surface-and-execution|Surface and execution]]
* [[docs/boris/src/aside/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/aside/review-state|Review state]]

## Executive summary

`src/aside.zig` is the constrained authoring-component tokenizer and projection layer for Boris milestone 10. It recognizes exactly two PascalCase tags — `&lt;Aside>` and `&lt;Details>` — outside CommonMark-style fenced code, validates a closed attribute grammar, and projects each match into three product surfaces: ordered body segments for HTML streaming, structured records for diagnostics, and non-round-trippable RAG directive blocks for export. It is not generic HTML parsing, not MDX, and not a multi-component registry. Unknown PascalCase open tags are hard errors (`unregistered_component` → pipeline `ECOMPONENT`).

The module exists because Boris keeps admonitions and disclosures as **in-document tokens**, not graph nodes or separate pages. Trunk/Satellite topology stays in `graph.zig`; asides stay in source order inside a page body. That separation lets IR validation, HTML publish, and RAG export share one parse of the body without inventing standalone aside routes or executable component semantics.

Callers that depend on it include `html_body.zig` (ordered HTML body pipeline), `pipeline.zig` / `rag.zig` (shared compile validation and `:::kind` / `:::details` export), `compile.zig` (via the body path), `hardening_test.zig`, and the fuzz harness via `parseBodySegmentsSimple`. Build wiring creates `aside_mod` from this file, links Apex (`linkApex(..., false)`), and runs `aside_tests` under `zig build test`.

Correctness properties the module owns: fence-aware recognition; line-start-only close tags; no nesting or cross-nesting; allowlisted Aside kinds; safe-anchor ids; plain-text Details summaries; quoted attributes only; UTF-8 gate on tokenize; HTML attribute escaping at render sinks; document-order segment stream; RAG export that drops raw `&lt;Aside>`/`&lt;Details>` tags. What it does not own: full Markdown rendering of outer page prose (Apex does that), layout chrome, graph identity, or a general component plugin system.

Confidence is high on the closed grammar and happy/error unit matrix embedded in the file, and on end-to-end hardening coverage (invalid component → `ECOMPONENT`; valid Aside/Details through IR, RAG, and HTML). Residual risk is concentrated in adversarial edge cases at the fence/tag boundary, attribute scan on malformed multi-line tags (mitigated by newline ending quote mode), and the fact that HTML render trusts already-tokenized structs — bypassing tokenize can still feed hostile ids into escape sinks (defensively escaped, but not re-validated).

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production component tokenizer + HTML/RAG projectors + embedded unit tests |
| Conceptual domain | In-page Aside/Details authoring; segment stream; `ECOMPONENT` diagnostics |
| Build or test root | Root of `aside_mod` / `aside_tests` (`zig build test`); also imported by pipeline, rag, html_body, compile, hardening, fuzz |
| Production runtime dependency | Yes — HTML body path, IR/RAG component validation, RAG export projection |
| Expected execution command | `zig build test` (aside unit tests + hardening integration) |
| Main collaborators | `apex.zig` (inner Markdown → HTML), `html_body.zig`, `pipeline.zig`, `rag.zig` / `ragemit.zig`, `diag.zig`, `build.zig`, `docs/contracts/components.md` |
| Documentation depth warranted | High — authoring contract surface; every diagnostic kind maps to product exit behavior |


***

## Role in the Boris architecture

In the product pipeline, body handling is ordered roughly as: parse frontmatter → optional Textile adapt → includes → wiki/doc links → content-local assets → **Aside/Details tokenize** → stream markdown segments through Apex and component segments through `renderHtml` / `renderDetailsHtml`. `aside.zig` is the tokenize + component-render leaf of that chain. IR and RAG reuse the same tokenizer so an unregistered `&lt;Figure>` fails content validation with `ECOMPONENT` whether or not HTML is published.

Asides are never first-class graph nodes. Entity catalogs and parent edges ignore them; document order is preserved in HTML and in RAG page bodies as `:::tip` / `:::details` blocks. That matches AGENTS policy: no standalone HTML/RAG pages per aside; no arbitrary MDX.

Against non-goals: the module refuses nested components, unknown attributes, unquoted values, and brand-named pseudo-tags (`Broside`). Extension requires an explicit grammar change and tests — not a runtime registry string.

***
