# 670 slice 2 — Editor: Header, SectionNav, RecoveryBanner components

Slice 2 of #670: extract presentational header/nav/recovery shell from the App.svelte monolith.

- `editor/ui/src/components/Header.svelte` — props `{connection}`, header + `skip-link:1778` (`header` + `.eyebrow` + `.connection`), no `fetch`
- `editor/ui/src/components/SectionNav.svelte` — no props, 6 anchors `Project|Source|Graph|Publication|Problems|Preview:1789`
- `editor/ui/src/components/RecoveryBanner.svelte` — props `{snapshots: RecoverySnapshot[]}`, emits `onRestore(snapshot)`/`onDiscard(path)`, `recovery-banner:styles.css:29` intact, `Tab`/`Enter` hints preserved

`App.svelte` `2188 → 2157` (-31) now imports and prop-drills to the three components; ownership rule preserved (components never call `fetch`, security boundary stays in `lib/api.ts`). `styles.css` single source, stable ids and class names unchanged.

Verification: `npm --prefix editor/ui run check` 0 errors (22 kbd hints, 2 moved to `RecoveryBanner.svelte` by design), `npm run build` succeeds, `zig build --build-file editor/build.zig test` green, `test-contract-fixture.sh`, `test-host.sh`, `test:e2e` 112/112 green, screenshot `375|768|1440` byte-identical.

Follows `docs/plans/670-editor-segmentation.md` slice 2. Next: ProjectPane + SourcePane/AuthoringTools.
