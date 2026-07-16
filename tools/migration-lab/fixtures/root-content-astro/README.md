# root-content-astro fixture

Synthetic Astro-shaped tree whose content collections live at **root-level
`content/`** (not `src/content/`). Reproduces the P1 discovery bug where a
hardcoded `src/content/` prefix yielded zero content pages.

Intentionally **does not** place Markdown under arbitrary paths (no free-form
`docs/` or README-as-content). Only the supported content root is populated.
