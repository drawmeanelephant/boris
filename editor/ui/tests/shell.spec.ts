import { expect, test } from '@playwright/test';

test.beforeEach(async ({ page }) => {
  await page.route('**/api/health', async route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'ok',
      editor_id: 'boris-editor/0.1.0',
      project: { content: true, default_layout: true, publication_profile: true }
    })
  }));
  await page.route('**/api/version', async route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ compiler_id: 'boris/0.8.1' })
  }));
  await page.goto('/#token=test-session-token');
});

test('semantic shell exposes stable keyboard and voice names', async ({ page }) => {
  await expect(page.getByRole('heading', { name: 'Boris Editor', level: 1 })).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Editor sections' })).toBeVisible();
  for (const name of ['Project', 'Source', 'Problems', 'Preview']) {
    const link = page.getByRole('link', { name, exact: true });
    await expect(link).toBeVisible();
    await expect(link).toHaveText(name);
  }
  await expect(page.getByRole('status')).toContainText('Connected to boris-editor/0.1.0.');
  await expect(page.locator('main').ariaSnapshot()).resolves.toContain('heading "Project"');
});

test('all shell navigation works without a pointer', async ({ page }) => {
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Skip to workspace' })).toBeFocused();
  await page.keyboard.press('Tab');
  const project = page.getByRole('link', { name: 'Project', exact: true });
  await expect(project).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/#project$/);

  await page.goto('/#token=test-session-token');
  await page.keyboard.press('Tab');
  await page.keyboard.press('Enter');
  await expect(page.locator('main')).toBeFocused();
});
