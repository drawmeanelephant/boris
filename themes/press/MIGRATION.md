# Migrating the legacy Textpattern shape

The files under REFERENCE/rk/ are visual and template provenance. They are
not a Boris input tree because their placeholders belong to another system.
This sheet records the deliberate translation used by the shipped
`themes/press` theme.

## Placeholder map

| Legacy reference | Boris-native replacement | Porting note |
|---|---|---|
| $title$ | {{title}} | Use in document titles or authored chrome where the current page name belongs. |
| $body$ | {{content}} | Oliver renders the Markdown body; the layout supplies the reading measure and surrounding semantics. |
| $description$ | Authored opening prose and frontmatter metadata | There is no conditional template expression in a Boris layout. Keep a description visible in the content or make it part of the fixed layout copy. |
| $assets_root$ | {{asset-url assets/...}} | Theme-owned CSS and images are copied beneath the target assets tree and rewritten page-relatively. |
| $if(description)$ ... $endif$ | Static semantic HTML or Markdown | Choose a layout variant with build rules when the page shape changes; do not invent a template conditional. |
| legacy related-content lists | Boris graph navigation and authored links | Keep the port honest: do not invent a second relationship renderer in the theme. |
| theme CSS classes | Local theme classes around Boris slots | The port keeps the txp-* naming family where it describes the visual language, while styling Boris-emitted site-nav, page-toc, page-children, page-metadata, admonition, and details classes. |

## Recommended file moves

1. Put the old stylesheet’s stable visual tokens into
   assets/css/press.css.
2. Put a small site mark under theme/assets/img/ and reference it with
   asset-url from each layout that uses it.
3. Move page-specific media beside its Markdown file as
   page-stem.assets/; the home diagram in this example is
   content/index.assets/press-cycle.svg.
4. Split the old page wrapper into layout variants under theme/layouts/.
5. Keep shared closing HTML in theme/footer.html and splice it with
   {{footer}}.
6. Express graph relationships with parent frontmatter. Do not hard-code a
   second navigation tree in a sidebar.

## Layout selection used here

The candidate uses exact page IDs for the named landings and one glob for blog
entries:

    id:index       -> layouts/home.html
    id:guides      -> layouts/section.html
    id:reference   -> layouts/section.html
    id:blog        -> layouts/blog.html
    id:archive     -> layouts/archive.html
    glob:blog/*    -> layouts/blog.html
    fallback       -> layouts/main.html

The selectors do not overlap. That is intentional for auditability and
portability. The refreshed binary also produced the same selected layout for
the overlapping `id:index`/`role:trunk` probe in either declaration order;
the precedence behavior is tracked as resolved in
https://github.com/drawmeanelephant/boris/issues/400.

## What is not being migrated

Dynamic publishing services, comments, TrackBacks, login controls, remote
fonts, and CMS conditionals are not silently represented as working features.
If a legacy page depends on one, preserve the information as authored content
or metadata and label the boundary. If the binary behaves unexpectedly while
rendering the port, record the smallest reproduction as a Boris or Oliver
issue instead of modifying the engine.
