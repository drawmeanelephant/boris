<script lang="ts">
  let {
    dialog = $bindable(),
    activePath,
    onKeydown,
    onClose,
    onDelete,
    onCancel
  }: {
    dialog: HTMLDialogElement | undefined;
    activePath: string;
    onKeydown: (event: KeyboardEvent) => void;
    onClose: () => void;
    onDelete: () => void;
    onCancel: () => void;
  } = $props();
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="delete-heading">
  <h2 id="delete-heading">Delete file</h2>
  <p>Delete {activePath || 'selected file'}? This changes the project immediately and cannot be undone in Boris Editor.</p>
  <div class="dialog-actions">
    <button type="button" onclick={onCancel}>Cancel<kbd>Esc</kbd></button>
    <button type="button" class="danger" onclick={onDelete}>Delete {activePath || 'file'}<kbd>Enter</kbd></button>
  </div>
</dialog>
