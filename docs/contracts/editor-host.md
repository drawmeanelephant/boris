# Editor host API

**Status:** normative and implemented — `boris-editor/0.1.0`

**Version:** host contract 1 (unversioned on the wire); `boris/0.8.2`-era
compiler surface; no IR schema change

The Boris Editor is a local, compiler-backed authoring host. `boris-editor`
(`editor/src/`) is a Zig loopback HTTP host that serves the built Svelte shell
(`editor/ui/dist`) and exposes exactly one authenticated JSON API under
`/api/`. This document is the normative contract for that API: transport and
security discipline, the endpoint surface and its payloads, author-owned file
operations, managed compiler daemons, and the preview origin.

Narrative description of the editor lives in
[`editor/README.md`](../../editor/README.md); on conflict, this contract wins.
Compiler behavior stays owned by the rest of
[`docs/contracts/`](README.md).

## 1. Authority rule

Boris remains the only authority for source parsing, frontmatter, identity,
graph topology, validation, completion, rendering, and publication. The host:

- **must not** parse Markdown, MDX, Cooklang, or Textile source, infer graph
  meaning, validate content, render markup, or decide publication facts;
- **must not** accept argv, a working directory, or an artifact path from the
  UI except through the closed allowlist in §6;
- forwards Boris artifacts after discriminator/version validation and never
  rewrites their meaning; a forwarded document keeps Boris's own key spelling;
- owns only loopback transport, path safety, exclusive file writes, process
  lifecycle, and static delivery of `dist/` on the preview origin.

Fields authored by the host use `snake_case`. Fields inside forwarded Boris
documents are untouched (`schemaVersion`, `sourcePath`, `contentRoot`, …).

## 2. Conformance and drift

The host, the shell (`editor/ui/src/`), and the mocked Playwright specs that
pin payload shapes are one surface built from one commit. There is no wire
version negotiation and no `Accept`-style content negotiation; the API is
**closed**. Therefore:

- adding or removing an endpoint, renaming or retyping a response field,
  changing an error code, or changing a status code is a **breaking contract
  change** and must update this document, `editor/ui/src/lib/types.ts`, and
  every affected spec in `editor/ui/tests/` in the same change;
- additive fields are allowed, but must be documented here as additive so a
  consumer knows they may be absent (existing examples: `watch_active` on
  `/api/preview/state`, `supported`/`validate_watch`/`watch_json` on
  `/api/version`, `skipped` on `/api/recovery`);
- changing a fixed Boris invocation in §6 or §7 is also a contract change:
  operators and tests depend on *which* command ran, not only on the response;
- an artifact the host does not recognize by discriminator/version must surface
  as an explicit `unsupported`/`build_required` state, never as a
  plausible-looking empty result (§6.4).

The endpoint table in §4 and the error taxonomy in §9 are enforced by
[`editor/scripts/test-host-contract.sh`](../../editor/scripts/test-host-contract.sh):
it reconciles both tables against the host's own route and error-code sets in
both directions, probes every documented endpoint live, and floods the watch
event ring past each of its two bounds (§7.3) to pin the eviction contract. A
new route, method, or error code fails that script until it is documented here,
and a documented row that the host does not implement fails it too.

**Every documented error code must be producible.** A code that no handler can
raise is a contract defect, not a reservation: produce it or delete it from both
the mapping and this table. The conformance script enforces that as coverage —
every code in §9 must be driven to its documented status by a live request, so
there is no "reserved" row to rot.

## 3. Launch, transport, and security

### 3.1 Process and launch line

```text
boris-editor [DIR] [--boris PATH] [--ui-dir DIR] [--port PORT]
```

| Element | Rule |
|---|---|
| `DIR` | Project root, default `.`; canonicalized at startup. A directory without `content/` is a startup error (exit 2). |
| `--boris PATH` | Compiler binary for every fixed invocation. A path-like value (contains `/` or `\`) is canonicalized against the editor's cwd so a child spawned with cwd = project root still resolves it; a bare name goes through `PATH`. Unresolvable is exit 2. |
| `--ui-dir DIR` | Built shell, default `editor/ui/dist`. |
| `--port N` | Loopback port; `0` (default) is ephemeral and the printed port is the bound one. |
| `--help` / `-h` | Usage, exit 0. Unknown flag or extra positional argument: usage, exit 2. |

Startup failures exit `3` (project real-path failure, discovery failure, state
root unavailable, secure-token failure, preview-listener failure, host failure)
or `2` (usage, unresolvable `--boris`, no content directory). Success is not an
exit: the host runs until it is signalled.

**Launch line (pinned).** Immediately after the listener is bound, the host
prints exactly one line to **stderr**:

```text
BORIS_EDITOR_URL=http://127.0.0.1:<port>/#token=<32 lowercase hex chars>
```

The prefix, the loopback URL shape, and the `#token=` fragment are fixed. The
token is 32 lowercase hex characters generated per process from 16 random bytes.
It lives in the URL **fragment** so navigation never sends it to the server; API
calls carry it in the `x-boris-editor-token` header instead. An embedder may
append `&open=<project-relative path>` to the fragment as a shell-side
convenience; the host never reads a file from the URL and its transport posture
is unchanged (see [`editor/README.md`](../../editor/README.md#launch-line-contract)).

### 3.2 Loopback and header discipline

- The host binds `127.0.0.1` only. There is no TLS, no Unix socket, and no
  remote bind option.
- Every request — API and static — must carry a `Host` equal to
  `127.0.0.1:<host port>` or `localhost:<host port>` (ASCII case-insensitive).
  Anything else is `403 Invalid Host` as plain text.
- Every `/api/*` request must additionally satisfy:

| Requirement | Rule |
|---|---|
| Token | Header `x-boris-editor-token` must equal the session token exactly, compared in constant time. Wrong length or value → `403 Forbidden`. |
| `Origin` | When present, must equal `http://127.0.0.1:<host port>` or `http://localhost:<host port>`. A mismatch → `403 Forbidden`. Absent `Origin` is accepted (non-browser clients and same-origin navigations). |

- Static shell requests (`/`, `/index.html`, `/assets/*`) require the loopback
  `Host` but **not** the token: the shell is a public-by-locality asset bundle
  and the API is the sensitive surface.
- Paths passed to the static handler are guarded: no leading `/`, and no `\`,
  `%`, NUL, empty, `.`, or `..` segment. Violations are `400 Invalid path`;
  a missing file is `404`.

### 3.3 Methods and bodies

- Read endpoints accept `GET` and `HEAD`. Mutating endpoints require `POST`.
  Any other method on a known path is `405` with an `Allow` header naming the
  permitted methods.
- Every `POST` endpoint that takes a body requires `content-type:
  application/json` (case-insensitive prefix, parameters allowed); otherwise
  `415 unsupported_media_type`. An empty or absent body is a `415` too — send
  `{}`. The two exceptions are `POST /api/watch/start` and `POST
  /api/watch/stop`, which take no body and neither read nor require one; they
  accept any content type, or none.
- Request bodies are read with a hard ceiling of `max_file_bytes + 1 MiB`
  (9 MiB), enforced first against `content-length` and then while reading.
  Exceeding it is `413 payload_too_large`.

### 3.4 Response discipline

- JSON responses carry `content-type: application/json; charset=utf-8`,
  `cache-control: no-store`, and `x-content-type-options: nosniff`.
- Shell and text responses carry `content-type` (or `text/plain;
  charset=utf-8`), `cache-control: no-store`, `x-content-type-options:
  nosniff`, and a **Content-Security-Policy**:
  `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'
  data:; frame-src 'self' http://127.0.0.1:<preview port>; connect-src 'self';
  base-uri 'none'; form-action 'none'`.
  The `frame-src` entry is the only reason the preview iframe renders, and it
  names the **`127.0.0.1`** form of the preview origin — a shell that framed
  `http://localhost:<preview port>` instead would be blocked.
- Responses are not kept alive (`keep_alive = false`); one request per
  connection.
- Unknown `/api/*` paths return `404 Not found` as **plain text**, not JSON.
- The host logs a warning per failed request and continues; one malformed
  request must never take the host down.

### 3.5 Shutdown

`SIGINT` and `SIGTERM` (non-Windows) set an async-signal-safe latch; a monitor
thread self-connects to the listener so the blocked `accept` wakes, the loop
exits, the listener closes, and the process exits **`0`** — the same contract as
`boris watch`, so an embedder treats `terminationReason == .uncaughtSignal` as
cancel, not crash. Every managed child (§7) is SIGTERM'd and reaped during host
teardown; no orphan compiler process survives. On Windows there is no signal
handler and no monitor thread.

## 4. Endpoint surface

Read endpoints: `GET` / `HEAD`. Mutating endpoints: `POST` with a JSON body.
All paths are exact matches; there is no prefix routing and no versioned
prefix. A query string is stripped before routing, so an unrecognized
parameter is ignored rather than rejected; the only parameter the host reads is
`after` (§7.3).

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/health` | GET, HEAD | Host, project discovery, and daemon reaping |
| `/api/version` | GET, HEAD | Compiler identity and the host's supported artifact matrix |
| `/api/files` | GET, HEAD | Flat author-owned file list |
| `/api/files/open` | POST | Read one file with its fingerprint |
| `/api/files/probe` | POST | Compare a fingerprint to disk without writing |
| `/api/files/save` | POST | Fingerprinted atomic replace |
| `/api/files/create` | POST | No-clobber create |
| `/api/files/rename` | POST | No-clobber rename |
| `/api/files/delete` | POST | Confirmed delete |
| `/api/recovery` | GET, HEAD | List dirty-buffer recovery snapshots |
| `/api/recovery/snapshot` | POST | Write/refresh a recovery snapshot |
| `/api/recovery/clear` | POST | Delete one recovery snapshot |
| `/api/commands/run` | POST | Run one allowlisted Boris command |
| `/api/validate-state` | GET, HEAD | Validation-daemon state |
| `/api/watch/start` | POST | Explicit start of the managed watch daemon |
| `/api/watch/stop` | POST | Graceful stop of the managed watch daemon |
| `/api/watch/state` | GET, HEAD | Watch-daemon state |
| `/api/watch/events` | GET, HEAD | Bounded buffered compiler events (`?after=`) |
| `/api/authoring` | GET, HEAD | Frontmatter schema + completion index |
| `/api/graph` | GET, HEAD | Validated `.boris/graph.json` |
| `/api/publication` | GET, HEAD | Publication profiles + local Proof Pack summary |
| `/api/preview/state` | GET, HEAD | Preview phase and iframe URL |
| `/api/preview/rebuild` | POST | One fixed incremental preview build |

Plus the static shell: `GET`/`HEAD` `/`, `/index.html`, and `/assets/*`.

`/api/health`, `/api/validate-state`, `/api/watch/state`, and
`/api/watch/events` are the only endpoints that may touch process lifecycle on
a read, and then only to **reap** an already-managed child or to **restart** a
daemon that an explicit start already activated. No read endpoint lazy-starts
a daemon. `/api/version`, `/api/commands/run`, `/api/preview/rebuild`, and the
two `start` paths are the only endpoints that may create a process.

### 4.1 `/api/health`

```json
{"status":"ok","editor_id":"boris-editor/0.1.0",
 "project":{"content":true,"default_layout":true,"publication_profile":true,"input_mode":"markdown"}}
```

`input_mode` is one of `markdown`, `cooklang`, `textile`, `mixed`, `empty` and
is derived from a **page-extension scan of `content/`** only — the host never
parses a page. Discovery failure degrades to all-false/`empty` rather than an
error, because health must answer while the project is broken.

Side effect (normative): health calls the non-blocking reap for both daemons so
an unexpected death is noticed on the shell's periodic poll. It must not spawn
a compiler process.

### 4.2 `/api/version`

Runs the fixed `boris --version` invocation (10 s timeout, 4 KiB output caps).
Success requires exit 0, non-empty output starting with `boris/`, and no
embedded newline; otherwise `502 invalid_boris_version`. Failure to spawn is
`503 boris_unavailable`.

```json
{"compiler_id":"boris/0.8.2",
 "supported":{"completion":[1],"ir":["0.2.0","0.3.0","0.4.0"],
              "documentation_intelligence":["0.2.0"],"publication_plan":[1],
              "frontmatter":[1],"validate_watch":true,"watch_json":true}}
```

`validate_watch` and `watch_json` are one-time capability probes (`boris
validate --help` contains `--watch`; `boris watch --help` contains
`--watch-json`), always `false` on Windows. Compiler identifiers are opaque and
may carry Boris-owned variant suffixes.

### 4.3 Authoring, graph, and publication passthrough

| Endpoint | Payload | Status field |
|---|---|---|
| `/api/authoring` | `{frontmatter_schema, completion, completion_status}` | `ready` / `build_required` (no `.boris/completion.json`) / `unsupported` (unrecognized discriminator or version) |
| `/api/graph` | `{graph, graph_status}` | `ready` / `build_required` / `unsupported` |
| `/api/publication` | `{profiles, proof, proof_status}` | `ready` / `absent` (no Proof Pack) / `unsupported` (unrecognized Proof Pack) |

- `frontmatter_schema` is the canonical
  [`boris-frontmatter-1.schema.json`](schemas/boris-frontmatter-1.schema.json),
  embedded verbatim in the host at build time and validated through the
  contract adapter. The schema is always present; only completion degrades.
- `completion` is Boris's `.boris/completion.json` forwarded after validation.
- `graph` is Boris's `.boris/graph.json`; the host invents no node, edge,
  backlink, or nav entry.
- `profiles` lists root-level `*.json` files whose `format` is
  `boris-publication-profile` and `schema_version` is `1`, plus a conventional
  `boris.json` even before it is a valid profile; sorted by path, capped at 32.
- `proof` summarizes a validated `dist/_boris/proof/proof-pack.json` and names
  `index.html` only when it exists. Local evidence is not deployment
  verification.
- An unsupported document must never be silently dropped: the status field
  says so and the document field is `null`.

## 5. File operations

### 5.1 Author-owned path rule

A path is author-owned iff it is exactly `boris.json`, or it begins with
`content/` or `themes/`. In addition a path must: be 1–4096 bytes, valid UTF-8,
relative (no leading `/`, no absolute form), contain no `\` or NUL, contain no
empty, `.`, or `..` segment, and not be an editor save temp name
(`.boris-editor-save-<32 hex>.tmp`). Violations are `400 invalid_path`; a
syntactically valid path outside the author-owned roots is `403
path_not_author_owned`.

Every directory component is opened **without following symlinks**, and the
final component is opened as a regular file only (`allow_directory = false`,
`resolve_beneath = true`). Symlinks, directories, device files, and traversal
never resolve. Generated trees (`dist/`, `.boris/`) are not author-owned.

Reads and writes are bounded at **8 MiB per file** (`413 payload_too_large`),
non-UTF-8 content is rejected (`422 invalid_utf8`), and the file list is capped
at **50 000 entries** (`413 too_many_files`).

Documented limit: because the request-body ceiling (§3.3) is 9 MiB of *JSON*,
the effective maximum save is the 8 MiB content cap reduced by JSON escaping
and framing overhead. A near-8 MiB file full of quotes can therefore be
rejected by the body ceiling before the content ceiling is reached.

### 5.2 Fingerprint

`fingerprint` is 64 lowercase hex characters: SHA-256 over
`"<size>:<mtime nanoseconds>:"` concatenated with SHA-256 of the file bytes.
It is opaque to the shell and must be echoed back unchanged on save and probe.
A malformed fingerprint is `400 invalid_fingerprint`.

### 5.3 Responses and shapes

`/api/files` returns a **flat** list, sorted lexicographically by full path:

```json
{"files":[{"path":"boris.json"},{"path":"content/index.md"}]}
```

`open`, `save` (both outcomes), and `create` share the buffer shape:

```json
{"status":"opened","path":"content/index.md","content":"…",
 "fingerprint":"<64 hex>","read_only":false}
```

`status` is `opened` (`open`), `saved` / `conflict` (`save`), or `created`
(`create`, HTTP `201`). `read_only` reflects the file's write permission at
read time.

| Endpoint | Request | Response |
|---|---|---|
| `/api/files/open` | `{path}` | buffer shape, `200` |
| `/api/files/probe` | `{path, fingerprint}` | `{status:"unchanged",fingerprint,read_only}`, `{status:"changed",path,content,fingerprint,read_only}`, `{status:"deleted"}`, or `{status:"transient"}` |
| `/api/files/save` | `{path, content, fingerprint, recreate?}` | buffer shape `200`; conflict buffer with the **disk** bytes at `409`; `409 {"status":"deleted"}` when the file is gone and `recreate` is false |
| `/api/files/create` | `{path, content?}` | buffer shape, `201`; `409 path_already_exists` |
| `/api/files/rename` | `{path, new_path}` | `{"status":"renamed","path":"<new_path>"}` |
| `/api/files/delete` | `{path, confirmed}` | `{"status":"deleted"}`; `409 confirmation_required` when `confirmed` is not true |

`transient` exists so a momentary `AccessDenied`/`Busy`/`SystemResources` on
the disk stays in-session instead of being reported as a conflict or a
deletion.

### 5.4 Save is atomic and never overwrites unreviewed work

A save must:

1. re-read the file and compare the caller's fingerprint against disk;
2. refuse with `conflict` **(carrying the current disk bytes)** when they differ
   — the host never applies a stale buffer;
3. refuse with `409 read_only` when the file is read-only;
4. write a fresh temp file (`.boris-editor-save-<32 hex>.tmp`, created
   exclusively) **in the destination directory**, flush, `fsync`, and only then
   `rename` it over the target, preserving the existing file's permissions;
5. on any failure before the rename, leave the original bytes untouched and
   remove the temp file.

Saving a file that was deleted on disk requires `recreate: true` (a
no-overwrite rename, so a file that reappeared is still not clobbered).
`create` and `rename` are no-clobber: both fail with `409` rather than
replacing an existing file. `delete` consumes no fingerprint but **requires
`confirmed: true`** — the guard is server-side, not only in the shell.

A successful `save`, `create`, `rename`, or `delete` clears that path's
recovery snapshot and records the change with the validation daemon (§7.2).

### 5.5 Recovery snapshots and the editor state root

Dirty-buffer snapshots are **disposable derived state**, never project truth,
and live outside the project under the OS user cache root:

| OS | Base |
|---|---|
| Windows | `%LOCALAPPDATA%` |
| macOS | `~/Library/Caches` |
| other | `$XDG_CACHE_HOME`, else `~/.cache` |

The state root is `<base>/boris-editor/<key>`, where `key` is the first 16
bytes of SHA-256 of the canonical project path as hex (32 chars). It is
project-keyed and stable: two projects never share a state root.

- Snapshots live in `<state_root>/recovery/<sha256(path) hex>.json`, format
  `{"format":"boris-editor-recovery","schema_version":1,"path","content","fingerprint"}`,
  written atomically with `replace = true` (one snapshot per path).
- `GET /api/recovery` returns `{snapshots, skipped}` sorted by path.
  Unparseable files, foreign formats, invalid stored paths, invalid
  fingerprints, oversized or non-UTF-8 content are **skipped and counted**,
  never fatal — one corrupt snapshot must not hide the valid ones. There is
  deliberately no `corrupt_recovery` error code: a damaged snapshot degrades
  the list instead of failing the request.
- `POST /api/recovery/snapshot {path, content, fingerprint}` validates the
  path and fingerprint, caps content at 8 MiB (`413 payload_too_large`) and
  answers `{"status":"snapshotted"}`.
- `POST /api/recovery/clear {path}` answers `{"status":"cleared"}` and is
  idempotent for a path with no snapshot.
- Recovery data never becomes repository truth: it is only offered back for an
  explicit Restore, and a normal save clears it.

## 6. Boris process orchestration

### 6.1 Fixed allowlist

The UI cannot supply argv or a working directory. `/api/commands/run` accepts
one of seven modes and the host builds the exact command; every child runs with
cwd = project root, a 120 s timeout, and 16 MiB stdout/stderr ceilings.

| `mode` | Fixed argv (prefixed by the resolved compiler path) |
|---|---|
| `validate` | `validate --input content --report .boris/html-build-report.json` |
| `ir_build` | `build --input content --out .boris` |
| `html_build` | `build --input content --html-dir dist --report .boris/html-build-report.json` |
| `check` | `check --input content --format json --report .boris/editor-check.json` |
| `impact` | `impact <impact_id> --input content --format json --report .boris/editor-impact.json` |
| `plan` | `plan --profile <profile>` |
| `recipe_scale` | `recipe-scale --input content --id <id> --factor <factor>` |

When project discovery reports `input_mode: cooklang`, `--cooklang` is appended
to every mode except `plan` (mode parity with the one-shot CLI). A timeout or a
stdout/stderr overrun yields a `terminated` process problem, not an API error.

`validate` is served by the managed validation daemon whenever the compiler
advertises `validate --watch` (§7.2); every other mode always uses the one-shot
runner. The invoked mode is reported back as `mode`, so a consumer can tell
which path answered.

### 6.2 Request validation

| Field | Rule |
|---|---|
| `impact_id` | Required for `impact`; forbidden for every other mode. 1–4096 bytes, valid UTF-8, no NUL/CR/LF, and must not start with `-` (so an id can never become an option). |
| `profile` | Required for `plan`; forbidden otherwise. Author-owned relative source path (≤1024 bytes), same option-injection guard. |
| `recipe_scale_id`, `recipe_scale_factor` | Required for `recipe_scale`; forbidden otherwise. Same guards; factor is trimmed, 1–64 bytes, and must not start with `-`. |

Violations are `400 invalid_command_request`.

### 6.3 Outcome model

The result payload is:

```json
{"mode":"validate","exit_code":0,"failure_class":"success",
 "compiler_id":"boris/0.8.2","report_version":"html-build-report-0.2.0",
 "used_stderr_fallback":false,"problems":[],"findings":[],"impact":[],
 "publication_plan":null,"recipe_scale_view":null}
```

- `failure_class` maps the compiler's contracted exit convention —
  `0` success, `1` content, `2` usage, `3` io, anything else (or no exit code)
  `terminated`. The daemon path maps the report's `ok` field to `success` with
  exit 0 or `content` with exit 1, so consumers never see a third convention.
- Each `problem` is
  `{severity, code, message, remediation, source_path, line, column, id,
  origin, position_confidence, packet}`:
  - `origin` is `build_report` (IR/HTML/validate reports), `analysis_report`
    (check/impact), `stderr` (compatibility fallback), or `process`
    (timeout, overrun, dead daemon);
  - `position_confidence` is `exact`, `best_effort`, or `none`. Structured
    diagnostics are `exact` unless line/column are unknown (`none`) or the
    source is a `.cook` page whose code is not `ECOOKLANG` (`best_effort`,
    because the locus is an adapted-Markdown approximation);
  - messages, remediations, codes, and ids are bounded, whitespace/control
    sanitized, and have the absolute project root replaced with `<project>`.
- `used_stderr_fallback` is true when no structured report was consumed. The
  stderr adapter parses the documented `severity: CODE: path:line:col: message`
  form (keeping `best_effort` when a locus is present) and, failing that,
  `error:`/`warning:`/`info:` prose lines as unstructured problems. Unsafe
  paths in stderr are dropped rather than reflected.
- `findings` (check/impact) and `impact` (impact) are Boris-owned analysis
  facts; the host infers neither.
- `plan` and `recipe_scale` results carry `publication_plan` and
  `recipe_scale_view` respectively, forwarded as parsed Boris documents,
  only on a successful exit.

A stale artifact must never be mistaken for this run's output: the host deletes
the report named in the table above before spawning the child, for every mode
that consumes one.

### 6.4 Artifact version negotiation

Before a report is consumed it must pass its discriminator/version check. A
failure is `502 unsupported_boris_artifact` for the command path, or the
explicit `unsupported` status for the passthrough endpoints.

| Artifact | Accepted |
|---|---|
| `completion.json` | `format = boris-completion-index`, `schema_version = 1` |
| `build-report.json`, `manifest.json`, `graph.json` | `schemaVersion` in `0.2.0`, `0.3.0`, `0.4.0` |
| `html-build-report.json` | `schemaVersion = html-build-report-0.2.0` (the retired `0.1.0` is rejected) |
| Documentation Intelligence (`check` / `impact`) | `format = boris-documentation-intelligence`, `schemaVersion = 0.2.0` |
| Publication plan | `format = boris-publication-plan`, `schema_version = 1` |
| Proof Pack | `format = boris-publication-proof-pack`, `schema_version = 1` |
| Frontmatter schema | draft 2020-12 `$schema`, `additionalProperties: false`, schema v1 |
| Recipe scale view | `format = boris-recipe-scale` from stdout |

The host validates only the discriminator/version boundary and the fields it
adapts; Boris and its JSON Schemas remain authoritative for full meaning. A
Boris version bump that changes a forwarded document's shape is a Boris
contract change, and the host's matrix here is what a reviewer must check.

### 6.5 Diagnostic packets

Each problem carries a bounded, metadata-only `packet` (≤4096 bytes) intended
for explicit author copying: `boris`, `editor`, `command`, `exit_class`,
`severity`, `code`, `message`, `remediation`, `source`, `position`, `origin`,
`position_confidence`, and an explicit `context: metadata only; source excerpt
omitted` line. The packet must not contain a source excerpt or the absolute
project identity; the project root is replaced with `<project>` and an unsafe
source path with `<redacted>`.

## 7. Managed daemons

The host supervises **at most one daemon per role per project**: one zero-write
validation daemon and one watch daemon. Both follow the same discipline.

### 7.1 Shared lifecycle rules

- The invocation is fixed by the host from project discovery; the UI never
  supplies argv or a cwd.
- Capability is probed once per host session via the compiler's own `--help`
  and reported in `/api/version`. Windows reports unsupported and never spawns;
  every one-shot path stays unchanged there.
- Reaping is non-blocking (`wait4` with `NOHANG`) so the single-request accept
  loop never blocks on a child. Unexpected death is recovered with bounded
  exponential backoff, 1 s doubling to a 30 s cap, reset on a completed cycle.
- Graceful shutdown is `SIGTERM` then wait for exit (the contract
  `boris watch` / `boris validate --watch` provide), applied both to an explicit
  `stop` and to host teardown. **No orphan compiler process may survive the
  host** — this is the reason the daemons exist in-process instead of as
  detached shells.
- All supervision happens synchronously inside the request loop. There is no
  background thread in the host, so a request handler must never block
  indefinitely on daemon output.

### 7.2 Validation daemon (zero-write)

```text
boris validate --input content --report .boris/html-build-report.json --watch [--cooklang]
```

- **Lazy start.** The daemon spawns on the first validate demand — a
  `/api/commands/run` with `mode: validate` when the compiler advertises
  `validate_watch` — and stays up until host exit. The first demand waits
  (bounded, 120 s) for the initial cycle so it never answers "nothing".
- **Cycles.** The daemon rewrites the report every debounced change
  (replacement, never append) and stays alive across recoverable content
  failures. The host watches the report's mtime + size, and a torn in-place
  read simply fails to parse and is retried on the next poll.
- **The report is the single authority.** A daemon answer is a
  validate-mode result built from the report through the same
  structured-diagnostic path as the one-shot runner, so payloads stay
  byte-compatible and `report_version` is `html-build-report-0.2.0`.
- **A validate demand follows the newest save.** The four mutating file
  endpoints record the change; a validate demand landing within 3 s of one
  waits (bounded, 3 s) for the save-triggered cycle to rewrite the report past
  it, so a manual validate right after a save never answers from before it.
  No pending cycle means no added latency.
- **Reads never spawn.** `GET /api/validate-state` polls liveness and refreshes
  the report but never spawns; only a validate demand does.
- A daemon that died or cannot be kept running answers with a `process`
  problem and, when known, the reaped exit code's failure class, instead of
  serving a stale success.

`GET /api/validate-state` returns
`{supported, state, cycle, failure_class, problems_count, report_age_ms}`.
`state` is `idle` / `running` / `success` / `failed` / `stale` and is derived
only from the daemon's liveness and the report it wrote — never fabricated into
a mid-cycle state. `cycle` counts fully parsed report cycles; `failures` and the
backoff window reset on one. `report_age_ms` is clamped at zero.

### 7.3 Watch daemon (dist writer)

```text
boris watch --input content --html-dir dist --watch-json [--cooklang]
```

- **Explicit start only.** It is never lazy-started: `POST /api/watch/start`
  spawns it, `POST /api/watch/stop` stops it. Start is idempotent and reports
  `started`, `already-running`, or `backing-off`, wrapped with the same state
  object as `/api/watch/state`. Start is refused outright — `409` with
  `{"error":"watch_unsupported"}` or `{"error":"watch_schema_unsupported"}` —
  for an incapable compiler or after an unsupported schema handshake.
- **Event capture is file-based.** The child's stderr (which is the exclusive
  NDJSON stream under `--watch-json`, per
  [`watch-mode.md`](watch-mode.md)) is redirected to
  `<state_root>/watch-events.ndjson`, truncated on every (re)start, and parsed
  on demand by request handlers. Nothing in the accept loop blocks on daemon
  output, and the spool belongs to exactly one daemon generation.
- **Schema handshake.** The first record is `hello`; its
  `watch_events_schema` must equal the host's expected version (currently `1`).
  A mismatch stops the daemon and refuses every later start for the rest of the
  host session, naming the supported version in `last_error` — matching how IR
  artifacts gate on `schemaVersion`.
- **Bounded event ring.** At most 100 events and ~4 MiB are buffered; overflow
  evicts the oldest. `seq` is host-assigned, strictly increasing within a host
  session (across daemon restarts). An unparseable, discriminator-less, or
  oversized line increments `dropped_lines` and **consumes no `seq`**, so a
  cursor client never sees a phantom hole. Unknown future event names are
  buffered verbatim rather than dropped.
- **`dropped_lines` is session-scoped**: it resets to 0 with each editor
  process, so a client that persists an `after` cursor across a host restart
  must resync from `/api/watch/state`'s `seq` / `oldest_seq`.
- **Stop is final for that generation.** An explicit stop (or the daemon's own
  graceful exit 0, which it announces with `watch-stopped`) parks the daemon
  `idle` and clears crash residue, so the post-stop state reads idle and the
  next start is not refused by an inherited backoff. Trailing spool lines from
  the dying process are recorded as history (seq, cycle, ring) but must not
  resurrect the lifecycle state.
- **Supervision heartbeat.** `GET /api/watch/state` and `/api/watch/events`
  drain, reap, and — only if an explicit start already activated it — restart a
  crashed daemon. `/api/health` reaps but never restarts.

`GET /api/watch/state` returns `{supported, state, seq, cycle, events_count,
oldest_seq, dropped_lines, last_event, compiler_id, hello_schema, last_error}`
with the same state vocabulary as `/api/validate-state`. `hello_schema` is a
**number** (the negotiated `watch_events_schema`), or `null` before `hello`.

`GET /api/watch/events?after=<seq>` returns
`{supported, seq, oldest_seq, gap, events:[{seq, event}]}` where `event` is the
compiler's exact NDJSON object. `gap: true` means events the consumer has not
seen were evicted from the head of the ring (more than one missing), so it must
resync from `oldest_seq`. A missing `after` reads as `0`; a malformed one
(empty, non-digits, longer than 20 characters) is `400 invalid_query`, never a
silent truncation. On an unsupported compiler both endpoints answer `200` with
`supported: false` and empty counters rather than an error.

### 7.4 Coexistence and the dist-writer seat

- Both daemons may run at once: the watch daemon (HTML mode) never writes the
  validation report — `--report` is a usage error with `watch` — and the report
  lives under `.boris/`, which the watch loop ignores. They are write-disjoint.
- **Dist-writer mutual exclusion.** Once a watch daemon has been started, the
  host treats `dist/` as owned by it until an explicit stop or a refusal —
  *including* while it is in a backoff-restart window, because a respawn may
  begin writing at any moment. During that ownership
  `POST /api/preview/rebuild` refuses with `409
  {"error":"watch_daemon_active"}` instead of racing the daemon, and
  `/api/preview/state` carries the additive `watch_active: true`. Stopping the
  watch daemon re-enables rebuild.

## 8. Preview origin

### 8.1 Second loopback origin

`boris watch --serve` exists (see [`cli.md`](cli.md) and
[`watch-mode.md`](watch-mode.md)), but the editor's preview is still its own
origin: a second `127.0.0.1` listener on an ephemeral port, created at startup,
that serves **only** the committed `dist/` bytes.

- `GET`/`HEAD` only; any other method is `405`.
- `Host` must be `127.0.0.1:<preview port>` or `localhost:<preview port>`; a
  supplied `Origin` must be the matching `http://` origin.
- Authorization: a `?token=<session token>` query on any path, or the
  `BorisPreview_<preview port>=<token>` cookie that such a request sets
  (`Path=/; HttpOnly; SameSite=Strict`). Comparison is constant-time. Anything
  else is `403`.
  The token is the **same** session token as the host's, and the query form
  exists because iframe subresources cannot carry the launch fragment.
- Paths are guarded exactly as the shell's static paths are (no leading `/`, no
  `\`, `%`, NUL, `.`, `..`), `dist/` is opened without following symlinks, and
  files are read with a 32 MiB ceiling. Missing files are `404`; there is no
  directory listing and no other tree is reachable.
- Responses are `no-store` with `nosniff` and a content type from the file
  extension. The preview origin is not a publication target and terminates with
  the editor process.

### 8.2 Fixed rebuild command

```text
boris build --input content --incremental --html-dir dist [--cooklang]
```

One fixed command per requested rebuild (cwd = project root, 120 s timeout,
16 MiB output caps), triggered by an explicit successful save or the visibly
named Rebuild preview action. The host never watches or renders source, and it
never transforms HTML on the way out: the iframe shows the bytes Boris
committed. Boris's staged commit preserves the last valid `dist/` tree after a
failed rebuild.

`GET /api/preview/state` returns `{phase, generation, exit_code,
used_stderr_fallback, message, preview_url, watch_active}`:

| `phase` | Meaning |
|---|---|
| `idle` | No preview output has been built in this session |
| `running` | A rebuild is in flight |
| `success` | The rebuild succeeded; `generation` advanced |
| `failed` | The rebuild failed and no valid output exists |
| `stale` | Output exists, but from an earlier build or a failed rebuild |

`generation` advances **only** on success, so the shell can reload the iframe
exactly once per successful build. On failure `message` is the last
`error:`/`warning:` line of Boris's stderr with any private project path
removed, and `used_stderr_fallback` says the failure is being reported from
stderr. `preview_url` is the tokened `http://127.0.0.1:<preview port>/` URL the
shell must frame (see §3.4 for the CSP form).

**Open reconciliation.** The compiler's own dev server and this origin now
overlap on serve-and-reload. They differ in posture: the preview origin
requires the session token, validates `Host` and any supplied `Origin`, rejects
traversal and symlinks, and scopes generated subresources with an HttpOnly
cookie; `watch --serve` is an untokened static server on its own port.
Resolving this — delegate to `watch --serve`, or record why this posture is
worth a second server — is **open work**. `AGENTS.md` treats the compiler's
live server as *the* dev server and forbids inventing a second one, so
delegation is the default answer until the posture argument is written down.
A future change must not regress the token/`Host`/traversal defenses while
that decision is pending.

## 9. Error taxonomy

`/api/*` errors are JSON: `{"error":"<code>"}` (plus `{"status":"..."}` for the
file outcomes that carry a body). The mapping is closed:

| Code | Status | Raised by |
|---|---|---|
| `invalid_json` | 400 | Unparseable request body |
| `invalid_query` | 400 | Malformed `?after=` |
| `invalid_path` | 400 | Path rule violation (§5.1) |
| `invalid_fingerprint` | 400 | Fingerprint not 64 hex |
| `invalid_command_request` | 400 | Mode/field mismatch or a bad id/profile/factor (§6.2) |
| `path_not_author_owned` | 403 | Well-formed path outside `boris.json`, `content/`, `themes/` |
| `file_not_found` | 404 | Missing author-owned file |
| `path_already_exists` | 409 | `create` / `rename` collision |
| `read_only` | 409 | Save of a read-only file |
| `confirmation_required` | 409 | `delete` without `confirmed` |
| `unsafe_artifact_path` | 409 | `UnsafeArtifact` / symlink loop in a Boris artifact path |
| `payload_too_large` | 413 | Body ceiling, 8 MiB file, 8 MiB snapshot |
| `too_many_files` | 413 | File list over 50 000 entries |
| `unsupported_media_type` | 415 | Non-JSON or empty `POST` body |
| `invalid_utf8` | 422 | Non-UTF-8 file content |
| `unsupported_boris_artifact` | 502 | Report fails discriminator/version check |
| `invalid_boris_version` | 502 | `boris --version` output not a `boris/…` id |
| `boris_unavailable` | 503 | Compiler could not be spawned |
| `io_error` | 500 | Any other failure, including a non-regular file where a page is expected |
| `watch_daemon_active` | 409 | `POST /api/preview/rebuild` while the watch daemon owns the `dist/` writer seat (§7.4) |
| `watch_unsupported` | 409 | `POST /api/watch/start` on a compiler without `--watch-json`, or on Windows |
| `watch_schema_unsupported` | 409 | `POST /api/watch/start` after a refused `hello` schema handshake (§7.3) |

A `405 Method not allowed` is **not** part of this taxonomy: it is a plain-text
response with an `Allow` header and no JSON error code, and it is specified by
the method discipline in §4. Other non-error outcomes:
`409 {"status":"conflict"}` and `409 {"status":"deleted"}` carry a buffer so
the shell can show the disk version.

## 10. Deliberate exclusions

Not part of this contract unless a later change adds them with an amendment
here:

- an editor-owned parser, graph, validator, renderer, or publication pipeline —
  and any "helpful" local interpretation of Boris output;
- arbitrary commands, argv, working directory, environment, or profiles from
  the UI; LSP; autofix; source rewriting;
- autosave (every write is an explicit request), and any write outside
  `boris.json`, `content/`, `themes/`;
- remote bind, TLS, multi-user sessions, or authentication beyond the
  per-process loopback token; the token is a local consent boundary, not a
  security boundary against a hostile local process;
- HMR, CSS injection, a host-side watcher or renderer, or a second dev server
  (pending the §8.2 reconciliation);
- daemon supervision on Windows (the one-shot paths are the contract there).

## 11. Acceptance

The contract is pinned by the host's own Zig tests and by the black-box
integration scripts; a change here must keep all of them green.

| Script | Pins |
|---|---|
| `editor/scripts/test-host-contract.sh` | This document: §4 reconciled against the host's route table, §9 reconciled against its error set, every documented endpoint probed with `Allow` pinning its methods, generated and plausible-but-absent `/api/*` paths rejected with 404, every documented code driven to its documented status by a live request (including fixture-heavy and stub-compiler scenarios), `Host`/token/`Origin` discipline |
| `editor/scripts/test-host.sh` | Launch-line shape, token/`Host`/`Origin`/traversal discipline, health and version payloads, SIGTERM exit 0 |
| `editor/scripts/test-contract-fixture.sh` | Artifact version negotiation against real compiler output |
| `editor/scripts/test-safe-editing.sh` | Path rules, fingerprint conflicts, atomicity, recovery, restart |
| `editor/scripts/test-diagnostics.sh` | Structured reports, stderr fallback, exit classes 1/2/3, packets |
| `editor/scripts/test-validation-daemon.sh` | One daemon across validates, save → cycle waiting, backoff recovery, SIGTERM reaping |
| `editor/scripts/test-watch-daemon.sh` | Explicit start, schema handshake, event ring and `seq`, dist-writer refusal, coexistence, reaping |
| `editor/scripts/test-preview.sh` | Rebuild byte identity, last-good preservation, preview-origin defenses, CSP framing |

The conformance script drives **every** code in §9 to its documented status
with a live request — including fixture-heavy scenarios (a 50 000-file project
for `too_many_files`, a non-regular file for `io_error`) and stub compilers (an
incapable one, one that emits an unsupported `watch_events_schema`, and one that
reports an unsafe diagnostic source path). There is no static-only code list to
leave a stale entry behind.

`editor/scripts/test-editor-gate.sh` runs all of the above (including the
conformance script) plus the UI checks, build, and Playwright suite against a
given Boris binary, and the CI `editor-test` lane invokes that same script.
Mocked Playwright specs in `editor/ui/tests/` pin the payload shapes the shell
depends on; per §2 they move with this document.
