<script lang="ts">
  let {
    dialog = $bindable(),
    activePath,
    resolutionPrompt,
    resolutionVerb,
    onKeydown,
    onClose,
    onCancel,
    onDiscard,
    onSave
  }: {
    dialog: HTMLDialogElement | undefined;
    activePath: string;
    resolutionPrompt: string;
    resolutionVerb: string;
    onKeydown: (event: KeyboardEvent) => void;
    onClose: () => void;
    onCancel: () => void;
    onDiscard: () => void;
    onSave: () => void;
  } = $props();
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="resolution-heading">
  <h2 id="resolution-heading">Unsaved changes in {activePath}</h2>
  <p>{resolutionPrompt}</p>
  <div class="dialog-actions">
    <button type="button" onclick={onCancel}>Cancel<kbd>Esc</kbd></button>
    <button type="button" onclick={onDiscard}>Discard &amp; {resolutionVerb}<kbd>Alt+D</kbd></button>
    <button type="button" class="primary" onclick={onSave}>Save &amp; {resolutionVerb}<kbd>Alt+S</kbd></button>
  </div>
</dialog>
