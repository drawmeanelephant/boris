//! `boris init`: materialize a deterministic starter site and prove it compiles.
//!
//! `boris init [DIR] [--type NAME]` writes a fixed starter tree selected by
//! `--type` (default `docs`, byte-identical to the historical starter):
//!
//! - `docs`     — Markdown documentation tree: trunk/satellite graph, wiki
//!   links, a semantic relation, a starter theme with a wired browser
//!   search client, and both publication profiles.
//! - `garden`  — a flat-ish digital garden: dense `[[wiki-links]]`,
//!   semantic relations, `{{include}}` composition from `content/includes/`,
//!   and a registered `<Aside>` component, under the shipped `ledger` theme.
//! - `cookbook` — a `.cook` Cooklang recipe box (ingredients, cookware,
//!   timers, sub-recipe references, `servings`) under `cards`, whose
//!   profile declares `input_format: cook`; `layout_rules` send `id:index`
//!   to `home.html`, whose `{{children}}` deck shows each recipe as a card.
//! - `blog`    — dated posts on a parent chain (`index` → `posts` → dated
//!   entries with `published_at` + `summary`) under the `cozy` theme.
//! - `textile` — `.textile` pages through the native adapter under `press`,
//!   whose profile declares `input_format: textile`.
//! - `landing` — a single-Trunk page composed from `{{include}}` section
//!   fragments, plus one satellite, under `service`; the profile's
//!   `layout_rules` send `id:index` to the theme's `home.html`.
//! - `wiki`    — a three-level reference tree (`index` → section hubs →
//!   leaf entries) with cross-entry wiki links under `reference`;
//!   `layout_rules` send `id:index` to `home.html` and `glob:wiki/*` hubs
//!   to `section.html`, so `{{breadcrumb}}` and `{{toc}}` do real work.
//! - `link-in-bio` — the smallest honest site: one trunk page holding a
//!   personal link list, under `minimal`.
//! - `changelog` — release notes (`index` → `changes` hub → dated entries
//!   with `published_at` + `summary`) under `journal`; one entry is
//!   `status: draft`, the unreleased section that renders unadvertised.
//!   `layout_rules` send `id:changes` to `archive.html`, whose
//!   `{{children}}` listing names the published releases.
//! - `resume`  — a single-page CV with `tags` for `{{metadata}}` and one
//!   "now" satellite under `corporate`, whose print stylesheet is the PDF.
//! - `newsletter` — a weekly paper (`index` → `issues` hub → dated issues)
//!   under `press`; `layout_rules` route the masthead, archive, and issues
//!   to press's named layouts, and the profile's target enables `head` and
//!   declares `rss` plus `sitemap`, so the first build ships `feed.xml`
//!   with autodiscovery links in every issue's head.
//! - `portfolio` — a studio front (`index`, an `about` satellite, three
//!   dated `projects/` satellites) under `showcase`; `layout_rules` send
//!   `id:index` to `home.html`, whose `{{children}}` lists the work, and
//!   every other page uses `main.html`.
//! - `archive` — a long-lived archive under `archive`: four tagged
//!   entries joined by `relates_to` / `supersedes` relations (so entries
//!   render `{{relations}}` and `{{backlinks}}`), one `status: archived`
//!   record, and a hand-kept `topics` index by tag; `layout_rules` send
//!   `id:index` to `archive.html`.
//! - `dashboard` — a project-status board under `engineering`: the trunk
//!   board table and three `projects/` satellites, one per `status:` value
//!   (`published` = active, `draft` = proposed, `archived` = retired, the
//!   mapping documented on the board), with `depends_on` / `supersedes`
//!   relations and status-history tables; `layout_rules` send `id:index`
//!   to `home.html`.
//! - `photo-gallery` — a trunk front page and two `photos/` album
//!   satellites under `gallery`, each page carrying small PNG plates in its
//!   own `{stem}.assets/` folder inside `<figure>` captions; `layout_rules`
//!   send `id:index` to `home.html`, whose `{{children}}` is the album grid.
//!   The images are content, so they embed from `src/init_templates/`.
//!
//! Type selection lives entirely in this file's archetype table — the
//! compiler gains no per-archetype branches. Each archetype's `boris.json`
//! declares its own `input_format` and theme, so `boris --profile
//! boris.json` builds the materialized tree through the normal
//! profile-driven path.
//!
//! After materializing, `init` compiles the fresh tree into a probe output
//! directory and deletes it again. Exit 0 therefore means "materialized AND
//! compiled": agents and scripts can assert the stronger postcondition, and
//! a starter that ever stops compiling fails loudly instead of shipping.
//!
//! Every tree is byte-deterministic: all files are fixed constants (theme
//! bytes are embedded straight from `themes/` via the
//! `init_archetype_themes` module, which roots there because `@embedFile`
//! cannot cross the `src/` package boundary). Two runs in identical
//! conditions produce identical trees. `init` refuses to touch an existing
//! non-empty directory — no archaeology, and no silent clobbering.

const std = @import("std");
const compile = @import("compile.zig");
const diagnostic = @import("diagnostic.zig");
const identity = @import("identity.zig");
const archetype_themes = @import("init_archetype_themes");
const Io = std.Io;

const ExitCode = diagnostic.ExitCode;

/// Starter archetypes accepted by `--type`. `docs` is the default and
/// writes the same bytes `init` has always written.
pub const Archetype = enum { docs, garden, cookbook, blog, textile, landing, wiki, @"link-in-bio", changelog, @"resume", newsletter, portfolio, archive, dashboard, @"photo-gallery" };

/// Comptime-joined `docs, garden, cookbook, …` for diagnostics and help
/// text — the table below is the single source of truth.
pub const archetype_names: []const u8 = blk: {
    var names: []const u8 = "";
    for (@typeInfo(Archetype).@"enum".field_names, 0..) |name, i| {
        names = names ++ (if (i == 0) "" else ", ") ++ name;
    }
    break :blk names;
};

const starter_layout = @embedFile("init_templates/layouts/main.html");
const starter_css = @embedFile("init_templates/assets/css/boris.css");

// --- docs (default; the historical starter, unchanged) ----------------------

const index_md =
    \\---
    \\title: My Boris Site
    \\tags: [home]
    \\---
    \\
    \\# Welcome
    \\
    \\This is a fresh [Boris](https://github.com/drawmeanelephant/boris)
    \\documentation site. It already has a page graph: this trunk page,
    \\two guides beneath it, wiki links between them, and one semantic
    \\relation.
    \\
    \\Start here:
    \\
    \\- [[guides/getting-started]] — add your own pages and watch the graph grow.
    \\- [[guides/publishing]] — turn the site into a verified publication.
    \\
    \\## Anatomy of this starter
    \\
    \\The tree `boris init` created:
    \\
    \\```text
    \\content/
    \\  index.md                    trunk page (this one)
    \\  guides/getting-started.md   satellite, parent: index
    \\  guides/publishing.md        satellite, parent: index
    \\themes/boris/                 starter theme (closed layout slots, search UI)
    \\boris.json                    publication profile (GitHub Pages)
    \\standard-site.json            Atmosphere profile (edit the fake DID/URL)
    \\```
    \\
    \\Search is wired up: the compiler publishes
    \\`dist/_boris/search/search-index.json` and this theme ships the
    \\no-dependency browser client that queries it. Press `/` on any page.
    \\
;

const getting_started_md =
    \\---
    \\title: Getting Started
    \\parent: index
    \\tags: [guides]
    \\---
    \\
    \\# Getting Started
    \\
    \\A page is one Markdown file with YAML frontmatter. The frontmatter
    \\`id` is derived from the path unless you write one; `title`, `tags`,
    \\and `parent` shape the graph.
    \\
    \\## Add a page
    \\
    \\Create `content/guides/example.md`:
    \\
    \\```markdown
    \\---
    \\title: Example
    \\parent: index
    \\tags: [guides]
    \\---
    \\
    \\# Example
    \\
    \\Hello from [[index]].
    \\```
    \\
    \\Rebuild with `boris --input content --html-dir dist --theme themes/boris`
    \\and the page appears in the nav forest, the breadcrumb chain, and the
    \\frozen graph.
    \\
    \\## Frontmatter at a glance
    \\
    \\- `title` — page title (`{{title}}`, search, and metadata).
    \\- `parent` — entity id of the structural parent (this page lives under
    \\  `index`).
    \\- `tags` — free-form list rendered into page metadata.
    \\- `relations` — semantic edges such as `[relates_to=target]`; see
    \\  [semantic relations](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/semantic-relations.md).
    \\
    \\A wiki link `[[getting-started]]` is a real graph edge: a link to a
    \\missing page fails the build instead of rendering as dead prose.
    \\
;

const publishing_md =
    \\---
    \\title: Publishing
    \\parent: index
    \\tags: [guides]
    \\relations: [relates_to=guides/getting-started]
    \\---
    \\
    \\# Publishing
    \\
    \\Boris treats the deployment URL as publication truth, not an incidental
    \\detail. The starter profile declares one public HTML target:
    \\
    \\```json
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/boris" }
    \\  ]
    \\}
    \\```
    \\
    \\Inspect the normalized plan before publishing:
    \\
    \\```text
    \\boris plan --profile boris.json
    \\boris standard-site plan --profile standard-site.json
    \\```
    \\
    \\The official GitHub Pages workflow (see the repository's
    \\`docs/github-pages.md`) builds a verified target: it resolves the Pages
    \\location from `actions/configure-pages`, fails on any URL projection
    \\that disagrees with it, uploads only inventory-verified files, and
    \\retains a separate evidence artifact. Atmosphere publication uses
    \\`standard-site.json`: replace the obviously-fake DID and URL
    \\before `standard-site publish`. This starter page is related to
    \\[[guides/getting-started]] so the semantic graph has an edge to inspect.
    \\
;

const starter_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "site": { "title": "My Boris Site" },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/boris" }
    \\  ]
    \\}
    \\
;

/// Obviously fake Atmosphere identity. The DID is syntactically valid
/// `did:plc` (24 `a`s) and the URL is not a real public site. Testers must
/// replace both. `pds` is omitted: publish binds to the discovered PDS.
const standard_site_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "site": { "title": "My Boris Site" },
    \\  "publication": {
    \\    "target": "standard-site",
    \\    "base_url": "https://replace-me.example.com/",
    \\    "origin": "https://replace-me.example.com/",
    \\    "base_path": "",
    \\    "did": "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
    \\    "name": "My Boris Site",
    \\    "show_in_discover": false,
    \\    "prune": false
    \\  },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/boris" }
    \\  ]
    \\}
    \\
;

// --- garden -----------------------------------------------------------------

const garden_index_md =
    \\---
    \\title: Seedling Garden
    \\tags: [garden]
    \\---
    \\
    \\# Seedling Garden
    \\
    \\A digital garden is a pile of notes that link to each other. This
    \\starter is flat on purpose: every note declares `parent: index`, and
    \\the meaning lives in wiki links and semantic relations instead of
    \\folders.
    \\
    \\Wander:
    \\
    \\- [[notes/digital-garden]] — what this shape is for.
    \\- [[notes/wiki-links]] — how a wiki link becomes a validated edge.
    \\- [[notes/composition]] — compose one page from `{{include}}` fragments.
    \\- [[notes/semantic-relations]] — typed edges such as `relates_to`.
    \\
    \\<Aside kind="tip" id="garden-0">
    \\
    \\Every `[[link]]` is checked at build time: a link to a missing page
    \\fails the build instead of rotting into dead prose.
    \\
    \\</Aside>
    \\
;

const garden_digital_garden_md =
    \\---
    \\title: Digital Gardens
    \\parent: index
    \\tags: [garden, notes]
    \\relations: [relates_to=notes/wiki-links]
    \\---
    \\
    \\# Digital Gardens
    \\
    \\Gardens trade chronology for connection. Notes such as
    \\[[notes/wiki-links]] and [[notes/composition]] accrete edges over
    \\time; `boris check` reports the graph's health and
    \\`boris impact notes/wiki-links` shows what breaks when a note moves.
    \\
    \\The graph is flat-ish by choice — every note is a satellite of
    \\[[index]] — because the structure that matters is the link web, not
    \\the tree. [[notes/semantic-relations]] adds the typed edges.
    \\
;

const garden_wiki_links_md =
    \\---
    \\title: Wiki Links
    \\parent: index
    \\tags: [garden, notes]
    \\---
    \\
    \\# Wiki Links
    \\
    \\Write `[[entity-id]]` and Boris rewrites it to the target's output
    \\path, with an optional `[[entity-id|display label]]` or
    \\`[[entity-id#heading-id]]` fragment. Every link is a real edge in the
    \\frozen graph — see [[notes/semantic-relations]] for the typed cousins.
    \\
    \\Try it: this note links back to [[notes/digital-garden]] and forward
    \\to [[notes/composition]].
    \\
;

const garden_semantic_relations_md =
    \\---
    \\title: Semantic Relations
    \\parent: index
    \\tags: [garden, notes]
    \\relations: [implements=notes/wiki-links, relates_to=notes/digital-garden]
    \\---
    \\
    \\# Semantic Relations
    \\
    \\Frontmatter `relations` declares typed, directional edges —
    \\`relates_to`, `implements`, `depends_on`, `supersedes` — validated
    \\against the frozen graph and rendered by the theme's `{{relations}}`
    \\and `{{backlinks}}` slots. This page claims it *implements*
    \\[[notes/wiki-links]]; the ledger theme prints both directions.
    \\
;

const garden_composition_md =
    \\---
    \\title: Composition with Includes
    \\parent: index
    \\tags: [garden, notes]
    \\relations: [depends_on=notes/wiki-links]
    \\---
    \\
    \\# Composition with Includes
    \\
    \\A page can be assembled from fragments: the `{{include}}` directive
    \\below splices `content/includes/house-style.md` into this page at
    \\build time. Fragments under `content/includes/` are never discovered
    \\as pages, so they never surface in `boris check` as
    \\`unreferenced_page` findings — they exist only inside the pages that
    \\include them.
    \\
    \\{{include includes/house-style.md}}
    \\
    \\The next section is a fragment too, and its links still count:
    \\wiki links authored inside an include are graph edges of the page
    \\that includes them.
    \\
    \\{{include includes/link-roll.md}}
    \\
;

const garden_house_style_md =
    \\## House Style
    \\
    \\Shared prose lives in `content/includes/` and is spliced in verbatim:
    \\same Markdown, same heading ids, same validation. A fragment has no
    \\page of its own — it exists only inside pages that include it, like
    \\[[notes/composition]].
    \\
;

const garden_link_roll_md =
    \\## Link Roll
    \\
    \\- [[notes/digital-garden]] — the garden idea itself.
    \\- [[index]] — back to the front door.
    \\
;

const garden_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Seedling Garden" },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/ledger" }
    \\  ]
    \\}
    \\
;

// --- cookbook ---------------------------------------------------------------

const cookbook_index_cook =
    \\---
    \\title: Recipe Box
    \\---
    \\
    \\-- Every page in this starter is a `.cook` Cooklang source. The
    \\-- publication profile boris.json declares "input_format": "cook", so
    \\-- a plain `boris --profile boris.json` build (or --cooklang on the
    \\-- CLI) runs the native adapter; there is no per-site switch in the
    \\-- compiler. Lines like this one are comments and never render.
    \\--
    \\-- The profile's layout_rules render this page through the cards
    \\-- theme's home.html: every recipe declares parent: index, so the
    \\-- "In this collection" deck under the menu lists each one as a card.
    \\
    \\Tonight's menu: @./mains/carbonara{1} finished with
    \\@./sauces/pepper-oil{1%tbsp}.
    \\
    \\Tomorrow's breakfast: @./mains/pancakes{1}.
    \\
    \\> Scale any recipe without rewriting its source: boris recipe-scale --cooklang --id mains/carbonara --servings 4
    \\
;

const cookbook_carbonara_cook =
    \\---
    \\title: Spaghetti Carbonara
    \\parent: index
    \\tags: [pasta, quick]
    \\relations: [depends_on=sauces/pepper-oil]
    \\servings: 2
    \\---
    \\
    \\-- The classic: eggs, pecorino, guanciale, pepper. No cream.
    \\
    \\= Preparation
    \\
    \\Bring a #large pot{} of salted water to the boil and add @spaghetti{400%g}.
    \\
    \\Beat @eggs{3} with @pecorino{60%g} and @black pepper{} in a #bowl.
    \\
    \\== Cooking ==
    \\
    \\Fry @guanciale{150%g}(cut into strips) in a #frying pan{} for ~{5%minutes}.
    \\
    \\Cook the pasta for ~pasta{9%minutes}, then drain it, [- keep a cup of water -]
    \\reserving @pasta water{1%cup}.
    \\
    \\Combine everything off the heat so the egg thickens without scrambling.\
    \\Serve immediately with @./sauces/pepper-oil{1%tbsp}.
    \\
    \\> Off the heat is the whole trick: carbonara is emulsified, never cooked.
    \\
;

const cookbook_pancakes_cook =
    \\---
    \\title: Weekday Pancakes
    \\parent: index
    \\tags: [breakfast]
    \\servings: 4
    \\---
    \\
    \\= Batter
    \\
    \\Whisk @flour{250%g}, @sugar{2%tbsp}, @baking powder{2%tsp}, and
    \\@salt{1%tsp} in a #large bowl{}.
    \\
    \\Whisk in @milk{300%ml}, @eggs{2}, and @melted butter{40%g} until just
    \\combined.
    \\
    \\== Cooking ==
    \\
    \\Pour ladles of batter onto a hot, buttered #frying pan{} and cook
    \\~{2%minutes} per side.
    \\
    \\> Feeding a crowd without arithmetic: boris recipe-scale --cooklang --id mains/pancakes --servings 8
    \\
;

const cookbook_pepper_oil_cook =
    \\---
    \\title: Pepper Oil
    \\parent: index
    \\tags: [sauce]
    \\relations: [relates_to=mains/carbonara]
    \\servings: 8
    \\---
    \\
    \\Warm @olive oil{120%ml} with @cracked black pepper{2%tsp} in a
    \\#small saucepan{} over low heat for ~{10%minutes} — never let it smoke.
    \\
    \\Cool, then keep in a #sealed jar{} for up to a week.
    \\
;

const cookbook_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "cook",
    \\  "site": { "title": "Recipe Box" },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/cards",
    \\      "layout_rules": [
    \\        { "selector": "id:index", "layout": "themes/cards/layouts/home.html" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

// --- blog -------------------------------------------------------------------

const blog_index_md =
    \\---
    \\title: The Corner
    \\tags: [home]
    \\---
    \\
    \\# The Corner
    \\
    \\A small personal site in the mid-2000s style: an [[about]] page and
    \\dated posts under [[posts]]. Every post declares `parent: posts` plus
    \\`published_at` and `summary`, so the chain `index` → `posts` → post
    \\is the graph shape Boris calls trunk, satellite, satellite.
    \\
    \\Latest entry: [[posts/2026-10-05-why-i-write]].
    \\
;

const blog_about_md =
    \\---
    \\title: About
    \\parent: index
    \\tags: [meta]
    \\---
    \\
    \\# About
    \\
    \\This site runs on [Boris](https://github.com/drawmeanelephant/boris):
    \\Markdown in, a validated page graph, static HTML out. It was
    \\materialized by `boris init --type blog` and builds with
    \\`boris --profile boris.json`.
    \\
    \\Back to [[index]], or read the [[posts]] archive.
    \\
;

const blog_posts_md =
    \\---
    \\title: Posts
    \\parent: index
    \\tags: [posts]
    \\---
    \\
    \\# Posts
    \\
    \\Every entry is a satellite of this page; this page is a satellite of
    \\[[index]]. Newest first:
    \\
    \\- [[posts/2026-10-05-why-i-write]]
    \\- [[posts/2026-09-21-week-notes]]
    \\- [[posts/2026-09-14-first-post]]
    \\
;

const blog_post_first_md =
    \\---
    \\title: First Post
    \\parent: posts
    \\published_at: 2026-09-14T09:00:00Z
    \\summary: Where this site starts, and what it is for.
    \\tags: [meta]
    \\---
    \\
    \\# First Post
    \\
    \\A dated post is a Markdown page like any other; `published_at` and
    \\`summary` in the frontmatter are what make it a post. The parent
    \\chain puts it under [[posts]], which sits under [[index]] — the
    \\breadcrumb and navigation are generated from that graph, not from
    \\the folder names.
    \\
    \\Next: [[posts/2026-09-21-week-notes]].
    \\
;

const blog_post_week_notes_md =
    \\---
    \\title: Week Notes, № 1
    \\parent: posts
    \\published_at: 2026-09-21T18:30:00Z
    \\summary: Notes on tidying the corner and picking fonts.
    \\tags: [weeknotes]
    \\relations: [relates_to=posts/2026-09-14-first-post]
    \\---
    \\
    \\# Week Notes, № 1
    \\
    \\A rhythm of small dated entries is all a blog needs. This one relates
    \\back to [[posts/2026-09-14-first-post]] — both through the wiki link
    \\and through a `relates_to` semantic relation in the frontmatter —
    \\and forward to [[posts/2026-10-05-why-i-write]].
    \\
    \\<Aside kind="note" id="weeknotes-1">
    \\
    \\`status: draft` keeps a post out of search, feeds, and publication
    \\projections while it still renders in the default HTML target.
    \\
    \\</Aside>
    \\
;

const blog_post_why_i_write_md =
    \\---
    \\title: Why I Write
    \\parent: posts
    \\published_at: 2026-10-05T08:15:00Z
    \\summary: A short argument for keeping a public notebook.
    \\tags: [essay]
    \\---
    \\
    \\# Why I Write
    \\
    \\Because the archive compounds. A post like this one needs only a date
    \\and a summary; the compiler handles the rest of the furniture. See
    \\[[posts]] for the full list, or [[about]] for who is talking.
    \\
;

const blog_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "The Corner" },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/cozy" }
    \\  ]
    \\}
    \\
;

// --- textile ----------------------------------------------------------------

const textile_index_textile =
    \\---
    \\title: The Compositor
    \\tags: [textile]
    \\---
    \\h1. The Compositor
    \\
    \\This site is authored in "Textile":https://textile-lang.com/, Dean
    \\Allen's humane markup. Boris adapts it natively into the same graph
    \\every input family gets: frontmatter, parents, relations, validation,
    \\and one compiled site.
    \\
    \\Two dispatches:
    \\
    \\* "Why Textile":./dispatches/why-textile.html
    \\* "Migration notes":./dispatches/migration-notes.html
    \\
;

const textile_why_textile_textile =
    \\---
    \\title: Why Textile
    \\parent: index
    \\tags: [textile, history]
    \\---
    \\h1. Why Textile
    \\
    \\Textile was written for writers: *strong*, _emphasis_,
    \\@inline code@, and "named links":https://textile-lang.com/ that stay
    \\readable in the source. Boris accepts the closed subset documented in
    \\its Textile compatibility contract and fails loudly on the rest — no
    \\silent dialects.
    \\
    \\bq. A small language can leave a long shadow.
    \\
    \\Head back to "the front page":../index.html or sideways to
    \\"migration notes":./migration-notes.html.
    \\
;

const textile_migration_notes_textile =
    \\---
    \\title: Migration Notes
    \\parent: index
    \\tags: [textile]
    \\relations: [relates_to=dispatches/why-textile]
    \\---
    \\h1. Migration Notes
    \\
    \\The adapter is a migration surface as much as an authoring one: a
    \\legacy @.textile@ tree can be pointed at Boris as-is. Frontmatter is
    \\the same bounded grammar every Boris page uses — @id@, @parent@,
    \\@tags@, @relations@, @published_at@ — while the body stays Textile.
    \\
    \\* Flat bullet lists
    \\* keep notes skimmable
    \\
    \\Back to "the index":../index.html.
    \\
;

const textile_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "textile",
    \\  "site": { "title": "The Compositor" },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/press" }
    \\  ]
    \\}
    \\
;

// --- landing ----------------------------------------------------------------

const landing_index_md =
    \\---
    \\title: Fieldstone Cycle Repair
    \\tags: [home]
    \\---
    \\
    \\# Fieldstone Cycle Repair
    \\
    \\Honest repairs for everyday bikes, done the same week. Bring it in, get a
    \\ticket, ride it home tuned.
    \\
    \\**Next step:** read [[about]] to see how this one-page site is put
    \\together, then replace this prose with your own pitch.
    \\
    \\{{include includes/services.md}}
    \\
    \\{{include includes/faq.md}}
    \\
    \\{{include includes/visit.md}}
    \\
;

const landing_about_md =
    \\---
    \\title: About
    \\parent: index
    \\tags: [about]
    \\---
    \\
    \\# About
    \\
    \\A landing site is a legitimate Boris graph: one trunk page, [[index]],
    \\and only as many satellites as the story needs. This page is the one
    \\satellite, so the navigation and breadcrumb have something to show.
    \\
    \\## How this starter is wired
    \\
    \\- `content/index.md` is the long page. Its sections come from
    \\  `content/includes/*.md` through `{{include}}` directives, so each
    \\  section stays a small file you can edit on its own.
    \\- `boris.json` declares one `layout_rules` entry that sends `id:index`
    \\  to `themes/service/layouts/home.html`. Every other page, including
    \\  this one, falls back to the theme's `main.html`.
    \\
;

const landing_services_md =
    \\## What we do
    \\
    \\- **Tune-ups** — brakes, gears, and bearings, back the same week.
    \\- **Wheel builds** — hand-laced and trued on the stand.
    \\- **Fittings** — saddle, bar, and cleat set-up for long days out.
    \\
;

const landing_faq_md =
    \\## Questions
    \\
    \\### Do I need an appointment?
    \\
    \\No. Drop in during opening hours; bigger jobs get a ticket and a date.
    \\
    \\### How is this page built?
    \\
    \\From fragments. Each section of the front page is a file under
    \\`content/includes/`, spliced into [[index]] by an `{{include}}`
    \\directive. Fragments never compile as pages of their own.
    \\
;

const landing_visit_md =
    \\## Visit
    \\
    \\Open Tuesday to Saturday, 9:00–17:30. The story behind the shop is on
    \\the [[about]] page.
    \\
;

const landing_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Fieldstone Cycle Repair" },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/service",
    \\      "layout_rules": [
    \\        { "selector": "id:index", "layout": "themes/service/layouts/home.html" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

// --- wiki -------------------------------------------------------------------

const wiki_index_md =
    \\---
    \\title: Workshop Wiki
    \\tags: [wiki]
    \\---
    \\
    \\# Workshop Wiki
    \\
    \\A reference wiki three levels deep: this trunk page, two section hubs,
    \\and leaf entries under each hub. Every entry's breadcrumb walks the whole
    \\chain, and every `[[link]]` between entries is a validated graph edge.
    \\
    \\## Sections
    \\
    \\- [[wiki/tools]] — what is on the bench.
    \\- [[wiki/techniques]] — what you do with it.
    \\
    \\## Start anywhere
    \\
    \\[[wiki/techniques/sharpening]] is the entry most others point at.
    \\
;

const wiki_tools_md =
    \\---
    \\title: Tools
    \\parent: index
    \\tags: [wiki, tools]
    \\---
    \\
    \\# Tools
    \\
    \\A hub page: it declares `parent: index`, and every tool entry declares
    \\`parent: wiki/tools`. The profile sends hubs to the theme's
    \\`section.html` layout, whose `{{children}}` slot lists the entries
    \\without a hand-kept index.
    \\
    \\- [[wiki/tools/chisels]] — paring and chopping.
    \\- [[wiki/tools/hand-planes]] — flattening and smoothing.
    \\
;

const wiki_techniques_md =
    \\---
    \\title: Techniques
    \\parent: index
    \\tags: [wiki, techniques]
    \\---
    \\
    \\# Techniques
    \\
    \\The second hub. Entries here link sideways into [[wiki/tools]], so the
    \\graph is a web across sections, not just a tree.
    \\
    \\- [[wiki/techniques/sharpening]] — the skill every tool depends on.
    \\- [[wiki/techniques/dovetails]] — the joint everyone wants to cut.
    \\
;

const wiki_chisels_md =
    \\---
    \\title: Chisels
    \\parent: wiki/tools
    \\tags: [tools]
    \\---
    \\
    \\# Chisels
    \\
    \\A bench chisel pares; a mortise chisel levers. Both only work sharp —
    \\see [[wiki/techniques/sharpening]].
    \\
    \\## Bench chisels
    \\
    \\Bevel-edged, 6–25 mm, for paring to a line and for cleaning out the
    \\waste in [[wiki/techniques/dovetails]].
    \\
    \\## Mortise chisels
    \\
    \\Thick and square-sided, struck with a mallet, levered against the
    \\mortise walls.
    \\
    \\## Care
    \\
    \\Keep the backs flat and the edges covered in the tool roll.
    \\
;

const wiki_hand_planes_md =
    \\---
    \\title: Hand Planes
    \\parent: wiki/tools
    \\tags: [tools]
    \\---
    \\
    \\# Hand Planes
    \\
    \\A plane is a chisel held at a fixed angle in a body. The iron is sharpened
    \\exactly like a chisel: [[wiki/techniques/sharpening]].
    \\
    \\## Jack plane
    \\
    \\The first plane: removes stock fast and flattens rough boards.
    \\
    \\## Smoothing plane
    \\
    \\Takes the last gossamer shavings before finish.
    \\
    \\## Setting the iron
    \\
    \\Advance the iron until it just bites, then take test shavings on scrap.
    \\
;

const wiki_sharpening_md =
    \\---
    \\title: Sharpening
    \\parent: wiki/techniques
    \\tags: [techniques]
    \\relations: [relates_to=wiki/tools/chisels]
    \\---
    \\
    \\# Sharpening
    \\
    \\Every edge tool in [[wiki/tools]] dulls. Sharpening is three steps, and
    \\the same for [[wiki/tools/chisels]] and [[wiki/tools/hand-planes]].
    \\
    \\## Grind
    \\
    \\Restore the primary bevel on a coarse stone only when the edge is chipped.
    \\
    \\## Hone
    \\
    \\Raise a burr with a fine stone at the secondary bevel angle.
    \\
    \\## Strop
    \\
    \\Remove the burr on leather. The `relations:` frontmatter on this page
    \\records a typed `relates_to` edge to [[wiki/tools/chisels]] as well.
    \\
;

const wiki_dovetails_md =
    \\---
    \\title: Dovetails
    \\parent: wiki/techniques
    \\tags: [techniques, joinery]
    \\---
    \\
    \\# Dovetails
    \\
    \\The interlocking corner joint. Saw the tails, mark the pins from them,
    \\then pare to the line with sharp [[wiki/tools/chisels]].
    \\
    \\## Layout
    \\
    \\Mark the baseline with a gauge and the slopes with a bevel.
    \\
    \\## Sawing
    \\
    \\Saw on the waste side of every line.
    \\
    \\## Fitting
    \\
    \\Pare, test, and pare again. A dull edge crushes fibres, so revisit
    \\[[wiki/techniques/sharpening]] before the final fit.
    \\
;

const wiki_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Workshop Wiki" },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/reference",
    \\      "layout_rules": [
    \\        { "selector": "id:index", "layout": "themes/reference/layouts/home.html" },
    \\        { "selector": "glob:wiki/*", "layout": "themes/reference/layouts/section.html" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

// --- link-in-bio ------------------------------------------------------------

const link_in_bio_index_md =
    \\---
    \\title: Robin Vale
    \\tags: [links]
    \\---
    \\
    \\# Robin Vale
    \\
    \\Letterpress printer and occasional bookbinder. This whole site is one
    \\page: the smallest graph Boris builds, still parsed, validated, and
    \\published through the same profile as any larger site.
    \\
    \\## Elsewhere
    \\
    \\- [Studio journal](https://example.com/journal)
    \\- [Print shop](https://example.com/shop)
    \\- [Newsletter](https://example.com/newsletter)
    \\- [Email](mailto:robin@example.com)
    \\
    \\Replace these links with yours. Add a second page only when you need one.
    \\
;

const link_in_bio_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Robin Vale" },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/minimal" }
    \\  ]
    \\}
    \\
;

// --- changelog --------------------------------------------------------------

const changelog_index_md =
    \\---
    \\title: Tidepool Release Notes
    \\tags: [home]
    \\---
    \\
    \\# Tidepool Release Notes
    \\
    \\Release notes for Tidepool, a small command-line tide-table tool. Every
    \\release is a dated page under [[changes]]; the newest shipped release is
    \\[[changes/2026-09-28-v0-2-0]].
    \\
;

const changelog_changes_md =
    \\---
    \\title: Changes
    \\parent: index
    \\tags: [changes]
    \\---
    \\
    \\# Changes
    \\
    \\Every release is a satellite of this hub (`parent: changes`). The
    \\profile's `layout_rules` render this page through the journal theme's
    \\`archive.html`, whose entry listing is `{{children}}`: each published
    \\release, in id order, so the date-prefixed ids sort oldest first.
    \\
    \\The entry marked `status: draft` is the unreleased section: it renders
    \\at its normal route, but stays out of that listing, the search index,
    \\feeds, and the sitemap until you change it to `status: published`.
    \\Until then, this hand-written link reaches it: [[changes/unreleased]].
    \\
;

const changelog_unreleased_md =
    \\---
    \\title: Unreleased
    \\parent: changes
    \\status: draft
    \\published_at: 2026-10-10T00:00:00Z
    \\summary: Work merged since v0.2.0 that has not shipped yet.
    \\tags: [release]
    \\---
    \\
    \\# Unreleased
    \\
    \\## Added
    \\
    \\- `tidepool export --ics` writes a calendar of the week's high tides.
    \\
    \\## Changed
    \\
    \\- Station names match case-insensitively.
    \\
    \\When this ships, set the real `published_at`, rename the file to its
    \\version, and drop `status: draft` (or set `status: published`).
    \\
;

const changelog_v0_2_0_md =
    \\---
    \\title: v0.2.0
    \\parent: changes
    \\published_at: 2026-09-28T12:00:00Z
    \\summary: Station search, metric heights by default, and a faster parser.
    \\tags: [release]
    \\---
    \\
    \\# v0.2.0
    \\
    \\## Added
    \\
    \\- `tidepool search NAME` finds stations by name.
    \\
    \\## Changed
    \\
    \\- Heights print in metres by default; `--feet` restores the old unit.
    \\
    \\## Fixed
    \\
    \\- Daylight-saving transitions no longer drop a tide.
    \\
    \\Previous release: [[changes/2026-08-17-v0-1-0]].
    \\
;

const changelog_v0_1_0_md =
    \\---
    \\title: v0.1.0
    \\parent: changes
    \\published_at: 2026-08-17T12:00:00Z
    \\summary: First public release — today's tides for one station.
    \\tags: [release]
    \\---
    \\
    \\# v0.1.0
    \\
    \\## Added
    \\
    \\- `tidepool today STATION` prints the day's highs and lows.
    \\- A bundled station list for the home coast.
    \\
    \\Next release: [[changes/2026-09-28-v0-2-0]].
    \\
;

const changelog_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Tidepool Release Notes" },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/journal",
    \\      "layout_rules": [
    \\        { "selector": "id:changes", "layout": "themes/journal/layouts/archive.html" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

// --- resume -----------------------------------------------------------------

const resume_index_md =
    \\---
    \\title: Ada Brennan
    \\tags: [production-editing, typesetting, publishing-systems]
    \\published_at: 2026-10-01T09:00:00Z
    \\summary: Production editor and publishing-systems engineer.
    \\---
    \\
    \\# Ada Brennan
    \\
    \\Production editor and publishing-systems engineer. This page is the
    \\whole CV: print it, and the theme's print stylesheet turns the site into
    \\the PDF.
    \\
    \\## Summary
    \\
    \\Ten years taking manuscripts to print and to the web from one source.
    \\Comfortable in the copy room and in the build pipeline.
    \\
    \\## Experience
    \\
    \\### Lead production editor — Harrow & Finch, 2021–present
    \\
    \\- Moved a 40-title backlist to a single-source Markdown workflow.
    \\- Cut proof turnaround from nine days to four.
    \\
    \\### Production editor — Lantern Quarterly, 2016–2021
    \\
    \\- Ran the quarterly print schedule and the web edition.
    \\- Wrote the house style guide still in use today.
    \\
    \\## Projects
    \\
    \\- **Open specimen book** — a typeface specimen built from plain text.
    \\- **Proof tracker** — a small tool for routing page proofs.
    \\
    \\## Skills
    \\
    \\Copy-editing, typesetting, accessibility review, static publishing.
    \\
    \\## Contact
    \\
    \\- Email: ada@example.com
    \\- What I am working on right now: [[now]].
    \\
;

const resume_now_md =
    \\---
    \\title: Now
    \\parent: index
    \\tags: [now]
    \\published_at: 2026-10-05T09:00:00Z
    \\summary: What I am working on this season.
    \\---
    \\
    \\# Now
    \\
    \\- Typesetting a poetry collection for spring.
    \\- Reading about variable fonts in long-form print.
    \\- Open to contract production work from November.
    \\
    \\Back to the [[index]] CV.
    \\
;

const resume_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Ada Brennan" },
    \\  "targets": [
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/corporate" }
    \\  ]
    \\}
    \\
;

// --- newsletter -------------------------------------------------------------

const newsletter_index_md =
    \\---
    \\title: The Saturday Sheet
    \\tags: [home]
    \\---
    \\
    \\# The Saturday Sheet
    \\
    \\A weekly paper of small-press news, one issue every Saturday. Each issue
    \\is a dated page under [[issues]]; this week's is
    \\[[issues/2026-10-03-the-paper-mill]].
    \\
    \\Every build publishes `feed.xml` and `sitemap.xml` from the profile.
    \\The feed rides on the target's enabled `head`: every page's head links
    \\the feed so feed readers can discover it, and every press layout
    \\carries the `{{head}}` slot that makes that possible.
    \\
;

const newsletter_issues_md =
    \\---
    \\title: Back Issues
    \\parent: index
    \\tags: [issues]
    \\---
    \\
    \\# Back Issues
    \\
    \\Every issue is a satellite of this page, newest first. An issue needs a
    \\`published_at` date and a one-line `summary`; the date orders feeds, and
    \\the summary becomes the feed item description.
    \\
    \\- [[issues/2026-10-03-the-paper-mill]]
    \\- [[issues/2026-09-26-type-on-the-shelf]]
    \\- [[issues/2026-09-19-first-edition]]
    \\
;

const newsletter_issue_1_md =
    \\---
    \\title: "№ 1: First Edition"
    \\parent: issues
    \\published_at: 2026-09-19T08:00:00Z
    \\summary: Why a weekly paper, and what each issue will carry.
    \\tags: [editorial]
    \\---
    \\
    \\# № 1: First Edition
    \\
    \\Welcome to the first sheet. Each Saturday: one lead story, three short
    \\notes, and a reading list. Next week: [[issues/2026-09-26-type-on-the-shelf]].
    \\
;

const newsletter_issue_2_md =
    \\---
    \\title: "№ 2: Type on the Shelf"
    \\parent: issues
    \\published_at: 2026-09-26T08:00:00Z
    \\summary: A visit to a print shop that still sets metal type.
    \\tags: [type, visits]
    \\---
    \\
    \\# № 2: Type on the Shelf
    \\
    \\## Lead
    \\
    \\Two cases of twelve-point Caslon and a proofing press in a back room.
    \\
    \\## Notes
    \\
    \\- A typefoundry reopens its casting room.
    \\- The county library adds a letterpress club.
    \\
    \\Previous: [[issues/2026-09-19-first-edition]].
    \\
;

const newsletter_issue_3_md =
    \\---
    \\title: "№ 3: The Paper Mill"
    \\parent: issues
    \\published_at: 2026-10-03T08:00:00Z
    \\summary: Where the paper comes from, and a follow-up on last week's print shop.
    \\tags: [paper, visits]
    \\relations: [relates_to=issues/2026-09-26-type-on-the-shelf]
    \\---
    \\
    \\# № 3: The Paper Mill
    \\
    \\## Lead
    \\
    \\A family mill that still makes cotton rag paper by the vat.
    \\
    \\## Follow-up
    \\
    \\The print shop from [[issues/2026-09-26-type-on-the-shelf]] buys its
    \\stock here. This issue also declares a typed `relates_to` relation to
    \\that one in its frontmatter.
    \\
    \\## Reading list
    \\
    \\- Back issues: [[issues]].
    \\
;

const newsletter_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": {
    \\    "title": "The Saturday Sheet",
    \\    "url": "https://saturday-sheet.example.com/",
    \\    "description": "A weekly paper of small-press news."
    \\  },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/press",
    \\      "layout_rules": [
    \\        { "selector": "id:index", "layout": "themes/press/layouts/home.html" },
    \\        { "selector": "id:issues", "layout": "themes/press/layouts/archive.html" },
    \\        { "selector": "glob:issues/*", "layout": "themes/press/layouts/blog.html" }
    \\      ],
    \\      "head": { "enabled": true, "base_url": "https://saturday-sheet.example.com/" },
    \\      "rss": { "path": "feed.xml" },
    \\      "sitemap": { "path": "sitemap.xml" }
    \\    }
    \\  ]
    \\}
    \\
;

// --- portfolio --------------------------------------------------------------

const portfolio_index_md =
    \\---
    \\title: Mara Lindqvist Studio
    \\tags: [home]
    \\---
    \\
    \\# Mara Lindqvist Studio
    \\
    \\Wayfinding, print, and type for public places.
    \\
    \\Each project under `content/projects/` is a satellite of this page
    \\(`parent: index`) with a `published_at` date and a one-line `summary`.
    \\The showcase home layout's `{{children}}` slot lists this page's direct
    \\satellites under "Explore", so a new project file joins that list on
    \\the next build without an edit here.
    \\
;

const portfolio_about_md =
    \\---
    \\title: About
    \\parent: index
    \\tags: [about]
    \\---
    \\
    \\# About
    \\
    \\A two-person studio working with towns, museums, and small publishers.
    \\
    \\## How this starter is wired
    \\
    \\`boris.json` declares a `layout_rules` entry that sends `id:index` to
    \\`themes/showcase/layouts/home.html`. Every other page, including this
    \\one and each project, falls back to the theme's `main.html`. Layout
    \\choice is build configuration in the profile, never page frontmatter.
    \\
    \\Back to the [[index]].
    \\
;

const portfolio_harbor_signage_md =
    \\---
    \\title: Harbor Signage
    \\parent: index
    \\published_at: 2026-06-12T09:00:00Z
    \\summary: A wayfinding system for a working harbor front.
    \\tags: [wayfinding]
    \\---
    \\
    \\# Harbor Signage
    \\
    \\Forty signs, two languages, one typeface tuned for salt and glare.
    \\
    \\## Brief
    \\
    \\Make the harbor walkable for visitors without slowing the people who
    \\work there.
    \\
    \\## Outcome
    \\
    \\Installed in spring; the same grid later set the
    \\[[projects/field-almanac]] pages.
    \\
;

const portfolio_field_almanac_md =
    \\---
    \\title: Field Almanac
    \\parent: index
    \\published_at: 2026-08-03T09:00:00Z
    \\summary: A pocket almanac for a regional nature trust.
    \\tags: [print, editorial]
    \\relations: [relates_to=projects/harbor-signage]
    \\---
    \\
    \\# Field Almanac
    \\
    \\A 96-page pocket book of tides, moon phases, and walking routes.
    \\
    \\## Approach
    \\
    \\The layout grid comes from [[projects/harbor-signage]]; the `relations:`
    \\frontmatter records that lineage as a typed `relates_to` edge.
    \\
;

const portfolio_specimen_book_md =
    \\---
    \\title: Specimen Book
    \\parent: index
    \\published_at: 2026-09-22T09:00:00Z
    \\summary: A type specimen for the studio's harbor typeface.
    \\tags: [type]
    \\---
    \\
    \\# Specimen Book
    \\
    \\Every weight of the harbor face, set at reading and display sizes.
    \\
    \\Back to the [[index]].
    \\
;

const portfolio_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Mara Lindqvist Studio" },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/showcase",
    \\      "layout_rules": [
    \\        { "selector": "id:index", "layout": "themes/showcase/layouts/home.html" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

// --- archive ----------------------------------------------------------------

const archive_index_md =
    \\---
    \\title: Harbor Street Archive
    \\---
    \\
    \\A long-lived archive of small records from one street by the harbor:
    \\timetables, photographs, and notices, filed so a later reader can follow
    \\what replaced what.
    \\
    \\## How the taxonomy works
    \\
    \\- `tags:` file an entry under one or more subjects. Boris generates no
    \\  tag pages, so [[topics]] is a hand-kept index by tag.
    \\- `relations:` record typed edges between entries: `relates_to` for "see
    \\  also" and `supersedes` when a newer record replaces an older one.
    \\- `{{backlinks}}` is derived evidence: each entry lists the entries
    \\  whose relations point at it, so an old record shows what replaced it.
    \\- `status: archived` marks a record that is kept but no longer current.
    \\
    \\Every entry is a satellite of this page; the layout's `{{children}}`
    \\slot lists them.
    \\
;

const archive_topics_md =
    \\---
    \\title: Topics
    \\parent: index
    \\tags: [index]
    \\---
    \\
    \\# Topics
    \\
    \\An index by tag, kept by hand. Boris validates every link here, but it
    \\never generates this page: when you tag a new entry, add it below.
    \\
    \\## harbor
    \\
    \\- [[entries/2020-harbor-lights]]
    \\- [[entries/2023-pier-closing]]
    \\
    \\## transit
    \\
    \\- [[entries/2019-ferry-timetable]]
    \\- [[entries/2021-ferry-timetable]]
    \\- [[entries/2023-pier-closing]]
    \\
    \\## paper
    \\
    \\- [[entries/2019-ferry-timetable]]
    \\- [[entries/2021-ferry-timetable]]
    \\
    \\## photographs
    \\
    \\- [[entries/2020-harbor-lights]]
    \\
;

const archive_ferry_2019_md =
    \\---
    \\title: Ferry timetable, 2019
    \\parent: index
    \\status: archived
    \\tags: [transit, paper]
    \\---
    \\
    \\# Ferry timetable, 2019
    \\
    \\**Filed March 2019 · folded card, two sides**
    \\
    \\Hourly sailings from seven until seven, with a late boat on Fridays.
    \\Kept as a record: it is `status: archived`, and its backlinks name the
    \\timetable that replaced it.
    \\
;

const archive_harbor_lights_md =
    \\---
    \\title: Harbor lights
    \\parent: index
    \\tags: [harbor, photographs]
    \\relations: [relates_to=entries/2019-ferry-timetable]
    \\---
    \\
    \\# Harbor lights
    \\
    \\**Filed November 2020 · six prints**
    \\
    \\The last ferry crossing at dusk, photographed from the pier steps. The
    \\sailing times on the back come from the 2019 timetable.
    \\
;

const archive_ferry_2021_md =
    \\---
    \\title: Ferry timetable, 2021
    \\parent: index
    \\tags: [transit, paper]
    \\relations: [supersedes=entries/2019-ferry-timetable]
    \\---
    \\
    \\# Ferry timetable, 2021
    \\
    \\**Filed April 2021 · single sheet**
    \\
    \\Sailings every ninety minutes; the Friday late boat is gone. This sheet
    \\`supersedes` the 2019 card, which keeps its place in the archive.
    \\
;

const archive_pier_closing_md =
    \\---
    \\title: Pier closing notice
    \\parent: index
    \\tags: [harbor, transit]
    \\relations: [relates_to=entries/2020-harbor-lights, relates_to=entries/2021-ferry-timetable]
    \\---
    \\
    \\# Pier closing notice
    \\
    \\**Filed June 2023 · notice, one page**
    \\
    \\The old pier closes for repair; ferries move to the east landing. The
    \\notice relates to the 2021 timetable it amends and to the photographs of
    \\the pier as it was.
    \\
;

const archive_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Harbor Street Archive" },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/archive",
    \\      "layout_rules": [
    \\        { "selector": "id:index", "layout": "themes/archive/layouts/archive.html" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

// --- dashboard --------------------------------------------------------------

const dashboard_index_md =
    \\---
    \\title: Harbor Systems Status Board
    \\---
    \\
    \\One page per project, each a satellite of this board. A project's
    \\`status:` frontmatter is its state: the theme shows it as a label under
    \\the page title, and Boris uses the same field to decide what it
    \\advertises.
    \\
    \\## Projects
    \\
    \\| Project | `status:` | State | Depends on |
    \\|---|---|---|---|
    \\| [[projects/tide-gauge-network]] | `published` | Active | — |
    \\| [[projects/harbor-sensor-pilot]] | `draft` | Proposed | Tide gauge network |
    \\| [[projects/telemetry-relay]] | `archived` | Retired | — |
    \\
    \\## Status vocabulary
    \\
    \\Boris has exactly three status values. This board maps them to project
    \\states:
    \\
    \\| `status:` | Project state | What Boris does with the page |
    \\|---|---|---|
    \\| `published` | Active: running and supported | Renders and advertises it (search, sitemap, feeds, nav) |
    \\| `draft` | Proposed: not yet approved | Renders it at its route but does not advertise it |
    \\| `archived` | Retired: kept for the record | Renders and advertises it like `published`; the label says archived |
    \\
    \\There is no "blocked" or "at risk" value. Put that in the project's
    \\status-history table, not in `status:`.
    \\
;

const dashboard_tide_gauge_md =
    \\---
    \\title: Tide gauge network
    \\parent: index
    \\status: published
    \\summary: Six harbor tide gauges reporting every five minutes.
    \\tags: [sensors, operations]
    \\relations: [supersedes=projects/telemetry-relay]
    \\---
    \\
    \\Six gauges along the harbor wall, each reporting water level every five
    \\minutes over the cellular uplink that replaced the [[projects/telemetry-relay]].
    \\
    \\## Status history
    \\
    \\| Date | `status:` | Note |
    \\|---|---|---|
    \\| 2025-03-02 | `draft` | Proposed with two pilot gauges |
    \\| 2025-09-15 | `published` | All six gauges live |
    \\| 2026-06-01 | `published` | Cellular uplink replaces the radio relay |
    \\
    \\## Service
    \\
    \\| Gauge | Location | Uptime (90 days) |
    \\|---|---|---|
    \\| G1 | North mole | 99.8% |
    \\| G2 | Ferry slip | 99.5% |
    \\| G3 | East landing | 98.9% |
    \\
;

const dashboard_sensor_pilot_md =
    \\---
    \\title: Harbor sensor pilot
    \\parent: index
    \\status: draft
    \\summary: A proposed water-quality pilot on two existing gauges.
    \\tags: [sensors, proposal]
    \\relations: [depends_on=projects/tide-gauge-network]
    \\---
    \\
    \\A proposal to add temperature and turbidity sensors to gauges G1 and G2
    \\of the [[projects/tide-gauge-network]]. Until it is approved the page is
    \\`status: draft`: it renders here but stays out of search and the sitemap.
    \\
    \\## Status history
    \\
    \\| Date | `status:` | Note |
    \\|---|---|---|
    \\| 2026-09-20 | `draft` | Proposal written; waiting on the harbor board |
    \\
    \\To approve it, change `status: draft` to `status: published`.
    \\
;

const dashboard_telemetry_relay_md =
    \\---
    \\title: Telemetry relay
    \\parent: index
    \\status: archived
    \\summary: The retired radio relay that carried gauge data until 2026.
    \\tags: [operations]
    \\---
    \\
    \\A VHF radio relay on the harbor office roof that carried gauge readings
    \\from 2019 until the cellular uplink replaced it. The page is
    \\`status: archived`: it is still published, and its backlinks name the
    \\project that superseded it.
    \\
    \\## Status history
    \\
    \\| Date | `status:` | Note |
    \\|---|---|---|
    \\| 2019-04-11 | `published` | Relay commissioned |
    \\| 2026-06-01 | `archived` | Retired; replaced by the cellular uplink |
    \\
;

const dashboard_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Harbor Systems Status Board" },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/engineering",
    \\      "layout_rules": [
    \\        { "selector": "id:index", "layout": "themes/engineering/layouts/home.html" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

// --- photo-gallery ----------------------------------------------------------

// Starter images are content, not theme assets, so they live with the init
// templates under src/ and embed by relative path. They are byte-identical
// copies of five examples/gallery-site plates (locally generated flat-colour
// PNGs; provenance and SHA-256 in examples/gallery-site/README.md).
const photo_gallery_tidewater_png = @embedFile("init_templates/photo-gallery/content/index.assets/tidewater.png");
const photo_gallery_dawn_png = @embedFile("init_templates/photo-gallery/content/photos/coast.assets/dawn.png");
const photo_gallery_dusk_png = @embedFile("init_templates/photo-gallery/content/photos/coast.assets/dusk.png");
const photo_gallery_ridge_png = @embedFile("init_templates/photo-gallery/content/photos/hills.assets/ridge.png");
const photo_gallery_pines_png = @embedFile("init_templates/photo-gallery/content/photos/hills.assets/pines.png");

const photo_gallery_index_md =
    \\---
    \\title: Two Walks
    \\tags: [gallery]
    \\summary: Two small albums of page-local images.
    \\---
    \\
    \\# Two Walks
    \\
    \\A coast walk and a hill walk, two plates each. Every page keeps its
    \\images in a sibling `{stem}.assets/` folder: this page's cover lives in
    \\`content/index.assets/`, and each album's plates live beside the album.
    \\
    \\<figure>
    \\
    \\![A posterized seascape at evening: banded sky fading from navy to coral above dark water, with a pale sun low on the right](index.assets/tidewater.png)
    \\
    \\<figcaption><strong>Tidewater.</strong> Cover plate, 1200 × 560 PNG.</figcaption>
    \\</figure>
    \\
    \\The album grid below comes from the layout's `{{children}}` slot. Boris
    \\copies each image byte for byte and rewrites its Markdown URL to a
    \\page-relative path. It never resizes, crops, or makes thumbnails, so
    \\scale and compress images before you add them.
    \\
;

const photo_gallery_coast_md =
    \\---
    \\title: Coast
    \\parent: index
    \\tags: [coast, album]
    \\summary: One horizon at two times of day.
    \\relations: [relates_to=photos/hills]
    \\---
    \\
    \\# Coast
    \\
    \\One horizon, twelve hours apart. A `gallery-grid` block sets the figures
    \\side by side on a wide screen and stacks them on a narrow one.
    \\
    \\<div class="gallery-grid">
    \\
    \\<figure>
    \\
    \\![Dawn: lavender-to-peach banded sky over slate water, a small pale sun low on the left with a striped reflection](coast.assets/dawn.png)
    \\
    \\<figcaption><strong>Dawn.</strong> Cold light, low sun.</figcaption>
    \\</figure>
    \\
    \\<figure>
    \\
    \\![Dusk: plum-to-orange banded sky, a large amber sun touching the horizon above a long striped reflection](coast.assets/dusk.png)
    \\
    \\<figcaption><strong>Dusk.</strong> The sun sits on the water line.</figcaption>
    \\</figure>
    \\
    \\</div>
    \\
    \\Next walk: [[photos/hills]].
    \\
;

const photo_gallery_hills_md =
    \\---
    \\title: Hills
    \\parent: index
    \\tags: [hills, album]
    \\summary: Layered ridges and one portrait plate.
    \\---
    \\
    \\# Hills
    \\
    \\Inland, the ridges stack up. One plate is portrait, so the grid copes
    \\with uneven heights.
    \\
    \\<div class="gallery-grid">
    \\
    \\<figure>
    \\
    \\![Ridge: four layered ridgelines in blue-grey to dark green under a banded sky](hills.assets/ridge.png)
    \\
    \\<figcaption><strong>Ridge.</strong> Four layers, nearest darkest.</figcaption>
    \\</figure>
    \\
    \\<figure>
    \\
    \\![Pines: three stepped dark-green pine silhouettes on an olive ground under a pale sky, portrait format](hills.assets/pines.png)
    \\
    \\<figcaption><strong>Pines.</strong> Portrait, 720 × 960.</figcaption>
    \\</figure>
    \\
    \\</div>
    \\
    \\## Adding a plate
    \\
    \\Put the file in `content/photos/hills.assets/`, then reference it from
    \\this page with an ordinary Markdown image inside a `<figure>`. Keep the
    \\blank lines around the image so it stays Markdown, which is what lets
    \\Boris check and rewrite its URL. A missing file fails the build with
    \\`EASSET`.
    \\
;

const photo_gallery_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": { "title": "Two Walks" },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/gallery",
    \\      "layout_rules": [
    \\        { "selector": "id:index", "layout": "themes/gallery/layouts/home.html" }
    \\      ]
    \\    }
    \\  ]
    \\}
    \\
;

// --- archetype table ---------------------------------------------------------

const FileToWrite = struct {
    path: []const u8,
    data: []const u8,
};

/// One starter archetype: the files it writes (fixed order, fixed bytes),
/// the input format its profile declares, and the layout the compile probe
/// uses. Reports are pre-formatted, indented line blocks.
const ArchetypeSpec = struct {
    /// Whole-tree input format the archetype's `boris.json` declares; the
    /// probe passes the same value so "materialized AND compiled" exercises
    /// the real adapter.
    input_format: identity.InputFormat = .markdown,
    /// Probe layout path: lexical, `/`-separated, relative to the target.
    layout_path: []const u8,
    files: []const FileToWrite,
    tree_report: []const u8,
    next_steps: []const u8,
    conventions: []const u8 = "",
};

/// Every file `init --type docs` writes, in fixed order, with fixed bytes.
const docs_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = index_md },
    .{ .path = "content/guides/getting-started.md", .data = getting_started_md },
    .{ .path = "content/guides/publishing.md", .data = publishing_md },
    .{ .path = "themes/boris/layouts/main.html", .data = starter_layout },
    .{ .path = "themes/boris/assets/css/boris.css", .data = starter_css },
    .{ .path = "boris.json", .data = starter_profile },
    .{ .path = "standard-site.json", .data = standard_site_profile },
};

const garden_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = garden_index_md },
    .{ .path = "content/notes/digital-garden.md", .data = garden_digital_garden_md },
    .{ .path = "content/notes/wiki-links.md", .data = garden_wiki_links_md },
    .{ .path = "content/notes/composition.md", .data = garden_composition_md },
    .{ .path = "content/notes/semantic-relations.md", .data = garden_semantic_relations_md },
    .{ .path = "content/includes/house-style.md", .data = garden_house_style_md },
    .{ .path = "content/includes/link-roll.md", .data = garden_link_roll_md },
    .{ .path = "themes/ledger/layouts/main.html", .data = archetype_themes.ledger_layout_main },
    .{ .path = "themes/ledger/footer.html", .data = archetype_themes.ledger_footer },
    .{ .path = "themes/ledger/assets/ledger.css", .data = archetype_themes.ledger_css },
    .{ .path = "themes/ledger/README.md", .data = archetype_themes.ledger_readme },
    .{ .path = "themes/ledger/ACCESSIBILITY.md", .data = archetype_themes.ledger_accessibility },
    .{ .path = "boris.json", .data = garden_profile },
};

const cookbook_files = [_]FileToWrite{
    .{ .path = "content/index.cook", .data = cookbook_index_cook },
    .{ .path = "content/mains/carbonara.cook", .data = cookbook_carbonara_cook },
    .{ .path = "content/mains/pancakes.cook", .data = cookbook_pancakes_cook },
    .{ .path = "content/sauces/pepper-oil.cook", .data = cookbook_pepper_oil_cook },
    .{ .path = "themes/cards/layouts/main.html", .data = archetype_themes.cards_layout_main },
    .{ .path = "themes/cards/layouts/home.html", .data = archetype_themes.cards_layout_home },
    .{ .path = "themes/cards/footer.html", .data = archetype_themes.cards_footer },
    .{ .path = "themes/cards/assets/css/cards.css", .data = archetype_themes.cards_css },
    .{ .path = "themes/cards/README.md", .data = archetype_themes.cards_readme },
    .{ .path = "themes/cards/ACCESSIBILITY.md", .data = archetype_themes.cards_accessibility },
    .{ .path = "boris.json", .data = cookbook_profile },
};

const blog_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = blog_index_md },
    .{ .path = "content/about.md", .data = blog_about_md },
    .{ .path = "content/posts.md", .data = blog_posts_md },
    .{ .path = "content/posts/2026-09-14-first-post.md", .data = blog_post_first_md },
    .{ .path = "content/posts/2026-09-21-week-notes.md", .data = blog_post_week_notes_md },
    .{ .path = "content/posts/2026-10-05-why-i-write.md", .data = blog_post_why_i_write_md },
    .{ .path = "themes/cozy/layouts/main.html", .data = archetype_themes.cozy_layout_main },
    .{ .path = "themes/cozy/footer.html", .data = archetype_themes.cozy_footer },
    .{ .path = "themes/cozy/assets/cozy.css", .data = archetype_themes.cozy_css },
    .{ .path = "themes/cozy/README.md", .data = archetype_themes.cozy_readme },
    .{ .path = "themes/cozy/ACCESSIBILITY.md", .data = archetype_themes.cozy_accessibility },
    .{ .path = "boris.json", .data = blog_profile },
};

const textile_files = [_]FileToWrite{
    .{ .path = "content/index.textile", .data = textile_index_textile },
    .{ .path = "content/dispatches/why-textile.textile", .data = textile_why_textile_textile },
    .{ .path = "content/dispatches/migration-notes.textile", .data = textile_migration_notes_textile },
    .{ .path = "themes/press/layouts/main.html", .data = archetype_themes.press_layout_main },
    .{ .path = "themes/press/layouts/home.html", .data = archetype_themes.press_layout_home },
    .{ .path = "themes/press/layouts/section.html", .data = archetype_themes.press_layout_section },
    .{ .path = "themes/press/layouts/blog.html", .data = archetype_themes.press_layout_blog },
    .{ .path = "themes/press/layouts/archive.html", .data = archetype_themes.press_layout_archive },
    .{ .path = "themes/press/footer.html", .data = archetype_themes.press_footer },
    .{ .path = "themes/press/assets/css/press.css", .data = archetype_themes.press_css },
    .{ .path = "themes/press/assets/img/press-mark.svg", .data = archetype_themes.press_mark_svg },
    .{ .path = "themes/press/README.md", .data = archetype_themes.press_readme },
    .{ .path = "themes/press/ACCESSIBILITY.md", .data = archetype_themes.press_accessibility },
    .{ .path = "themes/press/MIGRATION.md", .data = archetype_themes.press_migration },
    .{ .path = "boris.json", .data = textile_profile },
};

const landing_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = landing_index_md },
    .{ .path = "content/about.md", .data = landing_about_md },
    .{ .path = "content/includes/services.md", .data = landing_services_md },
    .{ .path = "content/includes/faq.md", .data = landing_faq_md },
    .{ .path = "content/includes/visit.md", .data = landing_visit_md },
    .{ .path = "themes/service/layouts/main.html", .data = archetype_themes.service_layout_main },
    .{ .path = "themes/service/layouts/home.html", .data = archetype_themes.service_layout_home },
    .{ .path = "themes/service/layouts/section.html", .data = archetype_themes.service_layout_section },
    .{ .path = "themes/service/footer.html", .data = archetype_themes.service_footer },
    .{ .path = "themes/service/assets/css/service.css", .data = archetype_themes.service_css },
    .{ .path = "themes/service/README.md", .data = archetype_themes.service_readme },
    .{ .path = "themes/service/ACCESSIBILITY.md", .data = archetype_themes.service_accessibility },
    .{ .path = "boris.json", .data = landing_profile },
};

const wiki_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = wiki_index_md },
    .{ .path = "content/wiki/tools.md", .data = wiki_tools_md },
    .{ .path = "content/wiki/techniques.md", .data = wiki_techniques_md },
    .{ .path = "content/wiki/tools/chisels.md", .data = wiki_chisels_md },
    .{ .path = "content/wiki/tools/hand-planes.md", .data = wiki_hand_planes_md },
    .{ .path = "content/wiki/techniques/sharpening.md", .data = wiki_sharpening_md },
    .{ .path = "content/wiki/techniques/dovetails.md", .data = wiki_dovetails_md },
    .{ .path = "themes/reference/layouts/main.html", .data = archetype_themes.reference_layout_main },
    .{ .path = "themes/reference/layouts/home.html", .data = archetype_themes.reference_layout_home },
    .{ .path = "themes/reference/layouts/section.html", .data = archetype_themes.reference_layout_section },
    .{ .path = "themes/reference/footer.html", .data = archetype_themes.reference_footer },
    .{ .path = "themes/reference/assets/css/reference.css", .data = archetype_themes.reference_css },
    .{ .path = "themes/reference/assets/img/mark.svg", .data = archetype_themes.reference_mark_svg },
    .{ .path = "themes/reference/README.md", .data = archetype_themes.reference_readme },
    .{ .path = "themes/reference/ACCESSIBILITY.md", .data = archetype_themes.reference_accessibility },
    .{ .path = "boris.json", .data = wiki_profile },
};

const link_in_bio_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = link_in_bio_index_md },
    .{ .path = "themes/minimal/layouts/main.html", .data = archetype_themes.minimal_layout_main },
    .{ .path = "themes/minimal/footer.html", .data = archetype_themes.minimal_footer },
    .{ .path = "themes/minimal/assets/minimal.css", .data = archetype_themes.minimal_css },
    .{ .path = "themes/minimal/README.md", .data = archetype_themes.minimal_readme },
    .{ .path = "themes/minimal/ACCESSIBILITY.md", .data = archetype_themes.minimal_accessibility },
    .{ .path = "boris.json", .data = link_in_bio_profile },
};

const changelog_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = changelog_index_md },
    .{ .path = "content/changes.md", .data = changelog_changes_md },
    .{ .path = "content/changes/unreleased.md", .data = changelog_unreleased_md },
    .{ .path = "content/changes/2026-09-28-v0-2-0.md", .data = changelog_v0_2_0_md },
    .{ .path = "content/changes/2026-08-17-v0-1-0.md", .data = changelog_v0_1_0_md },
    .{ .path = "themes/journal/layouts/main.html", .data = archetype_themes.journal_layout_main },
    .{ .path = "themes/journal/layouts/archive.html", .data = archetype_themes.journal_layout_archive },
    .{ .path = "themes/journal/footer.html", .data = archetype_themes.journal_footer },
    .{ .path = "themes/journal/assets/journal.css", .data = archetype_themes.journal_css },
    .{ .path = "themes/journal/README.md", .data = archetype_themes.journal_readme },
    .{ .path = "themes/journal/ACCESSIBILITY.md", .data = archetype_themes.journal_accessibility },
    .{ .path = "boris.json", .data = changelog_profile },
};

const resume_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = resume_index_md },
    .{ .path = "content/now.md", .data = resume_now_md },
    .{ .path = "themes/corporate/layouts/main.html", .data = archetype_themes.corporate_layout_main },
    .{ .path = "themes/corporate/footer.html", .data = archetype_themes.corporate_footer },
    .{ .path = "themes/corporate/assets/corporate.css", .data = archetype_themes.corporate_css },
    .{ .path = "themes/corporate/README.md", .data = archetype_themes.corporate_readme },
    .{ .path = "themes/corporate/ACCESSIBILITY.md", .data = archetype_themes.corporate_accessibility },
    .{ .path = "boris.json", .data = resume_profile },
};

const newsletter_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = newsletter_index_md },
    .{ .path = "content/issues.md", .data = newsletter_issues_md },
    .{ .path = "content/issues/2026-09-19-first-edition.md", .data = newsletter_issue_1_md },
    .{ .path = "content/issues/2026-09-26-type-on-the-shelf.md", .data = newsletter_issue_2_md },
    .{ .path = "content/issues/2026-10-03-the-paper-mill.md", .data = newsletter_issue_3_md },
    .{ .path = "themes/press/layouts/main.html", .data = archetype_themes.press_layout_main },
    .{ .path = "themes/press/layouts/home.html", .data = archetype_themes.press_layout_home },
    .{ .path = "themes/press/layouts/section.html", .data = archetype_themes.press_layout_section },
    .{ .path = "themes/press/layouts/blog.html", .data = archetype_themes.press_layout_blog },
    .{ .path = "themes/press/layouts/archive.html", .data = archetype_themes.press_layout_archive },
    .{ .path = "themes/press/footer.html", .data = archetype_themes.press_footer },
    .{ .path = "themes/press/assets/css/press.css", .data = archetype_themes.press_css },
    .{ .path = "themes/press/assets/img/press-mark.svg", .data = archetype_themes.press_mark_svg },
    .{ .path = "themes/press/README.md", .data = archetype_themes.press_readme },
    .{ .path = "themes/press/ACCESSIBILITY.md", .data = archetype_themes.press_accessibility },
    .{ .path = "themes/press/MIGRATION.md", .data = archetype_themes.press_migration },
    .{ .path = "boris.json", .data = newsletter_profile },
};

const portfolio_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = portfolio_index_md },
    .{ .path = "content/about.md", .data = portfolio_about_md },
    .{ .path = "content/projects/harbor-signage.md", .data = portfolio_harbor_signage_md },
    .{ .path = "content/projects/field-almanac.md", .data = portfolio_field_almanac_md },
    .{ .path = "content/projects/specimen-book.md", .data = portfolio_specimen_book_md },
    .{ .path = "themes/showcase/layouts/main.html", .data = archetype_themes.showcase_layout_main },
    .{ .path = "themes/showcase/layouts/home.html", .data = archetype_themes.showcase_layout_home },
    .{ .path = "themes/showcase/layouts/section.html", .data = archetype_themes.showcase_layout_section },
    .{ .path = "themes/showcase/layouts/blog.html", .data = archetype_themes.showcase_layout_blog },
    .{ .path = "themes/showcase/footer.html", .data = archetype_themes.showcase_footer },
    .{ .path = "themes/showcase/assets/css/showcase.css", .data = archetype_themes.showcase_css },
    .{ .path = "themes/showcase/assets/img/mark.svg", .data = archetype_themes.showcase_mark_svg },
    .{ .path = "themes/showcase/README.md", .data = archetype_themes.showcase_readme },
    .{ .path = "themes/showcase/ACCESSIBILITY.md", .data = archetype_themes.showcase_accessibility },
    .{ .path = "boris.json", .data = portfolio_profile },
};

const archive_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = archive_index_md },
    .{ .path = "content/topics.md", .data = archive_topics_md },
    .{ .path = "content/entries/2019-ferry-timetable.md", .data = archive_ferry_2019_md },
    .{ .path = "content/entries/2020-harbor-lights.md", .data = archive_harbor_lights_md },
    .{ .path = "content/entries/2021-ferry-timetable.md", .data = archive_ferry_2021_md },
    .{ .path = "content/entries/2023-pier-closing.md", .data = archive_pier_closing_md },
    .{ .path = "themes/archive/layouts/main.html", .data = archetype_themes.archive_layout_main },
    .{ .path = "themes/archive/layouts/archive.html", .data = archetype_themes.archive_layout_archive },
    .{ .path = "themes/archive/footer.html", .data = archetype_themes.archive_footer },
    .{ .path = "themes/archive/assets/archive.css", .data = archetype_themes.archive_css },
    .{ .path = "themes/archive/README.md", .data = archetype_themes.archive_readme },
    .{ .path = "themes/archive/ACCESSIBILITY.md", .data = archetype_themes.archive_accessibility },
    .{ .path = "boris.json", .data = archive_profile },
};

const dashboard_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = dashboard_index_md },
    .{ .path = "content/projects/tide-gauge-network.md", .data = dashboard_tide_gauge_md },
    .{ .path = "content/projects/harbor-sensor-pilot.md", .data = dashboard_sensor_pilot_md },
    .{ .path = "content/projects/telemetry-relay.md", .data = dashboard_telemetry_relay_md },
    .{ .path = "themes/engineering/layouts/main.html", .data = archetype_themes.engineering_layout_main },
    .{ .path = "themes/engineering/layouts/home.html", .data = archetype_themes.engineering_layout_home },
    .{ .path = "themes/engineering/layouts/section.html", .data = archetype_themes.engineering_layout_section },
    .{ .path = "themes/engineering/footer.html", .data = archetype_themes.engineering_footer },
    .{ .path = "themes/engineering/assets/css/engineering.css", .data = archetype_themes.engineering_css },
    .{ .path = "themes/engineering/README.md", .data = archetype_themes.engineering_readme },
    .{ .path = "themes/engineering/ACCESSIBILITY.md", .data = archetype_themes.engineering_accessibility },
    .{ .path = "boris.json", .data = dashboard_profile },
};

const photo_gallery_files = [_]FileToWrite{
    .{ .path = "content/index.md", .data = photo_gallery_index_md },
    .{ .path = "content/index.assets/tidewater.png", .data = photo_gallery_tidewater_png },
    .{ .path = "content/photos/coast.md", .data = photo_gallery_coast_md },
    .{ .path = "content/photos/coast.assets/dawn.png", .data = photo_gallery_dawn_png },
    .{ .path = "content/photos/coast.assets/dusk.png", .data = photo_gallery_dusk_png },
    .{ .path = "content/photos/hills.md", .data = photo_gallery_hills_md },
    .{ .path = "content/photos/hills.assets/ridge.png", .data = photo_gallery_ridge_png },
    .{ .path = "content/photos/hills.assets/pines.png", .data = photo_gallery_pines_png },
    .{ .path = "themes/gallery/layouts/main.html", .data = archetype_themes.gallery_layout_main },
    .{ .path = "themes/gallery/layouts/home.html", .data = archetype_themes.gallery_layout_home },
    .{ .path = "themes/gallery/footer.html", .data = archetype_themes.gallery_footer },
    .{ .path = "themes/gallery/assets/css/gallery.css", .data = archetype_themes.gallery_css },
    .{ .path = "themes/gallery/README.md", .data = archetype_themes.gallery_readme },
    .{ .path = "themes/gallery/ACCESSIBILITY.md", .data = archetype_themes.gallery_accessibility },
    .{ .path = "boris.json", .data = photo_gallery_profile },
};

const docs_spec = ArchetypeSpec{
    .layout_path = "themes/boris/layouts/main.html",
    .files = &docs_files,
    .tree_report =
    \\  content/index.md                  trunk page
    \\  content/guides/getting-started.md satellite page
    \\  content/guides/publishing.md      satellite page with a relation
    \\  themes/boris/                     starter theme (closed layout slots, search UI)
    \\  boris.json                        publication profile (GitHub Pages)
    \\  standard-site.json                Atmosphere profile (replace the fake DID/URL)
    ,
    .next_steps =
    \\  boris --input content --html-dir dist --theme themes/boris     build the site
    \\  boris check                                                    graph-health report
    \\  boris impact guides/getting-started                            dependency impact report
    \\  boris --context --quiet                                        AI Context Bundle
    \\  boris plan --profile boris.json                                inspect the plan
    \\  boris standard-site plan --profile standard-site.json          inspect Atmosphere records
    \\  boris watch --input content --html-dir dist --theme themes/boris   rebuild on change
    ,
    .conventions =
    \\  search works out of the box: the theme ships the client for dist/_boris/search/search-index.json
    \\  shared fragments live under content/includes/ and never compile as pages
    \\  page images live in <stem>.assets/ beside the page that owns them
    ,
};

const garden_spec = ArchetypeSpec{
    .layout_path = "themes/ledger/layouts/main.html",
    .files = &garden_files,
    .tree_report =
    \\  content/index.md                  trunk page
    \\  content/notes/                    four densely linked satellites
    \\  content/includes/                 shared {{include}} fragments (never pages)
    \\  themes/ledger/                    shipped "ledger" theme — dense early-web nodes
    \\  boris.json                        profile (input_format: markdown, theme: ledger)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the garden (profile drives input, format, theme)
    \\  boris check                           graph-health report — try deleting a link target
    \\  boris graph                           render the link web as Mermaid
    \\  boris impact notes/wiki-links         dependency impact report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  [[entity-id]] is a validated graph edge; [[id|label]] and [[id#heading]] variants work
    \\  {{include path}} splices a content-root-relative fragment into a page
    \\  relations: [kind=target] adds typed edges; this theme renders relations and backlinks
    \\  fragments under content/includes/ never compile as pages or unreferenced_page findings
    ,
};

const cookbook_spec = ArchetypeSpec{
    .input_format = .cook,
    .layout_path = "themes/cards/layouts/main.html",
    .files = &cookbook_files,
    .tree_report =
    \\  content/index.cook                trunk page (prose plus recipe references; home layout)
    \\  content/mains/                    two recipe satellites
    \\  content/sauces/pepper-oil.cook    sub-recipe used as an ingredient
    \\  themes/cards/                     shipped "cards" theme — soft recipe cards
    \\  boris.json                        profile (input_format: cook, theme: cards, layout_rules id:index → home)
    ,
    .next_steps =
    \\  boris --profile boris.json                                     build the recipe box (index shows a recipe deck)
    \\  boris recipe-scale --cooklang --id mains/carbonara --servings 4   scaled view (never rewrites source)
    \\  boris check --cooklang --input content                          graph-health report
    \\  boris watch --profile boris.json                                rebuild on change
    ,
    .conventions =
    \\  @name{amount%unit} is an ingredient, #name{} cookware, ~{n%unit} a timer
    \\  @./sauces/pepper-oil{1%tbsp} references another page as a validated graph edge
    \\  servings in frontmatter feeds `recipe-scale --servings`; = and == are section headings
    \\  parent: index puts a recipe in the home deck; layout_rules match .cook pages by id like any other
    ,
};

const blog_spec = ArchetypeSpec{
    .layout_path = "themes/cozy/layouts/main.html",
    .files = &blog_files,
    .tree_report =
    \\  content/index.md                  trunk page
    \\  content/about.md                  satellite page
    \\  content/posts.md                  satellite; parent of the dated posts
    \\  content/posts/                    three dated posts (published_at + summary)
    \\  themes/cozy/                      shipped "cozy" theme — mid-2000s personal blog
    \\  boris.json                        profile (input_format: markdown, theme: cozy)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the site (profile drives input, format, theme)
    \\  boris check                           graph-health report
    \\  boris impact posts                    dependency impact report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  parent: posts is what makes a dated file a post — the chain index → posts → post is the graph
    \\  published_at needs summary (and wants a real UTC date); status: draft stays out of feeds
    ,
};

const textile_spec = ArchetypeSpec{
    .input_format = .textile,
    .layout_path = "themes/press/layouts/main.html",
    .files = &textile_files,
    .tree_report =
    \\  content/index.textile             trunk page (Textile source)
    \\  content/dispatches/               two Textile satellites
    \\  themes/press/                     shipped "press" theme — editorial paper
    \\  boris.json                        profile (input_format: textile, theme: press)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the site through the Textile adapter
    \\  boris check --textile --input content graph-health report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  the profile's input_format: textile is the mechanism — no per-site compiler switch
    \\  bodies keep the closed subset: h1.–h6., p., bq., flat * and # lists, "label":dest links
    \\  frontmatter is unchanged: parent, tags, relations, published_at still shape the graph
    ,
};

const landing_spec = ArchetypeSpec{
    .layout_path = "themes/service/layouts/main.html",
    .files = &landing_files,
    .tree_report =
    \\  content/index.md                  trunk page — the whole landing page
    \\  content/about.md                  the one satellite page
    \\  content/includes/                 section fragments spliced by {{include}} (never pages)
    \\  themes/service/                   shipped "service" theme — public-service information
    \\  boris.json                        profile (theme: service, layout_rules id:index → home)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the site (index renders through home.html)
    \\  boris check                           graph-health report
    \\  boris plan --profile boris.json       inspect the normalized layout rules
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  one trunk page is a complete site; add satellites only when the story needs them
    \\  {{include includes/NAME.md}} splices a section fragment; links inside it count as edges
    \\  layout_rules in boris.json pick named layouts (id:, glob:, role:); frontmatter never does
    ,
};

const wiki_spec = ArchetypeSpec{
    .layout_path = "themes/reference/layouts/main.html",
    .files = &wiki_files,
    .tree_report =
    \\  content/index.md                  trunk page
    \\  content/wiki/tools.md             section hub (parent: index)
    \\  content/wiki/techniques.md        section hub (parent: index)
    \\  content/wiki/<hub>/               four leaf entries, two per hub
    \\  themes/reference/                 shipped "reference" theme — calm documentation
    \\  boris.json                        profile (theme: reference, layout_rules for index and hubs)
    ,
    .next_steps =
    \\  boris --profile boris.json                 build the wiki (index → home, hubs → section)
    \\  boris check                                graph-health report — try breaking a link
    \\  boris impact wiki/techniques/sharpening    what depends on the most-linked entry
    \\  boris watch --profile boris.json           rebuild on change
    ,
    .conventions =
    \\  parent: is the chain — an entry's breadcrumb walks index → hub → entry
    \\  glob:wiki/* matches exactly two segments, so hubs get section.html and entries keep main.html
    \\  two globs with the same literal-segment count would tie; ties are usage errors, not order
    ,
};

const link_in_bio_spec = ArchetypeSpec{
    .layout_path = "themes/minimal/layouts/main.html",
    .files = &link_in_bio_files,
    .tree_report =
    \\  content/index.md                  the only page — a trunk with your links
    \\  themes/minimal/                   shipped "minimal" theme — same shell, no search
    \\  boris.json                        profile (input_format: markdown, theme: minimal)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the one-page site
    \\  boris check                           graph-health report (still runs on one page)
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  a single trunk page is a valid site; graph, validation, and profile still apply
    \\  external links are plain Markdown links; [[wiki-links]] are for pages in this site
    ,
};

const changelog_spec = ArchetypeSpec{
    .layout_path = "themes/journal/layouts/main.html",
    .files = &changelog_files,
    .tree_report =
    \\  content/index.md                  trunk page
    \\  content/changes.md                satellite hub; its archive layout lists the releases
    \\  content/changes/                  two dated releases plus an unreleased status: draft entry
    \\  themes/journal/                   shipped "journal" theme — phosphor terminal diary
    \\  boris.json                        profile (theme: journal, layout_rules id:changes → archive)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the release notes (the draft renders, unadvertised)
    \\  boris plan --profile boris.json       inspect the normalized layout rules
    \\  boris check                           graph-health report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  each release is a satellite of changes with published_at + summary
    \\  the hub's {{children}} listing is id order: date-prefixed ids sort oldest first
    \\  status: draft renders at its route but stays out of search, RSS, sitemap, nav, and children
    \\  ship a release: set its real published_at and drop status: draft
    ,
};

const resume_spec = ArchetypeSpec{
    .layout_path = "themes/corporate/layouts/main.html",
    .files = &resume_files,
    .tree_report =
    \\  content/index.md                  trunk page — the whole CV
    \\  content/now.md                    one "what I'm doing now" satellite
    \\  themes/corporate/                 shipped "corporate" theme — dense product-docs chrome
    \\  boris.json                        profile (input_format: markdown, theme: corporate)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the CV, then print dist/index.html to PDF
    \\  boris check                           graph-health report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  {{metadata}} renders the page's status and tags; edit tags: to change the CV keywords
    \\  summary: and published_at: feed RSS and enabled head metadata, not the page body
    \\  the theme's @media print hides the header, navigation, and contents rail for paper
    ,
};

const newsletter_spec = ArchetypeSpec{
    .layout_path = "themes/press/layouts/main.html",
    .files = &newsletter_files,
    .tree_report =
    \\  content/index.md                  trunk page — the masthead
    \\  content/issues.md                 back-issue hub (archive layout)
    \\  content/issues/                   three dated issues (published_at + summary; blog layout)
    \\  themes/press/                     shipped "press" theme — editorial paper
    \\  boris.json                        profile (theme: press, layout_rules, head + rss + sitemap)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the paper, dist/feed.xml, and dist/sitemap.xml
    \\  boris plan --profile boris.json       inspect layout rules and the feed and sitemap declarations
    \\  boris check                           graph-health report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  an issue is a satellite of issues with published_at + summary; the date orders feeds
    \\  rss needs site.url, title, description, and an enabled head whose base_url equals site.url
    \\  status: draft issues stay out of the feed and sitemap; replace example.com before publishing
    ,
};

const portfolio_spec = ArchetypeSpec{
    .layout_path = "themes/showcase/layouts/main.html",
    .files = &portfolio_files,
    .tree_report =
    \\  content/index.md                  trunk page — the studio front (home layout lists the work)
    \\  content/about.md                  satellite page
    \\  content/projects/                 three project satellites (published_at + summary)
    \\  themes/showcase/                  shipped "showcase" theme — soft docs + blog shell
    \\  boris.json                        profile (theme: showcase, layout_rules id:index → home)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the portfolio (index renders through home.html)
    \\  boris plan --profile boris.json       inspect the normalized layout rules
    \\  boris check                           graph-health report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  a project is a satellite of index with published_at + summary; add one per piece of work
    \\  layout_rules pick named layouts by id:, glob:, or role:; every other page uses main.html
    \\  {{children}} lists a page's direct satellites; the home page's project list is never hand-kept
    ,
};

const archive_spec = ArchetypeSpec{
    .layout_path = "themes/archive/layouts/main.html",
    .files = &archive_files,
    .tree_report =
    \\  content/index.md                  trunk page — the archive index (archive layout)
    \\  content/topics.md                 hand-kept index by tag (Boris generates no tag pages)
    \\  content/entries/                  four tagged entries joined by relates_to / supersedes
    \\  themes/archive/                   shipped "archive" theme — ordered field-notes index
    \\  boris.json                        profile (theme: archive, layout_rules id:index → archive)
    ,
    .next_steps =
    \\  boris --profile boris.json                  build the archive (entries show relations and backlinks)
    \\  boris graph                                 render the relation web as Mermaid
    \\  boris impact entries/2019-ferry-timetable   what depends on the oldest record
    \\  boris check                                 graph-health report
    \\  boris watch --profile boris.json            rebuild on change
    ,
    .conventions =
    \\  tags: files an entry under subjects; keep topics.md in step by hand
    \\  relations: [relates_to=ID, supersedes=ID] are typed, validated edges; backlinks derive from them
    \\  status: archived keeps a record rendered and published but marks it no longer current
    ,
};

const dashboard_spec = ArchetypeSpec{
    .layout_path = "themes/engineering/layouts/main.html",
    .files = &dashboard_files,
    .tree_report =
    \\  content/index.md                  trunk page — the status board and the status vocabulary
    \\  content/projects/                 three projects, one per status (published, draft, archived)
    \\  themes/engineering/               shipped "engineering" theme — dense boxes and status labels
    \\  boris.json                        profile (theme: engineering, layout_rules id:index → home)
    ,
    .next_steps =
    \\  boris --profile boris.json                build the board (each project shows its status label)
    \\  boris impact projects/tide-gauge-network  what depends on the active project
    \\  boris check                               graph-health report
    \\  boris watch --profile boris.json          rebuild on change
    ,
    .conventions =
    \\  status: is the project state: published = active, draft = proposed, archived = retired
    \\  drafts render at their route but stay out of search, sitemap, feeds, and nav
    \\  relations: [depends_on=ID, supersedes=ID] cross-reference projects; backlinks derive from them
    ,
};

const photo_gallery_spec = ArchetypeSpec{
    .layout_path = "themes/gallery/layouts/main.html",
    .files = &photo_gallery_files,
    .tree_report =
    \\  content/index.md                  trunk page — the gallery front (home layout, album grid)
    \\  content/index.assets/             the front page's cover image
    \\  content/photos/                   two album satellites, each with its own <album>.assets/ images
    \\  themes/gallery/                   shipped "gallery" theme — gallery wall, mats, and labels
    \\  boris.json                        profile (theme: gallery, layout_rules id:index → home)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the gallery (images copy beside their pages)
    \\  boris check                           graph-health report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  a page owns the images in its sibling <stem>.assets/ folder; reference them as ![alt](<stem>.assets/file)
    \\  Boris copies and rewrites image URLs page-relative; it never resizes, so scale images first
    \\  wrap a Markdown image in <figure> with blank lines to caption it; raw <img src> is not checked
    ,
};

fn specFor(archetype: Archetype) *const ArchetypeSpec {
    return switch (archetype) {
        .docs => &docs_spec,
        .garden => &garden_spec,
        .cookbook => &cookbook_spec,
        .blog => &blog_spec,
        .textile => &textile_spec,
        .landing => &landing_spec,
        .wiki => &wiki_spec,
        .@"link-in-bio" => &link_in_bio_spec,
        .changelog => &changelog_spec,
        .@"resume" => &resume_spec,
        .newsletter => &newsletter_spec,
        .portfolio => &portfolio_spec,
        .archive => &archive_spec,
        .dashboard => &dashboard_spec,
        .@"photo-gallery" => &photo_gallery_spec,
    };
}

/// Create `sub_path` (including any missing parents) relative to `dir`,
/// tolerating an existing leaf directory. `Io.Dir.createDir` creates exactly
/// one level, so a nested target like `projects/site` needs the full-path
/// variant to build its parents.
fn createDirIfMissing(io: Io, dir: Io.Dir, sub_path: []const u8) !void {
    dir.createDirPath(io, sub_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Write the archetype's tree under `target_dir`, which must not exist yet
/// or must be empty. Returns an allocator-owned message on refusal so the
/// caller can explain the failure without guessing.
pub fn materialize(io: Io, gpa: std.mem.Allocator, target_dir: []const u8, archetype: Archetype) ![]const u8 {
    const spec = specFor(archetype);
    const cwd = Io.Dir.cwd();
    createDirIfMissing(io, cwd, target_dir) catch |err| {
        return std.fmt.allocPrint(gpa, "cannot create target directory: {s}", .{@errorName(err)});
    };
    var dir = try cwd.openDir(io, target_dir, .{ .iterate = true });
    defer dir.close(io);

    // Refuse to clobber an existing project. Empty is fine (a user may point
    // init at a fresh checkout).
    var it = dir.iterate();
    if (try it.next(io)) |_| {
        return gpa.dupe(u8, "target directory is not empty; refusing to overwrite an existing site");
    }

    // If any write fails midway (permission, disk, I/O), remove the partial
    // tree so the next invocation can retry without manual cleanup. Installed
    // only after the emptiness check: a refusal writes nothing and must never
    // delete user content.
    errdefer cwd.deleteTree(io, target_dir) catch {};

    // Parent directories are derived from the file table: `createDirPath`
    // builds every missing level, so no separate directory list can drift
    // out of sync with the files.
    for (spec.files) |f| {
        if (std.fs.path.dirname(f.path)) |parent| {
            try createDirIfMissing(io, dir, parent);
        }
        try dir.writeFile(io, .{ .sub_path = f.path, .data = f.data });
    }
    return "";
}

/// Compile the freshly materialized starter into a probe output directory,
/// then remove the probe tree. `init` writes a starter tree, not a built
/// site, so the probe output never survives a successful run.
///
/// All probe paths are derived relative to the process working directory,
/// even when `target_dir` was spelled absolute: layout paths are
/// contractually required to be clean relative paths
/// (`layout_select.validateLayoutPath`), and every generated probe path is
/// resolved against the workspace like any other output tree. A target
/// outside the workspace cannot host the probe at all; the caller is told so
/// it can report the skipped verification honestly instead of pretending.
///
/// The probe lives inside `target_dir` (which `init` owns: the directory was
/// empty before it ran), keeping every generated path inside the target like
/// any other output tree. A crashed probe can leave the directory non-empty,
/// which the next `init` refuses with its normal message — the same failure
/// shape as a crash during materialization.
pub const ProbeResult = union(enum) {
    /// Pages compiled from the starter tree.
    verified: usize,
    /// Target resolves outside the workspace; probe skipped (reported).
    skipped,
};

fn verifyStarter(io: Io, gpa: std.mem.Allocator, target_dir: []const u8, archetype: Archetype) !ProbeResult {
    const spec = specFor(archetype);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target_abs = try std.fs.path.resolve(gpa, &.{ cwd, target_dir });
    defer gpa.free(target_abs);
    const rel_target = try std.fs.path.relative(gpa, cwd, null, cwd, target_abs);
    defer gpa.free(rel_target);

    // Outside the workspace: the probe's output tree would violate the same
    // containment rule every other generated output obeys.
    if (std.mem.startsWith(u8, rel_target, "..")) return .skipped;

    // `init .` into a fresh empty cwd is legal (relative() then returns an
    // empty or "." path); path.join skips empty parts.
    const base: []const u8 = if (std.mem.eql(u8, rel_target, ".")) "" else rel_target;

    const content_root = try std.fs.path.join(gpa, &.{ base, "content" });
    defer gpa.free(content_root);
    // Layout paths obey a lexical grammar: workspace-relative, '/'-separated
    // (layout_select.validateLayoutPath). `base` is a native path spelling, so
    // on Windows it arrives with '\\' separators that the grammar rejects.
    const base_lexical = try gpa.dupe(u8, base);
    defer gpa.free(base_lexical);
    for (base_lexical) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    const layout_path = if (base_lexical.len == 0)
        try gpa.dupe(u8, spec.layout_path)
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_lexical, spec.layout_path });
    defer gpa.free(layout_path);
    const probe_dist = try std.fs.path.join(gpa, &.{ base, ".boris-init-probe" });
    defer gpa.free(probe_dist);

    errdefer Io.Dir.cwd().deleteTree(io, probe_dist) catch {};
    const stats = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content_root,
        .dist_dir = probe_dist,
        .layout_path = layout_path,
        .quiet = true,
        // The archetype's declared whole-tree format: the probe exercises
        // the same adapter the profile selects, so a drifting starter and
        // a drifting adapter fail here together.
        .input_format = spec.input_format,
    });
    Io.Dir.cwd().deleteTree(io, probe_dist) catch {};
    return .{ .verified = stats.pages_written };
}

pub fn run(io: Io, gpa: std.mem.Allocator, target_dir: []const u8, type_name: ?[]const u8, quiet: bool) u8 {
    const archetype: Archetype = if (type_name) |name|
        std.meta.stringToEnum(Archetype, name) orelse {
            std.debug.print(
                "error: unknown init type \"{s}\" (expected one of: {s})\n",
                .{ name, archetype_names },
            );
            return @backingInt(ExitCode.usage);
        }
    else
        .docs;
    const spec = specFor(archetype);

    const message = materialize(io, gpa, target_dir, archetype) catch |err| {
        std.debug.print("error: boris init failed: {s}\n", .{@errorName(err)});
        return @backingInt(ExitCode.io_error);
    };
    if (message.len > 0) {
        std.debug.print("error: {s}\n", .{message});
        gpa.free(message);
        return @backingInt(ExitCode.usage);
    }

    // Self-verify before claiming success. The starter tree is fixed, so a
    // probe failure means the binary and its starter templates disagree —
    // never ship that silently. Remove the whole tree (it was empty before
    // `init` ran) so exit 0 keeps meaning "materialized AND compiled".
    const outcome = verifyStarter(io, gpa, target_dir, archetype) catch |err| {
        Io.Dir.cwd().deleteTree(io, target_dir) catch {};
        std.debug.print(
            "error: the starter tree failed to compile ({s}); the target directory was removed — this is a compiler/starter drift bug, please report it\n",
            .{@errorName(err)},
        );
        return @backingInt(ExitCode.content_error);
    };

    if (!quiet) {
        std.debug.print(
            \\ok: initialized a Boris site in {s}
            \\  archetype: {s}
            \\{s}
            \\
            \\
        , .{ target_dir, @tagName(archetype), spec.tree_report });
        switch (outcome) {
            .verified => |pages| std.debug.print(
                "verified: starter compiled {d} page(s)\n\n",
                .{pages},
            ),
            .skipped => std.debug.print(
                "note: target directory resolves outside the workspace; skipped the starter compile probe\n\n",
                .{},
            ),
        }
        std.debug.print(
            \\next steps:
            \\{s}
            \\
        , .{spec.next_steps});
        if (spec.conventions.len > 0) {
            std.debug.print(
                \\conventions:
                \\{s}
                \\
            , .{spec.conventions});
        }
    }
    return @backingInt(ExitCode.success);
}

test "archetype names cover the CLI surface" {
    try std.testing.expectEqualStrings("docs, garden, cookbook, blog, textile, landing, wiki, link-in-bio, changelog, resume, newsletter, portfolio, archive, dashboard, photo-gallery", archetype_names);
    inline for (@typeInfo(Archetype).@"enum".field_values) |value| {
        const spec = specFor(@fromBackingInt(@intCast(value)));
        // Every archetype writes a profile and content, and its probe layout
        // is one of the files it writes.
        var has_profile = false;
        var has_layout = false;
        for (spec.files) |file| {
            if (std.mem.eql(u8, file.path, "boris.json")) has_profile = true;
            if (std.mem.eql(u8, file.path, spec.layout_path)) has_layout = true;
        }
        try std.testing.expect(has_profile);
        try std.testing.expect(has_layout);
    }
}

test "starter layout marks the search extraction root" {
    const marker = "<main class=\"site-body\" data-boris-search-root>";
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, starter_layout, idx, marker)) |at| {
        count += 1;
        idx = at + marker.len;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "starter layout carries the search client seams" {
    // These strings are the browser/compiler seam from the rendered-search
    // contract and the hooks the embedded client queries. If the starter and
    // the repo theme's search UI ever drift apart, this test names what went
    // missing instead of leaving a starter site with silent search.
    const layout_markers = [_][]const u8{
        "data-boris-search-ui",
        "data-boris-search-form",
        "data-boris-search-status",
        "data-boris-search-results",
        "_boris/search/search-index.json",
        "<noscript>",
        // The Standard.site contract requires the init reference layout to
        // include the closed {{head}} slot.
        "{{head}}",
    };
    for (layout_markers) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, starter_layout, marker) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, starter_layout, "data-boris-search-exclude") != null);
    try std.testing.expect(std.mem.indexOf(u8, starter_css, ".site-search") != null);
}

test "each archetype profile declares the format and theme its spec uses" {
    // The profile is the mechanism: `boris --profile boris.json` on a
    // materialized tree must select the same input_format and theme the
    // probe compiled with. Assert the agreement by construction here so a
    // spec/profile edit can never drift the two apart.
    const expect_format = [_][]const u8{ "markdown", "markdown", "cook", "markdown", "textile", "markdown", "markdown", "markdown", "markdown", "markdown", "markdown", "markdown", "markdown", "markdown", "markdown" };
    const expect_theme = [_][]const u8{ "themes/boris", "themes/ledger", "themes/cards", "themes/cozy", "themes/press", "themes/service", "themes/reference", "themes/minimal", "themes/journal", "themes/corporate", "themes/press", "themes/showcase", "themes/archive", "themes/engineering", "themes/gallery" };
    inline for (@typeInfo(Archetype).@"enum".field_values, 0..) |value, i| {
        const spec = specFor(@fromBackingInt(@intCast(value)));
        var profile: []const u8 = "";
        for (spec.files) |file| {
            if (std.mem.eql(u8, file.path, "boris.json")) profile = file.data;
        }
        const format_needle = "\"input_format\": \"" ++ expect_format[i] ++ "\"";
        const theme_needle = "\"theme\": \"" ++ expect_theme[i] ++ "\"";
        const fmt_ok = std.mem.indexOf(u8, profile, format_needle) != null or
            // `docs` is the historical profile byte-for-byte: it predates the
            // key and relies on markdown being the default.
            (i == 0 and std.mem.indexOf(u8, profile, "input_format") == null);
        try std.testing.expect(fmt_ok);
        try std.testing.expect(std.mem.indexOf(u8, profile, theme_needle) != null);
        // The probe layout lives under the declared theme root.
        try std.testing.expect(std.mem.startsWith(u8, spec.layout_path, expect_theme[i] ++ "/"));
        // The spec's input format matches the profile's declaration.
        const declared: identity.InputFormat = @fromBackingInt(@intCast(switch (i) {
            2 => @backingInt(identity.InputFormat.cook),
            4 => @backingInt(identity.InputFormat.textile),
            else => @backingInt(identity.InputFormat.markdown),
        }));
        try std.testing.expectEqual(declared, spec.input_format);
    }
}

fn writesFile(spec: *const ArchetypeSpec, path: []const u8) bool {
    for (spec.files) |f| {
        if (std.mem.eql(u8, f.path, path)) return true;
    }
    return false;
}

test "every profile layout rule and include directive names a written file" {
    // A `layout_rules` layout or `{{include}}` fragment the starter does not
    // write would only fail at `boris --profile boris.json`, after init has
    // already claimed success (the probe compiles with the fallback layout).
    inline for (@typeInfo(Archetype).@"enum".field_values) |value| {
        const spec = specFor(@fromBackingInt(@intCast(value)));
        for (spec.files) |f| {
            if (std.mem.eql(u8, f.path, "boris.json")) {
                const needle = "\"layout\": \"";
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, f.data, at, needle)) |start| {
                    const path_start = start + needle.len;
                    const path_end = std.mem.indexOfScalarPos(u8, f.data, path_start, '"').?;
                    try std.testing.expect(writesFile(spec, f.data[path_start..path_end]));
                    at = path_end;
                }
            }
            if (std.mem.startsWith(u8, f.path, "content/")) {
                const needle = "{{include ";
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, f.data, at, needle)) |start| {
                    const path_start = start + needle.len;
                    const path_end = std.mem.indexOfPos(u8, f.data, path_start, "}}").?;
                    var buf: [256]u8 = undefined;
                    const written = try std.fmt.bufPrint(&buf, "content/{s}", .{f.data[path_start..path_end]});
                    try std.testing.expect(writesFile(spec, written));
                    at = path_end;
                }
            }
        }
    }
}

test "starter theme docs only link to files the starter writes" {
    // Theme READMEs link to their siblings (ACCESSIBILITY.md, MIGRATION.md);
    // a starter that embeds the README but not the sibling ships a dead link.
    // Links leaving the theme (`../`), absolute URLs, anchors, and examples
    // inside fenced code are out of scope.
    inline for (@typeInfo(Archetype).@"enum".field_values) |value| {
        const spec = specFor(@fromBackingInt(@intCast(value)));
        for (spec.files) |f| {
            if (!std.mem.startsWith(u8, f.path, "themes/") or !std.mem.endsWith(u8, f.path, ".md")) continue;
            const dir = std.fs.path.dirname(f.path).?;
            var fenced = false;
            var lines = std.mem.splitScalar(u8, f.data, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) fenced = !fenced;
                if (fenced) continue;
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, line, at, "](")) |start| {
                    const target_start = start + 2;
                    const target_end = std.mem.indexOfAnyPos(u8, line, target_start, ")#") orelse line.len;
                    const target = line[target_start..target_end];
                    at = target_end;
                    if (target.len == 0 or std.mem.startsWith(u8, target, "../") or
                        std.mem.indexOf(u8, target, "://") != null or std.mem.startsWith(u8, target, "mailto:")) continue;
                    var buf: [256]u8 = undefined;
                    const written = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, target });
                    if (!writesFile(spec, written)) {
                        std.debug.print("{s} links to unwritten {s}\n", .{ f.path, written });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }
    }
}

test "landing is one trunk page composed from include fragments" {
    var pages: usize = 0;
    var trunks: usize = 0;
    for (landing_spec.files) |f| {
        if (std.mem.startsWith(u8, f.path, "content/") and !std.mem.startsWith(u8, f.path, "content/includes/")) {
            pages += 1;
            if (std.mem.indexOf(u8, f.data, "\nparent: ") == null) trunks += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), pages);
    try std.testing.expectEqual(@as(usize, 1), trunks);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, landing_index_md, "{{include includes/"));
    try std.testing.expect(std.mem.indexOf(u8, landing_profile, "\"selector\": \"id:index\", \"layout\": \"themes/service/layouts/home.html\"") != null);
}

test "wiki entries sit three levels deep under their hub" {
    var entries: usize = 0;
    for (wiki_spec.files) |f| {
        const prefix = "content/wiki/";
        if (!std.mem.startsWith(u8, f.path, prefix)) continue;
        const rest = f.path[prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            // content/wiki/<hub>/<entry>.md declares `parent: wiki/<hub>`.
            var buf: [64]u8 = undefined;
            const want = try std.fmt.bufPrint(&buf, "\nparent: wiki/{s}\n", .{rest[0..slash]});
            try std.testing.expect(std.mem.indexOf(u8, f.data, want) != null);
            try std.testing.expect(std.mem.indexOf(u8, f.data, "\n## ") != null);
            entries += 1;
        } else {
            try std.testing.expect(std.mem.indexOf(u8, f.data, "\nparent: index\n") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), entries);
    // One glob rule only: a second glob with the same literal-segment count
    // would be a selector tie (templating-and-themes.md §4.2).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, wiki_profile, "\"glob:"));
    try std.testing.expect(std.mem.indexOf(u8, wiki_sharpening_md, "relations: [relates_to=wiki/tools/chisels]") != null);
}

test "link-in-bio is exactly one trunk page" {
    var pages: usize = 0;
    for (link_in_bio_spec.files) |f| {
        if (std.mem.startsWith(u8, f.path, "content/")) pages += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pages);
    try std.testing.expect(std.mem.indexOf(u8, link_in_bio_index_md, "\nparent:") == null);
    try std.testing.expect(std.mem.indexOf(u8, link_in_bio_index_md, "\ntags: [links]\n") != null);
}

test "changelog entries are dated and exactly one is a draft" {
    var entries: usize = 0;
    var drafts: usize = 0;
    for (changelog_spec.files) |f| {
        if (!std.mem.startsWith(u8, f.path, "content/changes/")) continue;
        try std.testing.expect(std.mem.indexOf(u8, f.data, "\nparent: changes\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, f.data, "\npublished_at: 2026-") != null);
        try std.testing.expect(std.mem.indexOf(u8, f.data, "\nsummary: ") != null);
        if (std.mem.indexOf(u8, f.data, "\nstatus: draft\n") != null) drafts += 1;
        entries += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), entries);
    try std.testing.expectEqual(@as(usize, 1), drafts);
    try std.testing.expect(std.mem.indexOf(u8, changelog_unreleased_md, "\nstatus: draft\n") != null);
    // Drafts leave {{children}}, so the hub links the draft by hand.
    try std.testing.expect(std.mem.indexOf(u8, changelog_changes_md, "[[changes/unreleased]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, changelog_profile, "\"selector\": \"id:changes\", \"layout\": \"themes/journal/layouts/archive.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archetype_themes.journal_layout_archive, "{{children}}") != null);
}

test "resume is one CV page with metadata-bearing frontmatter and a print stylesheet" {
    for ([_][]const u8{ "\ntags: [", "\npublished_at: 2026-", "\nsummary: " }) |key| {
        try std.testing.expect(std.mem.indexOf(u8, resume_index_md, key) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, resume_now_md, "\nparent: index\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, archetype_themes.corporate_layout_main, "{{metadata}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, archetype_themes.corporate_css, "@media print") != null);
}

test "newsletter issues are dated and the profile declares an rss feed riding an enabled head" {
    var issues: usize = 0;
    for (newsletter_spec.files) |f| {
        if (!std.mem.startsWith(u8, f.path, "content/issues/")) continue;
        for ([_][]const u8{ "\nparent: issues\n", "\npublished_at: 2026-", "\nsummary: " }) |key| {
            try std.testing.expect(std.mem.indexOf(u8, f.data, key) != null);
        }
        issues += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), issues);
    try std.testing.expect(std.mem.indexOf(u8, newsletter_profile, "\"url\": \"https://") != null);
    try std.testing.expect(std.mem.indexOf(u8, newsletter_profile, "\"sitemap\": { \"path\": \"sitemap.xml\" }") != null);
    // The single-target RSS rider (head-metadata.md) needs an enabled head
    // whose base equals site.url, and exactly one {{head}} in every layout a
    // page can select.
    try std.testing.expect(std.mem.indexOf(u8, newsletter_profile, "\"rss\": { \"path\": \"feed.xml\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, newsletter_profile, "\"head\": { \"enabled\": true, \"base_url\": \"https://saturday-sheet.example.com/\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, newsletter_profile, "\"url\": \"https://saturday-sheet.example.com/\"") != null);
    for ([_][]const u8{ archetype_themes.press_layout_main, archetype_themes.press_layout_home, archetype_themes.press_layout_archive, archetype_themes.press_layout_blog, archetype_themes.press_layout_section }) |layout| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, layout, "{{head}}"));
    }
}

test "portfolio projects are dated satellites of index and one carries a relation" {
    var projects: usize = 0;
    var related: usize = 0;
    for (portfolio_spec.files) |f| {
        if (!std.mem.startsWith(u8, f.path, "content/projects/")) continue;
        for ([_][]const u8{ "\nparent: index\n", "\npublished_at: 2026-", "\nsummary: " }) |key| {
            try std.testing.expect(std.mem.indexOf(u8, f.data, key) != null);
        }
        if (std.mem.indexOf(u8, f.data, "\nrelations: [") != null) related += 1;
        projects += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), projects);
    try std.testing.expectEqual(@as(usize, 1), related);
    try std.testing.expect(std.mem.indexOf(u8, portfolio_profile, "\"selector\": \"id:index\", \"layout\": \"themes/showcase/layouts/home.html\"") != null);
    // The home layout lists the work; the index keeps no hand-written copy.
    try std.testing.expect(std.mem.indexOf(u8, archetype_themes.showcase_layout_home, "{{children}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, portfolio_index_md, "[[projects/") == null);
}

test "archive entries share tags and relations give every entry backlinks or relations" {
    var entries: usize = 0;
    var supersedes: usize = 0;
    var archived: usize = 0;
    for (archive_spec.files) |f| {
        if (!std.mem.startsWith(u8, f.path, "content/entries/")) continue;
        try std.testing.expect(std.mem.indexOf(u8, f.data, "\nparent: index\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, f.data, "\ntags: [") != null);
        if (std.mem.indexOf(u8, f.data, "supersedes=") != null) supersedes += 1;
        if (std.mem.indexOf(u8, f.data, "\nstatus: archived\n") != null) archived += 1;
        // Every entry is a relation source or target, so {{relations}} or
        // {{backlinks}} has real content on every entry page.
        const stem = f.path["content/".len .. f.path.len - ".md".len];
        var targeted = false;
        for (archive_spec.files) |g| {
            if (!std.mem.startsWith(u8, g.path, "content/entries/")) continue;
            var buf: [96]u8 = undefined;
            if (std.mem.indexOf(u8, g.data, try std.fmt.bufPrint(&buf, "={s}", .{stem})) != null) targeted = true;
        }
        try std.testing.expect(targeted or std.mem.indexOf(u8, f.data, "\nrelations: [") != null);
        entries += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), entries);
    try std.testing.expectEqual(@as(usize, 1), supersedes);
    try std.testing.expectEqual(@as(usize, 1), archived);
    try std.testing.expect(std.mem.indexOf(u8, archive_profile, "\"selector\": \"id:index\", \"layout\": \"themes/archive/layouts/archive.html\"") != null);
    for ([_][]const u8{ archetype_themes.archive_layout_main, archetype_themes.archive_layout_archive }) |layout| {
        try std.testing.expect(std.mem.indexOf(u8, layout, "{{relations}}{{backlinks}}") != null);
    }
}

test "dashboard has one project per status value and documents the mapping" {
    var seen = [_]bool{ false, false, false };
    const values = [_][]const u8{ "published", "draft", "archived" };
    for (dashboard_spec.files) |f| {
        if (!std.mem.startsWith(u8, f.path, "content/projects/")) continue;
        try std.testing.expect(std.mem.indexOf(u8, f.data, "\nparent: index\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, f.data, "## Status history") != null);
        for (values, 0..) |v, i| {
            var buf: [32]u8 = undefined;
            if (std.mem.indexOf(u8, f.data, try std.fmt.bufPrint(&buf, "\nstatus: {s}\n", .{v})) != null) seen[i] = true;
        }
    }
    for (seen) |s| try std.testing.expect(s);
    // The board names every value and the project state it stands for.
    for ([_][]const u8{ "| `published` | Active", "| `draft` | Proposed", "| `archived` | Retired" }) |row| {
        try std.testing.expect(std.mem.indexOf(u8, dashboard_index_md, row) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, dashboard_profile, "\"selector\": \"id:index\", \"layout\": \"themes/engineering/layouts/home.html\"") != null);
    // Status is legible only because every engineering layout carries it.
    for ([_][]const u8{ archetype_themes.engineering_layout_main, archetype_themes.engineering_layout_home }) |layout| {
        try std.testing.expect(std.mem.indexOf(u8, layout, "data-status=\"{{page-status}}\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, layout, "{{metadata}}") != null);
    }
}

test "photo-gallery albums embed images from their own assets folders" {
    var albums: usize = 0;
    var images: usize = 0;
    for (photo_gallery_spec.files) |f| {
        if (!std.mem.startsWith(u8, f.path, "content/") or !std.mem.endsWith(u8, f.path, ".md")) continue;
        const stem_path = f.path[0 .. f.path.len - ".md".len];
        const stem = std.fs.path.basename(stem_path);
        if (std.mem.startsWith(u8, f.path, "content/photos/")) {
            try std.testing.expect(std.mem.indexOf(u8, f.data, "\nparent: index\n") != null);
            albums += 1;
        }
        // Every Markdown image names this page's own `{stem}.assets/` file,
        // and the starter writes that file.
        var at: usize = 0;
        var page_images: usize = 0;
        while (std.mem.indexOfPos(u8, f.data, at, "![")) |start| {
            const dest_start = std.mem.indexOfPos(u8, f.data, start, "](").? + 2;
            const dest_end = std.mem.indexOfScalarPos(u8, f.data, dest_start, ')').?;
            at = dest_end;
            const dest = f.data[dest_start..dest_end];
            var want: [64]u8 = undefined;
            try std.testing.expect(std.mem.startsWith(u8, dest, try std.fmt.bufPrint(&want, "{s}.assets/", .{stem})));
            var buf: [128]u8 = undefined;
            try std.testing.expect(writesFile(&photo_gallery_spec, try std.fmt.bufPrint(&buf, "{s}/{s}", .{ std.fs.path.dirname(f.path).?, dest })));
            page_images += 1;
        }
        try std.testing.expect(page_images >= 1);
        images += page_images;
    }
    try std.testing.expectEqual(@as(usize, 2), albums);
    try std.testing.expectEqual(@as(usize, 5), images);
    // Images stay small: the starter is embedded in the binary.
    var bytes: usize = 0;
    for (photo_gallery_spec.files) |f| {
        if (std.mem.endsWith(u8, f.path, ".png")) {
            try std.testing.expect(std.mem.startsWith(u8, f.data, "\x89PNG\r\n\x1a\n"));
            bytes += f.data.len;
        }
    }
    try std.testing.expect(bytes < 32 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, photo_gallery_profile, "\"selector\": \"id:index\", \"layout\": \"themes/gallery/layouts/home.html\"") != null);
}

test "garden demonstrates include composition, components, and dense links" {
    // The seams a cold-start agent cannot guess: `{{include}}`, `<Aside>`,
    // and wiki links. If a template edit drops one, this test names it.
    try std.testing.expect(std.mem.indexOf(u8, garden_composition_md, "{{include includes/house-style.md}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, garden_composition_md, "{{include includes/link-roll.md}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, garden_index_md, "<Aside kind=\"tip\"") != null);
    for (garden_spec.files) |f| {
        if (std.mem.eql(u8, f.path, "content/includes/house-style.md")) {
            try std.testing.expect(std.mem.indexOf(u8, f.data, "[[notes/composition]]") != null);
        }
    }
    // Every include directive resolves to a written fragment file.
    for ([_][]const u8{ "content/includes/house-style.md", "content/includes/link-roll.md" }) |frag| {
        var found = false;
        for (garden_spec.files) |f| {
            if (std.mem.eql(u8, f.path, frag)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "cookbook exercises the Cooklang constructs and names recipe-scale" {
    for (cookbook_spec.files) |f| {
        if (std.mem.startsWith(u8, f.path, "content/")) {
            try std.testing.expect(std.mem.endsWith(u8, f.path, ".cook"));
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, cookbook_carbonara_cook, "servings: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookbook_carbonara_cook, "@./sauces/pepper-oil{1%tbsp}") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookbook_index_cook, "recipe-scale") != null);
    // Every recipe is a direct satellite of index, so the home deck lists it.
    for (cookbook_spec.files) |f| {
        if (std.mem.startsWith(u8, f.path, "content/") and !std.mem.eql(u8, f.path, "content/index.cook")) {
            try std.testing.expect(std.mem.indexOf(u8, f.data, "\nparent: index\n") != null);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, cookbook_profile, "\"selector\": \"id:index\", \"layout\": \"themes/cards/layouts/home.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archetype_themes.cards_layout_home, "{{children}}") != null);
}

test "blog posts carry the dated-post frontmatter pair" {
    var dated: usize = 0;
    for (blog_spec.files) |f| {
        if (std.mem.startsWith(u8, f.path, "content/posts/")) {
            try std.testing.expect(std.mem.indexOf(u8, f.data, "published_at:") != null);
            try std.testing.expect(std.mem.indexOf(u8, f.data, "summary:") != null);
            try std.testing.expect(std.mem.indexOf(u8, f.data, "parent: posts") != null);
            dated += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), dated);
}

test "textile pages stay inside the adapter's closed subset" {
    for (textile_spec.files) |f| {
        if (std.mem.startsWith(u8, f.path, "content/")) {
            try std.testing.expect(std.mem.endsWith(u8, f.path, ".textile"));
            // The adapter refuses Boris's Markdown-only authoring syntax;
            // guard the sources so a template edit fails here, not at init.
            try std.testing.expect(std.mem.indexOf(u8, f.data, "{{include") == null);
            try std.testing.expect(std.mem.indexOf(u8, f.data, "[[") == null);
            try std.testing.expect(std.mem.indexOf(u8, f.data, "<Aside") == null);
        }
    }
}

test "materialized starter compiles and the probe cleans up after itself" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const refused = try materialize(io, gpa, root, .docs);
    defer if (refused.len > 0) gpa.free(refused);
    try std.testing.expectEqual(@as(usize, 0), refused.len);

    // The production probe path: the fixed starter tree must compile, and the
    // probe output must be gone again afterwards.
    const outcome = try verifyStarter(io, gpa, root, .docs);
    try std.testing.expectEqual(@as(usize, 3), outcome.verified);

    const probe_dist = try std.fmt.allocPrint(gpa, "{s}/.boris-init-probe", .{root});
    defer gpa.free(probe_dist);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openDir(io, probe_dist, .{}));

    // The black-box script inits with an absolute target inside the
    // workspace; the probe must still find clean relative layout paths there.
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const abs_root = try std.fs.path.resolve(gpa, &.{ cwd, root });
    defer gpa.free(abs_root);
    const abs_outcome = try verifyStarter(io, gpa, abs_root, .docs);
    try std.testing.expectEqual(@as(usize, 3), abs_outcome.verified);

    // A target outside the workspace cannot host the probe (the containment
    // rule every generated output obeys); it must be skipped, not failed.
    const outside = try std.fs.path.resolve(gpa, &.{ cwd, "../../boris-init-outside" });
    defer gpa.free(outside);
    const skip = try verifyStarter(io, gpa, outside, .docs);
    try std.testing.expect(skip == .skipped);

    // One real compile to lock the rendered seams: the search index artifact
    // exists and a rendered page carries the search UI from the starter theme.
    const content_root = try std.fmt.allocPrint(gpa, "{s}/content", .{root});
    defer gpa.free(content_root);
    const layout_path = try std.fmt.allocPrint(gpa, "{s}/themes/boris/layouts/main.html", .{root});
    defer gpa.free(layout_path);
    const dist = try std.fmt.allocPrint(gpa, "{s}/.init-test-dist", .{root});
    defer gpa.free(dist);
    _ = try compile.compileHtmlSite(io, gpa, .{
        .content_root = content_root,
        .dist_dir = dist,
        .layout_path = layout_path,
        .quiet = true,
    });
    var dist_dir = try Io.Dir.cwd().openDir(io, dist, .{});
    defer dist_dir.close(io);
    _ = try dist_dir.statFile(io, "_boris/search/search-index.json", .{});
    const index_html = blk: {
        var file = try dist_dir.openFile(io, "index.html", .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        break :blk try reader.interface.allocRemaining(gpa, .unlimited);
    };
    defer gpa.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "data-boris-search-ui") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "_boris/search/search-index.json") != null);
}

test "every archetype materializes and compiles through its declared adapter" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (@typeInfo(Archetype).@"enum".field_values, 0..) |value, i| {
        const archetype: Archetype = @fromBackingInt(@intCast(value));
        const spec = specFor(archetype);
        const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, @typeInfo(Archetype).@"enum".field_names[i] });
        defer gpa.free(root);
        const refused = try materialize(io, gpa, root, archetype);
        defer if (refused.len > 0) gpa.free(refused);
        try std.testing.expectEqual(@as(usize, 0), refused.len);

        // Exit-0's real postcondition, per archetype: the tree compiles in
        // the input format its own profile declares, and the probe tree is
        // gone afterwards.
        const outcome = try verifyStarter(io, gpa, root, archetype);
        var content_pages: usize = 0;
        for (spec.files) |file| {
            if (std.mem.startsWith(u8, file.path, "content/") and
                !std.mem.startsWith(u8, file.path, "content/includes/") and
                std.mem.indexOf(u8, file.path, ".assets/") == null)
            {
                content_pages += 1;
            }
        }
        try std.testing.expectEqual(content_pages, outcome.verified);
    }
}
