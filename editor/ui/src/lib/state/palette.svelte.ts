// editor/ui/src/lib/state/palette.svelte.ts
// Command palette state: the filter query, the keyboard selection, the
// derived filtered item list (commands, graph entities, openable files), and
// the derived enabled map that keeps every palette action honest about what
// it can do right now.

import { unfilteredPaletteEntryLimit, visibleFileLimit } from '../types';
import { paletteItemDetailPure, paletteItemKey, paletteItemLabel } from '../utils';
import type { PaletteItem } from '../types';
import { buffer, dirty } from './buffer.svelte';
import { focusMode } from './focus.svelte';
import { graph, activeNode, parentNode } from './graph.svelte';
import { problems } from './problems.svelte';
import { project } from './project.svelte';
import { preview } from './preview.svelte';
import { watch, watchStartEnabled, watchStopEnabled } from './watch.svelte';

export const palette = $state({
  query: '',
  selection: 0
});

// Note: derived values are exposed as plain functions that read $state at
// call time. Reactive tracking happens in the caller's template/effect
// context, which keeps every consumer honest about the current state.
export function paletteItems(): PaletteItem[] {
  const needle = palette.query.trim().toLocaleLowerCase();
  // The matcher sees the live context exactly like the pre-runes palette did,
  // so details such as "No graph page is open" only apply when they are true.
  const matches = (item: PaletteItem): boolean => {
    if (!needle) return true;
    return (
      paletteItemLabel(item).toLocaleLowerCase().includes(needle) ||
      paletteItemDetailPure(item, {
        activePath: buffer.activePath,
        parentNode: parentNode(),
        activeNode: activeNode(),
        graphPayload: graph.payload
      }).toLocaleLowerCase().includes(needle)
    );
  };
  const items: PaletteItem[] = [];
  const commands: PaletteItem[] = [
    { kind: 'create' }, { kind: 'rename' }, { kind: 'delete' },
    { kind: 'save' },
    { kind: 'command', mode: 'validate' },
    { kind: 'command', mode: 'ir_build' },
    { kind: 'command', mode: 'html_build' },
    { kind: 'command', mode: 'check' },
    { kind: 'command', mode: 'impact' },
    { kind: 'command', mode: 'plan' },
    { kind: 'preview' },
    { kind: 'source' },
    { kind: 'focus-enter' },
    { kind: 'focus-exit' },
    { kind: 'parent' },
    { kind: 'impact-here' }
  ];
  for (const item of commands) {
    if (matches(item)) items.push(item);
  }
  // Watch daemon commands exist only when the host answered the state probe;
  // against a pre-#938 host the palette stays exactly as it was.
  if (watch.supported === true) {
    const watchCommands: PaletteItem[] = [{ kind: 'watch-start' }, { kind: 'watch-stop' }, { kind: 'watch-go' }];
    for (const item of watchCommands) {
      if (matches(item)) items.push(item);
    }
  }
  const entryCap = needle ? visibleFileLimit : unfilteredPaletteEntryLimit;
  let entities = 0;
  for (const node of graph.payload?.graph?.nodes ?? []) {
    const item: PaletteItem = { kind: 'entity', id: node.id };
    if (!matches(item)) continue;
    items.push(item);
    entities += 1;
    if (entities >= entryCap) break;
  }
  let opens = 0;
  for (const file of project.files) {
    const item: PaletteItem = { kind: 'open', path: file.path };
    if (!matches(item)) continue;
    items.push(item);
    opens += 1;
    if (opens >= entryCap) break;
  }
  return items;
}

export function paletteEnabled(): Map<string, boolean> {
  return new Map<string, boolean>(
    paletteItems().map(item => {
      if (item.kind === 'open' || item.kind === 'source' || item.kind === 'entity') return [paletteItemKey(item), true] as const;
      if (item.kind === 'focus-enter') return [paletteItemKey(item), !focusMode.open] as const;
      if (item.kind === 'focus-exit') return [paletteItemKey(item), focusMode.open] as const;
      if (item.kind === 'parent') return [paletteItemKey(item), parentNode() !== null] as const;
      if (item.kind === 'impact-here') return [paletteItemKey(item), activeNode() !== null && !problems.running] as const;
      if (item.kind === 'save') return [paletteItemKey(item), dirty() && !buffer.readOnly && !buffer.saveInFlight] as const;
      if (item.kind === 'preview') return [paletteItemKey(item), preview.data?.phase !== 'running'] as const;
      if (item.kind === 'command') return [paletteItemKey(item), !problems.running] as const;
      if (item.kind === 'watch-start') return [paletteItemKey(item), watchStartEnabled()] as const;
      if (item.kind === 'watch-stop') return [paletteItemKey(item), watchStopEnabled()] as const;
      if (item.kind === 'watch-go') return [paletteItemKey(item), true] as const;
      if (dirty()) return [paletteItemKey(item), false] as const;
      return [paletteItemKey(item), item.kind === 'create' || buffer.activePath !== ''] as const;
    })
  );
}
