---
title: Measure
parent: index
status: published
tags: [theme, typesetting]
---

# Measure

The theme keeps a Latin reading measure of about 42rem and a system UI
stack. East Asian passages switch stacks and line-height through `:lang`.
No font files are shipped. If a machine lacks those system faces, the
browser falls through to `sans-serif`.

Do not vendor Noto CJK here. Those files are huge and this theme is a
typesetting default, not a font distribution.
