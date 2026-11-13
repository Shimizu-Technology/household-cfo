import { defineConfig, devices } from '@playwright/test'

const port = Number(process.env.PLAYWRIGHT_PORT ?? 4173)
// CI tests real Chrome. Local runs use Playwright's full bundled Chromium: real Chrome starts more
// slowly and each launch costs macOS's ctkd smart-card service about a second of CPU.
const chromeChannel = process.env.CI ? 'chrome' : 'chromium'

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  workers: 1,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? 'github' : 'list',
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    // Reduced motion removes movement, so a dialog or sheet is in
    // its resting place the moment it exists and layout can be measured without waiting.
    // 'BOG UI dialogs rise into place...' opts back in to check the entry motion itself.
    contextOptions: { reducedMotion: 'reduce' },
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'desktop-chrome', use: { ...devices['Desktop Chrome'], channel: chromeChannel } },
    {
      name: 'tablet-768-chrome',
      grep: /large financial values|participant navigation remains available|participant links preserve|desktop Tools|Coach Studio|Mia memory|BOG UI|Admin UI|Auth recovery/,
      use: {
        channel: chromeChannel,
        viewport: { width: 768, height: 1024 },
        deviceScaleFactor: 2,
        hasTouch: true,
      },
    },
    {
      name: 'tablet-1024-chrome',
      grep: /large financial values|participant navigation remains available|participant links preserve|desktop Tools|Coach Studio|Mia memory|BOG UI|Admin UI|Auth recovery/,
      use: {
        channel: chromeChannel,
        viewport: { width: 1024, height: 768 },
        deviceScaleFactor: 2,
        hasTouch: true,
      },
    },
    {
      name: 'mobile-chrome',
      use: {
        channel: chromeChannel,
        viewport: { width: 390, height: 844 },
        deviceScaleFactor: 3,
        hasTouch: true,
        isMobile: true,
      },
    },
    {
      name: 'compact-mobile-chrome',
      use: {
        channel: chromeChannel,
        viewport: { width: 320, height: 568 },
        deviceScaleFactor: 2,
        hasTouch: true,
        isMobile: true,
      },
    },
    {
      name: 'mobile-webkit',
      grep: /large financial values|Ask Mia renders bounded history|compact phone layouts|mobile Ask Mia|PDF document preview|Coach Studio|Mia memory|BOG UI|Admin UI|Auth recovery/,
      use: {
        browserName: 'webkit',
        viewport: { width: 390, height: 844 },
        deviceScaleFactor: 3,
        hasTouch: true,
        isMobile: true,
      },
    },
  ],
  webServer: {
    command: `npm run dev -- --host 127.0.0.1 --port ${port} --strictPort`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: !process.env.CI && !process.env.PLAYWRIGHT_PORT,
    env: {
      VITE_API_BASE_URL: 'http://api.test',
      VITE_AUTH_PROVIDER: '',
      VITE_WORKOS_CLIENT_ID: '',
      VITE_PUBLIC_POSTHOG_KEY: '',
      VITE_E2E_AUTH: 'true',
    },
  },
})
