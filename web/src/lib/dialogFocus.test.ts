// @vitest-environment jsdom
import { afterEach, expect, test, vi } from 'vitest'
import { revealDialogControl } from './dialogFocus'
afterEach(() => { document.body.innerHTML = ''; vi.restoreAllMocks() })
function geometry(element: HTMLElement, top: number, height: number) {
  vi.spyOn(element, 'getBoundingClientRect').mockReturnValue({ top, bottom: top + height, height } as DOMRect)
  Object.defineProperty(element, 'clientHeight', { configurable: true, value: height })
}
test.each(['pilot-dialog-body', 'mia-assist-body'])('focused controls reveal in %s without scrolling the persistent header', className => {
  document.body.innerHTML = `<section role="dialog"><header><button>Close</button></header><div class="${className}"><textarea></textarea></div></section>`
  const dialog = document.querySelector<HTMLElement>('section')!, body = document.querySelector<HTMLElement>(`.${className}`)!, field = document.querySelector<HTMLElement>('textarea')!
  geometry(dialog, 10, 300); geometry(body, 80, 230); geometry(field, 300, 44)
  revealDialogControl(field, dialog)
  expect(body.scrollTop).toBe(34); expect(dialog.scrollTop).toBe(0)
  geometry(field, 60, 44); revealDialogControl(field, dialog)
  expect(body.scrollTop).toBe(14); expect(dialog.scrollTop).toBe(0)
})
test('other dialogs keep their existing outer scrolling behavior', () => {
  document.body.innerHTML = '<section role="dialog"><input /></section>'
  const dialog = document.querySelector<HTMLElement>('section')!, field = document.querySelector<HTMLElement>('input')!
  geometry(dialog, 10, 300); geometry(field, 300, 44)
  revealDialogControl(field, dialog); expect(dialog.scrollTop).toBe(34)
})
