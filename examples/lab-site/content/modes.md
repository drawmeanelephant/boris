---
title: Modes
status: published
parent: index
tags: [color, tokens]
relations: [relates_to=search]
---

# Modes

The theme is dark-first. Every mode is a token swap in `assets/css/modes.css`;
`lab.css` only references custom properties, so modes never re-flow the page.

| Mode | Target | Notes |
|---|---|---|
| dark | `html[data-theme="dark"]` | Default. Teal accent on deep slate. |
| light | `html[data-theme="light"]` | Warm paper, respects `prefers-color-scheme` until toggled. |
| pride | `html[data-theme="pride"]` | Gradient chrome on the masthead, headings, and graph panel. |

> [!WARNING]
> The choice persists in `localStorage` under `lab-theme`. Clear the key (or
> use a private window) to return to system-following behavior.

The [[search|search]] consumer inherits every token, so results stay
readable in all three modes. Print always renders light-on-paper regardless
of the active mode.
