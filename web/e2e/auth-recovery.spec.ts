import { expect, test } from '@playwright/test'

const qaUser = {
  id: 901, clerk_id: 'qa_auth_recovery_user', email: 'auth-recovery@pilot.test',
  first_name: 'Fictional', last_name: 'Participant', full_name: 'Fictional Participant',
  role: 'participant', is_admin: false, is_coach: false, is_participant: true, is_staff: false,
}
const authRoute = 'http://api.test/api/v1/auth/me'

test.describe('BOG UI auth verification recovery', () => {
  test('a session identity opens without loading a full profile', async ({ page }) => {
    await page.route(authRoute, route => route.fulfill({ json: { user: qaUser } }))
    await page.goto('/auth-recovery-qa.html?mode=ready')
    await expect(page.getByTestId('verified-workspace')).toBeVisible()
    await expect(page.getByText('This fixture never requests a full Clerk profile.')).toBeVisible()
  })

  for (const mode of ['sdk-pending', 'identity-pending', 'token-pending']) {
    test(`${mode} stops waiting at the deadline and stays closed`, async ({ page }) => {
      let requestCount = 0
      await page.route(authRoute, route => { requestCount += 1; return route.fulfill({ json: { user: qaUser } }) })
      await page.clock.install()
      await page.goto(`/auth-recovery-qa.html?mode=${mode}`)
      await expect(page.getByRole('heading', { name: 'Opening your workspace…' })).toBeVisible()
      await expect(page.getByRole('button', { name: 'Try again', exact: true })).toHaveCount(0)
      await page.clock.fastForward(8_100)
      await expect(page.getByRole('button', { name: 'Try again', exact: true })).toBeVisible()
      await page.clock.fastForward(22_100)
      await expect(page.getByRole('heading', { name: 'We couldn’t finish checking your access.' })).toBeVisible()
      await expect(page.getByRole('alert')).toContainText('took too long')
      await expect(page.getByTestId('verified-workspace')).toHaveCount(0)
      expect(requestCount).toBe(0)
      if (mode === 'token-pending') {
        await page.getByRole('button', { name: 'Release late token' }).click()
        await page.clock.fastForward(100)
        await expect(page.getByTestId('verified-workspace')).toHaveCount(0)
        await expect(page.getByRole('heading', { name: 'We couldn’t finish checking your access.' })).toBeVisible()
      }
      await page.getByRole('combobox', { name: 'Session state' }).selectOption('ready')
      if (mode === 'token-pending') await page.getByRole('button', { name: 'Check access again' }).click()
      await expect(page.getByTestId('verified-workspace')).toBeVisible()
    })
  }

  test('network failures offer retry and retry verifies the same identity', async ({ page }) => {
    let requestCount = 0
    await page.route(authRoute, route => {
      requestCount += 1
      return requestCount === 1
        ? route.abort('failed')
        : route.fulfill({ json: { user: qaUser } })
    })
    await page.goto('/auth-recovery-qa.html?mode=ready')
    await expect(page.getByRole('heading', { name: 'We couldn’t finish checking your access.' })).toBeVisible()
    await expect(page.getByTestId('verified-workspace')).toHaveCount(0)
    await page.getByRole('button', { name: 'Check access again' }).click()
    await expect(page.getByTestId('verified-workspace')).toBeVisible()
    expect(requestCount).toBe(2)
  })

  test('a denied account stays closed and can sign out', async ({ page }) => {
    await page.route(authRoute, route => route.fulfill({ status: 403, json: { error: 'Program invitation required' } }))
    await page.goto('/auth-recovery-qa.html?mode=ready')
    await expect(page.getByRole('heading', { name: 'Your account does not have program access.' })).toBeVisible()
    await expect(page.getByTestId('verified-workspace')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Reload page' })).toBeVisible()
    await page.getByRole('button', { name: 'Sign out' }).click()
    await expect(page.getByRole('heading', { name: 'Signed out' })).toBeVisible()
  })

  test('a response for another account never opens the workspace', async ({ page }) => {
    await page.route(authRoute, route => route.fulfill({ json: { user: { ...qaUser, clerk_id: 'someone_else' } } }))
    await page.goto('/auth-recovery-qa.html?mode=ready')
    await expect(page.getByRole('heading', { name: 'We couldn’t finish checking your access.' })).toBeVisible()
    await expect(page.getByTestId('verified-workspace')).toHaveCount(0)
  })

  test('recovery controls fit the viewport and the reload action works', async ({ page }) => {
    await page.clock.install()
    await page.goto('/auth-recovery-qa.html?mode=sdk-pending')
    await page.clock.fastForward(30_100)
    const button = page.getByRole('button', { name: 'Reload page' })
    await expect(button).toBeVisible()
    await button.scrollIntoViewIfNeeded()
    const bounds = await button.boundingBox()
    expect(bounds).not.toBeNull()
    expect(bounds!.x).toBeGreaterThanOrEqual(0)
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(page.viewportSize()!.width)
    const reload = page.waitForEvent('load')
    await button.click()
    await reload
    await expect(page.getByRole('heading', { name: 'Opening your workspace…' })).toBeVisible()
  })
})


test.describe('WorkOS Auth recovery', () => {
  const workosUser = { ...qaUser, auth_provider: 'workos', auth_subject: qaUser.clerk_id }
  test('verifies the active subject and keeps the account control usable in the header slot', async ({ page }) => {
    await page.route(authRoute, route => route.fulfill({ json: { user: workosUser } }))
    await page.goto('/auth-recovery-qa.html?provider=workos')
    await expect(page.getByTestId('verified-workspace')).toBeVisible()
    const account = page.getByLabel('Account and help', { exact: true })
    await account.click()
    const menu = page.locator('.shell-account-panel')
    await expect(menu).toContainText('Fictional Participant')
    const bounds = await menu.boundingBox()
    expect(bounds!.x).toBeGreaterThanOrEqual(0)
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(page.viewportSize()!.width)
    await page.keyboard.press('Escape')
    await expect(account).toBeFocused()
    await expect(menu).not.toBeVisible()
    await account.click()
    await page.getByRole('button', { name: 'Sign out', exact: true }).click()
    await expect(page.getByRole('heading', { name: 'Signed out' })).toBeVisible()
  })
  for (const role of ['participant', 'coach', 'admin']) {
    test(`one account menu fits long email and direct sign-out for ${role}`, async ({ page }) => {
      const email = 'fictional.long.account.address@household-pilot.example.test'
      await page.route(authRoute, route => route.fulfill({ json: { user: { ...workosUser, email, role, is_admin: role === 'admin', is_coach: role === 'coach', is_participant: role === 'participant' } } }))
      await page.goto('/auth-recovery-qa.html?provider=workos')
      const account = page.getByLabel('Account and help', { exact: true })
      await account.click()
      const panel = page.locator('.shell-account-panel')
      await expect(panel.getByRole('button', { name: 'Sign out', exact: true })).toBeVisible()
      await expect(panel.getByRole('button', { name: 'Guide', exact: true })).toBeVisible()
      await expect(panel.getByText(email, { exact: true })).toHaveAttribute('title', email)
      await expect(panel.locator('details')).toHaveCount(0)
      const layout = await panel.evaluate(node => {
        const panel = node.getBoundingClientRect()
        const email = node.querySelector('.shell-account-email')!.getBoundingClientRect()
        const style = getComputedStyle(node.querySelector('.shell-account-email')!)
        return { left: panel.left, right: panel.right, bottom: panel.bottom, emailInside: email.left >= panel.left && email.right <= panel.right, nowrap: style.whiteSpace, height: email.height, lineHeight: parseFloat(style.lineHeight), width: innerWidth, viewHeight: innerHeight }
      })
      expect(layout.left).toBeGreaterThanOrEqual(0)
      expect(layout.right).toBeLessThanOrEqual(layout.width)
      expect(layout.bottom).toBeLessThanOrEqual(layout.viewHeight)
      expect(layout.emailInside).toBe(true)
      expect(layout.nowrap).toBe('nowrap')
      const signOut = panel.getByRole('button', { name: 'Sign out', exact: true })
      expect((await signOut.boundingBox())!.height).toBeGreaterThanOrEqual(44)
      await page.keyboard.press('Escape')
      await expect(account).toBeFocused()
      await expect(panel).not.toBeVisible()
      await page.keyboard.press('Enter')
      await expect(signOut).toBeVisible()
      await page.getByText('Development QA · fictional account', { exact: true }).click()
      await expect(panel).not.toBeVisible()
      await account.click()
      await signOut.click()
      await expect(page.getByRole('heading', { name: 'Signed out' })).toBeVisible()
      await expect(panel).toHaveCount(0)
    })
  }
  for (const status of [401, 403, 503]) {
    test(`HTTP ${status} stays closed with the right recovery`, async ({ page }) => {
      await page.route(authRoute, route => route.fulfill({ status, json: { error: status === 503 ? 'Secure access service is unavailable' : 'Access denied' } }))
      await page.goto('/auth-recovery-qa.html?provider=workos')
      const heading = status === 401 ? 'Sign in again to continue.' : status === 503 ? 'Secure access is temporarily unavailable.' : 'Your account does not have program access.'
      await expect(page.getByRole('heading', { name: heading })).toBeVisible()
      await expect(page.getByTestId('verified-workspace')).toHaveCount(0)
      await expect(page.getByRole('button', { name: status === 401 ? 'Sign in again' : 'Check access again' })).toBeVisible()
    })
  }
  test('rejects another provider even when its subject matches the active session', async ({ page }) => {
    await page.route(authRoute, route => route.fulfill({ json: { user: { ...workosUser, auth_provider: 'clerk' } } }))
    await page.goto('/auth-recovery-qa.html?provider=workos')
    await expect(page.getByRole('heading', { name: 'We couldn’t finish checking your access.' })).toBeVisible()
    await expect(page.getByTestId('verified-workspace')).toHaveCount(0)
  })
})
