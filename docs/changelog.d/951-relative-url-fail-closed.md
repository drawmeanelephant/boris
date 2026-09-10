### Fixed

- `boris nostr plan` now fails closed (`ENOSTRMARKDOWN`, `relative-url`) on an ordinary authored relative link or image destination in the publication-safe Markdown view, not only on the four Boris-mediated classes; every link and image destination must be scheme- or origin-qualified. Links: [Nostr publication contract](/docs/contracts/nostr-publication.md), [#893](https://github.com/drawmeanelephant/boris/issues/893).
