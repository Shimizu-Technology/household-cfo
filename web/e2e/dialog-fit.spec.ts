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
      async function assertFitsDialog(target: ReturnType<typeof dialog.getByRole>) {
        await expect.poll(() => target.evaluate(node => {
          const panel = node.closest('[role="dialog"], dialog') as HTMLElement
          const box = panel.getBoundingClientRect()
          const rect = node.getBoundingClientRect()
          const left = box.left + panel.clientLeft
          const top = box.top + panel.clientTop
          return rect.left >= left - 1 && rect.right <= left + panel.clientWidth + 1 &&
            rect.top >= top - 1 && rect.bottom <= top + panel.clientHeight + 1 &&
            node.scrollWidth <= node.clientWidth + 1 && node.scrollHeight <= node.clientHeight + 1
        })).toBe(true)
      }
      await assertFitsDialog(dialog.getByRole('heading', { level: 2 }))
      if (fixture.page === '/privacy-qa.html') {
        const purpose = dialog.getByRole('combobox', { name: 'Purpose', exact: true })
        // Native popup interaction is checked through computer use; headless
        // mobile WebKit does not expose its system picker to keyboard input.
        await purpose.selectOption('selected_details')
        await expect(purpose).toHaveValue('selected_details')
        await purpose.focus()
        await expect(purpose).toBeInViewport()
        expect(await purpose.evaluate(el => getComputedStyle(el).outlineStyle)).not.toBe('none')
      }
      const last = dialog.locator('button:visible:not([disabled]), summary:visible').last()
      await last.focus()
      await assertFitsDialog(last)
      const overflow = await dialog.evaluate(el => { const bounds = el.getBoundingClientRect(); return { amount: el.scrollWidth - el.clientWidth, offenders: Array.from(el.querySelectorAll('*')).filter(child => { const r=child.getBoundingClientRect(); return r.height > 0 && (r.right > bounds.right + 1 || r.left < bounds.left - 1 || child.scrollWidth > child.clientWidth + 1) }).slice(0, 12).map(child => ({ tag: child.tagName, class: child.className, text: child.textContent?.slice(0, 40), width: child.getBoundingClientRect().width, scroll:child.scrollWidth,client:child.clientWidth })) } })
      expect(overflow.amount, JSON.stringify(overflow.offenders)).toBeLessThanOrEqual(1)
      await page.keyboard.press('Tab')
      expect(await dialog.evaluate(el => el.contains(document.activeElement))).toBe(true)
      await page.keyboard.press('Escape')
      await expect(dialog).not.toBeVisible()
    }
  })
}
