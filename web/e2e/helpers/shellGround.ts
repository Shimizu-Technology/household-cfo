import { expect, type Page } from '@playwright/test'

// Check actual text line boxes at mid-scroll, including both screen edges.
// The opaque ground must also intercept taps on the content it covers.
export async function expectPhoneGroundCoverage(page: Page) {
  await page.evaluate(() => document.fonts.ready)
  await page.evaluate(() => window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) / 2))
  await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(0)
  // A midpoint can land on a card gap. Align the nearest real text line with
  // the bottom band, keeping the page between its start and end positions.
  await page.evaluate(() => {
    const walker = document.createTreeWalker(document.querySelector('.shell-main')!, NodeFilter.SHOW_TEXT)
    const positions: number[] = []
    const maximum = document.documentElement.scrollHeight - innerHeight
    while (walker.nextNode()) {
      const node = walker.currentNode
      if (!node.textContent?.trim() || !node.parentElement?.checkVisibility()) continue
      const range = document.createRange()
      range.selectNodeContents(node)
      for (const rect of range.getClientRects()) {
        const position = scrollY + rect.top + rect.height / 2 - (innerHeight - 7)
        if (position > 0 && position < maximum) positions.push(position)
      }
    }
    positions.sort((a, b) => Math.abs(a - scrollY) - Math.abs(b - scrollY))
    if (positions.length) window.scrollTo(0, positions[0])
  })
  const coverage = await page.evaluate(() => {
    const bar = document.querySelector<HTMLElement>('.tabs-shell')!
    const ground = document.querySelector<HTMLElement>('.tabs-ground')!
    const pill = bar.getBoundingClientRect()
    const band = ground.getBoundingClientRect()
    const css = getComputedStyle(ground)
    const probe = document.createElement('span')
    probe.style.background = 'var(--surface-ground)'
    ground.append(probe)
    const pageGround = getComputedStyle(probe).backgroundColor
    probe.remove()
    const exposed: { text: string; x: number; y: number; front: string | null }[] = []
    let coveredLines = 0
    const walker = document.createTreeWalker(document.querySelector('.shell-main')!, NodeFilter.SHOW_TEXT)
    while (walker.nextNode()) {
      const node = walker.currentNode
      if (!node.textContent?.trim() || !node.parentElement?.checkVisibility()) continue
      const range = document.createRange()
      range.selectNodeContents(node)
      for (const rect of range.getClientRects()) {
        if (rect.bottom <= band.top || rect.top >= innerHeight) continue
        const top = Math.max(rect.top, band.top), bottom = Math.min(rect.bottom, innerHeight)
        // Hit-test whole CSS pixels inside both the text intersection and the
        // viewport. Chromium rounds a bottom-edge subpixel outside the screen.
        const firstY = Math.ceil(top), lastY = Math.min(innerHeight - 1, Math.floor(bottom))
        if (firstY > lastY) continue
        coveredLines++
        for (const y of [firstY, Math.floor((firstY + lastY) / 2), lastY]) {
          for (let x = Math.max(1, Math.ceil(rect.left)); x < Math.min(innerWidth - 1, rect.right); x += 4) {
            const front = document.elementFromPoint(x, y)
            if (front !== ground && !bar.contains(front) && exposed.length < 12) {
              exposed.push({ text: node.textContent.trim(), x, y, front: front?.className ?? null })
            }
          }
        }
      }
    }
    // The empty margins and the gap below the pill must be covered too.
    for (const x of [1, innerWidth / 2, innerWidth - 1]) {
      for (const y of [pill.bottom + 1, innerHeight - 1]) {
        const front = document.elementFromPoint(x, y)
        if (front !== ground) exposed.push({ text: 'bottom gap', x, y, front: front?.className ?? null })
      }
    }
    return { visible: ground.checkVisibility(), band: band.toJSON(), centre: pill.top + pill.height / 2,
      width: innerWidth, height: innerHeight, background: css.backgroundColor, pageGround,
      opacity: css.opacity, coveredLines, exposed }
  })
  expect(coverage.visible).toBe(true)
  expect(coverage.band.top).toBeCloseTo(coverage.centre, 0)
  expect(coverage.band.left).toBe(0)
  expect(coverage.band.right).toBe(coverage.width)
  expect(coverage.band.bottom).toBe(coverage.height)
  expect(coverage.background).toBe(coverage.pageGround)
  expect(coverage.background).not.toBe('rgba(0, 0, 0, 0)')
  expect(coverage.opacity).toBe('1')
  expect(coverage.coveredLines, 'mid-scroll must place real page text behind the band').toBeGreaterThan(0)
  expect(coverage.exposed, 'no page text may paint above the opaque ground').toEqual([])
}
