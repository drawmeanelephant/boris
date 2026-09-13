import { expect, test, type Page } from '@playwright/test';

// Graph map e2e: the frozen-graph visual aid rendered by GraphMap.svelte. The
// suite pins the accessibility posture (the SVG is a review aid, not a
// keyboard surface), the deterministic one-node-per-page render, and
// click-to-open, plus the invariant that the semantic lists below it stay the
// navigation path. Same mocked-host approach as the other suites: every
// endpoint is routed in-page, no Zig host is spawned.

const FILES = [
  { path: 'boris.json' },
  { path: 'content/index.md' },
  { path: 'content/guides/start.md' },
  { path: 'content/guides/exit-codes.md' },
  { path: 'content/guides/topics/a.md' },
  { path: 'content/guides/topics/b.md' },
  { path: 'content/guides/topics/c.md' }
];

// Wide enough to overflow the pane at actual size: five satellites under one
// trunk is the shape the viewport zoom controls exist for.
const GRAPH = {
  schemaVersion: '0.2.0',
  frozen: true,
  nodes: [
    { index: 0, id: 'guides/exit-codes', sourcePath: 'content/guides/exit-codes.md', role: 'satellite', parent: 'index', parentIndex: 5, title: 'Exit Codes', status: null, tags: [], bodyOffset: 0 },
    { index: 1, id: 'guides/start', sourcePath: 'content/guides/start.md', role: 'satellite', parent: 'index', parentIndex: 5, title: 'Start Here', status: null, tags: [], bodyOffset: 0 },
    { index: 2, id: 'guides/topics/a', sourcePath: 'content/guides/topics/a.md', role: 'satellite', parent: 'index', parentIndex: 5, title: 'Topic A', status: null, tags: [], bodyOffset: 0 },
    { index: 3, id: 'guides/topics/b', sourcePath: 'content/guides/topics/b.md', role: 'satellite', parent: 'index', parentIndex: 5, title: 'Topic B', status: null, tags: [], bodyOffset: 0 },
    { index: 4, id: 'guides/topics/c', sourcePath: 'content/guides/topics/c.md', role: 'satellite', parent: 'index', parentIndex: 5, title: 'Topic C', status: null, tags: [], bodyOffset: 0 },
    { index: 5, id: 'index', sourcePath: 'content/index.md', role: 'trunk', parent: null, parentIndex: null, title: 'Home', status: null, tags: [], bodyOffset: 0 }
  ],
  edges: [
    { from: { type: 'page', value: 'guides/exit-codes' }, to: { type: 'page', value: 'index' }, kind: 'parent' },
    { from: { type: 'page', value: 'guides/start' }, to: { type: 'page', value: 'index' }, kind: 'parent' },
    { from: { type: 'page', value: 'guides/topics/a' }, to: { type: 'page', value: 'index' }, kind: 'parent' },
    { from: { type: 'page', value: 'guides/topics/b' }, to: { type: 'page', value: 'index' }, kind: 'parent' },
    { from: { type: 'page', value: 'guides/topics/c' }, to: { type: 'page', value: 'index' }, kind: 'parent' },
    { from: { type: 'page', value: 'index' }, to: { type: 'page', value: 'guides/start' }, kind: 'reference' }
  ],
  reverseIndex: [
    { target: { type: 'page', value: 'guides/start' }, incomingEdges: [5] },
    { target: { type: 'page', value: 'index' }, incomingEdges: [0, 1, 2, 3, 4] }
  ],
  nav: [
    { index: 0, id: 'guides/exit-codes', breadcrumb: [5, 0], children: [], siblings: [1, 2, 3, 4] },
    { index: 1, id: 'guides/start', breadcrumb: [5, 1], children: [], siblings: [0, 2, 3, 4] },
    { index: 2, id: 'guides/topics/a', breadcrumb: [5, 2], children: [], siblings: [0, 1, 3, 4] },
    { index: 3, id: 'guides/topics/b', breadcrumb: [5, 3], children: [], siblings: [0, 1, 2, 4] },
    { index: 4, id: 'guides/topics/c', breadcrumb: [5, 4], children: [], siblings: [0, 1, 2, 3] },
    { index: 5, id: 'index', breadcrumb: [5], children: [0, 1, 2, 3, 4], siblings: [] }
  ]
};

async function installApi(page: Page) {
  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'ok', editor_id: 'boris-editor/0.1.0',
      project: { content: true, default_layout: true, publication_profile: true, input_mode: 'markdown' }
    })
  }));
  await page.route('**/api/version', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ compiler_id: 'boris/0.8.2' })
  }));
  await page.route('**/api/files', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ files: FILES })
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
  await page.route('**/api/files/probe', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'unchanged', fingerprint: 'a'.repeat(64), read_only: false })
  }));
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        status: 'opened', path, content: `# ${path}\n`, fingerprint: 'a'.repeat(64), read_only: false
      })
    });
  });
  await page.route('**/api/files/save', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'saved', path: 'content/index.md', content: '# Home\n', fingerprint: 'c'.repeat(64), read_only: false })
  }));
  await page.route('**/api/commands/run', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      mode: 'validate', exit_code: 0, failure_class: 'success', compiler_id: 'boris/0.8.2',
      report_version: null, used_stderr_fallback: false, problems: [], findings: [], impact: []
    })
  }));
  await page.route('**/api/validate-state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ supported: false, state: 'idle', cycle: 0, failure_class: null, problems_count: 0 })
  }));
  for (const endpoint of ['state', 'start', 'stop']) {
    await page.route(`**/api/watch/${endpoint}`, route => route.fulfill({
      status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
    }));
  }
  await page.route(/\/api\/watch\/events/, route => route.fulfill({
    status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
  }));
  await page.route('**/api/authoring', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ frontmatter_schema: { title: 'Boris frontmatter grammar (schema v1)', properties: {} }, completion: null, completion_status: 'build_required' })
  }));
  await page.route('**/api/graph', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ graph: GRAPH, graph_status: 'ready' })
  }));
  await page.route('**/api/publication', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ profiles: [{ path: 'boris.json' }], proof: null })
  }));
  await page.route('**/api/preview/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      phase: 'idle', generation: 0, exit_code: null, used_stderr_fallback: false,
      message: 'Preview has not been built yet.', preview_url: 'https://preview.invalid/?token=test'
    })
  }));
  await page.route('**/api/preview/rebuild', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      phase: 'success', generation: 1, exit_code: 0, used_stderr_fallback: false,
      message: 'Preview is current from a successful Boris incremental build.', preview_url: 'https://preview.invalid/?token=test'
    })
  }));
  await page.route('https://preview.invalid/**', route => route.fulfill({ contentType: 'text/html', body: '<h1>Compiler output</h1>' }));
  await page.goto('/#token=test-session-token');
}

async function openIndex(page: Page) {
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# content/index.md\n');
}

test('graph map is available before a file is open (#970)', async ({ page }) => {
  await installApi(page);
  const map = page.getByTestId('graph-map');
  await expect(map).toBeVisible();
  await expect(map.locator('[data-node-id]')).toHaveCount(GRAPH.nodes.length);
  await expect(page.getByText('Select a node to open a page, or pick a file from Project files.')).toBeVisible();
  await expect(page.locator('[data-node-id].graph-map-node--active')).toHaveCount(0);
});

test('graph map renders one node per page and stays out of the accessibility tree', async ({ page }) => {
  await installApi(page);
  await openIndex(page);

  const map = page.getByTestId('graph-map');
  await expect(map).toBeVisible();
  await expect(map.locator('[data-node-id]')).toHaveCount(GRAPH.nodes.length);
  await expect(map.locator('[data-node-id="guides/start"] text')).toHaveText('Start Here');
  // The map is a review aid: assistive tech reads the semantic lists, not
  // the SVG, so no workflow can depend on pointer-only pixels.
  await expect(map.locator('svg')).toHaveAttribute('aria-hidden', 'true');
  const focusableNodes = await map.locator('[data-node-id]').evaluateAll(
    (nodes) => nodes.filter((node) => node.hasAttribute('tabindex') || node.hasAttribute('href')).length
  );
  expect(focusableNodes).toBe(0);
});

test('graph map click opens the page and the active node is highlighted', async ({ page }) => {
  await installApi(page);
  await openIndex(page);

  const map = page.getByTestId('graph-map');
  await expect(map.locator('[data-node-id="index"]')).toHaveClass(/graph-map-node--active/);

  await map.locator('[data-node-id="guides/start"]').click();
  await expect(page.getByRole('textbox', { name: 'Source for content/guides/start.md' })).toHaveValue('# content/guides/start.md\n');
  await expect(map.locator('[data-node-id="guides/start"]')).toHaveClass(/graph-map-node--active/);
  await expect(map.locator('[data-node-id="index"]')).not.toHaveClass(/graph-map-node--active/);
});

test('the semantic lists below the map remain the navigation path', async ({ page }) => {
  await installApi(page);
  await openIndex(page);

  const map = page.getByTestId('graph-map');
  const children = page.getByRole('button', { name: /^Go to child guides\/exit-codes/ });
  await expect(children).toBeVisible();
  await expect(children).toHaveJSProperty('tagName', 'BUTTON');
  await children.focus();
  await expect(children).toBeFocused();
  // Measured below the figure in DOM order: the visual aid never replaces
  // the keyboard-reachable list.
  const mapBottom = (await map.boundingBox())?.y ?? 0;
  const childBox = await children.boundingBox();
  expect(childBox && childBox.y).toBeGreaterThan(mapBottom);
});

test('zoom controls fit the map, zoom in, and restore actual size', async ({ page }) => {
  await installApi(page);
  await openIndex(page);

  const svg = page.getByTestId('graph-map').locator('svg');
  const viewport = page.getByRole('region', { name: 'Graph map viewport' });
  const zoom = page.getByTestId('graph-map-zoom');
  const clientWidth = await viewport.evaluate((element) => element.clientWidth);

  // Default is fit: nothing clips at first paint.
  const fitWidth = Number(await svg.getAttribute('width'));
  expect(fitWidth).toBeLessThanOrEqual(clientWidth + 1);
  await expect(zoom).not.toHaveText('100%');

  await page.getByRole('button', { name: 'Zoom in' }).click();
  expect(Number(await svg.getAttribute('width'))).toBeGreaterThan(fitWidth);

  await page.getByRole('button', { name: 'Actual size (100%)' }).click();
  await expect(zoom).toHaveText('100%');
  // The acceptance graph is deliberately wider than the pane, so 1:1 panning
  // is real rather than an empty scrollbar.
  expect(Number(await svg.getAttribute('width'))).toBeGreaterThan(clientWidth);

  await page.getByRole('button', { name: 'Fit map to width' }).click();
  expect(Number(await svg.getAttribute('width'))).toBeLessThanOrEqual(clientWidth + 1);
});

test('the map viewport pans with the keyboard once focused', async ({ page }) => {
  await installApi(page);
  await openIndex(page);

  await page.getByRole('button', { name: 'Actual size (100%)' }).click();
  const viewport = page.getByRole('region', { name: 'Graph map viewport' });
  await viewport.focus();
  await expect(viewport).toBeFocused();

  const before = await viewport.evaluate((element) => element.scrollLeft);
  await page.keyboard.press('ArrowRight');
  await expect.poll(() => viewport.evaluate((element) => element.scrollLeft)).toBeGreaterThan(before);
});
