### Fixed

- Route Starlight and Astro-archaeology migration outputs through the shared owned/staged publication path so a reused or nested `--out` is refused (or replaced only when lab-owned) instead of silently overwriting user files. See [`tools/migration-lab/publication.zig`](/tools/migration-lab/publication.zig) and [#715](https://github.com/drawmeanelephant/boris/issues/715).
