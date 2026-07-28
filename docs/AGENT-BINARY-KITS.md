# Agent binary kits

Use [`scripts/agent-pack.sh`](../scripts/agent-pack.sh) to build and collect
the installed Boris command-line tools into one native archive for another
agent or machine.

From a clean checkout:

```bash
./scripts/agent-pack.sh
```

The script builds the root binaries and standalone developer tools, then writes
`boris-agent-kit/boris-agent-kit-<commit>.tar.gz` plus a sidecar SHA-256 file.
The archive contains `MANIFEST.json`, `SHA256SUMS`, and these executables:

- `boris`
- `boris-package`
- `boris-source-rag`
- `boris-search-index`
- `boris-migration-lab`
- `boris-docs-maintenance`

The manifest records the repository commit, branch, dirty state, platform, Zig
version, and digest for every executable. Archive inputs are sorted and have
normalized ownership and timestamps. Re-running the command for the same clean
commit and platform produces the same archive bytes.

For an already-built checkout, use `--no-build`. A dirty checkout is rejected
by default because its binaries cannot be described as a reproducible commit
build; use `--allow-dirty` only when that is intentional. Use `--out DIR` to
place the kit elsewhere.

These are native executables. A kit built on macOS ARM64 is not a Linux or
x86-64 kit; send the manifest with the archive so the recipient can verify the
target before execution. The kit supplements a source checkout and does not
replace it.
