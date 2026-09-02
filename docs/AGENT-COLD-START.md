# Agent cold-start onboarding evaluation

**Status:** non-normative evaluation protocol. Model-agnostic; proven across
two agents of very different capability (one low-effort, one thorough) on the
`boris/0.8.2` kit. Related: [`AGENT-BINARY-KITS.md`](AGENT-BINARY-KITS.md) for
how kits are built and verified.

## Purpose

The standard way to measure Boris onboarding is to hand an agent a bare binary
and watch it figure the product out. This protocol makes that experiment
repeatable and its results comparable across runs:

- It measures **discovery**, not intention — what a cold-start agent can find
  using only the binary and what the binary prints.
- It is the acceptance check for onboarding-surface work (init, orientation,
  help text, starter scaffolding): run it before and after such a change.
- Its output feeds the normal review discipline: report lines are **leads**,
  classified per [`../AGENTS.md`](../AGENTS.md) (Confirmed defect, Likely
  defect, Insufficient evidence, Documented limitation, Non-issue) before any
  card is cut.

## Procedure

1. **Sender.** From a clean worktree of the commit under test, build the kit:
   `./scripts/agent-pack.sh`. Record the commit, branch, platform, and Zig
   version from the printed manifest summary. Keep the kit outside tracked
   product files.
2. **Recipient verification.** The agent verifies the archive checksum, the
   manifest platform against its machine, and the per-binary `SHA256SUMS`
   **before executing anything**. This step is part of the experiment: it is
   the first thing onboarding must teach.
3. **Discovery and task.** From a fresh empty directory, the agent works out
   what `boris` is from the binary alone, then builds a small documentation
   site with the fixed graph shape below and validates the output.
4. **Report.** The agent returns the structured report in the prompt. Artifacts
   stay in the agent's workspace; the report is the deliverable.

## The neutral prompt

The experiment is void if the prompt names a feature under test. Do not
mention search, analysis commands, publication, or any surface being measured —
the detector is whether the agent finds them unprompted. Canonical text:

```text
You have a Boris agent kit: an archive, a SHA-256 sidecar, and a manifest.

1. Verify the archive checksum, extract it, and check the manifest's
   platform matches your machine before executing anything from it.
2. From a fresh empty directory, work out what `boris` is and how to use
   it, using only the binary itself and whatever it prints. Do not fetch
   Boris documentation or source; the point is testing what a cold-start
   agent can discover from the binary alone.
3. Create a small documentation site: one trunk page, at least two
   satellites beneath it with real parent links, a wiki link between two
   pages, and one semantic relation. Build the site to HTML and confirm
   the output is complete and valid.
4. The deliverable is an onboarding report:
   - every command you ran, and what told you to run it (--help text,
     a command's own output, or guesswork);
   - anything the tool did for you that you did not ask for;
   - anything you expected a static-site compiler to provide that you
     did not find — list these even if they seem minor;
   - every point where you were stuck for more than a minute.

Send me the report and leave the built site in your workspace.
```

## Reading the report

| Report line | What it measures | How to act |
|---|---|---|
| What told you to run each command | Orientation attribution: help text vs a command's own output vs guesswork | Guesswork entries are discoverability gaps — highest-value onboarding cards |
| Anything the tool did unasked | Invisible capabilities (self-verification, generated artifacts, emitted projections) | Confirms fixes landed without being asked about; a silent no-op here means the surface is not discoverable |
| Expected but not found | The failure-mode detector: what onboarding fails to teach | Each entry is a lead — verify against current code/contracts, then classify |
| Stuck for more than a minute | Friction queue | Immediate card candidates, ordered by recurrence |

Run at least two agents of different capability when validating a change. A fix
is proven when the low-effort model clears a detector that the earlier run
failed; the thorough model additionally probes depth (inspecting artifacts,
querying emitted data, building beyond the minimum).

## Boundaries

- Discovery never fetches Boris documentation or source; that is the
  experiment. The kit's own manifest/README are in bounds.
- Reports name agent-side workspaces that may not be locally verifiable.
  Verify what is reachable; classify the rest rather than assuming.
- The protocol never widens product surfaces: findings become cards through
  the normal contract-first process, never in-experiment feature requests.
- Not a CI gate: it is manual, deliberate, and model-dependent by design.
