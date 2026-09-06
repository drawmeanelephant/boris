// editor/ui/src/lib/state/problems.svelte.ts
// Boris diagnostics: the last command result, the command status line,
// running/impact/packet-copy state, the validate --watch daemon state, and
// the derived problem surfaces — grouped problems, problems in the open
// file, per-problem staleness (#660/#662), the honest empty-pane notice
// (#658), layout selections, and the recipe scale view.

import { api, elapsedLabel } from '../api';
import { failureLabel, groupProblems, packetCopyKey, projectPathForProblem } from '../utils';
import type { CommandResult, Problem, ProblemGroup, RecipeScaleView, ValidateState } from '../types';
import { buffer, dirty } from './buffer.svelte';
import { connection } from './connection.svelte';
import { graph, activeNode } from './graph.svelte';

export const problems = $state({
  result: null as CommandResult | null,
  status: 'No Boris command has run yet.',
  running: false,
  impactId: '',
  copiedPacketKey: '',
  validateState: null as ValidateState | null,
  lastValidateCycle: -1,
  scaleFactor: '',
  scaleView: null as RecipeScaleView | null
});

export function problemGroups(): ProblemGroup[] {
  return groupProblems(problems.result?.problems ?? []);
}

// Honest empty-pane naming (#658): distinguish "the tree was never
// validated" from "the newest report has zero problems". The notice is
// derived purely from state the host already sends (validate-state for the
// daemon path, commandResult presence for the one-shot path) and only
// renders when the pane has nothing to list and the last command was
// validate (or none) — so it can never contradict a different command's
// problem list. `clean` marks a claim about a completed report, which is
// what earns the dirty-buffer caveat.
export function problemsNotice(): { text: string; clean: boolean } {
  const results = problems.result?.problems ?? [];
  if (results.length > 0) return { text: '', clean: false };
  if (problems.result && problems.result.mode !== 'validate') return { text: '', clean: false };
  if (connection.validateDaemon) {
    if (!problems.validateState) return { text: '', clean: false };
    switch (problems.validateState.state) {
      case 'idle':
        return { text: 'No validation report yet. Run Validate project to start the daemon.', clean: false };
      case 'running':
        return { text: 'Waiting for the first validation cycle…', clean: false };
      case 'success':
        if ((problems.validateState.problems_count ?? 0) > 0) return { text: '', clean: false };
        return { text: `No problems in the newest report (cycle ${problems.validateState.cycle ?? 0}).`, clean: true };
      default:
        return { text: '', clean: false };
    }
  }
  if (problems.result == null) {
    return { text: 'No validation report yet. Run Validate project to check the tree.', clean: false };
  }
  return { text: '', clean: false };
}

export function activeProblems(): Problem[] {
  return (problems.result?.problems ?? []).filter(
    problem => problem.source_path !== null && projectPathForProblem(problem.source_path) === buffer.activePath
  );
}

// Per-problem staleness (#660, #662): a problem is possibly stale when the
// open buffer changed the problem's own source region since the last report
// and the caret currently sits inside that region. Lines are compared
// against `baseline` (the last loaded/saved buffer, i.e. the report-time
// snapshot); edits on other lines and problems in other files never mark
// anything. The #662 drift extension also marks when the buffer's line count
// changed and the first divergence from `baseline` sits strictly above the
// problem's line: the reported line number may address moved text even when
// the text at that line happens to match (e.g. adjacent identical lines).
// That is the documented approximation from #662 — it errs toward honesty,
// and the mark clears on caret move or save; identical-line insertion above
// stays ambiguous from text alone.
export function staleProblems(): Set<Problem> {
  const set = new Set<Problem>();
  if (!dirty() || !buffer.activePath || buffer.content === buffer.baseline) return set;
  const savedLines = buffer.baseline.split('\n');
  const bufferLines = buffer.content.split('\n');
  const changed = new Set<number>();
  let firstDiff = -1;
  for (let index = 0; index < Math.max(savedLines.length, bufferLines.length); index += 1) {
    if (savedLines[index] !== bufferLines[index]) {
      changed.add(index + 1);
      if (firstDiff < 0) firstDiff = index;
    }
  }
  if (changed.size === 0) return set;
  const lineCountChanged = savedLines.length !== bufferLines.length;
  for (const problem of activeProblems()) {
    if (!problem.source_path || problem.line == null) continue;
    if (problem.position_confidence === 'none') continue;
    if (problem.line !== buffer.cursor.line) continue;
    if (problem.column != null && buffer.cursor.column < problem.column) continue;
    if (changed.has(problem.line)) {
      set.add(problem);
      continue;
    }
    if (lineCountChanged && firstDiff >= 0 && firstDiff < problem.line - 1) set.add(problem);
  }
  return set;
}

export function layoutSelections(): Problem[] {
  return (problems.result?.problems ?? []).filter(problem => problem.code === 'ILAYOUTSELECTED');
}

export function visibleScaleView(): RecipeScaleView | null {
  const node = activeNode();
  return problems.scaleView && node && problems.scaleView.page === node.id ? problems.scaleView : null;
}

let copiedPacketTimer: ReturnType<typeof setTimeout> | undefined;

export async function copyDiagnosticPacket(problem: Problem) {
  try {
    await navigator.clipboard.writeText(problem.packet);
    problems.status = `Copied diagnostic packet for ${problem.code ?? 'unstructured Boris output'}.`;
    problems.copiedPacketKey = packetCopyKey(problem);
    if (copiedPacketTimer !== undefined) clearTimeout(copiedPacketTimer);
    copiedPacketTimer = setTimeout(() => {
      problems.copiedPacketKey = '';
      copiedPacketTimer = undefined;
    }, 1500);
  } catch {
    problems.status = 'Could not copy the diagnostic packet. Clipboard access was denied.';
  }
}

// With a `validate --watch` daemon the host rewrites the report on its own
// debounced cycle after every save; this poller watches the cycle counter
// and pulls the newest problems only when a cycle actually completes.

let validateStateTimer: ReturnType<typeof setInterval> | undefined;

export function startValidateWatch() {
  if (validateStateTimer) return;
  validateStateTimer = setInterval(() => void watchValidateState(), 1000);
}

async function watchValidateState() {
  if (!connection.validateDaemon) return;
  const result = await api<ValidateState>('/api/validate-state');
  if (!result.response.ok) return;
  const state = result.data as ValidateState;
  problems.validateState = state;
  if (state.cycle === undefined || state.cycle === problems.lastValidateCycle) return;
  problems.lastValidateCycle = state.cycle;
  await refreshValidate();
}

let saveRefreshTimer: ReturnType<typeof setTimeout> | undefined;

// A successful save is the highest-signal moment for validation feedback:
// fire the existing cycle-aware refresh on a short trailing debounce so
// rapid saves coalesce, instead of waiting for the next 1 s poll tick (#656).
export function scheduleValidateRefresh() {
  if (saveRefreshTimer) clearTimeout(saveRefreshTimer);
  saveRefreshTimer = setTimeout(() => {
    saveRefreshTimer = undefined;
    void refreshValidate();
  }, 300);
}

// Honest state naming for the problems surface (#654): the daemon reports
// idle/running/success/failed/stale, and the shell names exactly what the
// validate-state payload says — never a fabricated mid-cycle state.
export async function refreshValidate() {
  const started = Date.now();
  const result = await api<CommandResult>('/api/commands/run', {
    method: 'POST',
    body: JSON.stringify({ mode: 'validate' })
  });
  if (!result.response.ok) return;
  problems.result = result.data as CommandResult;
  problems.status = `Validation updated from the daemon: ${failureLabel(problems.result.failure_class, problems.result.exit_code)}. (${elapsedLabel(started)})`;
}
