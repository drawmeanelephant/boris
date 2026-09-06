<script lang="ts">
  import { buffer } from '../lib/state/buffer.svelte';

  let {
    dialog = $bindable(),
    onKeydown,
    onClose,
    onDelete,
    onCancel
  }: {
    dialog: HTMLDialogElement | undefined;
    onKeydown: (event: KeyboardEvent) => void;
    onClose: () => void;
    onDelete: () => void;
    onCancel: () => void;
  } = $props();
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="delete-heading">
  <h2 id="delete-heading">Delete file</h2>
  <p>Delete {buffer.activePath || 'selected file'}? This changes the project immediately and cannot be undone in Boris Editor.</p>
  <div class="dialog-actions">
    <button type="button" onclick={onCancel}>Cancel<kbd>Esc</kbd></button>
    <button type="button" class="danger" onclick={onDelete}>Delete {buffer.activePath || 'file'}<kbd>Enter</kbd></button>
  </div>
</dialog>
