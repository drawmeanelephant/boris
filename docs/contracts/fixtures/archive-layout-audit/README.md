# Archive-layout audit fixture

This is a bounded, realistic archive-shaped HTML fixture. It exercises existing
Trunk/Satellite graph semantics, `{{children}}`, navigation, breadcrumbs,
page-local assets, and deterministic `--layout-rule` selection. It does not
introduce archive sorting, recursive children, or grandchildren.

The source tree deliberately looks deeper than the graph:

```text
content/archive.md                         root archive Trunk (no children)
content/years/2024.md                      year Trunk (many Satellites)
content/years/2024/*.md                    direct Satellites of years/2024
content/years/2025.md                      year Trunk (one Satellite)
content/topics/field-notes.md              empty Trunk
```

The nested source paths are entity-id paths, not graph depth. In particular,
`years/2024/010-kickoff` has parent `years/2024`; it is not a child of the
root archive page.

## Reproduce the audit

From the repository root, after `zig build`:

```bash
test/archive-layout-audit.sh
```

The harness publishes only to a temporary directory, checks the selected
layouts and generated HTML, runs the standalone generated-output link audit,
and repeats the render to prove byte-identical output. Its expected evidence
is recorded in [REPORT.md](REPORT.md).

For a manual visual pass, build the same fixture into a retained directory:

```bash
./zig-out/bin/boris \
  --input docs/contracts/fixtures/archive-layout-audit/content \
  --theme docs/contracts/fixtures/archive-layout-audit/theme \
  --layout-rule default id:archive \
    docs/contracts/fixtures/archive-layout-audit/theme/layouts/archive.html \
  --layout-rule default role:trunk \
    docs/contracts/fixtures/archive-layout-audit/theme/layouts/section.html \
  --html-dir test-output/archive-layout-audit \
  --quiet
```

`id:archive` wins for the root archive; `role:trunk` selects the section
layout for the year/category trunks; Satellite pages use the main fallback.
`test-output/` is gitignored; remove that local output when the manual pass is
finished.
