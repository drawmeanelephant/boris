<script lang="ts">
  import {
    project,
    visibleFiles,
    fileTree,
    fileTreeStatus,
    isDirCollapsed,
    toggleDir,
    revealPath
  } from '../lib/state/project.svelte';
  import { connection } from '../lib/state/connection.svelte';
  import { buffer, dirty } from '../lib/state/buffer.svelte';
  import type { ProjectTreeNode } from '../lib/types';

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

  const tree = $derived(fileTree());

  // Opening a file from anywhere (the tree, the command palette, a graph link,
  // a problem) must land on a visible row, so the folders above the active
  // path are expanded whenever the active path *changes*. The previous-path
  // guard is a plain variable rather than reactive state, so re-collapsing the
  // folder holding the open file sticks until the author opens another file.
  // The set read inside revealPath is untracked, so this effect depends on the
  // active path alone.
  let revealedFor = '';
  $effect(() => {
    const path = buffer.activePath;
    if (path === revealedFor) return;
    revealedFor = path;
    revealPath(path);
  });
</script>

<section id="project" class="project-pane" tabindex="-1" aria-labelledby="project-heading">
  <div class="pane-heading">
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
      {#snippet treeLevel(nodes: ProjectTreeNode[])}
        <ul>
          {#each nodes as node (node.path)}
            <li>
              {#if node.kind === 'dir'}
                {@const collapsed = isDirCollapsed(node.path)}
                <!--
                  A folder toggle is a real named button, so it is reachable by
                  pointer, keyboard, and assistive tech alike; the caret is a CSS
                  pseudo-element, so it never pollutes the accessible name and
                  the name stays exactly the visible text. aria-expanded is the
                  state, and the folder's own segment is the label, so a folder
                  and a file that share a name can never be confused.
                -->
                <button
                  type="button"
                  class="file-tree-dir"
                  aria-expanded={!collapsed}
                  onclick={() => toggleDir(node.path)}
                >{node.name}/</button
                >
                {#if !collapsed}
                  {@render treeLevel(node.children)}
                {/if}
              {:else}
                <!--
                  The row shows the file's own segment and the indentation
                  carries the rest of the path, which is what stops a long
                  path from breaking mid-word. The full project-relative path
                  stays the button's accessible name (aria-label) and its
                  tooltip, so the names a keyboard user or screen reader
                  encounters are exactly the names this pane has always exposed, and two
                  files that share a basename in different directories stay
                  distinguishable.
                -->
                <button
                  type="button"
                  class="file-tree-file"
                  class:active={node.path === buffer.activePath}
                  aria-current={node.path === buffer.activePath ? 'page' : undefined}
                  aria-label={node.path}
                  title={node.path}
                  onclick={() => onOpen(node.path)}>{node.name}</button
                >
              {/if}
            </li>
          {/each}
        </ul>
      {/snippet}
      {@render treeLevel(tree)}
    {/if}
  </nav>
</section>
