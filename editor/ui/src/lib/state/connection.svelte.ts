// editor/ui/src/lib/state/connection.svelte.ts
// Host connection state: the status strings, the project shape reported by
// /api/health, the compiler identity from /api/version, and whether the host
// advertises the validate --watch daemon. Status copy stays honest: the
// strings only restate what a host payload actually said.

import { elapsedLabel } from '../api';
import { versionLabel } from '../utils';
import type { Health, Version } from '../types';

// `phase` is the machine-readable twin of the status pair, written by the same
// functions, so panes can tell "still loading" from "never loaded" without
// parsing a sentence. `loaded` stays true once the initial host payloads
// arrived: a later host failure leaves the last real data on screen.
export type ConnectionPhase = 'connecting' | 'connected' | 'failed' | 'token-missing' | 'host-unavailable';

export const connection = $state({
  // The compact label the header chip shows (#993). It is written together
  // with the honest sentence below — never derived by parsing it — so a short
  // label can never quietly disagree with the detail it summarizes.
  summary: 'Connecting…',
  status: 'Connecting to the local host…',
  phase: 'connecting' as ConnectionPhase,
  loaded: false,
  compiler: 'Checking Boris version…',
  project: 'Checking project conventions…',
  inputMode: 'empty' as NonNullable<Health['project']['input_mode']>,
  validateDaemon: false
});

// The single writer for the status pair: the chip's short label and the full
// sentence the author expands on demand. Both are honest restatements of what
// a host payload said, so they change in the same place and stay in step.
function setStatus(phase: ConnectionPhase, summary: string, detail: string) {
  connection.phase = phase;
  connection.summary = summary;
  connection.status = detail;
}

export function markTokenMissing() {
  setStatus('token-missing', 'Token missing', 'Session token missing. Launch the editor from boris-editor.');
  connection.compiler = 'Boris version unavailable.';
  connection.project = 'Project status unavailable.';
}

export function markConnected(editorId: string, started: number) {
  setStatus('connected', 'Connected', `Connected to ${editorId}. Opened project in ${elapsedLabel(started)}.`);
  connection.loaded = true;
}

export function applyHealth(health: Health) {
  connection.inputMode = health.project.input_mode ?? 'empty';
  connection.project = health.project.content
    ? `Project found${health.project.publication_profile ? ' with boris.json' : ''}${
        connection.inputMode === 'cooklang'
          ? '; Cooklang tree (--cooklang)'
          : connection.inputMode === 'textile'
            ? '; Textile tree (--textile)'
            : ''
      }.`
    : 'This folder is not a Boris project.';
}

export function applyVersion(version: Version) {
  connection.compiler = versionLabel(version);
  connection.validateDaemon = version.supported?.validate_watch ?? false;
}

export function markConnectFailed() {
  connection.phase = 'failed';
  connection.compiler = 'Boris version unavailable.';
  connection.project = 'Project status unavailable.';
}

// The host-unavailable sentence is also the guard other host-watch paths use
// to tell "already reported" from "just failed", so it lives here with the
// writer instead of being re-typed at each site — one place to keep the short
// label and the sentence in step with each other.
export const HOST_UNAVAILABLE_DETAIL = 'Local host unavailable. Restart boris-editor.';

export function markHostUnavailable() {
  setStatus('host-unavailable', 'Host unavailable', HOST_UNAVAILABLE_DETAIL);
}

// Visual tone for the header chip. Only a live connection reads calm; every
// failure phase is loud, because nothing below it can be trusted to refresh.
export function connectionTone(): 'neutral' | 'ok' | 'danger' {
  if (connection.phase === 'connected') return 'ok';
  if (connection.phase === 'connecting') return 'neutral';
  return 'danger';
}
