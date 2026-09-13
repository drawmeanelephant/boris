<script lang="ts">
  import { buffer } from '../lib/state/buffer.svelte';
  import { dialogs } from '../lib/state/dialogs.svelte';

  let {
    dialog = $bindable(),
    onKeydown,
    onClose,
    onRename,
    onCancel
  }: {
    dialog: HTMLDialogElement | undefined;
    onKeydown: (event: KeyboardEvent) => void;
    onClose: () => void;
    onRename: () => void;
    onCancel: () => void;
  } = $props();

  // Same silent-failure guard as CreateDialog: renameFile() early-returns on
  // an empty path, so clear the input and press Enter and nothing happens.
  // The disabled submitter makes the invalid state visible and lets the
  // browser refuse implicit Enter submission. (No active file is not
  // reachable here — the dialog only opens from active-file affordances.)
  const submitReady = $derived(dialogs.renamePath.trim().length > 0);
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="rename-heading">
  <h2 id="rename-heading">Rename file</h2>
  <p>Rename {buffer.activePath} without replacing an existing file.</p>
  <form onsubmit={(event) => { event.preventDefault(); onRename(); }}>
    <label for="rename-path">New file path</label>
    <input
      id="rename-path"
      value={dialogs.renamePath}
      aria-invalid={dialogs.renameError ? 'true' : undefined}
      aria-describedby={dialogs.renameError ? 'rename-error' : undefined}
      oninput={(e) => {
        dialogs.renamePath = (e.currentTarget as HTMLInputElement).value;
        dialogs.renameError = '';
      }}
    />
    {#if dialogs.renameError}
      <p id="rename-error" class="warning-text" role="alert">{dialogs.renameError}</p>
    {/if}
    <div class="dialog-actions">
      <button type="button" aria-keyshortcuts="Escape" onclick={onCancel}>Cancel<kbd aria-hidden="true">Esc</kbd></button>
      <button type="submit" class="primary" disabled={!submitReady} aria-keyshortcuts="Enter">Rename file<kbd aria-hidden="true">Enter</kbd></button>
    </div>
  </form>
</dialog>
