### Fixed

- Theme and content-local asset walks reject a file whose name contains a literal backslash with a located `EASSET` diagnostic naming the actual file (e.g. `theme/assets/css/weird\name.css`), instead of normalizing the name into a nested path and failing later with a bare `FileNotFound` for a file that visibly exists. POSIX-only edge; the normal-name control keeps building. Links: [the templating-and-themes contract](/docs/contracts/templating-and-themes.md), [#870](https://github.com/drawmeanelephant/boris/issues/870).
