<script lang="ts">
  import { theme, toggleTheme } from '../lib/theme.svelte';
  import { density, setDensity } from '../lib/state/density.svelte';
  import { connection } from '../lib/state/connection.svelte';

  // The connection readout is a compact chip (#993): the live region announces
  // the short label, and the honest sentence is one activation away. The
  // disclosure is deliberately a real button — the detail must be reachable by
  // keyboard and assistive tech, not just by a pointer hover.
  let connectionDetailOpen = $state(false);
</script>

<header data-density={density.mode}>
  <a
    class="skip-link"
    href="#workspace"
    onclick={(event) => {
      event.preventDefault();
      document.getElementById('workspace')?.focus();
    }}>Skip to workspace</a
  >
  <!-- #993: the identity row. The product mark and the live connection status
       are the only things an author needs up here, so they share one row
       instead of stacking as eyebrow + title + a full-width sentence. The
       eyebrow ("Local authoring environment") said nothing on a second
       reading, so it is gone rather than restyled. The status keeps its role
       and accessible name; its text is now the chip's short label, with the
       full sentence behind the disclosure. -->
  <div class="header-identity">
    <h1>Boris Editor</h1>
    <p class="connection" role="status" aria-label="Connection status" aria-live="polite">
      <button
        type="button"
        class="connection-chip"
        aria-expanded={connectionDetailOpen}
        title={connectionDetailOpen ? 'Hide connection details' : 'Show connection details'}
        onclick={() => (connectionDetailOpen = !connectionDetailOpen)}
      >{connection.summary}</button>
      {#if connectionDetailOpen}
        <span class="connection-detail">{connection.status}</span>
      {/if}
    </p>
  </div>
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
    <!-- The theme control is a quiet preference, not a headline: the visible
         label is the state itself, matching its accessible name, and the
         title explains what activating it does. -->
    <button
      type="button"
      class="theme-toggle"
      aria-pressed={theme.current === 'dark'}
      title={`Theme: ${theme.current} — switch to ${theme.current === 'dark' ? 'light' : 'dark'}`}
      onclick={toggleTheme}>{theme.current === 'dark' ? 'Dark' : 'Light'}</button
    >
  </div>
</header>
