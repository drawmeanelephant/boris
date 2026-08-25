# Publication-location projection fixture

This fixture is a small, real-site-shaped HTML input for the second GitHub
Pages publication slice.

```text
content/index.md                         published Trunk
content/guides/start.md                  published Satellite
content/index.assets/logo.svg            content-local asset
content/guides/start.assets/diagram.svg  nested content-local asset
theme/layouts/main.html                   theme asset-url + search root
theme/assets/css/site.css                theme-owned asset
poisoned/*.html                           deliberately contradictory layouts
```

The valid build test compiles the same bytes as a project site, a root
`github.io` site, and a custom domain. Internal links and asset references stay
target-relative, while sitemap `<loc>` values use the selected normalized
`base_url`. The generated search index is target-relative and is checked for
presence, not described as a public-URL assertion.

The poisoned layouts are used by the compile integration test:

| Layout | Poison | Expected result |
|---|---|---|
| `project-root-relative.html` | `/assets/...` under project `/boris` | `EPUBLICATIONLOCATION` |
| `wrong-origin.html` | canonical URL on another origin | `EPUBLICATIONLOCATION` |
| `stale-root-prefix.html` | `/boris` retained on root `github.io` | stable `EROUTEMISSING` link-audit failure |
| `custom-github-origin.html` | `github.io` URL on custom domain | `EPUBLICATIONLOCATION` |

Sitemap and RSS disagreement cases are exercised by their projection tests;
IR, RAG, Context Bundle, and rendered-search v1 remain explicitly outside
this location assertion because their current artifacts contain no applicable
public URL field. A root site cannot classify an arbitrary nested path as a
stale repository prefix from the origin alone; this fixture deliberately leaves
that route unpublished so the existing route diagnostic is the authoritative
failure.
