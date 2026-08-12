# Experiment report — two-resource economy overlay (round 3)

**Status:** disposable spike evidence — **not** normative, **not** a contract.
Boris core was not modified. Companion to `EXPERIMENT-REPORT.md` (round 2:
interactive overlay), `README.md` (round-1 friction log and assessment), and
`docs/spikes/svelte-consumer.md` (agent handoff).

**Question under test:** does the Boris↔Svelte seam hold when the browser-side
interaction is a *stateful application* rather than a trivial widget — state
that ticks against wall-clock time, holds interdependent resources, and
survives navigation and reload?

**Answer:** yes — the same verdict as round 2 (**Clean with minor consumer
friction**, verdict 2). The heavier state machine changed nothing about the
boundary: Boris content, metadata, relations, routes, and determinism were
untouched, and the widget required zero Boris knowledge. Zero new integration
glue was added; total glue remains the round-1 link rewrite (~15 lines) plus
the round-2 asset copy (~7 lines).

---

## 1. What was built

`src/lib/components/EconomyToy.svelte` (~200 lines) — a two-resource economy
with passive production, replacing the round-2 `IncrementalToy.svelte` (which
was deleted; the storage key changed from `boris-spike:incremental:` to
`boris-spike:economy:` so old keys are simply ignored).

```text
wood: 0    +1/tick   [Chop (+2)]      stone: 0   +1/tick   [Mine (+2)]
[Axe: 10 stone → +1 wood/tick]   [Pickaxe: 10 wood → +1 stone/tick]   [reset]
```

What makes it heavier than round 2, deliberately:

- **Two interdependent resources**, not one scalar: the axe is paid in *stone*,
  the pickaxe in *wood* — cross-resource costs so the economy actually
  interacts instead of being two independent bars.
- **A wall-clock ticker**: passive production (`+1 resource/tick`, upgrades
  add `+1/tick` each) runs on `setInterval` while the component is mounted and
  stops cleanly on unmount (`onDestroy` clears the timer).
- **Upgrade cost scaling**: `ceil(10 × 1.6^level)` — verified 10 → 16 → 26.
- **Offline catch-up**: a `savedAt` timestamp is persisted with the state; on
  mount the widget computes wall-clock elapsed time and accrues production for
  it, capped at 3600 ticks (1h) so long absences can't produce absurd numbers.

Boundary rule unchanged from round 2: pure browser-owned `$state`; the only
Boris-derived input is `entityId`, used opaquely as a `localStorage` key. No
new identity system. Boris is not involved in any of the game semantics.

Mounted on every detail page under the same `{#key node.id}` remount pattern
as round 2, so each entity owns its slot and its storage key.

## 2. Boundary result

**Did Boris-managed content and Svelte-owned interactive state coexist without
architectural leakage? Yes.**

- The widget sits between the Boris-rendered body and the Boris-graph relations
  panel on every entity page; all three render together, hydrate, and update
  independently.
- The heavier state machine introduced **no new coupling**: no Boris source
  reading, no relation resolution, no schema knowledge, no invented ids. The
  widget could be deleted and Boris content would be unaffected; Boris content
  could be deleted and the widget would still run.
- The one interaction between the two systems is the *identity handshake* — the
  widget borrows the canonical entity id as an opaque storage key — and it
  already existed in round 2. No leakage in either direction was observed.

## 3. State behavior

All verified live in a real browser (production build, prerendered pages):

| Behavior | Result |
|---|---|
| Ticking | +1 wood & +1 stone per second while mounted (wood 8 → 11 in ~2.6 s) |
| Manual gather | Chop/Mine add +2 instantly |
| Upgrade purchase | Axe bought with stone; cost 10 → 16 → 26 (1.6× scale); wood rate +1 → +2 → +3/tick |
| Persistence | `localStorage` written on every state change (`boris-spike:economy:{entityId}`) |
| Offline catch-up | `savedAt` backdated 60 s → ~180 wood / ~60 stone accrued instantly on reload, then live ticking continued |
| Page reload | Full reload restores state and resumes ticking |
| SPA navigation away + back | Overview state (332 wood / 112 stone, axe level 2) restored exactly on return |
| Per-entity isolation | Each entity has its own storage key; state does not bleed between pages; ticks halt when the widget unmounts |

The smallest reasonable persistence mechanism remains the round-2 conclusion:
browser `localStorage`, keyed by the canonical id — no server, no Boris. The
new wrinkle this round is that *time-based* state needs a `savedAt` anchor
for offline catch-up; that is an ordinary incremental-game concern (every
incremental game does this), not a Boris or SvelteKit one.

## 4. Content rebuild behavior

Not re-run as a separate experiment this round: round 2 already proved the
content-edit → rebuild loop (title change propagated through unlabeled
wiki-links, widget state survived untouched), and this round made **no Boris
content change** — the point of round 3 was heavier *client* state. What was
re-verified:

- `bash boris-data.sh` rebuilt the whole data feed; all 48 files
  (manifest, graph, build-report, 45 body fragments) were **byte-identical**
  before and after (`sha256sum` comparison).
- `git status` shows zero `content/` changes — Boris source, schemas, and
  compiler untouched by the entire round.
- The Svelte-only rebuild path (`npm run build`) re-rendered all 45 pages with
  the new widget; every page prerendered successfully.

## 5. Friction log

New awkwardness this round: **none that touches the seam.**

| Observation | Classification |
|---|---|
| Svelte 5 flushes state updates asynchronously outside event handlers — a test probe that read the DOM synchronously after a programmatic `.click()` saw stale values | Ordinary frontend concern (test tooling; a `setTimeout` settle fixes it). Not a Boris or SvelteKit issue |
| A ticker that runs while mounted means `localStorage` writes once per second while a page is open | Ordinary frontend concern — trivial payload, and only while the page is focused |
| The `savedAt` timestamp required for offline catch-up | Ordinary frontend concern (standard incremental-game pattern) |

No new routes, assets, ids, metadata, hydration, prerendering, or generated
paths were involved. The round-2 caveats (page-local assets need the ~7-line
copy step; incremental builds are HTML-path-only) remain unchanged.

## 6. Glue delta

**Before this round:** ~15-line link rewrite (`src/lib/boris/body.ts`) + ~7-line
asset copy step (`boris-data.sh`).

**After this round:** identical — the same ~22 lines total. The economy widget
added **zero** integration glue; it is pure application code living inside the
Svelte sandbox. This is the cleanest possible outcome: heavier interaction did
not cost the boundary anything.

## 7. Boris changes

> **None.**

No Boris source, schema, contract, or compiler code was touched, and no
existing public behavior was strained. The experiment required nothing new
from Boris — evidence that the "Boris owns knowledge, Svelte owns interaction"
split is real rather than aspirational.

## 8. Things Boris should NOT absorb

Updated from rounds 1–2 based on this round's evidence:

- **No game-state concepts in Boris metadata** — the economy is a pure
  Svelte/browser concern; nothing about it belongs in frontmatter or IR. (A
  real product might want *content-authored* balance numbers someday, but that
  is a content-model question for a future experiment, not evidence this round
  produced.)
- **No server or database persistence for client state** — `localStorage` +
  a `savedAt` anchor is the right size for the experiments so far.
- **No rendered bodies in IR** (unchanged) — the `--html-layout` body feed
  still covers it.
- **No TS types in Boris** (unchanged), **no extensionless-href mode**
  (unchanged), **no slug maps** (unchanged), **no frontend SDK** (unchanged),
  **no Svelte-side Markdown re-rendering** (unchanged).
- **No asset-serving in Boris** (unchanged) — the consumer copy step is
  trivial and stable.

## 9. Architectural verdict

**2 — Clean with minor consumer friction.**

Round 3 pushed the client side from a button-and-counter toy to a
time-driven, two-resource stateful application, and the boundary did not move:
the widget ticked, upgraded, persisted, caught up offline time, and survived
navigation and reload with no Boris involvement of any kind, while Boris
content and determinism remained untouched. The two consumer conventions
(link re-targeting, asset copy) are unchanged and documented.

## 10. Post-review hardening (Greptile P1, PR #365)

Greptile review found a real bug in the ticker: each interval fire granted
only **one** tick and the persistence effect then advanced `savedAt` to the
current wall-clock time — so when the browser throttled or delayed the timer
(background tab, device suspension, main-thread blocking), the missed elapsed
production was permanently discarded.

Fixed by making ticks **time-aware**: each fire grants production for the
wall-clock time actually elapsed since the last granted tick (capped at
`MAX_OFFLINE_TICKS`), and the persisted `savedAt` anchor is now `lastTickAt`
so the reload catch-up resumes from the last *granted* tick rather than a
later write. Verified in a real browser by blocking the main thread for 3 s:
the delayed tick granted 3 ticks (not 1), and the persisted anchor tracked the
tick. Normal cadence and reload catch-up both still work; this is pure Svelte
widget logic, no Boris involvement.

## 11. Recommended next step

The interactive-app thread has now been exercised at two levels of state
complexity, both clean. Continuing to grow the widget would be building a game,
not testing the seam — explicitly out of scope. The evidence-backed next step
remains the cheapest un-run probe:

> **Non-Svelte consumer cross-check (~50 lines):** a tiny Zig or vanilla-JS
> script that renders a page from the same manifest/graph/body feed, proving
> the "clean consumer boundary" claim is not Svelte-specific.

This locks the framework-neutrality claim that rounds 1–3 have been building
toward. If it passes, the boundary is proven and further spikes should stop —
real applications (including games) should be built *on top of* the seam, not
by extending it.
