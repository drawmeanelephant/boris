### Fixed

- Clicking a [completion option](/content/guides/editor.md) in the editor now
  only selects it; the explicit **Insert selected completion** action inserts
  exactly one token, so the select-then-insert workflow can no longer duplicate
  an inserted completion ([#446](https://github.com/drawmeanelephant/boris/issues/446)).