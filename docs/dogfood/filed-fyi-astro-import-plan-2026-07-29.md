# Filed.fyi Astro import-plan read-only dogfood

**Date:** 2026-07-29

**Tool:** `boris-migration-lab --mode=astro-import-plan` (plan-only v1)

## Command and scope

The local Filed.fyi checkout was read through its explicit
`src/content/docs` content root. The run did not execute Astro/Node/MDX or
project JavaScript, fetch resources, modify the checkout, copy assets, emit
migrated Markdown, or apply any plan. Its output was written only to a
temporary sibling-safe directory outside the source checkout.

## Bounded result

The selected root yielded **567 quarantine rows**, **11 unsupported
directory-inventory rows**, and no proposed creates. This is expected evidence
for the deliberately narrow first slice: its source uses unsupported content
rather than the explicit plain-`.md` profile. The complete-tree hardening makes
directory evidence explicit rather than omitting it from the snapshot. The
generated source snapshot, plan, and bounded report were 362,725, 396,653, and
7,001 bytes respectively. No source paths, page text, or private output were
retained in this repository.

This does not claim universal Astro compatibility or a completed import. The
next card is a reviewed, non-applying expansion only after additional supported
plain-Markdown source evidence exists.
