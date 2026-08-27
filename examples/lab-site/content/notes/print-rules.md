---
title: Print rules
status: published
parent: notes
tags: [print]
---

# Print rules

`layouts/print.html` is an optional named shape. It loads only the base
stylesheet and forces light-on-paper: the header, rail, search, and graph
panel are hidden, links lose their accent color, and code blocks print on
plain white.

Select it for a target with a layout rule, for example:

```text
--layout-rule default 'glob:notes/*' themes/lab/layouts/print.html
```
