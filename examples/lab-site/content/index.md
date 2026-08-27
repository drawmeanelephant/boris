---
title: lab
status: published
tags: [theme, terminal, modes]
---

# lab

Dark-first documentation theme for Boris with three persisted color modes.
The header toggle cycles **dark → light → pride**; the initial mode follows
`prefers-color-scheme`, applied before first paint so nothing flashes.

## What this specimen shows

- [[modes|Modes]] — what each color mode changes and how the choice
  persists.
- [[search|Search]] — the first-party rendered-search consumer wired to
  the `data-boris-search-*` hooks.
- [[notes|Notes]] — a small nested trunk for the navigation tree,
  the graph panel, and print rules.

> [!TIP]
> Press <kbd>/</kbd> anywhere to focus the search field. The panel supports
> arrow-key navigation and closes on <kbd>Escape</kbd> or an outside click.

> [!NOTE]
> The theme ships zero external JavaScript. The mode toggle and the search
> consumer are inline first-party scripts; CSS lives in two files
> (`lab.css` plus the `modes.css` token layer).

See [[modes|Modes]] for the mode list, and
[[search]] for how the index is validated.
