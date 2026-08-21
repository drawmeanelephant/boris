# Agent playbook — Boris

This is supporting operational guidance for the binding standing rules in
[`AGENTS.md`](../AGENTS.md). It keeps detailed procedures available without
making them standing context for every task.

## Review and release procedure

For audits, release reviews, or external AI packets, first record the packet's
stated release/version and resolve the authority: review only, review plus
agent/docs guidance, or implementation. External notes are leads, never
repository truth. Use this evidence order:

1. Executable behavior and current code.
2. Canonical [`docs/contracts/`](contracts/) documentation.
3. [`AGENTS.md`](../AGENTS.md), then [`STATUS.md`](STATUS.md), then
   [`CHANGELOG.md`](../CHANGELOG.md).
4. Release-gate docs/scripts, README and narrative RAG seeds, then external or
   historical notes.

Classify every material observation once:

- **Confirmed defect** — reproduced failure, unsafe reachable path, or direct
  code/contract contradiction.
- **Likely defect** — strong code-path evidence without reliable reproduction.
- **Insufficient evidence** — unavailable tests, code, or environment prevent a
  material conclusion.
- **Documented limitation** — behavior matches an explicit current limitation.
- **Non-issue / packet drift** — authoritative current evidence contradicts the
  concern or the packet is stale.

For actionable findings, include severity, classification, exact locus,
evidence/reproduction, user or release impact, smallest remediation card, and
verification command. Keep optional hardening separate.

## Gates and environment evidence

Capture the initial `git status --short`. Run the smallest relevant gates before
an aggregate gate so one failure cannot hide others. For a microrelease, normally
check `zig build`, `zig build test`, `zig build test-render`, `zig build
package`, then `./scripts/release-gate.sh` when scope permits.

Distinguish product failures from environment interference. A Zig global-cache
`PermissionDenied` or denied symlink operation needs an allowed rerun or an
explicit evidence boundary; it is not a product failure. If cleanup panics after an earlier assertion,
report the primary failure and the masking cleanup defect separately; do not
weaken the test. A reproducibly failing required gate blocks shipping until fixed
or until the release claim is explicitly narrowed in current docs/contracts.

For a concurrency or determinism claim, compare sequential output, parallel
output, and a repeated parallel run of the same input. A small passing smoke does
not overrule a stress failure.

## Branch and recovery operations

During the active judging window, bring `afterparty` up to date before branching:

```bash
git fetch origin
git checkout afterparty
git pull --ff-only
git checkout -b codex/short-topic
```

Use one owned branch per concern. Before a PR, inspect `git status -sb` and the
diff, stage only intended paths, and rebase or merge the current integration line
when it moved. After merge, delete the topic branch and return the local checkout
to the integration line. Generated/ignored output is not branch currency.

Make small milestone commits where appropriate: automated workspace/sandbox sync
can otherwise risk local progress. If a workspace is accidentally reset, the IDE
keeps chronological byte-level write history at
`<appDataDir>/brain/<conversation-id>/.system_generated/logs/transcript_full.jsonl`.
Use that transcript to reconstruct only the lost work; never use it to overwrite
unrelated user changes.

## Suggested GitHub protections

Until hosting enforcement exists, `AGENTS.md` remains binding. When available,
protect `refs/heads/main` with PR-required direct-push blocking, no force pushes,
no deletion, stale-review dismissal, zero required approvals while solo, stable
CI checks, and narrowly allowed admin bootstrap bypass. During judging, apply the
same controls to `refs/heads/afterparty`, prevent its deletion, and remove or
revise the temporary rule after its deliberate PR into `main`.

## Supporting repository map

- [`README.md`](../README.md): human outcomes and CLI.
- [`docs/STATUS.md`](STATUS.md): phase banner + pointer table (capability snapshot in `archived/capability-matrix-v0.8.md`).
- [`docs/contracts/`](contracts/): normative IR, frontmatter, graph,
  diagnostics, and fixtures.
- [`docs/RELEASE-GATE.md`](RELEASE-GATE.md): mechanical ship checks.
- [`docs/COMPLETION-REPORT-TEMPLATE.md`](COMPLETION-REPORT-TEMPLATE.md): final
  evidence format.
- [`CHANGELOG.md`](../CHANGELOG.md) and [`docs/changelog.d/`](changelog.d/):
  release history and queued fragments.
- [`docs/AGENT-BINARY-KITS.md`](AGENT-BINARY-KITS.md): reproducible native
  handoffs; run `scripts/agent-pack.sh` from the target PR worktree and keep kits
  outside tracked product files.
