<script lang="ts">
  import { theme, toggleTheme } from '../lib/theme.svelte';

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
  <button
    type="button"
    class="theme-toggle"
    aria-pressed={theme.current === 'dark'}
    onclick={toggleTheme}>Theme: {theme.current}</button
  >
</header>
