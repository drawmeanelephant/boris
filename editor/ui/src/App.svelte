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

  let connection = 'Connecting to the local host…';
  let compiler = 'Checking Boris version…';
  let project = 'Checking project conventions…';
  let editorStatus = 'Choose a project file to begin editing.';
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

  $: dirty = activePath !== '' && content !== baseline;

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
      const [healthResult, versionResult, filesResult] = await Promise.all([
        api<Health>('/api/health'),
        api<Version>('/api/version'),
        api<FileList>('/api/files')
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

  async function openFile(path: string) {
    if (path === activePath) return;
    if (dirty) {
      editorStatus = `Save or undo changes to ${activePath} before opening another file.`;
      return;
    }
    const result = await api<BufferResponse | ErrorResponse>('/api/files/open', {
      method: 'POST', body: JSON.stringify({ path })
    });
    if (result.response.ok) {
      const buffer = result.data as BufferResponse;
      loadBuffer(buffer, buffer.read_only ? `Opened ${path} read-only.` : `Opened ${path}.`);
    } else {
      editorStatus = `Could not open ${path}.`;
    }
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
      <p class:warning={dirty || readOnly} class="buffer-state">
        {readOnly ? 'Read-only file' : dirty ? 'Unsaved changes' : 'Saved on disk'}
      </p>
    {:else}
      <p>Choose a file from Project files. Generated output and editor state are intentionally excluded.</p>
    {/if}
    <p role="status" aria-label="Editing status" aria-live="polite">{editorStatus}</p>
  </section>

  <section id="problems" aria-labelledby="problems-heading">
    <h2 id="problems-heading">Problems</h2>
    <p>Boris diagnostics arrive in the compiler-invocation slice.</p>
  </section>

  <section id="preview" aria-labelledby="preview-heading">
    <h2 id="preview-heading">Preview</h2>
    <p>Compiler-produced preview arrives in the live-preview slice.</p>
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
