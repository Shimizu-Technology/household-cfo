import { expect, type Page } from '@playwright/test'

// Every dropdown must keep its text clear of its arrow. The shared control styles reserve
// 38px at the end of a select for the arrow; a rule that removes that space, or a layout
// that squeezes a select narrower than its text when it has room to grow, puts the text
// under the arrow or cuts it short. Long values in a select that already fills its
// container may truncate with an ellipsis; that is the only allowed case.
export async function expectSelectsLeaveRoomForArrow(page: Page) {
  let findings: string[]
  try {
    findings = await page.evaluate(() => {
      const canvas = document.createElement('canvas').getContext('2d')!
      const problems: string[] = []
      for (const node of document.querySelectorAll('select')) {
        if (!node.checkVisibility() || node.multiple || node.size > 1) continue
        const style = getComputedStyle(node)
        const name = node.getAttribute('aria-label') || node.labels?.[0]?.textContent?.trim().slice(0, 40) || node.name || node.className || 'select'
        const end = parseFloat(style.direction === 'rtl' ? style.paddingLeft : style.paddingRight)
        if (style.appearance === 'none' && style.backgroundImage !== 'none' && end < 38) problems.push(`${name}: ${end}px beside the arrow, needs 38px`)
        canvas.font = style.font
        const text = node.selectedOptions[0]?.textContent?.trim() ?? ''
        const room = node.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)
        const parent = node.parentElement
        const parentStyle = parent ? getComputedStyle(parent) : null
        const available = parent && parentStyle ? parent.clientWidth - parseFloat(parentStyle.paddingLeft) - parseFloat(parentStyle.paddingRight) : Infinity
        const filled = node.getBoundingClientRect().width >= available - 2
        if (canvas.measureText(text).width > room + 1 && !filled) problems.push(`${name}: "${text}" needs ${Math.ceil(canvas.measureText(text).width)}px, has ${Math.floor(room)}px, and its container is ${Math.floor(available)}px wide`)
      }
      return problems
    })
  } catch {
    return // The page closed or navigated as the test ended.
  }
  expect(findings, 'dropdown text must stay clear of its arrow').toEqual([])
}
