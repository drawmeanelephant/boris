### Fixed

- Documentation links rewrite inside compact (blank-line-free) `<Aside>`/`<Details>` bodies instead of failing the link audit: component tags no longer open the raw-HTML-block skip (#861). A stray unmatched backtick no longer suppresses link rewriting for the rest of the page (#862).
- Published-path collisions emit a located `EASSET` diagnostic naming the shared output path and the colliding page/entity instead of a bare `AssetCollision` ([content-local-assets](/docs/contracts/content-local-assets.md), #868).
