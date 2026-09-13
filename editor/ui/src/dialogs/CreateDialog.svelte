<script lang="ts">
  import { dialogs } from '../lib/state/dialogs.svelte';

  let {
    dialog = $bindable(),
    onKeydown,
    onClose,
    onCreate,
    onCancel
  }: {
    dialog: HTMLDialogElement | undefined;
    onKeydown: (event: KeyboardEvent) => void;
    onClose: () => void;
    onCreate: () => void;
    onCancel: () => void;
  } = $props();

  // An empty path cannot create anything; the App-level early return in
  // createFile() would swallow the submit silently. Disabling the submitter
  // surfaces that as native form invalidity — the button reads disabled and
  // the browser blocks implicit Enter submission when the only submitter is
  // disabled (the same convention the Project pane buttons use).
  const submitReady = $derived(dialogs.createPath.trim().length > 0);
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="create-heading">
  <h2 id="create-heading">Create file</h2>
  <p>Use a project-relative path under content/ or themes/, or boris.json. Markdown (<code>.md</code>), Textile (<code>.textile</code>), and Cooklang (<code>.cook</code>) pages are valid.</p>
  <form onsubmit={(event) => { event.preventDefault(); onCreate(); }}>
    <label for="create-path">New file path</label>
    <input
      id="create-path"
      value={dialogs.createPath}
      aria-invalid={dialogs.createError ? 'true' : undefined}
      aria-describedby={dialogs.createError ? 'create-error' : undefined}
      oninput={(e) => {
        dialogs.createPath = (e.currentTarget as HTMLInputElement).value;
        dialogs.createError = '';
      }}
    />
    {#if dialogs.createError}
      <p id="create-error" class="warning-text" role="alert">{dialogs.createError}</p>
    {/if}
    <div class="dialog-actions">
      <button type="button" aria-keyshortcuts="Escape" onclick={onCancel}>Cancel<kbd aria-hidden="true">Esc</kbd></button>
      <button type="submit" class="primary" disabled={!submitReady} aria-keyshortcuts="Enter">Create file<kbd aria-hidden="true">Enter</kbd></button>
    </div>
  </form>
</dialog>
