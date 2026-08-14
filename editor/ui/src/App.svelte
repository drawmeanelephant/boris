<script lang="ts">
  import { tick } from 'svelte';

  type Health = {
    status: string;
    editor_id: string;
    project: { content: boolean; default_layout: boolean; publication_profile: boolean };
  };
  type Version = { compiler_id: string };
  type FileEntry = { path: string };
  type FileList = { files: FileEntry[] };
  type BufferResponse = {
    status: 'opened' | 'saved' | 'created' | 'conflict';
    path: string;
    content: string;
    fingerprint: string;
    read_only: boolean;
  };
  type RecoverySnapshot = { path: string; content: string; fingerprint: string };
  type RecoveryList = { snapshots: RecoverySnapshot[] };
  type ErrorResponse = { error?: string; status?: string };
  type CommandMode = 'validate' | 'ir_build' | 'html_build' | 'check' | 'impact';
  type FailureClass = 'success' | 'content' | 'usage' | 'io' | 'terminated';
  type Problem = {
    severity: 'error' | 'warning' | 'info';
    code: string | null;
    message: string;
    remediation: string;
    source_path: string | null;
    line: number | null;
    column: number | null;
    id: string | null;
    origin: 'build_report' | 'analysis_report' | 'stderr' | 'process';
    position_confidence: 'exact' | 'best_effort' | 'none';
    packet: string;
  };
  type AnalysisFinding = {
    code: string;
    endpoint_type: 'page' | 'source';
    value: string;
    count: number;
    source_path: string | null;
    line: number | null;
    column: number | null;
  };
  type ImpactEndpoint = { endpoint_type: 'page' | 'source'; value: string };
  type CommandResult = {
    mode: CommandMode;
    exit_code: number | null;
    failure_class: FailureClass;
    compiler_id: string;
    report_version: string | null;
    used_stderr_fallback: boolean;
    problems: Problem[];
    findings: AnalysisFinding[];
    impact: ImpactEndpoint[];
  };
  type ProblemGroup = { key: string; label: string; problems: Problem[] };
  type JsonSchemaProperty = { type?: string | string[]; enum?: Array<string | null>; maxLength?: number; maxItems?: number; pattern?: string; items?: JsonSchemaProperty };
  type CompletionEntity = { id: string; title: string | null; parent: string | null; role: string; status: string | null; tags: string[]; relations: Array<{ kind: string; target: string }> };
  type CompletionIndex = { format: string; schema_version: number; compiler_id: string; frozen: boolean; entities: CompletionEntity[]; relation_kinds: string[]; parent_targets: string[]; layout_slots: string[] };
  type AuthoringPayload = { frontmatter_schema: { title: string; properties: Record<string, JsonSchemaProperty> }; completion: CompletionIndex | null; completion_status: 'ready' | 'build_required' };
  type CompletionKind = 'frontmatter_key' | 'status' | 'entity' | 'wiki_link' | 'parent' | 'relation_kind' | 'relation_target' | 'layout_slot';
  type Suggestion = { value: string; insert: string; detail: string };

  let connection = 'Connecting to the local host…';
  let compiler = 'Checking Boris version…';
  let project = 'Checking project conventions…';
  let editorStatus = 'Choose a project file to begin editing.';
  let commandStatus = 'No Boris command has run yet.';
  let previewState = 'Preview is not running.';
  let files: FileEntry[] = [];
  let snapshots: RecoverySnapshot[] = [];
  let activePath = '';
  let content = '';
  let baseline = '';
  let fingerprint = '';
  let readOnly = false;
  let undoStack: string[] = [];
  let redoStack: string[] = [];
  let recoveryTimer: ReturnType<typeof setInterval> | undefined;
  let conflict: BufferResponse | null = null;
  let deletedConflict = false;
  let conflictDialog: HTMLDialogElement;
  let createDialog: HTMLDialogElement;
  let renameDialog: HTMLDialogElement;
  let deleteDialog: HTMLDialogElement;
  let createPath = 'content/new-page.md';
  let renamePath = '';
  let commandRunning = false;
  let commandResult: CommandResult | null = null;
  let impactId = '';
  let authoring: AuthoringPayload | null = null;
  let authoringStatus = 'Loading Boris authoring vocabulary…';
  let completionKind: CompletionKind = 'frontmatter_key';
  let completionQuery = '';
  let selectedSuggestion = 0;

  $: dirty = activePath !== '' && content !== baseline;
  $: problemGroups = groupProblems(commandResult?.problems ?? []);
  $: activeProblems = (commandResult?.problems ?? []).filter(problem =>
    problem.source_path !== null && projectPathForProblem(problem.source_path) === activePath
  );
  $: suggestions = completionSuggestions(authoring, completionKind, completionQuery);
  $: if (selectedSuggestion >= suggestions.length) selectedSuggestion = Math.max(0, suggestions.length - 1);

  const token = new URLSearchParams(window.location.hash.slice(1)).get('token') ?? '';

  async function api<T>(path: string, options: RequestInit = {}): Promise<{ response: Response; data: T }> {
    const headers = new Headers(options.headers);
    headers.set('X-Boris-Editor-Token', token);
    if (options.body) headers.set('Content-Type', 'application/json');
    let response: Response;
    try {
      response = await fetch(path, { ...options, headers });
    } catch {
      return {
        response: new Response('{"error":"host_unavailable"}', {
          status: 503, headers: { 'Content-Type': 'application/json' }
        }),
        data: { error: 'host_unavailable' } as T
      };
    }
    let data: T;
    try {
      data = await response.json() as T;
    } catch {
      data = {} as T;
    }
    return { response, data };
  }

  async function connect() {
    if (!token) {
      connection = 'Session token missing. Launch the editor from boris-editor.';
      compiler = 'Boris version unavailable.';
      project = 'Project status unavailable.';
      return;
    }
    try {
      const [healthResult, versionResult, filesResult, authoringResult] = await Promise.all([
        api<Health>('/api/health'),
        api<Version>('/api/version'),
        api<FileList>('/api/files'),
        api<AuthoringPayload>('/api/authoring')
      ]);
      if (![healthResult, versionResult, filesResult].every(result => result.response.ok)) {
        throw new Error('host request failed');
      }
      const health = healthResult.data;
      connection = `Connected to ${health.editor_id}.`;
      compiler = `Compiler: ${versionResult.data.compiler_id}`;
      project = health.project.content
        ? `Project found${health.project.publication_profile ? ' with boris.json' : ''}.`
        : 'This folder is not a Boris project.';
      files = filesResult.data.files;
      if (authoringResult.response.ok) setAuthoring(authoringResult.data);
      else authoringStatus = 'Boris authoring vocabulary is unavailable.';
      const recoveryResult = await api<RecoveryList>('/api/recovery');
      if (recoveryResult.response.ok) {
        snapshots = recoveryResult.data.snapshots;
      } else {
        editorStatus = 'Project files are available, but recovery snapshots could not be loaded.';
      }
    } catch {
      connection = 'Local host unavailable. Restart boris-editor.';
      compiler = 'Boris version unavailable.';
      project = 'Project status unavailable.';
    }
  }

  async function refreshFiles() {
    const result = await api<FileList>('/api/files');
    if (result.response.ok) files = result.data.files;
  }

  function loadBuffer(buffer: BufferResponse, status: string) {
    stopRecoveryTimer();
    activePath = buffer.path;
    content = buffer.content;
    baseline = buffer.content;
    fingerprint = buffer.fingerprint;
    readOnly = buffer.read_only;
    undoStack = [];
    redoStack = [];
    editorStatus = status;
  }

  async function openFile(path: string): Promise<boolean> {
    if (path === activePath) return true;
    if (dirty) {
      editorStatus = `Save or undo changes to ${activePath} before opening another file.`;
      return false;
    }
    const result = await api<BufferResponse | ErrorResponse>('/api/files/open', {
      method: 'POST', body: JSON.stringify({ path })
    });
    if (result.response.ok) {
      const buffer = result.data as BufferResponse;
      loadBuffer(buffer, buffer.read_only ? `Opened ${path} read-only.` : `Opened ${path}.`);
      return true;
    } else {
      editorStatus = `Could not open ${path}.`;
      return false;
    }
  }

  async function runCommand(mode: CommandMode) {
    if (dirty) {
      commandStatus = `Save or undo changes to ${activePath}; Boris commands read project files from disk.`;
      return;
    }
    if (mode === 'impact' && !impactId.trim()) {
      commandStatus = 'Enter an entity or source endpoint before running impact.';
      return;
    }
    commandRunning = true;
    commandStatus = `Running ${commandLabel(mode)}…`;
    const body = mode === 'impact' ? { mode, impact_id: impactId.trim() } : { mode };
    const result = await api<CommandResult | ErrorResponse>('/api/commands/run', {
      method: 'POST', body: JSON.stringify(body)
    });
    commandRunning = false;
    if (!result.response.ok) {
      commandStatus = `Could not run ${commandLabel(mode)}: ${(result.data as ErrorResponse).error ?? 'request failed'}.`;
      return;
    }
    commandResult = result.data as CommandResult;
    commandStatus = `${commandLabel(mode)} finished: ${failureLabel(commandResult.failure_class, commandResult.exit_code)}.`;
    if (mode === 'html_build') {
      previewState = commandResult.failure_class === 'success'
        ? 'The last HTML build succeeded. Live preview serving arrives in the preview slice.'
        : 'The HTML build failed. Existing dist output, if any, is previous and stale.';
    }
    if (mode === 'ir_build' && commandResult.failure_class === 'success') await refreshAuthoring();
  }

  function setAuthoring(payload: AuthoringPayload) {
    authoring = payload;
    authoringStatus = payload.completion
      ? `Boris completion index ready from ${payload.completion.compiler_id}.`
      : 'Frontmatter schema ready. Build diagnostics to create graph completion data.';
  }

  async function refreshAuthoring() {
    const result = await api<AuthoringPayload>('/api/authoring');
    if (result.response.ok) setAuthoring(result.data);
    else authoringStatus = 'The Boris build succeeded, but completion.json could not be adapted.';
  }

  function completionSuggestions(payload: AuthoringPayload | null, kind: CompletionKind, query: string): Suggestion[] {
    if (!payload) return [];
    const schema = payload.frontmatter_schema.properties;
    const index = payload.completion;
    let values: Suggestion[] = [];
    if (kind === 'frontmatter_key') values = Object.entries(schema).map(([name, property]) => ({ value: name, insert: `${name}: `, detail: schemaHint(property) }));
    if (kind === 'status') values = (schema.status?.enum ?? []).filter((value): value is string => typeof value === 'string').map(value => ({ value, insert: value, detail: 'Closed enum from Boris frontmatter schema' }));
    if (kind === 'entity' || kind === 'relation_target') values = (index?.entities ?? []).map(entity => ({ value: entity.id, insert: entity.id, detail: `${entity.role}${entity.title ? ` · ${entity.title}` : ''}` }));
    if (kind === 'wiki_link') values = (index?.entities ?? []).map(entity => ({ value: entity.id, insert: `[[${entity.id}]]`, detail: entity.title ?? entity.role }));
    if (kind === 'parent') values = (index?.parent_targets ?? []).map(value => ({ value, insert: value, detail: 'Observed parent target from completion.json' }));
    if (kind === 'relation_kind') values = (index?.relation_kinds ?? []).map(value => ({ value, insert: `${value}=`, detail: 'Relation kind from completion.json' }));
    if (kind === 'layout_slot') values = (index?.layout_slots ?? []).map(value => ({ value, insert: `{{${value}}}`, detail: 'Closed layout slot from completion.json' }));
    const needle = query.trim().toLocaleLowerCase();
    return values.filter(item => !needle || item.value.toLocaleLowerCase().startsWith(needle)).slice(0, 50);
  }

  function schemaHint(property: JsonSchemaProperty): string {
    const type = Array.isArray(property.type) ? property.type.filter(value => value !== 'null').join(' or ') : (property.type ?? 'value');
    const bounds = property.maxLength ? ` · at most ${property.maxLength} characters` : property.maxItems ? ` · at most ${property.maxItems} items` : '';
    return `${type}${bounds}`;
  }

  function completionKeydown(event: KeyboardEvent) {
    if (!suggestions.length) return;
    if (event.key === 'ArrowDown') { event.preventDefault(); selectedSuggestion = (selectedSuggestion + 1) % suggestions.length; }
    if (event.key === 'ArrowUp') { event.preventDefault(); selectedSuggestion = (selectedSuggestion + suggestions.length - 1) % suggestions.length; }
    if (event.key === 'Enter') { event.preventDefault(); void insertSuggestion(suggestions[selectedSuggestion]); }
    if (event.key === 'Escape') completionQuery = '';
  }

  async function insertSuggestion(suggestion: Suggestion | undefined) {
    if (!suggestion || !activePath || readOnly) return;
    const editor = document.querySelector<HTMLTextAreaElement>('#source-editor');
    if (!editor) return;
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    undoStack = [...undoStack.slice(-99), content];
    redoStack = [];
    content = `${content.slice(0, start)}${suggestion.insert}${content.slice(end)}`;
    editorStatus = `Inserted ${suggestion.value} from Boris authoring vocabulary.`;
    scheduleRecovery();
    await tick();
    editor.focus();
    editor.setSelectionRange(start + suggestion.insert.length, start + suggestion.insert.length);
  }

  function commandLabel(mode: CommandMode): string {
    return ({
      validate: 'Validate project',
      ir_build: 'Build diagnostics',
      html_build: 'Build HTML',
      check: 'Check graph',
      impact: 'Run impact'
    } satisfies Record<CommandMode, string>)[mode];
  }

  function failureLabel(failure: FailureClass, exitCode: number | null): string {
    const labels: Record<FailureClass, string> = {
      success: 'Success',
      content: 'Content or graph failure',
      usage: 'Usage or configuration failure',
      io: 'I/O or system failure',
      terminated: 'Process terminated'
    };
    return exitCode === null ? labels[failure] : `${labels[failure]} (exit ${exitCode})`;
  }

  function groupProblems(problems: Problem[]): ProblemGroup[] {
    const groups = new Map<string, ProblemGroup>();
    for (const problem of problems) {
      const source = problem.source_path ?? 'Project';
      const code = problem.code ?? 'Unstructured Boris output';
      const key = `${source}\u0000${problem.severity}\u0000${code}`;
      const existing = groups.get(key);
      if (existing) {
        existing.problems.push(problem);
      } else {
        groups.set(key, { key, label: `${source} · ${problem.severity} · ${code}`, problems: [problem] });
      }
    }
    const severityOrder = { error: 0, warning: 1, info: 2 };
    return [...groups.values()].sort((left, right) => {
      const source = (left.problems[0].source_path ?? '\uffff').localeCompare(right.problems[0].source_path ?? '\uffff');
      if (source !== 0) return source;
      const severity = severityOrder[left.problems[0].severity] - severityOrder[right.problems[0].severity];
      return severity !== 0 ? severity : left.label.localeCompare(right.label);
    });
  }

  function projectPathForProblem(sourcePath: string): string {
    if (sourcePath === 'boris.json' || sourcePath.startsWith('content/') || sourcePath.startsWith('themes/')) return sourcePath;
    return `content/${sourcePath}`;
  }

  async function navigateToProblem(problem: Problem | AnalysisFinding) {
    if (!problem.source_path) return;
    const path = projectPathForProblem(problem.source_path);
    if (!await openFile(path)) return;
    await tick();
    const editor = document.getElementById('source-editor') as HTMLTextAreaElement | null;
    if (!editor) return;
    const offset = sourceOffset(content, problem.line, problem.column);
    editor.focus();
    editor.setSelectionRange(offset, offset);
    editor.scrollTop = Math.max(0, editor.scrollHeight * (offset / Math.max(1, content.length)) - editor.clientHeight / 2);
    editorStatus = problem.line
      ? `Moved to ${path}, line ${problem.line}${problem.column ? `, column ${problem.column}` : ''}.`
      : `Opened ${path} for this Boris finding.`;
  }

  function sourceOffset(source: string, line: number | null, column: number | null): number {
    if (!line || line < 1) return 0;
    let lineStart = 0;
    for (let currentLine = 1; currentLine < line; currentLine += 1) {
      const newline = source.indexOf('\n', lineStart);
      if (newline < 0) return source.length;
      lineStart = newline + 1;
    }
    if (!column || column <= 1) return lineStart;
    const lineEnd = source.indexOf('\n', lineStart);
    const text = source.slice(lineStart, lineEnd < 0 ? source.length : lineEnd);
    const wantedBytes = column - 1;
    let consumedBytes = 0;
    let codeUnits = 0;
    const encoder = new TextEncoder();
    for (const character of text) {
      const bytes = encoder.encode(character).length;
      if (consumedBytes + bytes > wantedBytes) break;
      consumedBytes += bytes;
      codeUnits += character.length;
    }
    return lineStart + codeUnits;
  }

  async function copyDiagnosticPacket(problem: Problem) {
    try {
      await navigator.clipboard.writeText(problem.packet);
      commandStatus = `Copied diagnostic packet for ${problem.code ?? 'unstructured Boris output'}.`;
    } catch {
      commandStatus = 'Could not copy the diagnostic packet. Clipboard access was denied.';
    }
  }

  function problemLocationLabel(problem: Problem | AnalysisFinding): string {
    if (!problem.source_path) return 'project';
    if (!problem.line) return problem.source_path;
    return `${problem.source_path} line ${problem.line}${problem.column ? ` column ${problem.column}` : ''}`;
  }

  function editSource(event: Event) {
    const next = (event.currentTarget as HTMLTextAreaElement).value;
    if (next === content) return;
    undoStack = [...undoStack.slice(-99), content];
    redoStack = [];
    content = next;
    editorStatus = `Unsaved changes in ${activePath}.`;
    scheduleRecovery();
  }

  function undo() {
    if (undoStack.length === 0 || readOnly) return;
    const previous = undoStack[undoStack.length - 1];
    undoStack = undoStack.slice(0, -1);
    redoStack = [...redoStack.slice(-99), content];
    content = previous;
    editorStatus = `Undid change in ${activePath}.`;
    scheduleRecovery();
  }

  function redo() {
    if (redoStack.length === 0 || readOnly) return;
    const next = redoStack[redoStack.length - 1];
    redoStack = redoStack.slice(0, -1);
    undoStack = [...undoStack.slice(-99), content];
    content = next;
    editorStatus = `Redid change in ${activePath}.`;
    scheduleRecovery();
  }

  function scheduleRecovery() {
    if (!activePath || content === baseline) {
      stopRecoveryTimer();
      if (activePath) void clearRecovery(activePath);
      return;
    }
    if (!recoveryTimer) recoveryTimer = setInterval(() => void snapshotBuffer(), 3000);
  }

  function stopRecoveryTimer() {
    if (recoveryTimer) clearInterval(recoveryTimer);
    recoveryTimer = undefined;
  }

  async function snapshotBuffer() {
    if (!activePath || content === baseline) return;
    const result = await api<ErrorResponse>('/api/recovery/snapshot', {
      method: 'POST', body: JSON.stringify({ path: activePath, content, fingerprint })
    });
    if (!result.response.ok) editorStatus = `Unsaved changes in ${activePath}; recovery snapshot failed.`;
  }

  async function saveFile(recreate = false, replacementFingerprint = fingerprint) {
    if (!activePath || readOnly || !dirty) return;
    const result = await api<BufferResponse | ErrorResponse>('/api/files/save', {
      method: 'POST',
      body: JSON.stringify({ path: activePath, content, fingerprint: replacementFingerprint, recreate })
    });
    if (result.response.ok) {
      const buffer = result.data as BufferResponse;
      loadBuffer(buffer, `Saved ${activePath}.`);
      snapshots = snapshots.filter(snapshot => snapshot.path !== activePath);
      conflictDialog?.close();
      conflict = null;
      deletedConflict = false;
      await refreshFiles();
      return;
    }
    const error = result.data as ErrorResponse;
    if (result.response.status === 409 && error.status === 'conflict') {
      conflict = result.data as BufferResponse;
      deletedConflict = false;
      editorStatus = `External changes detected in ${activePath}. Nothing was overwritten.`;
      await tick();
      conflictDialog.showModal();
    } else if (result.response.status === 409 && error.status === 'deleted') {
      conflict = null;
      deletedConflict = true;
      editorStatus = `${activePath} was deleted outside the editor. Nothing was written.`;
      await tick();
      conflictDialog.showModal();
    } else if (error.error === 'read_only') {
      readOnly = true;
      editorStatus = `${activePath} is read-only. Nothing was written.`;
    } else {
      editorStatus = `Save failed for ${activePath}. Your buffer remains unsaved.`;
    }
  }

  async function loadDiskVersion() {
    if (!conflict) return;
    loadBuffer(conflict, `Loaded the current disk version of ${activePath}.`);
    await clearRecovery(activePath);
    conflict = null;
    conflictDialog.close();
  }

  async function discardDeletedBuffer() {
    const discardedPath = activePath;
    await clearRecovery(discardedPath);
    stopRecoveryTimer();
    activePath = '';
    content = '';
    baseline = '';
    fingerprint = '';
    undoStack = [];
    redoStack = [];
    deletedConflict = false;
    conflictDialog.close();
    editorStatus = `Discarded unsaved changes for deleted file ${discardedPath}.`;
    await refreshFiles();
  }

  async function clearRecovery(path: string) {
    const result = await api<ErrorResponse>('/api/recovery/clear', { method: 'POST', body: JSON.stringify({ path }) });
    if (result.response.ok) {
      snapshots = snapshots.filter(snapshot => snapshot.path !== path);
    } else {
      editorStatus = `Could not discard recovery for ${path}.`;
    }
  }

  async function restoreSnapshot(snapshot: RecoverySnapshot) {
    if (dirty) {
      editorStatus = `Save or undo changes to ${activePath} before restoring recovered work.`;
      return;
    }
    const opened = await api<BufferResponse>('/api/files/open', {
      method: 'POST', body: JSON.stringify({ path: snapshot.path })
    });
    if (opened.response.ok) {
      loadBuffer(opened.data, `Recovered unsaved work for ${snapshot.path}.`);
      content = snapshot.content;
    } else if (opened.response.status === 404) {
      activePath = snapshot.path;
      content = snapshot.content;
      baseline = '';
      fingerprint = snapshot.fingerprint;
      readOnly = false;
      undoStack = [];
      redoStack = [];
      editorStatus = `Recovered unsaved work for deleted file ${snapshot.path}.`;
    } else {
      editorStatus = `Could not restore recovered work for ${snapshot.path}.`;
    }
  }

  async function createFile() {
    const path = createPath.trim();
    if (!path) return;
    const result = await api<BufferResponse | ErrorResponse>('/api/files/create', {
      method: 'POST', body: JSON.stringify({ path, content: '' })
    });
    if (result.response.ok) {
      createDialog.close();
      await refreshFiles();
      loadBuffer(result.data as BufferResponse, `Created ${path}.`);
    } else {
      editorStatus = `Could not create ${path}: ${(result.data as ErrorResponse).error ?? 'request failed'}.`;
    }
  }

  function openRenameDialog() {
    renamePath = activePath;
    renameDialog.showModal();
  }

  async function renameFile() {
    const newPath = renamePath.trim();
    if (!activePath || !newPath) return;
    const oldPath = activePath;
    const result = await api<ErrorResponse>('/api/files/rename', {
      method: 'POST', body: JSON.stringify({ path: oldPath, new_path: newPath })
    });
    if (result.response.ok) {
      activePath = newPath;
      renameDialog.close();
      await refreshFiles();
      editorStatus = `Renamed ${oldPath} to ${newPath}.`;
    } else {
      editorStatus = `Could not rename ${oldPath}: ${result.data.error ?? 'request failed'}.`;
    }
  }

  async function deleteFile() {
    if (!activePath) return;
    const path = activePath;
    const result = await api<ErrorResponse>('/api/files/delete', {
      method: 'POST', body: JSON.stringify({ path, confirmed: true })
    });
    if (result.response.ok) {
      deleteDialog.close();
      activePath = '';
      content = '';
      baseline = '';
      fingerprint = '';
      undoStack = [];
      redoStack = [];
      await refreshFiles();
      editorStatus = `Deleted ${path}.`;
    } else {
      editorStatus = `Could not delete ${path}: ${result.data.error ?? 'request failed'}.`;
    }
  }

  function handleShortcut(event: KeyboardEvent) {
    const command = event.metaKey || event.ctrlKey;
    if (!command || event.altKey) return;
    if (event.key.toLowerCase() === 's') {
      event.preventDefault();
      if (document.querySelector('dialog[open]')) return;
      void saveFile();
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

  function warnUnsaved(event: BeforeUnloadEvent) {
    if (!dirty) return;
    event.preventDefault();
    event.returnValue = '';
  }

  connect();
</script>

<svelte:head>
  <meta name="description" content="Local, compiler-backed Boris authoring environment" />
</svelte:head>

<svelte:window onkeydown={handleShortcut} onbeforeunload={warnUnsaved} />

<header>
  <a class="skip-link" href="#workspace">Skip to workspace</a>
  <div>
    <p class="eyebrow">Local authoring environment</p>
    <h1>Boris Editor</h1>
  </div>
  <p class="connection" role="status" aria-label="Connection status" aria-live="polite">{connection}</p>
</header>

<nav class="section-nav" aria-label="Editor sections">
  <a href="#project">Project</a>
  <a href="#source">Source</a>
  <a href="#problems">Problems</a>
  <a href="#preview">Preview</a>
</nav>

{#if snapshots.length > 0}
  <aside class="recovery-banner" aria-labelledby="recovery-heading">
    <div>
      <h2 id="recovery-heading">Recovered unsaved work</h2>
      <p>Recovery copies never replace project files without an explicit save.</p>
    </div>
    <ul>
      {#each snapshots as snapshot (snapshot.path)}
        <li>
          <span>{snapshot.path}</span>
          <button type="button" onclick={() => restoreSnapshot(snapshot)}>Restore {snapshot.path}</button>
          <button type="button" onclick={() => clearRecovery(snapshot.path)}>Discard recovery for {snapshot.path}</button>
        </li>
      {/each}
    </ul>
  </aside>
{/if}

<main id="workspace" tabindex="-1">
  <section id="project" class="project-pane" aria-labelledby="project-heading">
    <div>
      <h2 id="project-heading">Project</h2>
      <p>{project}</p>
      <p>{compiler}</p>
    </div>
    <div class="file-actions" aria-label="File actions">
      <button type="button" disabled={dirty} onclick={() => createDialog.showModal()}>Create file</button>
      <button type="button" disabled={!activePath || dirty} onclick={openRenameDialog}>Rename file</button>
      <button type="button" class="danger" disabled={!activePath || dirty} onclick={() => deleteDialog.showModal()}>Delete file</button>
    </div>
    <nav class="file-tree" aria-label="Project files">
      {#if files.length === 0}
        <p>No author-owned project files found.</p>
      {:else}
        <ul>
          {#each files as file (file.path)}
            <li>
              <button
                type="button"
                class:active={file.path === activePath}
                aria-current={file.path === activePath ? 'page' : undefined}
                onclick={() => openFile(file.path)}
              >{file.path}</button>
            </li>
          {/each}
        </ul>
      {/if}
    </nav>
  </section>

  <section id="source" class="source-pane" aria-labelledby="source-heading">
    <div class="source-heading">
      <div>
        <h2 id="source-heading">Source</h2>
        <p class="path">{activePath || 'No file selected'}</p>
      </div>
      <div class="source-actions" aria-label="Editing actions">
        <button type="button" disabled={undoStack.length === 0 || readOnly} onclick={undo}>Undo</button>
        <button type="button" disabled={redoStack.length === 0 || readOnly} onclick={redo}>Redo</button>
        <button type="button" class="primary" disabled={!dirty || readOnly} onclick={() => saveFile()}>Save file</button>
      </div>
    </div>
    {#if activePath}
      <label for="source-editor">Source for {activePath}</label>
      <textarea
        id="source-editor"
        value={content}
        readonly={readOnly}
        spellcheck="false"
        oninput={editSource}
      ></textarea>
      <aside class="authoring-tools" aria-labelledby="authoring-heading">
        <div class="authoring-heading">
          <div>
            <h3 id="authoring-heading">Boris authoring hints</h3>
            <p>{authoringStatus}</p>
          </div>
          <button type="button" onclick={refreshAuthoring}>Refresh Boris suggestions</button>
        </div>
        <div class="completion-controls">
          <div>
            <label for="completion-kind">Completion category</label>
            <select id="completion-kind" bind:value={completionKind} onchange={() => { completionQuery = ''; selectedSuggestion = 0; }}>
              <option value="frontmatter_key">Frontmatter key</option>
              <option value="status">Status value</option>
              <option value="entity">Entity id</option>
              <option value="wiki_link">Wiki link</option>
              <option value="parent">Parent target</option>
              <option value="relation_kind">Relation kind</option>
              <option value="relation_target">Relation target</option>
              <option value="layout_slot">Layout slot</option>
            </select>
          </div>
          <div class="combobox-wrap">
            <label for="completion-query">Filter {completionKind.replaceAll('_', ' ')}</label>
            <input
              id="completion-query"
              role="combobox"
              aria-autocomplete="list"
              aria-expanded={suggestions.length > 0}
              aria-controls="completion-options"
              aria-activedescendant={suggestions.length ? `completion-option-${selectedSuggestion}` : undefined}
              bind:value={completionQuery}
              onkeydown={completionKeydown}
            />
          </div>
          <button type="button" disabled={!suggestions.length || readOnly} onclick={() => insertSuggestion(suggestions[selectedSuggestion])}>Insert selected completion</button>
        </div>
        <ul id="completion-options" role="listbox" aria-label="Boris completion suggestions">
          {#each suggestions as suggestion, suggestionIndex (`${completionKind}-${suggestion.value}`)}
            <li
              id="completion-option-{suggestionIndex}"
              role="option"
              tabindex="-1"
              aria-selected={suggestionIndex === selectedSuggestion}
              class:selected={suggestionIndex === selectedSuggestion}
              onclick={() => { selectedSuggestion = suggestionIndex; void insertSuggestion(suggestion); }}
              onkeydown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); void insertSuggestion(suggestion); } }}
            >
              <strong>{suggestion.value}</strong><span>{suggestion.detail}</span>
            </li>
          {/each}
        </ul>
        {#if authoring}
          <details>
            <summary>Frontmatter field bounds from Boris schema</summary>
            <dl>
              {#each Object.entries(authoring.frontmatter_schema.properties) as [field, property]}
                <div><dt>{field}</dt><dd>{schemaHint(property)}</dd></div>
              {/each}
            </dl>
            <p>The schema is a looser pre-check for multibyte lengths and dates. The Boris parser remains authoritative.</p>
          </details>
        {/if}
      </aside>
      <p class:warning={dirty || readOnly} class="buffer-state">
        {readOnly ? 'Read-only file' : dirty ? 'Unsaved changes' : 'Saved on disk'}
      </p>
      {#if activeProblems.length > 0}
        <aside class="inline-problems" aria-label="Problems in {activePath}">
          <h3>Problems in this file</h3>
          <ul>
            {#each activeProblems as problem}
              <li>
                <button type="button" onclick={() => navigateToProblem(problem)}>
                  Go to {problemLocationLabel(problem)}: {problem.code ?? 'Unstructured Boris output'}
                </button>
              </li>
            {/each}
          </ul>
        </aside>
      {/if}
    {:else}
      <p>Choose a file from Project files. Generated output and editor state are intentionally excluded.</p>
    {/if}
    <p role="status" aria-label="Editing status" aria-live="polite">{editorStatus}</p>
  </section>

  <section id="problems" class="problems-pane" aria-labelledby="problems-heading">
    <div class="problems-heading">
      <div>
        <h2 id="problems-heading">Problems</h2>
        <p>Every result below comes from the Boris CLI or one of its published artifacts.</p>
      </div>
      {#if commandResult}
        <p class:failure={commandResult.failure_class !== 'success'} class="command-result">
          {failureLabel(commandResult.failure_class, commandResult.exit_code)}
        </p>
      {/if}
    </div>
    <div class="command-bar" aria-label="Boris commands">
      <button type="button" disabled={commandRunning || dirty} onclick={() => runCommand('validate')}>Validate project</button>
      <button type="button" disabled={commandRunning || dirty} onclick={() => runCommand('ir_build')}>Build diagnostics</button>
      <button type="button" disabled={commandRunning || dirty} onclick={() => runCommand('html_build')}>Build HTML</button>
      <button type="button" disabled={commandRunning || dirty} onclick={() => runCommand('check')}>Check graph</button>
    </div>
    <div class="impact-command">
      <label for="impact-id">Impact entity or source endpoint</label>
      <div>
        <input id="impact-id" bind:value={impactId} disabled={commandRunning || dirty} />
        <button type="button" disabled={commandRunning || dirty} onclick={() => runCommand('impact')}>Run impact</button>
      </div>
    </div>
    {#if dirty}
      <p class="warning-text">Save or undo changes before running Boris; commands read repository files from disk.</p>
    {/if}
    <p role="status" aria-label="Boris command status" aria-live="polite">{commandStatus}</p>

    {#if commandResult?.used_stderr_fallback}
      <p class="fallback-notice">Machine-readable diagnostics were unavailable for this command. Boris stderr was used; reported source positions are labeled best-effort.</p>
    {/if}

    {#if commandResult && commandResult.problems.length === 0}
      <p>No Boris diagnostics were reported by the last command.</p>
    {/if}

    <div class="problem-groups" aria-label="Boris diagnostic groups">
      {#each problemGroups as group, groupIndex (group.key)}
        <section class="problem-group" aria-labelledby="problem-group-{groupIndex}">
          <h3 id="problem-group-{groupIndex}">{group.label}</h3>
          <ul>
            {#each group.problems as problem}
              <li class="problem-card">
                <p>{problem.message}</p>
                {#if problem.remediation}<p><strong>Remediation:</strong> {problem.remediation}</p>{/if}
                <p class="confidence">
                  {problem.position_confidence === 'exact'
                    ? 'Exact compiler-reported source position'
                    : problem.position_confidence === 'best_effort'
                      ? 'Best-effort source position'
                      : 'No source position reported'}
                </p>
                <div class="problem-actions">
                  {#if problem.source_path}
                    <button type="button" onclick={() => navigateToProblem(problem)}>Go to {problemLocationLabel(problem)}</button>
                  {/if}
                  <button type="button" onclick={() => copyDiagnosticPacket(problem)}>
                    Copy packet for {problem.code ?? 'unstructured Boris output'} at {problem.source_path ?? 'project'}
                  </button>
                </div>
              </li>
            {/each}
          </ul>
        </section>
      {/each}
    </div>

    {#if commandResult && commandResult.findings.length > 0}
      <section class="analysis-results" aria-labelledby="analysis-findings-heading">
        <h3 id="analysis-findings-heading">Analysis findings</h3>
        <ul>
          {#each commandResult.findings as finding}
            <li>
              <span>{finding.code} · {finding.endpoint_type} {finding.value} · count {finding.count}</span>
              {#if finding.source_path}
                <button type="button" onclick={() => navigateToProblem(finding)}>Go to {problemLocationLabel(finding)}</button>
              {/if}
            </li>
          {/each}
        </ul>
      </section>
    {/if}

    {#if commandResult?.mode === 'impact' && commandResult.impact.length > 0}
      <section class="analysis-results" aria-labelledby="impact-results-heading">
        <h3 id="impact-results-heading">Impact results</h3>
        <ul>
          {#each commandResult.impact as endpoint}
            <li>{endpoint.endpoint_type}: {endpoint.value}</li>
          {/each}
        </ul>
      </section>
    {/if}
  </section>

  <section id="preview" aria-labelledby="preview-heading">
    <h2 id="preview-heading">Preview</h2>
    <p>{previewState}</p>
  </section>
</main>

<dialog bind:this={conflictDialog} aria-labelledby="conflict-heading">
  <h2 id="conflict-heading">{deletedConflict ? 'File deleted outside Boris Editor' : 'External changes detected'}</h2>
  {#if deletedConflict}
    <p>{activePath} no longer exists on disk. Your unsaved version is still in the editor.</p>
    <label for="deleted-version">Your unsaved version</label>
    <textarea id="deleted-version" readonly value={content}></textarea>
    <div class="dialog-actions">
      <button type="button" onclick={() => conflictDialog.close()}>Keep editing</button>
      <button type="button" onclick={discardDeletedBuffer}>Discard changes</button>
      <button type="button" class="primary" onclick={() => saveFile(true)}>Re-create file</button>
    </div>
  {:else if conflict}
    <p>{activePath} changed on disk after you opened it. Compare both versions before choosing.</p>
    <div class="comparison">
      <div>
        <label for="unsaved-version">Your unsaved version</label>
        <textarea id="unsaved-version" readonly value={content}></textarea>
      </div>
      <div>
        <label for="disk-version">Current disk version</label>
        <textarea id="disk-version" readonly value={conflict.content}></textarea>
      </div>
    </div>
    <div class="dialog-actions">
      <button type="button" onclick={() => conflictDialog.close()}>Keep editing</button>
      <button type="button" onclick={loadDiskVersion}>Load disk version</button>
      <button type="button" class="primary" onclick={() => saveFile(false, conflict!.fingerprint)}>Replace disk version</button>
    </div>
  {/if}
</dialog>

<dialog bind:this={createDialog} aria-labelledby="create-heading">
  <h2 id="create-heading">Create file</h2>
  <p>Use a project-relative path under content/ or themes/, or boris.json.</p>
  <label for="create-path">New file path</label>
  <input id="create-path" bind:value={createPath} />
  <div class="dialog-actions">
    <button type="button" onclick={() => createDialog.close()}>Cancel</button>
    <button type="button" class="primary" onclick={createFile}>Create file</button>
  </div>
</dialog>

<dialog bind:this={renameDialog} aria-labelledby="rename-heading">
  <h2 id="rename-heading">Rename file</h2>
  <p>Rename {activePath} without replacing an existing file.</p>
  <label for="rename-path">New file path</label>
  <input id="rename-path" bind:value={renamePath} />
  <div class="dialog-actions">
    <button type="button" onclick={() => renameDialog.close()}>Cancel</button>
    <button type="button" class="primary" onclick={renameFile}>Rename file</button>
  </div>
</dialog>

<dialog bind:this={deleteDialog} aria-labelledby="delete-heading">
  <h2 id="delete-heading">Delete file</h2>
  <p>Delete {activePath}? This changes the project immediately and cannot be undone in Boris Editor.</p>
  <div class="dialog-actions">
    <button type="button" onclick={() => deleteDialog.close()}>Cancel</button>
    <button type="button" class="danger" onclick={deleteFile}>Delete {activePath}</button>
  </div>
</dialog>

<footer>
  <p>Boris owns meaning. Oliver owns markup semantics. The editor owns interaction.</p>
</footer>
