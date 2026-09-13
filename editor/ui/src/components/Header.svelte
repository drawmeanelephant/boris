<script lang="ts">
  import { theme, toggleTheme } from '../lib/theme.svelte';
  import { density, setDensity } from '../lib/state/density.svelte';

  let { connection }: { connection: string } = $props();
</script>

<header>
  <a
    class="skip-link"
    href="#workspace"
    onclick={(event) => {
      event.preventDefault();
      document.getElementById('workspace')?.focus();
    }}>Skip to workspace</a
  >
  <div>
    <p class="eyebrow">Local authoring environment</p>
    <h1>Boris Editor</h1>
  </div>
  <p class="connection" role="status" aria-label="Connection status" aria-live="polite">{connection}</p>
  <div class="header-preferences">
    <!-- Density mode (#990): a disposable per-browser preference, kept out of
         project truth. Author is the calm writing view; Review restores the
         full diagnostics chrome. -->
    <div class="density-toggle" role="group" aria-label="Editor density">
      <button
        type="button"
        class="density-option"
        aria-pressed={density.mode === 'author'}
        title="Calm writing view: Source and Project only"
        onclick={() => setDensity('author')}>Author</button
      >
      <button
        type="button"
        class="density-option"
        aria-pressed={density.mode === 'review'}
        title="Full review chrome: Problems, Graph, Preview, Publication, and Watch"
        onclick={() => setDensity('review')}>Review</button
      >
    </div>
    <button
      type="button"
      class="theme-toggle"
      aria-pressed={theme.current === 'dark'}
      onclick={toggleTheme}>Theme: {theme.current}</button
    >
  </div>
</header>
