---
title: "`src/html_nav.zig` evidence and cases"
id: docs/boris/src/html_nav/evidence-and-cases
parent: docs/boris/src/html_nav
status: draft
tags: [boris, zig, source-reference, evidence, html_nav]
---

# `src/html_nav.zig` evidence and cases

## Test coverage

### Test: `appendEscaped escapes markup`

**Setup:** Allocates a fresh `ArrayList(u8)` with `std.testing.allocator`. Calls `appendEscaped` with the string `"a<b>&\"c"`.

**Assertion:** `expectEqualStrings("a&lt;b&gt;&amp;&quot;c", buf.items)` — exact byte equality.

**Coverage:** Verifies that all four special characters are escaped correctly and that non-special characters pass through unchanged. Does not test multi-byte UTF-8 sequences, NUL bytes, or sequences with consecutive special characters.

***

### Test: `renderNav forest and breadcrumb`

**Setup:** Constructs three nodes (`guides/intro` Trunk, `guides/tips` Satellite of `guides/intro`, `index` Trunk). Runs `graph.validate` → `graph.freeze` → `graph.buildNav`. Locates `guides/tips` in the frozen array by id scan to get `tips_i`.

**Assertions for `renderNav`:**

- Output contains `"site-nav"` (class present)
- Output contains `"is-current"` (current node marked)
- Output contains `"../index.html"` (relative href from `guides/tips.html` to `index.html` crosses a directory)
- Output contains `href="intro.html"` (relative href from `guides/tips.html` to `guides/intro.html` in the same directory is basename-only)

**Assertions for `renderBreadcrumb`:**

- Output contains `"breadcrumb"` (class present)
- Output contains `aria-current="page"` (self item marked)
- Output contains `"Tips"` (title text present)

**Coverage:** Confirms cross-directory relative hrefs, same-directory hrefs, current-node marking, and breadcrumb self-labeling. Does not assert exact byte output; substring checks only.

***

### Test: `renderChildren is id-sorted, escaped, relative, and empty for satellite`

**Setup:** Three nodes — `zeta` (Satellite of `index`), `index` (Trunk), `alpha` (Satellite of `index` with title `"A & &lt;Alpha> \"quoted\""`). Validates → freezes → builds nav.

**Assertions for the Trunk (`index`, `current_index = 1` in frozen order):**

- Output contains `"page-children"` (class present)
- Output contains `href="alpha.html"` (alpha rendered as child)
- Output contains `"A &amp; &lt;Alpha&gt; &quot;quoted&quot;"` (title fully escaped)
- Output contains `href="zeta.html">zeta` (zeta rendered, id used as title fallback)
- `alpha.html` appears before `zeta.html` (id-sorted child order)

**Assertions for the Satellite (`alpha`, `current_index = 0` in frozen order):**

- `renderChildren` returns `""` (empty string literal, not a heap allocation)
- `expectEqualStrings("", satellite)` confirms this

**Coverage:** Directly tests the id-sorted child order guarantee, HTML escaping in child titles, id-fallback display, and the empty-satellite early return. The test correctly does not `defer gpa.free(satellite)` for the empty case, demonstrating correct usage of the mixed-ownership return.

***

### Test: `navigation chrome has deterministic landmarks, lists, current state, and escaped sinks`

**Setup:** Two nodes — `index` (Trunk, title `"Home & &lt;Start> \"quoted\""`) and `guides/intro` (Satellite of `index`). Validates → freezes → builds nav. Locates `index` by id scan.

**Assertions:** Four `expectEqualStrings` calls, each testing exact byte output:

1. `renderNav` output must equal:

```
<nav class="site-nav" aria-label="Site">
<ul>
```

<li class="site-nav__trunk is-current"><a href="index.html" aria-current="page">Home &amp; &lt;Start&gt; &quot;quoted&quot;</a>
```
<ul>
```
<li class="site-nav__satellite"><a href="guides/intro.html">Intro</a></li>
```
</ul>
</li>
</ul>
</nav>

```

```

2. `renderChildren` output must equal:

```
<nav class="page-children" aria-label="Children">
<ul>
<li><a href="guides/intro.html">Intro</a></li>
</ul>
</nav>
```

3. `renderBreadcrumb` output must equal:

```
<nav class="breadcrumb" aria-label="Breadcrumb">
<ol>
```

<li aria-current="page">Home \& <Start> "quoted"</li>

```
</ol>
</nav>
```

4. `renderTitle` output must equal `"Home &amp; &lt;Start&gt; &quot;quoted&quot;"`.

**Coverage:** This is the most rigorous test in the file. It provides exact pixel-level evidence for: CSS class names and values, `aria-label` attribute values, `aria-current` placement, `is-current` co-presence, relative href correctness for root-level pages, child href construction, single-item breadcrumb rendering, and HTML escaping in both title text and (implicitly, since `index.html` has no special characters) href sinks. The test serves as a regression anchor for any change to the rendered HTML structure.

**Gaps:** Does not test `siteNavMaterial`. Does not test a deeper site (3+ levels would be blocked by `EPARENTNOTTRUNK` in the one-level model, so this is not a gap in practice). Does not test a Satellite as the `current_index` for `renderNav` in exact-output mode (only via substring assertions in the previous test).

***

## Control flow

```text
test declaration (e.g. "navigation chrome …")
    │
    ├─ graph.validate(gpa, gpa, &nodes, &diags)
    │       → diagnoseDuplicateIds  (no duplicates → passes)
    │       → validateTopology      (parent resolved → satellite classified)
    │
    ├─ graph.freeze(gpa, &nodes, null)
    │       → sort nodes by id
    │       → assign .index fields
    │       → remap parent_index to sorted positions
    │       → build Edge slice
    │       → returns Graph{.nodes = sorted_nodes, .edges = …, .frozen = true}
    │
    ├─ graph.buildNav(gpa, g.nodes)
    │       → build child_lists (reverse adjacency)
    │       → buildBreadcrumb for each node
    │       → dupe children from child_lists
    │       → buildSiblings for each node
    │       → returns []NavEntry (caller owns, free with freeNav)
    │
    ├─ locate current_index by id scan over g.nodes
    │
    ├─ renderNav(gpa, g.nodes, nav, current_index, "index.html")
    │       → iterate g.nodes
    │           → skip nodes where .parent != null (non-Trunks)
    │           → outputPathFor(allocator, node)   → "{id}.html"  defer free
    │           → identity.relativeHref(...)        → relative href  defer free
    │           → appendEscaped(href)
    │           → appendEscaped(displayTitle(node))
    │           → iterate nav[i].children
    │               → outputPathFor(child)           defer free
    │               → identity.relativeHref(...)     defer free
    │               → appendEscaped(child_href)
    │               → appendEscaped(displayTitle(child))
    │       → buf.toOwnedSlice(allocator) → caller-owned []u8
    │
    ├─ renderChildren / renderBreadcrumb / renderTitle (same pattern)
    │
    └─ std.testing.expectEqualStrings(expected, actual)
```


***
