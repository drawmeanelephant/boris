# Boris authoring spine

**Status:** teaching layer — **non-normative**. Every step links to a
normative contract instead of restating it; if this page and a contract seem
to disagree, the contract wins (see the [rules of use](contracts/README.md#rules-of-use)).

This is the shortest honest path from a blank directory to a published,
verified Boris site. Six steps, each about a screen of guidance, grounded in
the starter tree that `boris init` writes; step 7 then adds the Boris Editor,
the compiler-backed surface where steps 2–4 happen:

```
start → content & frontmatter → links & graph → layout → publish → verify
```

## 1. Start

```bash
boris init my-site      # writes the starter tree, then:
cd my-site
boris --quiet           # compiles content/ → dist/
```

`boris init [DIR]` writes a complete starter, not archaeology: `content/`
with an `index.md` trunk and two satellites
(`guides/getting-started.md`, `guides/publishing.md`), a working theme
(`themes/boris/` with `layouts/main.html` and `assets/css/boris.css`), and
a `boris.json` publication profile. Every page in the spine trail below is
already present in that tree.

- Contracts: [CLI routing](contracts/cli.md) · [publication profile](contracts/publication-profile.md)

## 2. Content & frontmatter

Authoring is Markdown plus a **closed frontmatter block** — exactly
`id`, `title`, `parent`, `status`, `tags`, `relations`, `published_at`, and
`summary`, nothing else. Unknown keys are hard errors, not warnings; that
closedness is what keeps your content machine-consumable.

The starter's `content/index.md` shows the shape (`title`, `parent`, `tags`,
`relations`). For schema-aware editing, the same grammar is published as
`boris-frontmatter-1.schema.json` — editors and agents can validate against
it without reading the parser.

- Contracts: [frontmatter grammar](contracts/frontmatter.md) ·
  [`boris-frontmatter-1.schema.json`](contracts/schemas/boris-frontmatter-1.schema.json)

## 3. Links & graph

Pages are nodes in a validated graph, not loose files:

- `parent: <id>` builds the Trunk/Satellite hierarchy and navigation;
- `[[entity-id]]` wiki-links and `{{include}}` transclusions are checked
  against the frozen graph before anything is written;
- broken parents, links, headings, includes, and cycles fail with
  actionable diagnostics (`EPARENTMISSING`, `EREFERENCEMISSING`, …) instead
  of quietly producing a broken site.

The starter's `publishing.md` links `[[guides/getting-started]]` and
declares a `relations` edge so the graph has something to inspect.

- Contracts: [identity & paths](contracts/identity-and-paths.md) ·
  [IR graph & Trunk/Satellite](contracts/ir-schema.md) ·
  [includes & wiki-links](contracts/includes-and-wiki-links.md) ·
  [graph-backed markdown links](contracts/documentation-links.md) ·
  [diagnostics](contracts/diagnostics.md)

## 4. Layout

A theme is local HTML + assets, shaped by the **closed layout vocabulary**:
ten slots (`{{content}}`, `{{title}}`, `{{nav}}`, `{{breadcrumb}}`,
`{{toc}}`, `{{children}}`, `{{metadata}}`, `{{relations}}`,
`{{backlinks}}`, `{{footer}}`) plus the repeatable `{{asset-url}}` helper.
The starter's `themes/boris/layouts/main.html` is the working example.

Schema-aware themes: the completion index's `layout_slots` enum
(`boris-completion-1.schema.json`) is the machine-readable closed slot set.

- Contracts: [templating & themes](contracts/templating-and-themes.md) ·
  [content-local assets](contracts/content-local-assets.md) ·
  [`boris-completion-1.schema.json`](contracts/schemas/boris-completion-1.schema.json)

## 5. Publish

Publishing is profile → normalized plan → location validation, not a shell
recipe. `boris.json` declares one public target; `boris plan --profile
boris.json` shows the normalized declaration before anything is published.

For a hosted site, the deployment URL is publication truth: `base_url`,
`origin`, and `base_path` must agree or the build fails closed
(`EPUBLICATIONLOCATION`). The official GitHub Pages workflow implements the
full verified target — resolve the location, validate every URL projection
against it, upload only inventory-verified files.

Atmosphere publication is a separate, explicit family (`boris standard-site`).
It does not replace the HTML site. First testers on bsky.social should use
the app-password path in [Standard.site](standard-site.md), not browser OAuth.

- Contracts: [publication profile](contracts/publication-profile.md) ·
  [publication plan](contracts/publication-plan.md) ·
  [GitHub Pages](github-pages.md) ·
  [Standard.site](standard-site.md) ·
  [publication platform model](contracts/publication-platforms.md)

## 6. Verify

Verification is a chain, each layer bound to the one before it:

- `boris validate` — authoritative preflight, no output written;
- `boris check` / `boris impact` — graph health and dependency impact;
- after a publish, the target-local evidence chain records exactly what was
  committed (`artifacts.json` → `checks.json` → `claims.json` →
  `touches.json` → `proof-pack.json`), and the optional deployment audit
  observes the live site against that evidence.

A successful build is not a deployment claim; the audit step is what (optionally)
binds the deployed site back to the committed inventory.

- Contracts: [validation](contracts/validation.md) ·
  [documentation intelligence](contracts/documentation-intelligence.md) ·
  [artifact inventory](contracts/publication-artifacts.md) ·
  [checks](contracts/publication-checks.md) · [claims](contracts/publication-claims.md) ·
  [Touch Atlas](contracts/publication-touches.md) · [Proof Pack](contracts/publication-proof-pack.md) ·
  [deployment evidence](contracts/github-pages-deployment-evidence.md)

## 7. Edit with the Boris Editor

The Boris Editor is a local, browser-served authoring surface for the trail
above. It is an interaction layer only: Boris stays the sole parser, graph,
validation, completion, rendering, and publication authority, and Oliver
stays the markup authority.

- **Schema- and graph-aware completion** — the frontmatter schema
  (`boris-frontmatter-1.schema.json`) completes step 2's keys and enums; a
  successful IR build's `completion.json` completes step 3's entity ids,
  wiki-links, parents, and relations, and step 4's layout slots. Insertion is
  explicit and undoable, never a typing-time rewrite.
- **Compiler-backed commands and problems** — a fixed allowlist wraps the
  step 3 and step 6 commands (`validate`, IR build, HTML build, `check`,
  `impact`). Problems group by source, severity, and code; navigate to exact
  UTF-8 positions; and copy metadata-only diagnostic packets. Exits 1, 2,
  and 3 stay distinct.
- **Live preview** — one fixed rebuild
  (`boris build --input content --incremental --html-dir dist`) serves the
  committed `dist/` tree byte-for-byte, preserving the last good output after
  a failed rebuild.

Saving is explicit and never automatic: the editor writes nothing to your
repository without a save. See the guide for the launch command and the full
surface:

- [Boris Editor: compiler-backed authoring](../content/guides/editor.md)

## Schema-aware authoring

Two published schemas are the machine twins of the spine's closed
vocabularies, for editors, agents, and CI:

| Step | Closed vocabulary | Machine twin |
|---|---|---|
| 2 — frontmatter | the eight keys | [`boris-frontmatter-1.schema.json`](contracts/schemas/boris-frontmatter-1.schema.json) |
| 3 & 4 — graph and layout | entity ids, parent targets, relation kinds, layout slots | `completion.json` ([`boris-completion-1.schema.json`](contracts/schemas/boris-completion-1.schema.json)) |

`completion.json` is emitted alongside the IR artifact set on a successful
freeze, so an editor can offer schema-aware completion without re-deriving
the vocabulary from prose.

## Acceptance trail

The newcomer path this spine guarantees:

1. `boris init my-site` and `cd my-site`
2. Write one page with closed frontmatter (step 2) and one wiki-link (step 3)
3. `boris --quiet` — the site builds or fails with an actionable diagnostic
4. Edit the starter layout's slots (step 4) and rebuild
5. `boris plan --profile boris.json`, then publish via the GitHub Pages
   workflow (step 5)
6. `boris validate` before and `boris check` after (step 6)

Nothing in that path requires reading a compiler module. The contracts
remain the source of truth; this spine only orders the trail through them.
