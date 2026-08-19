# Boris Editor — GitHub Issue Drafts & Milestone Updates

This document contains drafted updates for existing issues and new proposed issues based on real-browser testing against `boris/0.8.1` and the `boris-editor` host.

## 1. Progress Comment for Issue #418 (Boris Editor Epic)

**Target Issue**: [drawmeanelephant/boris#418](https://github.com/drawmeanelephant/boris/issues/418)  
**Title**: Boris Editor: first-class authoring environment over compiler-owned contracts  

### Draft Comment Content:

```markdown
### Visual & Browser Verification Report (M0 – M5 Execution)

Completed full headless browser validation against live Boris (`boris/0.8.1+semantic-relations`) and `boris-editor` host across all core authoring workflows:

#### 1. Workflow & Gate Results
- **Safe File Editing (M2)**: Open, save, create, rename, delete, and session undo/redo all verified. External disk modifications correctly open the side-by-side comparison modal (`Your unsaved version` vs `Current disk version`) without clobbering disk state.
- **Compiler Commands & Problems (M3)**: IR build, validate, check graph, and impact commands verified. Problem cards properly extract compiler codes (e.g. `EFRONTMATTER`), remediation notes, exact UTF-8 byte location jumps, and bounded diagnostic packet copy actions. Dirty buffers strictly disable compiler execution to prevent desync.
- **Authoring Vocabulary & Combobox (M4)**: Schema pre-check and Boris `completion.json` index categories (entities, relation kinds, layout slots, parent targets, wiki links) are fully navigable via ARIA 1.2 combobox with explicit token insertion.
- **Live Preview Fallback (M5)**: Ephemeral loopback preview origin serves committed `dist/` bytes cleanly inside sandboxed iframe with atomic fallback preservation on build failures.
- **Test Matrix**:
  - `playwright test`: **21 / 21 passed**
  - `svelte-check`: **0 errors, 0 warnings**
  - Host integration & contract fixture gates: **all passed**

#### 2. Accessibility & Voice Control Audit
- **Visible Label Matching**: 100% of interactive controls have accessible names matching visible text (Apple Voice Control / Windows Voice Access compliance).
- **Native `<textarea>`**: Preserves native OS dictation and voice selection semantics.
- **Focus Rings**: High-contrast rust outline (`#bf4f24`) visible across all keyboard and voice navigation paths.
- **Modal Dialogs**: Native `<dialog>` elements with focus trapping and `Escape` dismiss.
```

---

## 2. New Issue Draft: Auto-sync Initial Preview State

**Title**: `[Editor UX] Auto-sync initial preview state when dist/ is pre-populated at startup`  
**Labels**: `editor`, `ux`, `enhancement`  

### Description:

### Summary
When `boris-editor` is launched on a repository that already contains built `dist/` artifacts (e.g. from a previous `boris build` or `boris watch`), the preview pane initially reports:

```text
stale: Existing preview output is previous/stale until rebuilt.
```

The embedded preview iframe remains empty until the user explicitly saves a file or clicks the **Rebuild preview** button.

### Expected Behavior
If a valid `dist/index.html` exists at host startup, the editor should inspect the current output generation and initialize the preview state to `success` (or trigger an initial non-blocking background sync) so the author sees their site immediately upon opening the editor.

### Proposed Implementation
1. In `editor/src/preview.zig`, check if `dist/index.html` is present during `preview.Manager.init` or first `/api/preview/state` query.
2. If present and valid, report `phase: .success` with `generation: 1` rather than `.idle` / `.stale`.
3. UI in `editor/ui/src/App.svelte` will automatically render the iframe on initial connection.

---

## 3. New Issue Draft: Auto-Focus Filter Input on Category Switch

**Title**: `[Editor A11y] Auto-focus filter input when switching completion categories`  
**Labels**: `editor`, `a11y`, `keyboard-navigation`  

### Description:

### Summary
In the Boris authoring hints section, changing the `<select id="completion-kind">` dropdown clears the query input and resets the selected suggestion, but leaves keyboard focus on the `<select>` element.

### Expected Behavior
For seamless keyboard and voice-control authoring, selecting a new completion category (e.g. switching from `frontmatter_key` to `relation_kind` or `entity`) should automatically focus `#completion-query` so the user can immediately begin filtering suggestions without needing an extra `Tab` key press.

### Proposed Implementation
In `editor/ui/src/App.svelte`:
```svelte
<select
  id="completion-kind"
  bind:value={completionKind}
  onchange={() => {
    completionQuery = '';
    selectedSuggestion = 0;
    tick().then(() => document.getElementById('completion-query')?.focus());
  }}
>
```

---

## 4. New Issue Draft: Visual Confirmation on Diagnostic Packet Copy

**Title**: `[Editor UX] Add transient visual confirmation when copying diagnostic packets`  
**Labels**: `editor`, `ux`, `diagnostics`  

### Description:

### Summary
In the Problems pane, clicking **Copy packet for `<CODE>` at `<PATH>`** writes the bounded diagnostic JSON payload to the clipboard and updates the live status region text (`Copied diagnostic packet for ... to clipboard.`). However, the button itself has no transient visual state.

### Expected Behavior
To provide immediate feedback to sighted and pointer users, the button label should temporarily switch to `"Copied!"` (or display a confirmation badge) for ~1.5s before reverting to its standard accessible label.

### Proposed Implementation
1. Track active copied button state in `App.svelte` (`let copiedProblemPacketId = ''`).
2. When clicked, set `copiedProblemPacketId = problem.id ?? problem.code` and clear via `setTimeout` after 1500ms.
3. Preserve the full accessible label via `aria-label` while presenting the visual confirmation text.

---

## 5. New Issue Draft: Surface the live validation cycle and report age

**Title**: `[Editor UX] Show the validation daemon cycle and report age in the status line`
**Labels**: `editor`, `ux`, `validation`

### Summary

The editor already receives the daemon's validation state and completed cycle
counter, but the Problems pane only names the state. An author cannot tell
which report they are looking at or whether a successful report is becoming
old while the daemon is quiet or delayed.

### Expected Behavior

When the compiler supports `validate --watch`, show the live completed cycle
and report age beside the existing validation state, for example:

```text
Validation passed (cycle 5).    Cycle 5 · Report age: 4s
```

Before the first report, show an honest missing age (`Report age: —`). The age
must come from the daemon's report signature, update with the existing state
poll, and remain absent on the one-shot fallback path. No compiler result is
inferred from elapsed time.

### Acceptance Criteria

- [ ] `/api/validate-state` includes `report_age_ms`, or `null` before a report.
- [ ] The editor status line surfaces the current cycle and a human-readable
      report age next to idle/running/success/failed/stale state text.
- [ ] The age advances while the report remains unchanged; cycle changes still
      refresh the Problems surface as before.
- [ ] One-shot hosts and existing validation-state labels remain unchanged.
- [ ] Gates: `npm run check`, `npm run build`, editor host tests, validation
      daemon integration, and Playwright.
