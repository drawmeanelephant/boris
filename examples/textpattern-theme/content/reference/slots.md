---
title: Slots and layout rules
parent: reference
status: published
tags: [reference, slots, accessibility]
---

# Slots and layout rules

Every layout in this example is ordinary HTML with a small, closed set of
Boris markers.

| Marker | Placement in this theme | Design responsibility |
| --- | --- | --- |
| `{{title}}` | document title | Keep the browser title useful and concise |
| `{{content}}` | article reading column | Give Oliver's HTML a comfortable measure |
| `{{nav}}` | header, rail, or disclosure | Style the generated graph without rebuilding it |
| `{{breadcrumb}}` | masthead trail | Keep page context visible on nested routes |
| `{{toc}}` | sidebar/widget | Make heading structure discoverable |
| `{{children}}` | landings and archive | Surface direct graph children |
| `{{metadata}}` | article header | Make status and tags part of the editorial chrome |
| `{{footer}}` | shared footer | Centralize the closing note in `footer.html` |

## Rule selection

The build uses exact IDs for the named landings and one non-overlapping blog
glob. Guide and reference Satellites use `main.html` by fallback. No page
frontmatter chooses a layout.

## Asset ownership

The CSS and mark belong to the theme and are referenced with `asset-url`.
The press-cycle diagram belongs to the home page and lives beside its Markdown
file in `index.assets/`.

<Details summary="What to do when a build surprises you" id="errata-path">

Record the binary version, the exact fixture, the command, the expected
output, the actual output, and a small rendered artifact. File a Boris issue
for system/layout behavior or an Oliver issue for Markdown/render behavior.
Keep the theme change limited to design intent; do not patch the engines here.

</Details>
