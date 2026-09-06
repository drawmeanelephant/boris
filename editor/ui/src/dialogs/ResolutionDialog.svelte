<script lang="ts">
  import { buffer } from '../lib/state/buffer.svelte';
  import { dialogs, resolutionPrompt, resolutionVerb } from '../lib/state/dialogs.svelte';

  let {
    dialog = $bindable(),
    onKeydown,
    onClose,
    onCancel,
    onDiscard,
    onSave
  }: {
    dialog: HTMLDialogElement | undefined;
    onKeydown: (event: KeyboardEvent) => void;
    onClose: () => void;
    onCancel: () => void;
    onDiscard: () => void;
    onSave: () => void;
  } = $props();
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="resolution-heading">
  <h2 id="resolution-heading">Unsaved changes in {buffer.activePath}</h2>
  <p>{resolutionPrompt()}</p>
  <div class="dialog-actions">
    <button type="button" onclick={onCancel}>Cancel<kbd>Esc</kbd></button>
    <button type="button" onclick={onDiscard}>Discard &amp; {resolutionVerb()}<kbd>Alt+D</kbd></button>
    <button type="button" class="primary" onclick={onSave}>Save &amp; {resolutionVerb()}<kbd>Alt+S</kbd></button>
  </div>
</dialog>
