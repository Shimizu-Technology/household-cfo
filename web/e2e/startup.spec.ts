import { expect, test, type Page, type Route } from '@playwright/test'
const session = { client_id: 'client_FICTIONAL1', user: { id: 'user_FICTIONAL1', email: 'fictional@pilot.test', first_name: 'Fictional', last_name: 'Participant' }, organization_id: 'org_FICTIONAL1', authentication_method: 'GoogleOAuth', access_token: 'fictional-short-lived', expires_at: new Date(Date.now() + 3600000).toISOString() }
const user = { id: 901, auth_provider: 'workos', auth_subject: 'user_FICTIONAL1', full_name: 'Fictional Participant', role: 'participant', is_participant: true }
const brand = { schema_version: 1, product_name: 'Startup QA', short_name: 'QA', organization_name: 'Fictional startup QA', participant_role_term: 'participant', powered_by_name: null, powered_by_placement: 'hidden', tagline: 'Fictional startup test', welcome_heading: 'Fictional program unavailable', welcome_description: 'This fixture checks startup ordering.', logo_url: null, favicon_url: null, support: { label: null, email: null, url: null }, colors: { background: '#f7f2ea', surface: '#fffdf8', surface_muted: '#fbf7ef', text: '#1f2421', text_muted: '#706d66', border: '#e2d9cb', primary: '#536a63', primary_hover: '#3f524c', primary_soft: '#e5ece9', accent: '#9a7457', on_primary: '#ffffff', focus: '#536a63' }, typography: { display: 'system_serif', body: 'system_sans' }, footer: { text: null, privacy_url: null, terms_url: null } }
const brandResponse = { brand, source: 'qa', available: true }

async function transport(page: Page) {
  const calls = { session: 0, actor: 0, workspace: 0 }
  await page.route('**/api/auth/session', route => { calls.session++; return route.fulfill({ json: session }) })
  await page.route('http://api.test/api/v1/auth/me', route => { calls.actor++; expect(route.request().headers().authorization).toBe('Bearer fictional-short-lived'); return route.fulfill({ json: { user } }) })
  await page.route('**/api/v1/startup-qa/workspace', route => { calls.workspace++; return route.fulfill({ json: { ready: true } }) })
  return calls
}
const opening = (page: Page) => page.getByRole('heading', { name: 'Opening your workspace…', exact: true })
async function boundedOpening(page: Page) {
  await expect(opening(page)).toBeVisible()
  const box = await page.getByRole('region', { name: 'Opening workspace' }).boundingBox()
  expect(box).not.toBeNull()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(page.viewportSize()!.width + 1)
  expect(box!.y).toBeGreaterThanOrEqual(0)
  expect(box!.y + box!.height).toBeLessThanOrEqual(page.viewportSize()!.height + 1)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
}

test.describe('BOG UI startup program and authentication gates', () => {
  test('branding and session overlap while actor and workspace remain closed until each approval', async ({ page }) => {
    const calls = await transport(page)
    let heldBrand!: Route
    let heldActor!: Route
    let heldWorkspace!: Route
    await page.route('http://api.test/api/public/brand**', route => { heldBrand = route })
    await page.route('http://api.test/api/v1/auth/me', route => { calls.actor++; heldActor = route })
    await page.route('**/api/v1/startup-qa/workspace', route => { calls.workspace++; heldWorkspace = route })
    await page.goto('/startup-qa.html')
    await boundedOpening(page)
    await expect.poll(() => calls.session).toBe(1)
    expect(heldBrand).toBeTruthy()
    expect(calls.actor).toBe(0)
    expect(calls.workspace).toBe(0)
    await expect(page.getByRole('button', { name: /reload|try again/i })).toHaveCount(0)
    await expect(page.getByRole('status')).toHaveText('Checking your program…')
    await heldBrand.fulfill({ json: brandResponse })
    await expect.poll(() => calls.actor).toBe(1)
    await boundedOpening(page)
    await expect(page.getByRole('status')).toHaveText('Signing you in securely…')
    expect(calls.workspace).toBe(0)
    expect(heldActor.request().headers().authorization).toBe('Bearer fictional-short-lived')
    await heldActor.fulfill({ json: { user } })
    await expect.poll(() => calls.workspace).toBe(1)
    await boundedOpening(page)
    await expect(page.getByRole('status')).toHaveText('Loading your household…')
    await heldWorkspace.fulfill({ json: { ready: true } })
    await expect(page.getByTestId('startup-verified-workspace')).toBeVisible()
    expect(calls).toEqual({ session: 2, actor: 1, workspace: 1 })
    await expect(opening(page)).toHaveCount(0)
  })

  for (const unavailable of [false, true]) {
    test(`public branding ${unavailable ? 'unavailable' : 'failure'} never opens private data and retry recovers`, async ({ page }) => {
      const calls = await transport(page)
      let brands = 0
      await page.route('http://api.test/api/public/brand**', route => ++brands === 1 ? route.fulfill({ status: unavailable ? 404 : 503, json: unavailable ? { ...brandResponse, available: false } : {} }) : route.fulfill({ json: brandResponse }))
      await page.goto('/startup-qa.html')
      await expect(page.getByRole('heading', { name: unavailable ? 'This program link is not available' : 'Your program could not load' })).toBeVisible()
      expect(calls.actor).toBe(0)
      expect(calls.workspace).toBe(0)
      await expect(page.getByTestId('startup-verified-workspace')).toHaveCount(0)
      await page.getByRole('button', { name: 'Try again', exact: true }).click()
      await expect(page.getByTestId('startup-verified-workspace')).toBeVisible()
      expect(brands).toBe(2)
      expect(calls.actor).toBe(1)
      expect(calls.workspace).toBe(1)
    })
  }

  test('recovery appears only after sustained waiting and does not compete with normal startup', async ({ page }) => {
    await page.clock.install()
    const calls = await transport(page)
    await page.route('http://api.test/api/public/brand**', route => route.fulfill({ json: brandResponse }))
    await page.route('**/api/auth/session', route => { if (++calls.session > 1) return route.fulfill({ json: session }) })
    await page.goto('/startup-qa.html')
    await expect(page.getByRole('status')).toHaveText('Signing you in securely…')
    await boundedOpening(page)
    await expect(page.getByRole('button', { name: 'Try again' })).toHaveCount(0)
    await page.clock.fastForward(8001)
    await expect(page.getByText('This is taking a little longer. You can keep waiting or try again.')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Try again' })).toBeVisible()
    expect(calls.actor).toBe(0)
    await page.getByRole('button', { name: 'Try again' }).click()
    await expect(page.getByTestId('startup-verified-workspace')).toBeVisible()
    // Explicit reload restarts the cookie read, then the actor token getter
    // performs its fresh authoritative cookie check before verification.
    expect(calls).toEqual({ session: 3, actor: 1, workspace: 1 })
  })

  test('session outage retains a closed workspace and retry restores existing access', async ({ page }) => {
    const calls = await transport(page)
    let sessions = 0
    await page.route('http://api.test/api/public/brand**', route => route.fulfill({ json: brandResponse }))
    await page.route('**/api/auth/session', route => ++sessions === 1 ? route.fulfill({ status: 503, json: {} }) : route.fulfill({ json: session }))
    await page.goto('/startup-qa.html')
    await expect(page.getByRole('heading', { name: 'We couldn’t finish checking your access.' })).toBeVisible()
    expect(calls.actor).toBe(0)
    expect(calls.workspace).toBe(0)
    await page.getByRole('button', { name: 'Check access again' }).click()
    await expect(page.getByTestId('startup-verified-workspace')).toBeVisible()
    expect(calls.actor).toBe(1)
  })

  for (const wrongActor of [false, true]) {
    test(`a valid cookie with ${wrongActor ? 'a different Rails actor' : 'denied invitation access'} cannot open the workspace`, async ({ page }) => {
      const calls = await transport(page)
      await page.route('http://api.test/api/public/brand**', route => route.fulfill({ json: brandResponse }))
      await page.route('http://api.test/api/v1/auth/me', route => {
        calls.actor++
        return wrongActor ? route.fulfill({ json: { user: { ...user, auth_subject: 'user_OTHER' } } }) : route.fulfill({ status: 403, json: { error: 'This account has no program invitation.' } })
      })
      await page.goto('/startup-qa.html')
      await expect(page.getByRole('heading', { name: 'We couldn’t finish checking your access.' })).toBeVisible()
      expect(calls.actor).toBe(1)
      expect(calls.workspace).toBe(0)
      await expect(page.getByTestId('startup-verified-workspace')).toHaveCount(0)
    })
  }
})
