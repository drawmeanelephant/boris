# Gallery sample site

Specimen Markdown for the shipped [`themes/gallery`](../../themes/gallery/)
theme: a Trunk index, two album Satellites, and one single-image page, each
carrying its own images in a sibling `{stem}.assets/` folder
([content-local assets](../../docs/contracts/content-local-assets.md)).

```bash
./zig-out/bin/boris \
  --input examples/gallery-site/content \
  --theme themes/gallery \
  --layout-rule default id:index themes/gallery/layouts/home.html \
  --html-dir test-output/gallery \
  --quiet
```

Keep generated output under ignored `test-output/`. For live authoring, swap
the build for `boris watch --serve` with the same flags.

## Shape

| Page | Layout | Depth | Shows |
|---|---|---|---|
| `index.md` | `home` | 0 | Cover figure, Aside tip, Details, `{{children}}` album grid |
| `photos/coast.md` | `main` | 1 | `gallery-grid` of three figures, blockquote, definition list, footnote, `see_also` relation |
| `photos/coast/low-tide.md` | `main` | 2 | One full-width figure; `{{parent}}` back link |
| `photos/hills.md` | `main` | 1 | Mixed landscape/portrait grid, table, fenced code, four Aside kinds, backlink |

Image URLs are page-relative at every depth (`index.assets/…`,
`coast.assets/…`, `low-tide.assets/…`); Boris rewrites the Markdown image and
copies the file beside the page.

## Image provenance

Every image here was generated locally for this example. There are no
downloads, no photographs, and no third-party input. A throwaway
standard-library Python script drew posterized flat-colour landscapes (banded
skies, sine-wave ridges, stepped trees, ellipse tide pools) and wrote them as
8-bit RGB PNGs with fixed zlib settings. It uses no randomness and no
timestamps, and two runs produced byte-identical files. The script is not
committed and is not a build step: these PNGs are ordinary content.

| File | Pixels | Bytes | SHA-256 |
|---|---|---:|---|
| `index.assets/tidewater.png` | 1200 × 560 | 3,783 | `f16b6770234140f7dc930c3d8f564da1ba2529c9192e95e5794c1894a43ff61b` |
| `photos/coast.assets/dawn.png` | 1200 × 800 | 4,946 | `859cc68a26648d6a0cd94edab4b42912bc2fe6a76d6922602f9c41298f2e526b` |
| `photos/coast.assets/noon.png` | 1200 × 800 | 4,983 | `4e97d310b681277e63fdb09d4b519930c2de7bcd7b13a83f471dcde9d30510c6` |
| `photos/coast.assets/dusk.png` | 1200 × 800 | 5,070 | `91b2605613b49b0c5db81c0e4b21e1f92d40c54958de9ea5fa8943ed9d610ce0` |
| `photos/coast/low-tide.assets/low-tide.png` | 1200 × 800 | 10,045 | `4cd5a077b74b3b7fbec6405f2ff28bcd042902cfd84171175b20e9ee4b752e63` |
| `photos/hills.assets/ridge.png` | 1200 × 800 | 7,991 | `69dca0b7e333ed74c4d117384dfc7e4de3d6e0eb1474a5bfd500bfdc6f27342e` |
| `photos/hills.assets/fog.png` | 1200 × 800 | 6,377 | `4d29cdd7b1203e025eaab4a47f3067c38639aa40913144c636af0f3ab940c866` |
| `photos/hills.assets/pines.png` | 720 × 960 | 5,468 | `d510cb70aca37e630b230c2641ed9039d1983b3e78332b1c7bf4f596825385df` |

Released with the repository under its [license](../../LICENSE).

## Check

After building, the shared check in [`examples/README.md`](../README.md)
should print nothing:

```bash
rg -n 'https?://|<script src=|@import' test-output/gallery --glob '*.html' --glob '*.css' || true
```
