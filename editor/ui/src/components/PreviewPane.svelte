<script lang="ts">
  import type { PreviewState } from '../lib/types';

  let {
    previewData,
    previewState,
    previewWidth,
    onRebuild,
    onWidthChange
  }: {
    previewData: PreviewState | null;
    previewState: string;
    previewWidth: 'full' | '375' | '768' | '1440';
    onRebuild: () => void;
    onWidthChange: (width: 'full' | '375' | '768' | '1440') => void;
  } = $props();
</script>

<section id="preview" aria-labelledby="preview-heading">
  <div class="preview-heading">
    <div>
      <h2 id="preview-heading">Preview</h2>
      <p>The frame serves unchanged files from Boris's committed <code>dist/</code> output.</p>
    </div>
    <div class="preview-actions" aria-label="Preview actions">
      <button type="button" disabled={previewData?.phase === 'running'} onclick={onRebuild}>Rebuild preview</button>
      {#if previewData && (previewData.phase === 'success' || previewData.phase === 'stale')}
        <a class="button-link" href={previewData.preview_url} target="_blank" rel="noreferrer">Open preview in new tab</a>
      {/if}
    </div>
  </div>
  <fieldset class="preview-viewports" aria-label="Preview width">
    <legend>Preview width</legend>
    <label><input type="radio" name="preview-width" value="full" checked={previewWidth === 'full'} onchange={() => onWidthChange('full')} /> Full pane</label>
    <label><input type="radio" name="preview-width" value="375" checked={previewWidth === '375'} onchange={() => onWidthChange('375')} /> 375px</label>
    <label><input type="radio" name="preview-width" value="768" checked={previewWidth === '768'} onchange={() => onWidthChange('768')} /> 768px</label>
    <label><input type="radio" name="preview-width" value="1440" checked={previewWidth === '1440'} onchange={() => onWidthChange('1440')} /> 1440px</label>
  </fieldset>
  <details class="preview-a11y">
    <summary>Accessibility review aid</summary>
    <p>This list does not replace Voice Control, VoiceOver, or a real audit.</p>
    <ul>
      <li>Open the preview in a new tab and run Voice Control “Show names”.</li>
      <li>Tab through the compiled page without a pointer.</li>
      <li>Check that status is not color-only.</li>
    </ul>
  </details>
  <p class="preview-state" class:current={previewData?.phase === 'success'} class:failure={previewData?.phase === 'failed' || previewData?.phase === 'stale'}>
    <strong>{previewData?.phase ?? 'idle'}:</strong> {previewState}
  </p>
  {#if previewData?.used_stderr_fallback}
    <p class="fallback-notice">Rich HTML diagnostics are unavailable; this failure message comes from bounded Boris stderr.</p>
  {/if}
  {#if previewData && (previewData.phase === 'success' || previewData.phase === 'stale')}
    <div class="preview-frame" class:constrained={previewWidth !== 'full'} style={previewWidth === 'full' ? undefined : `width:${previewWidth}px`}>
      <iframe
        title="Boris site preview"
        src={`${previewData.preview_url}&generation=${previewData.generation}`}
        sandbox="allow-same-origin"
      ></iframe>
    </div>
  {:else}
    <p>No valid Boris preview output is available yet.</p>
  {/if}
</section>
