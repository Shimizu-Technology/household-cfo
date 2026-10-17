// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, expect, test, vi } from 'vitest'
import { ChallengeOpensSoon } from './ChallengeOpensSoon'
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia' }) }))
afterEach(cleanup)

test('explains calmly that the challenge is not open yet and offers no savings actions', () => {
  render(<ChallengeOpensSoon />)
  expect(screen.getByRole('heading', { name: 'Your savings challenge opens soon' })).toBeTruthy()
  expect(screen.getByRole('status').textContent).toContain('Mia cannot record savings')
  expect(screen.queryByRole('button')).toBeNull()
})
