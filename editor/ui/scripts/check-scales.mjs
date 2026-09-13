#!/usr/bin/env node
// Static conformance lint for the editor's declared scales.
//
// Each ordered scale in the editor — the type chain, the spacing rhythm, the
// corner steps, the stacking ladder — has its order written down in exactly one
// place: a `--scale-*` list in src/lib/tokens.css. Nothing else keeps a copy.
// The browser walk in `ui/tests/scales.spec.ts` resolves those lists out of the
// *applied* stylesheet; this script checks the same lists statically, before a
// browser is needed. That division is the point: a duplicated order is how the
// app title ended up rendering at exactly the pane-title size with every suite
// green, because the tests and the stylesheet each had their own idea of what
// the chain was.
//
// Per scale, against tokens.css:
//   1. the scale's list exists and is non-empty;
//   2. every declared token of the family is classified in exactly one of the
//      scale's lists, so nothing enters the surface unclassified;
//   3. every listed name is a declared token, so no entry survives a rename;
//   4. no name is listed twice, and none is in both lists;
//   5. the list ascends — numerically wherever a value is resolvable without a
//      viewport, and reported as deferred where it is not (a `clamp` in `vw`);
//   6. a scale with a stated base is a whole multiple of it;
//   7. an integer scale (the layer ladder) holds bare numbers, not lengths.
// Per scale, against editor/README.md:
//   8. the documented section names the scale's list, so the prose points at
//      the one source instead of restating the order;
//   9. it names no token of that family that tokens.css does not declare.
// Globally, against styles.css:
//  10. no `z-index` is a bare number — the ladder is the only authority on
//      stacking order — and every `--layer-*` name it uses is declared.
//
// Zero dependencies: plain Node, regex over the three files. Runs built-in
// self-tests first, then checks the real source.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOKENS_CSS = join(HERE, '..', 'src', 'lib', 'tokens.css');
const STYLES_CSS = join(HERE, '..', 'src', 'styles.css');
const README = join(HERE, '..', '..', 'README.md');

/** The declared scales. `prefix` is what a token of this scale looks like, and
 *  `readme` is the section that documents it. */
const define = (id, prefix, rest) => ({ id, prefix, family: new RegExp(`^${prefix}`), ...rest });

export const SCALES = [
  define('type', '--text-', {
    list: '--scale-type',
    offChain: '--scale-type-offchain',
    readme: 'Reading hierarchy',
    kind: 'length'
  }),
  define('space', '--space-', {
    list: '--scale-space',
    readme: 'Spacing, radius, and stacking',
    kind: 'length',
    // The base is a declared token, not a literal here: a second copy of it
    // would be exactly the drift this script exists to prevent.
    base: '--scale-space-base'
  }),
  define('radius', '--radius-', {
    list: '--scale-radius',
    readme: 'Spacing, radius, and stacking',
    kind: 'length'
  }),
  define('layer', '--layer-', {
    list: '--scale-layer',
    readme: 'Spacing, radius, and stacking',
    kind: 'integer'
  })
];

/** Comments carry prose that names tokens; strip them so prose can never be
 *  mistaken for a declaration. */
export function stripComments(cssText) {
  return cssText.replace(/\/\*[\s\S]*?\*\//g, '');
}

/** Declared custom properties of one family. The lookahead requires a `:`, so a
 *  name merely *referenced* inside a list value is not a declaration. */
export function declaredTokens(cssText, family) {
  const names = [...new Set(cssText.match(/--[a-z0-9-]+(?=\s*:)/g) ?? [])];
  return names.filter(name => family.test(name)).sort();
}

/** The declaration text of one token, or null when it is not declared. */
export function declaredValue(cssText, name) {
  const match = cssText.match(new RegExp(`${name}\\s*:\\s*([^;]*);`));
  return match ? match[1].trim() : null;
}

/** The whitespace-separated value of a list declaration, or null when absent. */
export function listedValues(cssText, name) {
  const value = declaredValue(cssText, name);
  return value === null ? null : value.split(/\s+/).filter(Boolean);
}

/** A value as a comparable number, or null when only a viewport can resolve it.
 *  `rem` assumes the 16px root: the editor sets no root font-size, and the
 *  browser walk asserts the effective values, so a future root change shows up
 *  there rather than silently skewing this comparison. */
export function scalarValue(value, kind = 'length') {
  const text = String(value).trim();
  if (kind === 'integer') return /^\d+$/.test(text) ? Number(text) : null;
  if (/^-?\d*\.?\d+px$/i.test(text)) return Number.parseFloat(text);
  if (/^-?\d*\.?\d+rem$/i.test(text)) return Number.parseFloat(text) * 16;
  return null;
}

/** Classification problems for one scale. */
export function classificationProblems(scale, { declared, chain, offChain }) {
  if (!chain) return [`tokens.css declares no ${scale.list}`];
  if (scale.offChain && !offChain) return [`tokens.css declares no ${scale.offChain}`];

  const problems = [];
  if (chain.length === 0) problems.push(`${scale.list} is empty`);
  for (const name of chain) {
    if (offChain.includes(name)) problems.push(`${name} is listed in both ${scale.list} and ${scale.offChain}`);
  }
  const lists = scale.offChain ? [[scale.list, chain], [scale.offChain, offChain]] : [[scale.list, chain]];
  for (const [label, names] of lists) {
    for (const name of names) {
      if (names.indexOf(name) !== names.lastIndexOf(name)) problems.push(`${name} is listed twice in ${label}`);
      if (!declared.includes(name)) problems.push(`${label} lists ${name}, which tokens.css does not declare`);
    }
  }
  for (const name of declared) {
    if (!chain.includes(name) && !offChain.includes(name)) {
      problems.push(`${name} is declared but classified by no ${scale.id} list — add it to ${scale.list}`);
    }
  }
  return problems;
}

/** Ordering, base-multiple, and kind problems for one scale. Returns the
 *  problems plus how many adjacent pairs a viewport had to resolve. */
export function scaleOrderProblems(scale, chain, values, base = null) {
  const problems = [];
  const deferred = [];
  let previous = null;

  for (const name of chain) {
    const value = values.get(name);
    if (value === null || value === undefined) {
      deferred.push(name);
      continue;
    }
    if (scale.kind === 'integer' && !/^\d+$/.test(String(value))) {
      problems.push(`${name} must be a bare number, not ${value}`);
    }
    if (previous && value <= previous.value) {
      problems.push(`${name} must outrank ${previous.name} in ${scale.list}`);
    }
    previous = { name, value };
  }

  if (scale.base && base !== null) {
    for (const name of chain) {
      const value = values.get(name);
      if (value === null || value === undefined) continue;
      if (!Number.isInteger(value / base.px)) {
        problems.push(`${name} is ${value}px, not a whole multiple of the ${base.token} base (${base.px}px)`);
      }
    }
  } else if (scale.base) {
    problems.push(`tokens.css declares no usable ${scale.base}`);
  }
  return { problems, deferred };
}

/** Whether `text` names `name` as a whole token rather than as the prefix of a
 *  longer one: `--scale-space-base` must not pass for `--scale-space`. */
export function mentions(text, name) {
  return new RegExp(`${name}(?![a-z0-9-])`).test(text);
}

/** README problems for one scale: the section must point at the scale's list and
 *  must not name tokens that do not exist. */
export function readmeProblems(scale, readmeText, declared) {
  const problems = [];
  const section = readmeText.split(/^## /m).find(text => text.startsWith(scale.readme));
  if (!section) {
    problems.push(`editor/README.md has no "${scale.readme}" section to check ${scale.id} against`);
    return problems;
  }
  if (!mentions(section, scale.list)) {
    problems.push(`editor/README.md's "${scale.readme}" section does not name ${scale.list}`);
  }
  // A token name is hyphen-separated segments, each non-empty: that keeps the
  // *prefix* of a glob like `--text-*` from reading as a token named `--text-`.
  for (const name of new Set(section.match(/--[a-z0-9]+(?:-[a-z0-9]+)*/g) ?? [])) {
    if (scale.family.test(name) && !declared.includes(name)) {
      problems.push(`editor/README.md names ${name}, which tokens.css does not declare`);
    }
  }
  return problems;
}

/** No bare-number `z-index`: the ladder is the only authority on stacking. */
export function stackingProblems(stylesCss) {
  const problems = [];
  for (const match of stripComments(stylesCss).matchAll(/z-index:\s*([^;}]+)/g)) {
    const value = match[1].trim();
    if (!/^var\(--layer-[a-z0-9-]+\)$/.test(value)) {
      problems.push(`styles.css sets z-index: ${value} — name a layer token instead`);
    }
  }
  return problems;
}

/** Where a scale token may be declared, and that every reference resolves. */
export function placementProblems(scales, tokensCss, stylesCss) {
  const problems = [];

  // Declared once: a repeated declaration is an override in disguise, because
  // the last one wins in the cascade and nothing else says so.
  for (const scale of scales) {
    // Deliberately unanchored: a re-declaration is just as real inside a
    // one-line or nested block, and the colon is what marks a declaration (a
    // list value or a `var()` reference is never followed by one).
    const found = (tokensCss.match(new RegExp(`${scale.prefix}[a-z0-9-]+\\s*:`, 'g')) ?? [])
      .map(match => match.replace(/\s*:$/, ''));
    for (const name of new Set(found)) {
      const count = found.filter(candidate => candidate === name).length;
      if (count > 1) problems.push(`${name} is declared ${count} times in tokens.css — a scale has one value per step`);
    }
  }

  // And declared only there: a scale token in styles.css would be a second
  // source of truth wearing a different file name.
  for (const match of stripComments(stylesCss).matchAll(/(--[a-z0-9-]+)\s*:/g)) {
    const name = match[1];
    const owner = scales.find(candidate => candidate.family.test(name));
    if (owner) problems.push(`styles.css declares ${name}; the ${owner.id} scale belongs in tokens.css`);
  }

  // Every reference must land on a declared step of the same scale — a typo in
  // a `var()` is otherwise an invalid property at runtime and nothing else.
  const known = new Map(scales.map(scale => [scale, declaredTokens(tokensCss, scale.family)]));
  for (const match of stripComments(stylesCss).matchAll(/var\(\s*(--[a-z0-9-]+)/g)) {
    const name = match[1];
    const owner = scales.find(candidate => candidate.family.test(name));
    if (owner && !known.get(owner).includes(name)) {
      problems.push(`styles.css uses var(${name}), which tokens.css does not declare`);
    }
  }
  return problems;
}

function runSelfTests() {
  const fixtures = [
    {
      name: 'a fully classified scale reports nothing',
      actual: classificationProblems(
        { id: 'x', list: '--scale-x', offChain: '--scale-x-offchain' },
        { declared: ['--x-a', '--x-b', '--x-c'], chain: ['--x-a', '--x-b'], offChain: ['--x-c'] }
      ),
      expected: []
    },
    {
      name: 'an unclassified token is reported',
      actual: classificationProblems(
        { id: 'x', list: '--scale-x' },
        { declared: ['--x-a', '--x-b'], chain: ['--x-a'], offChain: [] }
      ),
      expected: ['--x-b is declared but classified by no x list — add it to --scale-x']
    },
    {
      name: 'a stale entry is reported',
      actual: classificationProblems(
        { id: 'x', list: '--scale-x' },
        { declared: ['--x-a'], chain: ['--x-a', '--x-gone'], offChain: [] }
      ),
      expected: ['--scale-x lists --x-gone, which tokens.css does not declare']
    },
    {
      name: 'a missing list is reported rather than passing vacuously',
      actual: classificationProblems({ id: 'x', list: '--scale-x' }, { declared: [], chain: null, offChain: [] }),
      expected: ['tokens.css declares no --scale-x']
    },
    {
      name: 'an empty off-chain axis is legitimate',
      actual: classificationProblems(
        { id: 'x', list: '--scale-x', offChain: '--scale-x-offchain' },
        { declared: ['--x-a'], chain: ['--x-a'], offChain: [] }
      ),
      expected: []
    },
    {
      name: 'a collapsed step is reported',
      actual: scaleOrderProblems(
        { id: 'x', list: '--scale-x', kind: 'length' },
        ['--x-a', '--x-b'],
        new Map([['--x-a', 16], ['--x-b', 16]])
      ).problems,
      expected: ['--x-b must outrank --x-a in --scale-x']
    },
    {
      name: 'a viewport-dependent step is deferred, not failed',
      actual: scaleOrderProblems(
        { id: 'x', list: '--scale-x', kind: 'length' },
        ['--x-a', '--x-b', '--x-c'],
        new Map([['--x-a', 16], ['--x-b', null], ['--x-c', 32]])
      ),
      expected: { problems: [], deferred: ['--x-b'] }
    },
    {
      name: 'a step off the declared base is reported',
      actual: scaleOrderProblems(
        { id: 'x', list: '--scale-x', kind: 'length', base: '--scale-x-base' },
        ['--x-a', '--x-b'],
        new Map([['--x-a', 4], ['--x-b', 6]]),
        { token: '--scale-x-base', px: 4 }
      ).problems,
      expected: ['--x-b is 6px, not a whole multiple of the --scale-x-base base (4px)']
    },
    {
      name: 'a scale whose base went missing is reported, not skipped',
      actual: scaleOrderProblems(
        { id: 'x', list: '--scale-x', kind: 'length', base: '--scale-x-base' },
        ['--x-a'],
        new Map([['--x-a', 4]]),
        null
      ).problems,
      expected: ['tokens.css declares no usable --scale-x-base']
    },
    {
      name: 'a bare-number z-index is reported',
      actual: stackingProblems('.f { z-index: 5; }', []),
      expected: ['styles.css sets z-index: 5 — name a layer token instead']
    },
    {
      name: 'a layered z-index passes',
      actual: stackingProblems('.f { z-index: var(--layer-nav); }'),
      expected: []
    },
    {
      name: 'an undeclared reference is caught',
      actual: placementProblems(
        [define('layer', '--layer-', { id: 'layer' })],
        ':root { --layer-nav: 5; }',
        '.f { z-index: var(--layer-nav); } .g { z-index: var(--layer-nope); }'
      ),
      expected: ['styles.css uses var(--layer-nope), which tokens.css does not declare']
    },
    {
      name: 'a scale token re-declared in tokens.css is caught',
      actual: placementProblems(
        [define('layer', '--layer-', { id: 'layer' })],
        ':root { --layer-nav: 5; }\n:root { --layer-nav: 9; }',
        ''
      ),
      expected: ['--layer-nav is declared 2 times in tokens.css — a scale has one value per step']
    },
    {
      name: 'a scale token declared in styles.css is caught',
      actual: placementProblems(
        [define('layer', '--layer-', { id: 'layer' })],
        ':root { --layer-nav: 5; }',
        '.f { --layer-local: 3; }'
      ),
      expected: ['styles.css declares --layer-local; the layer scale belongs in tokens.css']
    },
    {
      name: 'comments are not declarations',
      actual: declaredTokens(stripComments(':root {\n /* --text-fake: 1rem; */\n --text-real: 1rem;\n}'), /^--text-/),
      expected: ['--text-real']
    },
    {
      name: 'units normalize for comparison',
      actual: [scalarValue('0.25rem'), scalarValue('999px'), scalarValue('clamp(1rem, 2vw, 2rem)'), scalarValue('5', 'integer')],
      expected: [4, 999, null, 5]
    },
    {
      name: 'a glob is not a token name',
      actual: ('## Reading hierarchy\n\nsee `--text-*` and --text-xl').match(/--[a-z0-9]+(?:-[a-z0-9]+)*/g),
      expected: ['--text', '--text-xl']
    },
    {
      name: 'a longer name does not satisfy the list pointer',
      actual: readmeProblems(
        { id: 'space', list: '--scale-space', family: /^--space-/, readme: 'Spacing', kind: 'length' },
        '## Spacing\n\nThe base is --scale-space-base.\n',
        []
      ),
      expected: ['editor/README.md\'s "Spacing" section does not name --scale-space']
    },
    {
      name: 'the list name satisfies its own pointer',
      actual: readmeProblems(
        { id: 'space', list: '--scale-space', family: /^--space-/, readme: 'Spacing', kind: 'length' },
        '## Spacing\n\nEight steps, declared as --scale-space.\n',
        []
      ),
      expected: []
    }
  ];

  const show = value => (value && !Array.isArray(value) && typeof value === 'object'
    ? JSON.stringify({ problems: value.problems, deferred: value.deferred })
    : JSON.stringify(value));

  let failures = 0;
  for (const fixture of fixtures) {
    if (show(fixture.actual) !== show(fixture.expected)) {
      console.error(`  - self-test "${fixture.name}" expected ${show(fixture.expected)}, got ${show(fixture.actual)}`);
      failures += 1;
    }
  }
  return failures;
}

// --- main -------------------------------------------------------------------

const selfTestFailures = runSelfTests();

const tokensCss = readFileSync(TOKENS_CSS, 'utf8');
const stylesCss = readFileSync(STYLES_CSS, 'utf8');
const readme = readFileSync(README, 'utf8');
const tokens = stripComments(tokensCss);

const problems = [];
const summary = [];

for (const scale of SCALES) {
  const declared = declaredTokens(tokens, scale.family);
  const chain = listedValues(tokens, scale.list);
  const offChain = scale.offChain ? listedValues(tokens, scale.offChain) : [];
  problems.push(...classificationProblems(scale, { declared, chain, offChain }));

  const values = new Map();
  for (const name of chain ?? []) {
    const raw = declaredValue(tokens, name);
    values.set(name, raw === null ? null : scalarValue(raw, scale.kind));
  }
  let base = null;
  if (scale.base) {
    const baseText = declaredValue(tokens, scale.base);
    const px = baseText === null ? null : scalarValue(baseText);
    base = px === null ? null : { token: scale.base, px };
  }
  const order = scaleOrderProblems(scale, chain ?? [], values, base);
  problems.push(...order.problems);
  problems.push(...readmeProblems(scale, readme, declared));

  summary.push(`${scale.id} ${(chain ?? []).length}${order.deferred.length > 0 ? ` (${order.deferred.length} deferred to the browser walk)` : ''}`);
}

problems.push(...stackingProblems(stylesCss));
problems.push(...placementProblems(SCALES, tokens, stripComments(stylesCss)));

for (const problem of problems) console.error(`  - ${problem}`);
if (problems.length > 0) {
  console.error(`\nscale conformance: ${problems.length} problem(s)`);
  process.exitCode = 1;
} else {
  console.log(`scale conformance: OK (${summary.join(', ')}; no bare z-index)`);
}

if (selfTestFailures > 0) process.exitCode = 1;
