//! Build-time embed table for `boris init --type` starter archetypes.
//!
//! `@embedFile` is confined to the embedding module's package root, so this
//! table lives beside the shipped themes rather than under `src/` — rooting
//! the module here lets `init` materialize a starter's theme byte-for-byte
//! from the first-party catalog instead of keeping a drifting copy.
//!
//! Consumed by `src/init.zig` as the `init_archetype_themes` import
//! (wired in `build.zig`). Add a starter-facing theme's files here when a
//! new archetype adopts it.

pub const ledger_layout_main = @embedFile("ledger/layouts/main.html");
pub const ledger_footer = @embedFile("ledger/footer.html");
pub const ledger_css = @embedFile("ledger/assets/ledger.css");
pub const ledger_readme = @embedFile("ledger/README.md");
pub const ledger_accessibility = @embedFile("ledger/ACCESSIBILITY.md");

pub const cards_layout_main = @embedFile("cards/layouts/main.html");
pub const cards_layout_home = @embedFile("cards/layouts/home.html");
pub const cards_footer = @embedFile("cards/footer.html");
pub const cards_css = @embedFile("cards/assets/css/cards.css");
pub const cards_readme = @embedFile("cards/README.md");
pub const cards_accessibility = @embedFile("cards/ACCESSIBILITY.md");

pub const cozy_layout_main = @embedFile("cozy/layouts/main.html");
pub const cozy_footer = @embedFile("cozy/footer.html");
pub const cozy_css = @embedFile("cozy/assets/cozy.css");
pub const cozy_readme = @embedFile("cozy/README.md");
pub const cozy_accessibility = @embedFile("cozy/ACCESSIBILITY.md");

pub const press_layout_main = @embedFile("press/layouts/main.html");
pub const press_layout_home = @embedFile("press/layouts/home.html");
pub const press_layout_section = @embedFile("press/layouts/section.html");
pub const press_layout_blog = @embedFile("press/layouts/blog.html");
pub const press_layout_archive = @embedFile("press/layouts/archive.html");
pub const press_footer = @embedFile("press/footer.html");
pub const press_css = @embedFile("press/assets/css/press.css");
pub const press_mark_svg = @embedFile("press/assets/img/press-mark.svg");
pub const press_readme = @embedFile("press/README.md");
pub const press_accessibility = @embedFile("press/ACCESSIBILITY.md");
pub const press_migration = @embedFile("press/MIGRATION.md");

pub const service_layout_main = @embedFile("service/layouts/main.html");
pub const service_layout_home = @embedFile("service/layouts/home.html");
pub const service_layout_section = @embedFile("service/layouts/section.html");
pub const service_footer = @embedFile("service/footer.html");
pub const service_css = @embedFile("service/assets/css/service.css");
pub const service_readme = @embedFile("service/README.md");
pub const service_accessibility = @embedFile("service/ACCESSIBILITY.md");

pub const reference_layout_main = @embedFile("reference/layouts/main.html");
pub const reference_layout_home = @embedFile("reference/layouts/home.html");
pub const reference_layout_section = @embedFile("reference/layouts/section.html");
pub const reference_footer = @embedFile("reference/footer.html");
pub const reference_css = @embedFile("reference/assets/css/reference.css");
pub const reference_mark_svg = @embedFile("reference/assets/img/mark.svg");
pub const reference_readme = @embedFile("reference/README.md");
pub const reference_accessibility = @embedFile("reference/ACCESSIBILITY.md");

pub const minimal_layout_main = @embedFile("minimal/layouts/main.html");
pub const minimal_footer = @embedFile("minimal/footer.html");
pub const minimal_css = @embedFile("minimal/assets/minimal.css");
pub const minimal_readme = @embedFile("minimal/README.md");
pub const minimal_accessibility = @embedFile("minimal/ACCESSIBILITY.md");

pub const journal_layout_main = @embedFile("journal/layouts/main.html");
pub const journal_layout_archive = @embedFile("journal/layouts/archive.html");
pub const journal_footer = @embedFile("journal/footer.html");
pub const journal_css = @embedFile("journal/assets/journal.css");
pub const journal_readme = @embedFile("journal/README.md");
pub const journal_accessibility = @embedFile("journal/ACCESSIBILITY.md");

pub const corporate_layout_main = @embedFile("corporate/layouts/main.html");
pub const corporate_footer = @embedFile("corporate/footer.html");
pub const corporate_css = @embedFile("corporate/assets/corporate.css");
pub const corporate_readme = @embedFile("corporate/README.md");
pub const corporate_accessibility = @embedFile("corporate/ACCESSIBILITY.md");

pub const showcase_layout_main = @embedFile("showcase/layouts/main.html");
pub const showcase_layout_home = @embedFile("showcase/layouts/home.html");
pub const showcase_layout_section = @embedFile("showcase/layouts/section.html");
pub const showcase_layout_blog = @embedFile("showcase/layouts/blog.html");
pub const showcase_footer = @embedFile("showcase/footer.html");
pub const showcase_css = @embedFile("showcase/assets/css/showcase.css");
pub const showcase_mark_svg = @embedFile("showcase/assets/img/mark.svg");
pub const showcase_readme = @embedFile("showcase/README.md");
pub const showcase_accessibility = @embedFile("showcase/ACCESSIBILITY.md");

pub const archive_layout_main = @embedFile("archive/layouts/main.html");
pub const archive_layout_archive = @embedFile("archive/layouts/archive.html");
pub const archive_footer = @embedFile("archive/footer.html");
pub const archive_css = @embedFile("archive/assets/archive.css");
pub const archive_readme = @embedFile("archive/README.md");
pub const archive_accessibility = @embedFile("archive/ACCESSIBILITY.md");

pub const engineering_layout_main = @embedFile("engineering/layouts/main.html");
pub const engineering_layout_home = @embedFile("engineering/layouts/home.html");
pub const engineering_layout_section = @embedFile("engineering/layouts/section.html");
pub const engineering_footer = @embedFile("engineering/footer.html");
pub const engineering_css = @embedFile("engineering/assets/css/engineering.css");
pub const engineering_readme = @embedFile("engineering/README.md");
pub const engineering_accessibility = @embedFile("engineering/ACCESSIBILITY.md");

pub const gallery_layout_main = @embedFile("gallery/layouts/main.html");
pub const gallery_layout_home = @embedFile("gallery/layouts/home.html");
pub const gallery_footer = @embedFile("gallery/footer.html");
pub const gallery_css = @embedFile("gallery/assets/css/gallery.css");
pub const gallery_readme = @embedFile("gallery/README.md");
pub const gallery_accessibility = @embedFile("gallery/ACCESSIBILITY.md");
