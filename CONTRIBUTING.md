# Contributing to Boris

Thanks for being here. Contributions of every size are welcome — bug
reports, fixes, docs, tests, features, and honest questions. You don't need
permission to help, and you don't need to be an expert. If something looks
wrong or confusing, that is useful signal: please tell us.

Boris is a graph-native publication compiler: Markdown in, validated
Trunk/Satellite graph, one or more contracted targets out. It's written in
Zig and renders Markdown in-process via Oliver. New here? The
[README](README.md) covers what it does,
[`docs/contracts/publication-model.md`](docs/contracts/publication-model.md)
covers the content model, and
[`docs/SOURCE-MAP.md`](docs/SOURCE-MAP.md) helps you find your way around
the code.

## Getting set up

1. Install Zig at or above the `minimum_zig_version` in
   [`build.zig.zon`](build.zig.zon) (currently 0.17.0).
2. `zig build` — the first build fetches the pinned dependencies.
3. `zig build test` — this is the baseline gate. Run it before and after
   your change.
4. See it work: `./zig-out/bin/boris watch --serve` builds the bundled
   content and serves it on loopback with live reload.

[`AGENTS.md`](AGENTS.md) is the project field manual for humans and agents
alike — build traps, branch policy, and the architectural boundaries that
are not negotiable. Skim it before a big change; it will save you time.

## Ways to contribute

- **Report bugs.** Open an issue with what you did, what you expected, and
  what happened. A minimal Markdown input that reproduces the problem is
  the most useful thing you can attach. Blank issues are fine — a clear
  description beats a template. (Windows is supported but not gated in CI,
  so Windows failures are especially welcome reports.)
- **Suggest features.** Open an issue describing the problem you want to
  solve before building something large. Boris has firm architectural
  boundaries, and a short conversation up front saves real rework.
- **Send small PRs.** Typos, fixes, tests, doc corrections — focused PRs
  are the fastest to review and the most likely to land quickly. Forks are
  welcome: branch from `main` and open the PR against `main` (or whatever
  line [`docs/STATUS.md`](docs/STATUS.md) declares active).
- **Improve docs.** Unclear contracts, stale pointers, missing examples:
  all fair game.
- **Work on the editor.** `editor/` is a sanctioned product surface — a
  Zig host plus a Svelte 5 + Vite + TypeScript UI. Front-end help is
  genuinely useful here; see [`editor/README.md`](editor/README.md).

## What a good PR looks like

- **Focused.** One change per PR beats one big PR every time.
- **Formatted and tested.** Run `zig fmt` on the files you touched and
  `zig build test`; CI checks both. If your change affects IR output, also
  run `./scripts/release-gate.sh` (bash, macOS/Linux). If you can't, say
  so in the PR.
- **Honest.** The PR template asks what you ran, what you saw, and what
  you didn't check — fill in what applies, write N/A for the rest, and
  don't sweat it for a typo fix. "I didn't test X" is a perfectly
  acceptable entry.
- **Linked.** Reference issues as `Closes #N` or `Refs #N`, one per line
  and not in backticks — CI lints this.
- **Contract-aligned.** Behavior that touches IR shape, frontmatter,
  graph rules, or diagnostics updates the relevant
  [`docs/contracts/`](docs/contracts/) file and its fixtures in the same
  change; breaking IR changes bump `schemaVersion`. If code and contract
  disagree, the PR should resolve the contradiction — fix the code or fix
  the contract, and say why. (Pure contract-restoring bug fixes don't need
  contract edits.) The contract index is
  [`docs/contracts/README.md`](docs/contracts/README.md).
- **Changelogged.** Feature and fix PRs add a fragment under
  `docs/changelog.d/` — see its
  [README](docs/changelog.d/README.md). The filename starts with the PR
  number, so you can open the PR first and add it after. Docs-only PRs
  don't need one.

It's fine to open a draft PR early. Feedback on direction is much cheaper
than feedback on a finished diff. Reviews are best-effort on response time;
a maintainer may tag your PR for an automated review pass as well.

## Style notes

- Match the code around you. Consistency with existing style matters more
  than personal preference.
- Prefer `std`, explicit structures, and the established module
  boundaries. Boris favors in-memory, arena-friendly, single-pass work.
- The compiler core is Zig + Oliver, deliberately — don't add another
  language or toolchain there. That boundary is scoped to the core; the
  editor's stack is its own thing, described in `AGENTS.md`.
- AI-assisted contributions are welcome — the bar is the same, and you own
  what you submit.

## Conduct

Be kind and assume good intent. Disagree with ideas, not people.
Harassment isn't welcome; maintainers will remove it and, if needed, the
people doing it. If you need to raise a conduct issue privately, contact
the maintainer through their GitHub profile.

## License

MIT, no CLA. By contributing, you agree that your contributions are
licensed under the same terms as the project — see [LICENSE](LICENSE).
