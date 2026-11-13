import { expect, test } from '@playwright/test'

// BOG UI prefix also includes the foundation on the project's tablet/WebKit
// filters, so every browser matrix actually exercises this shared CSS.
test.describe('BOG UI design foundation', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/ui-foundation-qa.html')
    await expect(page.getByRole('heading', { name: 'The shared foundation' })).toBeVisible()
    await page.evaluate(() => document.fonts.ready)
  })

  test('both brands keep every primitive readable, bounded and touch sized', async ({ page }) => {
    for (const name of ['Household CFO', 'Blue coach']) {
      const brand = page.getByRole('region', { name, exact: true })
      const result = await brand.evaluate(root => {
        const canvas = document.createElement('canvas')
        canvas.width = canvas.height = 1
        const ctx = canvas.getContext('2d')!
        const rgb = (color: string) => { ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = color; ctx.fillRect(0, 0, 1, 1); return [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3) }
        const luminance = (color: string) => rgb(color).map(n => n / 255).map(n => n <= 0.04045 ? n / 12.92 : ((n + 0.055) / 1.055) ** 2.4).reduce((sum, n, i) => sum + n * [0.2126, 0.7152, 0.0722][i], 0)
        const answer = root.querySelector('.ui-answer')!
        const bg = luminance(getComputedStyle(answer).backgroundColor)
        const ratios = [...answer.querySelectorAll('.ui-label, .ui-figure, .ui-answer__note, .ui-key > span, .ui-key strong')].map(node => {
          const fg = luminance(getComputedStyle(node).color)
          return (Math.max(bg, fg) + 0.05) / (Math.min(bg, fg) + 0.05)
        })
        const short = [...root.querySelectorAll('button, a, input, select, summary')].filter(node => {
          const box = node.getBoundingClientRect()
          return box.width > 0 && box.height > 0 && (box.width < 43.5 || box.height < 43.5)
        }).map(node => node.outerHTML.slice(0, 150))
        const overflow = [...root.querySelectorAll('*')].filter(node => {
          const box = node.getBoundingClientRect()
          return box.width > 0 && box.height > 0 && (box.right > innerWidth + 1 || box.left < -1)
        }).map(node => node.className)
        const field = root.querySelector('select')!
        return { ratios, short, overflow, font: getComputedStyle(field).fontSize, arrow: getComputedStyle(field).appearance, deep: getComputedStyle(answer).backgroundColor }
      })
      expect(result.ratios.every(ratio => ratio >= 4.5), `${name}: ${result.ratios}`).toBe(true)
      expect(result.short).toEqual([])
      expect(result.overflow).toEqual([])
      expect(result.font).toBe('16px')
      expect(result.arrow).toBe('none')
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    const backgrounds = await page.locator('.ui-answer').evaluateAll(nodes => nodes.map(node => getComputedStyle(node).backgroundColor))
    expect(backgrounds[0]).not.toBe(backgrounds[1])
  })

  test('native controls retain keyboard behavior and a single focus treatment', async ({ page }) => {
    const brand = page.getByRole('region', { name: 'Household CFO', exact: true })
    const select = brand.locator('select').first()
    await select.selectOption('Transport')
    await expect(select).toHaveValue('Transport')
    const check = brand.getByRole('checkbox', { name: 'Remind me later' })
    await check.focus()
    await page.keyboard.press('Space')
    await expect(check).toBeChecked()
    const focus = await check.evaluate(node => ({ width: getComputedStyle(node).outlineWidth, offset: getComputedStyle(node).outlineOffset, style: getComputedStyle(node).outlineStyle }))
    expect(focus).toEqual({ width: '2px', offset: '2px', style: 'solid' })
    const summary = brand.getByText('How this is counted', { exact: true })
    await summary.focus()
    await page.keyboard.press('Enter')
    await expect(brand.getByText('Only purchases you confirm count as spent.')).toBeVisible()
    await brand.getByRole('button', { name: 'This month', exact: true }).click()
    await expect(brand.getByRole('button', { name: 'This month', exact: true })).toHaveAttribute('aria-pressed', 'true')
    const disabled = brand.getByRole('button', { name: 'Legacy disabled' })
    await expect(disabled).toBeDisabled()
    expect(await disabled.evaluate(node => getComputedStyle(node).borderRadius)).toBe('999px')
  })

  test('native dialog enters and exits, and reduced motion keeps only fades', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'no-preference' })
    const brand = page.getByRole('region', { name: 'Household CFO', exact: true })
    const open = brand.getByRole('button', { name: 'Open preview dialog' })
    await open.focus()
    await open.click()
    const dialog = brand.locator('dialog')
    await expect(dialog).toBeVisible()
    await dialog.evaluate(node => Promise.allSettled(node.getAnimations().map(a => a.finished)))
    await dialog.getByRole('button', { name: 'Close preview dialog' }).evaluate(node => (node as HTMLButtonElement).click())
    await expect.poll(() => dialog.evaluate(node => (node as HTMLDialogElement).open)).toBe(false)
    await expect(dialog).not.toBeVisible()
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await open.focus()
    await open.click()
    expect(await dialog.evaluate(node => new DOMMatrix(getComputedStyle(node).transform).isIdentity)).toBe(true)
    await page.keyboard.press('Escape')
    await expect.poll(() => dialog.evaluate(node => (node as HTMLDialogElement).open)).toBe(false)
  })

  test('forced colours preserve native checkbox and radio semantics', async ({ page, browserName }) => {
    test.skip(browserName === 'webkit', 'WebKit does not emulate forced-colors')
    await page.emulateMedia({ forcedColors: 'active' })
    const check = page.getByRole('region', { name: 'Household CFO', exact: true }).getByRole('checkbox', { name: 'Remind me later' })
    expect(await check.evaluate(node => getComputedStyle(node).appearance)).toBe('auto')
    await check.check()
    await expect(check).toBeChecked()
  })
})
