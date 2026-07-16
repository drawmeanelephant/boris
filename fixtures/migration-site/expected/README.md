# Expected outputs (migration fixture)

This directory documents **expectations**. It does not store generated HTML,
IR, RAG, or caches (those stay untracked).

## HTML (`--html-dir test-output/migration-dist`)

| Artifact | Expectation |
|----------|-------------|
| Exit code | `0` |
| `index.html` | Present; title contains “Contoso”; sidebar nav present |
| `guides/getting-started.html` | Present; breadcrumb includes Guides |
| `guides/deep/nested/path/note.html` | Present (deep path) |
| `reference/HTTP-status.html` | Case preserved in path |
| `special/CaseDemo.html` | Case preserved |
| `special/cafe-notes.html` | Unicode in body/title; ASCII path for wiki links |
| `assets/css/site.css` | Byte copy of theme CSS |
| `assets/img/mark.svg` | Byte copy of theme mark |
| CSS href on `index.html` | `assets/css/site.css` (page-relative) |
| CSS href on `guides/*.html` | `../assets/css/site.css` |
| Wiki links | Resolved to relative `.html` hrefs (not raw `[[…]]`) |
| Includes | Expanded body text; `includes/` not emitted as pages |

Rough page count: **about 32** HTML files (one per discovered page).

## IR (`--out test-output/migration-ir`)

| File | Expectation |
|------|-------------|
| `manifest.json` | Present |
| `graph.json` | Present; nodes for each page; parent edges for satellites |
| `build-report.json` | Present; success |

## RAG (`--rag-dir test-output/migration-rag`)

Optional. Expect catalog + content packaging; do not commit the directory.

## Non-goals of this fixture

- Not wired into `scripts/release-gate.sh`
- Not a normative contract golden under `docs/contracts/fixtures/`
- Not a replacement for root `content/` dogfood docs
