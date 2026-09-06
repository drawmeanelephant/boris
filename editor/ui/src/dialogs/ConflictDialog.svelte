<script lang="ts">
  import { buffer } from '../lib/state/buffer.svelte';

  let {
    dialog = $bindable(),
    onKeydown,
    onClose,
    onKeepEditing,
    onDiscardDeleted,
    onRecreate,
    onLoadDisk,
    onReplace
  }: {
    dialog: HTMLDialogElement | undefined;
    onKeydown: (event: KeyboardEvent) => void;
    onClose: () => void;
    onKeepEditing: () => void;
    onDiscardDeleted: () => void;
    onRecreate: () => void;
    onLoadDisk: () => void;
    onReplace: () => void;
  } = $props();
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="conflict-heading">
  <h2 id="conflict-heading">{buffer.deletedConflict ? 'File deleted outside Boris Editor' : 'External changes detected'}</h2>
  {#if buffer.deletedConflict}
    <p>{buffer.activePath} no longer exists on disk. Your unsaved version is still in the editor.</p>
    <label for="deleted-version">Your unsaved version</label>
    <textarea id="deleted-version" readonly value={buffer.content}></textarea>
    <div class="dialog-actions">
      <button type="button" onclick={onKeepEditing}>Keep editing<kbd>Esc</kbd></button>
      <button type="button" onclick={onDiscardDeleted}>Discard changes<kbd>Alt+D</kbd></button>
      <button type="button" class="primary" onclick={onRecreate}>Re-create file<kbd>Enter</kbd></button>
    </div>
  {:else if buffer.conflict}
    <p>{buffer.activePath} changed on disk after you opened it. Compare both versions before choosing.</p>
    <div class="comparison">
      <div>
        <label for="unsaved-version">Your unsaved version</label>
        <textarea id="unsaved-version" readonly value={buffer.content}></textarea>
      </div>
      <div>
        <label for="disk-version">Current disk version</label>
        <textarea id="disk-version" readonly value={buffer.conflict.content}></textarea>
      </div>
    </div>
    <div class="dialog-actions">
      <button type="button" onclick={onKeepEditing}>Keep editing<kbd>Esc</kbd></button>
      <button type="button" onclick={onLoadDisk}>Load disk version<kbd>Alt+L</kbd></button>
      <button type="button" class="primary" onclick={onReplace}>Replace disk version<kbd>Enter</kbd></button>
    </div>
  {/if}
</dialog>
