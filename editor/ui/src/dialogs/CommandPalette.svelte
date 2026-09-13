<script lang="ts">
  import { fly } from 'svelte/transition';
  import { prefersReducedMotion } from 'svelte/motion';
  import type { PaletteItem } from '../lib/types';
  import { paletteItemKey, paletteItemLabel, paletteItemDetailWrapper } from '../lib/utils';
  import { palette, paletteItems, paletteEnabled } from '../lib/state/palette.svelte';
  import { buffer } from '../lib/state/buffer.svelte';
  import { graph, activeNode, parentNode } from '../lib/state/graph.svelte';

  let {
    dialog = $bindable(),
    onKeydown,
    onBackdropClick,
    onDialogClose,
    onCancel,
    onExecute
  }: {
    dialog: HTMLDialogElement | undefined;
    onKeydown: (event: KeyboardEvent) => void;
    onBackdropClick: (event: MouseEvent) => void;
    onDialogClose: () => void;
    onCancel: () => void;
    onExecute: (item: PaletteItem) => void;
  } = $props();

  function detailFor(item: PaletteItem): string {
    // Use the pure wrapper that takes explicit ctx so the palette detail stays honest
    return paletteItemDetailWrapper(
      item,
      buffer.activePath,
      parentNode(),
      activeNode(),
      graph.payload
    );
  }

  function isEnabled(item: PaletteItem): boolean {
    return paletteEnabled().get(paletteItemKey(item)) ?? false;
  }
</script>

<dialog
  class="command-palette"
  bind:this={dialog}
  onkeydown={onKeydown}
  onclick={onBackdropClick}
  onclose={onDialogClose}
  aria-labelledby="palette-heading"
>
  <h2 id="palette-heading">Commands</h2>
  <p>Ctrl+K anywhere opens this palette. Esc or a click outside closes it.</p>
  <label for="palette-query">Filter commands</label>
  <input
    id="palette-query"
    role="combobox"
    aria-autocomplete="list"
    aria-expanded={paletteItems().length > 0}
    aria-controls="palette-options"
    aria-activedescendant={paletteItems().length ? `palette-option-${palette.selection}` : undefined}
    value={palette.query}
    oninput={(e) => (palette.query = (e.currentTarget as HTMLInputElement).value)}
  />
  {#if paletteItems().length > 0}
    <ul id="palette-options" role="listbox" aria-label="Boris commands">
      {#each paletteItems() as item, itemIndex (paletteItemKey(item))}
        <li
          id="palette-option-{itemIndex}"
          role="option"
          tabindex="-1"
          aria-selected={itemIndex === palette.selection}
          aria-label="{paletteItemLabel(item)}; {detailFor(item)}"
          aria-disabled={isEnabled(item) ? 'false' : 'true'}
          class:selected={itemIndex === palette.selection}
          class:disabled={!isEnabled(item)}
          in:fly={{ duration: prefersReducedMotion.current ? 0 : 150, y: prefersReducedMotion.current ? 0 : 4 }}
          onclick={() => { if (isEnabled(item)) onExecute(item); }}
          onkeydown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); if (isEnabled(item)) onExecute(item); } }}
        >
          <strong>{paletteItemLabel(item)}</strong><span>{detailFor(item)}</span>
        </li>
      {/each}
    </ul>
  {:else}
    <p>No commands match “{palette.query}”.</p>
  {/if}
  <div class="dialog-actions">
    <button type="button" aria-keyshortcuts="Escape" onclick={onCancel}>Cancel<kbd aria-hidden="true">Esc</kbd></button>
  </div>
</dialog>
