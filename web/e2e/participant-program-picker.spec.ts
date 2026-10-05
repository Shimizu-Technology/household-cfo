import { expect, test } from '@playwright/test'

const current = { id: 104, name: 'Fictional current program with a deliberately long descriptive name for phone layouts', status: 'active' }
const programs = Array.from({ length: 104 }, (_, index) => index === 103 ? current : ({ id: index + 1, name: `Fictional program ${index + 1}`, status: 'completed' }))

test('BOG UI participant program picker preserves current selection and pages all native choices without overflow', async ({ page }, testInfo) => {
  const reads: number[] = []
  await page.route('**/api/v1/participant_programs**', async route => {
    const cursor = Number(new URL(route.request().url()).searchParams.get('cursor') ?? 0)
    reads.push(cursor)
    const rows = programs.filter(row => row.id > cursor).slice(0, 50)
    await route.fulfill({ json: { actor_id: 7, current_cohort_id: current.id, current_program: current, selection_unavailable: false, programs: rows, next_cursor: rows.at(-1)!.id < 104 ? rows.at(-1)!.id : null } })
  })
  await page.goto('/program-picker-qa.html')
  const select = page.getByRole('combobox', { name: 'Switch participant program' })
  await expect(select).toHaveValue('104')
  await expect(page.getByText('No explicit program choice yet.')).toBeVisible()
  await expect(select.locator('option')).toHaveCount(52)
  await page.getByRole('button', { name: 'Load more programs' }).click()
  await expect(select.locator('option')).toHaveCount(102)
  await page.getByRole('button', { name: 'Load more programs' }).click()
  await expect(select.locator('option')).toHaveCount(105)
  expect(reads).toEqual([0, 50, 100])
  await expect(page.getByRole('button', { name: 'Load more programs' })).toHaveCount(0)
  await select.focus()
  await expect(select).toBeFocused()
  await select.selectOption('103')
  await expect(page.getByText('Explicit program choice: 103')).toBeVisible()
  const layout = await page.evaluate(() => ({ width: window.innerWidth, scrollWidth: document.documentElement.scrollWidth, overflowing: [...document.querySelectorAll('main *')].filter(element => element.getBoundingClientRect().right > window.innerWidth).map(element => ({ tag: element.tagName, width: element.getBoundingClientRect().width })) }))
  expect(layout.scrollWidth, JSON.stringify(layout)).toBeLessThanOrEqual(layout.width)
  const bounds = await select.boundingBox()
  expect(bounds!.height).toBeGreaterThanOrEqual(44)
  await page.screenshot({ path: testInfo.outputPath('synthetic-program-picker.png'), fullPage: true })
})

test('BOG UI participant unavailable program needs explicit alternative selection and supports private read retry', async ({ page }) => {
  let attempts = 0
  await page.route('**/api/v1/participant_programs**', async route => {
    if (++attempts === 1) { await route.fulfill({ status: 403, json: { errors: ['Synthetic session unavailable.'] } }); return }
    await route.fulfill({ json: { actor_id: 7, current_cohort_id: null, current_program: null, selection_unavailable: true, programs: [{ id: 3, name: 'Fictional alternative', status: 'active' }], next_cursor: null } })
  })
  await page.goto('/program-picker-qa.html')
  await expect(page.getByRole('alert')).toContainText('Synthetic session unavailable.')
  await expect(page.getByRole('combobox')).toHaveCount(0)
  await page.getByRole('button', { name: 'Retry program choices' }).click()
  await expect(page.getByText(/selected program is unavailable/)).toBeVisible()
  await expect(page.getByText('No explicit program choice yet.')).toBeVisible()
  await expect(page.getByRole('combobox')).toHaveCount(0)
  const button = page.getByRole('button', { name: 'Use Fictional alternative' })
  await button.focus()
  await button.press('Enter')
  await expect(page.getByText('Explicit program choice: 3')).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})

test('BOG UI participant program picker rejects another actor before exposing an alternative choice', async ({ page }) => {
  let reads = 0
  await page.route('**/api/v1/participant_programs**', async route => {
    const actorId = ++reads === 1 ? 8 : 7
    await route.fulfill({ json: {
      actor_id: actorId,
      current_cohort_id: null,
      current_program: null,
      selection_unavailable: true,
      programs: [{ id: 3, name: 'Fictional alternative', status: 'active' }],
      next_cursor: null,
    } })
  })
  await page.goto('/program-picker-qa.html')
  await expect(page.getByRole('alert')).toContainText('Program choices belong to a different account')
  await expect(page.getByRole('button', { name: 'Use Fictional alternative' })).toHaveCount(0)
  await expect(page.getByRole('combobox')).toHaveCount(0)
  await expect(page.getByText('No explicit program choice yet.')).toBeVisible()
  await page.getByRole('button', { name: 'Retry program choices' }).click()
  await expect(page.getByText(/selected program is unavailable/)).toBeVisible()
  await expect(page.getByText('No explicit program choice yet.')).toBeVisible()
  await page.getByRole('button', { name: 'Use Fictional alternative' }).click()
  await expect(page.getByText('Explicit program choice: 3')).toBeVisible()
})
