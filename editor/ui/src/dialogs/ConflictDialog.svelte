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

  let deletedVersion = $state<HTMLTextAreaElement | undefined>();
  let unsavedVersion = $state<HTMLTextAreaElement | undefined>();
  let diskVersion = $state<HTMLTextAreaElement | undefined>();

  // Compare panes can otherwise reopen at leftover scroll offsets from a
  // previous conflict, so the two columns look more divergent than they are.
  $effect(() => {
    void buffer.content;
    void buffer.conflict?.content;
    void buffer.deletedConflict;
    if (deletedVersion) deletedVersion.scrollTop = 0;
    if (unsavedVersion) unsavedVersion.scrollTop = 0;
    if (diskVersion) diskVersion.scrollTop = 0;
  });
</script>

<dialog bind:this={dialog} onkeydown={onKeydown} onclose={onClose} aria-labelledby="conflict-heading">
  <h2 id="conflict-heading">{buffer.deletedConflict ? 'File deleted outside Boris Editor' : 'External changes detected'}</h2>
  {#if buffer.deletedConflict}
    <p>{buffer.activePath} no longer exists on disk. Your unsaved version is still in the editor.</p>
    <label for="deleted-version">Your unsaved version</label>
    <textarea id="deleted-version" bind:this={deletedVersion} readonly value={buffer.content}></textarea>
    <div class="dialog-actions">
      <button type="button" aria-keyshortcuts="Escape" onclick={onKeepEditing}>Keep editing<kbd aria-hidden="true">Esc</kbd></button>
      <button type="button" aria-keyshortcuts="Alt+D" onclick={onDiscardDeleted}>Discard changes<kbd aria-hidden="true">Alt+D</kbd></button>
      <button type="button" class="primary" aria-keyshortcuts="Enter" onclick={onRecreate}>Re-create file<kbd aria-hidden="true">Enter</kbd></button>
    </div>
  {:else if buffer.conflict}
    <p>{buffer.activePath} changed on disk after you opened it. Compare both versions before choosing.</p>
    <div class="comparison">
      <div>
        <label for="unsaved-version">Your unsaved version</label>
        <textarea id="unsaved-version" bind:this={unsavedVersion} readonly value={buffer.content}></textarea>
      </div>
      <div>
        <label for="disk-version">Current disk version</label>
        <textarea id="disk-version" bind:this={diskVersion} readonly value={buffer.conflict.content}></textarea>
      </div>
    </div>
    <div class="dialog-actions">
      <button type="button" aria-keyshortcuts="Escape" onclick={onKeepEditing}>Keep editing<kbd aria-hidden="true">Esc</kbd></button>
      <button type="button" aria-keyshortcuts="Alt+L" onclick={onLoadDisk}>Load disk version<kbd aria-hidden="true">Alt+L</kbd></button>
      <button type="button" class="primary" aria-keyshortcuts="Enter" onclick={onReplace}>Replace disk version<kbd aria-hidden="true">Enter</kbd></button>
    </div>
  {/if}
</dialog>
