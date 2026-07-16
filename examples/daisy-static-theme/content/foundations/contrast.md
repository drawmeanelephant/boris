---
title: Contrast and focus
parent: foundations
status: published
tags: [accessibility, focus]
---

# Contrast and focus

Good contrast makes the page easier to scan; a visible keyboard focus state
makes it usable without a pointer.

## Focus is a first-class state

The theme uses `:focus-visible` with a thick outline and offset. It does not
remove the browser focus indicator.

```css
:focus-visible {
  outline: 3px solid var(--focus);
  outline-offset: 3px;
}
```

## Color is not the only signal

Links are underlined, active navigation has both weight and a surface change,
and callouts carry a labelled title as well as a colored border.
