import { expect, test, type Page } from '@playwright/test'
const clientId = 'client_FICTIONAL1'
const session = (userId = 'user_FICTIONAL1') => ({ client_id: clientId, user: { id: userId, first_name: 'Fictional', last_name: 'Person', email: 'fictional@pilot.test' }, organization_id: 'org_FICTIONAL1', authentication_method: 'SSO', access_token: `short-lived-${userId}`, expires_at: new Date(Date.now() + 120_000).toISOString() })
const user = (other = false) => ({ id: other ? 902 : 901, clerk_id: 'retained-legacy', auth_provider: 'workos', auth_subject: other ? 'user_OTHER' : 'user_FICTIONAL1', full_name: other ? 'Other fictional account' : 'Fictional account', email: 'fictional@pilot.test', role: 'participant', is_admin: false, is_coach: false, is_staff: false, is_participant: true })
async function privateIdentity(page: Page, current: () => boolean = () => false) {
  let calls = 0
  await page.route('http://api.test/api/v1/auth/me', route => {
    calls += 1
    const other = current()
    expect(route.request().headers().authorization).toBe(`Bearer short-lived-${other ? 'user_OTHER' : 'user_FICTIONAL1'}`)
    return route.fulfill({ json: { user: user(other) } })
  })
  return () => calls
}
test.describe('Auth recovery free server-managed sessions', () => {
  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => { window.open = () => null })
    await page.route('**/api/auth/options', route => route.fulfill({ json: { google_enabled: false } }))
  })
  for (const destination of ['/#Review', '/organization-access']) {
    test(`hosted roundtrip restores ${destination} and its one-use bank reference without carrying private query details`, async ({ page }) => {
      const origin = new URL(test.info().project.use.baseURL!).origin
      let signedIn = false
      const restoredPage = async (route: import('@playwright/test').Route) => {
        const response = await route.fetch({ url: `${origin}/browser-session-qa.html` })
        return route.fulfill({ response })
      }
      await page.route(`${origin}/`, restoredPage)
      await page.route(`${origin}/organization-access`, restoredPage)
      await page.route('**/api/auth/session', route => route.fulfill({ json: signedIn ? session() : { client_id: clientId, user: null } }))
      await privateIdentity(page)
      await page.route('**/api/auth/email/start', route => {
        const input = route.request().postDataJSON()
        expect(input).toEqual({ email: 'bank@pilot.test', return_to: `${origin}${destination}` })
        expect(JSON.stringify(input)).not.toContain('fictional-bank-ref')
        expect(JSON.stringify(input)).not.toContain('4500')
        return route.fulfill({ json: { step: 'redirect', authorization_url: `https://api.workos.com/user_management/authorize?client_id=${clientId}&redirect_uri=${encodeURIComponent(`${origin}/api/auth/callback`)}` } })
      })
      await page.route('https://api.workos.com/user_management/authorize**', route => {
        signedIn = true
        return route.fulfill({ contentType: 'text/html', body: `<h1>Fictional hosted sign-in</h1><a href="${origin}${destination}">Return to app</a>` })
      })
      await page.goto('/browser-session-qa.html')
      await expect(page.getByRole('heading', { name: 'Signed out', exact: true })).toBeVisible()
      const initial = destination === '/organization-access' ? '/?enterprise=1&oauth_state_id=fictional-bank-ref&income=4500' : '/?oauth_state_id=fictional-bank-ref&income=4500#Review'
      await page.evaluate(path => window.history.replaceState(null, '', path), initial)
      await page.getByRole('button', { name: 'Sign in', exact: true }).click()
      await page.getByLabel('Email address').fill('bank@pilot.test')
      await page.getByRole('button', { name: 'Continue with email', exact: true }).click()
      await expect(page.getByRole('heading', { name: 'Fictional hosted sign-in' })).toBeVisible()
      expect(page.url()).not.toContain('fictional-bank-ref')
      await page.getByRole('link', { name: 'Return to app', exact: true }).click()
      await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
      const restored = new URL(page.url())
      expect(restored.pathname).toBe(destination === '/organization-access' ? destination : '/')
      expect(restored.hash).toBe(destination === '/#Review' ? '#Review' : '')
      expect(restored.searchParams.get('oauth_state_id')).toBe('fictional-bank-ref')
      expect(restored.searchParams.has('income')).toBe(false)
      expect(await page.evaluate(() => sessionStorage.length)).toBe(0)
      await page.goto(`${origin}${destination}`)
      await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
      expect(new URL(page.url()).search).toBe('')
    })
  }
  test('cold reload verifies cookie session and Rails actor with no refresh token browser storage', async ({ page }) => {
    await page.route('**/api/auth/session', route => { expect(route.request().headers()['x-frontend-origin']).toBe(new URL(test.info().project.use.baseURL!).origin); return route.fulfill({ json: session() }) })
    await privateIdentity(page)
    await page.goto('/browser-session-qa.html')
    await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
    expect(await page.evaluate(() => ({ local: localStorage.length, session: sessionStorage.length }))).toEqual({ local: 0, session: 0 })
    await page.reload()
    await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
    expect(await page.evaluate(() => localStorage.length)).toBe(0)
  })
  test('initial temporary session outage remains closed and explicit retry verifies without new credentials', async ({ page }) => {
    let attempt = 0
    await page.route('**/api/auth/session', route => ++attempt === 1 ? route.fulfill({ status: 503, json: {} }) : route.fulfill({ json: session() }))
    const calls = await privateIdentity(page)
    await page.goto('/browser-session-qa.html')
    await expect(page.getByRole('heading', { name: 'Secure access is temporarily unavailable.' })).toBeVisible()
    await expect(page.getByTestId('server-verified-workspace')).toHaveCount(0)
    expect(calls()).toBe(0)
    await page.getByRole('button', { name: 'Check access again' }).click()
    await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
    expect(calls()).toBe(1)
  })
  test('wrong expected client cannot request the private Rails identity or mount its workspace', async ({ page }) => {
    await page.route('**/api/auth/session', route => route.fulfill({ json: { ...session(), client_id: 'client_OTHER' } }))
    const calls = await privateIdentity(page)
    await page.goto('/browser-session-qa.html')
    await expect(page.getByRole('heading', { name: 'Secure access is temporarily unavailable.' })).toBeVisible()
    expect(calls()).toBe(0)
    await expect(page.getByTestId('server-verified-workspace')).toHaveCount(0)
  })
  test('cookie account switch discards previous private draft before another verified actor appears', async ({ page }) => {
    let other = false
    await page.route('**/api/auth/session', route => route.fulfill({ json: session(other ? 'user_OTHER' : 'user_FICTIONAL1') }))
    await privateIdentity(page, () => other)
    await page.goto('/browser-session-qa.html')
    await expect(page.getByTestId('verified-actor').filter({ hasText: /^Fictional account$/ })).toBeVisible()
    await page.getByLabel('Unsaved private draft').fill('Old account draft must disappear')
    other = true
    await page.evaluate(() => window.dispatchEvent(new Event('focus')))
    await expect(page.getByTestId('verified-actor').filter({ hasText: /^Other fictional account$/ })).toBeVisible()
    await expect(page.getByLabel('Unsaved private draft')).toHaveValue('')
    await expect(page.getByTestId('verified-actor').filter({ hasText: /^Fictional account$/ })).toHaveCount(0)
  })
  test('revoked cookie session closes the private workspace and offers fresh sign-in', async ({ page }) => {
    let revoked = false
    await page.route('**/api/auth/session', route => revoked ? route.fulfill({ status: 401, json: {} }) : route.fulfill({ json: session() }))
    await privateIdentity(page)
    await page.goto('/browser-session-qa.html')
    await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
    revoked = true
    await page.evaluate(() => window.dispatchEvent(new Event('focus')))
    await expect(page.getByRole('heading', { name: 'Sign in again to continue.' })).toBeVisible()
    await expect(page.getByTestId('server-verified-workspace')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Sign in again' })).toBeVisible()
  })
  test('invalid callback never auto-restarts authorization before explicit user retry', async ({ page }) => {
    let logins = 0
    const origin = new URL(test.info().project.use.baseURL!).origin
    await page.route('**/api/auth/session', route => route.fulfill({ json: { client_id: clientId, user: null } }))
    await page.route('**/api/auth/email/start', route => { logins += 1; return route.fulfill({ json: { step: 'redirect', authorization_url: `https://api.workos.com/user_management/authorize?client_id=${clientId}&redirect_uri=${encodeURIComponent(`${origin}/api/auth/callback`)}` } }) })
    await page.route('https://api.workos.com/user_management/authorize**', route => route.fulfill({ contentType: 'text/html', body: '<h1>Fictional hosted sign-in</h1>' }))
    await page.goto('/browser-session-qa.html?auth_error=invalid')
    await expect(page.getByRole('heading', { name: 'Sign in again to continue.' })).toBeVisible()
    expect(new URL(page.url()).searchParams.has('auth_error')).toBe(false)
    expect(logins).toBe(0)
    await page.getByRole('button', { name: 'Sign in again' }).click()
    await page.getByLabel('Email address').fill('bank@pilot.test')
    await page.getByRole('button', { name: 'Continue with email', exact: true }).click()
    await expect(page.getByRole('heading', { name: 'Fictional hosted sign-in' })).toBeVisible()
    expect(logins).toBe(1)
  })
  test('confirmed logout uses same-origin JSON and verified vendor navigation after clearing private state', async ({ page }) => {
    const origin = new URL(test.info().project.use.baseURL!).origin
    await page.route('**/api/auth/session', route => route.fulfill({ json: session() }))
    await privateIdentity(page)
    let body: unknown = null
    await page.route('**/api/auth/logout', route => {
      body = route.request().postDataJSON()
      expect(route.request().headers()['x-frontend-origin']).toBe(origin)
      return route.fulfill({ json: { redirect_url: `https://api.workos.com/user_management/sessions/logout?session_id=fictional&return_to=${encodeURIComponent(origin)}` } })
    })
    await page.route('https://api.workos.com/user_management/sessions/logout**', route => route.fulfill({ contentType: 'text/html', body: '<h1>Fictional session signed out</h1>' }))
    await page.goto('/browser-session-qa.html')
    await expect(page.getByTestId('server-verified-workspace')).toBeVisible()
    await page.getByLabel('Account and help', { exact: true }).click()
    await page.getByRole('button', { name: 'Sign out', exact: true }).click()
    await expect(page.getByRole('heading', { name: 'Fictional session signed out' })).toBeVisible()
    expect(body).toEqual({ expected_subject: 'user_FICTIONAL1', expected_organization_id: 'org_FICTIONAL1' })
  })
  test('atomic logout conflict closes old private content and explicitly recovers the current cookie account', async ({ page }) => {
    let other = false
    let logouts = 0
    await page.route('**/api/auth/session', route => route.fulfill({ json: session(other ? 'user_OTHER' : 'user_FICTIONAL1') }))
    await privateIdentity(page, () => other)
    await page.route('**/api/auth/logout', route => {
      logouts += 1
      expect(route.request().postDataJSON()).toEqual({ expected_subject: 'user_FICTIONAL1', expected_organization_id: 'org_FICTIONAL1' })
      other = true
      return route.fulfill({ status: 409, json: { code: 'account_changed' } })
    })
    await page.goto('/browser-session-qa.html')
    await expect(page.getByTestId('verified-actor').filter({ hasText: /^Fictional account$/ })).toBeVisible()
    await page.getByLabel('Unsaved private draft').fill('Retain while logout is rejected')
    await page.getByLabel('Account and help', { exact: true }).click()
    await page.getByRole('button', { name: 'Sign out', exact: true }).click()
    await expect(page.getByText('Your account or organization changed. Check the current account before signing out.', { exact: true })).toBeVisible()
    expect(new URL(page.url()).pathname).toBe('/browser-session-qa.html')
    await expect(page.getByTestId('server-verified-workspace')).toHaveCount(0)
    await expect(page.getByTestId('verified-actor').filter({ hasText: /^Fictional account$/ })).toHaveCount(0)
    await expect(page.getByLabel('Unsaved private draft')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Sign in again' })).toHaveCount(0)
    await page.getByRole('button', { name: 'Check access again', exact: true }).click()
    await expect(page.getByTestId('verified-actor').filter({ hasText: /^Other fictional account$/ })).toBeVisible()
    await expect(page.getByLabel('Unsaved private draft')).toHaveValue('')
    expect(logouts).toBe(1)
  })
  test('stale tab cannot sign out another account after the authoritative cookie changes', async ({ page }) => {
    let other = false
    await page.route('**/api/auth/session', route => route.fulfill({ json: session(other ? 'user_OTHER' : 'user_FICTIONAL1') }))
    await privateIdentity(page, () => other)
    let logouts = 0
    await page.route('**/api/auth/logout', route => { logouts += 1; return route.fulfill({ status: 500, json: {} }) })
    await page.goto('/browser-session-qa.html')
    await expect(page.getByTestId('verified-actor').filter({ hasText: /^Fictional account$/ })).toBeVisible()
    await page.getByLabel('Account and help', { exact: true }).click()
    other = true
    await page.getByRole('button', { name: 'Sign out', exact: true }).click()
    await expect(page.getByTestId('verified-actor').filter({ hasText: /^Other fictional account$/ })).toBeVisible()
    expect(logouts).toBe(0)
  })

})
