---
title: Citations and bibliography
parent: index
status: published
tags: [audit, apex, citations]
---

# Citations and bibliography

Pandoc-style: See [@smith2020] for details.

MultiMarkdown-style: Also [#smith2020].

mmark-style: [@RFC1234].

No bibliography file is packaged with this fixture and Boris closed frontmatter
rejects unknown metadata keys, so this probes host/default Unified behavior
without a configured `.bib` / CSL path.
