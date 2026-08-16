#!/usr/bin/env node
// Static conformance lint for the editor's visible key hints.
//
// Every <kbd> hint rendered in App.svelte must be backed by a keyboard
// mechanism on its surface:
//   - a <dialog> surface must carry an onkeydown handler; Esc is native
//     (dialog cancel), Enter is backed by a form submit button, by a
//     programmatic focus call on the dialog, or by the handler itself;
//     any other hinted key must be handled in the dialog's handler body.
//   - a .combobox-wrap surface must have a keydown handler on its filter
//     input and that handler must reference every hinted key.
//   - the .recovery-banner may only hint Tab/Enter (native button focus
//     and activation) and must contain buttons, with Restore routing a
//     dirty buffer through the resolution dialog.
//   - the footer's hints must be covered by the svelte:window keydown
//     handler.
//
// Beyond the hints, the state machines behind them are checked: the
// combobox input must reopen the list on focus/input after Esc closes it,
// the command palette's aria-expanded must track paletteItems while every
// option's Enter handler guards on the enabled state, the resolution
// dialog must clear its pending action on every close (an onclose handler
// assigning pendingResolution to null) with each resolve function nulling
// it before proceeding, and the conflict dialog must clear its conflict
// state on every close (an onclose assigning conflict/deletedConflict)
// with the Load disk version handler clearing conflict before closing.
//
// This keeps the e2e conformance sweep from having to grow by hand: a new
// hint without a matching handler fails CI here first.
//
// Zero dependencies: plain Node, regex + bracket scanning over App.svelte.
// Runs built-in self-tests first, then checks the real source.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SOURCE = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'App.svelte');

// --- key token mapping -----------------------------------------------------

const MODIFIER_KEYS = { Alt: 'altKey', Ctrl: 'ctrlKey', Meta: 'metaKey', Shift: 'shiftKey' };
const KEY_TOKENS = {
  '↑': ['ArrowUp'],
  '↓': ['ArrowDown'],
  Esc: ['Escape'],
  Enter: ['Enter'],
  Tab: ['Tab'],
  Ctrl: ['ctrlKey'],
  Alt: ['altKey'],
  Meta: ['metaKey'],
  Shift: ['shiftKey'],
};

// Maps a <kbd> token to the code tokens its handler body must reference.
function keyCodeTokens(token) {
  const combo = /^(Alt|Ctrl|Shift|Meta)\+([a-zA-Z])$/.exec(token);
  if (combo) return [MODIFIER_KEYS[combo[1]], combo[2].toLowerCase()];
  if (/^[a-zA-Z]$/.test(token)) return [token.toLowerCase()];
  return KEY_TOKENS[token] ?? null;
}

// --- handler extraction ----------------------------------------------------

function scriptBlock(source) {
  const start = source.indexOf('<script');
  if (start === -1) return '';
  const end = source.indexOf('</script>', start);
  return end === -1 ? source.slice(start) : source.slice(start, end);
}

// Extracts balanced { } bodies for every `function NAME(` in the script. The
// body brace is the first { after the parameter list closes, so type
// annotations like `{ path: string }` inside the signature are skipped.
function handlerBodies(script) {
  const bodies = new Map();
  const re = /function\s+([A-Za-z_$][\w$]*)\s*\(/g;
  let match;
  while ((match = re.exec(script))) {
    const name = match[1];
    const parenOpen = match.index + match[0].length - 1;
    let depth = 0;
    let quote = null;
    let parenClose = -1;
    for (let i = parenOpen; i < script.length; i++) {
      const ch = script[i];
      if (quote) {
        if (ch === quote && script[i - 1] !== '\\') quote = null;
      } else if (ch === '"' || ch === "'" || ch === '`') {
        quote = ch;
      } else if (ch === '(') {
        depth += 1;
      } else if (ch === ')') {
        depth -= 1;
        if (depth === 0) {
          parenClose = i;
          break;
        }
      }
    }
    if (parenClose === -1) continue;
    const open = script.indexOf('{', parenClose + 1);
    if (open === -1) continue;
    let bodyDepth = 0;
    quote = null;
    let end = open;
    for (; end < script.length; end++) {
      const ch = script[end];
      if (quote) {
        if (ch === quote && script[end - 1] !== '\\') quote = null;
      } else if (ch === '"' || ch === "'" || ch === '`') {
        quote = ch;
      } else if (ch === '{') {
        bodyDepth += 1;
      } else if (ch === '}') {
        bodyDepth -= 1;
        if (bodyDepth === 0) break;
      }
    }
    bodies.set(name, script.slice(open, end + 1));
  }
  return bodies;
}

// --- template tag scanning -------------------------------------------------

const VOID_TAGS = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);

// Yields { raw, start, end } for each <tag> in template text, tolerating
// '>' inside quoted attribute values and { ... } expression groups.
function* scanTags(text) {
  let i = 0;
  while (i < text.length) {
    const lt = text.indexOf('<', i);
    if (lt === -1) break;
    const next = text[lt + 1];
    if (!next || !/[a-zA-Z/!]/.test(next)) {
      i = lt + 1;
      continue;
    }
    let j = lt + 1;
    let depth = 0;
    let quote = null;
    for (; j < text.length; j++) {
      const ch = text[j];
      if (quote) {
        if (ch === quote) quote = null;
      } else if (ch === '"' || ch === "'") {
        quote = ch;
      } else if (ch === '{') {
        depth += 1;
      } else if (ch === '}') {
        depth -= 1;
      } else if (ch === '>' && depth === 0) {
        break;
      }
    }
    yield { raw: text.slice(lt, j + 1), start: lt, end: j + 1 };
    i = j + 1;
  }
}

function parseTag(raw) {
  const closing = /^<\//.test(raw);
  const selfClosing = /\/>$/.test(raw.trimEnd());
  const nameMatch = /^<\/?([a-zA-Z][a-zA-Z0-9-]*)/.exec(raw);
  const name = nameMatch ? nameMatch[1] : '';
  const attrs = {
    onkeydown: /onkeydown=\{\s*([A-Za-z_$][\w$]*)\s*\}/.exec(raw)?.[1] ?? null,
    bindThis: /bind:this=\{\s*([A-Za-z_$][\w$]*)\s*\}/.exec(raw)?.[1] ?? null,
    type: /type="([^"]*)"/.exec(raw)?.[1] ?? null,
    role: /role="([^"]*)"/.exec(raw)?.[1] ?? null,
    classes: [...raw.matchAll(/class="([^"]*)"/g)].flatMap(m => m[1].split(/\s+/)),
  };
  return { name, attrs, closing, selfClosing, void: VOID_TAGS.has(name) };
}

function lineOf(text, index) {
  return text.slice(0, index).split('\n').length;
}

// Value of an attribute like `onfocus={() => completionOpen = true}` inside a
// raw tag string, brace-balanced (returns null when the attribute is absent).
function attrValue(raw, name) {
  const idx = raw.indexOf(`${name}={`);
  if (idx === -1) return null;
  let i = idx + name.length + 2;
  let depth = 0;
  const start = i;
  for (; i < raw.length; i++) {
    const ch = raw[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) break;
    }
  }
  return raw.slice(start, i);
}

// Named function referenced by a button's onclick: supports both the inline
// arrow form (`() => restoreSnapshot(snapshot)`) and a plain reference.
function onclickCallee(raw) {
  const arrow = /onclick=\{\s*\(\)\s*=>\s*([A-Za-z_$][\w$]*)\s*\(/.exec(raw);
  if (arrow) return arrow[1];
  const named = /onclick=\{\s*([A-Za-z_$][\w$]*)\s*\}/.exec(raw);
  return named ? named[1] : null;
}

// --- analysis ---------------------------------------------------------------

function analyze(template, script, bodies) {
  const problems = [];
  const surfaces = [];
  const stack = [];
  const dialogs = [];
  const comboboxes = new Set();
  const banners = new Set();
  const globalHandler = /<svelte:window\b[^>]*onkeydown=\{\s*([A-Za-z_$][\w$]*)\s*\}/.exec(template)?.[1] ?? null;

  const isSurface = elem =>
    elem.name === 'dialog' || elem.name === 'footer' ||
    elem.attrs.classes.includes('combobox-wrap') || elem.attrs.classes.includes('recovery-banner');

  const surfaceKind = elem => {
    if (elem.name === 'dialog') return 'dialog';
    if (elem.name === 'footer') return 'footer';
    if (elem.attrs.classes.includes('combobox-wrap')) return 'combobox';
    if (elem.attrs.classes.includes('recovery-banner')) return 'banner';
    return null;
  };

  for (const tag of scanTags(template)) {
    const elem = parseTag(tag.raw);
    if (elem.closing) {
      // Pop up to the matching element (defensive; markup is well-formed).
      for (let s = stack.length - 1; s >= 0; s--) {
        const popped = stack.splice(s, 1)[0];
        if (popped.name === elem.name) break;
      }
      continue;
    }
    if (elem.name === 'kbd') {
      // The token is the text up to the matching close tag.
      const close = template.indexOf('</kbd>', tag.end);
      const token = close === -1 ? '' : template.slice(tag.end, close).trim();
      let surface = null;
      let button = null;
      let form = false;
      for (let s = stack.length - 1; s >= 0; s--) {
        const e = stack[s];
        if (surface === null && isSurface(e)) surface = e;
        if (button === null && e.name === 'button') button = e;
        if (e.name === 'form') form = true;
        if (surface !== null && button !== null) break;
      }
      if (surface) {
        const kind = surfaceKind(surface);
        if (kind === 'combobox') comboboxes.add(surface);
        if (kind === 'banner') banners.add(surface);
        // A dialog showing an Alt+<key> hint is the resolution dialog; note
        // its resolve actions (the buttons carrying those hints) for the
        // stale-pending check.
        if (kind === 'dialog' && /^Alt\+/.test(token)) {
          surface._isResolution = true;
          if (button) (surface._resolutionCallees ??= []).push(onclickCallee(button._raw ?? ''));
        }
      }
      surfaces.push({
        kind: surface ? surfaceKind(surface) : null,
        elem: surface,
        token,
        line: lineOf(template, tag.start),
        button,
        form,
      });
      // Push the <kbd> so its matching </kbd> pops it without disturbing
      // enclosing elements (otherwise the first close tag empties the stack).
      stack.push(elem);
      continue;
    }
    if (!elem.selfClosing && !elem.void) {
      elem._line = lineOf(template, tag.start);
      elem._raw = tag.raw;
      stack.push(elem);
      if (elem.name === 'dialog') dialogs.push(elem);
    }
    // The palette dialog is the one containing a role=combobox input; its
    // options are the role=option list items inside it.
    if (elem.name === 'input' && elem.attrs.role === 'combobox') {
      for (let s = stack.length - 1; s >= 0; s--) {
        const e = stack[s];
        if (e.name === 'dialog' && !e._paletteInput) {
          e._paletteInput = tag.raw;
          break;
        }
      }
    }
    if (elem.attrs.role === 'option') {
      for (let s = stack.length - 1; s >= 0; s--) {
        const e = stack[s];
        if (e.name === 'dialog') {
          (e._options ??= []).push({ raw: tag.raw, line: lineOf(template, tag.start) });
          break;
        }
      }
    }
    // Surface wiring discovered from descendants.
    if (elem.attrs.onkeydown && elem.name !== 'svelte:window') {
      if (!bodies.has(elem.attrs.onkeydown)) {
        problems.push(`onkeydown references missing handler function "${elem.attrs.onkeydown}" (line ${lineOf(template, tag.start)})`);
      }
      for (let s = stack.length - 1; s >= 0; s--) {
        const e = stack[s];
        if (e.attrs.classes.includes('combobox-wrap') && !e._handler) {
          e._handler = elem.attrs.onkeydown;
          e._inputRaw = tag.raw;
          break;
        }
      }
    }
    if (elem.name === 'button') {
      const info = {
        callee: onclickCallee(tag.raw),
        text: template.slice(tag.end, template.indexOf('</button>', tag.end)).trim(),
      };
      for (let s = stack.length - 1; s >= 0; s--) {
        const e = stack[s];
        if (e.attrs.classes.includes('recovery-banner')) {
          e._hasButton = true;
          (e._buttons ??= []).push(info);
          break;
        }
      }
      for (let s = stack.length - 1; s >= 0; s--) {
        const e = stack[s];
        if (e.name === 'dialog') {
          (e._dialogButtons ??= []).push(info);
          break;
        }
      }
    }
  }

  // The combobox Esc-close hint must be reversible: the filter input has to
  // reopen the list on focus and on input, or Esc becomes a one-way trap.
  for (const box of comboboxes) {
    const raw = box._inputRaw ?? '';
    for (const attr of ['onfocus', 'oninput']) {
      const value = attrValue(raw, attr);
      if (value === null || !value.includes('= true')) {
        problems.push(`completion combobox at line ${box._line ?? '?'} is missing ${attr} wiring that reopens the suggestion list after Esc closes it`);
      }
    }
  }

  // The command palette's state machine: the filter's aria-expanded must
  // track the current option list (otherwise the combobox role lies about
  // whether the list is open), and Enter on any option must be inert when the
  // option is disabled.
  for (const dialog of dialogs) {
    if (!dialog._paletteInput) continue; // not the palette
    const expanded = attrValue(dialog._paletteInput, 'aria-expanded');
    if (expanded === null || !expanded.includes('paletteItems')) {
      problems.push(`command palette filter (line ${dialog._line ?? '?'}) aria-expanded does not track paletteItems${expanded === null ? ' (attribute missing)' : ` (got: ${expanded})`}`);
    }
    const handler = dialog.attrs.onkeydown;
    if (handler) {
      const body = bodies.get(handler) ?? '';
      const missing = ['paletteItemEnabled', 'executePaletteItem'].filter(token => !body.includes(token));
      if (missing.length > 0) {
        problems.push(`command palette ${handler} does not guard Enter on the enabled state (missing ${missing.join(', ')})`);
      }
    }
    const options = dialog._options ?? [];
    if (options.length === 0) {
      problems.push(`command palette at line ${dialog._line ?? '?'} has no role=option elements to lint for the Enter guard`);
      continue;
    }
    for (const option of options) {
      const value = attrValue(option.raw, 'onkeydown');
      if (value === null) {
        problems.push(`command palette option at line ${option.line} has no onkeydown Enter handler`);
        continue;
      }
      const missing = ['paletteItemEnabled', 'executePaletteItem'].filter(token => !value.includes(token));
      if (missing.length > 0) {
        problems.push(`command palette option at line ${option.line} Enter handler does not guard execution on the enabled state (missing ${missing.join(', ')})`);
      }
    }
  }

  // The resolution dialog's pending action must be cleared on every close
  // (Esc, Cancel, programmatic): an onclose handler assigns pendingResolution
  // to null, and each resolve function nulls it before proceeding, so a stale
  // Save & switch/run/rebuild/restore can never fire after the dialog closes.
  for (const dialog of dialogs) {
    if (!dialog._isResolution) continue;
    const closeValue = attrValue(dialog._raw ?? '', 'onclose');
    if (closeValue === null || !closeValue.includes('pendingResolution') || !closeValue.includes('= null')) {
      problems.push(`resolution dialog at line ${dialog._line ?? '?'} does not clear pendingResolution on close: add an onclose handler assigning it to null so Esc cannot leave a stale action`);
    }
    for (const callee of new Set((dialog._resolutionCallees ?? []).filter(Boolean))) {
      const body = bodies.get(callee) ?? '';
      if (!body.includes('pendingResolution = null')) {
        problems.push(`resolution dialog ${callee} does not clear pendingResolution before proceeding, so a stale Save & action could fire after the dialog closes`);
      }
    }
  }

  // The conflict dialog's state must be cleared on every close (Keep
  // editing, Esc, and programmatic closes all fire onclose), and the Load
  // disk version handler must clear conflict before closing so stale
  // external-change state can never survive the dialog.
  for (const dialog of dialogs) {
    const buttons = dialog._dialogButtons ?? [];
    if (!buttons.some(button => button.text === 'Load disk version')) continue; // not the conflict dialog
    const closeValue = attrValue(dialog._raw ?? '', 'onclose');
    if (closeValue === null || !closeValue.includes('conflict') || !(closeValue.includes('= null') || closeValue.includes('= false'))) {
      problems.push(`conflict dialog at line ${dialog._line ?? '?'} does not clear the conflict state on close: add an onclose handler assigning conflict (and deletedConflict) to null/false so Keep editing and Esc cannot leave stale state`);
    }
    const load = buttons.find(button => button.text === 'Load disk version');
    if (!load.callee) {
      problems.push(`conflict dialog Load disk version button at line ${dialog._line ?? '?'} does not call a named handler`);
      continue;
    }
    const body = bodies.get(load.callee) ?? '';
    const nullAt = body.indexOf('conflict = null');
    const closeAt = body.indexOf('.close()');
    if (nullAt === -1 || closeAt === -1 || nullAt > closeAt) {
      problems.push(`conflict dialog Load disk version handler (${load.callee}) must clear conflict (conflict = null) before closing the dialog`);
    }
  }

  // The recovery banner's Restore button must route a dirty buffer through
  // the Save/Discard resolution dialog; otherwise the Tab + Enter hint drifts
  // from what Restore actually does while editing.
  for (const banner of banners) {
    const restore = (banner._buttons ?? []).find(button => button.text.startsWith('Restore'));
    if (!restore) {
      problems.push(`recovery banner at line ${banner._line ?? '?'} has no Restore button to route dirty buffers through the resolution dialog`);
      continue;
    }
    if (!restore.callee) {
      problems.push(`recovery banner Restore button at line ${banner._line ?? '?'} does not call a named handler`);
      continue;
    }
    const body = bodies.get(restore.callee) ?? '';
    const missing = ['dirty', 'requestResolution', "'restore'"].filter(token => !body.includes(token));
    if (missing.length > 0) {
      problems.push(`recovery banner Restore button (${restore.callee}, line ${banner._line ?? '?'}) does not route dirty buffers through the resolution dialog (missing ${missing.join(', ')})`);
    }
  }

  // Validate each hinted key.
  for (const hit of surfaces) {
    const token = hit.token;
    if (!token) {
      problems.push(`empty <kbd> hint (line ${hit.line})`);
      continue;
    }
    const tokens = keyCodeTokens(token);
    if (hit.kind === 'dialog') {
      const dialog = hit.elem;
      const handler = dialog.attrs.onkeydown;
      if (!handler) {
        problems.push(`dialog at line ${hit.line} shows a key hint (<kbd>${token}</kbd>) but has no onkeydown handler`);
        continue;
      }
      if (token === 'Esc') continue; // native dialog cancel
      if (token === 'Enter') {
        const submit = hit.button?.attrs.type === 'submit' && hit.form;
        const focused = script.includes(`${dialog.attrs.bindThis}.querySelector`);
        const inHandler = bodies.get(handler)?.includes('Enter');
        if (submit || focused || inHandler) continue;
        problems.push(`Enter hint (<kbd>Enter</kbd>, line ${hit.line}) in dialog "${dialog.attrs.bindThis}" is not backed: the button is not a form submit, the dialog is not programmatically focused, and ${handler} does not handle Enter`);
        continue;
      }
      if (!tokens) {
        problems.push(`key hint <kbd>${token}</kbd> (line ${hit.line}) in dialog "${dialog.attrs.bindThis}" is not a recognized key`);
        continue;
      }
      const body = bodies.get(handler) ?? '';
      const missing = tokens.filter(t => !body.includes(t));
      if (missing.length > 0) {
        problems.push(`key hint <kbd>${token}</kbd> (line ${hit.line}) in dialog "${dialog.attrs.bindThis}" is not handled by ${handler} (missing ${missing.map(t => `'${t}'`).join(', ')})`);
      }
    } else if (hit.kind === 'combobox') {
      const handler = hit.elem._handler ?? null;
      if (!handler) {
        problems.push(`combobox at line ${hit.line} shows a key hint (<kbd>${token}</kbd>) but its filter input has no onkeydown handler`);
        continue;
      }
      if (!tokens) {
        problems.push(`key hint <kbd>${token}</kbd> (line ${hit.line}) in the completion combobox is not a recognized key`);
        continue;
      }
      const body = bodies.get(handler) ?? '';
      const missing = tokens.filter(t => !body.includes(t));
      if (missing.length > 0) {
        problems.push(`key hint <kbd>${token}</kbd> (line ${hit.line}) in the completion combobox is not handled by ${handler} (missing ${missing.map(t => `'${t}'`).join(', ')})`);
      }
    } else if (hit.kind === 'banner') {
      if (hit.elem._hasButton && (token === 'Tab' || token === 'Enter')) continue; // native focus + activation
      problems.push(`key hint <kbd>${token}</kbd> (line ${hit.line}) in the recovery banner is not backed: only Tab/Enter on the banner's buttons are native`);
    } else if (hit.kind === 'footer') {
      if (!globalHandler) {
        problems.push(`footer key hint <kbd>${token}</kbd> (line ${hit.line}) but no svelte:window keydown handler exists`);
        continue;
      }
      if (!tokens) {
        problems.push(`footer key hint <kbd>${token}</kbd> (line ${hit.line}) is not a recognized key`);
        continue;
      }
      const body = bodies.get(globalHandler) ?? '';
      const missing = tokens.filter(t => !body.includes(t));
      if (missing.length > 0) {
        problems.push(`footer key hint <kbd>${token}</kbd> (line ${hit.line}) is not handled by the window-level ${globalHandler} (missing ${missing.map(t => `'${t}'`).join(', ')})`);
      }
    } else {
      problems.push(`key hint <kbd>${token}</kbd> (line ${hit.line}) is not inside a dialog, combobox, recovery banner, or footer with keyboard handling`);
    }
  }
  if (globalHandler && !bodies.has(globalHandler)) {
    problems.push(`svelte:window onkeydown references missing handler function "${globalHandler}"`);
  }
  return problems;
}

function checkSource(source) {
  const script = scriptBlock(source);
  const endScript = source.indexOf('</script>');
  const template = endScript === -1 ? '' : source.slice(endScript + '</script>'.length);
  return analyze(template, script, handlerBodies(script));
}

// --- self-tests -------------------------------------------------------------

const FIXTURES = [
  {
    name: 'dialog with Esc (native) and Enter (form submit) hints passes',
    expect: 0,
    source: `<script lang="ts">
  function trap(event: KeyboardEvent) { if (event.key !== 'Tab') return; }
</script>
<dialog bind:this={d} onkeydown={trap}>
  <form onsubmit={(event) => { event.preventDefault(); }}>
    <button type="submit">Create<kbd>Enter</kbd></button>
  </form>
  <button type="button" onclick={() => d.close()}>Cancel<kbd>Esc</kbd></button>
</dialog>`,
  },
  {
    name: 'dialog hint for an unhandled Alt key fails',
    expect: 1,
    source: `<script lang="ts">
  function trap(event: KeyboardEvent) { if (event.key !== 'Tab') return; }
</script>
<dialog bind:this={d} onkeydown={trap}>
  <button type="button" onclick={() => d.close()}>Save<kbd>Alt+X</kbd></button>
</dialog>`,
  },
  {
    name: 'key hint outside any handled surface fails',
    expect: 1,
    source: `<script lang="ts"></script>
<p class="key-hint"><kbd>Esc</kbd> closes nothing</p>`,
  },
  {
    name: 'dialog with key hints but no onkeydown handler fails',
    expect: 1,
    source: `<script lang="ts"></script>
<dialog bind:this={d}>
  <button type="button">Save<kbd>Enter</kbd></button>
</dialog>`,
  },
  {
    name: 'combobox hint not handled by its filter keydown fails',
    expect: 1,
    source: `<script lang="ts">
  function keys(event: KeyboardEvent) { if (event.key === 'ArrowDown') return; }
</script>
<div class="combobox-wrap">
  <input onkeydown={keys} />
  <p class="key-hint"><kbd>Esc</kbd> close</p>
</div>`,
  },
  {
    name: 'combobox with onfocus/oninput reopen wiring passes',
    expect: 0,
    source: `<script lang="ts">
  function keys(event: KeyboardEvent) {
    if (event.key === 'ArrowUp' || event.key === 'ArrowDown' || event.key === 'Enter' || event.key === 'Escape') return;
  }
</script>
<div class="combobox-wrap">
  <input onfocus={() => completionOpen = true} oninput={() => completionOpen = true} onkeydown={keys} />
  <p class="key-hint"><kbd>↑</kbd><kbd>↓</kbd> navigate · <kbd>Enter</kbd> insert · <kbd>Esc</kbd> close</p>
</div>`,
  },
  {
    name: 'combobox missing the onfocus/oninput reopen wiring fails',
    expect: 1,
    source: `<script lang="ts">
  function keys(event: KeyboardEvent) {
    if (event.key === 'ArrowUp' || event.key === 'ArrowDown' || event.key === 'Enter' || event.key === 'Escape') return;
  }
</script>
<div class="combobox-wrap">
  <input onkeydown={keys} />
  <p class="key-hint"><kbd>↑</kbd><kbd>↓</kbd> navigate · <kbd>Enter</kbd> insert · <kbd>Esc</kbd> close</p>
</div>`,
  },
  {
    name: 'banner Tab/Enter hints with a dirty-routing Restore pass',
    expect: 0,
    source: `<script lang="ts">
  async function restoreSnapshot(snapshot: { path: string }) {
    if (dirty) { await requestResolution({ action: 'restore', snapshot }); return; }
    await openFile(snapshot.path);
  }
</script>
<aside class="recovery-banner">
  <p class="key-hint"><kbd>Tab</kbd> to an action · <kbd>Enter</kbd> runs it</p>
  <button type="button" onclick={() => restoreSnapshot(snapshot)}>Restore content/index.md</button>
  <button type="button" onclick={() => clearRecovery(path)}>Discard recovery for content/index.md</button>
</aside>`,
  },
  {
    name: 'banner Restore without the dirty-buffer routing fails',
    expect: 1,
    source: `<script lang="ts">
  async function restoreSnapshot(snapshot: { path: string }) {
    await openFile(snapshot.path);
  }
</script>
<aside class="recovery-banner">
  <p class="key-hint"><kbd>Tab</kbd> to an action · <kbd>Enter</kbd> runs it</p>
  <button type="button" onclick={() => restoreSnapshot(snapshot)}>Restore content/index.md</button>
</aside>`,
  },
  {
    name: 'banner with no Restore button fails',
    expect: 1,
    source: `<script lang="ts">
  async function clearRecovery(path: string) {}
</script>
<aside class="recovery-banner">
  <p class="key-hint"><kbd>Tab</kbd> to an action · <kbd>Enter</kbd> runs it</p>
  <button type="button" onclick={() => clearRecovery(path)}>Discard recovery for content/index.md</button>
</aside>`,
  },
  {
    name: 'banner hint for a non-native key fails',
    expect: 1,
    source: `<script lang="ts">
  async function restoreSnapshot(snapshot: { path: string }) {
    if (dirty) { await requestResolution({ action: 'restore', snapshot }); return; }
  }
</script>
<aside class="recovery-banner">
  <p class="key-hint"><kbd>Alt+R</kbd> restores</p>
  <button type="button" onclick={() => restoreSnapshot(snapshot)}>Restore content/index.md</button>
</aside>`,
  },
  {
    name: 'footer Ctrl+K covered by the svelte:window handler passes',
    expect: 0,
    source: `<script lang="ts">
  function shortcut(event: KeyboardEvent) {
    const command = event.metaKey || event.ctrlKey;
    if (event.key.toLowerCase() === 'k') return;
  }
</script>
<svelte:window onkeydown={shortcut} />
<footer><p class="key-hint"><kbd>Ctrl</kbd>+<kbd>K</kbd> opens commands</p></footer>`,
  },
  {
    name: 'dialog Enter backed by programmatic focus passes',
    expect: 0,
    source: `<script lang="ts">
  function trap(event: KeyboardEvent) { if (event.key !== 'Tab') return; }
  function open() { d.querySelector('button')?.focus(); }
</script>
<dialog bind:this={d} onkeydown={trap}>
  <button type="button" class="danger">Delete<kbd>Enter</kbd></button>
</dialog>`,
  },
  {
    name: 'onkeydown referencing a missing handler fails',
    expect: 1,
    source: `<script lang="ts"></script>
<dialog bind:this={d} onkeydown={missingHandler}>
  <button type="button">Save<kbd>Esc</kbd></button>
</dialog>`,
  },
  {
    name: 'palette with tracking aria-expanded and guarded options passes',
    expect: 0,
    source: `<script lang="ts">
  function paletteKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      const item = paletteItems[paletteSelection];
      if (item && paletteItemEnabled(item)) executePaletteItem(item);
    }
  }
</script>
<dialog bind:this={paletteDialog} onkeydown={paletteKeydown}>
  <input role="combobox" aria-expanded={paletteItems.length > 0} aria-controls="palette-options" onkeydown={paletteKeydown} />
  <ul id="palette-options" role="listbox">
    <li role="option" onkeydown={(event) => { if (event.key === 'Enter') { event.preventDefault(); if (paletteItemEnabled(item)) executePaletteItem(item); } }}>Open file</li>
  </ul>
</dialog>`,
  },
  {
    name: 'palette aria-expanded not tracking paletteItems fails',
    expect: 1,
    source: `<script lang="ts">
  function paletteKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      const item = paletteItems[paletteSelection];
      if (item && paletteItemEnabled(item)) executePaletteItem(item);
    }
  }
</script>
<dialog bind:this={paletteDialog} onkeydown={paletteKeydown}>
  <input role="combobox" aria-expanded="true" aria-controls="palette-options" onkeydown={paletteKeydown} />
  <ul id="palette-options" role="listbox">
    <li role="option" onkeydown={(event) => { if (event.key === 'Enter') { event.preventDefault(); if (paletteItemEnabled(item)) executePaletteItem(item); } }}>Open file</li>
  </ul>
</dialog>`,
  },
  {
    name: 'palette option Enter without the enabled guard fails',
    expect: 1,
    source: `<script lang="ts">
  function paletteKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      const item = paletteItems[paletteSelection];
      if (item && paletteItemEnabled(item)) executePaletteItem(item);
    }
  }
</script>
<dialog bind:this={paletteDialog} onkeydown={paletteKeydown}>
  <input role="combobox" aria-expanded={paletteItems.length > 0} aria-controls="palette-options" onkeydown={paletteKeydown} />
  <ul id="palette-options" role="listbox">
    <li role="option" onkeydown={(event) => { if (event.key === 'Enter') { event.preventDefault(); executePaletteItem(item); } }}>Open file</li>
  </ul>
</dialog>`,
  },
  {
    name: 'palette handler Enter without the enabled guard fails',
    expect: 1,
    source: `<script lang="ts">
  function paletteKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter') { event.preventDefault(); executePaletteItem(paletteItems[paletteSelection]); }
  }
</script>
<dialog bind:this={paletteDialog} onkeydown={paletteKeydown}>
  <input role="combobox" aria-expanded={paletteItems.length > 0} aria-controls="palette-options" onkeydown={paletteKeydown} />
  <ul id="palette-options" role="listbox">
    <li role="option" onkeydown={(event) => { if (event.key === 'Enter') { event.preventDefault(); if (paletteItemEnabled(item)) executePaletteItem(item); } }}>Open file</li>
  </ul>
</dialog>`,
  },
  {
    name: 'resolution dialog clearing pendingResolution on close passes',
    expect: 0,
    source: `<script lang="ts">
  function h(event: KeyboardEvent) {
    if (event.altKey && event.key.toLowerCase() === 's') resolvePendingSave();
  }
  async function resolvePendingSave() {
    const pending = pendingResolution;
    if (!pending) return;
    pendingResolution = null;
    resolutionDialog.close();
    await saveFile();
  }
</script>
<dialog bind:this={resolutionDialog} onkeydown={h} onclose={() => { pendingResolution = null; }}>
  <button type="button" onclick={() => resolutionDialog.close()}>Cancel</button>
  <button type="button" onclick={resolvePendingSave}>Save &amp; switch<kbd>Alt+S</kbd></button>
</dialog>`,
  },
  {
    name: 'resolution dialog without an onclose pending clear fails',
    expect: 1,
    source: `<script lang="ts">
  function h(event: KeyboardEvent) {
    if (event.altKey && event.key.toLowerCase() === 's') resolvePendingSave();
  }
  async function resolvePendingSave() {
    const pending = pendingResolution;
    if (!pending) return;
    pendingResolution = null;
    resolutionDialog.close();
    await saveFile();
  }
</script>
<dialog bind:this={resolutionDialog} onkeydown={h}>
  <button type="button" onclick={() => resolutionDialog.close()}>Cancel</button>
  <button type="button" onclick={resolvePendingSave}>Save &amp; switch<kbd>Alt+S</kbd></button>
</dialog>`,
  },
  {
    name: 'resolution dialog resolve function not clearing the pending state fails',
    expect: 1,
    source: `<script lang="ts">
  function h(event: KeyboardEvent) {
    if (event.altKey && event.key.toLowerCase() === 's') resolvePendingSave();
  }
  async function resolvePendingSave() {
    await saveFile();
  }
</script>
<dialog bind:this={resolutionDialog} onkeydown={h} onclose={() => { pendingResolution = null; }}>
  <button type="button" onclick={() => resolutionDialog.close()}>Cancel</button>
  <button type="button" onclick={resolvePendingSave}>Save &amp; switch<kbd>Alt+S</kbd></button>
</dialog>`,
  },
  {
    name: 'conflict dialog clearing state on close and in Load disk version passes',
    expect: 0,
    source: `<script lang="ts">
  function h(event: KeyboardEvent) { if (event.key === 'Tab' || event.key === 'Enter') return; }
  async function loadDiskVersion() {
    if (!conflict) return;
    loadBuffer(conflict, 'Loaded the disk version.');
    conflict = null;
    conflictDialog.close();
  }
</script>
<dialog bind:this={conflictDialog} onkeydown={h} onclose={() => { conflict = null; deletedConflict = false; }}>
  <button type="button" onclick={() => conflictDialog.close()}>Keep editing<kbd>Esc</kbd></button>
  <button type="button" onclick={loadDiskVersion}>Load disk version</button>
  <button type="button" class="primary" onclick={() => saveFile(false, conflict!.fingerprint)}>Replace disk version<kbd>Enter</kbd></button>
</dialog>`,
  },
  {
    name: 'conflict dialog without an onclose state clear fails',
    expect: 1,
    source: `<script lang="ts">
  function h(event: KeyboardEvent) { if (event.key === 'Tab' || event.key === 'Enter') return; }
  async function loadDiskVersion() {
    if (!conflict) return;
    loadBuffer(conflict, 'Loaded the disk version.');
    conflict = null;
    conflictDialog.close();
  }
</script>
<dialog bind:this={conflictDialog} onkeydown={h}>
  <button type="button" onclick={() => conflictDialog.close()}>Keep editing<kbd>Esc</kbd></button>
  <button type="button" onclick={loadDiskVersion}>Load disk version</button>
  <button type="button" class="primary" onclick={() => saveFile(false, conflict!.fingerprint)}>Replace disk version<kbd>Enter</kbd></button>
</dialog>`,
  },
  {
    name: 'conflict dialog Load disk version clearing after close fails',
    expect: 1,
    source: `<script lang="ts">
  function h(event: KeyboardEvent) { if (event.key === 'Tab' || event.key === 'Enter') return; }
  async function loadDiskVersion() {
    if (!conflict) return;
    loadBuffer(conflict, 'Loaded the disk version.');
    conflictDialog.close();
    conflict = null;
  }
</script>
<dialog bind:this={conflictDialog} onkeydown={h} onclose={() => { conflict = null; deletedConflict = false; }}>
  <button type="button" onclick={() => conflictDialog.close()}>Keep editing<kbd>Esc</kbd></button>
  <button type="button" onclick={loadDiskVersion}>Load disk version</button>
  <button type="button" class="primary" onclick={() => saveFile(false, conflict!.fingerprint)}>Replace disk version<kbd>Enter</kbd></button>
</dialog>`,
  },
];

function runSelfTests() {
  let failed = 0;
  for (const fixture of FIXTURES) {
    const problems = checkSource(fixture.source);
    const count = problems.length;
    const ok = fixture.expect === 0 ? count === 0 : count > 0;
    if (!ok) {
      failed += 1;
      console.error(`SELF-TEST FAIL: ${fixture.name}\n  expected ${fixture.expect === 0 ? 'no problems' : 'a problem'}, got ${count}`);
      for (const p of problems.slice(0, 3)) console.error(`    - ${p}`);
    }
  }
  return failed;
}

// --- main -------------------------------------------------------------------

let failures = 0;
failures += runSelfTests();

const source = readFileSync(SOURCE, 'utf8');
const problems = checkSource(source);
for (const p of problems) console.error(`  - ${p}`);
if (problems.length > 0) {
  console.error(`\nkey-hints conformance: ${problems.length} problem(s) in ${SOURCE}`);
  process.exitCode = 1;
} else {
  const hints = (source.match(/<kbd>/g) ?? []).length;
  console.log(`key-hints conformance: OK (${hints} visible key hints backed by handlers)`);
}

if (failures > 0) process.exitCode = 1;
