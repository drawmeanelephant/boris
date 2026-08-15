import { expect, test, type Page } from '@playwright/test';

type MockOptions = {
  saveConflict?: boolean;
  recovery?: Array<{ path: string; content: string; fingerprint: string }>;
  disk?: string;
  commands?: Partial<Record<string, CommandResult>>;
  authoring?: Array<Record<string, unknown>>;
  previewRebuilds?: Array<Record<string, unknown>>;
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
};

function commandResult(mode: string, overrides: Partial<CommandResult> = {}): CommandResult {
  return {
    mode, exit_code: 0, failure_class: 'success', compiler_id: 'boris/0.8.1',
    report_version: null, used_stderr_fallback: false, problems: [], findings: [], impact: [],
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

async function installApi(page: Page, options: MockOptions = {}) {
  let disk = options.disk ?? '# Home\n';
  let fingerprint = 'a'.repeat(64);
  let authoringRequest = 0;
  let previewRebuild = 0;

  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'ok',
      editor_id: 'boris-editor/0.1.0',
      project: { content: true, default_layout: true, publication_profile: true }
    })
  }));
  await page.route('**/api/version', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ compiler_id: 'boris/0.8.1' })
  }));
  await page.route('**/api/files', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ files: [{ path: 'boris.json' }, { path: 'content/index.md' }] })
  }));
  await page.route('**/api/recovery', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ snapshots: options.recovery ?? [] })
  }));
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: 'opened', path, content: disk, fingerprint, read_only: false })
    });
  });
  await page.route('**/api/files/save', async route => {
    const body = route.request().postDataJSON() as { path: string; content: string };
    if (options.saveConflict) {
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
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify(options.commands?.[mode] ?? commandResult(mode))
    });
  });
  await page.route('**/api/authoring', route => {
    const sequence = options.authoring ?? [authoringPayload()];
    const body = sequence[Math.min(authoringRequest, sequence.length - 1)];
    authoringRequest += 1;
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
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
  for (const name of ['Project', 'Source', 'Problems', 'Preview']) {
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
  await page.clock.install();
  const file = page.getByRole('button', { name: 'content/index.md', exact: true });
  await file.focus();
  await page.keyboard.press('Enter');

  const editor = page.getByRole('textbox', { name: 'Source for content/index.md' });
  await expect(editor).toHaveValue('# Home\n');
  await editor.fill('# Draft\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
  const recoveryRequest = page.waitForRequest('**/api/recovery/snapshot');
  await page.clock.fastForward(3000);
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
    await expect(dialog.getByRole('button', { name, exact: true })).toHaveText(name);
  }
  await dialog.getByRole('button', { name: 'Load disk version' }).click();
  await expect(dialog).toBeHidden();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Changed elsewhere\n');
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
  await expect(dialog.getByRole('button', { name: 'Save & restore', exact: true })).toHaveText('Save & restore');

  // Cancel keeps the dirty buffer and does not restore.
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(dialog).toBeHidden();
  await expect(editor).toHaveValue('# Draft\n');

  // Discard & restore drops the buffer without saving, then restores the recovered work.
  let saveRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/save')) saveRequests += 1;
  });
  const openRequest = page.waitForRequest('**/api/files/open');
  await restore.click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: 'Discard & restore', exact: true }).click();
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
  await expect(dialog.getByRole('button', { name: 'Cancel', exact: true })).toHaveText('Cancel');
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
  await dialog.getByRole('button', { name: 'Create file', exact: true }).click();
  await expect(dialog).toBeHidden();
  expect(createRequests).toBe(1);
});

test('Delete dialog falls back to a named placeholder when no file is selected (#461)', async ({ page }) => {
  await installApi(page);
  const dialog = page.locator('dialog').filter({ has: page.locator('#delete-heading') });
  expect(await dialog.locator('p').first().textContent()).toBe(
    'Delete selected file? This changes the project immediately and cannot be undone in Boris Editor.'
  );
  expect(await dialog.locator('.dialog-actions .danger').textContent()).toBe('Delete file');
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
  await dialog.getByRole('button', { name: 'Delete content/index.md', exact: true }).click();
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
  await expect(dialog.getByRole('button', { name: 'Create file', exact: true })).toBeFocused();
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
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(dialog).toBeHidden();
  await expect(editor).toHaveValue('# Draft\n');
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();

  // Save & Switch persists the buffer, then opens the target.
  const saveRequest = page.waitForRequest('**/api/files/save');
  const openRequest = page.waitForRequest('**/api/files/open');
  await target.click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: 'Save & switch', exact: true }).click();
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
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: 'Discard & switch', exact: true }).click();
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
  await page.getByRole('button', { name: 'Build HTML', exact: true }).click();
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
  await copy.click();
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
  await dialog.getByRole('button', { name: 'Discard & run', exact: true }).click();
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
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(dialog).toBeHidden();
  await expect(editor).toHaveValue('# Draft\n');
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('No Boris command has run yet.');

  // Save & run persists the buffer, then runs the command.
  const saveRequest = page.waitForRequest('**/api/files/save');
  const commandRequest = page.waitForRequest('**/api/commands/run');
  await page.getByRole('button', { name: 'Validate project', exact: true }).click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: 'Save & run', exact: true }).click();
  expect((await saveRequest).postDataJSON()).toMatchObject({ path: 'content/index.md', content: '# Draft\n' });
  expect((await commandRequest).postDataJSON()).toMatchObject({ mode: 'validate' });
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Validate project finished: Success (exit 0).');
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
  await expect(dialog.getByRole('button', { name: 'Save & rebuild', exact: true })).toHaveText('Save & rebuild');
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(dialog).toBeHidden();
  await expect(editor).toHaveValue('# Draft\n');

  // Discard & rebuild drops the buffer without saving, then rebuilds.
  let saveRequests = 0;
  page.on('request', request => {
    if (request.url().includes('/api/files/save')) saveRequests += 1;
  });
  const rebuildRequest = page.waitForRequest('**/api/preview/rebuild');
  await page.getByRole('button', { name: 'Rebuild preview', exact: true }).click();
  await page.getByRole('dialog', { name: 'Unsaved changes' }).getByRole('button', { name: 'Discard & rebuild', exact: true }).click();
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
