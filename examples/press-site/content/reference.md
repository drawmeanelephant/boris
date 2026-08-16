---
title: Reference
parent: index
status: published
tags: [reference, theme]
---

# Reference

This section is the precise map of the first-class port. It describes the
closed marker vocabulary, asset ownership, and the layout decisions that make
the old Textpattern mood work inside Boris.

## The visual translation

| Textpattern cue | Boris expression |
| --- | --- |
| Paper and ink | CSS tokens with light/dark system modes |
| Header and navigation | semantic header plus generated `{{nav}}` |
| Article context | `{{breadcrumb}}` and `{{metadata}}` |
| Sidebar outline | `{{toc}}` with responsive stacking |
| Archive index | graph-backed `{{children}}` |
| Semantic HTML | Landmarks, skip link, native disclosure, and generated navigation |
| Shared closing note | `theme/footer.html` through `{{footer}}` |

Open [Slots and layout rules](reference/slots.md) for the authoring checklist.

<Aside kind="note">

The port keeps the legacy `REFERENCE/rk/` files as a source of visual
inspiration only. Their `$…$` placeholders are not valid Boris markers.

</Aside>
