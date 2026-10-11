### Changed

- `boris init --type photo-gallery` embeds its five PNG plates straight from
  the [`examples/gallery-site`](/examples/gallery-site/) specimen through a
  new `init_example_assets` module instead of byte copies under
  `src/init_templates/`, so the starter and the example share one source of
  truth ([#1084](https://github.com/drawmeanelephant/boris/issues/1084)).
