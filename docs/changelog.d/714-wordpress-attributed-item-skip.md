### Fixed

- Fix WordPress WXR parsing so an attributed `<item wp:post_id="…">` that precedes a bare `<item>` is no longer skipped; `nextItemSlice` now takes the earliest of the two open forms. See [`tools/migration-lab/wordpress.zig`](/tools/migration-lab/wordpress.zig) and [#714](https://github.com/drawmeanelephant/boris/issues/714).
