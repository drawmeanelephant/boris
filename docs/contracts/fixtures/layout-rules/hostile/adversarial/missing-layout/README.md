# Missing layout path

Build with a `--layout-rule` pointing at a non-existent layout file under the
same theme root. Expect a hard failure **before** HTML publish (no partial
tree of selected pages).

Example:

```bash
boris \
  --input docs/contracts/fixtures/layout-rules/hostile/content \
  --theme docs/contracts/fixtures/layout-rules/hostile/themes/alpha \
  --layout-rule default id:index \
    docs/contracts/fixtures/layout-rules/hostile/themes/alpha/layouts/does-not-exist.html \
  --html-dir /tmp/hostile-missing \
  --quiet
```

Expect non-zero exit; `/tmp/hostile-missing` must not contain published page
HTML for a successful site.
