<script lang="ts">
  import { Tween } from 'svelte/motion';
  import { cubicOut } from 'svelte/easing';
  import { fade } from 'svelte/transition';
  import { motionMs } from '../lib/motion';
  import { previewTone } from '../lib/utils';
  import { preview } from '../lib/state/preview.svelte';

  let {
    onRebuild
  }: {
    onRebuild: () => void;
  } = $props();

  // The constrained viewport width tweens between the author-selected widths;
  // under prefers-reduced-motion it jumps straight to the target.
  const frameWidth = Tween.of(() => (preview.width === 'full' ? 0 : Number(preview.width)), {
    duration: () => motionMs('base'),
    easing: cubicOut
  });

  const tone = $derived(previewTone(preview.data));
</script>

<section id="preview" class="pane" tabindex="-1" aria-labelledby="preview-heading">
  <div class="pane-heading">
    <div>
      <h2 id="preview-heading">Preview</h2>
      <p>The frame serves unchanged files from Boris's committed <code>dist/</code> output.</p>
    </div>
    <div class="preview-actions toolbar" aria-label="Preview actions">
      <button type="button" disabled={preview.data?.phase === 'running'} onclick={onRebuild}>Rebuild preview</button>
      {#if preview.data && (preview.data.phase === 'success' || preview.data.phase === 'stale')}
        <a class="button-link" href={preview.data.preview_url} target="_blank" rel="noreferrer">Open preview in new tab</a>
      {/if}
    </div>
  </div>
  <fieldset class="preview-viewports" aria-label="Preview width">
    <legend>Preview width</legend>
    <label><input type="radio" name="preview-width" value="full" checked={preview.width === 'full'} onchange={() => (preview.width = 'full')} /> Full pane</label>
    <label><input type="radio" name="preview-width" value="375" checked={preview.width === '375'} onchange={() => (preview.width = '375')} /> 375px</label>
    <label><input type="radio" name="preview-width" value="768" checked={preview.width === '768'} onchange={() => (preview.width = '768')} /> 768px</label>
    <label><input type="radio" name="preview-width" value="1440" checked={preview.width === '1440'} onchange={() => (preview.width = '1440')} /> 1440px</label>
  </fieldset>
  <details class="preview-a11y disclosure">
    <summary>Accessibility review aid</summary>
    <p>This list does not replace a screen reader or a real audit.</p>
    <ul>
      <li>Open the preview in a new tab and read the page with your screen reader.</li>
      <li>Tab through the compiled page without a pointer.</li>
      <li>Check that status is not color-only.</li>
    </ul>
  </details>
  {#key preview.data?.phase ?? 'idle'}
    <p class="preview-state notice" data-tone={tone} in:fade={{ duration: motionMs('fast') }}>
      <strong class="badge" data-tone={tone}>{preview.data?.phase ?? 'idle'}<span class="visually-hidden-text">:</span></strong> {preview.status}
    </p>
  {/key}
  {#if preview.data?.watch_active || preview.watchRefusal}
    <p class="notice" data-tone="warn" role="status" aria-label="Watch daemon active note">The watch daemon is active: Boris builds run on the daemon's cycle and manual rebuild is refused. Stop the watch daemon in the Watch pane to rebuild by hand.</p>
  {/if}
  {#if preview.data?.used_stderr_fallback}
    <p class="notice" data-tone="warn">Rich HTML diagnostics are unavailable; this failure message comes from bounded Boris stderr.</p>
  {/if}
  {#if preview.data && (preview.data.phase === 'success' || preview.data.phase === 'stale')}
    <div class="preview-frame" class:constrained={preview.width !== 'full'} style={preview.width === 'full' ? undefined : `width:${frameWidth.current}px`}>
      <iframe
        title="Boris site preview"
        src={`${preview.data.preview_url}&generation=${preview.data.generation}`}
        sandbox="allow-same-origin"
      ></iframe>
    </div>
  {:else}
    <p class="empty-state" class:is-loading={preview.data?.phase === 'running'}>No valid Boris preview output is available yet.</p>
  {/if}
</section>
