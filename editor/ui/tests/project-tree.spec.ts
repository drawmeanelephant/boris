import { expect, test, type Page } from '@playwright/test';

// Project pane directory tree. The pane renders the host's flat path list as
// an indented, collapsible tree so a long project path stops breaking
// mid-token. The contract this spec pins:
//
//   * a row shows one path segment — that is what removes the mid-token wrap;
//   * the full project-relative path stays each file row's accessible name
//     (and its tooltip), so every name this pane has ever exposed to tests,
//     keyboard users, and screen readers still resolves;
//   * folder rows are real named disclosure buttons (aria-expanded) whose
//     accessible name is exactly their visible segment, and they never count
//     against the bounded file budget;
//   * the filter still matches on the full path, not on the visible segment,
//     so "reference" finds content/reference/cli.md from the root;
//   * collapsing survives a reload, and opening a file from outside the tree
//     expands the folders above it;
//   * sibling order is directories first, then files, alphabetically.

const FILES = [
  { path: 'boris.json' },
  { path: 'content/index.md' },
  { path: 'content/getting-started.md' },
  { path: 'content/guides/frontmatter.md' },
  { path: 'content/guides/getting-started.md' },
  { path: 'content/reference/cli.md' },
  { path: 'themes/boris/layouts/default.html' },
  { path: 'themes/boris/layouts/page.html' }
];

const DIRS = ['content/', 'guides/', 'reference/', 'themes/', 'boris/', 'layouts/'];

async function installApi(page: Page) {
  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'ok', editor_id: 'boris-editor/0.1.0', project: { content: true, default_layout: true, publication_profile: true, input_mode: 'markdown' } })
  }));
  await page.route('**/api/version', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ compiler_id: 'boris/0.8.2' }) }));
  await page.route('**/api/files', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ files: FILES }) }));
  await page.route('**/api/recovery', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ snapshots: [], skipped: 0 }) }));
  await page.route('**/api/recovery/snapshot', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ status: 'snapshotted' }) }));
  await page.route('**/api/recovery/clear', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ status: 'cleared' }) }));
  await page.route('**/api/files/probe', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ status: 'unchanged', fingerprint: 'a'.repeat(64), read_only: false })
  }));
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: 'opened', path, content: '# Body\n', fingerprint: 'a'.repeat(64), read_only: false })
    });
  });
  await page.route('**/api/commands/run', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ mode: 'validate', exit_code: 0, failure_class: 'success', compiler_id: 'boris/0.8.2', report_version: null, used_stderr_fallback: false, problems: [], findings: [], impact: [] })
  }));
  await page.route('**/api/validate-state', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ supported: false, state: 'idle', cycle: 0, failure_class: null, problems_count: 0 })
  }));
  await page.route('**/api/authoring', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ frontmatter_schema: { title: 'Boris frontmatter grammar (schema v1)', properties: {} }, completion: null, completion_status: 'build_required' })
  }));
  await page.route('**/api/graph', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ graph: null, graph_status: 'build_required' }) }));
  await page.route('**/api/publication', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ profiles: [{ path: 'boris.json' }], proof: null }) }));
  await page.route('**/api/preview/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ phase: 'idle', generation: 0, exit_code: null, used_stderr_fallback: false, message: 'Preview has not been built yet.', preview_url: 'https://preview.invalid/?token=test' })
  }));
  await page.route('**/api/watch/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ supported: false, state: 'idle', seq: 0, cycle: 0, events_count: 0, oldest_seq: null, dropped_lines: 0, last_event: null, compiler_id: null, hello_schema: null, last_error: null })
  }));
  for (const endpoint of ['start', 'stop']) {
    await page.route(`**/api/watch/${endpoint}`, route => route.fulfill({ status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' }) }));
  }
  await page.route(/\/api\/watch\/events/, route => route.fulfill({ status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' }) }));
  await page.goto('/#token=test-session-token');
}

function tree(page: Page) {
  return page.getByRole('navigation', { name: 'Project files' });
}
function fileRows(page: Page) {
  return tree(page).locator('button.file-tree-file');
}
function dirRows(page: Page) {
  return tree(page).locator('button.file-tree-dir');
}
// A folder row shows only its own segment, and its accessible name is that
// segment plus the slash — never the full path. So this takes a segment
// ('guides/'), not a path ('content/guides/').
function folderRow(page: Page, segment: string) {
  return tree(page).getByRole('button', { name: segment, exact: true });
}
function depthOf(locator: ReturnType<Page['locator']>) {
  return locator.evaluate(el => {
    let levels = 0;
    for (let node = el.parentElement; node; node = node.parentElement) {
      if (node.tagName === 'UL') levels += 1;
    }
    return levels;
  });
}

test('a file row shows one path segment and keeps the full path as its name', async ({ page }) => {
  await installApi(page);
  const nav = tree(page);

  // Every file row's visible text is a single segment: no slash, so no row can
  // break mid-token the way the flat full-path rows did.
  const rows = await fileRows(page).evaluateAll(els => els.map(el => ({
    visible: (el.textContent ?? '').trim(),
    label: el.getAttribute('aria-label'),
    title: el.getAttribute('title')
  })));
  expect(rows).toHaveLength(FILES.length);
  for (const row of rows) {
    expect(row.visible).not.toContain('/');
    // The full project-relative path is the accessible name and the tooltip.
    expect(row.label).toBe(row.title);
    expect(FILES.some(file => file.path === row.label)).toBe(true);
    expect(row.label?.split('/').pop()).toBe(row.visible);
  }

  // Folder rows carry the segment plus a trailing slash.
  await expect(dirRows(page)).toHaveText(DIRS);
  expect(await nav.locator('button.file-tree-dir').count()).toBe(DIRS.length);
});

test('folder rows are named disclosure controls, not labels', async ({ page }) => {
  await installApi(page);
  const content = folderRow(page, 'content/');

  await expect(content).toBeVisible();
  await expect(content).toHaveAttribute('aria-expanded', 'true');
  // The accessible name is exactly the visible text: the caret is CSS-only, so
  // it never leaks into the label a screen reader announces.
  await expect(content).toHaveText('content/');
  // A folder and a file that share a name stay distinguishable by role+name.
  await expect(tree(page).getByRole('button', { name: 'content/', exact: true })).toHaveCount(1);
});

test('collapsing a folder hides its subtree and reports the state honestly', async ({ page }) => {
  await installApi(page);
  const content = folderRow(page, 'content/');

  await expect(folderRow(page, 'guides/')).toBeVisible();
  await content.click();

  await expect(content).toHaveAttribute('aria-expanded', 'false');
  await expect(page.getByRole('button', { name: 'content/index.md', exact: true })).toHaveCount(0);
  await expect(folderRow(page, 'guides/')).toHaveCount(0);
  // Only the 3 files outside the collapsed folder remain (boris.json and the
  // two under themes/).
  await expect(fileRows(page)).toHaveCount(3);
  await expect(folderRow(page, 'themes/')).toBeVisible();

  // Keyboard activation is native button behavior, not a pointer-only path.
  await content.focus();
  await page.keyboard.press('Enter');
  await expect(content).toHaveAttribute('aria-expanded', 'true');
  await expect(fileRows(page)).toHaveCount(FILES.length);
});

test('collapsed folders survive a reload and reject junk from storage', async ({ page }) => {
  await installApi(page);
  await folderRow(page, 'themes/').click();
  await expect(folderRow(page, 'themes/')).toHaveAttribute('aria-expanded', 'false');

  await page.reload();
  await expect(folderRow(page, 'themes/')).toHaveAttribute('aria-expanded', 'false');
  // The rest are still expanded.
  await expect(folderRow(page, 'content/')).toHaveAttribute('aria-expanded', 'true');

  // Storage is untrusted input: traversal, absolute paths, empty segments and
  // non-strings are dropped rather than repaired.
  await page.evaluate(() => {
    localStorage.setItem('boris-editor-project-collapsed', JSON.stringify([
      '../etc', '/absolute', 'a//b', 'content/../guides', '', 42, null, { path: 'themes' }, 'themes/boris'
    ]));
  });
  await page.reload();
  await expect(folderRow(page, 'boris/')).toHaveAttribute('aria-expanded', 'false');
  await expect(folderRow(page, 'themes/')).toHaveAttribute('aria-expanded', 'true');
  await expect(folderRow(page, 'content/')).toHaveAttribute('aria-expanded', 'true');
  // Exactly the one valid entry survived; every rejected entry left its folder
  // expanded rather than half-applied.
  await expect(tree(page).locator('button.file-tree-dir[aria-expanded="false"]')).toHaveCount(1);
});

test('opening a file from outside the tree expands the folders above it', async ({ page }) => {
  await installApi(page);
  await folderRow(page, 'content/').click();
  await expect(folderRow(page, 'content/')).toHaveAttribute('aria-expanded', 'false');

  // Open through the command palette, so the change comes from outside the
  // tree and the tree has to reveal it.
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  await palette.getByRole('combobox', { name: 'Filter commands' }).fill('frontmatter');
  await palette.getByRole('combobox', { name: 'Filter commands' }).press('Enter');
  await expect(palette).toBeHidden();
  await expect(page.getByRole('textbox', { name: 'Source for content/guides/frontmatter.md' })).toBeVisible();

  await expect(folderRow(page, 'content/')).toHaveAttribute('aria-expanded', 'true');
  await expect(folderRow(page, 'guides/')).toHaveAttribute('aria-expanded', 'true');
  const row = page.getByRole('button', { name: 'content/guides/frontmatter.md', exact: true });
  await expect(row).toBeVisible();
  await expect(row).toHaveAttribute('aria-current', 'page');
});

test('a deliberate collapse of the open file\'s own folder sticks', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/guides/frontmatter.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/guides/frontmatter.md' })).toBeVisible();

  // The reveal runs when the active path changes, not on every render, so
  // collapsing the folder that holds the open file is not undone.
  await folderRow(page, 'guides/').click();
  await expect(folderRow(page, 'guides/')).toHaveAttribute('aria-expanded', 'false');
  await expect(page.getByRole('button', { name: 'content/guides/frontmatter.md', exact: true })).toHaveCount(0);
});

test('indentation encodes depth and the ancestor chain rebuilds the path', async ({ page }) => {
  await installApi(page);
  const nav = tree(page);

  // The tree is nested lists: depth is real structure, not padding alone.
  expect(await depthOf(nav.getByRole('button', { name: 'content/guides/getting-started.md', exact: true }))).toBe(3);
  expect(await depthOf(folderRow(page, 'content/'))).toBe(1);

  // Each file sits under the folder whose label is its own parent segment.
  const parentLabel = await nav.getByRole('button', { name: 'content/guides/frontmatter.md', exact: true })
    .evaluate(el => el.closest('li')?.parentElement?.closest('li')?.querySelector('.file-tree-dir')?.textContent?.trim() ?? null);
  expect(parentLabel).toBe('guides/');
});

test('sibling order is directories first, then files, alphabetically', async ({ page }) => {
  await installApi(page);
  const rootOrder = await tree(page).evaluate(el => {
    const top = el.querySelector(':scope > ul');
    return [...(top?.children ?? [])].map(li => li.querySelector('.file-tree-dir')?.textContent?.trim() ?? li.querySelector('button')?.textContent?.trim());
  });
  // content/ and themes/ are directories; boris.json sorts below them.
  expect(rootOrder).toEqual(['content/', 'themes/', 'boris.json']);
});

test('file rows reserve the caret gutter so names align at every level', async ({ page }) => {
  await installApi(page);

  // A folder's name starts after its caret; a file row at the same level
  // reserves the same gutter as padding so the two names line up. The gutter
  // must not drift with depth, which is what an em-based caret would do (the
  // two row types use different font sizes).
  const gutters = await tree(page).evaluate(el => {
    const pad = (node: Element | null | undefined) => node ? Number.parseFloat(getComputedStyle(node).paddingLeft) : NaN;
    const folder = (segment: string) => [...el.querySelectorAll('.file-tree-dir')].find(b => b.textContent?.trim() === segment) ?? null;
    const file = (path: string) => el.querySelector(`button.file-tree-file[aria-label="${path}"]`);
    return {
      level1: pad(file('boris.json')) - pad(folder('content/')),
      level2: pad(file('content/index.md')) - pad(folder('guides/'))
    };
  });
  expect(gutters.level1).toBeGreaterThan(4);
  expect(gutters.level2).toBeCloseTo(gutters.level1, 1);
});

test('the filter still matches full paths, not visible segments', async ({ page }) => {
  await installApi(page);
  const nav = tree(page);
  const filter = page.getByRole('textbox', { name: 'Filter project files' });

  // "reference" is a folder segment that never appears on a file row.
  await filter.fill('reference');
  await expect(fileRows(page)).toHaveCount(1);
  await expect(page.getByRole('button', { name: 'content/reference/cli.md', exact: true })).toBeVisible();
  // Filtering prunes the tree: only folders that still hold a match remain.
  await expect(dirRows(page)).toHaveText(['content/', 'reference/']);

  // A partial path spanning segments matches too.
  await filter.fill('guides/getting');
  await expect(fileRows(page)).toHaveCount(1);
  await expect(page.getByRole('button', { name: 'content/guides/getting-started.md', exact: true })).toBeVisible();

  await filter.fill('nothing-here');
  await expect(nav.getByText('No project files match the filter.')).toBeVisible();
});

test('the open file is marked active at its true depth', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/guides/frontmatter.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/guides/frontmatter.md' })).toBeVisible();

  const active = tree(page).locator('button.file-tree-file.active');
  await expect(active).toHaveCount(1);
  await expect(active).toHaveAttribute('aria-current', 'page');
  await expect(active).toHaveAttribute('aria-label', 'content/guides/frontmatter.md');
  expect(await depthOf(active)).toBe(3);
});
