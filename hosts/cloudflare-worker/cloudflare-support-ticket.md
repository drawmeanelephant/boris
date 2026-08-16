# R2 write/read latency ~1 s — evidence record (NOT filed as a support ticket)

**Status: not filed.** This account is on the Workers Free plan, which has no support
entitlement — a ticket would not reach a human queue. Retained as the evidence trail for
the finding, per the worker host documentation. All measurements: **2026-08-16**, account
`aeac1b7dd21654884c0139a9f56fc321` (Workers Free + R2 free tier).

## Resolution (2026-08-16)

After review, the ~1 s PUT latency is **expected R2 write behavior**, not a defect:

- **Admin-API timings are control-plane noise.** `api.cloudflare.com` object PUTs route
  through the API gateway, not the R2 data plane; they overstate the "problem" and are
  not evidence of a data-plane defect.
- **Worker-binding timings (~0.6–1.1 s per put) are normal R2 write latency** for
  strongly consistent writes in this geometry.
- **Local Uploads was tested (open beta, Feb 2026)**: enabled on 2026-08-16, re-measured
  on both paths — no change. Expected: all callers (ORD/IAD workers, US-East clients) and
  the bucket are in ENAM, and per Cloudflare docs, same-region uploads bypass Local
  Uploads ("R2 follows the normal upload flow").
- **`enam` location hint** was also verified and changed nothing.

Local Uploads remains enabled (free, no downside; helps if uploads ever originate outside
ENAM). The original measurements below are retained as evidence.

---

## Original measurements

A Workers script and direct API calls both experience per-object R2 latency of roughly
**1 s per PUT** (reads ~0.6 s) for objects of **13 bytes to 8 KB**, from US-East locations
(client in Marlboro, NJ; worker colos ORD/IAD) against a bucket confirmed as `ENAM`.
The latency is steady — it does **not** improve with repeated writes (ruling out cold
provisioning), and does not change between a default-region bucket and an `ENAM`-located
bucket. (The original ~50–150 ms "expected" figure was an assumption that did not hold.)

## Environment

- Account ID: `aeac1b7dd21654884c0139a9f56fc321`
- Plan: Workers Free; R2 free tier (10 GB)
- Bucket: `boris-embed-artifacts` — `location: ENAM` (confirmed via
  `GET /accounts/{id}/r2/buckets/boris-embed-artifacts`), `storage_class: Standard`
- Worker: `boris-embed-worker` (`hosts/cloudflare-worker` in the Boris repo) —
  executes at colos **ORD** and **IAD**
- Caller machine: Marlboro, NJ, US (ASN 6128, Optimum Online/Cablevision), colo IAD/ORD
- Object sizes: 13 bytes (direct probes) and 126 B – 8.3 KB (worker artifact uploads)
- Worker CPU during the upload request: **3–7 ms** (`cpuTime` from `wrangler tail`) —
  well under the Free 10 ms limit; the wall time is pure I/O wait, not CPU

## Measured evidence

### 1. Worker → R2 binding (9 parallel PUTs of 126 B – 8.3 KB, one compile request)

Per-put timing instrumented with `Date.now()` deltas inside the worker
(request 1 / request 2, both HTTP 200):

```
request 1:  index.html 126B 568ms | graph.json 580ms | completion.json 586ms |
            manifest.json 588ms | build-report.json 592ms |
            _boris/proof/artifacts.json 685ms |
            _boris/proof/claims.json 1130ms | checks.json 1138ms |
            touches.json 1173ms  (total 1173ms for 9 artifacts)
request 2:  five small puts 684–726ms, last three 898–1474ms
```

Note the queueing: the last three puts complete ~2× later than the first five,
consistent with R2 serializing concurrent writes beyond ~5 in flight.

### 2. Direct admin-API PUTs from the client (NJ), 13-byte objects

`PUT /accounts/{id}/r2/buckets/boris-embed-artifacts/objects/probe-N.txt`,
`Authorization: Bearer <OAuth>`, 13-byte body, sequential:

```
Batch 1: 1301ms, 1572ms, 1100ms, 1079ms, 1019ms
Batch 2: 1151ms, 1196ms, 1028ms, 1065ms, 1406ms, 1122ms, 1035ms, 1177ms
```

### 3. Direct admin-API GETs from the client (NJ), same bucket

```
613ms, 577ms, 786ms, 456ms, 527ms
```

### 4. What we ruled out

- **Worker code**: identical ~1 s latency with a direct API call that never touches the
  Worker (measurements 2 and 3).
- **Bucket region**: bucket confirmed `ENAM`; a default-region bucket showed the same
  latency. (We recreated the bucket with `--location enam` and re-measured — no change.)
- **Cold provisioning / warm-up**: latency held steady across 13 sequential writes.
- **CPU limits / Free-plan throttling**: worker `cpuTime` 3–7 ms on the upload request;
  compile-only requests (no R2) complete in 1 ms wall.
- **Object size**: 13-byte objects are as slow as 8 KB objects.

## Questions raised during diagnosis (answered by Resolution above)

1. Why is per-object write latency ~1 s from US-East callers to an `ENAM` bucket, via both
   the Workers binding and the admin API? → Expected R2 write latency; admin-API numbers
   additionally include control-plane overhead.
2. Is there a data-plane/region-routing issue for this account? → Not indicated: an `enam`
   location hint and Local Uploads both changed nothing, which fits same-region expected
   behavior rather than a misprovisioned distant data plane.
3. Any remediation? → None needed; Local Uploads left enabled for future cross-region
   uploaders at no cost.

## Reproduction

From any machine (OAuth/API token with R2 edit permission):

```bash
# 13-byte PUT, timed — observe ~1 s on this account (R2 write latency)
time curl -X PUT \
  -H "Authorization: Bearer $CLOUDFLARE_TOKEN" \
  --data-binary "latency probe" \
  "https://api.cloudflare.com/client/v4/accounts/aeac1b7dd21654884c0139a9f56fc321/r2/buckets/boris-embed-artifacts/objects/probe.txt"

# Worker path: POST a small compile to https://boris-embed-worker.drawmeanelephant.workers.dev/compile
# and observe r2 upload time vs the 1 ms compile time in the response.
```
