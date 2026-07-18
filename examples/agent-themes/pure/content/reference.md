---
title: Reference
status: published
tags: [reference, slots, accessibility]
---

# Reference

This page is the second Trunk in the small graph. Its Satellite records the
layout vocabulary and the accessibility decisions behind the prototype.

## Theme surface

The prototype stays within Boris's closed static theme surface:

- trusted HTML layouts under `theme/layouts/`;
- a theme-local CSS asset under `theme/assets/`;
- a static `footer.html` fragment;
- Markdown, Trunk/Satellite frontmatter, and closed `Aside`/`Details`
  components.

<Aside kind="info">

The theme is intentionally easy to delete or replace. Nothing here changes
the compiler's default layout or the meaning of any frontmatter key.

</Aside>

## Read the slot map

The [Slots and accessibility](reference/slots.md) page maps every marker used
by the layouts and explains what happens when the viewport narrows.

## Original decisions

The following details are original to this prototype rather than copied from
Pure.css:

1. A “field notes” identity with a blue ink accent and amber warning edge.
2. A three-column Boris docs shell with a sticky reading rail on wide screens.
3. Native disclosure navigation on small screens.
4. Explicit high-contrast focus rings and reduced-motion behavior.
