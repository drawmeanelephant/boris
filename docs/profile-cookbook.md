# Publication profile cookbook

**Status:** worked examples — **non-normative**. The normative grammar lives in
[contracts/publication-profile.md](contracts/publication-profile.md) (schema,
bounds, validation, execution boundaries) and
[contracts/head-metadata.md](contracts/head-metadata.md) (`head`,
`html_profile`, the bounded RSS rider). If this page and a contract disagree,
the contract wins.

Each block below is a complete `boris.json`, grown one axis at a time from the
starter that `boris init --type portfolio` writes. Check a declaration before
building with `boris plan --profile boris.json` (normalize + validate, no
outputs), then execute it with `boris build --profile boris.json`.

## Where the keys live

The profile is strict JSON: unknown keys at any object level are errors that
name the key and its path. Most first-edit refusals are placement errors, so
before the recipes:

- `site` is a **root** field with exactly `url`, `title`, and `description`.
  There is no `site_url` target key — declaring one fails with
  `unknown key "site_url" in targets[0]`.
- `sitemap`, `rss`, `llms`, `static`, `head`, `html_profile`, `theme`,
  `layout`, `layout_rules`, and `public` are **per-target** fields inside
  `targets[]`.
- `sitemap`, `rss`, and `llms` each require an explicit `path`:
  `"sitemap": {}` fails with
  `missing required field "path" in targets[0].sitemap`.
- A target that emits `sitemap`, `rss`, or `llms` must be `"public": true`.
- `head.base_url` is a field of `head`. When the same target also emits
  sitemap or RSS, it must equal `site.url` exactly, and when a `publication`
  location is declared it must equal that `base_url`.

## 1. Minimal

Exactly what `boris init --type portfolio` materializes: one public HTML
target under the showcase theme, no public artifacts.

```json
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "input_format": "markdown",
  "site": { "title": "Mara Lindqvist Studio" },
  "targets": [
    {
      "name": "public",
      "output": "dist",
      "public": true,
      "theme": "themes/showcase",
      "layout_rules": [
        { "selector": "id:index", "layout": "themes/showcase/layouts/home.html" }
      ]
    }
  ]
}
```

`boris build --profile boris.json` compiles `content/` into `dist/`. Every
`layout_rules` layout must live under the target's declared `theme` root — the
two are checked against each other.

## 2. + Sitemap

Two additions: the site URL moves under root `site`, and the target declares
where the sitemap is emitted.

```json
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "input_format": "markdown",
  "site": {
    "title": "Mara Lindqvist Studio",
    "url": "https://showcase.example.com/"
  },
  "targets": [
    {
      "name": "public",
      "output": "dist",
      "public": true,
      "theme": "themes/showcase",
      "layout_rules": [
        { "selector": "id:index", "layout": "themes/showcase/layouts/home.html" }
      ],
      "sitemap": { "path": "sitemap.xml" }
    }
  ]
}
```

The build now emits `dist/sitemap.xml` with `<loc>` URLs bound to `site.url`.
A sitemap declaration without `site.url` is refused at plan time
(`PublicArtifactRequiresSiteUrl`) — the profile cannot write URLs it does
not know — and the HTML coordinator currently executes sitemap only on a
**single-target** profile
([execution boundary](contracts/publication-profile.md#html-execution)). The
path is target-relative and feeds into the same namespace protections as the
CLI's `--sitemap-path` ([xml-sitemap contract](contracts/xml-sitemap.md)).

## 3. + RSS and head metadata

Profile RSS executes only through the bounded single-target rider: the target
needs an enabled `head` carrying its own `base_url`, and the site needs
`title` and `description` alongside `url`.

```json
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "input_format": "markdown",
  "site": {
    "title": "Mara Lindqvist Studio",
    "url": "https://showcase.example.com/",
    "description": "Wayfinding, print, and type for public places."
  },
  "targets": [
    {
      "name": "public",
      "output": "dist",
      "public": true,
      "theme": "themes/showcase",
      "layout_rules": [
        { "selector": "id:index", "layout": "themes/showcase/layouts/home.html" }
      ],
      "head": { "enabled": true, "base_url": "https://showcase.example.com/" },
      "rss": { "path": "feed.xml" },
      "sitemap": { "path": "sitemap.xml" }
    }
  ]
}
```

The build emits `dist/feed.xml` (pages carrying `published_at` + `summary`,
drafts excluded) and every eligible page head gains canonical, optional
description, and the feed's `rel="alternate"` autodiscovery link. Three
requirements bite here:

- `rss` without `"head": { "enabled": true, ... }` — or on a multi-target
  profile — exits 2 with `declares rss; this HTML coordinator does not
  execute feeds`. The rider is the only profile-RSS path
  ([head-metadata contract](contracts/head-metadata.md#bounded-rss-rider-and-execution-boundary)).
- `head.base_url` must equal `site.url` byte-for-byte after normalization
  (`HeadBaseMismatch` otherwise).
- Every selected layout needs exactly one `{{head}}` slot directly inside its
  `<head>`. All catalog themes ship it; a hand-authored layout without it
  fails `EHEAD`. Layout rules must stay inside the declared theme root.

## 4. + HTML 4.01 Strict output

Two **separate** switches: the theme supplies a conforming document, and the
profile field selects the output gate.

```json
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "input_format": "markdown",
  "site": { "title": "Mara Lindqvist Studio" },
  "targets": [
    {
      "name": "public",
      "output": "dist",
      "public": true,
      "theme": "themes/html4-strict",
      "html_profile": "html4_strict"
    }
  ]
}
```

- The profile token is `html4_strict` with an **underscore** — the same
  surface spelled `html4-strict` is the CLI `--target-profile` spelling
  (`NAME=html4-strict`); in JSON it fails with
  `invalid value "html4-strict" for field "html_profile" in targets[0]`.
- `html_profile` alone does not make layouts conform: every assembled page —
  including `layout_rules` selections — must pass the Strict gate, so switch
  the theme to `themes/html4-strict` (or another layout whose output
  validates). A Strict-incompatible layout fails with `EHTML4STRICT`, e.g. a
  missing HTML 4.01 Strict DOCTYPE
  ([html4-strict contract](contracts/html4-strict.md)).
- `init` only copies the archetype's own theme into the tree; copy the
  catalog's `themes/html4-strict/` directory into the site before selecting
  it. Rules referencing the old theme's layouts must be dropped or retargeted
  — every `layout_rules` layout has to live under the declared theme root.
- No `.html`/`.htm`/`.xhtml` passthrough assets are permitted on the target.

## The canonical example

`boris init --type newsletter` materializes a complete `site.url` + `head` +
`rss` + `sitemap` profile — the archetype contract in
[cli.md](contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification)
describes it as the worked composition, and its emitted `boris.json` is the
canonical copy to read. More runnable specimens:
[`docs/contracts/fixtures/head-metadata/profile.json`](contracts/fixtures/head-metadata/profile.json)
(head + RSS + sitemap + GitHub Pages publication) and the
[`publication-plan` fixture set](contracts/fixtures/publication-plan/)
(minimal, full, github-pages, standard-site) with their normalized expected
plans.
