import { expect, test, type Page } from '@playwright/test'

// Real server, real permissions. The Admin side must show each kind of staff member what the server lets them do,
// with nothing mocked: the sections, Today, Reports, and the tools of a group.
//
// Needs a local API seeded with .codex/qa-kit/evidence/round5/r5-a2-fix1/seed.rb, with the e2e coach identity (e2e_coach)
// pointed at one person at a time (asrole.rb). Run once per role:
//   HCFO_A2_WEB=http://127.0.0.1:5404 HCFO_A2_ROLE=owner|editor|reviewer|admin npx playwright test e2e/admin-roles-live.spec.ts
const web = process.env.HCFO_A2_WEB
const role = process.env.HCFO_A2_ROLE
const e2eRole = role === 'admin' ? 'admin' : 'coach'
const group = 'Bank of Guam 90 day savings'
const fits = (page: Page) => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)
const stamp = Date.now().toString().slice(-7)

async function open(page: Page, path: string) {
  await page.goto(`${web}${path}?pilot_e2e_role=${e2eRole}&pilot_e2e_live_api=true`)
  await expect(page.locator('.admin-content')).toBeVisible()
}
async function sectionsOffered(page: Page) {
  await open(page, '/admin/today')
  const labels = await page.locator('.admin-sidebar-nav a, .admin-section-menu nav a').evaluateAll(links => links.map(link => link.querySelector('strong')?.textContent ?? ''))
  return [...new Set(labels)]
}
async function refused(page: Page, path: string) {
  await open(page, path)
  await expect(page.getByRole('heading', { name: 'That section isn’t part of your role' })).toBeVisible()
}

test.describe('Admin UI real server: program owner', () => {
  test.skip(!web || role !== 'owner', 'Needs the seeded local API, signed in as the program owner')
  test('has every section, and Today, Groups tools and cancelling an invitation work', async ({ page }) => {
    test.setTimeout(120_000)
    expect(await sectionsOffered(page)).toEqual(['Today', 'People', 'Groups', 'Coaching', 'Reports', 'Support', 'Settings'])
    await expect(page.getByRole('alert')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Invite people' })).toBeVisible()
    await expect(page.getByText(/Bog1 Member/)).toBeVisible()
    await open(page, '/admin/groups')
    await page.getByRole('button', { name: group }).click()
    await page.getByRole('button', { name: 'Tools people can use' }).click()
    await expect(page.getByLabel('Include Optionality')).toBeEnabled()
    await expect(page.getByRole('button', { name: 'Save draft' })).toBeVisible()
    // Invite someone to the group without sending email, then cancel that invitation. The server is the judge of both.
    await open(page, '/admin/people')
    await page.getByRole('button', { name: 'Invite people', exact: true }).click()
    const invite = page.getByRole('dialog')
    const email = `cancel-${stamp}@pilot.test`
    await invite.getByLabel(/Email addresses/).fill(email)
    await invite.getByLabel('Group').selectOption({ label: group })
    await invite.getByRole('checkbox', { name: /Email them an invitation now/ }).uncheck()
    await invite.getByRole('button', { name: 'Invite', exact: true }).click()
    await page.getByRole('alertdialog').getByRole('button').nth(1).click()
    await expect(invite.getByText('1 person invited.')).toBeVisible()
    await invite.getByRole('button', { name: 'Done' }).click()
    await page.getByLabel('Find someone').fill(email)
    await page.locator('.admin-table tbody th button, .admin-list-row').first().click()
    const person = page.getByRole('dialog')
    await expect(person.getByText(/^Invited/).first()).toBeVisible()
    await expect(person.getByRole('button', { name: 'Remove from group' })).toHaveCount(0)
    await person.getByRole('button', { name: 'Cancel the invitation' }).click()
    await page.getByRole('alertdialog').getByRole('button').nth(1).click()
    await expect(page.getByRole('status').filter({ hasText: /was cancelled/ })).toBeVisible()
    await expect(page.getByText(email)).toHaveCount(0)
    await page.reload()
    await page.getByLabel('Find someone').fill(email)
    await expect(page.getByText(email)).toHaveCount(0)
    expect(await fits(page)).toBe(true)
  })
})

test.describe('Admin UI real server: editor', () => {
  test.skip(!web || role !== 'editor', 'Needs the seeded local API, signed in as an editor')
  test('has Today and Coaching, reads only what an editor may, and edits group tools under Coaching', async ({ page }) => {
    test.setTimeout(120_000)
    expect(await sectionsOffered(page)).toEqual(['Today', 'Coaching'])
    await expect(page.getByRole('alert')).toHaveCount(0)
    await expect(page.getByText(/access required/i)).toHaveCount(0)
    await expect(page.getByText(/Bog1 Member/)).toBeVisible()
    await expect(page.getByRole('button', { name: 'Invite people' })).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Create a group' })).toHaveCount(0)
    for (const path of ['/admin/groups', '/admin/people', '/admin/reports', '/admin/settings']) await refused(page, path)
    await open(page, '/admin/coaching')
    await page.getByRole('button', { name: 'Open group tools', exact: true }).click()
    await page.getByRole('combobox', { name: 'Group' }).selectOption({ label: group })
    // The server gives an editor edit, but not preview, publish or going back to an earlier version.
    await expect(page.getByLabel('Include Optionality')).toBeEnabled()
    await page.getByLabel('Include Optionality').click()
    await expect(page.getByRole('button', { name: 'Save draft' })).toBeEnabled()
    await page.getByLabel('Include Optionality').click()
    expect(await fits(page)).toBe(true)
  })
})

test.describe('Admin UI real server: reviewer', () => {
  test.skip(!web || role !== 'reviewer', 'Needs the seeded local API, signed in as a reviewer')
  test('has Today, Coaching and Reports, can save a report, and can see but not change group tools', async ({ page }) => {
    test.setTimeout(120_000)
    expect(await sectionsOffered(page)).toEqual(['Today', 'Coaching', 'Reports'])
    await expect(page.getByRole('alert')).toHaveCount(0)
    await expect(page.getByText(/Bog1 Member/)).toBeVisible()
    for (const path of ['/admin/groups', '/admin/people', '/admin/support', '/admin/settings']) await refused(page, path)
    await open(page, '/admin/reports')
    await expect(page.getByRole('heading', { name: group })).toBeVisible()
    await expect(page.getByText('Day 30', { exact: true })).toBeVisible()
    await expect(page.getByRole('alert')).toHaveCount(0)
    await expect(page.getByText(/Only the coaches of this group can save it/)).toHaveCount(0)
    await open(page, '/admin/coaching')
    await page.getByRole('button', { name: 'Open group tools', exact: true }).click()
    await page.getByRole('combobox', { name: 'Group' }).selectOption({ label: group })
    await expect(page.getByLabel('Include Optionality')).toBeDisabled()
    await expect(page.getByRole('button', { name: 'Save draft' })).toBeDisabled()
    await expect(page.getByText('Your role can see these tools but can’t change them.')).toBeVisible()
    expect(await fits(page)).toBe(true)
  })
})

test.describe('Admin UI real server: platform administrator', () => {
  test.skip(!web || role !== 'admin', 'Needs the seeded local API, signed in as the platform administrator')
  test('has every section, filters staff, and can cancel an invitation without choosing a program first', async ({ page }) => {
    test.setTimeout(120_000)
    expect(await sectionsOffered(page)).toEqual(['Today', 'People', 'Groups', 'Coaching', 'Reports', 'Support', 'Settings'])
    await open(page, '/admin/people')
    await expect(page.getByLabel('Role')).toBeVisible()
    await page.getByLabel('Find someone').fill('Ines')
    await page.locator('.admin-table tbody th button, .admin-list-row').first().click()
    const seeded = page.getByRole('dialog')
    await expect(seeded.getByRole('button', { name: 'Cancel the invitation' })).toBeVisible()
    await expect(seeded.getByText(/Choose a program at the top of the page to remove/)).toHaveCount(0)
    await page.keyboard.press('Escape')
    // Cancel an invitation made just for this test (never the shared seed), with no program chosen, and read the result back.
    await page.getByRole('button', { name: 'Invite people', exact: true }).click()
    const invite = page.getByRole('dialog')
    const email = `admin-cancel-${stamp}@pilot.test`
    await invite.getByLabel(/Email addresses/).fill(email)
    await invite.getByLabel('Group').selectOption({ label: group })
    await invite.getByRole('checkbox', { name: /Email them an invitation now/ }).uncheck()
    await invite.getByRole('button', { name: 'Invite', exact: true }).click()
    await page.getByRole('alertdialog').getByRole('button').nth(1).click()
    await expect(invite.getByText('1 person invited.')).toBeVisible()
    await invite.getByRole('button', { name: 'Done' }).click()
    await page.getByLabel('Find someone').fill(email)
    await page.locator('.admin-table tbody th button, .admin-list-row').first().click()
    await page.getByRole('dialog').getByRole('button', { name: 'Cancel the invitation' }).click()
    await page.getByRole('alertdialog').getByRole('button').nth(1).click()
    await expect(page.getByRole('status').filter({ hasText: /was cancelled/ })).toBeVisible()
    await page.reload()
    await page.getByLabel('Find someone').fill(email)
    await expect(page.getByText(email)).toHaveCount(0)
    await open(page, '/admin/groups')
    await page.getByRole('checkbox', { name: /Show archived groups/ }).count()
    expect(await fits(page)).toBe(true)
  })
})
