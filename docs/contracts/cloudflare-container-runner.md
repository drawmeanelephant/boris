# Hosted job runner (Cloudflare Containers)

**Status:** normative contract — first slice implemented
**Version:** 1 (`boris-job-1`)
**Emitted by:** `src/job_runner.zig` (`boris-job-runner`)
**Host example:** [`examples/cloudflare-container/`](../../examples/cloudflare-container/)
**Operator path:** [`../cloudflare-container.md`](../cloudflare-container.md)

This is **not** a publication target. It does not add a name to
`publication.target`, it does not implement the verified-target adapter
seam, and a successful job is not a deployment claim. Cloudflare
Containers is one host for a small job runner that execs the existing
native `boris` binary once and returns a structured result.

The complementary Wasm embedding path is [#301](https://github.com/drawmeanelephant/boris/issues/301)
and is out of scope here.

---

## Why this exists

Boris already produces a complete publication package locally. A Worker
cannot run that binary inside an isolate. Cloudflare Containers can: the
Worker is the HTTP/authentication/control plane; the container has a
real Linux filesystem and runs ordinary native `boris`.

The runner is the product slice. The Worker is an official example of a
Cloudflare host, the same class as `.github/workflows/github-pages.yml`.

---

## Shape

```
source archive (ustar)
        |
        v
boris-job-runner
  - authenticate (listen mode)
  - reject a hostile archive
  - unpack into an isolated workspace
  - exec native `boris` once (no retry)
  - collect exit, report, artifacts, timings
  - delete the workspace
        |
        v
result.json  (+ optional result.tar)
```

`--once` is the local and CI path. `--listen` is the container path
(Cloudflare requires a listening port). Both call the same `runJob`.

---

## Request

The source body is an uncompressed **ustar** archive. Gzip/zip/pax-only
archives are rejected.

The archive must contain a `content/` directory at the archive root.
That directory is passed to `boris` as `--input`. Only `content/` is
visible to the compiler in `boris-job-1`: the fixed argv has no flag that
names a theme root, layout path, or publication profile, so other
top-level archive members are inert. Pages that need managed theme
assets ship them as content-local `content/themes/...` trees; the
default layout resolves against the runner process cwd (the official
image provides `themes/boris` there). There is no automatic prefix-strip
of a wrapping folder.

Optional query (HTTP) or flag (`--once`):

| Field | Values | Default |
|---|---|---|
| `command` | `build` \| `validate` | `build` |
| `jobId` | one path segment `[A-Za-z0-9._-]{1,64}` | first 16 hex of SHA-256(archive) |

`build` execs:

```text
boris --quiet --input <workspace>/content --html-dir <workspace>/out --report <workspace>/report.json
```

`validate` execs:

```text
boris validate --quiet --input <workspace>/content --report <workspace>/report.json
```

No other argv is accepted in this slice. `--watch`, `--jobs`,
`standard-site publish`, `nostr sign`, and key material cannot be
reached through the runner.

---

## Result (`boris-job-1`)

Deterministic pretty-printed JSON, 2-space indent, trailing LF, fixed
key order:

```text
schemaVersion, format, ok, status, runnerClass, exitCode,
compilerId, borisVersion, runnerId, imageDigest, jobId, command,
diagnostics, artifacts, limits, timings, workspaceRemoved, retried
```

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | `"boris-job-1"` | This contract |
| `format` | `"boris-job"` | Machine format id |
| `ok` | bool | `true` only when `runnerClass` is `ok` and Boris exited 0 |
| `status` | `"success"` \| `"failed"` | Mirror of `ok` for hosts that key on a string |
| `runnerClass` | enum | See below |
| `exitCode` | integer \| null | Boris process exit; `null` if Boris never started |
| `compilerId` | string \| null | From the HTML `--report` when present; else `boris --version` |
| `borisVersion` | string \| null | Product version recorded by the runner (`0.8.2` today) |
| `runnerId` | string | `boris-job-runner/<product-version>` |
| `imageDigest` | string \| null | `BORIS_IMAGE_DIGEST` when the host set it |
| `jobId` | string | Job identity |
| `command` | `"build"` \| `"validate"` | What ran |
| `diagnostics` | array | HTML-report diagnostic objects, same key order as [`diagnostics.md`](diagnostics.md) |
| `artifacts` | array | `{path, size, sha256}` for files under `out/`, sorted by `path`; empty when `ok` is false or `command` is `validate` |
| `limits` | object | The limits that governed this job |
| `timings` | object | `{wallMs, unpackMs, compileMs}` — transport metadata, excluded from parity |
| `workspaceRemoved` | bool | `true` when the workspace was deleted |
| `retried` | bool | Always `false`. The runner does not retry. |

`ok` is never `true` when any `error` diagnostic was emitted, when Boris
exited non-zero, or when the runner refused the job. Failed content
validation returns diagnostics and does not present the job as
successfully published.

Schema: [`schemas/boris-job-1.schema.json`](schemas/boris-job-1.schema.json).

---

## `runnerClass`

| Class | When | Typical HTTP |
|---|---|---|
| `ok` | Boris exited 0 with zero error diagnostics | 200 |
| `content` | Boris exited 1 | 200 (the job completed; the compile failed) |
| `usage` | Boris exited 2 | 200 |
| `io` | Boris exited 3 | 200 |
| `archive` | Path traversal, symlink, unsupported type, missing `content/` | 400 |
| `limit` | Source, expanded, file-count, or artifact bound exceeded | 413 |
| `timeout` | Compile exceeded `timeoutMs` | 504 |
| `auth` | Listen mode, missing or wrong bearer token | 401 |
| `process` | Spawn failed, unexpected signal, or unclassified exit | 500 |

HTTP 200 on `content` is deliberate: the Worker must not translate a
poisoned fixture into a transport failure. The body carries `ok: false`.

---

## Archive rules

Every member is checked before any byte is written:

- uncompressed ustar only
- regular files and directories only — symlink, hard link, device, and
  unknown types are `archive`
- names are rejected when they are empty, contain NUL or `\`, start with
  `/`, contain a `.` or `..` component, contain `//`, or exceed 1024 bytes
- expanded size is the sum of file sizes; exceeding `expandedBytes` is `limit`
- file count exceeding `fileCount` is `limit`
- archive byte length exceeding `sourceBytes` is `limit`

The workspace is created empty, used for one job, and deleted on every
path including failure.

---

## Limits (defaults)

| Limit | Default | Cap |
|---|---|---|
| `sourceBytes` | 16 MiB | 32 MiB |
| `expandedBytes` | 32 MiB | 64 MiB |
| `artifactBytes` | 64 MiB | 128 MiB |
| `fileCount` | 10 000 | 20 000 |
| `timeoutMs` | 120 000 | 300 000 |

The first slice is for **trusted author content**. Boris still passes raw
HTML through Oliver. This contract does not establish a safe multi-tenant
untrusted-content service.

---

## Listen mode

`--listen ADDR` binds a TCP port and serves:

| Method | Path | Body | Response |
|---|---|---|---|
| `GET` | `/health` | — | `{"ok":true,"runnerId":"...","schemaVersion":"boris-job-1"}` (no auth) |
| `POST` | `/v1/jobs` | ustar | `result.json` |
| `POST` | `/v1/jobs/package` | ustar | ustar of `result.json` then `artifacts/**` |

`POST` requires `Authorization: Bearer <token>` unless the process was
started with `--allow-unauthenticated`. The token is `BORIS_JOB_TOKEN`.
It is not written to the workspace, the result, or diagnostics.

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `BORIS_BIN` | PATH lookup of `boris` | Native compiler binary when `--boris` is not given. The default layout resolves against the runner process working directory. |
| `BORIS_WORK_ROOT` | `/tmp/boris-jobs` | Workspace parent when `--work-root` is not given. |
| `BORIS_JOB_TOKEN` | (none) | Bearer token for `POST /v1/jobs*`; see above. |
| `BORIS_IMAGE_DIGEST` | (none) | Recorded as `imageDigest` in `result.json`; see above. |

The official image starts with `--allow-unauthenticated` because the
Worker is the authenticated edge and the container port is not public.
A listen process that is reachable from the internet must set
`BORIS_JOB_TOKEN` and omit that flag.

The process handles one request at a time. That is the isolation model:
one job, one workspace, one `boris` exec, then cleanup.

---

## Security boundary

Minimum protections for this slice:

- archive path-traversal rejection
- source, expanded, artifact, file-count, and wall-clock limits
- no inherited job secrets in the workspace
- no silent retry
- workspace removal after completion
- authenticated build endpoint in listen mode
- outbound network is a host concern (`enableInternet = false` on the
  official Worker example). The runner itself makes no network calls.

Multi-tenant isolation, HTML sanitization, abuse quotas, and GitHub
webhook checkout are follow-ups, not this contract.

---

## Parity

A successful container (or `--once`) build of a fixture must produce
**byte-identical artifact SHA-256 values** to a native build of the same
fixture **on the same OS and architecture**, excluding `result.json`
transport fields (`jobId`, `imageDigest`, `timings`).

Cross-OS byte identity (macOS vs Linux) is **not** claimed. Compare
Linux-container output to a native Ubuntu `ReleaseSafe` build.

---

## Non-goals

- Running native `boris` inside a Worker isolate
- Rewriting Boris in TypeScript or JavaScript
- Adding `cloudflare` (or any other name) to `publication.target`
- Full multi-tenant SaaS
- Arbitrary untrusted repository execution
- GitHub checkout or webhook triggers
- Preview deployments / per-run public `base_url`
- Replacing the local CLI
- Solving the freestanding Wasm path (#301)

---

## Versioning

`schemaVersion` is `boris-job-1`. Additive fields may appear only if
existing keys, order, and meaning stay the same. A breaking change bumps
the identifier and this contract together.

`runnerId` tracks the product version in `src/pipeline.zig`
(`boris_version`). The version-pin script checks that lockstep.
