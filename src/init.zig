//! `boris init`: materialize a deterministic starter site and prove it compiles.
//!
//! `boris init [DIR] [--type NAME]` writes a fixed starter tree selected by
//! `--type` (default `docs`):
//!
//! - `docs`     — Markdown documentation tree: trunk/satellite graph, wiki
//!   links, a semantic relation, the catalog `boris` theme (whose layout
//!   ships the browser search client), and both publication profiles.
//!   Until #1063 it embedded a private two-file starter theme from
//!   `src/init_templates/`. That theme had no `{{relations}}`,
//!   `{{backlinks}}`, `{{children}}`, or `{{metadata}}`, so the starter's
//!   own index promised a semantic relation its theme could not show, and
//!   it drifted from every catalog `boris` fix (slot adoption, the a11y
//!   floor, the #1049 visual pass, the search-title marker). `docs` now
//!   embeds `themes/boris` like every sibling embeds its theme. The cost:
//!   it no longer writes the historical starter bytes.
//! - `garden`  — a flat-ish digital garden: dense `[[wiki-links]]`,
//!   semantic relations, `{{include}}` composition from `content/includes/`,
//!   and a registered `<Aside>` component, under the shipped `ledger` theme.
//! - `cookbook` — a `.cook` Cooklang recipe box (ingredients, cookware,
//!   timers, sub-recipe references, `servings`) under `cards`, whose
//!   profile declares `input_format: cook`; `layout_rules` send `id:index`
//!   to `home.html`, whose `{{children}}` deck shows each recipe as a card.
//! - `blog`    — dated posts on a parent chain (`index` → `posts` → dated
//!   entries with `published_at` + `summary`, plus one `status: draft` post
//!   held back from feeds, sitemap, search, and navigation) under `cozy`;
//!   the profile enables `head` and declares `rss` (`feed.xml`) plus
//!   `sitemap` (`sitemap.xml`), so the first build ships a feed with head
//!   autodiscovery.
//! - `textile` — `.textile` pages through the native adapter under `press`,
//!   whose profile declares `input_format: textile`.
//! - `photo-gallery` — a trunk front page and two `photos/` album
//!   satellites under `gallery`, each page carrying small PNG plates in its
//!   own `{stem}.assets/` folder inside `<figure>` captions; `layout_rules`
//!   send `id:index` to `home.html`, whose `{{children}}` is the album grid.
//!   The images are content, so they embed straight from the
//!   `examples/gallery-site` specimen via the `init_example_assets` module.
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
const example_assets = @import("init_example_assets");
const Io = std.Io;

const ExitCode = diagnostic.ExitCode;

/// Starter archetypes accepted by `--type`. `docs` is the default.
pub const Archetype = enum { docs, garden, cookbook, blog, textile, @"photo-gallery" };

/// Comptime-joined `docs, garden, cookbook, …` for diagnostics and help
/// text — the table below is the single source of truth.
pub const archetype_names: []const u8 = blk: {
    var names: []const u8 = "";
    for (@typeInfo(Archetype).@"enum".field_names, 0..) |name, i| {
        names = names ++ (if (i == 0) "" else ", ") ++ name;
    }
    break :blk names;
};

// --- docs (default) ---------------------------------------------------------

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
    \\themes/boris/                 the catalog boris theme (graph slots, search UI)
    \\boris.json                    publication profile (GitHub Pages)
    \\standard-site.json            Atmosphere profile (edit the fake DID/URL)
    \\```
    \\
    \\The theme renders the graph, not just the prose: tags in the page
    \\header, this page's satellites under "In this section", and the
    \\relation at the foot of [[guides/publishing]] ("Related") and of
    \\[[guides/getting-started]] ("Linked from").
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
    \\[[guides/getting-started]] so the semantic graph has an edge to inspect:
    \\the theme lists it below this page under "Related", and Getting
    \\Started lists this page under "Linked from".
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
    \\Every profile build emits `feed.xml` and `sitemap.xml` alongside the
    \\HTML tree. The feed rides on the target's enabled `head`, so every
    \\non-draft page carries a feed autodiscovery link in `<head>` while
    \\`status: draft` posts stay held back from the feed, sitemap, search
    \\index, and navigation.
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
    \\Work in progress (held back by `status: draft`, so it renders at its
    \\route without entering `feed.xml`, `sitemap.xml`, search, or
    \\`{{children}}`): [[posts/2026-10-12-in-progress]].
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

const blog_post_draft_md =
    \\---
    \\title: In Progress
    \\parent: posts
    \\published_at: 2026-10-12T09:00:00Z
    \\summary: A draft post held back from feeds, sitemap, search, and navigation.
    \\tags: [notes]
    \\status: draft
    \\---
    \\
    \\# In Progress
    \\
    \\A post marked `status: draft` still renders at its route so you can
    \\preview it locally, while staying out of `feed.xml`, `sitemap.xml`,
    \\the search index, and `{{nav}}` / `{{children}}` listings. Remove
    \\`status: draft` when it is ready to publish.
    \\
    \\Back to [[posts]].
    \\
;

const blog_profile =
    \\{
    \\  "format": "boris-publication-profile",
    \\  "schema_version": 1,
    \\  "input": "content",
    \\  "input_format": "markdown",
    \\  "site": {
    \\    "title": "The Corner",
    \\    "url": "https://the-corner.example.com/",
    \\    "description": "A small personal site of dated posts."
    \\  },
    \\  "targets": [
    \\    {
    \\      "name": "public",
    \\      "output": "dist",
    \\      "public": true,
    \\      "theme": "themes/cozy",
    \\      "head": { "enabled": true, "base_url": "https://the-corner.example.com/" },
    \\      "rss": { "path": "feed.xml" },
    \\      "sitemap": { "path": "sitemap.xml" }
    \\    }
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

// --- photo-gallery ----------------------------------------------------------

// Starter images are content, not theme assets, so they embed straight from
// the examples/gallery-site specimen through the init_example_assets module
// (#1084 — single source of truth; provenance and SHA-256 in
// examples/gallery-site/README.md).
const photo_gallery_tidewater_png = example_assets.gallery_tidewater_png;
const photo_gallery_dawn_png = example_assets.gallery_dawn_png;
const photo_gallery_dusk_png = example_assets.gallery_dusk_png;
const photo_gallery_ridge_png = example_assets.gallery_ridge_png;
const photo_gallery_pines_png = example_assets.gallery_pines_png;

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
    .{ .path = "themes/boris/layouts/main.html", .data = archetype_themes.boris_layout_main },
    .{ .path = "themes/boris/footer.html", .data = archetype_themes.boris_footer },
    .{ .path = "themes/boris/assets/css/boris.css", .data = archetype_themes.boris_css },
    .{ .path = "themes/boris/README.md", .data = archetype_themes.boris_readme },
    .{ .path = "themes/boris/ACCESSIBILITY.md", .data = archetype_themes.boris_accessibility },
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
    .{ .path = "content/posts/2026-10-12-in-progress.md", .data = blog_post_draft_md },
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
    \\  themes/boris/                     the catalog "boris" theme: relations, backlinks, search UI
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
    \\  themes/boris/ is your copy: its layout's brand line and footer.html still say "Boris"
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
    \\  content/posts/                    three dated posts plus one status: draft post
    \\  themes/cozy/                      shipped "cozy" theme — mid-2000s personal blog
    \\  boris.json                        profile (theme: cozy, enabled head + rss feed.xml + sitemap.xml)
    ,
    .next_steps =
    \\  boris --profile boris.json            build the site, dist/feed.xml, and dist/sitemap.xml
    \\  boris check                           graph-health report
    \\  boris impact posts                    dependency impact report
    \\  boris watch --profile boris.json      rebuild on change
    ,
    .conventions =
    \\  parent: posts is what makes a dated file a post — the chain index → posts → post is the graph
    \\  published_at needs summary (and a UTC date); status: draft renders locally but stays out of feeds, sitemap, search, and nav
    \\  replace site.url and head.base_url in boris.json with your own domain before publishing
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

/// Name of the per-target claim file `init` creates with exclusive create
/// before checking that the target is empty. Two racing `init` runs cannot
/// both hold it, so the holder's failure cleanup never deletes a sibling
/// run's files. A crash can leave it behind; that makes the directory
/// non-empty, which the next `init` refuses like any other partial tree.
const claim_file_name = ".boris-init.lock";

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

    // Claim the target before checking it: a bare emptiness check is
    // check-then-act, so two concurrent `init` runs could both pass it and a
    // later failure would delete the shared tree — including the other run's
    // half-written files. Exclusive create gives exactly one run the claim;
    // everything it cleans up afterwards is its own.
    var claim = dir.createFile(io, claim_file_name, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return std.fmt.allocPrint(
            gpa,
            "target directory contains {s} — another boris init is running there or a previous one was interrupted; remove that file to retry",
            .{claim_file_name},
        ),
        else => return err,
    };
    defer {
        claim.close(io);
        dir.deleteFile(io, claim_file_name) catch {};
    }

    // Refuse to clobber an existing project. Empty is fine (a user may point
    // init at a fresh checkout); the claim file above is ours.
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, claim_file_name)) continue;
        return gpa.dupe(u8, "target directory is not empty; refusing to overwrite an existing site");
    }

    // If any write fails midway (permission, disk, I/O), remove the partial
    // tree so the next invocation can retry without manual cleanup. Installed
    // only after the emptiness check: a refusal writes nothing and must never
    // delete user content. The claim means this tree is this run's alone — a
    // concurrent `init` refused above and wrote nothing here.
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
    // never ship that silently. Remove the whole tree — the materialize claim
    // guaranteed this run was its only writer — so exit 0 keeps meaning
    // "materialized AND compiled".
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
    try std.testing.expectEqualStrings("docs, garden, cookbook, blog, textile, photo-gallery", archetype_names);
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

test "docs starter layout marks the search extraction root" {
    const layout = archetype_themes.boris_layout_main;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, layout, "data-boris-search-root"));
    try std.testing.expect(std.mem.indexOf(u8, layout, "<main id=\"main-content\" tabindex=\"-1\" data-boris-search-root>") != null);
}

test "docs starter layout carries the search client seams and graph slots" {
    // These strings are the browser/compiler seam from the rendered-search
    // contract and the hooks the embedded client queries. The docs starter
    // advertises search ("Press `/` on any page") and a visible relation, so
    // if the catalog `boris` layout ever drops either, this test names what
    // went missing instead of shipping a starter whose prose lies.
    const starter_layout = archetype_themes.boris_layout_main;
    const starter_css = archetype_themes.boris_css;
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
        "event.key === \"/\"",
        "{{metadata}}",
        "{{children}}",
        "{{relations}}",
        "{{backlinks}}",
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
    const expect_format = [_][]const u8{ "markdown", "markdown", "cook", "markdown", "textile", "markdown" };
    const expect_theme = [_][]const u8{ "themes/boris", "themes/ledger", "themes/cards", "themes/cozy", "themes/press", "themes/gallery" };
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

test "blog posts are dated with one draft and a profile declaring head + rss + sitemap" {
    var dated: usize = 0;
    var drafts: usize = 0;
    for (blog_spec.files) |f| {
        if (std.mem.startsWith(u8, f.path, "content/posts/")) {
            try std.testing.expect(std.mem.indexOf(u8, f.data, "published_at:") != null);
            try std.testing.expect(std.mem.indexOf(u8, f.data, "summary:") != null);
            try std.testing.expect(std.mem.indexOf(u8, f.data, "parent: posts") != null);
            if (std.mem.indexOf(u8, f.data, "\nstatus: draft\n") != null) drafts += 1;
            dated += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), dated);
    try std.testing.expectEqual(@as(usize, 1), drafts);
    try std.testing.expect(std.mem.indexOf(u8, blog_posts_md, "[[posts/2026-10-12-in-progress]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, blog_profile, "\"url\": \"https://the-corner.example.com/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, blog_profile, "\"head\": { \"enabled\": true, \"base_url\": \"https://the-corner.example.com/\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, blog_profile, "\"rss\": { \"path\": \"feed.xml\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, blog_profile, "\"sitemap\": { \"path\": \"sitemap.xml\" }") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, archetype_themes.cozy_layout_main, "{{head}}"));
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
    // exists, a rendered page carries the search UI from the starter theme,
    // and the starter's one relation is visible on both of its ends.
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
    try std.testing.expect(std.mem.indexOf(u8, index_html, "<nav class=\"page-children\"") != null);
    const ends = [_][2][]const u8{
        .{ "guides/publishing.html", "<section class=\"semantic-relations\"" },
        .{ "guides/getting-started.html", "<section class=\"semantic-backlinks\"" },
    };
    for (ends) |end| {
        const html = blk: {
            var file = try dist_dir.openFile(io, end[0], .{});
            defer file.close(io);
            var reader = file.reader(io, &.{});
            break :blk try reader.interface.allocRemaining(gpa, .unlimited);
        };
        defer gpa.free(html);
        const at = std.mem.indexOf(u8, html, end[1]) orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOfPos(u8, html, at, "data-relation-kind=\"relates_to\"") != null);
    }
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

test "materialize refuses a claimed target and leaves the claim untouched" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A sibling run's claim — live or left by an interrupted run — must stop
    // this run before it writes anything, and must not be deleted: it is not
    // this run's to remove.
    try tmp.dir.createDirPath(io, "claimed");
    var marker = try tmp.dir.createFile(io, "claimed/" ++ claim_file_name, .{});
    marker.close(io);

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/claimed", .{tmp.sub_path});
    defer gpa.free(root);
    const refused = try materialize(io, gpa, root, .docs);
    defer gpa.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, claim_file_name) != null);

    var dir = try tmp.dir.openDir(io, "claimed", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    const entry = (try it.next(io)).?;
    try std.testing.expectEqualStrings(claim_file_name, entry.name);
    try std.testing.expect((try it.next(io)) == null);
}

test "materialize refusal leaves no claim file in an occupied target" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "occupied");
    var keep = try tmp.dir.createFile(io, "occupied/keep.txt", .{});
    keep.close(io);

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/occupied", .{tmp.sub_path});
    defer gpa.free(root);
    const refused = try materialize(io, gpa, root, .docs);
    defer gpa.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "not empty") != null);

    // The claim this run took to discover the refusal is cleaned up again:
    // the directory holds exactly what the user had there.
    var dir = try tmp.dir.openDir(io, "occupied", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    const entry = (try it.next(io)).?;
    try std.testing.expectEqualStrings("keep.txt", entry.name);
    try std.testing.expect((try it.next(io)) == null);
}

test "concurrent materialize on one target: at most one run writes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/raced", .{tmp.sub_path});
    defer gpa.free(root);

    // Two runs on the same empty target. The claim makes the interleaving
    // safe however the threads schedule: the loser either fails the
    // exclusive create or finds the winner's tree non-empty, so it refuses
    // without writing — and the winner's tree is its own to keep or clean.
    var results: [2][]const u8 = .{ "", "" };
    var threads: [2]std.Thread = undefined;
    for (0..2) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn go(run_io: Io, run_gpa: std.mem.Allocator, dir_path: []const u8, out: *[]const u8) void {
                out.* = materialize(run_io, run_gpa, dir_path, .docs) catch "";
            }
        }.go, .{ io, gpa, root, &results[i] });
    }
    for (&threads) |*t| t.join();
    defer for (results) |r| {
        if (r.len > 0) gpa.free(r);
    };

    var successes: usize = 0;
    for (results) |r| successes += @intFromBool(r.len == 0);
    try std.testing.expect(successes <= 1);
    if (successes == 1) {
        // The winner's tree is complete and its claim is gone.
        _ = try tmp.dir.statFile(io, "raced/boris.json", .{});
        try std.testing.expectError(
            error.FileNotFound,
            tmp.dir.statFile(io, "raced/" ++ claim_file_name, .{}),
        );
    } else {
        // Both refused or failed: the target is untouched, not half-written.
        var dir = tmp.dir.openDir(io, "raced", .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        try std.testing.expect((try it.next(io)) == null);
    }
}
