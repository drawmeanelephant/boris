---
published_at: 2026-08-14T00:00:00Z
summary: How Oliver publishes this docs tree to GitHub Pages with a pinned Boris binary: profile, plan, artifact, and audit contracts.
---

# GitHub Pages publication

Oliver publishes this `docs/` tree to GitHub Pages with a Boris binary built
from a pinned Boris revision. The official workflow lives at
`.github/workflows/github-pages.yml`. It builds the documentation with the
native Boris binary, resolves the Pages location through
`actions/configure-pages`, validates that location in a Boris publication
profile, and deploys only the verified public site tree.

Oliver is the markdown rendering library *inside* Boris; the dependency is
one-way at the toolchain level. Boris pins Oliver as a library in its own
`build.zig.zon`, and this repository uses a Boris binary to publish its docs —
there is no build cycle. The Boris revision is pinned in the workflow and
recorded in the retained evidence, so the binary that produced the site is
always identifiable.

## Pipeline at a glance

```text
profile ──> plan ──> validate ──> compile ──> artifact ──> deploy ──> [audit]
   │          │         │            │            │           │
   │          │         │            │            │           └─ optional, opt-in
   │          │         │            │            └─ public-site, inventory-verified only
   │          │         │            └─ dist/ HTML + sitemap + rss.xml + llms.txt + _boris/proof/ reports
   │          │         └─ local preflight; skips the link audit — the CI gate runs the full compile
   │          └─ normalized plan; the single source of URL truth
   └─ generated from configure-pages outputs
```

Each stage is governed by a normative contract in
[`contracts/`](contracts/index.html):

| Stage | What it produces / does | Contract |
|---|---|---|
| Profile | `jq` builds the profile from `configure-pages`; `boris plan --profile` validates it | [publication-profile](contracts/publication-profile.html) |
| Plan | normalized declaration with `site_kind` and the cross-checked `base_url`/`origin`/`base_path` | [publication-plan](contracts/publication-plan.html) |
| Validate | local preflight: renders pages + sitemap in memory, no writes; skips the post-render link audit, so the CI gate runs the full compile ([boris#430](https://github.com/drawmeanelephant/boris/issues/430)) | — (see compile) |
| Compile | HTML + sitemap under `dist/`; every URL projection audited against the declared location; proof reports emitted. `rss.xml` + `llms.txt` are generated afterward by the standalone exporters (see [Projections](#projections)) | [publication-model](contracts/publication-model.html) · [checks](contracts/publication-checks.html) · [claims](contracts/publication-claims.html) |
| Artifact | inventory-verified copy into `public-site/` (bytes + SHA-256, `index.html`, 1 GiB bound) | [artifacts](contracts/publication-artifacts.html) · [touches](contracts/publication-touches.html) · [proof pack](contracts/publication-proof-pack.html) |
| Deploy | `deploy-pages` publishes the artifact to the `github-pages` environment | — (GitHub's contract) |
| Audit (optional) | bounded HTTP observation bound to the retained plan and inventory | [deployment evidence](contracts/github-pages-deployment-evidence.html) |

## Enable the target

In the repository’s **Settings → Pages**, choose **GitHub Actions** as the
source. The workflow runs for pushes to `main` and can also be started with
**Run workflow**. The workflow uses the supported Pages action sequence:

1. `actions/checkout@v6`
2. `actions/configure-pages@v5`
3. `actions/upload-pages-artifact@v4`
4. `actions/deploy-pages@v4`

The workflow references immutable action commits with the released major
version in a comment. The Zig setup action is likewise pinned to the reviewed
`v2.2.1` commit. The deploy job requires a `github-pages` environment (create
it in **Settings → Environments** if it does not exist; add protection rules
as desired).

It grants `contents: read` and `pages: read` to the build job. The deployment
job alone receives `pages: write` and `id-token: write`. Build and deployment
concurrency is serialized so an older run cannot cancel a newer deployment
halfway through.

## Toolchain: the pinned Boris revision

The workflow checks out the Boris repository at the workflow-level `BORIS_REV`
environment variable into `boris/`, installs Zig 0.16.0, and builds the
toolchain:

```text
zig build -Doptimize=ReleaseSafe      # in boris/
```

`BORIS_REV` is the single bump point for the toolchain pin; it is referenced
from both checkouts (build and optional audit observer) and recorded in the
retained evidence and build summary. Bump it only after locally re-validating
against this `docs/` tree (see [Local parity](#local-parity-and-the-starter-profile))
at the new revision. The reference workflow builds Boris from its own source;
Oliver cannot do that, so the pinned checkout is the one genuinely new design
decision in the adapted workflow — everything else carries over.

## Location model

GitHub supplies three related values to the workflow: `base_url`, `origin`, and
`base_path`. Boris records them in the temporary profile used by
`boris plan --profile` and rejects contradictions before the site build:

| Pages shape | Example `base_url` | `origin` | `base_path` |
|---|---|---|---|
| Project site | `https://drawmeanelephant.github.io/oliver` | `https://drawmeanelephant.github.io` | `/oliver` |
| User/org root site | `https://drawmeanelephant.github.io` | `https://drawmeanelephant.github.io` | empty |
| Custom domain | `https://docs.example.com` | `https://docs.example.com` | empty |

The current declaration slice does not invent a CNAME or probe the network.
If a custom domain is configured with a non-empty path, or if `base_url` does
not equal `origin + base_path`, the profile fails closed. The normalized
identity is also available in the [publication profile](contracts/publication-profile.html)
and [publication plan](contracts/publication-plan.html) contracts.

The build step consumes that normalized plan identity directly:

```text
boris/zig-out/bin/boris --input docs \
  --target public=dist \
  --target-layout public=themes/oliver/layouts/main.html \
  --sitemap \
  --pages-base-url https://drawmeanelephant.github.io/oliver \
  --pages-origin https://drawmeanelephant.github.io \
  --pages-base-path /oliver \
  --site-url https://drawmeanelephant.github.io/oliver \
  --quiet
```

`--input docs` is explicit because the CLI default content root is `content`;
this repository publishes its `docs/` tree with the `themes/oliver` theme. The
compiler audits rendered root-relative/public metadata URLs before target
replacement and binds sitemap URLs to the same identity. `EPUBLICATIONLOCATION`
is an actionable publication failure. Root and custom-domain builds pass an
explicit empty `--pages-base-path`. The check is against the local generated
artifact; this workflow still makes no post-deploy HTTP claim.

## Local parity and the starter profile

Before touching Actions, run the same pipeline locally. The repository ships a
[starter publication profile](https://github.com/drawmeanelephant/oliver/blob/main/publication-profile.example.json) declaring
the project-site shape (`input: docs`, `theme: themes/oliver`,
`https://drawmeanelephant.github.io/oliver`) at the repository root, so every
path resolves workspace-relative. From the repository root:

```text
boris/zig-out/bin/boris plan --profile publication-profile.example.json > /tmp/plan.json
boris/zig-out/bin/boris validate --input docs \
  --target public=dist \
  --target-layout public=themes/oliver/layouts/main.html \
  --sitemap \
  --pages-base-url https://drawmeanelephant.github.io/oliver \
  --pages-origin https://drawmeanelephant.github.io \
  --pages-base-path /oliver \
  --site-url https://drawmeanelephant.github.io/oliver
```

`plan` writes the normalized declaration (exit 2 on an invalid profile, 3 on
I/O failure); `validate` renders the pages and sitemap in memory without
writing artifacts. Note that `validate` deliberately skips the post-render
link audit — location escapes (`EPUBLICATIONLOCATION`) and broken local
routes (`EROUTEMISSING`) pass it silently (see
[boris#430](https://github.com/drawmeanelephant/boris/issues/430)) — so the
authoritative prepublication check is the full compile command above, which
is exactly what the CI gate runs. Confirm exit 0 before the first CI run. The
profile is the single source of URL truth — never re-derive the Pages
location from the repository name.

## Projections: sitemap, RSS, and llms.txt

The public target declares three projections in the publication profile, and
the normalized plan records each one under `projections` so the post-deploy
audit can verify them:

| Projection | Path | Producer | Audit check |
|---|---|---|---|
| Sitemap | `sitemap.xml` | compiler (`--sitemap`) | `sitemap` |
| RSS 2.0 | `rss.xml` | exporter (`--rss`) | `rss` |
| llms.txt | `llms.txt` | exporter (`--llms`) | `llms` |

Declaring `rss` requires `site.url` **and** `site.title`/`site.description`
in the profile (`RssRequiresSiteMetadata` otherwise); the starter profile at
`publication-profile.example.json` carries all three.

RSS items come from pages whose frontmatter declares `published_at` (RFC
3339, e.g. `2026-08-13T00:00:00Z`) and `summary`; pages without them are
omitted, so the feed lists only documented publications. Add the block to a
doc to publish it in the feed:

```markdown
---
published_at: 2026-08-13T00:00:00Z
summary: One-line description of the document.
---
```

Frontmatter is metadata only: `published_at`/`summary` do not change the
rendered HTML. `boris --rss` sorts items by date descending, honors
`--rss-limit` (default 20), validates every link against the declared Pages
location, and fails on `published_at` values that are not RFC 3339.
`boris --llms` emits an absolute-URL link index for the whole graph, rooted
at the declared location.

The compiler at the pinned revision emits HTML/search/sitemap only, so the
workflow runs the two standalone exporters after the compile and appends
their records (bytes + SHA-256, re-sorted canonically) to the compiler-owned
inventory at `dist/_boris/proof/artifacts.json`. This is required by the
audit's plan↔inventory consistency rule: a projection declared in the plan
but absent from the inventory fails the deployment report, as does an
inventoried projection the plan omits. The CI gate runs the same two
exporters so a bad date or a projection URL escape fails before merge.

## Public artifact and retained evidence

The workflow creates two deliberately different uploads:

- The Pages artifact is copied from the exact `committed` records in
  `dist/_boris/proof/artifacts.json`. The copier checks every byte count and
  SHA-256, requires `index.html`, rejects symlinks and hard links, enforces the
  supported 1 GiB Pages artifact limit, and excludes `_boris/proof` reports.
- The retained evidence artifact contains the normalized plan, the target-local
  proof reports, and `github-pages-evidence.json`. That binding records the
  source commit, the pinned Boris revision and version, workflow identity,
  inventory digest, public file count/bytes, and the exact public-tree manifest
  digest.

The build summary reports the target, resolved URL/path, public payload size,
inventory binding, compiler finding count, the pinned Boris revision, and the
explicit limitation that deployment verification and a post-deploy HTTP audit
are not claimed by this workflow. A successful `deploy-pages` job means GitHub
accepted the Pages artifact for deployment; it is not a Boris claim that every
URL projection or browser request was audited.

## Optional post-deploy audit

The manual **Run workflow** form has an `audit_deployment` boolean, disabled by
default. When enabled, the deploy job downloads the exact retained plan and
target-local inventory from the build job, builds the standalone
`boris-github-pages-audit` Zig tool from the same pinned Boris checkout, and
passes it the successful `deploy-pages` `page_url`. Push-triggered runs keep
the audit disabled unless a future workflow-level control explicitly opts in.

The observer writes and uploads
`boris-github-pages-deployment-evidence-${{ github.run_id }}` as a separate
ordinary artifact. It is never copied into `public-site`, `_boris/proof`, or
the Pages artifact. The deployment summary distinguishes the build artifact,
deployment acceptance, and optional post-deploy audit. The audit step uses
`continue-on-error` so a failed or incomplete observation still reaches the
upload step; the JSON report carries the actionable result and limitations.

The default observer bounds are 256 HTTP requests including redirects, 8 MiB
per decoded response, three redirects per URL, a 10-second per-request
timeout, and 256 parsed URLs per projection/page. It sends no credentials or
cookies, accepts only HTTP(S) deployment URLs inside the normalized Pages
location, and records body digests separately from cache/ETag metadata. See
the [deployment evidence contract](contracts/github-pages-deployment-evidence.html)
for the result vocabulary, evidence binding, and coverage limits.

For GitHub’s workflow requirements and action behavior, see the
[custom workflows for GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages),
[`configure-pages`](https://github.com/actions/configure-pages),
[`upload-pages-artifact`](https://github.com/actions/upload-pages-artifact), and
[`deploy-pages`](https://github.com/actions/deploy-pages) documentation.
