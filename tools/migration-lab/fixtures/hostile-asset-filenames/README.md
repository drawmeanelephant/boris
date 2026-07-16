# hostile-asset-filenames fixture

Synthetic content tree for the migration-lab **asset-filename** mode. Exercises
filenames and references that Boris core content-local assets reject, without
relaxing the product ASCII path contract.

| Case | Path / reference |
|------|------------------|
| Spaces | `spaces.assets/hello world.png` (+ `%20` markdown form) |
| Unicode | `unicode.assets/café.png` |
| Percent-style name | `percent.assets/diagram%20copy.png` (literal `%20` on disk) |
| Nested | `nested.assets/deep/sub dir/shot.png` |
| Case collision | `Foo Bar.png` → `Foo-Bar.png` vs `foo-bar.png` (case-fold clash) |
| Sanitized-name collision | `foo bar.png` vs `foo-bar.png` → exact same dest |
| Traversal | Markdown `../` destinations under `traversal.assets/` |
| Symlink | `symlink.assets/alias.png` → `real.png` |
| Already safe | `safe.assets/already-ok.png` (must stay unchanged) |

Source tree is **read-only** for the lab: only `--out` is written.
