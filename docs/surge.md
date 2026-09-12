# Surge.sh static-host recipe

Surge.sh publishes a directory of static files from the CLI: no build plugin,
no framework integration, and nothing Boris has to know about. Boris writes
`dist/`; `surge` puts it on a CDN.

**This is not a verified target.** There is no `publication.target` named
`surge`, no location provider, no deployer adapter, and no Boris evidence chain
for a Surge deployment. In the [platform model](contracts/publication-platforms.md)
matrix, Surge sits with S3 + CloudFront and Firebase under **never proactive**:
adapter-shaped hosts with no distinct design problem, built only when a concrete
user needs one. A user who needs one gets this recipe, not a product surface.

Normative behavior stays where it lives: [publication platforms](contracts/publication-platforms.md)
(the registry boundary and why Surge is not a member), [publication profile](contracts/publication-profile.md),
[HTML output](contracts/html-output.md) (the `--static-dir` passthrough rules),
and [artifact inventory](contracts/publication-artifacts.md) (what a `committed`
record means).

## 1. Prerequisites

Zig 0.16+ and Node 18+. Install the CLI globally — with `sudo` you do not need
and should not want:

```bash
npm install --global surge
```

If `npm`'s global prefix is root-owned, fix the prefix or use a version manager
rather than escalating. Surge creates the account on your first publish, or you
hand it a token in CI (step 8). Publishing works before the account email is
verified; Surge prints a `surge verify` reminder after the first publish and you
should follow it.

## 2. Build the tree

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/boris --quiet          # content/ → dist/

# with a deployment URL declared for the machine projections:
./zig-out/bin/boris --quiet --sitemap --site-url https://demo.surge.sh
```

`--site-url` is **required** for `--sitemap` and `--rss`, and it must be the URL
you actually intend to deploy to. Boris validates every URL-bearing local
projection — public HTML metadata, sitemap, RSS, location-aware `llms.txt` —
against that identity before writing. Surge performs no equivalent check, so a
mismatch gives you a self-consistent tree pointing at the wrong origin with
nothing to catch it. On this host the location invariant is your responsibility,
not the compiler's.

## 3. Publish

```bash
surge ./dist demo.surge.sh
```

The publish propagates to every edge node while the command runs, and prints the
nodes as it goes; `Success!` means live, not queued. Confirm it from the
outside:

```bash
curl -sI https://demo.surge.sh/ | head -1
# HTTP/2 200
curl -s -o /dev/null -w '%{http_code}\n' https://demo.surge.sh/_boris/proof/checks.json
# 404 — expected once step 6's .surgeignore is in place
```

Those checks are yours to run. Nothing in `zig build test` touches the network,
and Boris makes no post-deploy claim about this host (step 9).

## 4. The CNAME file: declared or deployment-owned

On the first publish to a named domain, Surge records that domain in a `CNAME`
file in the published directory, the same convention GitHub Pages uses. After
that, `surge publish` needs no argument. Two separate facts matter here, and
they are easy to conflate:

- **A Surge-written `dist/CNAME` survives a Boris rebuild.** Boris commits the
  artifacts it declares and never touches unrecorded files in the target
  directory, so `dist/CNAME` is still there after the next `boris --quiet` — no
  passthrough is required merely to keep it from being wiped.
- **But it is deployment-owned.** It is absent from
  `dist/_boris/proof/artifacts.json`, no checks, claims, or Proof Pack entry
  mentions it, and it does not exist on a fresh clone or on a CI runner's first
  build.

If you want the domain to be a **declared** part of your target — inventoried,
copied byte-identically, present before the first publish, and scrubbed from the
committed tree when you delete it — author it in your own source tree and declare
the passthrough:

```text
static/CNAME
    boris-demo.surge.sh
```

```bash
./zig-out/bin/boris --quiet --static-dir static
```

`--static-dir` is the byte-identical passthrough ([#804](https://github.com/drawmeanelephant/boris/issues/804));
its profile equivalent is `static.dir`. Passthrough files land at the target
root, may not collide with generated paths or another passthrough file, and may
never enter the compiler-owned `_boris/` or `.boris-cache/` namespaces.

Either way, one honest consequence: a CNAME file is not a Boris claim that the
domain resolves. Boris writes bytes; Surge serves them.

## 5. Custom domain

Point the domain at Surge once, then publish to it exactly as before:

```bash
surge ./dist example.com
surge example.com debug status    # confirm the domain resolves to Surge
```

There are two ways to point DNS at Surge, per its own documentation: delegate
your name servers to `ns1.surge.world` … `ns4.surge.world`, or keep your provider
and add a `www` CNAME to `geo.surge.sh` (an apex needs an ALIAS/ANAME record or
provider flattening; providers without one cannot CNAME an apex, which is why
delegation is the recommended path). Certificate provisioning is automatic once
the domain resolves. Re-run step 2 afterwards with `--site-url` set to the
custom origin, or the sitemap and RSS keep pointing at the old one.

## 6. Do not publish the proof tree by accident

Surge uploads the directory you hand it. A Boris `dist/` contains
`_boris/proof/` — `artifacts.json`, `checks.json`, `claims.json`, `touches.json`,
`proof-pack.json`, and its `index.html` — plus `_boris/search/`. The GitHub Pages
workflow does not upload those: its copier takes only exact `committed`
inventory records and excludes `_boris/proof`. A bare `surge ./dist` has no such
boundary.

Exclude the evidence reports with a `.surgeignore` in the published directory:

```text
_boris/proof/
```

`surge` reads that file from the directory being published — the local
filesystem, not your working directory — and never uploads it: Surge's default
ignore list already skips `.git`, `.*`, `*.*~`, `node_modules`, and
`bower_components`. To have it present in `dist/` on every build instead of only
after a manual copy, declare it as a passthrough file too:

```text
static/.surgeignore
    _boris/proof/
```

A root-level dotfile is a legal passthrough path: `--static-dir static` copies
it to the target root and records it in the inventory like any other declared
file.

Keep `_boris/search/` when you enabled client-side search. Nothing here is a
secret; the point is that the served tree should be the tree you meant to
publish, and that a proof report published by accident is evidence about a local
build served from a public origin.

Boris already assumes this boundary. Point a page link at its own report tree
and the build fails with `EROUTEMISSING` — "does not resolve to a published
output" — even though the file exists on disk. The compiler treats the report
tree as not published; a bare `surge ./dist` is the command that would publish
it anyway.

## 7. Preview, revisions, rollback

```bash
surge ./dist demo.surge.sh --preview   # preview revision; production untouched
surge demo.surge.sh revs               # list the project's revisions
surge demo.surge.sh rollback           # move the live pointer (instant, global)
surge demo.surge.sh teardown           # remove the project (!destructive)
```

Project commands name the target first — `surge <project> <verb>`, where the
project is a domain, a path, or the current directory. From inside a directory
whose `CNAME` names the project, the short form `surge rollback` also resolves;
in CI and scripts, spell the domain out. Rollback is a pointer move between
revisions already on the edge, not a re-upload: it prints each edge node and
ends with `Done! - <domain> now serving revision <id>`.

`revs` lists revisions newest-first with each revision's preview host, size, and
file count, so a preview URL from a pull request is findable long after the job
log is gone.

## 8. CI: preview on pull requests, production on `main`

Mint a token scoped to one domain on a machine where you are logged in, and put
it in the repository's secrets as `SURGE_TOKEN`:

```bash
surge tokens add --domain demo.surge.sh -m "github actions"
```

```yaml
name: Publish
on:
  push:
    branches: [main]
  pull_request:

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2.2.1
        with:
          version: 0.16.0
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: zig build -Doptimize=ReleaseSafe
      - run: ./zig-out/bin/boris --quiet --sitemap --site-url https://demo.surge.sh
      - if: github.event_name == 'pull_request'
        run: npx surge ./dist demo.surge.sh --preview
        env:
          SURGE_TOKEN: ${{ secrets.SURGE_TOKEN }}
      - if: github.event_name == 'push'
        run: npx surge ./dist demo.surge.sh
        env:
          SURGE_TOKEN: ${{ secrets.SURGE_TOKEN }}
```

Notes that save time later:

- `SURGE_TOKEN` is read from the environment automatically; there is no login
  step and the CLI aborts rather than hanging when configuration is missing.
- Fork pull requests receive no secrets, so preview publishes run on same-repo
  branches only. That is GitHub's model, and it is the behavior you want for a
  token that can publish to your domain.
- The two floating action versions above are deliberate for a copy-paste
  example. This repository's own workflows pin every action to a commit with the
  major version in a comment; do the same in a repository you control.
- A token scoped with `--domain` can publish to that domain and nothing else;
  rotate it with `surge tokens` rather than deleting the secret's paper trail.

## 9. Limits of this path

- **No registry membership.** `publication.target` stays the closed pair
  `"github-pages"` / `"standard-site"`. Adding a name requires a product reason
  that accepts a new location invariant, not completeness — the bar recorded in
  the [platform model](contracts/publication-platforms.md).
- **No location provider.** Surge offers no equivalent of
  `actions/configure-pages`, so nothing resolves `base_url` / `origin` /
  `base_path` for you. Whatever you pass `--site-url` is the identity you assert,
  and it is asserted about local bytes only.
- **No deployment evidence.** Surge's per-node output is Surge's claim about its
  own propagation. Boris does not observe the deployed site here; the bounded
  post-deploy observer for GitHub Pages is the precedent for what that would
  take, and it does not generalize to a host with no normalized plan.
- **No SPA fallback needed.** Boris writes one file per page (`index.html`,
  `guides.html`), not a client-side router, so Surge's `200.html` fallback has
  nothing to fall back from.

## What this recipe was verified against

**The Boris half, offline.** A scratch site with one trunk page and one
satellite page, built with the `ReleaseSafe` binary:

- a Surge-style `dist/CNAME` written by hand **survives** a plain rebuild — the
  target keeps unrecorded files;
- `--static-dir static` places `static/CNAME` and `static/.surgeignore` at the
  target root, records both as `static-file` entries in
  `dist/_boris/proof/artifacts.json`, and they survive repeated rebuilds;
- `--sitemap` without `--site-url` fails; with it, sitemap URLs are bound to
  that origin;
- a page link into `_boris/proof/` fails the build with `EROUTEMISSING`.

**The Surge half, live.** Surge CLI 0.44.1 against a `.surge.sh` domain on
2026-09-11 (UTC 2026-09-12), from Surge's own documentation
([CLI](https://surge.sh/docs/cli), [custom domains](https://surge.sh/docs/platform/custom-domains),
[GitHub Actions](https://surge.sh/docs/guides/github-actions)):

| Step | Result |
|---|---|
| `surge ./dist <domain>` | Published; every edge node reported live; `server: Surge` on the response |
| Routes | `/`, `/index.html`, `/sitemap.xml`, and the satellite route all 200 |
| `.surgeignore` with `_boris/proof/` | `/_boris/proof/checks.json` and `proof-pack.json` 404, as intended; `/_boris/search/search-index.json` 200 |
| `surge ./dist <domain> --preview` | Served a preview host; the production revision did not move |
| `surge <domain> revs` | Two revisions, each with its preview host |
| `surge <domain> rollback` | `Done! - <domain> now serving revision <id>`; the served page reverted to the earlier revision |
| `surge <domain> rollfore` | Served the newer revision again |

The demo stays up at <https://boris-surge-recipe.surge.sh/> — that is a fact
about Surge serving bytes, not a Boris guarantee, and nothing in
`zig build test` touches the network.
