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
pub const cards_footer = @embedFile("cards/footer.html");
pub const cards_css = @embedFile("cards/assets/css/cards.css");
pub const cards_readme = @embedFile("cards/README.md");

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
