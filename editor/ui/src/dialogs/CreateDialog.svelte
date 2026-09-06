<script lang="ts">
  import { connection } from '../lib/state/connection.svelte';
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
    <input id="create-path" value={dialogs.createPath} oninput={(e) => (dialogs.createPath = (e.currentTarget as HTMLInputElement).value)} />
    <div class="dialog-actions">
      <button type="button" onclick={onCancel}>Cancel<kbd>Esc</kbd></button>
      <button type="submit" class="primary" disabled={!submitReady}>Create file<kbd>Enter</kbd></button>
    </div>
  </form>
</dialog>
