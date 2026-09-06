// editor/ui/src/lib/state/connection.svelte.ts
// Host connection state: the status strings, the project shape reported by
// /api/health, the compiler identity from /api/version, and whether the host
// advertises the validate --watch daemon. Status copy stays honest: the
// strings only restate what a host payload actually said.

import { elapsedLabel } from '../api';
import { versionLabel } from '../utils';
import type { Health, Version } from '../types';

export const connection = $state({
  status: 'Connecting to the local host…',
  compiler: 'Checking Boris version…',
  project: 'Checking project conventions…',
  inputMode: 'empty' as NonNullable<Health['project']['input_mode']>,
  validateDaemon: false
});

export function markTokenMissing() {
  connection.status = 'Session token missing. Launch the editor from boris-editor.';
  connection.compiler = 'Boris version unavailable.';
  connection.project = 'Project status unavailable.';
}

export function markConnected(editorId: string, started: number) {
  connection.status = `Connected to ${editorId}. Opened project in ${elapsedLabel(started)}.`;
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
  connection.compiler = 'Boris version unavailable.';
  connection.project = 'Project status unavailable.';
}

export function markHostUnavailable() {
  connection.status = 'Local host unavailable. Restart boris-editor.';
}
