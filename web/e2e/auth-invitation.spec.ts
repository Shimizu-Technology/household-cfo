import { expect, test } from '@playwright/test'
test.describe('Auth recovery free server session invitation transport', () => {
  for (const [action, screenHint] of [['Continue company sign-in', 'sign-in'], ['Create invited account', 'sign-up']]) {
    test(`${action} removes the credential from the URL and sends it only to the same-origin server`, async ({ page }) => {
      await page.addInitScript(() => { window.open = () => null })
      const appOrigin = new URL(test.info().project.use.baseURL!).origin
      let login: Record<string, unknown> | null = null
      const authorization = new URL('https://api.workos.com/user_management/authorize')
      authorization.searchParams.set('client_id', 'client_FICTIONAL1')
      authorization.searchParams.set('redirect_uri', `${appOrigin}/api/auth/callback`)
      authorization.searchParams.set('state', 'server-generated-opaque-state')
      await page.route('**/api/auth/session', route => route.fulfill({ json: { client_id: 'client_FICTIONAL1', user: null } }))
      await page.route('**/api/auth/login', route => {
        login = route.request().postDataJSON()
        expect(route.request().headers()['x-frontend-origin']).toBe(appOrigin)
        return route.fulfill({ json: { authorization_url: authorization.href } })
      })
      await page.route('https://api.workos.com/user_management/authorize**', route => route.fulfill({ contentType: 'text/html', body: '<h1>Fictional hosted sign-in</h1>' }))
      await page.goto('/auth-invitation-qa.html?invitation_token=fictional%2Bopaque%2Ftoken%3D')
      const control = page.getByRole('button', { name: action, exact: true })
      await expect(control).toBeEnabled()
      expect(page.url()).not.toContain('invitation_token')
      expect(page.url()).not.toContain('opaque')
      expect(await page.evaluate(() => localStorage.length)).toBe(0)
      await control.click()
      await expect(page.getByRole('dialog')).toBeVisible()
      await page.getByRole('button', { name: 'Continue with work SSO', exact: true }).click()
      await expect(page.getByRole('heading', { name: 'Fictional hosted sign-in' })).toBeVisible()
      expect(login).toEqual({ screen_hint: screenHint, organization_id: 'org_FICTIONAL1', invitation_token: 'fictional+opaque/token=', return_to: `${appOrigin}/organization-access` })
      expect(page.url()).not.toContain('opaque%2Ftoken')
      expect(new URL(page.url()).searchParams.get('state')).toBe('server-generated-opaque-state')
    })
  }
})
