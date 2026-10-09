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
//!   profile declares `input_format: cook`.
//! - `blog`    — dated posts on a parent chain (`index` → `posts` → dated
//!   entries with `published_at` + `summary`) under the `cozy` theme.
//! - `textile` — `.textile` pages through the native adapter under `press`,
//!   whose profile declares `input_format: textile`.
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
pub const Archetype = enum { docs, garden, cookbook, blog, textile };

/// Comptime-joined `docs, garden, cookbook, blog, textile` for diagnostics
/// and help text — the table below is the single source of truth.
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
    \\    { "name": "public", "output": "dist", "public": true, "theme": "themes/cards" }
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
    .{ .path = "themes/cards/footer.html", .data = archetype_themes.cards_footer },
    .{ .path = "themes/cards/assets/css/cards.css", .data = archetype_themes.cards_css },
    .{ .path = "themes/cards/README.md", .data = archetype_themes.cards_readme },
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
    \\  content/index.cook                trunk page (prose plus recipe references)
    \\  content/mains/                    two recipe satellites
    \\  content/sauces/pepper-oil.cook    sub-recipe used as an ingredient
    \\  themes/cards/                     shipped "cards" theme — soft recipe cards
    \\  boris.json                        profile (input_format: cook, theme: cards)
    ,
    .next_steps =
    \\  boris --profile boris.json                                     build the recipe box
    \\  boris recipe-scale --cooklang --id mains/carbonara --servings 4   scaled view (never rewrites source)
    \\  boris check --cooklang --input content                          graph-health report
    \\  boris watch --profile boris.json                                rebuild on change
    ,
    .conventions =
    \\  @name{amount%unit} is an ingredient, #name{} cookware, ~{n%unit} a timer
    \\  @./sauces/pepper-oil{1%tbsp} references another page as a validated graph edge
    \\  servings in frontmatter feeds `recipe-scale --servings`; = and == are section headings
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

fn specFor(archetype: Archetype) *const ArchetypeSpec {
    return switch (archetype) {
        .docs => &docs_spec,
        .garden => &garden_spec,
        .cookbook => &cookbook_spec,
        .blog => &blog_spec,
        .textile => &textile_spec,
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
    try std.testing.expectEqualStrings("docs, garden, cookbook, blog, textile", archetype_names);
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
    const expect_format = [_][]const u8{ "markdown", "markdown", "cook", "markdown", "textile" };
    const expect_theme = [_][]const u8{ "themes/boris", "themes/ledger", "themes/cards", "themes/cozy", "themes/press" };
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
                !std.mem.startsWith(u8, file.path, "content/includes/"))
            {
                content_pages += 1;
            }
        }
        try std.testing.expectEqual(content_pages, outcome.verified);
    }
}
