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
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="rename-heading">
  <h2 id="rename-heading">Rename file</h2>
  <p>Rename {buffer.activePath} without replacing an existing file.</p>
  <form onsubmit={(event) => { event.preventDefault(); onRename(); }}>
    <label for="rename-path">New file path</label>
    <input id="rename-path" value={dialogs.renamePath} oninput={(e) => (dialogs.renamePath = (e.currentTarget as HTMLInputElement).value)} />
    <div class="dialog-actions">
      <button type="button" onclick={onCancel}>Cancel<kbd>Esc</kbd></button>
      <button type="submit" class="primary">Rename file<kbd>Enter</kbd></button>
    </div>
  </form>
</dialog>
