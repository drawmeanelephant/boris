# Editor accessibility certification (#418)

The Boris Editor is a semantic HTML app with a native `<textarea>` source
surface, so the accessibility tree Playwright asserts in CI is the same tree
keyboard users and screen readers operate. This file is the recorded #418
accessibility posture.

## Scope decision: spoken OS voice control is descoped (2026-09-11)

The original #418 plan made macOS Voice Control / Windows Voice Access a
product acceptance criterion (milestone M10, sub-issue
[#677](https://github.com/drawmeanelephant/boris/issues/677)). That criterion is
**descoped from the v1 editor**. This is a product-scope decision, not an
accessibility regression:

- The editor's author-facing accessibility is delivered by semantic HTML, full
  keyboard operability, and a CI-asserted accessibility tree — certified below.
- Spoken voice control was intended as a hands-free *alternative* input path,
  never as the only way to reach a workflow. Every workflow already completes
  by keyboard and exposes stable accessible names, which is what the
  certification checks and what a screen reader consumes.
- No *shipped* capability is removed by the descope: no workflow was
  voice-only, and no voice-specific feature had landed.

The platform choice that made spoken control cheap to reach — a browser-served
semantic UI with a native text field — is unchanged, so re-opening this is
additive work rather than a rewrite. `editor/README.md` and the shell already
forbid canvas-rendered controls, hover/drag-only core flows, and unlabeled
icon-only controls; if voice certification returns, it restarts from those
gates and from the CI accessibility-tree assertions below.

Sub-issue #677 is closed as *not planned* under this decision, and the M10 line
of [#418](https://github.com/drawmeanelephant/boris/issues/418) is satisfied by
the keyboard + accessibility-tree certification below.

## What is certified

- **Keyboard and accessibility tree.** The `editor/ui` Playwright suite covers
  keyboard shortcuts, semantic roles and names, focus order, dialog focus
  trapping, and the absence of pointer-only core flows.
  [`editor/ui/scripts/check-key-hints.mjs`](ui/scripts/check-key-hints.mjs)
  statically asserts that every rendered key hint is backed by a handler. Both
  run in the `editor-test` CI lane through
  [`test-editor-gate.sh`](scripts/test-editor-gate.sh).
- **Accessible names.** Chrome buttons and links expose a non-empty accessible
  name that contains their visible label, so visible text and the programmatic
  name cannot drift. This is the same tree “Show names” reads; it is asserted
  here, not spoken.
- **Dialogs.** Native `<dialog>` surfaces with focus trapping, an Escape path,
  and a reachable close.
- **Status.** Never color-only; progress and errors are announced through
  visible text and live regions.
- **Source editing.** The native `<textarea>` keeps platform caret, selection,
  and text-editing behavior; the focus-mode reading surface is a review aid,
  never a replacement for the compiled preview.

## The 14 #418 actions

Each action from the #418 action checklist is reachable with keyboard alone and
carries a stable accessible name in the CI accessibility tree.

| #  | Action                                        | Keyboard (CI)              | Accessibility tree (CI) |
| -- | --------------------------------------------- | -------------------------- | ----------------------- |
| 1  | Launch / open a project                       | Yes                        | Yes                     |
| 2  | Open / create Markdown or Textile             | Yes                        | Yes                     |
| 3  | Open / create a Cooklang recipe               | Yes                        | Yes                     |
| 4  | Move between Source, Project, Problems, Preview | Yes                      | Yes                     |
| 5  | Edit frontmatter                              | Yes                        | Yes                     |
| 6  | Select a graph completion                     | Yes                        | Yes                     |
| 7  | Introduce a validation error                  | Yes                        | Yes                     |
| 8  | Locate / read / fix that error                | Yes                        | Yes                     |
| 9  | Save and preview                              | Yes                        | Yes                     |
| 10 | Scale a recipe where Boris supports it        | Yes (`boris recipe-scale`) | Yes                     |
| 11 | Navigate to a related recipe or page          | Yes                        | Yes                     |
| 12 | Run a publication plan                        | Yes                        | Yes                     |
| 13 | Recover from an interrupted operation         | Yes                        | Yes                     |
| 14 | Leave without silently losing changes         | Yes (dirty + recovery + beforeunload) | Yes           |

## Review aids are review aids

The Preview pane's *Accessibility review aid* is a checklist, not a
certification, and it says so. Screen-reader spot-checks (VoiceOver on macOS,
Orca on Linux) remain recommended during hardening (#418 M11) and are recorded
as observations rather than as a gate — the same honesty this file applies to
spoken voice control.
