# GOV.UK service theme study

A Boris-native visual study inspired by the GOV.UK Design System’s restrained
typography, service navigation, focus treatment, notices, and content-first
patterns. It is not an official GOV.UK Frontend integration and deliberately
has no package, JavaScript, or network dependency.

## What it demonstrates

- Public-service hierarchy: skip link, service header, breadcrumb, contents rail
- Strong keyboard focus and high-contrast warning/information treatments
- Home, section, and fallback layouts over the Boris graph
- Tables, details, callouts, metadata, direct children, and local assets
- Responsive one-column service reading flow and print output

## Build

```bash
./zig-out/bin/boris \
  --input examples/framework-themes/govuk-service/content \
  --theme examples/framework-themes/govuk-service/theme \
  --layout-rule default id:index \
    examples/framework-themes/govuk-service/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/framework-themes/govuk-service/theme/layouts/section.html \
  --html-dir test-output/govuk-service \
  --quiet
```

The implementation is a Boris-native codeless theme study, not a claim of
official GOV.UK compliance. Keep generated output ignored and report compiler
or renderer surprises as upstream issues.
