//! Build-time embed table for `boris init --type` starter content that lives
//! in `examples/` specimen sites.
//!
//! `@embedFile` is confined to the embedding module's package root, so this
//! table lives beside the example sites rather than under `src/` — rooting
//! the module here lets `init` materialize a starter's content byte-for-byte
//! from the specimen instead of keeping a drifting copy under
//! `src/init_templates/` (#1084).
//!
//! Consumed by `src/init.zig` as the `init_example_assets` import
//! (wired in `build.zig`). Add a starter-facing example asset here when a new
//! archetype adopts it.

pub const gallery_tidewater_png = @embedFile("gallery-site/content/index.assets/tidewater.png");
pub const gallery_dawn_png = @embedFile("gallery-site/content/photos/coast.assets/dawn.png");
pub const gallery_dusk_png = @embedFile("gallery-site/content/photos/coast.assets/dusk.png");
pub const gallery_ridge_png = @embedFile("gallery-site/content/photos/hills.assets/ridge.png");
pub const gallery_pines_png = @embedFile("gallery-site/content/photos/hills.assets/pines.png");
