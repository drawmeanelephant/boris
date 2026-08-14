import { expect, test, type Page } from '@playwright/test';

type MockOptions = {
  saveConflict?: boolean;
  recovery?: Array<{ path: string; content: string; fingerprint: string }>;
};

async function installApi(page: Page, options: MockOptions = {}) {
  let disk = '# Home\n';
  let fingerprint = 'a'.repeat(64);

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
