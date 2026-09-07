# Agent binary kits

Use [`scripts/agent-pack.sh`](../scripts/agent-pack.sh) to build and collect
the installed Boris command-line tools into one native archive for another
agent or machine.

From a clean checkout:

```bash
./scripts/agent-pack.sh
```

The script builds the root binaries, then writes
`boris-agent-kit/boris-agent-kit-<commit>.tar.gz` plus a sidecar SHA-256 file.
The archive contains `MANIFEST.json`, `SHA256SUMS`, and the selected
executables under `bin/`.

The default kit contains the root product CLIs built by `zig build`:

- `boris` — the compiler: HTML target, machine projections, and the
  publication families
- `boris-package` — stages IR (plus optional RAG) into a deterministic
  review archive
- `boris-source-rag` — packs a Boris source checkout into RAG working packs
  for LLM upload; built by the root build even though its source lives in
  `tools/source-rag/`

Standalone developer tools are repo development and testing material, not
agent handoff currency, so they are excluded by default. Pass `--all-tools`
to also build and include every executable installed by a direct
`tools/*/build.zig` file (currently `boris-search-index`,
`boris-docs-maintenance`, `boris-scale-smoke`,
`boris-testdata`, `boris-content-audit`, and `boris-github-pages-audit`).
Adding another direct `tools/<name>/build.zig` package automatically builds
and includes its installed executable(s) in `--all-tools` kits. The
migration laboratory is no longer packaged here — it lives in its own
repository ([`drawmeanelephant/boris-migration-lab`](https://github.com/drawmeanelephant/boris-migration-lab)) with its own kit story.

The editor host is likewise opt-in. Pass `--with-editor` to also build
`boris-editor` (via `editor/build.zig`) and bundle it with the prebuilt UI
shell under `ui/dist/`:

```bash
cd editor/ui && npm ci && npm run build && cd ../..
./scripts/agent-pack.sh --with-editor
```

The UI shell is built by Vite, not Zig, so the script requires a prebuilt
`editor/ui/dist/` and fails loudly with the build command when it is
missing. The kit records `"editor_ui": true` in `MANIFEST.json`, covers the
UI files in `SHA256SUMS`, and its README carries the editor launch line
(`boris-editor . --boris ./bin/boris --ui-dir ./ui/dist`). The
`boris-editor-contract-probe` test helper is never packaged.

The kit README names the built-in feedback loop for the recipient:
`boris watch --serve` serves the built site on loopback with automatic
browser reload, `boris watch --watch-json` streams machine-readable NDJSON
build events (including structured failure diagnostics), and
`boris validate --watch` re-runs the zero-write validation preflight on
every change.

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

To use a kit as an onboarding evaluation rather than a work handoff — the
standard cold-start experiment with its neutral prompt and detector reading —
see [`AGENT-COLD-START.md`](AGENT-COLD-START.md).
