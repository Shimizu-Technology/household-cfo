import { api, expect, signIn, test } from './stack'

type Me = { user: { coach_workspaces?: Array<{ id: number; name: string }> } }
type Assignable = { cohorts: Array<{ name: string; persona_assignment?: { persona?: { name?: string } } | null }> }
const stamp = new Date().toISOString().slice(11, 19).replaceAll(':', '')

test('Go live starts with no group ticked and reaches only the group she ticks @saves', async ({ page }) => {
  const me = await api<Me>('admin', '/api/v1/auth/me')
  if (!me.user.coach_workspaces?.length) {
    await signIn(page, 'admin', '/admin/settings')
    await page.getByText('Start a new program').click()
    await page.getByPlaceholder('Mrs. Mel’s program').fill('Local test program')
    await page.getByRole('button', { name: 'Create program' }).click()
    await expect(page.getByRole('button', { name: 'Create program' })).toHaveCount(0)
  }

  const groups = [`Group A ${stamp}`, `Group B ${stamp}`]
  for (const name of groups) {
    await signIn(page, 'admin', '/admin/groups')
    await page.getByRole('button', { name: 'New group' }).click()
    await page.getByPlaceholder('Tuesday evening group').fill(name)
    await page.getByRole('button', { name: 'Create group' }).click()
    await expect(page.getByRole('heading', { name })).toBeVisible()
  }
  // Group A gets a tools change to publish.
  await page.getByRole('button', { name: '‹ All groups' }).click()
  await page.getByText(groups[0], { exact: true }).click()
  await page.getByRole('button', { name: 'Tools people can use' }).click()
  await page.getByLabel('Include Wealth', { exact: true }).click()
  await page.getByRole('button', { name: 'Save draft' }).click()
  await expect(page.getByText('Tools saved. Review them in Go live.')).toBeVisible()

  await signIn(page, 'admin', '/admin/coaching')
  // A new program's first visit asks what the assistant is called; the default name starts its voice draft.
  const describe = page.getByRole('button', { name: 'Describe this assistant' })
  await expect(describe.or(page.getByRole('heading', { name: 'Your coach’s voice' })).first()).toBeVisible()
  if (await describe.isVisible()) {
    await describe.click()
    await expect(page.getByRole('heading', { name: 'How Mia sounds so far' })).toBeVisible()
  }
  await page.getByRole('button', { name: '3 · Preview and go live' }).click()
  for (const name of groups) await expect(page.getByLabel(name, { exact: true })).not.toBeChecked()
  await page.getByLabel(groups[0], { exact: true }).check()
  await page.getByRole('button', { name: 'Preview answers' }).click()
  await page.getByRole('button', { name: 'Approve and go live' }).click({ timeout: 60_000 })
  await expect(page.getByText(`Live for ${groups[0]}.`, { exact: false })).toBeVisible({ timeout: 60_000 })
  await expect(page.getByText(groups[1], { exact: false }).filter({ hasText: 'Live for' })).toHaveCount(0)

  // Read back what each group now has, not only the receipt: only the ticked group got the program's voice.
  const workspace = (await api<Me>('admin', '/api/v1/auth/me')).user.coach_workspaces?.[0]?.id
  const { cohorts } = await api<Assignable>('admin', '/api/v1/admin/personas/assignable_cohorts', workspace)
  const assigned = (name: string) => Boolean(cohorts.find(cohort => cohort.name === name)?.persona_assignment)
  expect([assigned(groups[0]), assigned(groups[1])]).toEqual([true, false])
})

test('Groups lists the new groups at phone width @reads', async ({ page }) => {
  await signIn(page, 'admin', '/admin/groups')
  await expect(page.getByText(/Group A \d{6}/).first()).toBeVisible()
  await expect(page.getByText(/Group B \d{6}/).first()).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})
