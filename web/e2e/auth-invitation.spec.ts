import { expect, test } from '@playwright/test'
test.describe('Auth recovery hosted invitation transport', () => {
  for (const action of ['Continue company sign-in', 'Create invited account']) {
    test(`${action} sanitizes the app URL and sends the opaque credential only as an SDK authorization parameter`, async ({ page }) => {
      let authorization: URL | null = null
      await page.route('https://auth-provider.test/**', route => {
        authorization = new URL(route.request().url())
        return route.fulfill({ contentType: 'text/html', body: '<h1>Fictional hosted sign-in</h1>' })
      })
      const appOrigin = new URL(test.info().project.use.baseURL!).origin
      await page.goto('/auth-invitation-qa.html?invitation_token=fictional%2Bopaque%2Ftoken%3D')
      const control = page.getByRole('button', { name: action, exact: true })
      await expect(control).toBeEnabled()
      expect(new URL(page.url()).pathname).toBe('/login')
      expect(page.url()).not.toContain('invitation_token')
      expect(page.url()).not.toContain('opaque')
      await control.click()
      await expect(page.getByRole('heading', { name: 'Fictional hosted sign-in' })).toBeVisible()
      expect(authorization).not.toBeNull()
      const params = authorization!.searchParams
      expect(params.get('client_id')).toBe('client_FICTIONAL1')
      expect(params.get('organization_id')).toBe('org_FICTIONAL1')
      expect(params.get('invitation_token')).toBe('fictional+opaque/token=')
      expect(params.get('code_challenge_method')).toBe('S256')
      expect(params.get('code_challenge')).toBeTruthy()
      const state = JSON.parse(params.get('state')!)
      expect(state.returnTo).toBe(`${appOrigin}/organization-access`)
      expect(JSON.stringify(state)).not.toContain('opaque')
      expect(JSON.stringify(state)).not.toContain('4000')
    })
  }
})
