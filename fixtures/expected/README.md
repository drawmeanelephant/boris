# Expected artifacts (milestone 2)

Full IR goldens (`manifest.json` / `graph.json` / `build-report.json` under
`.boris/`) are **not** committed yet: the compiler does not emit IR on the
default CLI.

What is stable and useful now:

| Artifact | Purpose |
|----------|---------|
| [`../manifest.json`](../manifest.json) | Inventory of valid/invalid fixtures and expected diagnostic categories |
| [`invalid-categories.txt`](invalid-categories.txt) | Flat list of content-error categories that must have fixtures |

When the pipeline lands, add golden IR under suite-specific `expected/` folders
and teach harness tests to compare them. Until then, do not invent goldens that
cannot be produced by the product binary.
