# 744 bounded nav

## Added

- Layouts may write `{{nav depth=N}}` (N ≥ 1) to cap the site-nav forest at N
  rendered levels (level 1 = root Trunks), keeping per-page nav bytes and
  memory bounded on large sites; plain `{{nav}}` stays unbounded and
  malformed depth arguments fail layout load with `ELAYOUTNAVDEPTH`. See
  [the templating contract](/docs/contracts/templating-and-themes.md) and
  [the HTML output contract](/docs/contracts/html-output.md).
