# Heading IDs and wiki fragment targets

**Status:** normative — HTML wiki fragments (`[[entity#heading]]`)  
**Modules:** Apex (header ids), [`src/html_toc.zig`](../../src/html_toc.zig) (id
harvest), [`src/wikilink.zig`](../../src/wikilink.zig) (fragment syntax + match)  
**Related:** [includes-and-wiki-links.md](includes-and-wiki-links.md),
[html-output.md](html-output.md), [apex-abi.md](apex-abi.md)

---

## Goals

- One canonical source of heading anchors: **Apex-rendered `id` attributes** on
  heading elements in the page body HTML.
- Wiki section links resolve to those ids exactly — no second Boris slugger.
- Fail loud when the author fragment does not match any rendered id.
- Leave IR graph edge shape and page-only `[[entity-id]]` behavior unchanged.

---

## Canonical heading IDs (Apex)

On the HTML path, after include expansion, wiki rewrite, Aside tokenize, and
Apex render of markdown segments (plus Aside HTML), each heading that Apex
emits with an `id` is a valid anchor target.

| Fact | Rule |
|------|------|
| Generator | ApexMarkdown Unified via the host ABI (`generate_header_ids`, GFM id format) |
| Manual override | MultiMarkdown / Kramdown-style manual ids Apex already supports (e.g. `{#custom-id}`) appear as that `id` when Apex accepts them |
| Levels | `h1`–`h6` with a non-empty `id` are targets (TOC may still list only h1–h3) |
| Harvest | Boris reads `id` attributes from **rendered body HTML** (same approach as `{{toc}}`) — it does **not** re-implement GFM/MMD slug rules in Zig |
| Included content | Headings introduced by `{{include}}` participate after expansion |
| Aside bodies | Headings that appear in the concatenated body stream after Aside render are included |

### Observed Apex / GFM id behavior (product pin)

These are **product observations** of the pinned Apex engine (not a second
spec). Authors should prefer linking to ids visible in TOC or in rendered HTML.

| Input heading | Typical `id` |
|---------------|--------------|
| `## Hello World` | `hello-world` |
| `## Hello, World!` | `hello-world` (punctuation stripped) |
| `## Café résumé` | `caf-rsum` (diacritics removed under GFM path) |
| `## Code \`span\` here` | `code-span-here` (code span text kept) |
| `## **Bold** and *italic*` | `bold-and-italic` |
| `## Dup` then another `## Dup` | **both** `id="dup"` (no auto `-1` / `-2` suffix) |

**Duplicate headings:** Apex may assign the **same** `id` to multiple headings.
That shared string is still a valid fragment target (set membership). Boris does
not invent disambiguating suffixes.

---

## Author syntax (wiki fragment)

```markdown
[[entity-id#heading-id]]
[[entity-id#heading-id|display label]]
```

| Rule | Detail |
|------|--------|
| Entity | Same grammar as page-only wiki links (`identity.validateEntityId`) |
| Separator | Single `#` after the entity id |
| Fragment token | Non-empty run until `\|` or `]]`; no CR/LF; must not contain `]` or `\|` |
| Empty fragment | `[[entity-id#]]` → `EREFERENCESYNTAX` |
| Hash-only | `[[#heading]]` → `EREFERENCESYNTAX` (entity required) |
| Matching | **Byte-exact** equality with a rendered heading `id` on the **target** page |
| Missing entity | `EREFERENCEMISSING` (unchanged) |
| Missing heading | `EREFERENCEMISSING` — **no** silent fall-back to the page URL without fragment |
| Label default | Unchanged: page `title` if set, else entity id |
| Fences | Unchanged: no rewrite inside fenced code |

Page-only forms remain valid and unchanged:

```markdown
[[entity-id]]
[[entity-id|label]]
```

---

## Resolve semantics (HTML)

1. Build a **heading index** for every page entity: expand includes → wiki rewrite
   **without** fragment validation → Aside tokenize → Apex (+ Aside HTML) →
   harvest all non-empty `id` attributes on `h1`–`h6` in document order into a
   per-entity set.
2. On rewrite (fingerprint plan + render): resolve entity → relative page href
   (same as page-only wiki) → if a fragment is present, require it in the
   target entity’s set → append `#` + URL-encoded fragment to the Markdown
   destination.
3. Never rewrite a missing fragment to a bare page link.

### URL escaping

- The **match key** is the exact rendered `id` attribute string.
- In the Markdown link destination, the fragment is emitted with **percent-encoding**
  of characters outside RFC 3986 *unreserved* (`A–Z` `a–z` `0–9` `-` `.` `_` `~`),
  so destinations stay Markdown-safe and browsers decode back to the id string.
- GFM auto-ids are typically already unreserved; exotic manual ids may encode.

### Same-page and cross-page

- Always emit a full relative page path plus fragment (e.g. `guides/a.html#sec`),
  never a bare `#sec`, so trunk and satellite pages share one rule.
- Relative path rules match page-only wiki links (`identity.relativeHref`).

---

## IR / RAG / fingerprints

| Surface | Behavior |
|---------|----------|
| IR `reference` edges | Still **page → page** only; fragment does not create a new edge kind or endpoint |
| IR fragment membership | **Not** validated on the IR path (no Apex render). Malformed `[[…]]` still fails; unknown entity fails; unknown heading is an HTML-only check |
| RAG export | Unchanged; no fragment schema |
| Fingerprint reference material | Still entity id + output path + title (sorted). Fragment presence is validated at HTML plan time against the heading index but does not alter material shape |
| Incremental dirty set | Target body edits change the target fingerprint; reverse `reference` walk dirties dependents that wiki-link the page (including fragment links) |
| Heading-index scope | Only pages that are targets of at least one fragment link are rendered for the index (empty site-wide fragment set → empty index, no extra Apex pass) |

---

## Diagnostics

| Code | When |
|------|------|
| `EREFERENCESYNTAX` | Malformed `[[…]]`, empty fragment after `#`, illegal fragment token |
| `EREFERENCEMISSING` | Unknown entity id **or** known entity but fragment not in its heading id set |

Messages distinguish missing entity vs missing heading; codes stay in the closed
diagnostics set ([diagnostics.md](diagnostics.md)).

---

## Non-goals

- Re-implementing GFM/MMD/Kramdown slug algorithms in Zig.
- Soft warnings or silent page-only fallback for bad fragments.
- Fragment-aware IR edges or schema bump.
- Restricting Markdown heading syntax beyond what Apex already accepts.
- Guaranteeing unique heading ids when Apex emits duplicates.
