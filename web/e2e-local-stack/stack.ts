import { test as base, expect, type Page } from '@playwright/test'

export const API = process.env.LOCAL_STACK_API_URL ?? 'http://127.0.0.1:3300'
const LOCAL = new Set(['127.0.0.1', 'localhost', '[::1]'])

type Role = 'participant' | 'coach' | 'admin'
const TOKENS: Record<Role, string> = {
  participant: 'test_token:e2e_participant:participant@pilot.test:Test:Participant',
  coach: 'test_token:e2e_coach:coach@pilot.test:Coach:Mendiola',
  admin: 'test_token:e2e_admin:admin@pilot.test:Pilot:Admin',
}

// Every test watches the network: any request to a host other than this machine fails it.
export const test = base.extend<{ outside: string[] }>({
  outside: [async ({ page }, use) => {
    const outside: string[] = []
    page.on('request', request => {
      const url = new URL(request.url())
      if (url.protocol.startsWith('http') && !LOCAL.has(url.hostname)) outside.push(url.host)
    })
    await use(outside)
    expect([...new Set(outside)], 'requests left this machine').toEqual([])
  }, { auto: true }],
})
export { expect }

/** Opens the app signed in as one of the fictional people bin/local-stack seeds. */
export async function signIn(page: Page, role: Role, path = '/') {
  const separator = path.includes('?') ? '&' : '?'
  await page.goto(`${path}${separator}pilot_e2e_role=${role}&pilot_e2e_live_api=true`)
  // Signed in once the app's navigation and the page's own heading are showing.
  await expect(page.getByRole('navigation').first()).toBeVisible({ timeout: 30_000 })
  await expect(page.locator('h2').first()).toBeVisible({ timeout: 30_000 })
}

/** A direct call to the local API, for setup checks and for reading what was saved. */
export async function api<T>(role: Role, path: string, workspaceId?: number): Promise<T> {
  const headers: Record<string, string> = { Authorization: `Bearer ${TOKENS[role]}`, Accept: 'application/json' }
  if (workspaceId) headers['X-Coach-Workspace-Id'] = String(workspaceId)
  const response = await fetch(`${API}${path}`, { headers })
  if (!response.ok) throw new Error(`${path} answered ${response.status}`)
  return response.json() as Promise<T>
}

/** Budget's report month in a given year, whatever year Budget opens on. */
export async function showBudgetMonth(page: Page, year: number, month: string) {
  const label = page.locator('.budget-year-label')
  for (let step = 0; step < 5 && Number(await label.textContent()) !== year; step += 1) {
    await page.getByRole('button', { name: Number(await label.textContent()) > year ? 'Previous year' : 'Next year' }).click()
    await expect(label).not.toHaveText('')
  }
  await expect(label).toHaveText(String(year))
  await page.getByLabel('Report month').selectOption({ label: month })
}

/** The More menu on phones, the sidebar on desktop. */
export async function openSection(page: Page, name: string) {
  const direct = page.getByRole('link', { name, exact: true }).first()
  const more = page.getByRole('button', { name: 'More', exact: true })
  await expect(direct.or(more).first()).toBeVisible()
  if (await direct.isVisible()) return direct.click()
  await more.click()
  await page.getByRole('link', { name, exact: true }).first().click()
}
