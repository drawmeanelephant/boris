### Fixed

- Malformed publication profiles now name the offending key or field and its object path (for example `unknown key "bogus" in targets[0]`, `duplicate key "format"`, `missing required field "output"`) instead of printing a bare error enumeration. See [the publication-profile contract](/docs/contracts/publication-profile.md) (Fixes #1038).
