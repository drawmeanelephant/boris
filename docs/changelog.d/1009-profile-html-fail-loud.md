### Fixed

- HTML `build --profile` now refuses profile target or edition settings that its CLI configuration does not select, instead of silently compiling a mismatched default site; matching Standard.site and Nostr metadata opt-ins still work. See [the publication-profile contract](/docs/contracts/publication-profile.md) (Refs #1006; full profile execution remains deferred).
