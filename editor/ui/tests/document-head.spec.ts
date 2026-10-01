import { expect, test } from '@playwright/test';

test('document head carries the Boris icon and tracks the active theme', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('boris-editor-theme', 'dark'));
  await page.goto('/#token=test-session-token');

  const favicon = page.locator('link[rel="icon"]');
  await expect(favicon).toHaveAttribute('href', /^data:image\/svg\+xml,/);
  expect(await favicon.evaluate(async (link) => {
    const image = new Image();
    image.src = (link as HTMLLinkElement).href;
    await image.decode();
    return image.naturalWidth === 64 && image.naturalHeight === 64;
  })).toBe(true);
  await expect(favicon).toHaveAttribute('href', /fill='%23173f34'/);

  const themeColor = page.locator('meta[name="theme-color"]');
  await expect(themeColor).toHaveAttribute('content', '#111a15');
  await page.getByRole('button', { name: 'Dark', exact: true }).click();
  await expect(themeColor).toHaveAttribute('content', '#eef2ed');
});

test('document explains the blank shell when JavaScript is disabled', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  try {
    const page = await context.newPage();
    await page.goto('/');
    const fallback = page.locator('noscript');
    await expect(fallback).toBeVisible();
    expect(await fallback.evaluate(element => element.textContent?.trim())).toBe(
      'Boris Editor needs JavaScript to run. Enable JavaScript and reload this page.'
    );
    await expect(page.locator('#app')).toBeEmpty();
  } finally {
    await context.close();
  }
});
