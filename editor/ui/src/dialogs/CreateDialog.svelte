<script lang="ts">
  let {
    dialog = $bindable(),
    createPath,
    onPathChange,
    onKeydown,
    onClose,
    onCreate,
    onCancel
  }: {
    dialog: HTMLDialogElement | undefined;
    createPath: string;
    onPathChange: (value: string) => void;
    onKeydown: (event: KeyboardEvent) => void;
    onClose: () => void;
    onCreate: () => void;
    onCancel: () => void;
  } = $props();
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="create-heading">
  <h2 id="create-heading">Create file</h2>
  <p>Use a project-relative path under content/ or themes/, or boris.json. Markdown (<code>.md</code>), Textile (<code>.textile</code>), and Cooklang (<code>.cook</code>) pages are valid.</p>
  <form onsubmit={(event) => { event.preventDefault(); onCreate(); }}>
    <label for="create-path">New file path</label>
    <input id="create-path" value={createPath} oninput={(e) => onPathChange((e.currentTarget as HTMLInputElement).value)} />
    <div class="dialog-actions">
      <button type="button" onclick={onCancel}>Cancel<kbd>Esc</kbd></button>
      <button type="submit" class="primary">Create file<kbd>Enter</kbd></button>
    </div>
  </form>
</dialog>
