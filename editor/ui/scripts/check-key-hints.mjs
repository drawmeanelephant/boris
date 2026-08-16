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
//     and activation) and must contain buttons.
//   - the footer's hints must be covered by the svelte:window keydown
//     handler.
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

// Extracts balanced { } bodies for every `function NAME(` in the script.
function handlerBodies(script) {
  const bodies = new Map();
  const re = /function\s+([A-Za-z_$][\w$]*)\s*\(/g;
  let match;
  while ((match = re.exec(script))) {
    const open = script.indexOf('{', match.index + match[0].length);
    if (open === -1) continue;
    let depth = 0;
    let quote = null;
    let end = open;
    for (; end < script.length; end++) {
      const ch = script[end];
      if (quote) {
        if (ch === quote && script[end - 1] !== '\\') quote = null;
      } else if (ch === '"' || ch === "'" || ch === '`') {
        quote = ch;
      } else if (ch === '{') {
        depth += 1;
      } else if (ch === '}') {
        depth -= 1;
        if (depth === 0) break;
      }
    }
    bodies.set(match[1], script.slice(open, end + 1));
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
    classes: [...raw.matchAll(/class="([^"]*)"/g)].flatMap(m => m[1].split(/\s+/)),
  };
  return { name, attrs, closing, selfClosing, void: VOID_TAGS.has(name) };
}

function lineOf(text, index) {
  return text.slice(0, index).split('\n').length;
}

// --- analysis ---------------------------------------------------------------

function analyze(template, script, bodies) {
  const problems = [];
  const surfaces = [];
  const stack = [];
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
    if (!elem.selfClosing && !elem.void) stack.push(elem);
    // Surface wiring discovered from descendants.
    if (elem.attrs.onkeydown && elem.name !== 'svelte:window') {
      if (!bodies.has(elem.attrs.onkeydown)) {
        problems.push(`onkeydown references missing handler function "${elem.attrs.onkeydown}" (line ${lineOf(template, tag.start)})`);
      }
      for (let s = stack.length - 1; s >= 0; s--) {
        const e = stack[s];
        if (e.attrs.classes.includes('combobox-wrap') && !e._handler) {
          e._handler = elem.attrs.onkeydown;
          break;
        }
      }
    }
    if (elem.name === 'button') {
      for (let s = stack.length - 1; s >= 0; s--) {
        const e = stack[s];
        if (e.attrs.classes.includes('recovery-banner')) {
          e._hasButton = true;
          break;
        }
      }
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
    name: 'banner Tab/Enter hints with buttons pass',
    expect: 0,
    source: `<script lang="ts"></script>
<aside class="recovery-banner">
  <p class="key-hint"><kbd>Tab</kbd> to an action · <kbd>Enter</kbd> runs it</p>
  <button type="button">Restore</button>
</aside>`,
  },
  {
    name: 'banner hint for a non-native key fails',
    expect: 1,
    source: `<script lang="ts"></script>
<aside class="recovery-banner">
  <p class="key-hint"><kbd>Alt+R</kbd> restores</p>
  <button type="button">Restore</button>
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
