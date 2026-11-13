// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest'
import { dialogExit } from './dialogExit'

afterEach(() => { document.body.innerHTML = ''; vi.useRealTimers(); vi.unstubAllGlobals() })
function panel() {
  document.body.innerHTML = '<div data-dialog-surface><section data-dialog-panel></section></div>'
  return document.querySelector('section')!
}

it('dismisses instantly without discrete transition support', () => {
  vi.stubGlobal('CSS', { supports: () => false })
  const done = vi.fn()
  dialogExit(panel(), done)
  expect(done).toHaveBeenCalledOnce()
})
it('waits for exit and dismisses only once if the deadline also expires', async () => {
  vi.useFakeTimers()
  vi.stubGlobal('CSS', { supports: () => true })
  const node = panel()
  let finish!: () => void
  const finished = new Promise<void>(resolve => { finish = resolve })
  node.getAnimations = () => [{ finished } as unknown as Animation]
  node.parentElement!.getAnimations = () => []
  const done = vi.fn()
  dialogExit(node, done)
  expect(done).not.toHaveBeenCalled()
  expect(node.dataset.dialogClosing).toBe('true')
  finish()
  await vi.advanceTimersByTimeAsync(0)
  expect(done).toHaveBeenCalledOnce()
  expect(node.dataset.dialogClosing).toBeUndefined()
  await vi.advanceTimersByTimeAsync(500)
  expect(done).toHaveBeenCalledOnce()
})
it('cancels on unmount without calling a stale owner', async () => {
  vi.useFakeTimers()
  vi.stubGlobal('CSS', { supports: () => true })
  const node = panel()
  node.getAnimations = () => [{ finished: new Promise(() => {}) } as unknown as Animation]
  node.parentElement!.getAnimations = () => []
  const done = vi.fn()
  const cancel = dialogExit(node, done)
  expect(dialogExit(node, done)).toBe(cancel)
  node.remove()
  cancel()
  await vi.advanceTimersByTimeAsync(500)
  expect(done).not.toHaveBeenCalled()
})
it('has a deadline when a browser never settles an animation', async () => {
  vi.useFakeTimers()
  vi.stubGlobal('CSS', { supports: () => true })
  const node = panel()
  node.getAnimations = () => [{ finished: new Promise(() => {}) } as unknown as Animation]
  node.parentElement!.getAnimations = () => []
  const done = vi.fn()
  dialogExit(node, done)
  await vi.advanceTimersByTimeAsync(200)
  expect(done).toHaveBeenCalledOnce()
})
