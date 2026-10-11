---
title: Landmarks
parent: index
status: published
tags: [landmarks, structure]
---

# Landmarks

A landmark is a region a reader can jump to by name. Screen readers list them,
browser reading modes use them, and automated checks count them. This theme
makes them visible, but it did not add them — they were the elements all along.

## What a landmark needs

Each region needs a job before it needs a name. The banner, the main region,
and the footer are the page's one-of-a-kind skeleton, so they need no label. A
landmark that can repeat — two `nav`s, two `aside`s — needs an `aria-label` so
a reader can tell them apart.

| Region | Named by | Repeats? |
|--------|----------|----------|
| `nav` | `aria-label="Site"` | Once, in the banner |
| `nav` | `aria-label="Breadcrumb"` | Once, above the article |
| `nav` | `aria-label="On this page"` | Once, when headings exist |
| `aside` | `aria-label` or a visible heading | Per callout |

## The pages below

Each entry takes one region and shows it where it belongs. The list of pages
is generated from the graph, not typed into the layout by hand.
