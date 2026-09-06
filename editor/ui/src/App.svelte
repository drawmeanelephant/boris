<script lang="ts">
  import { tick } from 'svelte';
  import { token, launchOpenPath, api, elapsedLabel, hostErrorLabel, isLaunchOpenSafe } from './lib/api';
  import type {
    Health,
    Version,
    FileList,
    BufferResponse,
    ProbeResponse,
    RecoverySnapshot,
    ErrorResponse,
    CommandMode,
    PendingResolution,
    PaletteItem,
    Problem,
    AnalysisFinding,
    PublicationPayload,
    CommandResult,
    AuthoringPayload,
    PreviewState,
    GraphNode,
    GraphPayload
  } from './lib/types';
  import {
    commandLabel,
    failureLabel,
    projectPathForProblem,
    projectPathForGraphSource,
    nodeForId,
    paletteItemKey,
    sourceOffset,
    defaultCreatePath
  } from './lib/utils';
  import { connection, applyHealth, applyVersion, markConnected, markTokenMissing, markConnectFailed, markHostUnavailable } from './lib/state/connection.svelte';
  import { project, refreshFiles } from './lib/state/project.svelte';
  import { buffer, dirty, loadBuffer, resetBuffer, undo, redo, trackCursor, discardBuffer, clearRecovery, stopRecoveryTimer, flushRecovery, loadRecovery, markBufferHostUnavailable } from './lib/state/buffer.svelte';
  import { authoring, suggestions, refreshAuthoring, setAuthoring } from './lib/state/authoring.svelte';
  import { graph, activeNode, parentNode, refreshGraph, setGraph } from './lib/state/graph.svelte';
  import { publication, refreshPublication, setPublication } from './lib/state/publication.svelte';
  import { preview, setPreview, noteWatchRefusal, refreshPreviewState } from './lib/state/preview.svelte';
  import { focusMode, openFocusMode, closeFocusMode, initFocusLayout, initFocusType, initFocusZen, focusReturnElement, setFocusReturn } from './lib/state/focus.svelte';
  import { problems, copyDiagnosticPacket, scheduleValidateRefresh, startValidateWatch } from './lib/state/problems.svelte';
  import {
    startWatchStateWatch,
    startWatchDaemon,
    stopWatchDaemon,
    watchStartEnabled,
    watchStopEnabled
  } from './lib/state/watch.svelte';
  import { palette, paletteItems, paletteEnabled } from './lib/state/palette.svelte';
  import { dialogs, resolutionPrompt, resolutionVerb, openModal, restoreDialogFocus } from './lib/state/dialogs.svelte';
  import Header from './components/Header.svelte';
  import FocusMode from './components/FocusMode.svelte';
  import SectionNav from './components/SectionNav.svelte';
  import RecoveryBanner from './components/RecoveryBanner.svelte';
  import ProjectPane from './components/ProjectPane.svelte';
  import SourcePane from './components/SourcePane.svelte';
  import ProblemsPane from './components/ProblemsPane.svelte';
  import PreviewPane from './components/PreviewPane.svelte';
  import WatchPane from './components/WatchPane.svelte';
  import ConflictDialog from './dialogs/ConflictDialog.svelte';
  import ResolutionDialog from './dialogs/ResolutionDialog.svelte';
  import CreateDialog from './dialogs/CreateDialog.svelte';
  import RenameDialog from './dialogs/RenameDialog.svelte';
  import DeleteDialog from './dialogs/DeleteDialog.svelte';
  import CommandPalette from './dialogs/CommandPalette.svelte';

  let conflictDialog = $state() as HTMLDialogElement;
  let resolutionDialog = $state() as HTMLDialogElement;
  let createDialog = $state() as HTMLDialogElement;
  let renameDialog = $state() as HTMLDialogElement;
  let deleteDialog = $state() as HTMLDialogElement;
  let paletteDialog = $state() as HTMLDialogElement;

  let hostTimer: ReturnType<typeof setInterval> | undefined;
  let diskTimer: ReturnType<typeof setInterval> | undefined;
  let probeInFlight = false;

  // The completion combobox selection must always point at a live suggestion;
  // run after render so newly derived suggestion lists are already in place.
  $effect(() => {
    if (authoring.selectedSuggestion >= suggestions().length) {
      authoring.selectedSuggestion = Math.max(0, suggestions().length - 1);
    }
  });

  // The palette selection clamp: when the selected item is disabled (or gone),
  // land on the first enabled item. Mirrors the legacy reactive statement.
  $effect(() => {
    if (paletteEnabled().size === 0) return;
    const current = paletteItems()[palette.selection];
    const currentEnabled = current ? paletteEnabled().get(paletteItemKey(current)) : undefined;
    if (!currentEnabled) {
      const first = paletteItems().findIndex(item => paletteEnabled().get(paletteItemKey(item)));
      palette.selection = first >= 0 ? first : 0;
    }
  });

  async function connect() {
    if (!token) {
      markTokenMissing();
      return;
    }
    const started = Date.now();
    try {
      const [healthResult, versionResult, filesResult, authoringResult, graphResult, previewResult, publicationResult] = await Promise.all([
        api<Health>('/api/health'),
        api<Version>('/api/version'),
        api<FileList>('/api/files'),
        api<AuthoringPayload>('/api/authoring'),
        api<GraphPayload>('/api/graph'),
        api<PreviewState>('/api/preview/state'),
        api<PublicationPayload>('/api/publication')
      ]);
      if (![healthResult, versionResult, filesResult].every(result => result.response.ok)) {
        throw new Error('host request failed');
      }
      markConnected(healthResult.data.editor_id, started);
      applyVersion(versionResult.data);
      applyHealth(healthResult.data);
      dialogs.createPath = defaultCreatePath(connection.inputMode);
      project.files = filesResult.data.files;
      if (authoringResult.response.ok) setAuthoring(authoringResult.data);
      else authoring.status = 'Boris authoring vocabulary is unavailable.';
      if (graphResult.response.ok) setGraph(graphResult.data);
      else graph.status = 'Boris graph is unavailable.';
      if (publicationResult.response.ok) setPublication(publicationResult.data);
      else publication.status = 'Publication profiles are unavailable.';
      if (previewResult.response.ok) setPreview(previewResult.data);
      const recovery = await loadRecovery();
      if (recovery.ok) {
        if (recovery.skipped > 0) {
          buffer.editorStatus = `${recovery.skipped} recovery snapshot${recovery.skipped === 1 ? ' was' : 's were'} unreadable and ignored.`;
        }
      } else {
        buffer.editorStatus = 'Project files are available, but recovery snapshots could not be loaded.';
      }
      if (launchOpenPath) {
        if (isLaunchOpenSafe(launchOpenPath)) {
          void openFile(launchOpenPath);
        } else {
          buffer.editorStatus = `Launch open path ignored: ${launchOpenPath} is not an author-owned project file.`;
        }
      }
      startHostWatch();
      startDiskWatch();
      if (connection.validateDaemon) startValidateWatch();
      startWatchStateWatch();
    } catch {
      noteHostUnavailable();
      markConnectFailed();
    }
  }

  // Mirrors editor/src/file_api.zig `validatePath` (the authoritative rule):
  // a launch target must be an author-owned project file. This pre-check keeps
  // an unsafe `open=` fragment from even reaching the host; the host still
  // re-validates every open request.

  async function openFile(path: string): Promise<boolean> {
    if (path === buffer.activePath) return true;
    if (dirty()) {
      await requestResolution({ action: 'open', target: path });
      return false;
    }
    const started = Date.now();
    buffer.editorStatus = `Opening ${path}…`;
    const result = await api<BufferResponse | ErrorResponse>('/api/files/open', {
      method: 'POST', body: JSON.stringify({ path })
    });
    if (result.response.ok) {
      const opened = result.data as BufferResponse;
      const wait = elapsedLabel(started);
      loadBuffer(opened, opened.read_only ? `Opened ${path} read-only. (${wait})` : `Opened ${path}. (${wait})`);
      return true;
    } else {
      buffer.editorStatus = `Could not open ${path}: ${hostErrorLabel((result.data as ErrorResponse).error)}.`;
      return false;
    }
  }

  async function runCommand(mode: CommandMode) {
    if (dirty()) {
      await requestResolution({ action: 'command', mode });
      return;
    }
    if (mode === 'impact' && !problems.impactId.trim()) {
      problems.status = 'Enter an entity or source endpoint before running impact.';
      return;
    }
    if (mode === 'plan' && !publication.selectedProfile.trim()) {
      problems.status = 'Choose a publication profile before running the plan.';
      return;
    }
    if (mode === 'recipe_scale' && !activeNode()) {
      problems.status = 'Open a recipe page before scaling.';
      return;
    }
    if (mode === 'recipe_scale' && !problems.scaleFactor.trim()) {
      problems.status = 'Enter a scale factor before scaling the recipe.';
      return;
    }
    problems.running = true;
    const started = Date.now();
    problems.status = `Running ${commandLabel(mode)}…`;
    const body = mode === 'impact'
      ? { mode, impact_id: problems.impactId.trim() }
      : mode === 'plan'
        ? { mode, profile: publication.selectedProfile.trim() }
        : mode === 'recipe_scale'
          ? { mode, recipe_scale_id: activeNode()!.id, recipe_scale_factor: problems.scaleFactor.trim() }
        : { mode };
    const result = await api<CommandResult | ErrorResponse>('/api/commands/run', {
      method: 'POST', body: JSON.stringify(body)
    });
    problems.running = false;
    if (!result.response.ok) {
      problems.status = `Could not run ${commandLabel(mode)}: ${hostErrorLabel((result.data as ErrorResponse).error)}.`;
      return;
    }
    problems.result = result.data as CommandResult;
    problems.status = `${commandLabel(mode)} finished: ${failureLabel(problems.result.failure_class, problems.result.exit_code)}. (${elapsedLabel(started)})`;
    if (problems.result.failure_class === 'terminated') {
      problems.status += ' Run the same command again when Boris is ready.';
    }
    if (mode === 'html_build') {
      preview.status = problems.result.failure_class === 'success'
        ? 'The last HTML build succeeded. Live preview serving arrives in the preview slice.'
        : 'The HTML build failed. Existing dist output, if any, is previous and stale.';
    }
    if (mode === 'ir_build' && problems.result.failure_class === 'success') {
      await refreshAuthoring();
      await refreshGraph();
    }
    if (problems.result.publication_plan) publication.lastPlan = problems.result.publication_plan;
    if (mode === 'recipe_scale' && problems.result.failure_class === 'success' && problems.result.recipe_scale_view) {
      problems.scaleView = problems.result.recipe_scale_view;
    }
    if (mode === 'html_build' || mode === 'plan') await refreshPublication();
  }

  async function rebuildPreview(reason: 'save' | 'manual' = 'manual') {
    if (dirty()) {
      await requestResolution({ action: 'preview', reason });
      return;
    }
    const previousData = preview.data;
    if (preview.data) preview.data = { ...preview.data, phase: 'running' };
    const started = Date.now();
    preview.status = reason === 'save' ? 'Saved. Boris preview build is running…' : 'Boris preview build is running…';
    const result = await api<PreviewState | ErrorResponse>('/api/preview/rebuild', { method: 'POST', body: '{}' });
    if (result.response.ok) {
      setPreview(result.data as PreviewState);
      preview.status = `${preview.status} (${elapsedLabel(started)})`;
    } else if ((result.data as ErrorResponse).error === 'watch_daemon_active') {
      // The managed watch daemon owns the dist/ writer seat: undo the
      // optimistic running phase and surface the refusal with a pointer to
      // the Watch pane instead of a generic host failure.
      if (previousData) preview.data = previousData;
      noteWatchRefusal();
    } else preview.status = `Preview host failed: ${(result.data as ErrorResponse).error ?? 'request failed'}. Existing output is not current.`;
  }

  async function openGraphPath(path: string) {
    await openFile(path);
  }

  async function openGraphNode(node: GraphNode | null) {
    if (!node) return;
    await openGraphPath(projectPathForGraphSource(node.sourcePath));
  }

  async function runImpactOnCurrent() {
    const node = activeNode();
    if (!node) return;
    problems.impactId = node.id;
    await runCommand('impact');
  }

  function resetScale() {
    problems.scaleView = null;
    problems.status = 'Showing authored recipe quantities.';
  }

  async function navigateToProblem(problem: Problem | AnalysisFinding) {
    if (!problem.source_path) return;
    const path = projectPathForProblem(problem.source_path);
    if (!await openFile(path)) return;
    await tick();
    const editor = document.getElementById('source-editor') as HTMLTextAreaElement | null;
    if (!editor) return;
    const offset = sourceOffset(buffer.content, problem.line, problem.column);
    editor.focus();
    editor.setSelectionRange(offset, offset);
    trackCursor();
    editor.scrollTop = Math.max(0, editor.scrollHeight * (offset / Math.max(1, buffer.content.length)) - editor.clientHeight / 2);
    buffer.editorStatus = problem.line
      ? `Moved to ${path}, line ${problem.line}${problem.column ? `, column ${problem.column}` : ''}.`
      : `Opened ${path} for this Boris finding.`;
  }

  function startHostWatch() {
    if (hostTimer) return;
    hostTimer = setInterval(() => void watchHost(), 5000);
  }

  function startDiskWatch() {
    if (diskTimer) return;
    diskTimer = setInterval(() => void probeDisk(), 3000);
  }

  async function watchHost() {
    const result = await api<Health>('/api/health');
    if (!result.response.ok) noteHostUnavailable();
  }

  function noteHostUnavailable() {
    const next = 'Local host unavailable. Restart boris-editor.';
    if (connection.status === next) return;
    markHostUnavailable();
    markBufferHostUnavailable();
  }

  async function probeDisk() {
    if (!buffer.activePath || !buffer.fingerprint || buffer.saveInFlight || probeInFlight) return;
    if (document.querySelector('dialog[open]')) return;
    probeInFlight = true;
    try {
      const result = await api<ProbeResponse | ErrorResponse>('/api/files/probe', {
        method: 'POST',
        body: JSON.stringify({ path: buffer.activePath, fingerprint: buffer.fingerprint })
      });
      if (!result.response.ok) {
        if ((result.data as ErrorResponse).error === 'host_unavailable') noteHostUnavailable();
        return;
      }
      const probe = result.data as ProbeResponse;
      if (probe.status === 'transient') return;
      if (probe.status === 'unchanged') {
        if (probe.read_only !== undefined && probe.read_only !== buffer.readOnly) {
          buffer.readOnly = probe.read_only;
          buffer.editorStatus = probe.read_only
            ? `${buffer.activePath} is now read-only on disk.`
            : `${buffer.activePath} is writable again.`;
        }
        return;
      }
      await refreshFiles();
      if (probe.status === 'deleted') {
        if (dirty()) {
          buffer.conflict = null;
          buffer.deletedConflict = true;
          buffer.editorStatus = `${buffer.activePath} was deleted outside the editor.`;
          await tick();
          openModal(conflictDialog);
          conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
        } else {
          const gone = buffer.activePath;
          stopRecoveryTimer();
          resetBuffer();
          buffer.editorStatus = `${gone} was deleted outside the editor.`;
        }
        return;
      }
      if (probe.status !== 'changed' || probe.content === undefined || !probe.fingerprint || !probe.path) return;
      const disk: BufferResponse = {
        status: 'conflict',
        path: probe.path,
        content: probe.content,
        fingerprint: probe.fingerprint,
        read_only: probe.read_only ?? false
      };
      if (dirty()) {
        buffer.conflict = disk;
        buffer.deletedConflict = false;
        buffer.editorStatus = `External changes detected in ${buffer.activePath}. Nothing was overwritten.`;
        await tick();
        openModal(conflictDialog);
        conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
      } else {
        loadBuffer(disk, `Loaded external changes to ${probe.path}.`);
      }
    } finally {
      probeInFlight = false;
    }
  }

  async function saveFile(recreate = false, replacementFingerprint: string = buffer.fingerprint): Promise<boolean> {
    if (!buffer.activePath || buffer.readOnly || !dirty() || buffer.saveInFlight) return false;
    // Capture before saveInFlight disables Save file; otherwise the conflict
    // dialog would remember <body> and Esc could not restore the trigger (#462).
    const trigger = document.activeElement;
    const started = Date.now();
    buffer.saveInFlight = true;
    buffer.editorStatus = `Saving ${buffer.activePath}…`;
    try {
      const result = await api<BufferResponse | ErrorResponse>('/api/files/save', {
        method: 'POST',
        body: JSON.stringify({ path: buffer.activePath, content: buffer.content, fingerprint: replacementFingerprint, recreate })
      });
      if (result.response.ok) {
        const saved = result.data as BufferResponse;
        loadBuffer(saved, `Saved ${buffer.activePath}. (${elapsedLabel(started)})`);
        buffer.snapshots = buffer.snapshots.filter(snapshot => snapshot.path !== buffer.activePath);
        buffer.conflict = null;
        buffer.deletedConflict = false;
        dialogs.skipFocusRestore = true;
        conflictDialog?.close();
        await refreshFiles();
        await rebuildPreview('save');
        if (connection.validateDaemon) scheduleValidateRefresh();
        return true;
      }
      const error = result.data as ErrorResponse;
      if (result.response.status === 409 && error.status === 'conflict') {
        buffer.conflict = result.data as BufferResponse;
        buffer.deletedConflict = false;
        buffer.editorStatus = `External changes detected in ${buffer.activePath}. Nothing was overwritten.`;
        await tick();
        openModal(conflictDialog, trigger);
        conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
      } else if (result.response.status === 409 && error.status === 'deleted') {
        buffer.conflict = null;
        buffer.deletedConflict = true;
        buffer.editorStatus = `${buffer.activePath} was deleted outside the editor. Nothing was written.`;
        await tick();
        openModal(conflictDialog, trigger);
        conflictDialog.querySelector<HTMLButtonElement>('.dialog-actions .primary')?.focus();
      } else if (error.error === 'read_only') {
        buffer.readOnly = true;
        buffer.editorStatus = `${buffer.activePath} is read-only. Nothing was written.`;
      } else {
        if (error.error === 'host_unavailable') noteHostUnavailable();
        buffer.editorStatus = `Save failed for ${buffer.activePath}: ${hostErrorLabel(error.error)}. Your buffer remains unsaved.`;
      }
      return false;
    } finally {
      buffer.saveInFlight = false;
    }
  }

  async function requestResolution(pending: PendingResolution) {
    dialogs.pendingResolution = pending;
    await tick();
    openModal(resolutionDialog);
  }

  async function resolvePendingSave() {
    const pending = dialogs.pendingResolution;
    if (!pending) return;
    dialogs.pendingResolution = null;
    dialogs.skipFocusRestore = true;
    resolutionDialog.close();
    if (await saveFile()) {
      await proceedAfterResolution(pending);
    } else if (buffer.readOnly) {
      buffer.editorStatus = `${buffer.activePath} is read-only, so it was not saved. Discard the unsaved buffer to continue.`;
    }
  }

  async function resolvePendingDiscard() {
    const pending = dialogs.pendingResolution;
    if (!pending) return;
    dialogs.pendingResolution = null;
    dialogs.skipFocusRestore = true;
    resolutionDialog.close();
    await discardBuffer();
    await proceedAfterResolution(pending);
  }

  async function proceedAfterResolution(pending: PendingResolution) {
    if (pending.action === 'open') {
      await openFile(pending.target);
    } else if (pending.action === 'command') {
      await runCommand(pending.mode);
    } else if (pending.action === 'restore') {
      await restoreSnapshot(pending.snapshot);
    } else {
      await rebuildPreview(pending.reason);
    }
  }

  async function loadDiskVersion() {
    if (!buffer.conflict) return;
    loadBuffer(buffer.conflict, `Loaded the current disk version of ${buffer.activePath}.`);
    await clearRecovery(buffer.activePath);
    buffer.conflict = null;
    dialogs.skipFocusRestore = true;
    conflictDialog.close();
  }

  async function discardDeletedBuffer() {
    const discardedPath = buffer.activePath;
    await clearRecovery(discardedPath);
    stopRecoveryTimer();
    resetBuffer();
    buffer.deletedConflict = false;
    dialogs.skipFocusRestore = true;
    conflictDialog.close();
    buffer.editorStatus = `Discarded unsaved changes for deleted file ${discardedPath}.`;
    await refreshFiles();
  }

  async function restoreSnapshot(snapshot: RecoverySnapshot) {
    if (dirty()) {
      await requestResolution({ action: 'restore', snapshot });
      return;
    }
    const opened = await api<BufferResponse>('/api/files/open', {
      method: 'POST', body: JSON.stringify({ path: snapshot.path })
    });
    if (opened.response.ok) {
      loadBuffer(opened.data, `Recovered unsaved work for ${snapshot.path}.`);
      buffer.content = snapshot.content;
    } else if (opened.response.status === 404) {
      buffer.activePath = snapshot.path;
      buffer.content = snapshot.content;
      buffer.baseline = '';
      buffer.fingerprint = snapshot.fingerprint;
      buffer.readOnly = false;
      buffer.undoStack = [];
      buffer.redoStack = [];
      buffer.editorStatus = `Recovered unsaved work for deleted file ${snapshot.path}.`;
    } else {
      buffer.editorStatus = `Could not restore recovered work for ${snapshot.path}.`;
    }
  }

  async function createFile() {
    const path = dialogs.createPath.trim();
    if (!path) return;
    const result = await api<BufferResponse | ErrorResponse>('/api/files/create', {
      method: 'POST', body: JSON.stringify({ path, content: '' })
    });
    if (result.response.ok) {
      dialogs.skipFocusRestore = true;
      createDialog.close();
      await refreshFiles();
      loadBuffer(result.data as BufferResponse, `Created ${path}.`);
    } else {
      buffer.editorStatus = `Could not create ${path}: ${hostErrorLabel((result.data as ErrorResponse).error)}.`;
    }
  }

  function openCreateDialog() {
    dialogs.createPath = defaultCreatePath(connection.inputMode);
    openModal(createDialog);
  }

  function openRenameDialog() {
    dialogs.renamePath = buffer.activePath;
    openModal(renameDialog);
  }

  function openDeleteDialog() {
    openModal(deleteDialog);
    deleteDialog.querySelector<HTMLButtonElement>('.dialog-actions .danger')?.focus();
  }

  function paletteItemEnabled(item: PaletteItem): boolean {
    if (item.kind === 'open' || item.kind === 'source' || item.kind === 'entity') return true;
    if (item.kind === 'focus-enter') return !focusMode.open;
    if (item.kind === 'focus-exit') return focusMode.open;
    if (item.kind === 'parent') return parentNode() !== null;
    if (item.kind === 'impact-here') return activeNode() !== null && !problems.running;
    if (item.kind === 'save') return dirty() && !buffer.readOnly && !buffer.saveInFlight;
    if (item.kind === 'preview') return preview.data?.phase !== 'running';
    if (item.kind === 'command') return !problems.running;
    if (item.kind === 'watch-start') return watchStartEnabled();
    if (item.kind === 'watch-stop') return watchStopEnabled();
    if (item.kind === 'watch-go') return true;
    if (dirty()) return false;
    return item.kind === 'create' || buffer.activePath !== '';
  }

  function paletteEnabledIndices(): number[] {
    return paletteItems()
      .map((item, index) => paletteItemEnabled(item) ? index : -1)
      .filter((index): index is number => index >= 0);
  }

  function openPalette() {
    if (document.querySelector('dialog[open]')) return;
    palette.query = '';
    palette.selection = 0;
    openModal(paletteDialog);
  }

  function paletteKeydown(event: KeyboardEvent) {
    handleDialogKeydown(event);
    if (event.defaultPrevented) return;
    const enabled = paletteEnabledIndices();
    if (enabled.length === 0) return;
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      const current = enabled.indexOf(palette.selection);
      const base = current >= 0 ? current : -1;
      palette.selection = enabled[(base + 1 + enabled.length) % enabled.length];
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      const current = enabled.indexOf(palette.selection);
      const base = current >= 0 ? current : enabled.length;
      palette.selection = enabled[(base - 1 + enabled.length) % enabled.length];
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const item = paletteItems()[palette.selection];
      if (item && paletteItemEnabled(item)) executePaletteItem(item);
    }
  }

  function executePaletteItem(item: PaletteItem) {
    dialogs.skipFocusRestore = true;
    paletteDialog.close();
    if (item.kind === 'create') {
      dialogs.createPath = defaultCreatePath(connection.inputMode);
      createDialog.showModal();
    } else if (item.kind === 'rename') {
      dialogs.renamePath = buffer.activePath;
      renameDialog.showModal();
    } else if (item.kind === 'delete') {
      deleteDialog.showModal();
      deleteDialog.querySelector<HTMLButtonElement>('.dialog-actions .danger')?.focus();
    } else if (item.kind === 'save') void saveFile();
    else if (item.kind === 'command') void runCommand(item.mode);
    else if (item.kind === 'preview') void rebuildPreview('manual');
    else if (item.kind === 'source') focusSourcePane();
    else if (item.kind === 'focus-enter') enterFocusMode();
    else if (item.kind === 'focus-exit') exitFocusMode();
    else if (item.kind === 'watch-start') void startWatchDaemon();
    else if (item.kind === 'watch-stop') void stopWatchDaemon();
    else if (item.kind === 'watch-go') focusWatchPane();
    else if (item.kind === 'parent') void openGraphNode(parentNode());
    else if (item.kind === 'impact-here') void runImpactOnCurrent();
    else if (item.kind === 'entity') void openGraphNode(nodeForId(graph.payload?.graph ?? null, item.id));
    else void openFile(item.path);
  }

  function focusSourcePane() {
    if (focusMode.open) {
      document.getElementById('focus-editor')?.focus();
      return;
    }
    const editor = document.getElementById('source-editor') as HTMLTextAreaElement | null;
    if (editor) {
      editor.focus();
      return;
    }
    document.getElementById('source')?.focus();
  }

  function focusWatchPane() {
    document.getElementById('watch')?.focus();
  }

  async function renameFile() {
    const newPath = dialogs.renamePath.trim();
    if (!buffer.activePath || !newPath) return;
    const oldPath = buffer.activePath;
    const result = await api<ErrorResponse>('/api/files/rename', {
      method: 'POST', body: JSON.stringify({ path: oldPath, new_path: newPath })
    });
    if (result.response.ok) {
      buffer.activePath = newPath;
      dialogs.skipFocusRestore = true;
      renameDialog.close();
      await refreshFiles();
      buffer.editorStatus = `Renamed ${oldPath} to ${newPath}.`;
    } else {
      buffer.editorStatus = `Could not rename ${oldPath}: ${hostErrorLabel(result.data.error)}.`;
    }
  }

  async function deleteFile() {
    if (!buffer.activePath) return;
    const path = buffer.activePath;
    const result = await api<ErrorResponse>('/api/files/delete', {
      method: 'POST', body: JSON.stringify({ path, confirmed: true })
    });
    if (result.response.ok) {
      dialogs.skipFocusRestore = true;
      deleteDialog.close();
      resetBuffer();
      await refreshFiles();
      buffer.editorStatus = `Deleted ${path}.`;
    } else {
      buffer.editorStatus = `Could not delete ${path}: ${hostErrorLabel(result.data.error)}.`;
    }
  }

  function handleShortcut(event: KeyboardEvent) {
    const command = event.metaKey || event.ctrlKey;
    if (!command || event.altKey) return;
    if (event.key.toLowerCase() === 's') {
      event.preventDefault();
      if (document.querySelector('dialog[open]')) return;
      void saveFile();
    } else if (event.key.toLowerCase() === 'k') {
      event.preventDefault();
      openPalette();
    } else if (event.key.toLowerCase() === 'z' && event.shiftKey) {
      if ((event.target as HTMLElement | null)?.id !== 'source-editor') return;
      event.preventDefault();
      redo();
    } else if (event.key.toLowerCase() === 'z') {
      if ((event.target as HTMLElement | null)?.id !== 'source-editor') return;
      event.preventDefault();
      undo();
    }
  }

  function handlePaletteBackdrop(event: MouseEvent) {
    if (event.target === paletteDialog) paletteDialog.close();
  }

  function handleConflictKeydown(event: KeyboardEvent) {
    handleDialogKeydown(event);
    if (event.defaultPrevented) return;
    if (!event.altKey || event.metaKey || event.ctrlKey) return;
    if (event.key.toLowerCase() === 'l' && buffer.conflict) {
      event.preventDefault();
      void loadDiskVersion();
    } else if (event.key.toLowerCase() === 'd' && buffer.deletedConflict) {
      event.preventDefault();
      void discardDeletedBuffer();
    }
  }

  function handleDialogKeydown(event: KeyboardEvent) {
    if (event.key !== 'Tab') return;
    const dialog = event.currentTarget as HTMLDialogElement;
    if (!dialog.open) return;
    const focusable = [...dialog.querySelectorAll<HTMLElement>(
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
    )];
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    const active = document.activeElement;
    if (event.shiftKey) {
      if (active === first || active === dialog || !dialog.contains(active)) {
        event.preventDefault();
        last.focus();
      }
    } else if (active === last || !dialog.contains(active)) {
      event.preventDefault();
      first.focus();
    }
  }

  function handleResolutionKeydown(event: KeyboardEvent) {
    handleDialogKeydown(event);
    if (event.defaultPrevented) return;
    if (!event.altKey || event.metaKey || event.ctrlKey) return;
    if (event.key.toLowerCase() === 's') {
      event.preventDefault();
      void resolvePendingSave();
    } else if (event.key.toLowerCase() === 'd') {
      event.preventDefault();
      void resolvePendingDiscard();
    }
  }

  function warnUnsaved(event: BeforeUnloadEvent) {
    if (!dirty()) return;
    event.preventDefault();
    event.returnValue = '';
  }

  function handleVisibility() {
    if (document.visibilityState === 'hidden') flushRecovery();
    else void probeDisk();
  }

  function enterFocusMode(trigger: HTMLElement | null = null) {
    openFocusMode(trigger);
  }

  function exitFocusMode() {
    const returnTo = focusReturnElement;
    closeFocusMode();
    setFocusReturn(null);
    returnTo?.focus();
  }

  initFocusLayout();
  initFocusType();
  initFocusZen();
  connect();
</script>

<svelte:head>
  <meta name="description" content="Local, compiler-backed Boris authoring environment" />
</svelte:head>

<svelte:window
  onkeydown={handleShortcut}
  onbeforeunload={warnUnsaved}
  onpagehide={flushRecovery}
  onvisibilitychange={handleVisibility}
  onfocus={() => void probeDisk()}
/>

<Header connection={connection.status} />

<SectionNav />

<RecoveryBanner onRestore={restoreSnapshot} onDiscard={clearRecovery} />

<main id="workspace" tabindex="-1">
  <ProjectPane
    onOpen={openFile}
    onCreate={openCreateDialog}
    onRename={openRenameDialog}
    onDelete={openDeleteDialog}
  />

  <SourcePane
    onSave={() => saveFile()}
    onNavigate={navigateToProblem}
    onOpenFile={openFile}
    onOpenGraphNode={openGraphNode}
    onImpact={runImpactOnCurrent}
    onScale={() => runCommand('recipe_scale')}
    onReset={resetScale}
    onRunPlan={() => runCommand('plan')}
    onEnterFocus={enterFocusMode}
  />

  <div class="workspace-rail">
    <ProblemsPane
      onRunCommand={runCommand}
      onNavigate={navigateToProblem}
    />
    <PreviewPane onRebuild={() => rebuildPreview('manual')} />
    <WatchPane />
  </div>
</main>

<ConflictDialog
  bind:dialog={conflictDialog}
  onKeydown={handleConflictKeydown}
  onClose={() => { buffer.conflict = null; buffer.deletedConflict = false; restoreDialogFocus(); }}
  onKeepEditing={() => conflictDialog.close()}
  onDiscardDeleted={discardDeletedBuffer}
  onRecreate={() => saveFile(true)}
  onLoadDisk={loadDiskVersion}
  onReplace={() => saveFile(false, buffer.conflict!.fingerprint)}
/>

<ResolutionDialog
  bind:dialog={resolutionDialog}
  onKeydown={handleResolutionKeydown}
  onClose={() => { dialogs.pendingResolution = null; restoreDialogFocus(); }}
  onCancel={() => resolutionDialog.close()}
  onDiscard={resolvePendingDiscard}
  onSave={resolvePendingSave}
/>

<CreateDialog
  bind:dialog={createDialog}
  onKeydown={handleDialogKeydown}
  onClose={() => { dialogs.createPath = defaultCreatePath(connection.inputMode); restoreDialogFocus(); }}
  onCreate={createFile}
  onCancel={() => createDialog.close()}
/>

<RenameDialog
  bind:dialog={renameDialog}
  onKeydown={handleDialogKeydown}
  onClose={() => { dialogs.renamePath = ''; restoreDialogFocus(); }}
  onRename={renameFile}
  onCancel={() => renameDialog.close()}
/>

<DeleteDialog
  bind:dialog={deleteDialog}
  onKeydown={handleDialogKeydown}
  onClose={restoreDialogFocus}
  onDelete={deleteFile}
  onCancel={() => deleteDialog.close()}
/>

<CommandPalette
  bind:dialog={paletteDialog}
  onKeydown={paletteKeydown}
  onBackdropClick={handlePaletteBackdrop}
  onDialogClose={restoreDialogFocus}
  onCancel={() => paletteDialog.close()}
  onExecute={executePaletteItem}
/>

<footer>
  <p class="key-hint"><kbd>Ctrl</kbd>+<kbd>K</kbd> opens commands</p>
  <p>Boris owns meaning. Oliver owns markup semantics. The editor owns interaction.</p>
</footer>

{#if focusMode.open}
  <FocusMode
    onSave={() => void saveFile()}
    onRebuild={() => void rebuildPreview('manual')}
    onExit={exitFocusMode}
  />
{/if}
