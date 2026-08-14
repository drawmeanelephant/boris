# Boris Editor

The Boris Editor is a local browser-served authoring environment and a clean
consumer of Boris. The Zig host owns loopback transport, safe local file
operations, session state, and fixed Boris CLI invocations. Boris remains the
only parser, graph, validation, completion, rendering, and publication
authority; Oliver remains the markup authority.

## M0 scaffold

Build the static Svelte UI and the independent Zig host:

```bash
cd editor/ui
npm ci
npm run check
npm run build
cd ../..
zig build
zig build --build-file editor/build.zig test
zig build --build-file editor/build.zig
./editor/zig-out/bin/boris-editor . \
  --boris ./zig-out/bin/boris \
  --ui-dir editor/ui/dist
```

The host binds an ephemeral port on `127.0.0.1`, prints a launch URL containing
a random session token in its URL fragment, and serves:

- `GET /` and `/assets/*`: compiled editor shell;
- `GET /api/health`: host/project-discovery health;
- `GET /api/version`: the result of the fixed `boris --version` invocation and
  the editor's supported artifact-version matrix.

Every API request requires the random token and a loopback `Host`; any supplied
`Origin` must match the session origin. The state-root path is computed from the
canonical project path under the OS user cache directory. M0 does not create
that directory and has no project-content write endpoint.

The adapter accepts only the published Boris versions for `completion.json`,
`build-report.json`, `manifest.json`, `graph.json`, Documentation Intelligence,
publication plans, and the frontmatter JSON Schema. Compiler identifiers are
opaque and may carry Boris-owned variant suffixes.

## M0 gates

```bash
npm --prefix editor/ui ci
npm --prefix editor/ui run check
npm --prefix editor/ui run build
npm --prefix editor/ui run test:e2e
zig fmt --check editor/build.zig editor/build.zig.zon editor/src
zig build --build-file editor/build.zig test
zig build --build-file editor/build.zig
./editor/scripts/test-contract-fixture.sh \
  ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor-contract-probe
./editor/scripts/test-host.sh \
  ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor editor/ui/dist
```

M0 deliberately does not edit files, display diagnostics, preview a site, or
provide completion UI.
