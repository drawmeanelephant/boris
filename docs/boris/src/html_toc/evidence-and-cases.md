---
title: "`src/html_toc.zig` evidence and cases"
id: docs/boris/src/html_toc/evidence-and-cases
parent: docs/boris/src/html_toc
status: draft
tags: [boris, zig, source-reference, evidence, html_toc]
---

# `src/html_toc.zig` evidence and cases

## Parser design and documented edge cases

The heading scanner is a straightforward linear byte scan without a full HTML parser. This is deliberate: it operates on HTML already produced by a well-behaved renderer (Apex), not on untrusted author HTML. Three notable design choices are documented by tests:

**Tag-boundary guard:** After matching `<h`, the scanner checks that the next byte after the digit is `>`, space, tab, CR, or LF — or is at the end of the buffer. This prevents false matches on element names like `<header` or `<h-custom`. The test `collectHeadings h1-h3 with ids; skip h4` implicitly validates level filtering; the tag-boundary logic is structural.

**Quoted `>` inside attributes:** `findTagEnd` tracks single- and double-quote state to avoid treating `>` inside attribute values as the end of the opening tag. This is tested directly by `collectHeadings ignores > inside attribute values` and the more complex `collectHeadings ignores greater-than inside quoted heading attributes`. Without this, a heading like `<h2 id="x" title="a>b">` would be incorrectly truncated at the `>` inside `title`.

**`id` attribute extraction:** `extractIdAttr` performs a linear attribute-name parse starting at byte 3 of the opening tag. It correctly skips the `data-id` attribute name (because that name does not case-insensitively equal `"id"`) and validates that it has consumed an exact `id` token rather than a prefix. A title attribute containing the text `id='fake'` is not mistaken for the `id` attribute because it is parsed as the *value* of the `title` attribute. The test `collectHeadings ignores greater-than inside quoted heading attributes` covers a compound hostile case: `title="1 > 0 and id='fake'"`, `data-id="also-fake"`, and `id = 'real'` (with spaces around `=`) all appear on the same tag, and the parser returns `"real"` — confirmed directly by assertion.

**Unclosed tags in inner HTML:** `stripTags` drops all content from an unclosed `<` to end of string rather than returning an error. This is a documented soft-failure; the implication is that malformed inner HTML silently truncates the text value. No test asserts this behavior; it is code-structural.

**HTML entity pass-through:** `stripTags` does not decode or re-encode entities. Entities from Apex (e.g., `&amp;`) are preserved literally in `Heading.text`, and `renderToc` passes them through to the output without re-escaping. The entity-double-escape test (`renderToc emits a labeled list landmark and preserves rendered text entities`) verifies that `A &amp;` in the inner HTML produces `A &amp;` in the TOC text (correct — the entity was already escaped by Apex) and that the extracted `id` value `a&amp;b&lt;c&gt;` is re-escaped by `appendEscaped` when placed in the `href` attribute, producing `a&amp;amp;b&amp;lt;c&amp;gt;` (double-escaped, which is the correct output because the raw `id` bytes contain literal `&`, `<`, `>`).

***

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `collectHeadings h1-h3 with ids; skip h4` | test | Level filtering, entity preservation in text | HTML with h1/h2/h3/h4 entries | 4 headings (not the h4); correct level, id, and text | h4 excluded by `toc_max_level = 3`; entities preserved in text |
| `collectHeadings ignores > inside attribute values` | test | Quoted `>` in attributes does not truncate tag | Two h2s with `title="a>b"` before or after `id` | Both headings collected with correct ids and stripped text | `findTagEnd` quote tracking |
| `renderToc empty when no headings` | test | Empty HTML → empty string, not error or null | `<p>no headings</p>` | `""` (allocated) | `renderToc` returns empty owned slice |
| `renderToc shape and anchors` | test | TOC HTML structure, ARIA, CSS class, tag stripping | h1 + h2 with `<em>` in inner content | Contains `page-toc`, ARIA label, `href="#top"`, `href="#sec"`, `page-toc__l1`, `page-toc__l2`; text `Section X` (em stripped) | HTML shape; `stripTags` removes inline elements |
| `renderToc emits a labeled list landmark and preserves rendered text entities` | test | Entity and id escaping; exact output | h2 with entity-laden id and entity+em in inner text | Exact full HTML string checked; id double-escaped in href; entity preserved in text; em stripped | Entity pass-through + `appendEscaped` on id value |
| `renderToc skips headings without id` | test | Headings without `id` are omitted from TOC | h2 without id + h2 with id | Only `href="#has"` present; `No id` absent | `extractIdAttr` returning null causes skip |
| `collectHeadings ignores greater-than inside quoted heading attributes` | test | Complex attribute parsing: `>` in title value, `data-id`, `id` with spaces around `=`, unquoted then quoted id | Single h2 with all three | Exactly one heading; `id = "real"`, text `"Real Title"` (em in inner stripped) | `extractIdAttr` exact-name match; `findTagEnd` quote tracking; `stripTags` inner tag removal |
| `collectHeadings frees stripped text when append allocation fails` | test | OOM cleanup: allocated `text` must not leak if `out.append` fails | `checkAllAllocationFailures` wrapping one-heading parse | No memory leak under any allocation-failure permutation | `errdefer`-equivalent: `allocator.free(text)` before propagating append error |
| `collectHeadingIds h1-h6 unique set includes h4` | test | Deduplication, h4 inclusion, owned copies | HTML with h1, h2 (duplicated), h4 | 3 entries: `"top"`, `"sec"`, `"deep"`; duplicate sec omitted | `StringHashMapUnmanaged` dedup; `fragment_max_level = 6` |

***

## Control flow

```text
renderToc(allocator, body_html)
    → collectHeadings(allocator, html, &headings)
        → collectHeadingsInRange(allocator, html, 1, 3, &headings)
            linear scan: find "<h"
            → tag-boundary check (next byte after digit)
            → level range filter
            → findTagEnd(html, open)   [quote-aware scan for ">"]
            → extractIdAttr(open_tag)  [attribute-name parse]
            → find close pattern "</hN>"
            → stripTags(allocator, inner)
                [fast path: dupe trimmed slice if no "<" present]
                [slow path: ArrayList accumulation, skip tags via findTagEnd]
            → out.append(allocator, Heading{…})
                [on error: allocator.free(text); return err]
    if headings empty → return allocator.dupe(u8, "")
    buf construction:
        appendSlice "<nav class=\"page-toc\"…"
        for each heading:
            appendSlice "<li class=\"page-toc__lN\">"
            appendSlice "<a href=\"#"
            → html_nav.appendEscaped(&buf, allocator, h.id)
            appendSlice "\">"
            appendSlice h.text           [entities from Apex passed through]
            appendSlice "</a></li>\n"
        appendSlice "</ul>\n</nav>"
    → buf.toOwnedSlice(allocator)  [caller owns result; errdefer guards buf]
```

```text
collectHeadingIds(allocator, html, out)
    → collectHeadingsInRange(allocator, html, 1, 6, &headings)
    seen: StringHashMapUnmanaged
    for each heading:
        skip h.id.len == 0
        seen.getOrPut(allocator, h.id)
            if found_existing → skip
            else:
                allocator.dupe(u8, h.id)  [own the id]
                gop.key_ptr.* = owned      [re-seat map key to owned copy]
                out.append(allocator, owned)
    defer: free headings text, deinit headings list, deinit seen
```
