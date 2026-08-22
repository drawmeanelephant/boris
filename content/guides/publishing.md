---
title: Publishing Targets
parent: guides
status: published
tags: [guides, publication, pages, standard-site]
summary: HTML dist/ is the default target. GitHub Pages and Standard.site are verified. Nostr is a shipped CLI family, not a verified target.
---

<p class="eyebrow">Targets</p>

# Publishing Targets {#publishing-targets}

{{include includes/identity.md}}

{{include includes/publish-first.md}}

<Aside kind="info" id="registry">

Publication is a **registry**, not a shell recipe. The closed target names
today are `github-pages` and `standard-site`. Unknown names fail in the
profile parser. Nostr is a shipped CLI family (`boris nostr`), not a
third verified-target name.

</Aside>

## The default target is still a folder {#local-html}

```bash
./zig-out/bin/boris validate --quiet
./zig-out/bin/boris --quiet
```

That writes `dist/`. Open `dist/index.html`. Serve the directory with any
static host if you want the search UI to fetch its same-origin index.

Local HTML
: Always first. Inspectable. No credentials. No deployment claim.

`boris validate`
: The same prepublication path, then discard. Writes nothing.

`boris plan --profile PATH`
: Normalize the declared target. Does not discover content and does not
  publish.

A successful `dist/` is **not** a deployment claim. Evidence after a hosted
publish is a different chain.

## Which target, in which order {#which-target}

| Order | Target | When | First command |
| :---: | :--- | :--- | :--- |
| 1 | Local `dist/` | Always | `boris --quiet` |
| 2 | GitHub Pages | You want the first verified hosted target | Official Actions workflow |
| 3 | Standard.site | You mean Atmosphere records | `boris standard-site` |
| — | Nostr | You want NIP-23 events | [[guides/nostr-publication|plan → sign → publish]] |

<Aside kind="tip" id="first-time">

A first-time author stops at row 1 or row 2. Standard.site is a second
verified target for testers who already have a `dist/` they trust.

</Aside>

## GitHub Pages {#github-pages}

Pages is the **depth model**: location identity, inventory-only upload,
retained evidence, optional post-deploy observer.

Enable **Settings → Pages → GitHub Actions**. The official workflow lives
at `.github/workflows/github-pages.yml`. It resolves `base_url` / `origin` /
`base_path`, rejects contradictions (`EPUBLICATIONLOCATION`), and uploads
only `committed` inventory records.

| Pages shape | Example `base_url` | `base_path` |
| :--- | :--- | :--- |
| Project site | `https://owner.github.io/boris` | `/boris` |
| User/org root | `https://owner.github.io` | empty |
| Custom domain | `https://docs.example.com` | empty |

Operator path (repository docs, not this compiled page):
[GitHub Pages](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/github-pages.md).

<Details summary="What Pages does not claim">

A green workflow is not proof of accessibility, prose quality, or that a
search engine will crawl you. The optional deployment observer is a
bounded, separate contract. Local generation is not a live-site claim.

</Details>

## Standard.site / AT Protocol {#standard-site}

Atmosphere publication writes `site.standard.publication` and one
`site.standard.document` per eligible page. The static HTML site stays
canonical. This is an **explicit second step**.

| Path | Status |
| :--- | :--- |
| Offline `plan` / `records` / `verify` | Works. No network, no credentials. |
| App-password login + publish + smoke | Works against bsky.social. First-tester path. |
| Browser OAuth | Implemented. Requests granular `repo:` scopes; the live smoke verifies the grant. |

```text
boris standard-site plan    --profile profiles/standard-site.json
boris standard-site records --profile profiles/standard-site.json
boris --quiet
boris standard-site login --app-password --handle YOU.test.bsky.social
boris standard-site publish --profile profiles/standard-site.json --did did:plc:…
boris standard-site logout --did did:plc:…
```

<Aside kind="danger" id="app-password">

App passwords grant **broad account write**, not just Standard.site. Use a
dedicated, non-personal test identity. Never put the password on argv, in
the profile, in the environment, in git, or in evidence.

</Aside>

<Aside kind="warning" id="verify-emit">

Production HTML does **not** yet emit verification surfaces (head links +
well-known). `verify` against a real `dist/` fails closed until that emit
lands. Plan and publish do not wait on it.

</Aside>

Operator path:
[Standard.site](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/standard-site.md).

## Evidence after a publish {#evidence}

Hosted publication records a target-local chain. Each file is bound to the
one before it:

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

`boris --quiet` writes this evidence for the HTML target. That is
publication of files, not a claim that GitHub or a PDS served them. The
optional Pages observer is a separate, explicitly bounded contract.

</Details>

## What is not a target {#not-a-target}

Nostr NIP-23
: Shipped CLI. Stays off the verified-target registry on purpose:
  relays are not a host. See
  [[guides/nostr-publication|Nostr NIP-23 Publication]].

Cloudflare Pages / Vercel / Netlify
: Waiting or “never proactive.” Adapter-shaped. No recipe in this guide.

Cloudflare Containers / Wasm
: Compiler-shaped bets, not deployer adapters. The Wasm path has an
  example Worker host at
  [`hosts/cloudflare-worker/`](https://github.com/drawmeanelephant/boris/blob/afterparty/hosts/cloudflare-worker/README.md);
  the contract is
  [`docs/contracts/embedding.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/embedding.md).
  Containers have an official hosted-runner example (`boris-job-runner`)
  with the operator path in `docs/cloudflare-container.md`. Neither is a
  `publication.target`.

The editor
: An authoring surface. It can run `Build HTML`. It is not a publication
  target.

## Next steps

- [[getting-started|Getting Started]] — build the local site first
- [[guides/nostr-publication|Nostr NIP-23]] — plan → sign → publish
- [[guides/cli-and-modes|CLI & Output Modes]] — commands vs projections
- [[guides/editor|Boris Editor]] — compiler-backed authoring
- [[reference/outputs|Outputs & Artifacts]] — what lands under `dist/`
- [[reference/commands|Command Reference]] — flags and exit codes
