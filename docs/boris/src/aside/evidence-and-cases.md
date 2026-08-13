---
title: "`src/aside.zig` evidence and cases"
id: docs/boris/src/aside/evidence-and-cases
parent: docs/boris/src/aside
status: draft
tags: [boris, zig, source-reference, evidence, aside]
---

# `src/aside.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- |
| `tokenize: valid Aside with optional id` | test | Happy path segments | 1 aside, 3 segments, kind/id/body | Authoring grammar |
| `tokenize: invalid kind` | test | `banana` | `invalid_kind` | Allowlist |
| `tokenize: duplicate attribute` | test | two `kind` | `duplicate_attribute` | Attr uniqueness |
| `tokenize: unterminated quote` | test | broken quotes | quote/angle/malformed family | Attr scan |
| `tokenize: nested Aside` | test | inner open | `nested_component` | No nesting |
| `tokenize: unknown component` / `Broside` | test | unregistered names | `unregistered_component` + name | Closed registry |
| `tokenize: fenced code keeps Aside literal` | test | fence | 0 asides; literal tags in md | Fence rule |
| `tokenize: real Aside after fence` | test | fence then real | 1 aside | Fence exit |
| `tokenize: unterminated Aside` | test | no close | `unterminated_component` | EOF rule |
| `tokenize: invalid id grammar` | test | `bad!` | `invalid_id` | Id grammar |
| `tokenize: Details rejects…` | test | table of bad Details | matching kinds | Details grammar |
| `tokenize: fenced Details remains literal` | test | fence | 0 details | Fence + Details |
| `tokenize: valid Details… RAG projection` | test | full Details | open flag; escaped RAG | Details + RAG |
| `formatRagDirective export representation` | test | tip+id | exact `:::tip{id="z1"}…` | RAG Aside shape |
| `isValidAsideId grammar` | test | unit | accept/reject matrix | Id helper |
| `tokenize rejects invalid UTF-8` | test | `0xFF 0xFE…` | `error.InvalidUtf8` | Encoding gate |
| `renderHtml wraps tip` / omits id / escapes id | test | HTML sinks | classes, no raw tag, escaped id | HTML Aside |
| `renderDetailsHtml…` | test | native details | open, escaped summary, strong body | HTML Details |
| `U15 Aside document order with real Oliver` | test | stream markers + table in aside | order AAA < aside < BBB; no `&lt;Aside` | HTML body order |
| `U15b Oliver callout inside Aside body` | test | GFM callout in aside | callout survives nested render | Oliver-in-Aside |
| Hardening: invalid component / valid Aside / Details | integration | pipeline/rag/compile | `ECOMPONENT` or clean export/HTML | Shared path |


***

## Correctness properties and non-goals

**Holds (by design + tests):**

- Only Aside/Details are registered components.
- Fenced examples do not tokenize as components.
- Close tags are line-start-only.
- Nesting is rejected; partial unterminated opens are not emitted as components.
- HTML attribute sinks escape active characters.
- RAG export replaces tags with directive blocks; dual-run hardening checks stability for Details across jobs/incremental.
- UTF-8 invalid bodies fail before scan.

**Does not claim:**

- Full HTML5 or MDX parsing.
- Nested admonitions or component composition.
- Sanitization of untrusted author HTML inside Oliver (trusted-author boundary lives at the rendering seam).
- That `renderHtml` re-validates kind/id if called with hand-built structs (escape is last line of defense).
- Independent Markdown semantics for Details summary (plain text only).

***
