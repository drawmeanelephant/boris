import { expect, test, type Page, type Request } from '@playwright/test';

type MockOptions = {
  saveConflict?: boolean;
  saveConflictOnce?: boolean;
  saveDeleted?: boolean;
  saveDeletedOnce?: boolean;
  recovery?: Array<{ path: string; content: string; fingerprint: string }>;
  disk?: string;
  commands?: Partial<Record<string, CommandResult>>;
  authoring?: Array<Record<string, unknown>>;
  graph?: Array<Record<string, unknown>>;
  files?: Array<{ path: string }>;
  inputMode?: 'markdown' | 'cooklang' | 'textile' | 'mixed' | 'empty';
  previewRebuilds?: Array<Record<string, unknown>>;
  publication?: Record<string, unknown>;
  version?: Record<string, unknown>;
  openError?: { error: string };
  saveError?: { error: string };
  commandByCall?: CommandResult[];
  recoverySkipped?: number;
};

type CommandResult = {
  mode: string;
  exit_code: number | null;
  failure_class: 'success' | 'content' | 'usage' | 'io' | 'terminated';
  compiler_id: string;
  report_version: string | null;
  used_stderr_fallback: boolean;
  problems: Array<{
    severity: 'error' | 'warning' | 'info'; code: string | null; message: string; remediation: string;
    source_path: string | null; line: number | null; column: number | null; id: string | null;
    origin: 'build_report' | 'analysis_report' | 'stderr' | 'process';
    position_confidence: 'exact' | 'best_effort' | 'none'; packet: string;
  }>;
  findings: Array<Record<string, unknown>>;
  impact: Array<Record<string, unknown>>;
  publication_plan?: Record<string, unknown> | null;
};

function commandResult(mode: string, overrides: Partial<CommandResult> = {}): CommandResult {
  return {
    mode, exit_code: 0, failure_class: 'success', compiler_id: 'boris/0.8.1',
    report_version: null, used_stderr_fallback: false, problems: [], findings: [], impact: [],
    publication_plan: null,
    ...overrides
  };
}

type CompletionEntity = {
  id: string; title: string | null; parent: string | null; role: string; status: string;
  tags: string[]; relations: Array<{ kind: string; target: string }>;
};

function authoringPayload(withGraph = true, entities: CompletionEntity[] = [
  { id: 'guides/intro', title: 'Introduction', parent: null, role: 'trunk', status: 'published', tags: ['guide'], relations: [] }
]) {
  return {
    frontmatter_schema: {
      title: 'Boris frontmatter grammar (schema v1)',
      properties: {
        id: { type: ['string', 'null'], maxLength: 255 },
        title: { type: ['string', 'null'], maxLength: 512 },
        parent: { type: ['string', 'null'], maxLength: 255 },
        status: { type: ['string', 'null'], enum: ['draft', 'published', 'archived', null] },
        tags: { type: 'array', maxItems: 32 },
        relations: { type: 'array', maxItems: 128 },
        published_at: { type: ['string', 'null'] },
        summary: { type: ['string', 'null'], maxLength: 1024 }
      }
    },
    completion: withGraph ? {
      format: 'boris-completion-index', schema_version: 1, compiler_id: 'boris/0.8.1', frozen: true,
      entities,
      relation_kinds: ['depends_on', 'relates_to'], parent_targets: ['guides/intro'],
      layout_slots: ['content', 'title', 'nav']
    } : null,
    completion_status: withGraph ? 'ready' : 'build_required'
  };
}

function graphPayload(ready = true): Record<string, unknown> {
  if (!ready) return { graph: null, graph_status: 'build_required' };
  return {
    graph_status: 'ready',
    graph: {
      schemaVersion: '0.2.0', frozen: true,
      nodes: [
        { index: 0, id: 'guides/intro', sourcePath: 'guides/intro.md', role: 'trunk', parent: null, parentIndex: null, title: 'Introduction', status: 'published', tags: ['guide'], bodyOffset: 20 },
        { index: 1, id: 'guides/intro-tips', sourcePath: 'guides/intro-tips.md', role: 'satellite', parent: 'guides/intro', parentIndex: 0, title: 'Intro Tips', status: 'draft', tags: ['guide'], bodyOffset: 20 },
        { index: 2, id: 'index', sourcePath: 'index.md', role: 'trunk', parent: null, parentIndex: null, title: 'Home', status: 'published', tags: ['home'], bodyOffset: 20 }
      ],
      edges: [
        { from: { type: 'page', value: 'guides/intro-tips' }, to: { type: 'page', value: 'guides/intro' }, kind: 'parent' },
        { from: { type: 'page', value: 'index' }, to: { type: 'page', value: 'guides/intro' }, kind: 'reference' }
      ],
      reverseIndex: [
        { target: { type: 'page', value: 'guides/intro' }, incomingEdges: [0, 1] }
      ],
      nav: [
        { index: 0, id: 'guides/intro', breadcrumb: [0], children: [1], siblings: [] },
        { index: 1, id: 'guides/intro-tips', breadcrumb: [0, 1], children: [], siblings: [] },
        { index: 2, id: 'index', breadcrumb: [2], children: [], siblings: [] }
      ]
    }
  };
}

async function installApi(page: Page, options: MockOptions = {}) {
  let disk = options.disk ?? '# Home\n';
  let fingerprint = 'a'.repeat(64);
  let authoringRequest = 0;
  let graphRequest = 0;
  let previewRebuild = 0;
  let conflictOnceRemaining = options.saveConflictOnce ? 1 : 0;
  let deletedOnceRemaining = options.saveDeletedOnce ? 1 : 0;

  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'ok',
      editor_id: 'boris-editor/0.1.0',
      project: { content: true, default_layout: true, publication_profile: true, input_mode: options.inputMode ?? 'markdown' }
    })
  }));
  await page.route('**/api/version', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify(options.version ?? { compiler_id: 'boris/0.8.1' })
  }));
  await page.route('**/api/files', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ files: options.files ?? [{ path: 'boris.json' }, { path: 'content/index.md' }] })
  }));
  await page.route('**/api/recovery', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ snapshots: options.recovery ?? [], skipped: options.recoverySkipped ?? 0 })
  }));
  await page.route('**/api/files/probe', async route => {
    const body = route.request().postDataJSON() as { fingerprint?: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        status: 'unchanged',
        fingerprint: body.fingerprint ?? 'a'.repeat(64),
        read_only: false
      })
    });
  });
  await page.route('**/api/files/open', async route => {
    if (options.openError) {
      await route.fulfill({
        status: 413,
        contentType: 'application/json',
        body: JSON.stringify({ error: options.openError.error })
      });
      return;
    }
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: 'opened', path, content: disk, fingerprint, read_only: false })
    });
  });
  let commandCall = 0;
  await page.route('**/api/files/save', async route => {
    if (options.saveError) {
      await route.fulfill({
        status: 413,
        contentType: 'application/json',
        body: JSON.stringify({ error: options.saveError.error })
      });
      return;
    }
    const body = route.request().postDataJSON() as { path: string; content: string };
    if (options.saveConflict || conflictOnceRemaining > 0) {
      if (conflictOnceRemaining > 0) conflictOnceRemaining -= 1;
      await route.fulfill({
        status: 409,
        contentType: 'application/json',
        body: JSON.stringify({
          status: 'conflict', path: body.path, content: '# Changed elsewhere\n',
          fingerprint: 'b'.repeat(64), read_only: false
        })
      });
      return;
    }
    if (options.saveDeleted || deletedOnceRemaining > 0) {
      if (deletedOnceRemaining > 0) deletedOnceRemaining -= 1;
      await route.fulfill({
        status: 409,
        contentType: 'application/json',
        body: JSON.stringify({ status: 'deleted', path: body.path })
      });
      return;
    }
    disk = body.content;
    fingerprint = 'c'.repeat(64);
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: 'saved', path: body.path, content: disk, fingerprint, read_only: false })
    });
  });
  for (const endpoint of ['snapshot', 'clear']) {
    await page.route(`**/api/recovery/${endpoint}`, route => route.fulfill({
      contentType: 'application/json', body: JSON.stringify({ status: endpoint === 'snapshot' ? 'snapshotted' : 'cleared' })
    }));
  }
  await page.route('**/api/files/create', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      status: 201, contentType: 'application/json',
      body: JSON.stringify({ status: 'created', path, content: '', fingerprint: 'd'.repeat(64), read_only: false })
    });
  });
  for (const endpoint of ['rename', 'delete']) {
    await page.route(`**/api/files/${endpoint}`, route => route.fulfill({
      contentType: 'application/json', body: JSON.stringify({ status: endpoint === 'rename' ? 'renamed' : 'deleted' })
    }));
  }
  await page.route('**/api/commands/run', async route => {
    const { mode } = route.request().postDataJSON() as { mode: string };
    const queued = options.commandByCall;
    const payload = queued
      ? queued[Math.min(commandCall, queued.length - 1)]
      : (options.commands?.[mode] ?? commandResult(mode));
    commandCall += 1;
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify(payload)
    });
  });
  await page.route('**/api/authoring', route => {
    const sequence = options.authoring ?? [authoringPayload()];
    const body = sequence[Math.min(authoringRequest, sequence.length - 1)];
    authoringRequest += 1;
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  await page.route('**/api/graph', route => {
    const sequence = options.graph ?? [graphPayload()];
    const body = sequence[Math.min(graphRequest, sequence.length - 1)];
    graphRequest += 1;
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  await page.route('**/api/publication', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify(options.publication ?? {
      profiles: [{ path: 'boris.json' }],
      proof: null
    })
  }));
  await page.route('**/api/preview/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ phase: 'idle', generation: 0, exit_code: null, used_stderr_fallback: false, message: 'Preview has not been built yet.', preview_url: 'https://preview.invalid/?token=test' })
  }));
  await page.route('**/api/preview/rebuild', route => {
    const sequence = options.previewRebuilds ?? [{ phase: 'success', generation: 1, exit_code: 0, used_stderr_fallback: false, message: 'Preview is current from a successful Boris incremental build.', preview_url: 'https://preview.invalid/?token=test' }];
    const body = sequence[Math.min(previewRebuild, sequence.length - 1)];
    previewRebuild += 1;
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  await page.route('https://preview.invalid/**', route => route.fulfill({ contentType: 'text/html', body: '<h1>Compiler output</h1>' }));
  await page.goto('/#token=test-session-token');
}

test('semantic shell and file tree expose stable keyboard and voice names', async ({ page }) => {
  await installApi(page);
  await expect(page.getByRole('heading', { name: 'Boris Editor', level: 1 })).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Editor sections' })).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Project files' })).toBeVisible();
  for (const name of ['Project', 'Source', 'Graph', 'Publication', 'Problems', 'Preview']) {
    const link = page.getByRole('link', { name, exact: true });
    await expect(link).toBeVisible();
    await expect(link).toHaveText(name);
  }
  for (const name of ['Create file', 'Rename file', 'Delete file', 'Undo', 'Redo', 'Save file']) {
    const button = page.getByRole('button', { name, exact: true });
    await expect(button).toHaveText(name);
  }
  await expect(page.getByRole('status', { name: 'Connection status' })).toContainText('Connected to boris-editor/0.1.0.');
  const tree = await page.getByRole('navigation', { name: 'Project files' }).ariaSnapshot();
  expect(tree).toContain('button "content/index.md"');
});

test('source editing, undo, redo, and explicit save work without a pointer', async ({ page }) => {
  await installApi(page);
  const file = page.getByRole('button', { name: 'content/index.md', exact: true });
  await file.focus();
  await page.keyboard.press('Enter');

  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await expect(editor).toHaveValue('# Home\n');
  const recoveryRequest = page.waitForRequest('**/api/recovery/snapshot');
  await editor.fill('# Draft\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
  expect((await recoveryRequest).postDataJSON()).toMatchObject({
    path: 'content/index.md', content: '# Draft\n', fingerprint: 'a'.repeat(64)
  });
  await file.click();
  await expect(editor).toHaveValue('# Draft\n');
  await editor.focus();
  await page.keyboard.press('Control+z');
  await expect(editor).toHaveValue('# Home\n');
  await page.keyboard.press('Control+Shift+z');
  await expect(editor).toHaveValue('# Draft\n');
  await page.keyboard.press('Control+s');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Saved content/index.md.');
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();
});

test('external edits open an explicit two-version conflict dialog', async ({ page }) => {
  await installApi(page, { saveConflict: true });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
  await page.getByRole('button', { name: 'Save file', exact: true }).click();

  const dialog = page.getByRole('dialog', { name: 'External changes detected' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('textbox', { name: 'Your unsaved version' })).toHaveValue('# Mine\n');
  await expect(dialog.getByRole('textbox', { name: 'Current disk version' })).toHaveValue('# Changed elsewhere\n');
  for (const name of ['Keep editing', 'Load disk version', 'Replace disk version']) {
    await expect(dialog.getByRole('button', { name: new RegExp(name) })).toContainText(name);
  }
  await dialog.getByRole('button', { name: 'Load disk version' }).click();
  await expect(dialog).toBeHidden();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Changed elsewhere\n');
});

test('Enter confirms the Delete dialog primary action with a visible hint (#462)', async ({ page }) => {
  await installApi(page);
  let deleteRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/delete')) deleteRequests += 1;
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('button', { name: 'Delete file', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Delete file' });
  await expect(dialog).toBeVisible();
  const confirm = dialog.getByRole('button', { name: /Delete content\/index\.md/ });
  await expect(confirm).toContainText('Enter');
  await expect(dialog.getByRole('button', { name: /Cancel/ })).toContainText('Esc');
  await expect(confirm).toBeFocused();
  const deleteRequest = page.waitForRequest('**/api/files/delete');
  await page.keyboard.press('Enter');
  expect((await deleteRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', confirmed: true });
  await expect(dialog).toBeHidden();
  expect(deleteRequests).toBe(1);
});

test('Enter confirms the conflict dialog primary action with a visible hint (#462)', async ({ page }) => {
  await installApi(page, { saveConflictOnce: true });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
  await page.getByRole('button', { name: 'Save file', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'External changes detected' });
  await expect(dialog).toBeVisible();
  const primary = dialog.getByRole('button', { name: /Replace disk version/ });
  await expect(primary).toBeFocused();
  await expect(primary).toContainText('Enter');
  const saveRequest = page.waitForRequest('**/api/files/save');
  await page.keyboard.press('Enter');
  expect((await saveRequest).postDataJSON()).toMatchObject({
    path: 'content/index.md', content: '# Mine\n', fingerprint: 'b'.repeat(64)
  });
  await expect(dialog).toBeHidden();
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Saved content/index.md.');
});

test('Create and Rename dialogs show visible Enter and Esc key hints (#462)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'Create file', exact: true }).click();
  const create = page.getByRole('dialog', { name: 'Create file' });
  await expect(create.getByRole('button', { name: /Create file/ })).toContainText('Enter');
  await expect(create.getByRole('button', { name: /Cancel/ })).toContainText('Esc');
  await page.keyboard.press('Escape');
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('button', { name: 'Rename file', exact: true }).click();
  const rename = page.getByRole('dialog', { name: 'Rename file' });
  await expect(rename.getByRole('button', { name: /Rename file/ })).toContainText('Enter');
  await expect(rename.getByRole('button', { name: /Cancel/ })).toContainText('Esc');
});

test('recovery is announced and restored only on an explicit named action', async ({ page }) => {
  await installApi(page, {
    recovery: [{ path: 'content/index.md', content: '# Recovered draft\n', fingerprint: 'a'.repeat(64) }]
  });
  const recovery = page.getByRole('complementary', { name: 'Recovered unsaved work' });
  await expect(recovery).toBeVisible();
  const restore = recovery.getByRole('button', { name: 'Restore content/index.md', exact: true });
  await expect(restore).toHaveText('Restore content/index.md');
  await restore.focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Recovered draft\n');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Recovered unsaved work');
});

test('restoring recovered work while dirty offers Save & restore and Discard & restore (#462)', async ({ page }) => {
  await installApi(page, {
    recovery: [{ path: 'content/guides/getting-started.md', content: '# Recovered guide\n', fingerprint: 'a'.repeat(64) }]
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await editor.fill('# Draft\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

  const recovery = page.getByRole('complementary', { name: 'Recovered unsaved work' });
  const restore = recovery.getByRole('button', { name: 'Restore content/guides/getting-started.md', exact: true });
  await restore.click();
  const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
  await expect(dialog).toBeVisible();
  await expect(dialog.locator('p').first()).toContainText('content/guides/getting-started.md');
  await expect(dialog.getByRole('button', { name: /Save & restore/ })).toContainText('Save & restore');

  // Cancel keeps the dirty buffer and does not restore.
  await dialog.getByRole('button', { name: /Cancel/ }).click();
  await expect(dialog).toBeHidden();
  await expect(editor).toHaveValue('# Draft\n');

  // Discard & restore drops the buffer without saving, then restores the recovered work.
  let saveRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/save')) saveRequests += 1;
  });
  const openRequest = page.waitForRequest('**/api/files/open');
  await restore.click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: /Discard & restore/ }).click();
  expect((await openRequest).postDataJSON()).toMatchObject({ path: 'content/guides/getting-started.md' });
  expect(saveRequests).toBe(0);
  await expect(page.getByRole('textbox', { name: 'Source for content/guides/getting-started.md' })).toHaveValue('# Recovered guide\n');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Recovered unsaved work for content/guides/getting-started.md.');
});

test('native file dialogs are keyboard-dismissible and all controls have visible names', async ({ page }) => {
  await installApi(page);
  const create = page.getByRole('button', { name: 'Create file', exact: true });
  await create.focus();
  await page.keyboard.press('Enter');
  const dialog = page.getByRole('dialog', { name: 'Create file' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('textbox', { name: 'New file path' })).toBeFocused();
  await expect(dialog.getByRole('button', { name: /Cancel/ })).toContainText('Cancel');
  await page.keyboard.press('Escape');
  await expect(dialog).toBeHidden();
});

test('Enter in the Create file path input submits the primary action exactly once (#459)', async ({ page }) => {
  await installApi(page);
  let createRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/create')) createRequests += 1;
  });
  await page.getByRole('button', { name: 'Create file', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Create file' });
  await expect(dialog).toBeVisible();
  const input = dialog.getByRole('textbox', { name: 'New file path' });
  await input.fill('content/posts/new-post.md');
  await input.press('Enter');
  await expect(dialog).toBeHidden();
  expect(createRequests).toBe(1);
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Created content/posts/new-post.md.');
});

test('Enter in the Rename file path input submits the primary action exactly once (#459)', async ({ page }) => {
  await installApi(page);
  let renameRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/rename')) renameRequests += 1;
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('button', { name: 'Rename file', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Rename file' });
  await expect(dialog).toBeVisible();
  const request = page.waitForRequest('**/api/files/rename');
  const input = dialog.getByRole('textbox', { name: 'New file path' });
  await input.fill('content/posts/moved.md');
  await input.press('Enter');
  expect((await request).postDataJSON()).toMatchObject({ path: 'content/index.md', new_path: 'content/posts/moved.md' });
  await expect(dialog).toBeHidden();
  expect(renameRequests).toBe(1);
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Renamed content/index.md to content/posts/moved.md.');
});

test('Enter with an invalid Create path does not submit (#459)', async ({ page }) => {
  await installApi(page);
  let createRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/create')) createRequests += 1;
  });
  await page.getByRole('button', { name: 'Create file', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Create file' });
  const input = dialog.getByRole('textbox', { name: 'New file path' });
  await input.fill('   ');
  await input.press('Enter');
  await expect(dialog).toBeVisible();
  expect(createRequests).toBe(0);
});

test('the Create file primary button still submits the same action (#459)', async ({ page }) => {
  await installApi(page);
  let createRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/create')) createRequests += 1;
  });
  await page.getByRole('button', { name: 'Create file', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Create file' });
  await dialog.getByRole('textbox', { name: 'New file path' }).fill('content/posts/button-post.md');
  await dialog.getByRole('button', { name: /Create file/ }).click();
  await expect(dialog).toBeHidden();
  expect(createRequests).toBe(1);
});

test('Delete dialog falls back to a named placeholder when no file is selected (#461)', async ({ page }) => {
  await installApi(page);
  const dialog = page.locator('dialog').filter({ has: page.locator('#delete-heading') });
  expect(await dialog.locator('p').first().textContent()).toBe(
    'Delete selected file? This changes the project immediately and cannot be undone in Boris Editor.'
  );
  expect(await dialog.locator('.dialog-actions .danger').textContent()).toContain('Delete file');
});

test('Delete dialog names the selected file and deletes exactly once (#461)', async ({ page }) => {
  await installApi(page);
  let deleteRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/delete')) deleteRequests += 1;
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Delete file' });
  await page.getByRole('button', { name: 'Delete file', exact: true }).click();
  await expect(dialog).toBeVisible();
  await expect(dialog.locator('p').first()).toContainText('Delete content/index.md?');
  const deleteRequest = page.waitForRequest('**/api/files/delete');
  await dialog.getByRole('button', { name: /Delete content\/index\.md/ }).click();
  expect((await deleteRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', confirmed: true });
  await expect(dialog).toBeHidden();
  expect(deleteRequests).toBe(1);
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Deleted content/index.md.');
});

test('Skip to workspace moves focus to the workspace landmark and keeps the session token (#447)', async ({ page }) => {
  await installApi(page);
  const skipLink = page.getByRole('link', { name: 'Skip to workspace' });
  const workspace = page.locator('main#workspace');
  await expect(workspace).toHaveAttribute('tabindex', '-1');
  await page.keyboard.press('Tab');
  await expect(skipLink).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(workspace).toBeFocused();
  expect(await page.evaluate(() => window.location.hash)).toContain('token=');
  await page.evaluate(() => (document.querySelector('.skip-link') as HTMLAnchorElement).click());
  await expect(workspace).toBeFocused();
  expect(await page.evaluate(() => window.location.hash)).toContain('token=');
});

test('modal dialogs trap keyboard focus while open (#460)', async ({ page }) => {
  await installApi(page);
  const dialog = page.getByRole('dialog', { name: 'Create file' });
  await page.getByRole('button', { name: 'Create file', exact: true }).click();
  await expect(dialog).toBeVisible();
  const insideDialog = () => page.evaluate(() => {
    const el = document.activeElement;
    return el instanceof HTMLElement && Boolean(el.closest('dialog'));
  });
  for (let i = 0; i < 8; i++) {
    await page.keyboard.press('Tab');
    expect(await insideDialog()).toBe(true);
  }
  await expect(dialog.getByRole('button', { name: /Create file/ })).toBeFocused();
  for (let i = 0; i < 8; i++) {
    await page.keyboard.press('Shift+Tab');
    expect(await insideDialog()).toBe(true);
  }
  await expect(dialog.getByRole('textbox', { name: 'New file path' })).toBeFocused();
});

test('switching files while dirty offers Cancel and Save & Switch (#462)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await editor.fill('# Draft\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

  const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
  const target = page.getByRole('button', { name: 'boris.json', exact: true });
  await target.click();
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('heading', { name: /content\/index\.md/ })).toBeVisible();
  await expect(dialog.locator('p').first()).toContainText('boris.json');

  // Cancel keeps the current file and its unsaved buffer.
  await dialog.getByRole('button', { name: /Cancel/ }).click();
  await expect(dialog).toBeHidden();
  await expect(editor).toHaveValue('# Draft\n');
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();

  // Save & Switch persists the buffer, then opens the target.
  const saveRequest = page.waitForRequest('**/api/files/save');
  const openRequest = page.waitForRequest('**/api/files/open');
  await target.click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: /Save & switch/ }).click();
  expect((await saveRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', content: '# Draft\n' });
  expect((await openRequest).postDataJSON()).toMatchObject({ path: 'boris.json' });
  await expect(page.getByRole('textbox', { name: 'Source for boris.json' })).toBeVisible();
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();
});

test('Discard & Switch drops the dirty buffer without saving and opens the target (#462)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Discard me\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
  let saveRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/save')) saveRequests += 1;
  });
  const openRequest = page.waitForRequest('**/api/files/open');
  await page.getByRole('button', { name: 'boris.json', exact: true }).click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: /Discard & switch/ }).click();
  expect((await openRequest).postDataJSON()).toMatchObject({ path: 'boris.json' });
  expect(saveRequests).toBe(0);
  await expect(page.getByRole('textbox', { name: 'Source for boris.json' })).toHaveValue('# Home\n');
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();
});

test('desktop viewports place Problems and Preview beside the editor without a deep page scroll (#463)', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await installApi(page);
  const source = page.locator('#source');
  const problems = page.locator('#problems');
  const preview = page.locator('#preview');
  await expect(problems).toBeVisible();
  await expect(preview).toBeVisible();
  const sourceBox = await source.boundingBox();
  const problemsBox = await problems.boundingBox();
  const previewBox = await preview.boundingBox();
  expect(sourceBox).not.toBeNull();
  expect(problemsBox).not.toBeNull();
  expect(previewBox).not.toBeNull();
  // Files | Editor | Diagnostics+Preview: Problems and Preview open to the right of the editor.
  expect(problemsBox!.x).toBeGreaterThan(sourceBox!.x + sourceBox!.width - 1);
  expect(previewBox!.x).toBeGreaterThan(sourceBox!.x + sourceBox!.width - 1);
  // Neither pane starts below the fold (previously ~1244px / ~1772px on this viewport).
  expect(problemsBox!.y).toBeLessThan(900);
  expect(previewBox!.y).toBeLessThan(900);
});

test('Boris commands expose visible voice names and distinct exit classes', async ({ page }) => {
  await installApi(page, {
    commands: {
      validate: commandResult('validate', { exit_code: 2, failure_class: 'usage' }),
      ir_build: commandResult('ir_build', { exit_code: 1, failure_class: 'content' }),
      html_build: commandResult('html_build', { exit_code: 3, failure_class: 'io' })
    }
  });
  for (const name of ['Validate project', 'Build diagnostics', 'Build HTML', 'Check graph', 'Run impact']) {
    await expect(page.getByRole('button', { name, exact: true })).toHaveText(name);
  }
  await page.getByRole('button', { name: 'Build diagnostics', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Content or graph failure (exit 1)');
  await page.getByRole('button', { name: 'Validate project', exact: true }).click();
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Usage or configuration failure (exit 2)');
  await page.getByRole('button', { name: 'Build HTML', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('I/O or system failure (exit 3)');
});

test('structured problems group, navigate by UTF-8 byte position, and copy a bounded packet', async ({ page }) => {
  let copied = '';
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: async (value: string) => { (window as unknown as { copied: string }).copied = value; } }
    });
  });
  const packet = 'Boris diagnostic packet\ncode: EDUPLICATEID\nsource: index.md\nposition: 1:6';
  await installApi(page, {
    disk: '# Héllo\n',
    commands: {
      ir_build: commandResult('ir_build', {
        exit_code: 1, failure_class: 'content', report_version: '0.3.0',
        problems: [{
          severity: 'error', code: 'EDUPLICATEID', message: 'Duplicate id.', remediation: 'Choose a unique id.',
          source_path: 'index.md', line: 1, column: 6, id: 'home', origin: 'build_report',
          position_confidence: 'exact', packet
        }]
      })
    }
  });
  await page.getByRole('button', { name: 'Build diagnostics', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'index.md · error · EDUPLICATEID' })).toBeVisible();
  const go = page.getByRole('button', { name: 'Go to index.md line 1 column 6', exact: true });
  await expect(go).toHaveText('Go to index.md line 1 column 6');
  await go.focus();
  await page.keyboard.press('Enter');
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await expect(editor).toBeFocused();
  expect(await editor.evaluate(node => (node as HTMLTextAreaElement).selectionStart)).toBe(4);

  const copy = page.getByRole('button', { name: 'Copy packet for EDUPLICATEID at index.md', exact: true });
  await expect(copy).toHaveText('Copy packet for EDUPLICATEID at index.md');
  await copy.focus();
  await page.keyboard.press('Enter');
  copied = await page.evaluate(() => (window as unknown as { copied: string }).copied);
  expect(copied).toBe(packet);
  expect(copied.length).toBeLessThanOrEqual(4096);
  expect(copied).not.toContain('/Users/');
});

test('stderr diagnostics are announced as best-effort and dirty buffers route commands through a resolution dialog', async ({ page }) => {
  await installApi(page, {
    commands: {
      validate: commandResult('validate', {
        exit_code: 1, failure_class: 'content', used_stderr_fallback: true,
        problems: [{
          severity: 'error', code: 'EFRONTMATTER', message: 'Unknown frontmatter key.', remediation: '',
          source_path: 'index.md', line: 2, column: 1, id: null, origin: 'stderr',
          position_confidence: 'best_effort', packet: 'code: EFRONTMATTER'
        }]
      })
    }
  });
  await page.getByRole('button', { name: 'Validate project', exact: true }).click();
  await expect(page.getByText(/stderr was used/)).toBeVisible();
  await expect(page.getByText('Best-effort source position', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Dirty\n');
  await expect(page.getByText(/commands read repository files from disk/)).toBeVisible();
  // Dirty buffers no longer disable commands; running one asks how to resolve the buffer.
  await page.getByRole('button', { name: 'Validate project', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
  await expect(dialog).toBeVisible();
  await expect(dialog.locator('p').first()).toContainText('Validate project');
  await dialog.getByRole('button', { name: /Discard & run/ }).click();
  await expect(dialog).toBeHidden();
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Content or graph failure (exit 1)');
  await expect(page.getByText(/stderr was used/)).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Home\n');
});

test('running a Boris command while dirty offers Cancel and Save & run (#462)', async ({ page }) => {
  await installApi(page, { commands: { validate: commandResult('validate') } });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await editor.fill('# Draft\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

  const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
  await page.getByRole('button', { name: 'Validate project', exact: true }).click();
  await expect(dialog).toBeVisible();
  await expect(dialog.locator('p').first()).toContainText('Validate project');
  await dialog.getByRole('button', { name: /Cancel/ }).click();
  await expect(dialog).toBeHidden();
  await expect(editor).toHaveValue('# Draft\n');
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('No Boris command has run yet.');

  // Save & run persists the buffer, then runs the command.
  const saveRequest = page.waitForRequest('**/api/files/save');
  const commandRequest = page.waitForRequest('**/api/commands/run');
  await page.getByRole('button', { name: 'Validate project', exact: true }).click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: /Save & run/ }).click();
  expect((await saveRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', content: '# Draft\n' });
  expect((await commandRequest).postDataJSON()).toMatchObject({ mode: 'validate' });
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Validate project finished: Success (exit 0).');
});

test('Alt+S in the resolution dialog saves and continues (#462)', async ({ page }) => {
  await installApi(page, { commands: { validate: commandResult('validate') } });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Draft\n');
  await page.getByRole('button', { name: 'Validate project', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('button', { name: /Save & run/ })).toContainText('Alt+S');
  await expect(dialog.getByRole('button', { name: /Discard & run/ })).toContainText('Alt+D');

  const saveRequest = page.waitForRequest('**/api/files/save');
  const commandRequest = page.waitForRequest('**/api/commands/run');
  await page.keyboard.press('Alt+S');
  expect((await saveRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', content: '# Draft\n' });
  expect((await commandRequest).postDataJSON()).toMatchObject({ mode: 'validate' });
  await expect(dialog).toBeHidden();
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Validate project finished: Success (exit 0).');
});

test('Alt+D in the resolution dialog discards and continues (#462)', async ({ page }) => {
  await installApi(page, { commands: { validate: commandResult('validate') } });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Draft\n');
  await page.getByRole('button', { name: 'Validate project', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
  await expect(dialog).toBeVisible();
  let saveRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/save')) saveRequests += 1;
  });
  const commandRequest = page.waitForRequest('**/api/commands/run');
  await page.keyboard.press('Alt+D');
  expect((await commandRequest).postDataJSON()).toMatchObject({ mode: 'validate' });
  expect(saveRequests).toBe(0);
  await expect(dialog).toBeHidden();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Home\n');
});

test('rebuilding the preview while dirty offers Cancel and Discard & rebuild (#462)', async ({ page }) => {
  await installApi(page, {
    previewRebuilds: [{
      phase: 'success', generation: 2, exit_code: 0, used_stderr_fallback: false,
      message: 'Preview is current from a successful Boris incremental build.',
      preview_url: 'https://preview.invalid/?token=test'
    }]
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await editor.fill('# Draft\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

  const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
  await page.getByRole('button', { name: 'Rebuild preview', exact: true }).click();
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('button', { name: /Save & rebuild/ })).toContainText('Save & rebuild');
  await dialog.getByRole('button', { name: /Cancel/ }).click();
  await expect(dialog).toBeHidden();
  await expect(editor).toHaveValue('# Draft\n');

  // Discard & rebuild drops the buffer without saving, then rebuilds.
  let saveRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/save')) saveRequests += 1;
  });
  const rebuildRequest = page.waitForRequest('**/api/preview/rebuild');
  await page.getByRole('button', { name: 'Rebuild preview', exact: true }).click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: /Discard & rebuild/ }).click();
  await rebuildRequest;
  expect(saveRequests).toBe(0);
  await expect(page.locator('.preview-state')).toContainText('Preview is current');
  await expect(page.getByTitle('Boris site preview')).toHaveAttribute('src', /generation=2/);
});

test('schema and graph completion are an ARIA combobox operable by keyboard and visible names', async ({ page }) => {
  await installApi(page, { disk: '' });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Boris authoring hints' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Refresh Boris suggestions', exact: true })).toHaveText('Refresh Boris suggestions');
  await expect(page.getByRole('button', { name: 'Insert selected completion', exact: true })).toHaveText('Insert selected completion');

  const filter = page.getByRole('combobox', { name: 'Filter frontmatter key', exact: true });
  await expect(filter).toHaveAttribute('aria-autocomplete', 'list');
  await filter.fill('sta');
  await filter.press('Enter');
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await expect(editor).toHaveValue('status: ');

  await page.getByRole('combobox', { name: 'Completion category', exact: true }).selectOption('status');
  const statusFilter = page.getByRole('combobox', { name: 'Filter status', exact: true });
  await statusFilter.fill('dra');
  await statusFilter.press('Enter');
  await expect(editor).toHaveValue('status: draft');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Inserted draft from Boris authoring vocabulary');
});

test('clicking a completion option selects without inserting; the insert action inserts exactly one token (#446)', async ({ page }) => {
  await installApi(page, { disk: '' });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await expect(editor).toHaveValue('');
  await page.getByRole('combobox', { name: 'Completion category', exact: true }).selectOption('wiki_link');
  const wiki = page.getByRole('combobox', { name: 'Filter wiki link', exact: true });
  await wiki.fill('guides');
  const option = page.getByRole('listbox', { name: 'Boris completion suggestions' }).getByRole('option', { name: /guides\/intro/ });
  await option.click();
  await expect(option).toHaveAttribute('aria-selected', 'true');
  await expect(editor).toHaveValue('');
  await page.getByRole('button', { name: 'Insert selected completion', exact: true }).click();
  await expect(editor).toHaveValue('[[guides/intro]]');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Inserted guides/intro from Boris authoring vocabulary');
  await editor.focus();
  await page.keyboard.press('Control+z');
  await expect(editor).toHaveValue('');
});

test('keyboard selection in the completion combobox inserts only the selected token once (#446)', async ({ page }) => {
  await installApi(page, {
    disk: '',
    authoring: [authoringPayload(true, [
      { id: 'guides/intro', title: 'Introduction', parent: null, role: 'trunk', status: 'published', tags: ['guide'], relations: [] },
      { id: 'guides/advanced', title: 'Advanced guides', parent: null, role: 'trunk', status: 'published', tags: ['guide'], relations: [] }
    ])]
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await page.getByRole('combobox', { name: 'Completion category', exact: true }).selectOption('wiki_link');
  const wiki = page.getByRole('combobox', { name: 'Filter wiki link', exact: true });
  await wiki.fill('guides');
  const listbox = page.getByRole('listbox', { name: 'Boris completion suggestions' });
  const first = listbox.getByRole('option', { name: /guides\/intro/ });
  await expect(first).toHaveAttribute('aria-selected', 'true');
  await expect(editor).toHaveValue('');
  await wiki.press('ArrowDown');
  const second = listbox.getByRole('option', { name: /guides\/advanced/ });
  await expect(second).toHaveAttribute('aria-selected', 'true');
  await expect(first).not.toHaveAttribute('aria-selected', 'true');
  await expect(editor).toHaveValue('');
  await wiki.press('Enter');
  await expect(editor).toHaveValue('[[guides/advanced]]');
  await editor.focus();
  await page.keyboard.press('Control+z');
  await expect(editor).toHaveValue('');
});

test('completion categories match Boris artifacts and refresh after a successful graph build', async ({ page }) => {
  await installApi(page, {
    disk: '',
    authoring: [authoringPayload(false), authoringPayload(true)],
    commands: { ir_build: commandResult('ir_build') }
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByText('Frontmatter schema ready. Build diagnostics to create graph completion data.')).toBeVisible();
  await page.getByRole('button', { name: 'Build diagnostics', exact: true }).click();
  await expect(page.getByText('Boris completion index ready from boris/0.8.1.')).toBeVisible();
  await page.getByRole('combobox', { name: 'Completion category', exact: true }).selectOption('wiki_link');
  const wiki = page.getByRole('combobox', { name: 'Filter wiki link', exact: true });
  await wiki.fill('guides');
  const listbox = page.getByRole('listbox', { name: 'Boris completion suggestions' });
  await expect(listbox.getByRole('option', { name: /guides\/intro/ })).toBeVisible();
  await wiki.press('Enter');
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('[[guides/intro]]');
});

test('the completion combobox shows arrow, Enter, and Esc key hints (#462)', async ({ page }) => {
  await installApi(page, { disk: '' });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const filter = page.getByRole('combobox', { name: 'Filter frontmatter key', exact: true });
  const hint = page.locator('.combobox-wrap .key-hint');
  await expect(hint).toBeVisible();
  await expect(hint).toContainText('navigate');
  await expect(hint).toContainText('insert');
  await expect(hint).toContainText('close');
  await expect(hint).toContainText('↑');
  await filter.focus();
  const listbox = page.getByRole('listbox', { name: 'Boris completion suggestions' });
  await expect(listbox).toBeVisible();
  await expect(filter).toHaveAttribute('aria-expanded', 'true');
  await filter.press('Escape');
  await expect(listbox).toBeHidden();
  await expect(filter).toHaveAttribute('aria-expanded', 'false');
});

test('Esc closes the completion list without clearing the filter (#462)', async ({ page }) => {
  await installApi(page, { disk: '' });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const filter = page.getByRole('combobox', { name: 'Filter frontmatter key', exact: true });
  await filter.fill('sta');
  const listbox = page.getByRole('listbox', { name: 'Boris completion suggestions' });
  await expect(listbox).toBeVisible();
  await expect(listbox.getByRole('option', { name: /status/ }).first()).toBeVisible();
  await filter.press('Escape');
  await expect(listbox).toBeHidden();
  await expect(filter).toHaveValue('sta');
  // Refocusing (after moving focus away) reopens the filtered list, and Enter still inserts.
  await page.getByRole('button', { name: 'Insert selected completion', exact: true }).focus();
  await filter.focus();
  await expect(listbox).toBeVisible();
  await expect(listbox.getByRole('option', { name: /status/ }).first()).toBeVisible();
  await filter.press('Enter');
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('status: ');
});

test('the recovery banner shows a Tab + Enter key hint for its actions (#462)', async ({ page }) => {
  await installApi(page, {
    recovery: [{ path: 'content/index.md', content: '# Recovered draft\n', fingerprint: 'a'.repeat(64) }]
  });
  const recovery = page.getByRole('complementary', { name: 'Recovered unsaved work' });
  await expect(recovery).toBeVisible();
  const hint = recovery.locator('.key-hint');
  await expect(hint).toBeVisible();
  await expect(hint).toContainText('Tab');
  await expect(hint).toContainText('Enter');
});

test('Ctrl+K opens the command palette; filtering and arrows select a file to open (#462)', async ({ page }) => {
  await installApi(page);
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  await expect(palette).toBeVisible();
  const input = palette.getByRole('combobox', { name: 'Filter commands' });
  await expect(input).toBeFocused();

  await input.fill('open');
  const listbox = palette.getByRole('listbox', { name: 'Boris commands' });
  const openOptions = listbox.getByRole('option', { name: /Open file/ });
  await expect(openOptions).toHaveCount(2);
  await expect(openOptions.first()).toHaveAttribute('aria-selected', 'true');
  await input.press('ArrowDown');
  await expect(openOptions.nth(1)).toHaveAttribute('aria-selected', 'true');
  await input.press('Enter');
  await expect(palette).toBeHidden();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
});

test('the command palette reuses the file dialogs and Esc closes it (#462)', async ({ page }) => {
  await installApi(page);
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  await expect(palette).toBeVisible();
  const input = palette.getByRole('combobox', { name: 'Filter commands' });

  // The first command (Create file) executes the existing create dialog.
  await input.press('Enter');
  const create = page.getByRole('dialog', { name: 'Create file' });
  await expect(create).toBeVisible();
  await expect(palette).toBeHidden();
  await page.keyboard.press('Escape');
  await expect(create).toBeHidden();

  // Esc closes the palette directly.
  await page.keyboard.press('Control+K');
  await expect(palette).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(palette).toBeHidden();
});

test('the command palette disables guarded actions while dirty and opens files through the resolution dialog (#462)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Draft\n');
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  const listbox = palette.getByRole('listbox', { name: 'Boris commands' });
  const options = listbox.locator('[role="option"]');
  await expect(options.filter({ hasText: 'Create file' })).toHaveAttribute('aria-disabled', 'true');
  await expect(options.filter({ hasText: 'Rename file' })).toHaveAttribute('aria-disabled', 'true');
  await expect(options.filter({ hasText: 'Delete file' })).toHaveAttribute('aria-disabled', 'true');
  await expect(options.filter({ hasText: 'Open file' }).first()).toHaveAttribute('aria-disabled', 'false');

  // Open entries stay usable: Enter on the selected entry asks how to resolve the buffer.
  const input = palette.getByRole('combobox', { name: 'Filter commands' });
  await input.fill('open');
  await input.press('Enter');
  const resolution = page.getByRole('dialog', { name: 'Unsaved changes' });
  await expect(resolution).toBeVisible();
  await expect(resolution.getByRole('button', { name: /Save & switch/ })).toBeVisible();
  await resolution.getByRole('button', { name: /Cancel/ }).click();
  await expect(resolution).toBeHidden();
});

test('the Ctrl+K palette runs Boris commands (#462)', async ({ page }) => {
  await installApi(page, {
    commands: { validate: commandResult('validate', { exit_code: 2, failure_class: 'usage' }) }
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  const input = palette.getByRole('combobox', { name: 'Filter commands' });
  await input.fill('validate');
  const commandRequest = page.waitForRequest('**/api/commands/run');
  await input.press('Enter');
  expect((await commandRequest).postDataJSON()).toMatchObject({ mode: 'validate' });
  await expect(palette).toBeHidden();
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Usage or configuration failure (exit 2)');
});

test('the Ctrl+K palette saves the dirty buffer (#462)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Draft\n');
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  const input = palette.getByRole('combobox', { name: 'Filter commands' });
  await input.fill('save');
  const saveRequest = page.waitForRequest('**/api/files/save');
  await input.press('Enter');
  expect((await saveRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', content: '# Draft\n' });
  await expect(palette).toBeHidden();
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();
});

test('the Ctrl+K palette focuses the Source pane editor (#462)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  const input = palette.getByRole('combobox', { name: 'Filter commands' });
  await input.fill('focus source');
  await input.press('Enter');
  await expect(palette).toBeHidden();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeFocused();
});

test('the palette marks editor commands by their enabled state (#462)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  const options = palette.locator('[role="option"]');
  await expect(options.filter({ hasText: 'Save file' })).toHaveAttribute('aria-disabled', 'true');
  await expect(options.filter({ hasText: 'Validate project' })).toHaveAttribute('aria-disabled', 'false');
  await expect(options.filter({ hasText: 'Rebuild preview' })).toHaveAttribute('aria-disabled', 'false');
  await expect(options.filter({ hasText: 'Focus source pane' })).toHaveAttribute('aria-disabled', 'false');
});

test('explicit save rebuilds and reloads the real-output preview by keyboard', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Saved preview\n');
  const rebuild = page.waitForRequest('**/api/preview/rebuild');
  await page.getByRole('button', { name: 'Save file', exact: true }).focus();
  await page.keyboard.press('Enter');
  await rebuild;
  await expect(page.locator('.preview-state')).toContainText('Preview is current');
  await expect(page.getByTitle('Boris site preview')).toHaveAttribute('src', /generation=1/);
  await expect(page.getByRole('link', { name: 'Open preview in new tab', exact: true })).toHaveText('Open preview in new tab');
});

test('failed rebuild keeps last output and labels it stale with stderr fallback', async ({ page }) => {
  await installApi(page, {
    previewRebuilds: [{
      phase: 'stale', generation: 7, exit_code: 1, used_stderr_fallback: true,
      message: 'error: EFRONTMATTER: index.md:1:1: invalid field; last valid output is stale.',
      preview_url: 'https://preview.invalid/?token=test'
    }]
  });
  const rebuild = page.getByRole('button', { name: 'Rebuild preview', exact: true });
  await expect(rebuild).toHaveText('Rebuild preview');
  await rebuild.focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('.preview-state')).toContainText('last valid output is stale');
  await expect(page.getByText(/bounded Boris stderr/)).toBeVisible();
  await expect(page.getByTitle('Boris site preview')).toHaveAttribute('src', /generation=7/);
});

test.describe('keyboard hints conformance sweep (#462)', () => {
  test('resolution dialog: Esc cancels and Alt+S / Alt+D resolve a file switch', async ({ page }) => {
    await installApi(page);
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
    await editor.fill('# Draft\n');
    await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

    // Esc cancels: dialog closes, buffer and file stay put.
    const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
    await page.getByRole('button', { name: 'boris.json', exact: true }).click();
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('button', { name: /Save & switch/ })).toContainText('Alt+S');
    await expect(dialog.getByRole('button', { name: /Discard & switch/ })).toContainText('Alt+D');
    await page.keyboard.press('Escape');
    await expect(dialog).toBeHidden();
    await expect(editor).toHaveValue('# Draft\n');
    await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();

    // Alt+S saves the buffer, then switches.
    const saveRequest = page.waitForRequest('**/api/files/save');
    const openRequest = page.waitForRequest('**/api/files/open');
    await page.getByRole('button', { name: 'boris.json', exact: true }).click();
    await page.keyboard.press('Alt+S');
    expect((await saveRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', content: '# Draft\n' });
    expect((await openRequest).postDataJSON()).toMatchObject({ path: 'boris.json' });
    await expect(page.getByRole('textbox', { name: 'Source for boris.json' })).toBeVisible();

    // Alt+D discards the new buffer without saving, then switches back.
    const jsonEditor = page.getByRole('textbox', { name: 'Source for boris.json' });
    await jsonEditor.fill('# JSON draft\n');
    await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
    let saveRequests = 0;
    page.on('request', request => {
      if (request.url().includes('/api/files/save')) saveRequests += 1;
    });
    const backRequest = page.waitForRequest('**/api/files/open');
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await page.keyboard.press('Alt+D');
    expect((await backRequest).postDataJSON()).toMatchObject({ path: 'content/index.md' });
    expect(saveRequests).toBe(0);
    await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
  });

  test('create and rename dialogs: Enter submits and Esc cancels', async ({ page }) => {
    await installApi(page);
    let createRequests = 0;
    let renameRequests = 0;
    page.on('request', request => {
      if (request.url().includes('/api/files/create')) createRequests += 1;
      if (request.url().includes('/api/files/rename')) renameRequests += 1;
    });

    const create = page.getByRole('dialog', { name: 'Create file' });
    await page.getByRole('button', { name: 'Create file', exact: true }).click();
    await expect(create).toBeVisible();
    await expect(create.getByRole('button', { name: /Create file/ })).toContainText('Enter');
    await expect(create.getByRole('button', { name: /Cancel/ })).toContainText('Esc');
    await create.getByRole('textbox', { name: 'New file path' }).fill('content/posts/sweep.md');
    await page.keyboard.press('Enter');
    await expect(create).toBeHidden();
    expect(createRequests).toBe(1);
    await page.getByRole('button', { name: 'Create file', exact: true }).click();
    await page.keyboard.press('Escape');
    await expect(create).toBeHidden();
    expect(createRequests).toBe(1);

    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    const rename = page.getByRole('dialog', { name: 'Rename file' });
    await page.getByRole('button', { name: 'Rename file', exact: true }).click();
    await expect(rename).toBeVisible();
    await expect(rename.getByRole('button', { name: /Rename file/ })).toContainText('Enter');
    await expect(rename.getByRole('button', { name: /Cancel/ })).toContainText('Esc');
    await rename.getByRole('textbox', { name: 'New file path' }).fill('content/posts/sweep-renamed.md');
    await page.keyboard.press('Enter');
    await expect(rename).toBeHidden();
    expect(renameRequests).toBe(1);
    await page.getByRole('button', { name: 'Rename file', exact: true }).click();
    await page.keyboard.press('Escape');
    await expect(rename).toBeHidden();
    expect(renameRequests).toBe(1);
  });

  test('delete dialog: Enter confirms and Esc cancels', async ({ page }) => {
    await installApi(page);
    let deleteRequests = 0;
    page.on('request', request => {
      if (request.url().includes('/api/files/delete')) deleteRequests += 1;
    });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'Delete file' });
    await page.getByRole('button', { name: 'Delete file', exact: true }).click();
    await expect(dialog).toBeVisible();
    const confirm = dialog.getByRole('button', { name: /Delete content\/index\.md/ });
    await expect(confirm).toContainText('Enter');
    await expect(dialog.getByRole('button', { name: /Cancel/ })).toContainText('Esc');
    await expect(confirm).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(dialog).toBeHidden();
    expect(deleteRequests).toBe(0);
    await page.getByRole('button', { name: 'Delete file', exact: true }).click();
    await expect(confirm).toBeFocused();
    const deleteRequest = page.waitForRequest('**/api/files/delete');
    await page.keyboard.press('Enter');
    expect((await deleteRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', confirmed: true });
    await expect(dialog).toBeHidden();
    expect(deleteRequests).toBe(1);
  });

  test('reopen contract: closing each dialog via Esc or pointer resets state and fires no stale requests', async ({ page }) => {
    await installApi(page);
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();

    type ReopenCase = {
      name: string;
      mock: MockOptions;
      staleRequest: RegExp;
      // Matching requests the close→reopen window may legitimately fire: 0 for triggerless
      // reopens, 1 for the conflict dialogs whose only reopen path is pressing Save again.
      expectedRequests: number;
      open: (page: Page) => Promise<void>;
      prime?: (page: Page) => Promise<void>;
      // The pointer close for surfaces with a Cancel/Keep-editing affordance.
      // After close, focus must return to the control that opened the dialog (#525).
      pointerClose?: (page: Page) => Promise<void>;
      reopen: (page: Page) => Promise<void>;
      assertAfterClose: (page: Page) => Promise<void>;
      assertReset: (page: Page) => Promise<void>;
    };

    let paletteTotal = 0;

    const surfaces: ReopenCase[] = [
      {
        name: 'create dialog',
        mock: {},
        staleRequest: /\/api\/files\/create/,
        expectedRequests: 0,
        open: async page => { await page.getByRole('button', { name: 'Create file', exact: true }).click(); },
        prime: async page => {
          await page.getByRole('dialog', { name: 'Create file' })
            .getByRole('textbox', { name: 'New file path' }).fill('content/posts/');
        },
        pointerClose: async page => { await page.getByRole('dialog', { name: 'Create file' }).getByRole('button', { name: /Cancel/ }).click(); },
        reopen: async page => { await page.getByRole('button', { name: 'Create file', exact: true }).click(); },
        assertAfterClose: async page => {
          await expect(page.getByRole('dialog', { name: 'Create file' })).toBeHidden();
          await expect(page.getByRole('button', { name: 'Create file', exact: true })).toBeFocused();
        },
        assertReset: async page => {
          const input = page.getByRole('dialog', { name: 'Create file' }).getByRole('textbox', { name: 'New file path' });
          await expect(input).toHaveValue('content/new-page.md');
          await expect(input).toBeFocused();
        }
      },
      {
        name: 'rename dialog',
        mock: {},
        staleRequest: /\/api\/files\/rename/,
        expectedRequests: 0,
        open: async page => { await page.getByRole('button', { name: 'Rename file', exact: true }).click(); },
        prime: async page => {
          await page.getByRole('dialog', { name: 'Rename file' })
            .getByRole('textbox', { name: 'New file path' }).fill('content/posts/renamed.md');
        },
        pointerClose: async page => { await page.getByRole('dialog', { name: 'Rename file' }).getByRole('button', { name: /Cancel/ }).click(); },
        reopen: async page => { await page.getByRole('button', { name: 'Rename file', exact: true }).click(); },
        assertAfterClose: async page => {
          await expect(page.getByRole('dialog', { name: 'Rename file' })).toBeHidden();
          await expect(page.getByRole('button', { name: 'Rename file', exact: true })).toBeFocused();
        },
        assertReset: async page => {
          const input = page.getByRole('dialog', { name: 'Rename file' }).getByRole('textbox', { name: 'New file path' });
          await expect(input).toHaveValue('content/index.md');
          await expect(input).toBeFocused();
        }
      },
      {
        name: 'delete dialog',
        mock: {},
        staleRequest: /\/api\/files\/delete/,
        expectedRequests: 0,
        open: async page => { await page.getByRole('button', { name: 'Delete file', exact: true }).click(); },
        prime: async page => {
          await expect(page.getByRole('dialog', { name: 'Delete file' }).getByRole('button', { name: /Delete content\/index\.md/ })).toBeFocused();
        },
        pointerClose: async page => { await page.getByRole('dialog', { name: 'Delete file' }).getByRole('button', { name: /Cancel/ }).click(); },
        reopen: async page => { await page.getByRole('button', { name: 'Delete file', exact: true }).click(); },
        assertAfterClose: async page => {
          await expect(page.getByRole('dialog', { name: 'Delete file' })).toBeHidden();
          await expect(page.getByRole('button', { name: 'Delete file', exact: true })).toBeFocused();
        },
        assertReset: async page => {
          await expect(page.getByRole('dialog', { name: 'Delete file' }).getByRole('button', { name: /Delete content\/index\.md/ })).toBeFocused();
        }
      },
      {
        name: 'command palette',
        mock: {},
        staleRequest: /\/api\/files\/(create|rename|delete|save|open)/,
        expectedRequests: 0,
        open: async page => {
          await page.getByRole('button', { name: 'Create file', exact: true }).focus();
          await page.keyboard.press('Control+K');
        },
        prime: async page => {
          const dialog = page.getByRole('dialog', { name: 'Commands' });
          paletteTotal = await dialog.getByRole('listbox', { name: 'Boris commands' }).getByRole('option').count();
          await dialog.getByRole('combobox', { name: 'Filter commands' }).fill('open');
          await expect(dialog.getByRole('listbox', { name: 'Boris commands' }).getByRole('option')).toHaveCount(2);
        },
        pointerClose: async page => { await page.getByRole('dialog', { name: 'Commands' }).getByRole('button', { name: /Cancel/ }).click(); },
        reopen: async page => { await page.keyboard.press('Control+K'); },
        assertAfterClose: async page => {
          await expect(page.getByRole('dialog', { name: 'Commands' })).toBeHidden();
          await expect(page.getByRole('button', { name: 'Create file', exact: true })).toBeFocused();
        },
        assertReset: async page => {
          const dialog = page.getByRole('dialog', { name: 'Commands' });
          const input = dialog.getByRole('combobox', { name: 'Filter commands' });
          await expect(input).toHaveValue('');
          await expect(input).toBeFocused();
          const options = dialog.getByRole('listbox', { name: 'Boris commands' }).getByRole('option');
          await expect(options).toHaveCount(paletteTotal);
          await expect(options.first()).toHaveAttribute('aria-selected', 'true');
        }
      },
      {
        name: 'resolution dialog',
        mock: {},
        staleRequest: /\/api\/files\/(save|open)/,
        expectedRequests: 0,
        open: async page => {
          await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Draft\n');
          await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
          await page.getByRole('button', { name: 'boris.json', exact: true }).click();
          await expect(page.getByRole('dialog', { name: 'Unsaved changes' })).toBeVisible();
        },
        pointerClose: async page => { await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: /Cancel/ }).click(); },
        reopen: async page => { await page.getByRole('button', { name: 'boris.json', exact: true }).click(); },
        assertAfterClose: async page => {
          await expect(page.getByRole('dialog', { name: 'Unsaved changes' })).toBeHidden();
          await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Draft\n');
          await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
          await expect(page.getByRole('button', { name: 'boris.json', exact: true })).toBeFocused();
        },
        assertReset: async page => {
          const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
          await expect(dialog).toBeVisible();
          await expect(dialog).toContainText('Save or discard the changes before opening boris.json?');
        }
      },
      {
        name: 'conflict dialog (external changes)',
        mock: { saveConflict: true },
        staleRequest: /\/api\/files\/save/,
        expectedRequests: 1,
        open: async page => {
          await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
          await page.getByRole('button', { name: 'Save file', exact: true }).click();
          await expect(page.getByRole('dialog', { name: 'External changes detected' })).toBeVisible();
        },
        prime: async page => {
          await expect(page.getByRole('dialog', { name: 'External changes detected' }).getByRole('button', { name: /Replace disk version/ })).toBeFocused();
        },
        pointerClose: async page => { await page.getByRole('dialog', { name: 'External changes detected' }).getByRole('button', { name: /Keep editing/ }).click(); },
        reopen: async page => { await page.getByRole('button', { name: 'Save file', exact: true }).click(); },
        assertAfterClose: async page => {
          await expect(page.getByRole('dialog', { name: 'External changes detected' })).toBeHidden();
          await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Mine\n');
          await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
          await expect(page.getByRole('button', { name: 'Save file', exact: true })).toBeFocused();
        },
        assertReset: async page => {
          const dialog = page.getByRole('dialog', { name: 'External changes detected' });
          await expect(dialog).toBeVisible();
          await expect(dialog.getByRole('button', { name: /Replace disk version/ })).toBeFocused();
          await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Mine\n');
        }
      },
      {
        name: 'deleted-file conflict dialog',
        mock: { saveDeleted: true },
        staleRequest: /\/api\/files\/save/,
        expectedRequests: 1,
        open: async page => {
          await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
          await page.getByRole('button', { name: 'Save file', exact: true }).click();
          await expect(page.getByRole('dialog', { name: 'File deleted outside Boris Editor' })).toBeVisible();
        },
        prime: async page => {
          await expect(page.getByRole('dialog', { name: 'File deleted outside Boris Editor' }).getByRole('button', { name: /Re-create file/ })).toBeFocused();
        },
        pointerClose: async page => { await page.getByRole('dialog', { name: 'File deleted outside Boris Editor' }).getByRole('button', { name: /Keep editing/ }).click(); },
        reopen: async page => { await page.getByRole('button', { name: 'Save file', exact: true }).click(); },
        assertAfterClose: async page => {
          await expect(page.getByRole('dialog', { name: 'File deleted outside Boris Editor' })).toBeHidden();
          await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Mine\n');
          await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
          await expect(page.getByRole('button', { name: 'Save file', exact: true })).toBeFocused();
        },
        assertReset: async page => {
          const dialog = page.getByRole('dialog', { name: 'File deleted outside Boris Editor' });
          await expect(dialog).toBeVisible();
          await expect(dialog.getByRole('button', { name: /Re-create file/ })).toBeFocused();
          await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Mine\n');
        }
      }
    ];

    const variants: Array<{ name: string; close: (surface: ReopenCase, page: Page) => Promise<void> }> = [
      { name: 'Esc', close: async (_surface, page) => { await page.keyboard.press('Escape'); } },
      { name: 'pointer close', close: async (surface, page) => { await surface.pointerClose!(page); } }
    ];

    // Surface-major so the clean-state dialogs (create/rename/delete/palette) always run
    // before the rows that leave the buffer dirty (resolution, conflict, deleted conflict).
    for (const surface of surfaces) {
      for (const variant of variants) {
        if (!surface.pointerClose && variant.name === 'pointer close') continue;
        await test.step(`${surface.name} — ${variant.name}`, async () => {
          await page.unrouteAll({ behavior: 'ignoreErrors' });
          await installApi(page, surface.mock);
          await surface.open(page);
          await surface.prime?.(page);

          let requests = 0;
          const onRequest = (request: Request) => {
            if (surface.staleRequest.test(request.url())) requests += 1;
          };
          page.on('request', onRequest);

          await variant.close(surface, page);
          await surface.assertAfterClose(page);
          await surface.reopen(page);
          await surface.assertReset(page);
          expect(requests).toBe(surface.expectedRequests);

          page.off('request', onRequest);
          await page.keyboard.press('Escape');
        });
      }
    }
  });

  test('conflict dialog: Esc keeps editing and Enter replaces the disk version', async ({ page }) => {
    await installApi(page, { saveConflict: true });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
    await editor.fill('# Mine\n');
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'External changes detected' });
    await expect(dialog).toBeVisible();
    const primary = dialog.getByRole('button', { name: /Replace disk version/ });
    await expect(dialog.getByRole('button', { name: /Keep editing/ })).toContainText('Esc');
    await expect(primary).toContainText('Enter');
    await expect(primary).toBeFocused();

    // Esc keeps editing: dialog closes, the unsaved buffer survives.
    await page.keyboard.press('Escape');
    await expect(dialog).toBeHidden();
    await expect(editor).toHaveValue('# Mine\n');
    await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

    // Enter replaces: a save request carrying the conflict fingerprint fires (mock keeps 409ing).
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    await expect(dialog).toBeVisible();
    const saveRequest = page.waitForRequest('**/api/files/save');
    await page.keyboard.press('Enter');
    expect((await saveRequest).postDataJSON()).toMatchObject({
      path: 'content/index.md', content: '# Mine\n', fingerprint: 'b'.repeat(64)
    });
    await expect(dialog).toBeVisible();
    await dialog.getByRole('button', { name: /Keep editing/ }).click();
    await expect(dialog).toBeHidden();
  });

  test('deleted-file conflict: Esc keeps editing, Discard changes discards, and Enter re-creates', async ({ page }) => {
    await installApi(page, { saveDeleted: true });
    let saveRequests = 0;
    page.on('request', request => {
      if (request.url().includes('/api/files/save')) saveRequests += 1;
    });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
    await editor.fill('# Mine\n');
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'File deleted outside Boris Editor' });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('textbox', { name: 'Your unsaved version' })).toHaveValue('# Mine\n');
    await expect(dialog.getByRole('button', { name: /Keep editing/ })).toContainText('Esc');
    await expect(dialog.getByRole('button', { name: /Discard changes/ })).toBeVisible();
    const recreate = dialog.getByRole('button', { name: /Re-create file/ });
    await expect(recreate).toContainText('Enter');
    await expect(recreate).toBeFocused();

    // Esc keeps editing: dialog closes, the dirty buffer survives.
    await page.keyboard.press('Escape');
    await expect(dialog).toBeHidden();
    await expect(editor).toHaveValue('# Mine\n');
    await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

    // Discard changes: Shift+Tab from the focused primary lands on it, Enter discards.
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    await expect(dialog).toBeVisible();
    await page.keyboard.press('Shift+Tab');
    await expect(dialog.getByRole('button', { name: /Discard changes/ })).toBeFocused();
    const clearRequest = page.waitForRequest('**/api/recovery/clear');
    await page.keyboard.press('Enter');
    expect((await clearRequest).postDataJSON()).toMatchObject({ path: 'content/index.md' });
    await expect(dialog).toBeHidden();
    await expect(page.getByText('No file selected', { exact: true })).toBeVisible();
    await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Discarded unsaved changes for deleted file content/index.md.');
    expect(saveRequests).toBe(2);

    // Enter re-creates: reopen, dirty the buffer, save, and confirm via Enter.
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await expect(editor).toHaveValue('# Home\n');
    await editor.fill('# Mine\n');
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    await expect(dialog).toBeVisible();
    const recreateRequest = page.waitForRequest('**/api/files/save');
    await page.keyboard.press('Enter');
    expect((await recreateRequest).postDataJSON()).toMatchObject({
      path: 'content/index.md', content: '# Mine\n', recreate: true
    });
    // The mock keeps 409ing with deleted, so the dialog stays and the buffer survives.
    await expect(dialog).toBeVisible();
    await expect(editor).toHaveValue('# Mine\n');
    await dialog.getByRole('button', { name: /Keep editing/ }).click();
    await expect(dialog).toBeHidden();
    expect(saveRequests).toBe(4);
  });

  test('command palette: Ctrl+K opens, arrows select, Enter runs, Esc closes', async ({ page }) => {
    await installApi(page);
    await expect(page.locator('footer .key-hint')).toContainText('Ctrl');
    await expect(page.locator('footer .key-hint')).toContainText('K');
    await page.keyboard.press('Control+K');
    const palette = page.getByRole('dialog', { name: 'Commands' });
    await expect(palette).toBeVisible();
    const input = palette.getByRole('combobox', { name: 'Filter commands' });
    await expect(input).toBeFocused();

    await input.fill('open');
    const listbox = palette.getByRole('listbox', { name: 'Boris commands' });
    const openOptions = listbox.getByRole('option', { name: /Open file/ });
    await expect(openOptions).toHaveCount(2);
    await expect(openOptions.first()).toHaveAttribute('aria-selected', 'true');
    await input.press('ArrowDown');
    await expect(openOptions.nth(1)).toHaveAttribute('aria-selected', 'true');
    await input.press('Enter');
    await expect(palette).toBeHidden();
    await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();

    await page.keyboard.press('Control+K');
    await expect(palette).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(palette).toBeHidden();
  });

  test('completion combobox: arrows navigate, Enter inserts, Esc closes', async ({ page }) => {
    await installApi(page, {
      disk: '',
      authoring: [authoringPayload(true, [
        { id: 'guides/intro', title: 'Introduction', parent: null, role: 'trunk', status: 'published', tags: ['guide'], relations: [] },
        { id: 'guides/advanced', title: 'Advanced guides', parent: null, role: 'trunk', status: 'published', tags: ['guide'], relations: [] }
      ])]
    });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await page.getByRole('combobox', { name: 'Completion category', exact: true }).selectOption('wiki_link');
    const filter = page.getByRole('combobox', { name: 'Filter wiki link', exact: true });
    const hint = page.locator('.combobox-wrap .key-hint');
    await expect(hint).toContainText('navigate');
    await expect(hint).toContainText('insert');
    await expect(hint).toContainText('close');
    const listbox = page.getByRole('listbox', { name: 'Boris completion suggestions' });
    await filter.fill('guides');
    await expect(listbox).toBeVisible();
    const first = listbox.getByRole('option', { name: /guides\/intro/ });
    await expect(first).toHaveAttribute('aria-selected', 'true');
    await filter.press('ArrowDown');
    await expect(listbox.getByRole('option', { name: /guides\/advanced/ })).toHaveAttribute('aria-selected', 'true');
    await expect(first).not.toHaveAttribute('aria-selected', 'true');
    await filter.press('ArrowUp');
    await expect(first).toHaveAttribute('aria-selected', 'true');
    await filter.press('Enter');
    await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('[[guides/intro]]');

    await filter.fill('guides');
    await expect(listbox).toBeVisible();
    await filter.press('Escape');
    await expect(listbox).toBeHidden();
    await expect(filter).toHaveValue('guides');
  });

  test('recovery banner: Tab + Enter runs Restore and Discard', async ({ page }) => {
    await installApi(page, {
      recovery: [
        { path: 'content/index.md', content: '# Recovered draft\n', fingerprint: 'a'.repeat(64) },
        { path: 'content/guides/getting-started.md', content: '# Recovered guide\n', fingerprint: 'a'.repeat(64) }
      ]
    });
    const recovery = page.getByRole('complementary', { name: 'Recovered unsaved work' });
    await expect(recovery).toBeVisible();
    const hint = recovery.locator('.key-hint');
    await expect(hint).toBeVisible();
    await expect(hint).toContainText('Tab');
    await expect(hint).toContainText('Enter');

    // Enter runs Discard: the snapshot's clear request fires and its row leaves the banner.
    const discard = recovery.getByRole('button', { name: 'Discard recovery for content/guides/getting-started.md', exact: true });
    const clearRequest = page.waitForRequest('**/api/recovery/clear');
    await discard.focus();
    await page.keyboard.press('Enter');
    expect((await clearRequest).postDataJSON()).toMatchObject({ path: 'content/guides/getting-started.md' });
    await expect(recovery.getByRole('button', { name: /getting-started/ })).toHaveCount(0);

    // Enter runs Restore: the recovered content lands in the editor.
    const restore = recovery.getByRole('button', { name: 'Restore content/index.md', exact: true });
    await restore.focus();
    await page.keyboard.press('Enter');
    await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Recovered draft\n');
    await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Recovered unsaved work for content/index.md.');
  });

  test('recovery banner: Enter on Restore while dirty routes through the resolution dialog', async ({ page }) => {
    await installApi(page, {
      recovery: [{ path: 'content/guides/getting-started.md', content: '# Recovered guide\n', fingerprint: 'a'.repeat(64) }]
    });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
    await editor.fill('# Draft\n');
    await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

    const recovery = page.getByRole('complementary', { name: 'Recovered unsaved work' });
    const restore = recovery.getByRole('button', { name: 'Restore content/guides/getting-started.md', exact: true });
    await restore.focus();
    await page.keyboard.press('Enter');
    const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('button', { name: /Save & restore/ })).toContainText('Alt+S');
    await expect(dialog.getByRole('button', { name: /Discard & restore/ })).toContainText('Alt+D');

    // Alt+D discards the buffer without saving, then the recovered content is restored.
    let saveRequests = 0;
    page.on('request', request => {
      if (request.url().includes('/api/files/save')) saveRequests += 1;
    });
    const openRequest = page.waitForRequest('**/api/files/open');
    await page.keyboard.press('Alt+D');
    expect((await openRequest).postDataJSON()).toMatchObject({ path: 'content/guides/getting-started.md' });
    expect(saveRequests).toBe(0);
    await expect(page.getByRole('textbox', { name: 'Source for content/guides/getting-started.md' })).toHaveValue('# Recovered guide\n');
  });

  test('secondary dialog actions carry visible key hints (#526)', async ({ page }) => {
    await installApi(page);
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Draft\n');
    await page.getByRole('button', { name: 'boris.json', exact: true }).click();
    const resolution = page.getByRole('dialog', { name: 'Unsaved changes' });
    await expect(resolution.getByRole('button', { name: /Cancel/ })).toContainText('Esc');
    await resolution.getByRole('button', { name: /Cancel/ }).click();

    await installApi(page, { saveConflict: true });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    const conflict = page.getByRole('dialog', { name: 'External changes detected' });
    await expect(conflict.getByRole('button', { name: /Load disk version/ })).toContainText('Alt+L');
    await conflict.getByRole('button', { name: /Keep editing/ }).click();

    await installApi(page, { saveDeleted: true });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    const deleted = page.getByRole('dialog', { name: 'File deleted outside Boris Editor' });
    await expect(deleted.getByRole('button', { name: /Discard changes/ })).toContainText('Alt+D');
  });

  test('Alt+L loads the disk version in the conflict dialog (#526)', async ({ page }) => {
    await installApi(page, { saveConflict: true });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
    await page.getByRole('button', { name: 'Save file', exact: true }).click();
    const dialog = page.getByRole('dialog', { name: 'External changes detected' });
    await expect(dialog).toBeVisible();
    await page.keyboard.press('Alt+L');
    await expect(dialog).toBeHidden();
    await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Changed elsewhere\n');
  });

  test('closed dialogs do not expose duplicate action names to the accessibility tree (#464)', async ({ page }) => {
    await installApi(page);
    await expect(page.getByRole('button', { name: 'Create file', exact: true })).toHaveCount(1);
    await expect(page.getByRole('button', { name: 'Rename file', exact: true })).toHaveCount(1);
    await expect(page.getByRole('button', { name: 'Delete file', exact: true })).toHaveCount(1);
    await expect(page.getByRole('button', { name: /Cancel/ })).toHaveCount(0);

    await page.getByRole('button', { name: 'Create file', exact: true }).click();
    const create = page.getByRole('dialog', { name: 'Create file' });
    await expect(create).toBeVisible();
    // Closed dialogs stay out of the tree: only the open dialog exposes Cancel.
    // The dialog primary is "Create file Enter", so it does not collide with the
    // toolbar's exact name. Native showModal inerts the background for Voice
    // Control; Playwright still lists the toolbar trigger.
    await expect(page.getByRole('button', { name: /Cancel/ })).toHaveCount(1);
    await expect(create.getByRole('button', { name: /Cancel/ })).toBeVisible();
    await expect(create.getByRole('button', { name: /Create file/ })).toHaveCount(1);
    await expect(page.getByRole('button', { name: 'Create file', exact: true })).toHaveCount(1);
    await page.keyboard.press('Escape');
    await expect(create).toBeHidden();
    await expect(page.getByRole('button', { name: 'Create file', exact: true })).toHaveCount(1);
    await expect(page.getByRole('button', { name: /Cancel/ })).toHaveCount(0);
  });

  test.describe('pointer conformance', () => {
    test('resolution dialog: clicking Save & switch matches Alt+S and Cancel matches Esc', async ({ page }) => {
      await installApi(page);
      await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
      const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
      await editor.fill('# Draft\n');
      await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

      const dialog = page.getByRole('dialog', { name: 'Unsaved changes' });
      await page.getByRole('button', { name: 'boris.json', exact: true }).click();
      await expect(dialog).toBeVisible();
      // Cancel click matches Esc: dialog closes, buffer and file stay put.
      await dialog.getByRole('button', { name: /Cancel/ }).click();
      await expect(dialog).toBeHidden();
      await expect(editor).toHaveValue('# Draft\n');
      await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();

      // Save & switch click matches Alt+S: the buffer is saved, then the target opens.
      const saveRequest = page.waitForRequest('**/api/files/save');
      const openRequest = page.waitForRequest('**/api/files/open');
      await page.getByRole('button', { name: 'boris.json', exact: true }).click();
      await dialog.getByRole('button', { name: /Save & switch/ }).click();
      expect((await saveRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', content: '# Draft\n' });
      expect((await openRequest).postDataJSON()).toMatchObject({ path: 'boris.json' });
      await expect(page.getByRole('textbox', { name: 'Source for boris.json' })).toBeVisible();
    });

    test('create and rename dialogs: clicking the primary matches Enter and Cancel matches Esc', async ({ page }) => {
      await installApi(page);
      let createRequests = 0;
      let renameRequests = 0;
      page.on('request', request => {
        if (request.url().includes('/api/files/create')) createRequests += 1;
        if (request.url().includes('/api/files/rename')) renameRequests += 1;
      });

      const create = page.getByRole('dialog', { name: 'Create file' });
      await page.getByRole('button', { name: 'Create file', exact: true }).click();
      await expect(create).toBeVisible();
      await create.getByRole('button', { name: /Cancel/ }).click();
      await expect(create).toBeHidden();
      expect(createRequests).toBe(0);
      await page.getByRole('button', { name: 'Create file', exact: true }).click();
      await create.getByRole('textbox', { name: 'New file path' }).fill('content/posts/pointer.md');
      await create.getByRole('button', { name: /Create file/ }).click();
      await expect(create).toBeHidden();
      expect(createRequests).toBe(1);

      await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
      const rename = page.getByRole('dialog', { name: 'Rename file' });
      await page.getByRole('button', { name: 'Rename file', exact: true }).click();
      await expect(rename).toBeVisible();
      await rename.getByRole('button', { name: /Cancel/ }).click();
      await expect(rename).toBeHidden();
      expect(renameRequests).toBe(0);
      await page.getByRole('button', { name: 'Rename file', exact: true }).click();
      await rename.getByRole('textbox', { name: 'New file path' }).fill('content/posts/pointer-renamed.md');
      await rename.getByRole('button', { name: /Rename file/ }).click();
      await expect(rename).toBeHidden();
      expect(renameRequests).toBe(1);
    });

    test('delete dialog: clicking the danger button matches Enter and Cancel matches Esc', async ({ page }) => {
      await installApi(page);
      let deleteRequests = 0;
      page.on('request', request => {
        if (request.url().includes('/api/files/delete')) deleteRequests += 1;
      });
      await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
      const dialog = page.getByRole('dialog', { name: 'Delete file' });
      await page.getByRole('button', { name: 'Delete file', exact: true }).click();
      await expect(dialog).toBeVisible();
      await dialog.getByRole('button', { name: /Cancel/ }).click();
      await expect(dialog).toBeHidden();
      expect(deleteRequests).toBe(0);
      await page.getByRole('button', { name: 'Delete file', exact: true }).click();
      const deleteRequest = page.waitForRequest('**/api/files/delete');
      await dialog.getByRole('button', { name: /Delete content\/index\.md/ }).click();
      expect((await deleteRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', confirmed: true });
      await expect(dialog).toBeHidden();
      expect(deleteRequests).toBe(1);
    });

    test('conflict dialog: clicking Replace disk version matches Enter and Keep editing matches Esc', async ({ page }) => {
      await installApi(page, { saveConflict: true });
      await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
      const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
      await editor.fill('# Mine\n');
      await page.getByRole('button', { name: 'Save file', exact: true }).click();
      const dialog = page.getByRole('dialog', { name: 'External changes detected' });
      await expect(dialog).toBeVisible();

      // Keep editing click matches Esc: dialog closes, the unsaved buffer survives.
      await dialog.getByRole('button', { name: /Keep editing/ }).click();
      await expect(dialog).toBeHidden();
      await expect(editor).toHaveValue('# Mine\n');
      await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

      // Replace disk version click matches Enter: a retry save with the conflict fingerprint fires.
      await page.getByRole('button', { name: 'Save file', exact: true }).click();
      await expect(dialog).toBeVisible();
      const saveRequest = page.waitForRequest('**/api/files/save');
      await dialog.getByRole('button', { name: /Replace disk version/ }).click();
      expect((await saveRequest).postDataJSON()).toMatchObject({
        path: 'content/index.md', content: '# Mine\n', fingerprint: 'b'.repeat(64)
      });
      await expect(dialog).toBeVisible();
      await dialog.getByRole('button', { name: /Keep editing/ }).click();
      await expect(dialog).toBeHidden();
    });

    test('deleted-file conflict: clicking Re-create file matches Enter', async ({ page }) => {
      await installApi(page, { saveDeletedOnce: true });
      await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
      const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
      await editor.fill('# Mine\n');
      await page.getByRole('button', { name: 'Save file', exact: true }).click();
      const dialog = page.getByRole('dialog', { name: 'File deleted outside Boris Editor' });
      await expect(dialog).toBeVisible();
      await expect(dialog.getByRole('textbox', { name: 'Your unsaved version' })).toHaveValue('# Mine\n');
      const recreateRequest = page.waitForRequest('**/api/files/save');
      await dialog.getByRole('button', { name: /Re-create file/ }).click();
      expect((await recreateRequest).postDataJSON()).toMatchObject({
        path: 'content/index.md', content: '# Mine\n', recreate: true
      });
      await expect(dialog).toBeHidden();
      await expect(editor).toHaveValue('# Mine\n');
      await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Saved content/index.md.');
      await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();
    });

    test('deleted-file conflict: clicking Discard changes discards the buffer', async ({ page }) => {
      await installApi(page, { saveDeleted: true });
      let saveRequests = 0;
      page.on('request', request => {
        if (request.url().includes('/api/files/save')) saveRequests += 1;
      });
      await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
      const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
      await editor.fill('# Mine\n');
      await page.getByRole('button', { name: 'Save file', exact: true }).click();
      const dialog = page.getByRole('dialog', { name: 'File deleted outside Boris Editor' });
      await expect(dialog).toBeVisible();
      const clearRequest = page.waitForRequest('**/api/recovery/clear');
      await dialog.getByRole('button', { name: /Discard changes/ }).click();
      expect((await clearRequest).postDataJSON()).toMatchObject({ path: 'content/index.md' });
      await expect(dialog).toBeHidden();
      await expect(page.getByText('No file selected', { exact: true })).toBeVisible();
      await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Discarded unsaved changes for deleted file content/index.md.');
      expect(saveRequests).toBe(1);
    });

    test('command palette: Cancel and backdrop click dismiss without running an action (#527)', async ({ page }) => {
      await installApi(page);
      let createRequests = 0;
      page.on('request', request => {
        if (request.url().includes('/api/files/create')) createRequests += 1;
      });
      await page.getByRole('button', { name: 'Create file', exact: true }).focus();
      await page.keyboard.press('Control+K');
      const palette = page.getByRole('dialog', { name: 'Commands' });
      await expect(palette).toBeVisible();
      await expect(palette.getByRole('button', { name: /Cancel/ })).toContainText('Esc');
      await palette.getByRole('button', { name: /Cancel/ }).click();
      await expect(palette).toBeHidden();
      await expect(page.getByRole('button', { name: 'Create file', exact: true })).toBeFocused();
      expect(createRequests).toBe(0);

      await page.keyboard.press('Control+K');
      await expect(palette).toBeVisible();
      const box = await palette.boundingBox();
      expect(box).not.toBeNull();
      await page.mouse.click(Math.max(8, box!.x - 16), Math.max(8, box!.y - 16));
      await expect(palette).toBeHidden();
      expect(createRequests).toBe(0);
    });

    test('command palette: clicking an option matches Enter', async ({ page }) => {
      await installApi(page);
      await page.keyboard.press('Control+K');
      const palette = page.getByRole('dialog', { name: 'Commands' });
      await expect(palette).toBeVisible();
      const input = palette.getByRole('combobox', { name: 'Filter commands' });
      await input.fill('open');
      const listbox = palette.getByRole('listbox', { name: 'Boris commands' });
      await listbox.getByRole('option', { name: /content\/index\.md/ }).click();
      await expect(palette).toBeHidden();
      await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
    });

    test('recovery banner: clicking Restore and Discard matches Enter', async ({ page }) => {
      await installApi(page, {
        recovery: [
          { path: 'content/index.md', content: '# Recovered draft\n', fingerprint: 'a'.repeat(64) },
          { path: 'content/guides/getting-started.md', content: '# Recovered guide\n', fingerprint: 'a'.repeat(64) }
        ]
      });
      const recovery = page.getByRole('complementary', { name: 'Recovered unsaved work' });
      await expect(recovery).toBeVisible();
      const clearRequest = page.waitForRequest('**/api/recovery/clear');
      await recovery.getByRole('button', { name: 'Discard recovery for content/guides/getting-started.md', exact: true }).click();
      expect((await clearRequest).postDataJSON()).toMatchObject({ path: 'content/guides/getting-started.md' });
      await expect(recovery.getByRole('button', { name: /getting-started/ })).toHaveCount(0);
      await recovery.getByRole('button', { name: 'Restore content/index.md', exact: true }).click();
      await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Recovered draft\n');
    });
  });
});

const graphFiles = [
  { path: 'boris.json' },
  { path: 'content/index.md' },
  { path: 'content/guides/intro.md' },
  { path: 'content/guides/intro-tips.md' }
];

test('graph inspector is a read-only view of Boris graph.json (#418 M6)', async ({ page }) => {
  await installApi(page, { files: graphFiles });
  await expect(page.getByRole('status', { name: 'Graph status' })).toContainText('Boris graph ready (3 pages).');
  await page.getByRole('button', { name: 'content/guides/intro-tips.md', exact: true }).click();
  const graph = page.locator('#graph');
  await expect(graph).toContainText('guides/intro-tips · Intro Tips · satellite');
  await expect(graph.getByRole('button', { name: 'Go to parent guides/intro', exact: true })).toBeVisible();
  await expect(graph.getByRole('button', { name: 'Run impact on guides/intro-tips', exact: true })).toBeVisible();
  await expect(graph.getByRole('button', { name: /Go to backlink parent ← guides\/intro-tips/ })).toHaveCount(0);

  const openRequest = page.waitForRequest('**/api/files/open');
  await graph.getByRole('button', { name: 'Go to parent guides/intro', exact: true }).focus();
  await page.keyboard.press('Enter');
  expect((await openRequest).postDataJSON()).toMatchObject({ path: 'content/guides/intro.md' });
  await expect(page.getByRole('textbox', { name: 'Source for content/guides/intro.md' })).toBeVisible();
  await expect(graph.getByRole('button', { name: /Go to child guides\/intro-tips/ })).toBeVisible();
  await expect(graph.getByRole('button', { name: /Go to backlink parent ← guides\/intro-tips/ })).toBeVisible();
  await expect(graph.getByRole('button', { name: /Go to backlink reference ← index/ })).toBeVisible();
});

test('wiki-link tokens in the buffer resolve through the Boris graph (#418 M6)', async ({ page }) => {
  await installApi(page, { files: graphFiles, disk: 'See [[guides/intro]] and [[missing-page]].\n' });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const graph = page.locator('#graph');
  await expect(graph.getByRole('button', { name: 'Go to wiki link guides/intro', exact: true })).toBeVisible();
  await expect(graph.getByText('Unresolved wiki link missing-page')).toBeVisible();
  const openRequest = page.waitForRequest('**/api/files/open');
  await graph.getByRole('button', { name: 'Go to wiki link guides/intro', exact: true }).focus();
  await page.keyboard.press('Enter');
  expect((await openRequest).postDataJSON()).toMatchObject({ path: 'content/guides/intro.md' });
});

test('the command palette jumps to a graph entity by title (#418 M6)', async ({ page }) => {
  await installApi(page, { files: graphFiles });
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  const input = palette.getByRole('combobox', { name: 'Filter commands' });
  await input.fill('Introduction');
  const option = palette.getByRole('listbox', { name: 'Boris commands' }).getByRole('option', { name: /Go to guides\/intro/ });
  await expect(option).toContainText('Introduction');
  const openRequest = page.waitForRequest('**/api/files/open');
  await input.press('Enter');
  expect((await openRequest).postDataJSON()).toMatchObject({ path: 'content/guides/intro.md' });
  await expect(page.getByRole('textbox', { name: 'Source for content/guides/intro.md' })).toBeVisible();
});

test('Run impact on this page uses the current graph entity (#418 M6)', async ({ page }) => {
  await installApi(page, {
    files: graphFiles,
    commands: { impact: commandResult('impact', { impact: [{ endpoint_type: 'page', value: 'guides/intro' }] }) }
  });
  await page.getByRole('button', { name: 'content/guides/intro.md', exact: true }).click();
  const request = page.waitForRequest('**/api/commands/run');
  await page.getByRole('button', { name: 'Run impact on guides/intro', exact: true }).focus();
  await page.keyboard.press('Enter');
  expect((await request).postDataJSON()).toMatchObject({ mode: 'impact', impact_id: 'guides/intro' });
  await expect(page.getByRole('heading', { name: 'Impact results' })).toBeVisible();
  await expect(page.getByText('page: guides/intro')).toBeVisible();
});

test('Cooklang trees expose a read-only recipe facet and recipeRef navigation (#418 M7)', async ({ page }) => {
  const cookGraph = graphPayload();
  const graph = cookGraph.graph as {
    nodes: Array<Record<string, unknown>>;
  };
  graph.nodes[0] = {
    ...graph.nodes[0],
    id: 'carbonara',
    sourcePath: 'carbonara.cook',
    title: 'Spaghetti Carbonara',
    recipe: {
      ingredients: [
        { name: 'spaghetti', quantity: { amount: '400', unit: 'g' }, preparation: '', recipeRef: null },
        { name: 'pepper-oil', quantity: { amount: '1', unit: 'tbsp' }, preparation: '', recipeRef: 'sauces/pepper-oil' }
      ],
      cookware: [{ name: 'large pot', quantity: { amount: '', unit: '' } }],
      timers: [{ name: 'pasta', quantity: { amount: '9', unit: 'minutes' } }]
    }
  };
  graph.nodes.push({
    index: 3, id: 'sauces/pepper-oil', sourcePath: 'sauces/pepper-oil.cook', role: 'satellite',
    parent: 'index', parentIndex: 2, title: 'Pepper oil', status: 'published', tags: [], bodyOffset: 20,
    recipe: { ingredients: [], cookware: [], timers: [] }
  });
  await installApi(page, {
    inputMode: 'cooklang',
    files: [
      { path: 'boris.json' },
      { path: 'content/carbonara.cook' },
      { path: 'content/sauces/pepper-oil.cook' }
    ],
    graph: [cookGraph]
  });
  await expect(page.getByText(/Cooklang tree/)).toBeVisible();
  await page.getByRole('button', { name: 'Create file', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Create file' }).getByRole('textbox', { name: 'New file path' })).toHaveValue('content/new-recipe.cook');
  await page.keyboard.press('Escape');

  await page.getByRole('button', { name: 'content/carbonara.cook', exact: true }).click();
  const recipe = page.locator('.recipe-pane');
  await expect(recipe.getByRole('heading', { name: 'Recipe' })).toBeVisible();
  await expect(recipe).toContainText('spaghetti');
  await expect(recipe).toContainText('400 g');
  await expect(recipe.getByRole('button', { name: 'Print this recipe', exact: true })).toBeVisible();
  await expect(recipe).toContainText('Scaling is not available');
  const openRequest = page.waitForRequest('**/api/files/open');
  await recipe.getByRole('button', { name: 'Go to recipe sauces/pepper-oil', exact: true }).focus();
  await page.keyboard.press('Enter');
  expect((await openRequest).postDataJSON()).toMatchObject({ path: 'content/sauces/pepper-oil.cook' });
});

test('.cook graph diagnostics are labeled position-approximate (#418 M7)', async ({ page }) => {
  await installApi(page, {
    inputMode: 'cooklang',
    files: [{ path: 'content/carbonara.cook' }],
    commands: {
      ir_build: commandResult('ir_build', {
        exit_code: 1, failure_class: 'content',
        problems: [{
          severity: 'error', code: 'EREFERENCEMISSING', message: 'Missing recipe.', remediation: '',
          source_path: 'carbonara.cook', line: 4, column: 1, id: null, origin: 'build_report',
          position_confidence: 'best_effort', packet: 'code: EREFERENCEMISSING'
        }]
      })
    }
  });
  await page.getByRole('button', { name: 'Build diagnostics', exact: true }).click();
  await expect(page.getByText('Position approximate: graph diagnostic on adapted Markdown, not the .cook line')).toBeVisible();
});

test('theme layouts list closed slots and preview widths are named (#418 M8)', async ({ page }) => {
  await installApi(page, {
    files: [
      { path: 'boris.json' },
      { path: 'content/index.md' },
      { path: 'themes/boris/layouts/main.html' },
      { path: 'themes/boris/assets/css/site.css' }
    ],
    disk: '<html><body>{{title}}{{content}}{{nav}}</body></html>\n',
    commands: {
      html_build: commandResult('html_build', {
        report_version: 'html-build-report-0.1.0',
        problems: [{
          severity: 'info', code: 'ILAYOUTSELECTED', message: 'layout rule id:index selected themes/boris/layouts/main.html',
          remediation: '', source_path: 'index.md', line: 1, column: 1, id: 'index',
          origin: 'build_report', position_confidence: 'exact', packet: 'code: ILAYOUTSELECTED'
        }, {
          severity: 'info', code: 'ILAYOUTSELECTED', message: 'layout fallback selected themes/boris/layouts/main.html',
          remediation: '', source_path: 'about.md', line: 1, column: 1, id: 'about',
          origin: 'build_report', position_confidence: 'exact', packet: 'code: ILAYOUTSELECTED'
        }]
      })
    }
  });
  await page.getByRole('button', { name: 'themes/boris/layouts/main.html', exact: true }).click();
  const theme = page.locator('.theme-pane');
  await expect(theme.getByRole('heading', { name: 'Theme layout' })).toBeVisible();
  await expect(theme).toContainText('Present:');
  await expect(theme).toContainText('{{title}}');
  await expect(theme).toContainText('{{content}}');
  await expect(theme.getByRole('button', { name: 'Open themes/boris/assets/css/site.css', exact: true })).toBeVisible();
  await expect(theme).toContainText('including fallback');

  await page.getByRole('button', { name: 'Build HTML', exact: true }).click();
  await expect(theme.getByRole('button', { name: /layout rule id:index selected/ })).toBeVisible();
  await expect(theme.getByRole('button', { name: /layout fallback selected/ })).toBeVisible();

  await expect(page.getByRole('group', { name: 'Preview width' })).toBeVisible();
  await page.getByRole('radio', { name: '375px', exact: true }).check();
  await expect(page.getByRole('radio', { name: '375px', exact: true })).toBeChecked();
  await expect(page.getByText('Accessibility review aid')).toBeVisible();
  await page.getByText('Accessibility review aid').click();
  await expect(page.getByText(/does not replace Voice Control/)).toBeVisible();
});

test('graph inspector refreshes after a successful diagnostics build (#418 M6)', async ({ page }) => {
  await installApi(page, {
    graph: [graphPayload(false), graphPayload(true)],
    commands: { ir_build: commandResult('ir_build') }
  });
  await expect(page.getByRole('status', { name: 'Graph status' })).toContainText('Build diagnostics to create the Boris graph.');
  await page.getByRole('button', { name: 'Build diagnostics', exact: true }).click();
  await expect(page.getByRole('status', { name: 'Graph status' })).toContainText('Boris graph ready (3 pages).');
});

test('publication pane plans an existing profile and does not deploy (#418 M9)', async ({ page }) => {
  const plan = {
    format: 'boris-publication-plan',
    schema_version: 1,
    input: 'content',
    input_format: 'markdown',
    site: { url: 'https://owner.github.io/boris', title: 'Boris', description: null },
    publication: {
      target: 'github-pages',
      base_url: 'https://owner.github.io/boris',
      origin: 'https://owner.github.io',
      base_path: '/boris',
      site_kind: 'project-site'
    },
    targets: [{ name: 'public', output: 'dist', public: true, theme: 'themes/boris', layout: null }],
    editions: { ir: null, rag: null, context: null }
  };
  await installApi(page, {
    publication: {
      profiles: [{ path: 'boris.json' }, { path: 'standard-site.json' }],
      proof: {
        path: 'dist/_boris/proof/proof-pack.json',
        html_path: 'dist/_boris/proof/index.html',
        target: 'public',
        schema_version: '1',
        overall_presentation_status: 'verified',
        artifacts_total: 2,
        checks_total: 3,
        findings_total: 0,
        claims_total: 3
      }
    },
    commands: { plan: commandResult('plan', { publication_plan: plan }) }
  });
  const publication = page.locator('#publication');
  await expect(publication.getByRole('heading', { name: 'Publication' })).toBeVisible();
  await expect(publication.getByRole('status', { name: 'Publication status' })).toContainText('Local Proof Pack present');
  await expect(page.getByRole('combobox', { name: 'Publication profile', exact: true })).toBeVisible();
  await page.getByRole('combobox', { name: 'Publication profile', exact: true }).selectOption('boris.json');
  const run = page.getByRole('button', { name: 'Run publication plan', exact: true });
  await expect(run).toHaveText('Run publication plan');
  const planRequest = page.waitForRequest('**/api/commands/run');
  await run.focus();
  await page.keyboard.press('Enter');
  expect((await planRequest).postDataJSON()).toMatchObject({ mode: 'plan', profile: 'boris.json' });
  await expect(publication.getByRole('heading', { name: 'Normalized plan' })).toBeVisible();
  await expect(publication).toContainText('github-pages');
  await expect(publication).toContainText('https://owner.github.io/boris');
  await expect(publication).toContainText('public → dist');
  await expect(publication).toContainText('does not run that workflow');
  await expect(publication.getByRole('heading', { name: 'Local evidence' })).toBeVisible();
  await expect(publication).toContainText('no-deployment-verification');
  await expect(page.getByRole('button', { name: 'Deploy', exact: true })).toHaveCount(0);
});

function visibleLabel(text: string): string {
  return text.replace(/\s+/g, ' ').replace(/\b(Enter|Esc|Alt\+[A-Za-z]|Ctrl|Cmd|Tab)\b/g, '').replace(/\s+/g, ' ').trim();
}

async function assertNamedControls(root: ReturnType<Page['locator']>) {
  const buttons = root.getByRole('button');
  const count = await buttons.count();
  expect(count).toBeGreaterThan(0);
  for (let index = 0; index < count; index += 1) {
    const button = buttons.nth(index);
    if (!(await button.isVisible())) continue;
    const text = visibleLabel(await button.innerText());
    await expect(button).toHaveAccessibleName(/\S/);
    if (text.length > 0) await expect(button).toHaveAccessibleName(new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  const links = root.getByRole('link');
  const linkCount = await links.count();
  for (let index = 0; index < linkCount; index += 1) {
    const link = links.nth(index);
    if (!(await link.isVisible())) continue;
    const text = visibleLabel(await link.innerText());
    await expect(link).toHaveAccessibleName(/\S/);
    if (text.length > 0) await expect(link).toHaveAccessibleName(new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
}

test('chrome buttons and links expose Show-names analog labels (#418 M10)', async ({ page }) => {
  await installApi(page);
  await assertNamedControls(page.locator('header, .section-nav, #project, #source, #publication, #problems, #preview, footer'));
  await page.getByRole('button', { name: 'Create file', exact: true }).focus();
  await page.keyboard.press('Enter');
  const create = page.getByRole('dialog', { name: 'Create file' });
  await expect(create.getByRole('textbox', { name: 'New file path' })).toBeFocused();
  await assertNamedControls(create);
  await page.keyboard.press('Escape');
});

test('Textile-only trees prefill a .textile create path (#418 M10)', async ({ page }) => {
  await installApi(page, { inputMode: 'textile' });
  await expect(page.getByText(/Textile tree/)).toBeVisible();
  await page.getByRole('button', { name: 'Create file', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('dialog', { name: 'Create file' }).getByRole('textbox', { name: 'New file path' })).toHaveValue('content/new-page.textile');
});

test('the 14 #418 actions are completable from the keyboard (#418 M10)', async ({ page }) => {
  const cookGraph = graphPayload();
  const graph = cookGraph.graph as { nodes: Array<Record<string, unknown>> };
  graph.nodes.push({
    index: 3, id: 'carbonara', sourcePath: 'carbonara.cook', role: 'trunk',
    parent: null, parentIndex: null, title: 'Carbonara', status: 'published', tags: [], bodyOffset: 20,
    recipe: {
      ingredients: [
        { name: 'pepper-oil', quantity: { amount: '1', unit: 'tbsp' }, preparation: '', recipeRef: 'sauces/pepper-oil' }
      ],
      cookware: [],
      timers: []
    }
  });
  graph.nodes.push({
    index: 4, id: 'sauces/pepper-oil', sourcePath: 'sauces/pepper-oil.cook', role: 'satellite',
    parent: 'carbonara', parentIndex: 3, title: 'Pepper oil', status: 'published', tags: [], bodyOffset: 20,
    recipe: { ingredients: [], cookware: [], timers: [] }
  });
  await installApi(page, {
    inputMode: 'mixed',
    files: [
      { path: 'boris.json' },
      { path: 'content/index.md' },
      { path: 'content/carbonara.cook' },
      { path: 'content/sauces/pepper-oil.cook' }
    ],
    graph: [cookGraph],
    publication: { profiles: [{ path: 'boris.json' }], proof: null },
    commands: {
      ir_build: commandResult('ir_build', {
        exit_code: 1, failure_class: 'content',
        problems: [{
          severity: 'error', code: 'EFRONTMATTER', message: 'Unknown key.', remediation: 'Remove it.',
          source_path: 'index.md', line: 1, column: 1, id: 'index', origin: 'build_report',
          position_confidence: 'exact', packet: 'code: EFRONTMATTER'
        }]
      }),
      plan: commandResult('plan', {
        publication_plan: {
          format: 'boris-publication-plan', schema_version: 1, input: 'content', input_format: 'markdown',
          publication: null, targets: [{ name: 'public', output: 'dist', public: true }]
        }
      })
    },
    recovery: [{ path: 'content/index.md', content: '# Recovered\n', fingerprint: 'd'.repeat(64) }]
  });

  // 1 launch / open project
  await expect(page.getByRole('heading', { name: 'Boris Editor', level: 1 })).toBeVisible();
  await expect(page.getByRole('status', { name: 'Connection status' })).toContainText('Connected');

  // 13 recover interrupted work before later saves clear the snapshot
  await page.getByRole('button', { name: 'Restore content/index.md', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Recovered unsaved work');
  await page.getByRole('button', { name: 'Save file', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();

  // 4 move between Source, Project, Problems, Preview
  for (const name of ['Project', 'Source', 'Problems', 'Preview']) {
    await page.getByRole('navigation', { name: 'Editor sections' }).getByRole('link', { name, exact: true }).focus();
    await page.keyboard.press('Enter');
  }

  // 2 create Markdown
  await page.getByRole('button', { name: 'Create file', exact: true }).focus();
  await page.keyboard.press('Enter');
  const create = page.getByRole('dialog', { name: 'Create file' });
  await expect(create.getByRole('textbox', { name: 'New file path' })).toHaveValue('content/new-page.md');
  await create.getByRole('textbox', { name: 'New file path' }).fill('content/notes.md');
  await create.getByRole('textbox', { name: 'New file path' }).press('Enter');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Created content/notes.md.');

  // 3 create Cooklang
  await page.getByRole('button', { name: 'Create file', exact: true }).focus();
  await page.keyboard.press('Enter');
  await create.getByRole('textbox', { name: 'New file path' }).fill('content/new-recipe.cook');
  await create.getByRole('textbox', { name: 'New file path' }).press('Enter');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Created content/new-recipe.cook.');

  // 5 edit frontmatter in the native textarea
  await page.getByRole('button', { name: 'content/index.md', exact: true }).focus();
  await page.keyboard.press('Enter');
  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await editor.fill('---\nid: index\ntitle: Home\n---\n# Home\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Save file', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();

  // 6 select a graph completion
  await page.getByLabel('Completion category', { exact: true }).selectOption('entity');
  await page.getByRole('combobox', { name: 'Filter entity', exact: true }).fill('guides');
  await expect(page.getByRole('option', { name: /guides\/intro/ }).first()).toBeVisible();
  await page.getByRole('button', { name: 'Insert selected completion', exact: true }).focus();
  await page.keyboard.press('Enter');
  await page.getByRole('button', { name: 'Save file', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();

  // 7–8 introduce a diagnostic and go to it
  await page.getByRole('button', { name: 'Build diagnostics', exact: true }).focus();
  await page.keyboard.press('Enter');
  const go = page.getByRole('button', { name: 'Go to index.md line 1 column 1', exact: true });
  await go.focus();
  await page.keyboard.press('Enter');
  await expect(editor).toBeFocused();

  // 9 save and preview
  await editor.fill('# Saved\n');
  await page.getByRole('button', { name: 'Save file', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Rebuild preview', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByText(/Preview is current from a successful/)).toBeVisible();

  // 10–11 recipe facet: scaling is an honest gap; related recipe is reachable
  await page.getByRole('button', { name: 'content/carbonara.cook', exact: true }).focus();
  await page.keyboard.press('Enter');
  const recipe = page.locator('.recipe-pane');
  await expect(recipe).toContainText('Scaling is not available');
  await expect(page.getByRole('button', { name: /Scale / })).toHaveCount(0);
  await recipe.getByRole('button', { name: 'Go to recipe sauces/pepper-oil', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('textbox', { name: 'Source for content/sauces/pepper-oil.cook' })).toBeVisible();

  // 12 publication plan
  const planRequest = page.waitForRequest('**/api/commands/run');
  await page.getByRole('button', { name: 'Run publication plan', exact: true }).focus();
  await page.keyboard.press('Enter');
  expect((await planRequest).postDataJSON()).toMatchObject({ mode: 'plan', profile: 'boris.json' });
  await expect(page.locator('#publication')).toContainText('Normalized plan');

  // 14 dirty buffer is visible; close is the browser beforeunload + recovery
  await page.getByRole('textbox', { name: 'Source for content/sauces/pepper-oil.cook' }).fill('# Still dirty\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
});

test('stale graph.json stays in the shell and names Build diagnostics (#418 M11)', async ({ page }) => {
  await installApi(page, {
    graph: [{ graph: null, graph_status: 'unsupported' }]
  });
  await expect(page.getByRole('status', { name: 'Graph status' })).toContainText('stale or unsupported');
  await expect(page.getByRole('status', { name: 'Graph status' })).toContainText('Build diagnostics');
  await expect(page.getByRole('heading', { name: 'Boris Editor', level: 1 })).toBeVisible();
});

test('stale completion.json keeps the frontmatter schema and names rebuild (#418 M11)', async ({ page }) => {
  await installApi(page, {
    authoring: [{
      ...authoringPayload(false),
      completion_status: 'unsupported'
    }]
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByText(/stale or unsupported/)).toBeVisible();
  await expect(page.getByText('Frontmatter field bounds from Boris schema')).toBeVisible();
});

test('opening a file over 8 MiB names the editor bound (#418 M11)', async ({ page }) => {
  await installApi(page, { openError: { error: 'payload_too_large' } });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('8 MiB editor bound');
});

test('saving a file over 8 MiB keeps the buffer and names the bound (#418 M11)', async ({ page }) => {
  await installApi(page, { saveError: { error: 'payload_too_large' } });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Too big\n');
  await page.getByRole('button', { name: 'Save file', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('8 MiB editor bound');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
});

test('a terminated Boris command stays retryable (#418 M11)', async ({ page }) => {
  await installApi(page, {
    commandByCall: [
      commandResult('validate', { exit_code: null, failure_class: 'terminated' }),
      commandResult('validate')
    ]
  });
  await page.getByRole('button', { name: 'Validate project', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Process terminated');
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Run the same command again');
  await page.getByRole('button', { name: 'Validate project', exact: true }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Success');
});

test('compiler version names the supported IR range (#418 M11)', async ({ page }) => {
  await installApi(page, {
    version: {
      compiler_id: 'boris/0.8.1',
      supported: { completion: [1], ir: ['0.2.0', '0.3.0', '0.4.0'], publication_plan: [1], frontmatter: [1] }
    }
  });
  await expect(page.getByText('Compiler: boris/0.8.1; IR 0.2.0–0.4.0')).toBeVisible();
});

test('overlapping saves send one request (#418 M11)', async ({ page }) => {
  let saves = 0;
  await installApi(page);
  await page.route('**/api/files/save', async route => {
    saves += 1;
    const body = route.request().postDataJSON() as { path: string; content: string };
    await new Promise(resolve => setTimeout(resolve, 80));
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        status: 'saved', path: body.path, content: body.content,
        fingerprint: 'c'.repeat(64), read_only: false
      })
    });
  });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Storm\n');
  await page.keyboard.press('Control+s');
  await page.keyboard.press('Control+s');
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();
  expect(saves).toBe(1);
});

test('unreadable recovery snapshots are ignored without hiding the valid ones (#418 M11)', async ({ page }) => {
  await installApi(page, {
    recovery: [{ path: 'content/index.md', content: '# Recovered\n', fingerprint: 'd'.repeat(64) }],
    recoverySkipped: 1
  });
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('1 recovery snapshot was unreadable and ignored');
  await expect(page.getByRole('button', { name: 'Restore content/index.md', exact: true })).toBeVisible();
});

function manyProjectFiles(count: number): Array<{ path: string }> {
  const files = [{ path: 'boris.json' }];
  for (let index = 0; index < count; index += 1) {
    files.push({ path: `content/p${String(index).padStart(3, '0')}.md` });
  }
  return files;
}

test('large project file trees stay bounded and filterable (#418 M11)', async ({ page }) => {
  await installApi(page, { files: manyProjectFiles(250) });
  const tree = page.getByRole('navigation', { name: 'Project files' });
  await expect(page.getByRole('status', { name: 'Project files status' }))
    .toContainText('Showing 200 of 251 project files. Filter to find the rest.');
  await expect(tree.getByRole('button')).toHaveCount(200);
  await expect(tree.getByRole('button', { name: 'content/p249.md', exact: true })).toHaveCount(0);

  await page.getByRole('textbox', { name: 'Filter project files' }).fill('p249');
  await expect(page.getByRole('status', { name: 'Project files status' }))
    .toContainText('1 project file matches “p249”');
  await expect(tree.getByRole('button')).toHaveCount(1);
  await page.getByRole('button', { name: 'content/p249.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/p249.md' })).toBeVisible();
});

test('command palette caps unfiltered files and finds the rest by filter (#418 M11)', async ({ page }) => {
  await installApi(page, { files: manyProjectFiles(250) });
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  const listbox = palette.getByRole('listbox', { name: 'Boris commands' });
  await expect(listbox.getByRole('option', { name: /Open file/ })).toHaveCount(50);
  await expect(listbox.getByRole('option', { name: /p249/ })).toHaveCount(0);

  await palette.getByRole('combobox', { name: 'Filter commands' }).fill('p249');
  await expect(listbox.getByRole('option', { name: /Open file/ })).toHaveCount(1);
  await expect(listbox.getByRole('option', { name: /p249/ })).toHaveAttribute('aria-selected', 'true');
  await palette.getByRole('combobox', { name: 'Filter commands' }).press('Enter');
  await expect(palette).toBeHidden();
  await expect(page.getByRole('textbox', { name: 'Source for content/p249.md' })).toBeVisible();
});

test('hiding the tab flushes the latest unsaved buffer (#418 M11)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const first = page.waitForRequest('**/api/recovery/snapshot');
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# First\n');
  expect((await first).postDataJSON()).toMatchObject({ content: '# First\n' });

  const flush = page.waitForRequest(request =>
    request.url().includes('/api/recovery/snapshot')
    && (request.postDataJSON() as { content?: string }).content === '# Later\n'
  );
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Later\n');
  await page.evaluate(() => window.dispatchEvent(new Event('pagehide')));
  expect((await flush).postDataJSON()).toMatchObject({
    path: 'content/index.md', content: '# Later\n', fingerprint: 'a'.repeat(64)
  });
});

test('a dead editor host is named and tells you to restart (#418 M11)', async ({ page }) => {
  await installApi(page);
  await expect(page.getByRole('status', { name: 'Connection status' })).toContainText('Connected to boris-editor/0.1.0.');
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.route('**/api/recovery/snapshot', route => route.abort());
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# After crash\n');
  await expect(page.getByRole('status', { name: 'Connection status' }))
    .toContainText('Local host unavailable. Restart boris-editor.');
  await expect(page.getByRole('status', { name: 'Editing status' }))
    .toContainText('The editor host stopped');
});

test('external disk changes while dirty open the conflict dialog (#418 M11)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
  await page.route('**/api/files/probe', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'changed', path: 'content/index.md', content: '# External\n',
      fingerprint: 'b'.repeat(64), read_only: false
    })
  }));
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  const dialog = page.getByRole('dialog', { name: 'External changes detected' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('textbox', { name: 'Your unsaved version' })).toHaveValue('# Mine\n');
  await expect(dialog.getByRole('textbox', { name: 'Current disk version' })).toHaveValue('# External\n');
});

test('external delete while dirty opens the deleted-file dialog (#418 M11)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Mine\n');
  await page.route('**/api/files/probe', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'deleted' })
  }));
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await expect(page.getByRole('dialog', { name: 'File deleted outside Boris Editor' })).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Mine\n');
});

test('a clean buffer reloads when disk changes outside the editor (#418 M11)', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Home\n');
  await page.route('**/api/files/probe', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'changed', path: 'content/index.md', content: '# External\n',
      fingerprint: 'b'.repeat(64), read_only: false
    })
  }));
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# External\n');
  await expect(page.getByRole('status', { name: 'Editing status' }))
    .toContainText('Loaded external changes to content/index.md.');
  await expect(page.getByText('Saved on disk', { exact: true })).toBeVisible();
});

test('opening the project names how long connect took (#418 M11)', async ({ page }) => {
  await installApi(page);
  await expect(page.getByRole('status', { name: 'Connection status' }))
    .toContainText('Opened project in');
});

test('opening and saving a file name the wait and elapsed time (#418 M11)', async ({ page }) => {
  await installApi(page);
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await new Promise(resolve => setTimeout(resolve, 80));
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        status: 'opened', path, content: '# Home\n',
        fingerprint: 'a'.repeat(64), read_only: false
      })
    });
  });
  await page.route('**/api/files/save', async route => {
    const body = route.request().postDataJSON() as { path: string; content: string };
    await new Promise(resolve => setTimeout(resolve, 80));
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        status: 'saved', path: body.path, content: body.content,
        fingerprint: 'c'.repeat(64), read_only: false
      })
    });
  });
  const opening = page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Opening content/index.md');
  await opening;
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Opened content/index.md.');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('s)');
  await page.getByRole('textbox', { name: 'Source for content/index.md' }).fill('# Wait\n');
  const saving = page.getByRole('button', { name: 'Save file', exact: true }).click();
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Saving content/index.md');
  await saving;
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Saved content/index.md.');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('s)');
});

test('a Boris command names the running wait and elapsed time (#418 M11)', async ({ page }) => {
  await installApi(page);
  await page.route('**/api/commands/run', async route => {
    const { mode } = route.request().postDataJSON() as { mode: string };
    await new Promise(resolve => setTimeout(resolve, 80));
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify(commandResult(mode))
    });
  });
  const running = page.getByRole('button', { name: 'Validate project', exact: true }).click();
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Running Validate project');
  await running;
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Validate project finished: Success');
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('s)');
});
