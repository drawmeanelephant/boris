import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  reporter: 'line',
  use: {
    baseURL: 'http://127.0.0.1:4178',
    browserName: 'chromium'
  },
  webServer: {
    command: 'npm run dev -- --host 127.0.0.1 --port 4178',
    port: 4178,
    reuseExistingServer: false
  }
});
