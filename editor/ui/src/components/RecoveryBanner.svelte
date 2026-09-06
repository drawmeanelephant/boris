<script lang="ts">
  import type { RecoverySnapshot } from '../lib/types';
  import { buffer } from '../lib/state/buffer.svelte';

  let {
    onRestore,
    onDiscard
  }: {
    onRestore: (snapshot: RecoverySnapshot) => void;
    onDiscard: (path: string) => void;
  } = $props();
</script>

{#if buffer.snapshots.length > 0}
  <aside class="recovery-banner" aria-labelledby="recovery-heading">
    <div>
      <h2 id="recovery-heading">Recovered unsaved work</h2>
      <p>Recovery copies never replace project files without an explicit save.</p>
      <p class="key-hint"><kbd>Tab</kbd> to an action · <kbd>Enter</kbd> runs it</p>
    </div>
    <ul>
      {#each buffer.snapshots as snapshot (snapshot.path)}
        <li>
          <span>{snapshot.path}</span>
          <button type="button" onclick={() => onRestore(snapshot)}>Restore {snapshot.path}</button>
          <button type="button" onclick={() => onDiscard(snapshot.path)}>Discard recovery for {snapshot.path}</button>
        </li>
      {/each}
    </ul>
  </aside>
{/if}
