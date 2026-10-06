// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AuthAccessPanel } from './AuthAccessPanel'
afterEach(cleanup)
it('keeps recovery controls available when a retry callback rejects', async () => {
  const retry = vi.fn().mockRejectedValue(new Error('Retry unavailable'))
  render(<AuthAccessPanel title="Access check paused" copy="Your workspace is still closed." recovering onRetry={retry} />)
  fireEvent.click(screen.getByRole('button', { name: 'Check access again' }))
  await waitFor(() => expect(retry).toHaveBeenCalledOnce())
  expect(screen.getByRole('alert').textContent).toBe('Your workspace is still closed.')
  expect(screen.getByRole('button', { name: 'Reload page' })).toBeTruthy()
  expect(screen.getByRole('button', { name: 'Check access again' })).toHaveProperty('disabled', false)
})
