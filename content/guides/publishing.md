---
title: Publishing Workflows
parent: guides
status: published
tags: [guides, publication, pages, standard-site]
summary: Local dist/ first, then a hosted target. GitHub Pages and Standard.site are verified. Nostr is a shipped CLI family, not a verified target.
---

<p class="eyebrow">Targets</p>

# Publishing Workflows {#publishing-workflows}

{{include includes/identity.md}}

Publishing is a **workflow**, not a single command and not a guess. Every
publication is: pick a target from the registry → normalize the declaration →
validate the location → build → (optional) deploy → (recorded) evidence.

HTML `dist/` is the default target, not the whole product. GitHub Pages and
Standard.site are verified targets. Nostr NIP-23 is a shipped CLI family, not
a third verified-target name.

<Aside kind="info" id="registry">

Publication is a **registry**, not a shell recipe. The closed target names
today are `github-pages` and `standard-site`. Unknown names fail in the
profile parser. A wish is not a target.

</Aside>

## The workflow in one line {#workflow-in-one-line}

```text
local dist/  →  first verified hosted target (GitHub Pages)
            →  second verified target (Standard.site, when you mean Atmosphere)
            →  Nostr plan/sign/publish (shipped, not a verified target)
```

Local is always step one. Hosted targets are explicit steps you choose, and
each one has its own evidence after the publish.

<Aside kind="tip" id="first-time">

A first-time author stops at local `dist/` or GitHub Pages. Standard.site is a
second verified target for testers who already have a `dist/` they trust.
`boris nostr publish` is not a first command.

</Aside>

## Step 1 — Publish local HTML {#local-html}

```bash
./zig-out/bin/boris validate --quiet
./zig-out/bin/boris --quiet
```

`validate` runs the same prepublication path and discards it — writes nothing.
`boris --quiet` writes `dist/`. Open `dist/index.html` to read, or serve the
directory with any static file server when you want the browser search UI to
fetch its same-origin index.

Local HTML
: Always first. Inspectable. No credentials. No deployment claim.

`boris plan --profile PATH`
: Normalize the declared target. Does not discover content and does not
  publish. This is the moment you find out the target name and location
  declaration are valid.

A successful `dist/` is **not** a deployment claim. Evidence after a hosted
publish is a different chain (step 4).

## Step 2 — Choose and enable a hosted target {#which-target}

| Order | Target | When | First command |
| :---: | :--- | :--- | :--- |
| 1 | Local `dist/` | Always | `boris --quiet` |
| 2 | GitHub Pages | You want the first verified hosted target | Official Actions workflow |
| 3 | Standard.site | You mean Atmosphere records | `boris standard-site` |
| — | Nostr | You want NIP-23 events | [[guides/nostr-publication|plan → sign → publish]] |

### Enable GitHub Pages {#github-pages}

In **Settings → Pages**, choose **GitHub Actions** as the source. That points
GitHub at the official workflow at `.github/workflows/github-pages.yml`, which
runs for pushes to `main` and can also be started with **Run workflow**.

That workflow is the whole delivery: it builds with the native Boris binary,
**resolves** the Pages location through `actions/configure-pages`, **validates**
that location in a Boris publication profile, and **uploads only the verified
public site tree** from the committed inventory. You do not assemble the
parts by hand.

### Enable Standard.site {#standard-site}

Atmosphere publication is a separate, explicit family under
`boris standard-site`. The static HTML site stays canonical; Standard.site
writes `site.standard.publication` and one `site.standard.document` per
eligible page. First testers start with the app-password path, not the
browser OAuth path.

## Step 3 — Walk the workflow to deployment {#deploy}

### GitHub Pages: location first {#pages-location}

The workflow records three related values and makes them agree
(`EPUBLICATIONLOCATION` if they do not):

| Pages shape | Example `base_url` | `base_path` |
| :--- | :--- | :--- |
| Project site | `https://owner.github.io/boris` | `/boris` |
| User/org root | `https://owner.github.io` | empty |
| Custom domain | `https://docs.example.com` | empty |

Every URL-bearing projection (HTML public metadata, sitemap) is bound to the
same identity. Root and custom-domain builds pass an explicit empty
`--pages-base-path`. A custom domain with a non-empty path fails closed.

The Pages artifact is copied from the exact `committed` inventory records in
`dist/_boris/proof/artifacts.json`: byte counts and SHA-256 verified,
`index.html` required, symlinks and hard links rejected, the supported 1 GiB
Pages artifact limit enforced, and proof reports excluded. No `.nojekyll` is
needed — artifact-based `deploy-pages` uploads are served as-is.

The build also retains a separate evidence artifact
(`boris-github-pages-evidence-<run id>`) holding the normalized plan, the
target-local proof reports, and `github-pages-evidence.json`, which binds the
source commit, Boris/Oliver pins, workflow identity, inventory digest, and
public-tree manifest digest.

<Aside kind="note" id="what-pages-does-not-claim">

A green workflow is not proof of accessibility, prose quality, or that a
search engine will crawl you. Successful `deploy-pages` means GitHub accepted
the Pages artifact for deployment — a distinct claim from “every URL was
observed by a post-deploy HTTP audit.”

</Aside>

#### Optional: a bounded post-deploy audit {#post-deploy-audit}

The manual **Run workflow** form has an `audit_deployment` boolean, disabled
by default. When enabled, the deploy job builds the standalone
`boris-github-pages-audit` tool and observes the live Pages URL against the
exact retained plan and inventory. The result is uploaded as a **separate**
evidence artifact — never copied into the public tree. Bounds: 256 HTTP
requests including redirects, 8 MiB per response, three redirects per URL, a
10-second per-request timeout. It sends no credentials.

Push-triggered runs keep the audit disabled.

### Standard.site: offline first {#standard-site-deploy}

The Standard.site flow separates offline work from any credential:

```text
boris standard-site plan    --profile profiles/standard-site.json
boris standard-site records --profile profiles/standard-site.json
boris --quiet
boris standard-site login --app-password --handle YOU.test.bsky.social
boris standard-site publish --profile profiles/standard-site.json --did did:plc:…
boris standard-site logout --did did:plc:…
```

| Path | Status |
| :--- | :--- |
| Offline `plan` / `records` / `verify` | Works. No network, no credentials. |
| App-password login + publish + smoke | Works against bsky.social. First-tester path. |
| Browser OAuth | Implemented. Requests granular `repo:` scopes; the live smoke verifies the grant. |

<Aside kind="danger" id="app-password">

App passwords grant **broad account write**, not just Standard.site. Use a
dedicated, non-personal test identity. Never put the password on argv, in the
profile, in the environment, in git, or in evidence.

</Aside>

<Aside kind="warning" id="verify-emit">

Production HTML does **not** yet emit verification surfaces (head links +
well-known). `verify` against a real `dist/` fails closed until that emit
lands. Plan and publish do not wait on it.

</Aside>

## Step 4 — Read the evidence {#evidence}

Hosted publication records a target-local chain. Each file is bound to the one
before it:

artifacts.json
: What bytes were committed.

checks.json
: What was checked against those bytes.

claims.json
: What the compiler is willing to claim, and what it refuses to.

touches.json
: The Touch Atlas — relationships among the three reports.

proof-pack.json + index.html
: The Proof Pack presentation over the whole chain.

```text
dist/_boris/proof/
  artifacts.json
  checks.json
  claims.json
  touches.json
  proof-pack.json
  index.html
```

<Details summary="A build is not a deployment">

`boris --quiet` writes this evidence for the HTML target. That is publication
of files, not a claim that GitHub or a PDS served them. The optional Pages
observer is a separate, explicitly bounded contract.

</Details>

## What is not a target {#not-a-target}

Nostr NIP-23
: Shipped CLI. Stays off the verified-target registry on purpose:
  relays are not a host. See
  [[guides/nostr-publication|Nostr NIP-23 Publication]].

Cloudflare Pages / Vercel / Netlify
: Adapter-shaped. No recipe in this guide. Cloudflare static Pages is the
  only “deliberate second static platform” and waits for a user.

Cloudflare Containers / Wasm
: Compiler-shaped bets, not deployer adapters. The Wasm path has an
  example Worker host at
  [`hosts/cloudflare-worker/`](https://github.com/drawmeanelephant/boris/blob/afterparty/hosts/cloudflare-worker/README.md) (#301); Containers have
  an official hosted-runner example (`boris-job-runner`) with operator path in
  `docs/cloudflare-container.md` (#300). Neither is a `publication.target`.

The editor
: An authoring surface. It can run `Build HTML`. It is not a publication
  target.

<Details summary="The platform map, in one sentence">

GitHub Pages is the verified **depth model**; Standard.site is the second
verified **target**. Everything else is waiting, off the seam, or not a host.
The normative platform model is the
[publication-platforms contract](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/publication-platforms.md).

</Details>

## Next steps

- [[getting-started|Getting Started]] — build the local site first
- [[guides/nostr-publication|Nostr NIP-23]] — plan → sign → publish
- [[guides/cli-and-modes|CLI & Output Modes]] — build, validate, `check`, `impact`, and projections
- [[guides/editor|Boris Editor]] — compiler-backed authoring
- [[reference/outputs|Outputs & Artifacts]] — what lands under `dist/`
- [[reference/commands|Command Reference]] — flags and exit codes