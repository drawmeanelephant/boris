### Changed

- Themes batch A (#1047, #1048): `reference`, `press`, `showcase`,
  `archive`, `journal`, `compact`, `minimal`, `corporate`, `service`, and
  `engineering` now wire `{{head}}` and labelled, search-excluded
  `{{relations}}`/`{{backlinks}}` on every layout, adopt `{{page-status}}`
  (a visible status label on `engineering`), `{{tags}}`, and `{{parent}}`
  where the theme's voice uses them, and record each intentional omission
  in the theme README. Each theme ships an `ACCESSIBILITY.md` with measured
  focus and text contrast; fixes include sub-3:1 focus rings (`press`,
  `service`, `engineering` header), dark-mode link and print palettes,
  missing focus/print/motion passes (`showcase`, `archive`), and a clean
  single-column CV print for `corporate`. See
  [the theme catalog](/themes/README.md) and
  [the slot contract](/docs/contracts/templating-and-themes.md).
