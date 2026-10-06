// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { MiaAssistPanels } from './MiaAssistPanels'
let compact = true
beforeEach(() => {
  vi.stubGlobal('matchMedia', () => ({ matches: compact, addEventListener: vi.fn(), removeEventListener: vi.fn() }))
  vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0))
  vi.stubGlobal('cancelAnimationFrame', clearTimeout)
})
afterEach(() => { cleanup(); vi.unstubAllGlobals(); compact = true })
function props() {
  return { panel: 'context' as const, onClose: vi.fn(), assistantName: 'Mia', contextSummary: 'Income saved. Account balance not entered.', pendingCount: 4, processingCount: 0, latestSource: 'Latest approved file: Budget, July 8.', realWorkspace: true, uploading: false, hasMessages: true, busy: false, onAttach: vi.fn(), onReviewImports: vi.fn(), onGuide: vi.fn(), onFeedback: vi.fn(), onClearChat: vi.fn(), onStartOver: vi.fn(), updatePrompts: [{ label: 'Update income', message: 'Help me update my income sources.' }], questionPrompts: [{ label: 'What income is saved?', message: 'What income is saved?' }], onChoosePrompt: vi.fn() }
}
test('context is a named modal on phones, with flattened status and separate reset/clear actions', () => {
  const p = props(); render(<MiaAssistPanels {...p} />)
  expect(screen.getByRole('dialog', { name: 'Context & help' }).getAttribute('aria-modal')).toBe('true')
  expect(screen.getByRole('heading', { name: 'Your saved picture' })).toBeTruthy()
  expect(screen.getByText('Income saved. Account balance not entered.')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Start over with my real numbers' }))
  expect(p.onClose).toHaveBeenCalledOnce(); expect(p.onStartOver).toHaveBeenCalledOnce(); expect(p.onClearChat).not.toHaveBeenCalled()
})
test('context keeps the complete guidance disclosure available verbatim', () => {
  const disclaimer = 'Mia is a coaching and education tool. She does not replace legal or financial advice.'
  render(<MiaAssistPanels {...props()} disclaimer={disclaimer} />)
  expect(screen.getByRole('region', { name: 'About Mia' }).textContent).toContain(disclaimer)
})
test('both prompt groups only prepare the composer after closing the surface', () => {
  const p = props(); const order: string[] = []; p.onClose.mockImplementation(() => { order.push('close') }); p.onChoosePrompt.mockImplementation(() => { order.push('prepare') })
  render(<MiaAssistPanels {...p} panel="prompts" />)
  fireEvent.click(screen.getByRole('button', { name: 'Update income' })); fireEvent.click(screen.getByRole('button', { name: 'What income is saved?' }))
  expect(order).toEqual(['close', 'prepare', 'close', 'prepare'])
  expect(p.onChoosePrompt.mock.calls).toEqual([['Help me update my income sources.'], ['What income is saved?']])
  expect(screen.queryByText('More prompts →')).toBeNull()
})
test('the controlled panel switches content rather than stacking two overlays', () => {
  const p = props(); const view = render(<MiaAssistPanels {...p} />)
  view.rerender(<MiaAssistPanels {...p} panel="prompts" />)
  expect(screen.getAllByRole('dialog')).toHaveLength(1); expect(screen.queryByRole('heading', { name: 'Files to review' })).toBeNull()
  view.rerender(<MiaAssistPanels {...p} panel={null} />)
  expect(screen.queryByRole('dialog')).toBeNull()
})
test('mobile keyboard focus is trapped and restored to the trigger on close', async () => {
  const trigger = document.createElement('button'); document.body.append(trigger); trigger.focus()
  const p = props(); const view = render(<MiaAssistPanels {...p} />)
  await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Close' })))
  fireEvent.keyDown(document, { key: 'Tab', shiftKey: true })
  expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Start over with my real numbers' }))
  fireEvent.keyDown(document, { key: 'Tab' }); expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Close' }))
  fireEvent.keyDown(document, { key: 'Escape' }); expect(p.onClose).toHaveBeenCalledOnce()
  act(() => view.unmount()); expect(document.activeElement).toBe(trigger); trigger.remove()
})
test('desktop context is a companion rather than a modal, unless expanded chat requires one', () => {
  compact = false; const p = props(); const view = render(<MiaAssistPanels {...p} />)
  expect(screen.queryByRole('dialog')).toBeNull(); expect(screen.getByRole('complementary', { name: 'Context & help' })).toBeTruthy()
  view.rerender(<MiaAssistPanels {...p} modal />); expect(screen.getByRole('dialog')).toBeTruthy()
})
test('busy chat disables reset, clear and prompts while help remains available', () => {
  const p = props(); const view = render(<MiaAssistPanels {...p} busy />)
  expect(screen.getByRole('button', { name: 'Clear chat' })).toHaveProperty('disabled', true)
  expect(screen.getByRole('button', { name: 'Start over with my real numbers' })).toHaveProperty('disabled', true)
  expect(screen.getByRole('button', { name: 'Guide' })).toHaveProperty('disabled', false)
  view.rerender(<MiaAssistPanels {...p} panel="prompts" busy />)
  expect(screen.getByRole('button', { name: 'Update income' })).toHaveProperty('disabled', true)
})
