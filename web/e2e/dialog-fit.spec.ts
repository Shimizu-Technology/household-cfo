import { expect, test } from '@playwright/test'

for (const fixture of [
  { page: '/privacy-qa.html', opener: 'Open private controls' },
  { page: '/optional-debt-qa.html', opener: 'Open optional card review' },
]) {
  test(`BOG UI private dialog ${fixture.page} keeps enlarged headers and final controls reachable on short screens`, async ({ page }) => {
    for (const size of [{ width: 320, height: 280 }, { width: 640, height: 280 }, { width: 1280, height: 720 }]) {
      await page.setViewportSize(size)
      await page.goto(fixture.page)
      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
      await page.getByRole('button', { name: fixture.opener, exact: true }).click()
      const dialog = page.getByRole('dialog')
      await expect(dialog).toBeVisible()
      const bounds = await dialog.boundingBox()
      expect(bounds!.y).toBeGreaterThanOrEqual(0)
      expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(size.height)
      expect(bounds!.x).toBeGreaterThanOrEqual(0)
      expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(size.width)
      await expect(dialog.getByRole('heading', { level: 2 })).toBeInViewport()
      const last = dialog.locator('button:visible:not([disabled]), summary:visible').last()
      await last.focus()
      await expect(last).toBeInViewport()
      const overflow = await dialog.evaluate(el => { const bounds = el.getBoundingClientRect(); return { amount: el.scrollWidth - el.clientWidth, offenders: Array.from(el.querySelectorAll('*')).filter(child => { const r=child.getBoundingClientRect(); return r.height > 0 && (r.right > bounds.right + 1 || r.left < bounds.left - 1 || child.scrollWidth > child.clientWidth + 1) }).slice(0, 12).map(child => ({ tag: child.tagName, class: child.className, text: child.textContent?.slice(0, 40), width: child.getBoundingClientRect().width, scroll:child.scrollWidth,client:child.clientWidth })) } })
      expect(overflow.amount, JSON.stringify(overflow.offenders)).toBeLessThanOrEqual(1)
      await page.keyboard.press('Tab')
      expect(await dialog.evaluate(el => el.contains(document.activeElement))).toBe(true)
      await page.keyboard.press('Escape')
      await expect(dialog).not.toBeVisible()
    }
  })
}
