### Fixed

- Catalog themes no longer carry demo-site copy into `boris init --type`
  starters, which copy each theme byte for byte (#1045, #1046). A fresh
  `archive` site no longer shows "Personal index · 2018—2024" and a fixed
  lede over its own title, and the `dashboard` board no longer says "Theme
  study". Fake site names, an owner bio, a `©` line, and theme pitches are
  gone from [`cozy`](/themes/cozy/README.md),
  [`press`](/themes/press/README.md), [`showcase`](/themes/showcase/README.md),
  [`reference`](/themes/reference/README.md),
  [`journal`](/themes/journal/README.md), and six other themes. Each theme
  shows its own name or a neutral label instead, within the closed slot
  vocabulary ([templating and themes](/docs/contracts/templating-and-themes.md)).
  Theme READMEs now link repository-only targets by absolute GitHub URL,
  so the copies inside a starter no longer have dead `../../examples/` links.
