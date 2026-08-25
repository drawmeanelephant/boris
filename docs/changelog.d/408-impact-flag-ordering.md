### Fixed

- `boris impact <ID>` now accepts flags before the positional target id
  (`boris impact --quiet ID`), matching the `init [DIR]` flag-ordering fix.
  Exactly one positional is still enforced, and a missing id (`boris impact`
  or `boris impact --quiet`) remains a usage error (exit 2).
