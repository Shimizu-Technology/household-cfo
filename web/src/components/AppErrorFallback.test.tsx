// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AppErrorFallback } from './AppErrorFallback'

afterEach(() => cleanup())

describe('AppErrorFallback', () => {
  it('explains the safe state and wires retry to the error-boundary reset', async () => {
    const resetError = vi.fn()
    render(<AppErrorFallback resetError={resetError} />)

    expect(screen.getByText('This screen hit an unexpected problem.')).toBeTruthy()
    expect(screen.getByText(/verify any changes you made just before the error/)).toBeTruthy()
    expect(screen.getByText('VERA')).toBeTruthy()
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(resetError).toHaveBeenCalledOnce()
  })
})
