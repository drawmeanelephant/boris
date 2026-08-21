<script lang="ts">
  import type { PaletteItem } from '../lib/types';
  import { paletteItemKey, paletteItemLabel, paletteItemDetailWrapper, paletteItemEnabledPure } from '../lib/utils';

  let {
    dialog = $bindable(),
    paletteItems,
    paletteEnabled,
    paletteQuery,
    paletteSelection,
    activePath,
    parentNode,
    activeNode,
    graphPayload,
    commandRunning,
    dirty,
    readOnly,
    saveInFlight,
    previewPhase,
    onQueryChange,
    onKeydown,
    onBackdropClick,
    onClose,
    onExecute
  }: {
    dialog: HTMLDialogElement | undefined;
    paletteItems: PaletteItem[];
    paletteEnabled: Map<string, boolean>;
    paletteQuery: string;
    paletteSelection: number;
    activePath: string;
    parentNode: unknown | null;
    activeNode: unknown | null;
    graphPayload: unknown | null;
    commandRunning: boolean;
    dirty: boolean;
    readOnly: boolean;
    saveInFlight: boolean;
    previewPhase?: string;
    onQueryChange: (value: string) => void;
    onKeydown: (event: KeyboardEvent) => void;
    onBackdropClick: (event: MouseEvent) => void;
    onClose: () => void;
    onExecute: (item: PaletteItem) => void;
  } = $props();

  function detailFor(item: PaletteItem): string {
    // Use the pure wrapper that takes explicit ctx so the palette detail stays honest
    return paletteItemDetailWrapper(
      item,
      activePath,
      parentNode as any,
      activeNode as any,
      graphPayload as any
    );
  }

  function isEnabled(item: PaletteItem): boolean {
    return paletteEnabled.get(paletteItemKey(item)) ?? false;
  }
</script>

<dialog
  class="command-palette"
  bind:this={dialog}
  onkeydown={onKeydown}
  onclick={onBackdropClick}
  onclose={onClose}
  aria-labelledby="palette-heading"
>
  <h2 id="palette-heading">Commands</h2>
  <p>Ctrl+K anywhere opens this palette. Esc or a click outside closes it.</p>
  <label for="palette-query">Filter commands</label>
  <input
    id="palette-query"
    role="combobox"
    aria-autocomplete="list"
    aria-expanded={paletteItems.length > 0}
    aria-controls="palette-options"
    aria-activedescendant={paletteItems.length ? `palette-option-${paletteSelection}` : undefined}
    value={paletteQuery}
    oninput={(e) => onQueryChange((e.currentTarget as HTMLInputElement).value)}
  />
  {#if paletteItems.length > 0}
    <ul id="palette-options" role="listbox" aria-label="Boris commands">
      {#each paletteItems as item, itemIndex (paletteItemKey(item))}
        <li
          id="palette-option-{itemIndex}"
          role="option"
          tabindex="-1"
          aria-selected={itemIndex === paletteSelection}
          aria-disabled={isEnabled(item) ? 'false' : 'true'}
          class:selected={itemIndex === paletteSelection}
          class:disabled={!isEnabled(item)}
          onclick={() => { if (isEnabled(item)) onExecute(item); }}
          onkeydown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); if (isEnabled(item)) onExecute(item); } }}
        >
          <strong>{paletteItemLabel(item)}</strong><span>{detailFor(item)}</span>
        </li>
      {/each}
    </ul>
  {:else}
    <p>No commands match “{paletteQuery}”.</p>
  {/if}
  <div class="dialog-actions">
    <button type="button" onclick={onClose}>Cancel<kbd>Esc</kbd></button>
  </div>
</dialog>
