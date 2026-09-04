# Code-health audit report — links, asides, and render

**Card:** [#812](https://github.com/drawmeanelephant/boris/issues/812) (milestone
[Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic
[#807](https://github.com/drawmeanelephant/boris/issues/807))
**Authority:** review only — no product-code changes on this card. Findings
filed individually: [#858], [#859], [#860], [#861], [#862], [#863], [#864].
**Commit audited:** `main` @ `3b1c912e` (branch `audit/812-links-asides-render`)
**Zig:** 0.16.0, macOS arm64 (darwin)
**Gate:** `zig build test` green before probes and re-run green after (exit 0).

## Setup

- Fresh branch `audit/812-links-asides-render` from `main` tip `3b1c912e`
  (== `origin/main`).
- `zig build test` → exit 0 before any probe work.
- Black-box probes: `zig build` binary `zig-out/bin/boris` run against six
  sibling scaffolded sites (`boris init`, then replaced `content/`) under the
  approved tmp tree; per-probe exit codes and output pasted below.
- Contracts read first: `docs/contracts/includes-and-wiki-links.md`,
  `documentation-links.md`, `components.md`, `oliver-renderer.md`.
- Locus files read in full: `src/wikilink.zig` (1547), `src/include.zig` (1297),
  `src/doclink.zig` (570), `src/aside.zig` (1345), `src/render.zig` (980).
- Cross-file checks: pipeline order in `src/html_body.zig:274-369`
  (doclink → include → wiki → assets → aside; matches both link contracts),
  `src/rag.zig` `:::` absence, Oliver import surface (`render.zig`,
  `cooklang_seam.zig`, `recipe_scale.zig`).

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| B1a | Unresolved wikilink | `[[no/such/page]]`; `boris --quiet` | `error: EREFERENCEMISSING: index.md:6:5: wiki-link target "no/such/page" not found in the page graph [remediation]`, exit 1; no generic re-print | Non-issue (contract-conformant) | wikilink.zig:552-557, 768-834; diag format matches contract §Diagnostics |
| B1b | Missing heading fragment | `[[index#no-such-heading]]` | `EREFERENCEMISSING … wiki-link heading target "index#no-such-heading" not found on the page`, exit 1; no silent fallback to page-only URL | Non-issue | wikilink.zig:445-475 checkFragment; contract "no silent fall-back" honored |
| B1c | Empty fragment + bad id | `[[index#]]`, `[[ok id]]` | `EREFERENCESYNTAX … malformed wiki-link near "index"`, exit 1 (first failure wins) | Non-issue | wikilink.zig:217-243; unit `scanWikiLinks empty fragment is syntax` OK |
| B2a | Include cycle A↔B | `a.md→b.md→a.md`; `boris --quiet` | `error: EINCLUDECYCLE: includes/b.md:1:8: include cycle involving "includes/a.md"`, exit 1; locus = nested fragment holding the directive | Non-issue | include.zig:470-509 cycle stack; contract locus rule (§Diagnostics) honored |
| B2b | Illegal / missing include | `{{include ../outside.md}}`, `{{include includes/gone.md}}` | `EINVALIDPATH` then `EINCLUDEMISSING`, exit 1 both, full-source line numbers correct | Non-issue | include.zig:104-130, 737-759; unit `diagnostic lines are full-source` OK |
| B2c | `{{include` without whitespace | `{{includeincludes/x.md}}` | exit 0; literal `{{includeincludes/x.md}}` published verbatim | Non-issue (grammar-conformant: directive form requires whitespace) | include.zig:389-395; contract author-syntax table |
| B3a | Nested Aside | `<Aside>` inside `<Aside>` | `ECOMPONENT … nested or cross-nested component is not supported`, exit 1 | Non-issue | aside.zig:616-627; unit `tokenize: nested Aside` OK |
| B3b | Cross-nested close | `</Details>` closing an Aside | two diagnostics: cross-nested close + unterminated Aside, exit 1 | Non-issue (both accurate; contract forbids cross-nesting) | aside.zig:515-531, 653-662; unit `Details rejects closed grammar and cross nesting` OK |
| B3c | Unregistered tag / invalid kind | `<Figure>`, `kind="banana"` | `ECOMPONENT … unregistered component tag` / `invalid Aside kind`, exit 1 | Non-issue | aside.zig:604-614, 308-313; units OK |
| B4 | Oliver fidelity spot-check | headings + IAL + `~~x~~` + footnote + dl + table + Aside + Details + wikilink | All match contract/golden byte shapes: `<h1 id="hello-world">`, `<h2 id="exit-codes">`, `<del>`, `<dl>`, `<table>`, components.md Details HTML byte-exact, wiki href relative — **except the footnote (B4b)** | Non-issue per construct; footnote split → **Confirmed defect → [#860]** | render.zig unit goldens; components.md §Details authoring HTML example |
| B4b | Footnote split by a component | ref before `<Aside>`, def after | `footnote-ref` count 0, definition text count 0, exit 0 — literal `[^1]` published, definition silently dropped; same-segment control renders correctly | **Confirmed defect (medium) → [#860]** | html_body.zig:251-261 per-segment render; aside.zig:738-791 |
| B5a | 3-space-indented fence (balanced) | `   ```…[[no/such/page]]…``` ` | exit 0, link literal in code block (accidentally correct: span pairing swallows the region) | Symptom of **Confirmed defect → [#858]** | wikilink.zig:111-120 (no indent tolerance); unit probe `hits=0` |
| B5b | Indented fence, unbalanced span | stray content after indented fence | `EREFERENCEMISSING` exit 1 on code-block content (spurious) | **Confirmed defect → [#858]** | repro in #858 |
| B5c | Indented fence, existing target, unbalanced | `   ``` ` + `[[fidelity-page]]` | exit 0; published code block contains `[Fidelity Page](fidelity-page.html)` (silent rewrite inside code) | **Confirmed defect → [#858]** | repro in #858 |
| B5d | Include inside indented fence | `   ``` ` + `{{include includes/real.md}}` | exit 0; published code block contains `REAL_INCLUDE_CONTENT` — expansion inside fenced code | **Confirmed defect (medium) → [#859]** | include.zig:167-176, 649-656; repro in #859 |
| B6a | Doc link after blank line inside Aside | blank line after `<Aside …>` | rewritten to `fidelity-page.html`, exit 0 | Non-issue | doclink.zig:352-359 block ends at blank line |
| B6b | Compact Aside (no blank line) + doc link | link on the line after `<Aside …>` | not rewritten; `EROUTEMISSING: href="fidelity-page.md" does not resolve`, `LinkAuditFailed`, exit 1 | **Confirmed defect (low) → [#861]** | doclink.zig:66-94 `isBlockHtmlTag("aside")` |
| B6c | Stray unmatched backtick + later doc link | `` Stray ` tick `` then valid link | link not rewritten; same `EROUTEMISSING`/`LinkAuditFailed`, exit 1 | **Confirmed defect (low) → [#862]** | doclink.zig:402-407 persistent `code_run` |
| W1 | RAG `:::kind` projection claim | `rg ':::' src/rag.zig src/aside.zig` | aside.zig:22-24 documents the export form; rag.zig:1441/1773 assert its absence; components.md says removed | **Confirmed defect (doc-only, low) → [#863]** | components.md:145-148 normative |
| W2 | Oliver import surface vs "only render.zig" | `rg 'import\("oliver"\)' src` | 3 importers; oliver-renderer.md:32-33 contradicts its own header + cooklang-compatibility.md:327 | **Confirmed defect (doc-only, low) → [#864]** | contract self-contradiction |
| W3 | Pipeline order vs contracts | `src/html_body.zig:274-369` | doclink → include → wiki → assets → aside tokenize, fixed order as both contracts specify | Non-issue | documentation-links.md §Rewrite boundary; includes-and-wiki-links.md §Resolve order |

## Findings

1. **[#858] Confirmed defect (medium):** wiki-link scanner misreads
   CommonMark-indented (≤3-space) fences — spurious `EREFERENCEMISSING` on
   code content and silent rewrites inside published code blocks.
   Locus `src/wikilink.zig:111-120, 203-210`.
2. **[#859] Confirmed defect (medium):** `{{include}}` expanded inside
   CommonMark-indented fenced code blocks, violating the contract's
   no-expansion-in-code rule. Locus `src/include.zig:167-176, 649-656`.
3. **[#860] Confirmed defect (medium):** a footnote reference/definition pair
   split by an Aside/Details loses the definition and publishes the reference
   literal — per-segment Oliver parses share no footnote state.
   Locus `src/html_body.zig:251-261`, `src/aside.zig:738-791`.
4. **[#861] Confirmed defect (low):** compact `<Aside>` bodies are skipped by
   the doc-link rewriter as raw-HTML blocks; the surviving `.md` href fails the
   link audit with a misleading `EROUTEMISSING`. Locus `src/doclink.zig:66-94`.
5. **[#862] Confirmed defect (low):** an unmatched backtick run latches the
   doc-link rewriter's code state for the rest of the body, suppressing all
   later rewrites (diverges from include/aside scanners). Locus
   `src/doclink.zig:402-407`.
6. **[#863] Confirmed defect (doc-only, low):** `aside.zig` header still
   documents the removed `:::kind` RAG export form. Locus `src/aside.zig:22-24`.
7. **[#864] Confirmed defect (doc-only, low):** `oliver-renderer.md` claims
   `render.zig` is the only Oliver API consumer, contradicting its own header
   and `cooklang_seam.zig`/`recipe_scale.zig`. Locus
   `docs/contracts/oliver-renderer.md:32-33`.

Non-issue observations recorded for the record (no action):

- `{{include` not followed by whitespace stays literal and builds clean
  (include.zig:389-395) — the directive form contractually requires
  whitespace; braces have no reserved meaning otherwise.
- Cross-nested close (`</Details>` while Aside open) emits two diagnostics
  (cross-nest + unterminated) — both individually accurate.
- `doclink.zig:154` contains a dead conditional (`if (…) i else i`) —
  cosmetic, both branches identical.
- Diagnostics across B1/B2 report full-source lines (frontmatter-adjusted) and
  nested loci per the contract's locus rule; exit codes are 1 for every content
  failure observed, with no generic `IncludeFailed`/`ReferenceFailed` re-print
  after a structured diagnostic.

## Exit checklist

- [x] 4 contracts read before the locus files
- [x] 5 locus files read in full; drift checked both directions
- [x] ≥3 falsification probes (21 black-box runs across B1–B6 + 3 white-box cross-checks + unit probe), ≥2 black-box: satisfied
- [x] Every material observation classified exactly once
- [x] Findings filed individually: #858–#860 (Confirmed/medium), #861–#862 (Confirmed/low), #863–#864 (Confirmed/doc-only/low)
- [x] `zig build test` green before and after probe work (exit 0 both runs)
- [x] Report PR targeting `main` (this PR)
- [x] Close-out comment posted on #812 with the mandated template
