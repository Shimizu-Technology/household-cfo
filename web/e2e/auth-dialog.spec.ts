import { expect, test } from '@playwright/test'
const clientId = 'client_FICTIONAL1'
const challenge = { step: 'code', challenge_id: 'e'.repeat(43), email: 'fictional@pilot.test', expires_at: new Date(Date.now() + 600_000).toISOString(), resend_after: 60 }
const session = { client_id: clientId, user: { id: 'user_DIALOG', email: challenge.email, first_name: 'Fictional', last_name: 'Participant' }, organization_id: null, authentication_method: 'MagicAuth', access_token: 'fictional-ephemeral-token', expires_at: new Date(Date.now() + 120_000).toISOString() }

test.describe('Auth recovery in-app sign-in dialog', () => {
  test.beforeEach(async ({ page }) => {
    await page.route('**/api/auth/session', route => route.fulfill({ json: { client_id: clientId, user: null } }))
    await page.route('**/api/auth/options', route => route.fulfill({ json: { google_enabled: true } }))
    await page.route('**/api/auth/email/cancel', route => route.fulfill({ status: 204 }))
  })
  test('email entry, wrong-code recovery and verification stay in the app and open the permanent account', async ({ page }) => {
    const origin = new URL(test.info().project.use.baseURL!).origin
    await page.route(`${origin}/`, async route => { const response = await route.fetch({ url: `${origin}/browser-session-qa.html` }); return route.fulfill({ response }) })
    let signedIn = false
    let attempts = 0
    await page.route('**/api/auth/session', route => route.fulfill({ json: signedIn ? session : { client_id: clientId, user: null } }))
    await page.route('http://api.test/api/v1/auth/me', route => route.fulfill({ json: { user: { id: 901, auth_provider: 'workos', auth_subject: session.user.id, full_name: 'Fictional participant', role: 'participant' } } }))
    await page.route('**/api/auth/email/start', route => {
      expect(route.request().postDataJSON().email).toBe(challenge.email)
      return route.fulfill({ json: challenge })
    })
    await page.route('**/api/auth/email/verify', route => {
      expect(route.request().postDataJSON().challenge_id).toBe(challenge.challenge_id)
      if (++attempts === 1) return route.fulfill({ status: 401, json: { code: 'email_code_invalid', error: 'Private provider error must not be visible' } })
      signedIn = true
      return route.fulfill({ json: { step: 'complete', return_to: new URL(test.info().project.use.baseURL!).origin } })
    })
    await page.goto('/browser-session-qa.html')
    await page.getByRole('button', { name: 'Sign in', exact: true }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Continue with Google' })).toBeVisible()
    await expect(page.getByRole('button', { name: /SSO|Continue with your organization/ })).toHaveCount(0)
    await page.getByLabel('Email address', { exact: true }).fill('Fictional@Pilot.Test')
    await page.getByRole('button', { name: 'Continue with email' }).click()
    await page.getByLabel('Sign-in code', { exact: true }).fill('123456')
    await page.getByRole('button', { name: 'Verify and sign in' }).click()
    await expect(page.getByRole('alert')).toContainText('That code did not match')
    await expect(page.getByText('Private provider error must not be visible')).toHaveCount(0)
    await page.getByLabel('Sign-in code', { exact: true }).fill('654321')
    await page.getByRole('button', { name: 'Verify and sign in' }).click()
    await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
    await expect(page.getByRole('dialog')).toHaveCount(0)
    expect(new URL(page.url()).origin).toBe(new URL(test.info().project.use.baseURL!).origin)
    expect(await page.evaluate(() => ({ local: localStorage.length, session: sessionStorage.length }))).toEqual({ local: 0, session: 0 })
    await page.reload()
    await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
  })
  test('dialog fits phone and desktop and keeps fields and close control reachable at short height', async ({ page }) => {
    await page.goto('/browser-session-qa.html')
    const trigger = page.getByRole('button', { name: 'Sign in', exact: true })
    await trigger.click()
    const dialog = page.getByRole('dialog')
    await expect(dialog).toBeVisible()
    const width = page.viewportSize()!.width
    await page.setViewportSize({ width, height: 340 })
    await expect.poll(async () => { const current = await dialog.boundingBox(); return current ? current.y + current.height : Number.POSITIVE_INFINITY }).toBeLessThanOrEqual(341)
    const bounds = await dialog.boundingBox()
    expect(bounds!.x).toBeGreaterThanOrEqual(0)
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width)
    expect(bounds!.y).toBeGreaterThanOrEqual(0)
    expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(341)
    await page.getByLabel('Email address', { exact: true }).fill(challenge.email)
    await page.getByRole('button', { name: 'Close', exact: true }).click()
    await expect(dialog).toHaveCount(0)
    await expect(trigger).toBeFocused()
  })
  test('desktop Google uses a separate window and cancellation leaves email sign-in available', async ({ page, context }) => {
    test.skip(test.info().project.name !== 'desktop-chrome', 'Separate desktop authentication window; phones use top-level redirect.')
    const origin = new URL(test.info().project.use.baseURL!).origin
    let login: Record<string, unknown> | undefined
    await context.route('**/api/auth/login', route => {
      login = route.request().postDataJSON()
      return route.fulfill({ json: { authorization_url: `https://api.workos.com/user_management/authorize?client_id=${clientId}&state=${'s'.repeat(43)}&redirect_uri=${encodeURIComponent(`${origin}/api/auth/callback`)}` } })
    })
    await page.route('**/api/auth/login/status', route => route.fulfill({ json: { status: 'pending' } }))
    await page.route('**/api/auth/login/cancel', route => route.fulfill({ json: { status: 'cancelled' } }))
    await context.route('https://api.workos.com/user_management/authorize**', route => route.fulfill({ contentType: 'text/html', body: '<h1>Fictional Google account chooser</h1>' }))
    await page.goto('/browser-session-qa.html')
    await page.getByRole('button', { name: 'Sign in', exact: true }).click()
    const opened = context.waitForEvent('page')
    await page.getByRole('button', { name: 'Continue with Google', exact: true }).click()
    const popup = await opened
    await expect(popup.getByRole('heading', { name: 'Fictional Google account chooser' })).toBeVisible()
    expect(login).toMatchObject({ authentication_method: 'google', popup: true })
    expect(new URL(page.url()).pathname).toBe('/browser-session-qa.html')
    await popup.close()
    await page.getByRole('button', { name: 'Cancel sign-in', exact: true }).click()
    await expect(page.getByLabel('Email address', { exact: true })).toBeEnabled()
    await page.getByLabel('Email address', { exact: true }).fill(challenge.email)
    await expect(page.getByRole('button', { name: 'Continue with email' })).toBeEnabled()
    await expect(page.getByRole('status')).toContainText('Stopped waiting')
  })
})

test.describe('Auth recovery Google completion and browser isolation', () => {
  for (const isolated of [false, true]) {
    test(`desktop Google completion ${isolated ? 'survives real opener isolation' : 'returns to the original app window'}`, async ({ page, context }) => {
      test.skip(test.info().project.name !== 'desktop-chrome', 'Desktop popup flow; mobile redirect is covered separately.')
      const origin = new URL(test.info().project.use.baseURL!).origin
      let signedIn = false
      let operationComplete = false
      const restored = async (route: import('@playwright/test').Route) => {
        const response = await route.fetch({ url: `${origin}/browser-session-qa.html` })
        return route.fulfill({ response })
      }
      await page.route(`${origin}/`, restored)
      await page.route('**/api/auth/session', route => route.fulfill({ json: signedIn ? { ...session, authentication_method: 'GoogleOAuth' } : { client_id: clientId, user: null } }))
      await page.route('**/api/auth/options', route => route.fulfill({ json: { google_enabled: true } }))
      await page.route('http://api.test/api/v1/auth/me', route => route.fulfill({ json: { user: { id: 901, auth_provider: 'workos', auth_subject: session.user.id, full_name: 'Original fictional Google account', role: 'participant' } } }))
      await page.route('**/api/auth/login/status', route => {
        expect(route.request().postDataJSON().state).toBe('s'.repeat(43))
        return route.fulfill({ json: { status: operationComplete ? 'complete' : 'pending' } })
      })
      await page.route('**/api/auth/login/cancel', route => route.fulfill({ json: { status: operationComplete ? 'complete' : 'cancelled' } }))
      await page.route('**/api/auth/login', route => {
        expect(route.request().postDataJSON()).toMatchObject({ authentication_method: 'google', popup: true })
        return route.fulfill({ json: { authorization_url: `https://api.workos.com/user_management/authorize?client_id=${clientId}&state=${'s'.repeat(43)}&redirect_uri=${encodeURIComponent(`${origin}/api/auth/callback`)}` } })
      })
      await context.route('https://api.workos.com/user_management/authorize**', route => route.fulfill({
        contentType: 'text/html', headers: isolated ? { 'Cross-Origin-Opener-Policy': 'same-origin' } : {},
        body: `<h1>Fictional Google sign-in</h1><a href="${origin}/login/complete">Complete fictional Google sign-in</a>`,
      }))
      await context.route(`${origin}/login/complete`, async route => {
        operationComplete = true; signedIn = true
        return restored(route)
      })
      await page.goto('/browser-session-qa.html')
      if (!isolated) await page.evaluate(() => window.history.replaceState(null, '', '/?oauth_state_id=fictional-google-bank-ref&income=4500#Review'))
      await page.getByRole('button', { name: 'Sign in', exact: true }).click()
      const opened = context.waitForEvent('page')
      await page.getByRole('button', { name: 'Continue with Google', exact: true }).click()
      const popup = await opened
      await expect(popup.getByRole('heading', { name: 'Fictional Google sign-in' })).toBeVisible()
      if (isolated) {
        expect(await popup.evaluate(() => window.opener === null)).toBe(true)
        await expect(page.getByRole('button', { name: 'Cancel sign-in' })).toBeVisible()
        await expect(page.getByRole('dialog')).toBeVisible()
      }
      await popup.getByRole('link', { name: 'Complete fictional Google sign-in', exact: true }).click()
      await expect(page.getByRole('dialog')).toHaveCount(0)
      await expect(page.getByTestId('verified-actor').filter({ hasText: 'Original fictional Google account' })).toBeVisible()
      const returned = new URL(page.url())
      expect(returned.origin).toBe(origin)
      if (!isolated) { expect(returned.searchParams.get('oauth_state_id')).toBe('fictional-google-bank-ref'); expect(returned.searchParams.has('income')).toBe(false); expect(returned.hash).toBe('#Review') }
      expect(await page.evaluate(() => ({ local: localStorage.length, session: sessionStorage.length }))).toEqual({ local: 0, session: 0 })
    })
  }
})
