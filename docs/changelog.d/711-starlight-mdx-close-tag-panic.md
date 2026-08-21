### Fixed

- Fix a SIGABRT in the Starlight migration lab when an MDX body line ends with `</`; the truncated closing tag is now neutralized instead of slicing backwards. See [`tools/migration-lab/starlight.zig`](/tools/migration-lab/starlight.zig) and [#711](https://github.com/drawmeanelephant/boris/issues/711).
