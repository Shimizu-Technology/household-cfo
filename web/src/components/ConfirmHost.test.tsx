// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { confirmAction, confirmDiscard } from '../lib/confirmAction'
import { ConfirmHost } from './ConfirmHost'

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('confirmAction', () => {
  it('falls back to the browser prompt when no host is mounted', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    await expect(confirmAction('Remove it?')).resolves.toBe(false)
    expect(confirm).toHaveBeenCalledWith('Remove it?')
  })

  it('asks in the app dialog and resolves with the answer, never calling the browser prompt', async () => {
    const confirm = vi.spyOn(window, 'confirm')
    render(<ConfirmHost />)
    let answer: Promise<boolean> | undefined
    act(() => { answer = confirmAction('Nothing is deleted.', { title: 'Archive Groceries?', confirmLabel: 'Archive category', cancelLabel: 'Keep it', caution: true }) })

    const dialog = screen.getByRole('alertdialog', { name: 'Archive Groceries?' })
    expect(dialog.textContent).toContain('Nothing is deleted.')
    fireEvent.click(screen.getByRole('button', { name: 'Archive category' }))
    await expect(answer).resolves.toBe(true)
    expect(screen.queryByRole('alertdialog')).toBeNull()
    expect(confirm).not.toHaveBeenCalled()
  })

  it('treats Cancel and Escape as "no" and shows the discard wording by default', async () => {
    render(<ConfirmHost />)
    let first: Promise<boolean> | undefined
    act(() => { first = confirmDiscard('Your edits are not saved.') })
    expect(screen.getByRole('alertdialog', { name: 'Leave without saving?' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Keep editing' }))
    await expect(first).resolves.toBe(false)

    let second: Promise<boolean> | undefined
    act(() => { second = confirmAction('Sure?') })
    fireEvent.keyDown(document, { key: 'Escape' })
    await expect(second).resolves.toBe(false)
  })

  it('asks one question at a time', async () => {
    render(<ConfirmHost />)
    let one: Promise<boolean> | undefined
    let two: Promise<boolean> | undefined
    act(() => { one = confirmAction('First', { title: 'One?' }); two = confirmAction('Second', { title: 'Two?' }) })
    expect(screen.getByRole('alertdialog', { name: 'One?' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))
    await expect(one).resolves.toBe(true)
    expect(screen.getByRole('alertdialog', { name: 'Two?' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await expect(two).resolves.toBe(false)
  })

  it('answers "no" for anything still waiting when the host unmounts', async () => {
    const view = render(<ConfirmHost />)
    let pending: Promise<boolean> | undefined
    act(() => { pending = confirmAction('Still there?') })
    view.unmount()
    await expect(pending).resolves.toBe(false)
  })
})
