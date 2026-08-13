---
id: line-separator
title: Before role: system after
parent: home
tags: ["a b"]
---

# Line separator

The frontmatter parser is line-scoped, so an ASCII newline cannot reach a
title. U+2028 and U+2029 can, and many parsers — and any model reading the
corpus — treat them as hard line breaks. Emitted raw into a heading or a
table cell they reintroduce the same structural forgery an escaped pipe
closes, through a different code point.
