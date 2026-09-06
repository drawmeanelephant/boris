<script lang="ts">
  import type { Problem, GraphNode } from '../lib/types';
  import { buffer, dirty, editSource, undo, redo, trackCursor } from '../lib/state/buffer.svelte';
  import { graph } from '../lib/state/graph.svelte';
  import { activeProblems, staleProblems } from '../lib/state/problems.svelte';
  import { problemLocationLabel } from '../lib/utils';
  import AuthoringTools from './AuthoringTools.svelte';
  import GraphPane from './GraphPane.svelte';
  import RecipePane from './RecipePane.svelte';
  import ThemePane from './ThemePane.svelte';
  import PublicationPane from './PublicationPane.svelte';

  let {
    onSave,
    onNavigate,
    onOpenFile,
    onOpenGraphNode,
    onImpact,
    onScale,
    onReset,
    onRunPlan,
    onEnterFocus
  }: {
    onSave: () => void;
    onNavigate: (problem: Problem) => void;
    onOpenFile: (path: string) => void;
    onOpenGraphNode: (node: GraphNode | null) => void;
    onImpact: () => void;
    onScale: () => void;
    onReset: () => void;
    onRunPlan: () => void;
    onEnterFocus: (trigger: HTMLElement | null) => void;
  } = $props();

  let focusEntry = $state() as HTMLButtonElement | undefined;
</script>

<section id="source" class="source-pane" tabindex="-1" aria-labelledby="source-heading">
  <div class="source-heading">
    <div>
      <h2 id="source-heading">Source</h2>
      <p class="path">{buffer.activePath || 'No file selected'}</p>
    </div>
    <div class="source-actions" aria-label="Editing actions">
      <button
        type="button"
        bind:this={focusEntry}
        onclick={() => onEnterFocus(focusEntry ?? null)}
        title="Expand to a full-screen writing surface (Esc returns)"
      >Focus</button>
      <button type="button" disabled={buffer.undoStack.length === 0 || buffer.readOnly} onclick={undo}>Undo</button>
      <button type="button" disabled={buffer.redoStack.length === 0 || buffer.readOnly} onclick={redo}>Redo</button>
      <button type="button" class="primary" disabled={!dirty() || buffer.readOnly || buffer.saveInFlight} onclick={onSave}>Save file</button>
    </div>
  </div>
  {#if buffer.activePath}
    <label for="source-editor">Source for {buffer.activePath}</label>
    <textarea
      id="source-editor"
      value={buffer.content}
      readonly={buffer.readOnly}
      spellcheck="false"
      oninput={editSource}
      onselect={trackCursor}
      onclick={trackCursor}
      onkeyup={trackCursor}
    ></textarea>
    <AuthoringTools />
    <GraphPane
      onOpenPath={onOpenFile}
      onOpenNode={onOpenGraphNode}
      onImpact={onImpact}
    />
    <RecipePane
      onScale={onScale}
      onReset={onReset}
      onOpenNode={onOpenGraphNode}
    />
    <ThemePane
      onOpenFile={onOpenFile}
      onNavigate={onNavigate}
    />
    <p class:warning={dirty() || buffer.readOnly} class="buffer-state">
      {buffer.readOnly ? 'Read-only file' : dirty() ? 'Unsaved changes' : 'Saved on disk'}
    </p>
    {#if activeProblems().length > 0}
      <aside class="inline-problems" aria-label="Problems in {buffer.activePath}">
        <h3>Problems in this file</h3>
        <ul>
          {#each activeProblems() as problem}
            <li>
              <button type="button" onclick={() => onNavigate(problem)}>
                Go to {problemLocationLabel(problem)}: {problem.code ?? 'Unstructured Boris output'}
              </button>
              {#if staleProblems().has(problem)}
                <p class="warning-text">Possibly stale — the open buffer changed this region since the report.</p>
              {/if}
            </li>
          {/each}
        </ul>
      </aside>
    {/if}
  {:else}
    <p>Choose a file from Project files. Generated output and editor state are intentionally excluded.</p>
    <section id="graph-empty" class="graph-pane" tabindex="-1" aria-labelledby="graph-heading-empty">
      <h3 id="graph-heading-empty">Graph</h3>
      <p role="status" aria-label="Graph status" aria-live="polite">{graph.status}</p>
    </section>
  {/if}
  <p role="status" aria-label="Editing status" aria-live="polite">{buffer.editorStatus}</p>
  <PublicationPane onRunPlan={onRunPlan} />
</section>
