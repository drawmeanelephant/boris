### Fixed

- A page file whose name violates the identity rules no longer bricks the build with a bare `InvalidPath`: discovery carries the offending walk path to the diagnostic boundary, so the build fails with a located `EINVALIDPATH` (e.g. `content/my page.md: not a valid page path`) and a rename remediation naming the actual file. Links: [the identity-and-paths contract](/docs/contracts/identity-and-paths.md), [#851](https://github.com/drawmeanelephant/boris/issues/851).
