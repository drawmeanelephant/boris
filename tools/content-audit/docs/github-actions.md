# GitHub Actions consumer example

`boris-content-audit` is a **consumer-side** tool: a content repository that
uses Boris can run it to audit poetry coverage without any changes to Boris
CI. This document shows a workflow for a consumer repository.

## What the workflow does

1. Checks out the consumer content repository.
2. Obtains or builds `boris-content-audit`.
3. Runs the poetry audit into a temporary output directory (never into the
   content tree).
4. Uploads the complete report as an Actions artifact on pull requests.
5. Writes the Markdown executive summary to `$GITHUB_STEP_SUMMARY`.
6. On main or manual dispatch, uploads `site/` as a GitHub Pages artifact.
7. Never commits generated reports back into the consumer content repository.
8. Uses read-only repository permissions except for the Pages deployment job.

## Workflow file

`.github/workflows/content-audit.yml` in the consumer repository:

```yaml
name: content-audit

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read   # read-only everywhere; Pages job overrides below

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - name: Check out content repository
        uses: actions/checkout@v4

      - name: Obtain boris-content-audit
        # Option A: download a prebuilt kit (see docs/AGENT-BINARY-KITS.md).
        # Option B: build from the Boris source checkout.
        #   - uses: goto-bus-stop/setup-zig@v2
        #     with:
        #       version: 0.16.0
        #   - run: zig build --build-file tools/content-audit/build.zig
        #   - run: cp tools/content-audit/zig-out/bin/boris-content-audit /usr/local/bin/
        run: |
          # Placeholder for obtaining the binary per your distribution channel.
          command -v boris-content-audit || echo "configure binary acquisition"

      - name: Run poetry audit
        id: audit
        run: |
          boris-content-audit \
            --mode=poetry \
            --root=. \
            --content-root=content \
            --policy=content-audit-policy.json \
            --out=/tmp/poetry-audit \
            --format=all

      - name: Upload report artifact
        uses: actions/upload-artifact@v4
        with:
          name: poetry-audit-report
          path: /tmp/poetry-audit
          if-no-files-found: error

      - name: Write executive summary to step summary
        run: |
          {
            echo "## Poetry content audit"
            echo ""
            sed -n '1,40p' /tmp/poetry-audit/REPORT.md
          } >> "$GITHUB_STEP_SUMMARY"

  publish-pages:
    # Main branch or manual dispatch only: publish the static site.
    if: github.event_name == 'push' && github.ref == 'refs/heads/main' || github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Check out content repository
        uses: actions/checkout@v4

      - name: Build / obtain binary
        run: |
          command -v boris-content-audit || echo "configure binary acquisition"

      - name: Run poetry audit
        run: |
          boris-content-audit \
            --mode=poetry \
            --root=. \
            --content-root=content \
            --policy=content-audit-policy.json \
            --out=/tmp/poetry-audit

      - name: Setup Pages
        uses: actions/configure-pages@v5

      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: /tmp/poetry-audit/site

      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

## Notes

- The audit output directory is always a temporary location
  (`/tmp/poetry-audit`); generated reports are **never** committed back into
  the consumer content repository.
- `--fail-on` defaults to `structural`, so a run with only missing or
  placeholder poetry still succeeds — use `--fail-on=policy` if the
  repository wants policy-level findings to fail CI.
- The report site is static and self-contained; it can be served from
  `file://` or published to Pages without any build step.
- Boris CI does **not** clone private or external dogfood repositories; this
  workflow lives in the consumer repository, not in Boris.
