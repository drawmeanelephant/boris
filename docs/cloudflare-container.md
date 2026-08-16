# Cloudflare Containers runner

Boris can run its **existing native Linux binary** inside a Cloudflare
Container. A Worker is the control plane. The container execs `boris`
once and returns a structured result.

This is **not** a verified publication target. It does not add a name to
`publication.target`. A successful job is not a claim that Cloudflare
served the site. The complementary Wasm path is
[#301](https://github.com/drawmeanelephant/boris/issues/301).

Normative behavior: [`contracts/cloudflare-container-runner.md`](contracts/cloudflare-container-runner.md).
Example host: [`examples/cloudflare-container/`](../examples/cloudflare-container/).

## What you get

- `boris-job-runner` — small Zig host. `--once` for local/CI; `--listen`
  for the container port Cloudflare requires.
- A reproducible image recipe that copies ReleaseSafe `boris` + the runner.
- A Worker example that authenticates, forwards a source archive, and
  can persist the result package to R2.

The compiler is unchanged. The runner is not linked into `boris`.

## Local path (no Cloudflare account)

```bash
zig build                              # installs zig-out/bin/boris and boris-job-runner
python3 - <<'PY'
import tarfile, io, pathlib
root = pathlib.Path("docs/contracts/fixtures/valid/content")
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as t:
    for p in sorted(root.rglob("*")):
        if p.is_file():
            t.add(p, arcname="content/" + str(p.relative_to(root)))
pathlib.Path("test-output/job-runner/valid.tar").parent.mkdir(parents=True, exist_ok=True)
pathlib.Path("test-output/job-runner/valid.tar").write_bytes(buf.getvalue())
PY

./zig-out/bin/boris-job-runner --once \
  --boris ./zig-out/bin/boris \
  --archive test-output/job-runner/valid.tar \
  --result-json test-output/job-runner/valid.json \
  --work-root test-output/job-runner/ws
```

A poisoned fixture (`docs/contracts/fixtures/missing-parent/content`)
must produce `ok: false`, `runnerClass: "content"`, and the
`EPARENTMISSING` diagnostic. It must not list artifacts.

`zig build test` covers path traversal, the valid fixture, and the
poisoned fixture through `runJob` directly.

## Image

Cloudflare Containers require `linux/amd64`. Build the binaries on
Ubuntu CI (or cross-compile) and copy them into the example Dockerfile:

```bash
zig build -Doptimize=ReleaseSafe
# on linux/amd64:
docker build -f examples/cloudflare-container/Dockerfile -t boris-job-runner .
```

The image entrypoint is `boris-job-runner --listen 0.0.0.0:8080
--allow-unauthenticated`. The Worker holds `BORIS_JOB_TOKEN` and is the
authenticated edge; the container port is not public. `BORIS_IMAGE_DIGEST`
is copied into `result.json` when the host provides it.

`scripts/test-job-runner-image.sh` builds the image and runs the valid
and poisoned fixtures when Docker is available. It skips cleanly when
Docker is not.

## Worker example

`examples/cloudflare-container/` is a deployable Worker + Container
pair. It is TypeScript/JavaScript because that is Cloudflare’s control
plane, the same way GitHub Actions YAML is the Pages host. It is not
product architecture.

1. Workers Paid plan.
2. `cd examples/cloudflare-container && npm install`.
3. Create an R2 bucket and bind it as `JOBS` (optional; without it the
   Worker still returns the result JSON).
4. `npx wrangler secret put BORIS_JOB_TOKEN`.
5. `npx wrangler deploy`.

`enableInternet` is `false`. The container never sees R2 credentials.
The Worker streams the result package to R2 when the binding is present.

Instance type defaults to `basic` (1 GiB / 1/4 vCPU / 4 GB). `lite`
(256 MiB, no swap) is a measurement target, not the default. Measure
before claiming a smaller type.

## Trusted input only

Boris still passes raw HTML through Oliver. This runner is for author
content you already trust. Archive path traversal, size limits, and an
authenticated endpoint are the minimum protections. They are not a
multi-tenant isolation policy.

## Parity

Compare container (or `--once`) artifact SHA-256 values to a **native
Linux** `ReleaseSafe` build of the same fixture. Do not claim macOS-vs-
Linux byte identity.

Transport fields in `result.json` (`jobId`, `imageDigest`, `timings`)
are excluded from that comparison.
