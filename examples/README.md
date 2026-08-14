# Boris theme example portfolio

This directory is a black-box theme-design portfolio for the supplied Boris
binary. The examples are static HTML/CSS/Markdown artifacts; none modifies
Boris or Oliver implementation code.

## Current catalog

| Example | Design direction | Feature posture |
|---|---|---|
| textpattern-theme | Classic Textpattern editorial paper, crimson/slate masthead, serif reading | First-class candidate; five layout shapes, graph navigation, core slots, local assets, components, responsive/dark/print states |
| reference-theme | Calm accessibility-forward documentation | Full reference shell; multi-layout docs, page-local assets, components, graph slots |
| static-theme-showcase | Soft component-library-inspired docs + blog | Full multi-layout shell; updated with children, TOC, metadata, skip links, and offline checks |
| daisy-static-theme | Friendly cards and quiet docs | Full single-shell specimen; local CSS and the complete generated docs surface |
| archive-theme | Ordered long-lived field-note archive | Updated complete archive shell; archive children plus nav, breadcrumb, metadata, TOC, footer |
| agent-themes/chota | Compact utility-light docs | Full compact docs specimen |
| agent-themes/pure | Restrained blue field notes | Full responsive docs specimen |
| agent-themes/cozy-corner | Warm mid-2000s personal blog | Updated complete blog shell; authored blogroll text, metadata, TOC, children, local illustration |
| agent-themes/journal-archive | Phosphor terminal diary | Updated complete archive shell; metadata, graph navigation, TOC, children, keyboard focus |
| agent-themes/node-tracker | Dense early-2000s knowledge database | Updated complete node shell; metadata, graph navigation, TOC, children, explicit static controls |
| framework-themes/pico-semantic | Semantic, class-light documentation | First framework study; native HTML, home/section/main layouts, dark/print/accessibility states |
| framework-themes/bulma-classic | Familiar CSS-only component vocabulary | First framework study; containers, columns, boxes, tags, responsive shell, no runtime |
| framework-themes/govuk-service | Public-service information design | Accessibility-forward service shell with banners, focus treatment, alerts, and contents rails |
| framework-themes/primer-engineering | GitHub-like engineering documentation | Dense boxes, labels, status metadata, code-friendly reading surface, tokenized states |
| framework-themes/uswds-public | Civic/public-information design tokens | Agency masthead, public banner, cards, alerts, responsive and high-contrast states |
| framework-themes/open-props-laboratory | Token-first fluid design system | Custom-property lab for fluid type, spacing, surfaces, color modes, and print |
| prototype-minimalist | Visual comparison prototype | Intentionally a prototype with static placeholder controls; not a production theme candidate |
| prototype-corporate | Visual comparison prototype | Intentionally a prototype with static placeholder controls; not a production theme candidate |

The two prototype folders are kept as visual research artifacts. Their
manual-review notes call out the controls that are not real Boris behavior;
they are not silently promoted to feature-complete themes.

The framework studies are deliberately Boris-native visual translations. They
do not vendor framework packages, claim official conformance, fetch a CDN, or
add a build/runtime dependency to Boris.

## Shared acceptance surface

The complete examples are expected to demonstrate, where the page shape makes
the slot meaningful:

- title, content, navigation, breadcrumb, metadata, TOC, direct children,
  shared footer, and page-relative managed assets;
- Trunk/Satellite graph relationships rather than hand-maintained site maps;
- headings, links, tables, lists, code, blockquotes, Aside, and Details;
- semantic landmarks, visible focus, readable mobile stacking, dark-mode
  behavior where appropriate, and reduced-motion handling;
- offline output with no CDN, remote fonts, or fake stylesheet navigation.

An empty direct-child region on a leaf page is expected. A prototype that
intentionally omits a slot should say so in its README or review notes.

## Validation pattern

Run the example's documented build command with the supplied binary, then
inspect the generated artifacts:

    find work/probe/<example> -type f | sort
    rg -n 'data-layout=|site-nav|page-toc|page-children|page-metadata|admonition|details' work/probe/<example> --glob '*.html'
    rg -n 'https?://|<script|@import' work/probe/<example> --glob '*.html' --glob '*.css' || true

Keep generated output inside the workspace under an ignored probe directory.
If the binary or renderer exhibits a defect, capture the exact fixture,
command, version, expected result, actual result, and artifact evidence in a
GitHub issue. Do not repair the engine from an example theme.

## Porting boundary

The legacy Textpattern files under REFERENCE/rk/ use dollar-sign placeholders
such as $title$ and $body$. They remain useful as visual provenance, but they
are not interchangeable with Boris brace markers. The Boris-native port lives
in textpattern-theme so it can be reviewed, replaced, or proposed as a
codeless example independently.
