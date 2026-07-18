# Pure Field Notes — independent Boris theme prototype

This is a self-contained Boris example inspired by the official [Pure.css
design language](https://pure-css.github.io/). It is deliberately an
adaptation, not a vendored copy of Pure.css and not a claim of compatibility
with the Pure.css API.

## What is inspired vs. original

| Pure.css cue | Original work in this example |
| --- | --- |
| Small, modular CSS with a restrained footprint | `theme/assets/pure-field-notes.css`, written for this example only |
| Flat surfaces, light borders, compact controls, and a blue accent | Boris-specific tokens, spacing, typography, component states, and content styling |
| Responsive, mobile-first composition | The three-column docs shell, responsive nav rail, hero layout, and slot wrappers |
| Native HTML controls and common elements | The `Aside`, `Details`, graph navigation, TOC, metadata, and footer presentation |

The prototype intentionally does not add Pure.css as a dependency. The output
is static HTML plus a local stylesheet copied by Boris. There is no CDN, remote
font, JavaScript runtime, build plugin, or network fetch in the example.

## Example tree

```text
examples/agent-themes/pure/
  README.md
  content/
    index.md
    guides.md
    guides/getting-started.md
    reference.md
    reference/slots.md
  theme/
    layouts/main.html
    layouts/home.html
    layouts/section.html
    footer.html
    assets/pure-field-notes.css
```

The content is a real Trunk/Satellite graph. The build selects a hero layout
for `index`, a section layout for Trunks, and the three-column documentation
layout for Satellite pages.

## Build and inspect

From the repository root, first build Boris:

```bash
zig build
```

Compile the example:

```bash
BORIS=./zig-out/bin/boris
OUT=test-output/agent-themes/pure

rm -rf "$OUT"
"$BORIS" \
  --input examples/agent-themes/pure/content \
  --theme examples/agent-themes/pure/theme \
  --layout-rule default id:index \
    examples/agent-themes/pure/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/agent-themes/pure/theme/layouts/section.html \
  --html-dir "$OUT" \
  --quiet
```

Useful structural and offline checks:

```bash
rg -n 'data-layout=|site-nav|page-toc|page-children|admonition|details|page-metadata' \
  test-output/agent-themes/pure --glob '*.html'
rg -n 'https?://|<script|@import|url\(' \
  test-output/agent-themes/pure --glob '*.html' --glob '*.css' || true
```

The second command should print nothing. The only `https://` in this README is
the official inspiration link above; generated output is offline/self-contained.

## Byte-identical double compile

This command compiles two independent output trees and compares relative-path
SHA-256 manifests. It is the deterministic verification used for this example:

```bash
BORIS=./zig-out/bin/boris
BASE=test-output/agent-themes/pure-determinism
RUN_ARGS=(
  --input examples/agent-themes/pure/content
  --theme examples/agent-themes/pure/theme
  --layout-rule default id:index examples/agent-themes/pure/theme/layouts/home.html
  --layout-rule default role:trunk examples/agent-themes/pure/theme/layouts/section.html
  --quiet
)

rm -rf "$BASE-a" "$BASE-b"
"$BORIS" "${RUN_ARGS[@]}" --html-dir "$BASE-a"
"$BORIS" "${RUN_ARGS[@]}" --html-dir "$BASE-b"

(cd "$BASE-a" && find . -type f ! -path './.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256) > /tmp/pure-theme-a.sha
(cd "$BASE-b" && find . -type f ! -path './.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256) > /tmp/pure-theme-b.sha
diff -u /tmp/pure-theme-a.sha /tmp/pure-theme-b.sha
```

`diff` exits 0 only when every published file is byte-identical. The cache is
excluded because it is compiler bookkeeping, not published theme output.

## Accessibility notes

- The layouts use `header`, named `nav`, `main`, `article`, `aside`, and
  `footer` landmarks.
- Every page has a keyboard-visible skip link and `:focus-visible` treatment.
- Navigation and the table of contents remain ordinary links and lists.
- `Aside` is styled as an always-visible semantic complementary region;
  `Details` remains the native keyboard-operable disclosure element.
- The mobile breakpoint collapses the rail layout into one reading column and
  moves navigation into a native `<details>` menu.
- The CSS includes a `prefers-reduced-motion` override and does not use color
  alone for focus, current-page, or warning states.

## Boundaries

This is an independent prototype under `examples/agent-themes/pure/`. It does
not modify Boris core, contracts, existing themes, or build dependencies. It
uses only the closed Boris layout markers documented in
[`docs/contracts/templating-and-themes.md`](../../../docs/contracts/templating-and-themes.md).
