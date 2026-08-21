<script lang="ts">
  import type { FileEntry, Problem } from '../lib/types';
  import { problemLocationLabel } from '../lib/utils';

  let {
    themeLayoutOpen,
    closedLayoutSlots,
    layoutSlotsInBuffer,
    layoutSlotsMissing,
    themeAssets,
    layoutSelections,
    onOpenFile,
    onNavigate
  }: {
    themeLayoutOpen: boolean;
    closedLayoutSlots: string[];
    layoutSlotsInBuffer: string[];
    layoutSlotsMissing: string[];
    themeAssets: FileEntry[];
    layoutSelections: Problem[];
    onOpenFile: (path: string) => void;
    onNavigate: (problem: Problem) => void;
  } = $props();
</script>

{#if themeLayoutOpen}
  <section class="theme-pane" aria-labelledby="theme-heading">
    <div class="problems-heading">
      <div>
        <h3 id="theme-heading">Theme layout</h3>
        <p>Closed slots come from Boris <code>completion.json</code>. The buffer scan is presentation only.</p>
      </div>
    </div>
    <p class="fallback-notice">Layout winners appear as <code>ILAYOUTSELECTED</code> after Build HTML or Validate. Fallback winners appear when the target has layout rules.</p>
    {#if closedLayoutSlots.length === 0}
      <p>Build diagnostics to load the closed layout-slot vocabulary.</p>
    {:else}
      <h4>Slots in this layout</h4>
      <ul class="graph-links">
        {#each layoutSlotsInBuffer as slot (slot)}
          <li>Present: <code>{'{{' + slot + '}}'}</code></li>
        {/each}
      </ul>
      {#if layoutSlotsMissing.length > 0}
        <h4>Closed slots not in this file</h4>
        <ul class="graph-links">
          {#each layoutSlotsMissing as slot (slot)}
            <li>Absent: <code>{'{{' + slot + '}}'}</code></li>
          {/each}
        </ul>
      {/if}
    {/if}
    {#if themeAssets.length > 0}
      <h4>Theme assets</h4>
      <ul class="graph-links">
        {#each themeAssets as asset (asset.path)}
          <li><button type="button" onclick={() => onOpenFile(asset.path)}>Open {asset.path}</button></li>
        {/each}
      </ul>
    {/if}
    {#if layoutSelections.length > 0}
      <h4>Layout selection from the last HTML report</h4>
      <ul class="graph-links">
        {#each layoutSelections as problem}
          <li>
            {#if problem.source_path}
              <button type="button" onclick={() => onNavigate(problem)}>
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
