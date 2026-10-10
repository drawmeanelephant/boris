### Fixed

- `boris init` now claims its target with an exclusive-create `.boris-init.lock` marker before the emptiness check, so two concurrent `init` runs on the same directory can no longer both materialize — or have one's failure cleanup delete the other's half-written tree. See [the CLI contract](/docs/contracts/cli.md) (Fixes #1099).
