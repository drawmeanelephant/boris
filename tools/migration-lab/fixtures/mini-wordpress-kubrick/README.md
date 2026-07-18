# Mini classic WordPress theme fixture

This is a small, synthetic, Kubrick-shaped benchmark for
`boris-migration-lab --mode=wordpress-theme`. It is not copied from an
authentic Kubrick distribution and contains no personal or remote content.

It models the classic theme surface that matters for archaeology:

- `index.php`, `single.php`, and `page.php` content templates;
- `header.php`, `footer.php`, `sidebar.php`, `comments.php`, and `searchform.php`;
- `functions.php` menu/widget registration and enqueue hooks;
- `style.css`, `rtl.css`, a small JS file, and static image assets.

The lab reads source text and hashes files. It never executes PHP or JavaScript.
Use the generated `manual_review.json` as the preservation boundary for every
dynamic hook, loop, widget, menu location, and unresolved template relation.

Run from `tools/migration-lab/`:

```bash
zig build run -- --mode=wordpress-theme \
  --root=./fixtures/mini-wordpress-kubrick \
  --out=./.wp-theme-report
```
