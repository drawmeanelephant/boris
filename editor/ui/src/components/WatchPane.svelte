<script lang="ts">
  import { fade } from 'svelte/transition';
  import { motionMs } from '../lib/motion';
  import {
    watch,
    watchStartEnabled,
    watchStopEnabled,
    startWatchDaemon,
    stopWatchDaemon
  } from '../lib/state/watch.svelte';
  import { stateTone, watchMetaLabel, watchStatusLabel } from '../lib/utils';

  // Start and stop are explicit named clicks straight from the pane; stop is
  // never automatic, and start needs no confirmation because the host owns
  // the fixed `boris watch` invocation (the UI never supplies argv).
</script>

<section id="watch" class="pane watch-pane" aria-labelledby="watch-heading" tabindex="-1">
  <div class="pane-heading">
    <div>
      <h2 id="watch-heading">Watch</h2>
      <p>The host supervises one fixed Boris watch daemon; its own build events stream here.</p>
    </div>
  </div>
  {#if watch.supported === false}
    <p class="watch-unsupported notice" role="status" aria-label="Watch daemon state" aria-live="polite">
      This Boris build does not support the watch daemon.
    </p>
  {:else}
    <div class="watch-state-line">
      <p class="watch-state status-text" data-tone={watch.supported === null || !watch.state ? 'busy' : stateTone(watch.state.state)} role="status" aria-label="Watch daemon state" aria-live="polite">{watchStatusLabel(watch.state, watch.supported)}</p>
      <span class="watch-meta" aria-label="Watch compiler and cycle">{watchMetaLabel(watch.state)}</span>
    </div>
    {#if watch.state?.last_error}
      <p class="notice" data-tone="danger">Last daemon error: {watch.state.last_error}</p>
    {/if}
    <div class="watch-actions toolbar" aria-label="Watch daemon actions">
      <button type="button" disabled={!watchStartEnabled()} onclick={() => void startWatchDaemon()}>Start watch daemon</button>
      <button type="button" disabled={!watchStopEnabled()} onclick={() => void stopWatchDaemon()}>Stop watch daemon</button>
    </div>
    <p role="status" aria-label="Watch status" aria-live="polite">{watch.status}</p>
    {#if watch.feed.length === 0}
      <p class="watch-feed-empty empty-state">No watch events have arrived yet.</p>
    {:else}
      <ol class="watch-feed" aria-label="Watch event feed">
        {#each watch.feed as item (item.key)}
          <li class="watch-event watch-event-{item.tone}" in:fade={{ duration: motionMs('fast') }}>
            {#if item.seq !== null}<span class="watch-event-seq">#{item.seq}</span>{/if}
            <span class="watch-event-label">{item.label}</span>
          </li>
        {/each}
      </ol>
    {/if}
  {/if}
</section>
