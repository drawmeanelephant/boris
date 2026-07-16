---
title: HTTP status (mixed-case path)
parent: reference
status: published
tags: [reference, identity]
---

# HTTP status codes (path case demo)

Source path:

```text
reference/HTTP-status.md
```

Entity id (case preserved):

```text
reference/HTTP-status
```

## Why this page exists

Many SSGs fold case in URLs. Boris **does not**. Wiki links and `parent`
values must match the entity id **exactly**, including `HTTP` vs `http`.

## Sample table

| Code | Meaning |
|-----:|---------|
| 200 | OK |
| 301 | Moved permanently — update wiki targets after renames |
| 404 | Missing page — fails loud as `EREFERENCEMISSING` if wiki-linked |

Link to this page as `[[reference/HTTP-status]]`, not a lowercased guess.
