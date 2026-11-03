import { fireEvent, screen, within } from '@testing-library/react'
import { expect } from 'vitest'

export type ExpectedConfirm = {
  title: string
  /** Exact wording shown under the title. */
  message: string
  confirmLabel: string
  cancelLabel: string
  /** Destructive confirmations show the confirm action as a caution. */
  caution?: boolean
}

/**
 * Finds the question a rendered ConfirmHost is asking, checks the words a person reads,
 * and returns buttons that answer it. Render <ConfirmHost /> next to the component.
 */
export async function askedConfirm(expected: ExpectedConfirm) {
  const dialog = await screen.findByRole('alertdialog', { name: expected.title })
  expect(within(dialog).getByText(expected.message)).toBeTruthy()
  const buttons = within(dialog).getAllByRole('button')
  expect(buttons.map(button => button.textContent)).toEqual([expected.cancelLabel, expected.confirmLabel])
  expect(buttons[1].className).toBe(expected.caution ? 'danger' : 'primary')
  return {
    dialog,
    cancel: () => fireEvent.click(buttons[0]),
    confirm: () => fireEvent.click(buttons[1]),
  }
}
