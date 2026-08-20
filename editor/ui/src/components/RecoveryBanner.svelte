<script lang="ts">
  import type { RecoverySnapshot } from '../lib/types';

  let {
    snapshots,
    onRestore,
    onDiscard
  }: {
    snapshots: RecoverySnapshot[];
    onRestore: (snapshot: RecoverySnapshot) => void;
    onDiscard: (path: string) => void;
  } = $props();
</script>

{#if snapshots.length > 0}
  <aside class="recovery-banner" aria-labelledby="recovery-heading">
    <div>
      <h2 id="recovery-heading">Recovered unsaved work</h2>
      <p>Recovery copies never replace project files without an explicit save.</p>
      <p class="key-hint"><kbd>Tab</kbd> to an action · <kbd>Enter</kbd> runs it</p>
    </div>
    <ul>
      {#each snapshots as snapshot (snapshot.path)}
        <li>
          <span>{snapshot.path}</span>
          <button type="button" onclick={() => onRestore(snapshot)}>Restore {snapshot.path}</button>
          <button type="button" onclick={() => onDiscard(snapshot.path)}>Discard recovery for {snapshot.path}</button>
        </li>
      {/each}
    </ul>
  </aside>
{/if}
