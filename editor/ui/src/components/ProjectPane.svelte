<script lang="ts">
  import type { FileEntry } from '../lib/types';

  let {
    files,
    activePath,
    dirty,
    fileQuery,
    visibleFiles,
    fileTreeStatus,
    project,
    compiler,
    onOpen,
    onCreate,
    onRename,
    onDelete,
    onQuery
  }: {
    files: FileEntry[];
    activePath: string;
    dirty: boolean;
    fileQuery: string;
    visibleFiles: FileEntry[];
    fileTreeStatus: string;
    project: string;
    compiler: string;
    onOpen: (path: string) => void;
    onCreate: () => void;
    onRename: () => void;
    onDelete: () => void;
    onQuery: (value: string) => void;
  } = $props();
</script>

<section id="project" class="project-pane" aria-labelledby="project-heading">
  <div>
    <h2 id="project-heading">Project</h2>
    <p>{project}</p>
    <p>{compiler}</p>
  </div>
  <div class="file-actions" aria-label="File actions">
    <button type="button" disabled={dirty} onclick={onCreate}>Create file</button>
    <button type="button" disabled={!activePath || dirty} onclick={onRename}>Rename file</button>
    <button type="button" class="danger" disabled={!activePath || dirty} onclick={onDelete}>Delete file</button>
  </div>
  {#if files.length > 0}
    <div class="file-filter">
      <label for="file-filter">Filter project files</label>
      <input id="file-filter" value={fileQuery} oninput={(e) => onQuery((e.currentTarget as HTMLInputElement).value)} />
      {#if fileTreeStatus}
        <p role="status" aria-label="Project files status" aria-live="polite">{fileTreeStatus}</p>
      {/if}
    </div>
  {/if}
  <nav class="file-tree" aria-label="Project files">
    {#if files.length === 0}
      <p>No author-owned project files found.</p>
    {:else if visibleFiles.length === 0}
      <p>No project files match the filter.</p>
    {:else}
      <ul>
        {#each visibleFiles as file (file.path)}
          <li>
            <button
              type="button"
              class:active={file.path === activePath}
              aria-current={file.path === activePath ? 'page' : undefined}
              onclick={() => onOpen(file.path)}>{file.path}</button
            >
          </li>
        {/each}
      </ul>
    {/if}
  </nav>
</section>
