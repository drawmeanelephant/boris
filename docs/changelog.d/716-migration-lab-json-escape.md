### Fixed

- Fix divergent JSON emitters in the migration lab so Starlight, Filed, and link-audit manifests escape all control characters (not just `\t`) and link-audit findings escape quotes/backslashes, keeping machine-readable output valid for hostile hrefs/filenames. See [`tools/migration-lab/starlight.zig`](/tools/migration-lab/starlight.zig) and [#716](https://github.com/drawmeanelephant/boris/issues/716).
