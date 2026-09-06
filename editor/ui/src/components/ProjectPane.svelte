<script lang="ts">
  import { project, visibleFiles, fileTreeStatus } from '../lib/state/project.svelte';
  import { connection } from '../lib/state/connection.svelte';
  import { buffer, dirty } from '../lib/state/buffer.svelte';

  let {
    onOpen,
    onCreate,
    onRename,
    onDelete
  }: {
    onOpen: (path: string) => void;
    onCreate: () => void;
    onRename: () => void;
    onDelete: () => void;
  } = $props();
</script>

<section id="project" class="project-pane" aria-labelledby="project-heading">
  <div>
    <h2 id="project-heading">Project</h2>
    <p>{connection.project}</p>
    <p>{connection.compiler}</p>
  </div>
  <div class="file-actions" aria-label="File actions">
    <button type="button" disabled={dirty()} onclick={onCreate}>Create file</button>
    <button type="button" disabled={!buffer.activePath || dirty()} onclick={onRename}>Rename file</button>
    <button type="button" class="danger" disabled={!buffer.activePath || dirty()} onclick={onDelete}>Delete file</button>
  </div>
  {#if project.files.length > 0}
    <div class="file-filter">
      <label for="file-filter">Filter project files</label>
      <input id="file-filter" value={project.fileQuery} oninput={(e) => (project.fileQuery = (e.currentTarget as HTMLInputElement).value)} />
      {#if fileTreeStatus()}
        <p role="status" aria-label="Project files status" aria-live="polite">{fileTreeStatus()}</p>
      {/if}
    </div>
  {/if}
  <nav class="file-tree" aria-label="Project files">
    {#if project.files.length === 0}
      <p>No author-owned project files found.</p>
    {:else if visibleFiles().length === 0}
      <p>No project files match the filter.</p>
    {:else}
      <ul>
        {#each visibleFiles() as file (file.path)}
          <li>
            <button
              type="button"
              class:active={file.path === buffer.activePath}
              aria-current={file.path === buffer.activePath ? 'page' : undefined}
              onclick={() => onOpen(file.path)}>{file.path}</button
            >
          </li>
        {/each}
      </ul>
    {/if}
  </nav>
</section>
