# Theme adversarial fixtures (F9.1)

Fail-loud and escape cases for the closed layout plan and target-owned assets.
Happy path: [theme-site](../theme-site/).

| Case | Intent | Expected |
|------|--------|----------|
| `missing-asset/` | `{{asset-url}}` points at a file not under theme `assets/` | hard fail (`AssetNotFound`) before publish |
| `theme-root-missing/` | documents bare-`layouts/` + `asset-url` intent | exercised via tmp `layouts/…` path in unit test (`ThemeRootMissing`); on-disk tree alone derives a parent theme root (see note below) |
| `unsafe-layout/` | `..`, absolute, backslash, non-`assets/` path in layout | hard fail at layout load (`LayoutInvalidAssetUrl`) |
| `metadata-escape/` | closed FM tags/title containing markup | metadata/title sinks HTML-escaped |
| `collision/` | page output path equals a theme asset path | hard fail (`AssetCollision`) |

These are exercised by unit tests in `src/compile.zig` / `src/assemble.zig`
(tmpDir isolation + fixture trees where paths are stable).

**Note on theme root:** `themeRootFromLayoutPath` returns null only for a path
that starts with `layouts/` (no parent segment). A fixture path such as
`theme-root-missing/layouts/main.html` derives theme root `theme-root-missing`
and fails with `AssetNotFound` if `assets/` is empty. The true
`ThemeRootMissing` case is the bare product layout prefix plus `asset-url`.
