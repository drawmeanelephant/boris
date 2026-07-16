### Fixed

- Instagram migration-lab archive index links child records with published
  `{entity_id}.html` paths (same mapping as product `identity.htmlOutputPath`)
  instead of source `.md` hrefs that 404 under a static server. Link labels
  escape `]` / `\`; regression covers mini-instagram (every child page linked,
  each href resolves to a content page).
  [`tools/migration-lab/instagram.zig`](/tools/migration-lab/instagram.zig).
