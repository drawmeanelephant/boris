# Cloudflare Container host example

Official Worker + Container pair for
[#300](https://github.com/drawmeanelephant/boris/issues/300). This is a
**host**, not a publication target. The compiler stays Zig.

Normative contract: [`docs/contracts/cloudflare-container-runner.md`](../../docs/contracts/cloudflare-container-runner.md).
Operator path: [`docs/cloudflare-container.md`](../../docs/cloudflare-container.md).

## Layout

| File | Role |
|---|---|
| `Dockerfile` | `linux/amd64` image: `boris` + `boris-job-runner` |
| `wrangler.jsonc` | Worker + Container class + optional R2 binding |
| `src/index.js` | Authenticate, forward the archive, persist the package |

## Deploy

Requires a Workers Paid plan and Docker (Wrangler builds the image).

```bash
# from the repository root, on linux/amd64:
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/boris zig-out/bin/boris-job-runner examples/cloudflare-container/bin/

cd examples/cloudflare-container
npm install
npx wrangler secret put BORIS_JOB_TOKEN
npx wrangler deploy
```

`bin/` is gitignored. The Dockerfile copies those two binaries.

## Call

```bash
curl -sS -X POST "$WORKER_URL/v1/jobs" \
  -H "Authorization: Bearer $BORIS_JOB_TOKEN" \
  -H "Content-Type: application/x-tar" \
  --data-binary @valid.tar
```

A poisoned archive must return HTTP 200 with `ok: false` and Boris
diagnostics. That is not a transport failure.

Without the `JOBS` R2 binding the Worker still returns `result.json`.
With the binding it also stores `jobs/<jobId>/package.tar`.
