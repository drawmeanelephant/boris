import { expect, test, type Page } from '@playwright/test';

// Every ordered scale the editor declares (#993 follow-up). The order itself
// lives in exactly one place — the `--scale-*` lists in src/lib/tokens.css —
// and this walks them out of the *applied* stylesheet rather than the source
// file. That is the half no static parse can do: it sees a value overridden in
// a later block, inside a media query, or by the dark theme, and it resolves
// the `clamp` steps whose whole point is to change with the viewport.
//
// scripts/check-scales.mjs holds the static half — classification, names, the
// prose in the README, and the ban on bare-number z-indexes. Together they keep
// every size, gap, corner, and layer on one declared list.

const FILES = [
  { path: 'boris.json' },
  { path: 'content/index.md' }
];

/** Only what a clean Author boot needs: the review panes are unmounted, so the
 *  graph/publication/preview/watch endpoints are never asked for. */
async function installApi(page: Page) {
  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'ok',
      editor_id: 'boris-editor/0.1.0',
      project: { content: true, default_layout: true, publication_profile: true, input_mode: 'markdown' }
    })
  }));
  await page.route('**/api/version', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ compiler_id: 'boris/0.8.2' })
  }));
  await page.route('**/api/files', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ files: FILES })
  }));
  await page.route('**/api/recovery', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ snapshots: [], skipped: 0 })
  }));
  await page.route('**/api/recovery/snapshot', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ status: 'snapshotted' })
  }));
  await page.route('**/api/recovery/clear', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ status: 'cleared' })
  }));
  await page.goto('/#token=test-session-token');
}

const REQUIRED_LISTS = ['--scale-type', '--scale-space', '--scale-radius', '--scale-layer'];

/** The scale lists as the cascade holds them, not as the file spells them. */
async function scaleLists(page: Page): Promise<Record<string, string[]>> {
  return page.evaluate(names => {
    const style = getComputedStyle(document.documentElement);
    const lists: Record<string, string[]> = {};
    for (const name of names) {
      lists[name] = style.getPropertyValue(name).trim().split(/\s+/).filter(Boolean);
    }
    return lists;
  }, [...REQUIRED_LISTS, '--scale-type-offchain']);
}

/** Resolve length tokens to the pixels a `font-size` takes. A custom property
 *  computes to its token stream (the `clamp(...)` itself), so a probe element
 *  is what turns it into the value the viewport actually produced. */
async function resolvedLengths(page: Page, names: string[]): Promise<Record<string, number>> {
  return page.evaluate(tokenNames => {
    const probe = document.createElement('span');
    probe.style.position = 'absolute';
    probe.style.visibility = 'hidden';
    document.body.appendChild(probe);
    const resolved: Record<string, number> = {};
    for (const name of tokenNames) {
      probe.style.fontSize = `var(${name})`;
      resolved[name] = Number.parseFloat(getComputedStyle(probe).fontSize);
    }
    probe.remove();
    return resolved;
  }, names);
}

/** Resolve unitless tokens (the layer ladder) straight from the cascade. */
async function resolvedIntegers(page: Page, names: string[]): Promise<Record<string, number>> {
  return page.evaluate(tokenNames => {
    const style = getComputedStyle(document.documentElement);
    const resolved: Record<string, number> = {};
    for (const name of tokenNames) {
      resolved[name] = Number.parseInt(style.getPropertyValue(name).trim(), 10);
    }
    return resolved;
  }, names);
}

function ascending(values: Record<string, number>, names: string[], label: string, where: string) {
  for (let i = 1; i < names.length; i += 1) {
    const lower = names[i - 1];
    const higher = names[i];
    expect(
      values[higher],
      `${label} scale: ${higher} must outrank ${lower} ${where}`
    ).toBeGreaterThan(values[lower]);
  }
}

// The widths matter here, not just as repetition: two steps are clamps in `vw`,
// so a chain can ascend at 1440px and collapse at 480px.
for (const width of [1920, 1440, 1024, 480]) {
  test(`every declared scale ascends in the applied stylesheet at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await installApi(page);

    const lists = await scaleLists(page);
    // An empty list means the cascade lost the contract — fail rather than let
    // the loops below pass vacuously on nothing.
    for (const name of REQUIRED_LISTS) {
      expect(lists[name].length, `${name} must be declared and non-empty in the cascade`).toBeGreaterThan(0);
    }

    const lengths = await resolvedLengths(page, [
      ...lists['--scale-type'],
      ...lists['--scale-space'],
      ...lists['--scale-radius']
    ]);
    for (const [name, value] of Object.entries(lengths)) {
      expect(value, `${name} must resolve to a pixel size`).toBeGreaterThan(0);
    }

    ascending(lengths, lists['--scale-type'], 'type', `at ${width}px`);
    ascending(lengths, lists['--scale-space'], 'space', `at ${width}px`);
    ascending(lengths, lists['--scale-radius'], 'radius', `at ${width}px`);

    // The rhythm is a rhythm: every step a whole multiple of the declared base.
    // Checking it here as well as statically is what catches a base or a step
    // overridden further down the cascade.
    const base = (await resolvedLengths(page, ['--scale-space-base']))['--scale-space-base'];
    expect(base, '--scale-space-base must resolve to a pixel size').toBeGreaterThan(0);
    for (const name of lists['--scale-space']) {
      const remainder = lengths[name] % base;
      expect(
        Math.min(remainder, base - remainder),
        `${name} (${lengths[name]}px) must be a whole multiple of the ${base}px base`
      ).toBeLessThan(1e-6);
    }
  });
}

test('the layer ladder is the only authority on z-index', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await installApi(page);

  const lists = await scaleLists(page);
  const layers = await resolvedIntegers(page, lists['--scale-layer']);
  for (const [name, value] of Object.entries(layers)) {
    expect(Number.isInteger(value), `${name} must resolve to an integer layer`).toBe(true);
  }
  ascending(layers, lists['--scale-layer'], 'layer', 'in the cascade');

  // The ladder has to reach the chrome, not just the token block: a bare number
  // in a rule would leave these two at whatever it said.
  await expect(page.locator('.section-nav')).toHaveCSS('z-index', String(layers['--layer-nav']));
  await expect(page.locator('.skip-link')).toHaveCSS('z-index', String(layers['--layer-skip-link']));
  // The skip link must stay above the nav it jumps past, or it is unreachable.
  expect(layers['--layer-skip-link']).toBeGreaterThan(layers['--layer-nav']);
});

test('the off-chain size interleaves with the chain but never coincides', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await installApi(page);

  const lists = await scaleLists(page);
  const [offChain] = lists['--scale-type-offchain'];
  expect(offChain, 'tokens.css must declare --scale-type-offchain').toBeTruthy();

  const lengths = await resolvedLengths(page, [offChain, ...lists['--scale-type']]);
  for (const step of lists['--scale-type']) {
    expect(lengths[offChain], `${offChain} must not coincide with ${step}`).not.toBe(lengths[step]);
  }
});
