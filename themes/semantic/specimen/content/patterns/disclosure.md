---
title: Native disclosure
parent: patterns
status: published
tags: [patterns, disclosure]
---

# Native disclosure

When content is optional, hide it behind `details` and label it with
`summary`. The browser supplies the open and close behaviour, the keyboard
handling, and the announcement. No script, no `aria-expanded`, and no click
handler to keep in sync.

## What the summary says

The summary is a label, not a paragraph. Keep it to the one question a reader
is asking; the answer goes in the body. The theme marks the summary with a
visible focus ring and leaves the browser's own marker in place.

## Details versus a callout

Reach for `details` when a reader can reasonably continue without opening it.
Reach for an `<Aside>` when they cannot — a warning they must see to act
safely.

<Details summary="Can a disclosure start open?">

Yes. Add `open` and it begins expanded while staying collapsible. Nothing else
about it changes.

</Details>

<Aside kind="info">

`details` is in the HTML standard, not a framework feature. It has worked in
every shipping browser for years, which is why this theme spends no bytes
rebuilding it.

</Aside>

See also [Tables and definitions](data.md).
