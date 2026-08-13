---
title: "`src/aside.zig` surface and execution"
id: docs/boris/src/aside/surface-and-execution
parent: docs/boris/src/aside
status: draft
tags: [boris, zig, source-reference, surface, aside]
---

# `src/aside.zig` surface and execution

## Module structure

1. **Bounds and allowlists** — `max_aside_id_bytes`, `max_details_summary_bytes`, `allowed_kinds`, `isAllowedKind`, `isValidAsideId`, `isValidDetailsSummary`.
2. **Public types** — `Aside`, `Details`, `Segment`, `DiagKind`, `Diagnostic`, `TokenizeResult`.
3. **Line/fence helpers** — `lineColAt`, `atLineStart`, `fenceAtLineStart`, `isPascalComponentName`, incremental `syncPos` cursor inside `tokenizeBody`.
4. **Attribute parsers** — `parseAttributes`, `parseDetailsAttributes`, `appendAttributeDiagnostic`.
5. **Tokenizer** — `tokenizeBody`, alias `parseBodySegmentsSimple`.
6. **HTML render** — `sanitizeClass`, `appendEscapedAttr`, `kindLabel`, `renderHtml`, `renderDetailsHtml`.
7. **RAG export** — `formatRagDirective`, `formatDetailsRagDirective`, `exportBodyWithDirectives`.
8. **Embedded tests** — tokenize matrix, render sinks, RAG shapes, U15/U15b Oliver stream order.

***

## Exported public surface

| Symbol | Kind | Purpose |
| :-- | :-- | :-- |
| `max_aside_id_bytes` | `usize` const | 64 — id length cap |
| `max_details_summary_bytes` | `usize` const | 256 — summary length cap |
| `allowed_kinds` | `[]const []const u8` | `note`, `tip`, `info`, `warning`, `danger` |
| `isAllowedKind` | fn | Exact lowercase kind membership |
| `isValidAsideId` | fn | Safe-anchor grammar `[A-Za-z0-9][A-Za-z0-9_-]{0,63}` |
| `isValidDetailsSummary` | fn | Non-empty plain text, no CR/LF, ≤256 bytes |
| `Aside` | struct | kind, id, body, raw_span, line, column (source views) |
| `Details` | struct | summary, id, open, body, raw_span, line, column |
| `Segment` | union(enum) | `markdown` \| `aside` \| `details` |
| `DiagKind` | enum | Stable component diagnostic kinds |
| `Diagnostic` | struct | kind, line, column, message, name |
| `TokenizeResult` | struct | segments, asides, details, diagnostics; `hasErrors()` |
| `tokenizeBody` | fn | Primary entry; requires valid UTF-8 |
| `parseBodySegmentsSimple` | fn | Alias for harness/fuzz |
| `renderHtml` | fn | Aside → admonition HTML via Oliver on body |
| `renderDetailsHtml` | fn | Details → native `<details>` HTML via Oliver on body |
| `formatRagDirective` | fn | Aside → `:::kind` / `:::kind{id="…"}` block |
| `formatDetailsRagDirective` | fn | Details → export-only `:::details` directive |
| `exportBodyWithDirectives` | fn | Rebuild body: md via caller prep + component directives |
| `diagnosticMessage` | fn | Returns `d.message` (pipeline mapping helper) |

Private: attribute parsers, fence/line helpers, `sanitizeClass`, `appendEscapedAttr`, `kindLabel`, `OpenState`.

***

## Bounds and allowlists

- **Kinds:** closed list, exact spellings, lowercase only. Default Aside kind when `kind`/`type` omitted is `"note"`.
- **Ids:** length 1..64; first char alnum; rest alnum, `_`, `-`. Leading `-` rejected. Used for HTML `id=` and RAG `{id="…"}`.
- **Details summary:** required; 1..256 bytes; no `\n` or `\r` (keeps open tags single-line). Not Markdown — rendered escaped.
- **Details `open`:** only `open="true"` accepted; absence means closed; `open="false"` is `invalid_open`.

These caps are product policy, not allocator limits. Oversized or illegal values become diagnostics, not silent truncation (except `sanitizeClass` on render, which only affects CSS class stems from already-allowlisted kinds).

***

## Types and lifetime

`Aside` / `Details` string fields are **slices into the parent page body source** (zero-copy). `raw_span` covers the full open…close extent for diagnostics. `line` / `column` are 1-based within the scanned buffer (body-relative when the caller passes body only).

`Segment` preserves document order: interleaving markdown slices with component values. Consumers must not assume a single markdown blob.

`TokenizeResult` arrays are allocator-owned (typically document arena). `hasErrors()` is `diagnostics.len > 0`. On attribute or nesting errors, the tokenizer still advances and may leave open spans as markdown rather than emitting partial component segments — unterminated open at EOF records `unterminated_component` and does not emit a partial aside segment.

***

## Recognition rules

| Rule | Behavior |
| :-- | :-- |
| Fence awareness | ``````` / `~~~` at line start (≤3 space indent, run ≥3); inside fence, no component recognition |
| Open tag shape | `<` + PascalCase name + boundary (space, `/`, `>`, tab, CR, LF) |
| Registered names | Only `Aside` and `Details`; other PascalCase → `unregistered_component` |
| Attributes | Single-line preferred; quoted `"…"` values only; `kind`/`type`, `id` for Aside; `summary`, `id`, `open` for Details |
| Close tag | Only at logical line start (optional leading spaces/tabs); must match open component; mid-line close ignored as close |
| Nesting | Second open while open → `nested_component`; mismatched close name → nested/cross diagnostic |
| Empty body | Valid; empty markdown segment emitted when entire body empty |

**Attribute scan hardening:** finding `>` walks with a quote flag; newline clears quote mode and breaks so an unmatched `"` cannot suppress `>` for the rest of the file (avoids O(N²) rescans). Missing `>` → `missing_close_angle`.

**Legacy alias:** attribute key `type` is accepted as synonym for `kind` on Aside (same allowlist, same slot, still duplicate-sensitive).

***

## `tokenizeBody`

```text
tokenizeBody(body, allocator)
  → utf8ValidateSlice or error.InvalidUtf8
  → single forward scan with:
       fence state, optional OpenState,
       incremental line/col cursor (O(N), not full rescans)
  → on open Aside/Details: parse attrs or appendAttributeDiagnostic
  → on line-start close: flush md before open, emit Aside/Details + segment
  → EOF: unterminated diagnostic if still open; trailing markdown segment
  → TokenizeResult
```

Allocation: four `ArrayList`s (segments, asides, details, diagnostics) with `errdefer` deinit, then `toOwnedSlice`. No recursion. Close-tag matching uses fixed prefixes `&lt;/Aside&gt;` (8) and `&lt;/Details&gt;` (10) after optional whitespace.

**What it does not do:** expand includes, resolve wiki links, parse Markdown inside the component shell (inner body remains raw Markdown for later Oliver), or mutate the source buffer.

***

## HTML projection

### `renderHtml`

Builds:

```html
<aside class="admonition admonition--{kind}" [id="…"] aria-label="{Label}">
<p class="admonition__title">{Label}</p>
<div class="admonition__body">
{render.render(body)}
</div>
</aside>
```

- Inner body goes through `render.render` on the **same** document `ArenaAllocator` (Whiteboard).
- Empty body → empty inner string (no render call).
- `id` and `aria-label` pass through `appendEscapedAttr` (`&`, `"`, `<`, `>`).
- Class stem from `sanitizeClass` (allowlisted kinds already safe; empty falls back to `note`).
- Output bytes are arena-owned; caller must keep the Whiteboard alive until flush.


### `renderDetailsHtml`

Builds native:

```html
<details class="details" [id="…"] [open]>
<summary>{escaped summary}</summary>
<div class="details__body">
{render.render(body)}
</div>
</details>
```

Summary is never Markdown-rendered — only escaped text. Matches the platform disclosure pattern used in default layout CSS (`.details`, `.admonition--*`).

***

## RAG projection

| API | Export shape |
| :-- | :-- |
| `formatRagDirective` | `:::kind` or `:::kind{id="id"}\n` + trimmed body + `\n:::\n` |
| `formatDetailsRagDirective` | `:::details summary="…" [id="…"] [open="true"]` with attribute escaping + body + closing `:::` |
| `exportBodyWithDirectives` | Walk segments; markdown via caller `prepare_md`; components via the two formatters |

Export is **not** round-trippable authoring syntax. Hardening tests assert RAG pages contain `:::tip{id="t1"}` (etc.) and **not** raw `&lt;Aside`. Id in Aside RAG path is appended without HTML escaping in `formatRagDirective` because tokenize already enforced safe-anchor grammar; Details summaries are escaped because they are free text.

***

## Diagnostics

| `DiagKind` | Typical cause |
| :-- | :-- |
| `unregistered_component` | `&lt;Figure>`, `&lt;Broside>`, other PascalCase |
| `unterminated_component` | Missing line-start close |
| `nested_component` | Nested/cross open or wrong close name |
| `invalid_kind` | kind not in allowlist |
| `invalid_id` | id grammar/length |
| `invalid_summary` | missing/empty/too long/newline in summary |
| `invalid_open` | `open` not exactly `true` |
| `duplicate_attribute` | repeated key (incl. kind+type) |
| `unknown_attribute` | e.g. `class=` |
| `unterminated_quote` | missing closing `"` |
| `malformed_attribute` | unquoted value, bad key shape |
| `missing_close_angle` | open tag without `>` |

Pipeline maps these to `diag.Code.ECOMPONENT` with remediation pointing at allowlisted Aside/Details usage outside fences. Messages are static string literals (not allocator-owned) except when the pipeline wraps them with the component name.

***

## Collaboration map

```text
parser body slice
       │
       ▼
aside.tokenizeBody ──► TokenizeResult
       │                    │
       │                    ├─► pipeline/rag: diagnostics → ECOMPONENT
       │                    ├─► rag/ragemit: formatRagDirective*
       │                    └─► html_body/compile: segment walk
       │                              │
       │                              ├─ markdown → render.render
       │                              ├─ aside    → renderHtml → render.render(body)
       │                              └─ details  → renderDetailsHtml → render.render(body)
       ▼
layouts CSS (.admonition--*, .details)
```

`build.zig` links `render_mod` into `aside_mod` because unit tests call the real `render.render` (U15/U15b and `renderHtml` tests).

***

## Residual risks and review notes

| Item | Classification | Notes |
| :-- | :-- | :-- |
| Mid-line `&lt;/Aside&gt;` does not close | Documented limitation | By contract; authors must close at line start |
| `type` alias for `kind` | Documented compatibility | Still single slot; duplicates error |
| Aside RAG id not HTML-escaped in `formatRagDirective` | Acceptable given grammar | Depends on tokenize validation; do not bypass |
| `sanitizeClass` silently drops bad chars | Defense in depth | Kinds already allowlisted at parse |
| Component body may contain fence-like text | OK | Inner body not re-tokenized for nested components; nesting already rejected at open |
| Large bodies | Bounded by page source limits upstream | No extra aside-specific size cap on body text |
| Parallel HTML `--jobs` | Safe w.r.t. aside | Pure functions + per-doc arena; Oliver is stateless, so no serialization is needed |

**Phased suggestions (non-blocking):** keep any new component behind the same PascalCase + allowlisted-attr pattern; add contract fixture golden for `:::details` if not already under `docs/contracts/`; prefer extending tests over widening grammar when migration-lab encounters Starlight-like tags.

***

## Acceptance criteria (module health)

- `zig build test` runs `aside_tests` green with the render seam linked.
- Unregistered tags fail IR with `ECOMPONENT` (`hardening_test` / component-fail fixture).
- Valid Aside appears in RAG as `:::kind` without raw tags; Details as `:::details` with escaped summary.
- HTML publish emits `.admonition--*` / `<details class="details"` and never leaves raw `&lt;Aside` in output for valid input.
- U15/U15b preserve document order and nested Oliver features inside aside bodies.

***

## Confidence

| Area | Level | Basis |
| :-- | :-- | :-- |
| Closed grammar \& diagnostics | High | Broad embedded matrix + hardening |
| Fence / line-start close | High | Dedicated tests; scan hardened for quote/newline |
| HTML/RAG projection | High | Unit + e2e determinism tests |
| Adversarial multi-byte/tag soup | Medium | Fuzz module imports alias; not fully enumerated here |
| Future multi-component registry | N/A | Explicit non-goal until designed |

<!-- BORIS-SOURCE-DOC END -->
<span style="display:none">[^3_1][^3_2][^3_3]</span>

<div align="center">⁂</div>

[^3_1]: boris-source-1.md

[^3_2]: boris-source-2.md

[^3_3]: boris-source-3.md


---

# in the same style review please evaluate src/assemble.zig
