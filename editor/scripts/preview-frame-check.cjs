// Real-host browser gate for the embedded Boris preview frame.
// Proves the iframe actually renders through the host's Content-Security-Policy
// and that a Boris rebuild round-trips end to end in a real browser.
//
// Usage: node preview-frame-check.cjs APP_URL EXPECTED_FRAGMENT
//
// Requires playwright and its chromium browser, e.g. from editor/ui/node_modules:
//   NODE_PATH=editor/ui/node_modules node editor/scripts/preview-frame-check.cjs ...
'use strict';

const { chromium } = require('playwright');

(async () => {
  const [appUrl, expectedFragment] = process.argv.slice(2);
  if (!appUrl || !expectedFragment) throw new Error('usage: preview-frame-check.cjs APP_URL EXPECTED_FRAGMENT');
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const violations = [];
  page.on('console', (msg) => {
    if (/Refused to frame|Content Security Policy/i.test(msg.text())) violations.push(msg.text());
  });
  try {
    await page.goto(appUrl, { waitUntil: 'domcontentloaded' });
    await page.getByRole('button', { name: 'Rebuild preview' }).click();
    await page.locator('p.preview-state').filter({ hasText: 'success' }).waitFor({ timeout: 120000 });
    const frameBody = page.frameLocator('iframe[title="Boris site preview"]').locator('body');
    await frameBody.waitFor({ timeout: 30000 });
    const text = await frameBody.innerText();
    if (!text.includes(expectedFragment)) {
      throw new Error(`preview frame did not render committed dist bytes (expected "${expectedFragment}")`);
    }
    if (violations.length > 0) throw new Error('CSP violations while framing preview: ' + violations.join(' | '));
    console.log(`preview frame renders committed dist bytes (${expectedFragment})`);
  } finally {
    await browser.close();
  }
})().catch((err) => {
  console.error('preview-frame-check: ' + err.message);
  process.exit(1);
});