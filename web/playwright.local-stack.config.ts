import { defineConfig, devices } from '@playwright/test'

// Runs against the real API and web app that bin/local-stack started (docs/testing/local-stack.md).
// Nothing is mocked: every request goes to this machine, and a test fails if one goes anywhere else.
// Not part of CI. Run it on a fresh stack: bin/local-stack reset, bin/local-stack up,
// bin/local-stack run bin/rails local_stack:household, then npm run test:local-stack.
const web = process.env.LOCAL_STACK_WEB_URL ?? 'http://127.0.0.1:5300'

export default defineConfig({
  testDir: './e2e-local-stack',
  // One shared database: specs run in order, one at a time.
  fullyParallel: false,
  workers: 1,
  retries: 0,
  // Real reads and saves: a statement can take a minute to read, and Go live previews real answers.
  timeout: 180_000,
  reporter: 'list',
  use: {
    baseURL: web,
    contextOptions: { reducedMotion: 'reduce' },
    trace: 'retain-on-failure',
  },
  projects: [
    // Saves money and groups once, on desktop.
    { name: 'desktop-chrome', grep: /@saves/, use: { ...devices['Desktop Chrome'], channel: 'chromium', viewport: { width: 1366, height: 900 } } },
    // Then reads the saved results at phone widths.
    { name: 'phone-webkit', grep: /@reads/, dependencies: ['desktop-chrome'], use: { browserName: 'webkit', viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, hasTouch: true, isMobile: true } },
    { name: 'compact-phone-chrome', grep: /@reads/, dependencies: ['desktop-chrome'], use: { channel: 'chromium', viewport: { width: 320, height: 700 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true } },
  ],
})
