import { afterEach, expect, it } from 'vitest'
import { cancelGroupOpen, handOffGroupOpen, takeGroupOpen } from './groupOpenHandoff'

afterEach(() => { takeGroupOpen(0, null) })

it('opens the group in the next Groups for the same person and program, once', () => {
  handOffGroupOpen(9, 5, 1, 1_000)
  expect(takeGroupOpen(1, 5, 2_000)).toBe(9)
  expect(takeGroupOpen(1, 5, 2_000)).toBeNull()
})

it('drops the handoff for another program, another person, or a later visit', () => {
  handOffGroupOpen(9, 5, 1, 1_000)
  expect(takeGroupOpen(1, 6, 1_500)).toBeNull()
  expect(takeGroupOpen(1, 5, 1_500)).toBeNull()
  handOffGroupOpen(9, 5, 1, 1_000)
  expect(takeGroupOpen(2, 5, 1_500)).toBeNull()
  handOffGroupOpen(9, 5, 1, 1_000)
  expect(takeGroupOpen(1, 5, 7_000)).toBeNull()
})

it('is cancelled by the screen that created the group once it opened it itself', () => {
  handOffGroupOpen(9, 5, 1, 1_000)
  cancelGroupOpen(8)
  cancelGroupOpen(9)
  expect(takeGroupOpen(1, 5, 1_500)).toBeNull()
})
