import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  workers: 1,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? 'github' : 'list',
  use: {
    baseURL: 'http://127.0.0.1:4173',
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'desktop-chrome', use: { ...devices['Desktop Chrome'], channel: 'chrome' } },
    {
      name: 'tablet-768-chrome',
      grep: /large financial values|participant navigation remains available|participant links preserve|desktop Tools/,
      use: {
        channel: 'chrome',
        viewport: { width: 768, height: 1024 },
        deviceScaleFactor: 2,
        hasTouch: true,
      },
    },
    {
      name: 'tablet-1024-chrome',
      grep: /large financial values|participant navigation remains available|participant links preserve|desktop Tools/,
      use: {
        channel: 'chrome',
        viewport: { width: 1024, height: 768 },
        deviceScaleFactor: 2,
        hasTouch: true,
      },
    },
    {
      name: 'mobile-chrome',
      use: {
        channel: 'chrome',
        viewport: { width: 390, height: 844 },
        deviceScaleFactor: 3,
        hasTouch: true,
        isMobile: true,
      },
    },
    {
      name: 'compact-mobile-chrome',
      use: {
        channel: 'chrome',
        viewport: { width: 320, height: 568 },
        deviceScaleFactor: 2,
        hasTouch: true,
        isMobile: true,
      },
    },
    {
      name: 'mobile-webkit',
      grep: /large financial values|Ask Mia renders bounded history|compact phone layouts|mobile Ask Mia|PDF document preview/,
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
    command: 'npm run dev -- --host 127.0.0.1 --port 4173',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: !process.env.CI,
    env: {
      VITE_API_BASE_URL: 'http://api.test',
      VITE_CLERK_PUBLISHABLE_KEY: '',
      VITE_PUBLIC_POSTHOG_KEY: '',
      VITE_E2E_AUTH: 'true',
    },
  },
})
