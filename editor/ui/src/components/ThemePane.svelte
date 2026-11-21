<script lang="ts">
  import type { Problem } from '../lib/types';
  import { problemLocationLabel } from '../lib/utils';
  import { buffer } from '../lib/state/buffer.svelte';
  import { authoring, closedLayoutSlots, refreshAuthoring } from '../lib/state/authoring.svelte';
  import { connection } from '../lib/state/connection.svelte';
  import { project, themeAssets } from '../lib/state/project.svelte';
  import { problems, layoutSelections } from '../lib/state/problems.svelte';

  let {
    onOpenFile,
    onNavigate,
    onBuildDiagnostics
  }: {
    onOpenFile: (path: string) => void;
    onNavigate: (problem: Problem) => void;
    onBuildDiagnostics: () => void;
  } = $props();

  const themeLayoutOpen = $derived(buffer.activePath.startsWith('themes/') && buffer.activePath.endsWith('.html'));
  const layoutSlotsInBuffer = $derived(closedLayoutSlots().filter(slot => buffer.content.includes(`{{${slot}}}`)));
  const layoutSlotsMissing = $derived(closedLayoutSlots().filter(slot => !buffer.content.includes(`{{${slot}}}`)));
</script>

{#if themeLayoutOpen}
  <section class="subpane theme-pane" aria-labelledby="theme-heading">
    <div class="pane-heading">
      <div>
        <h3 id="theme-heading">Theme layout</h3>
        <p>Closed slots come from Boris <code>completion.json</code>. The buffer scan is presentation only.</p>
      </div>
    </div>
    <p class="notice">Layout winners appear as <code>ILAYOUTSELECTED</code> after Build HTML or Validate. Fallback winners appear when the target has layout rules.</p>
    {#if !authoring.payload && connection.phase === 'connecting'}
      <p class="empty-state is-loading">Loading layout hints…</p>
    {:else if !authoring.payload || authoring.failed}
      <div class="notice" data-tone="danger">
        <p>Layout hints could not be loaded or refreshed. Previous hints, if any, remain unchanged.</p>
        <button type="button" onclick={refreshAuthoring}>Refresh layout hints</button>
      </div>
    {:else if authoring.payload.completion_status !== 'ready'}
      <div class="notice" data-tone={authoring.payload.completion_status === 'unsupported' ? 'warn' : 'neutral'}>
        <p>{authoring.payload.completion_status === 'unsupported' ? 'The saved layout hints are stale or unsupported.' : 'Layout hints have not been built yet.'} Build diagnostics to load the slots Boris supports. Results open in Problems.</p>
        <button
          type="button"
          class:is-running={problems.running && problems.runningMode === 'ir_build'}
          aria-busy={problems.running && problems.runningMode === 'ir_build'}
          disabled={problems.running}
          onclick={onBuildDiagnostics}>Build diagnostics for layout slots</button>
      </div>
    {/if}
    {#if authoring.payload?.completion_status === 'ready'}
      {#if closedLayoutSlots().length === 0}
        <p class="empty-state">Boris reported no layout slots in the current completion index.</p>
      {:else}
        <h4 class="group-label">Slots in this layout</h4>
        {#if layoutSlotsInBuffer.length === 0}
          <p class="empty-state">None of the closed slots appear in this file yet.</p>
        {:else}
          <ul class="graph-links row-list">
            {#each layoutSlotsInBuffer as slot (slot)}
              <li>Present: <code>{'{{' + slot + '}}'}</code></li>
            {/each}
          </ul>
        {/if}
        {#if layoutSlotsMissing.length > 0}
          <h4 class="group-label">Closed slots not in this file</h4>
          <ul class="graph-links row-list">
            {#each layoutSlotsMissing as slot (slot)}
              <li>Absent: <code>{'{{' + slot + '}}'}</code></li>
            {/each}
          </ul>
        {/if}
      {/if}
    {/if}
    {#if themeAssets().length > 0}
      <h4 class="group-label">Theme assets</h4>
      <ul class="graph-links row-list">
        {#each themeAssets() as asset (asset.path)}
          <li><button type="button" class="row-button" onclick={() => onOpenFile(asset.path)}>Open {asset.path}</button></li>
        {/each}
      </ul>
    {/if}
    {#if layoutSelections().length > 0}
      <h4 class="group-label">Layout selection from the last HTML report</h4>
      <ul class="graph-links row-list">
        {#each layoutSelections() as problem}
          <li>
            {#if problem.source_path}
              <button type="button" class="row-button" onclick={() => onNavigate(problem)}>
                {problemLocationLabel(problem)}: {problem.message}
              </button>
            {:else}
              {problem.message}
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </section>
{/if}
