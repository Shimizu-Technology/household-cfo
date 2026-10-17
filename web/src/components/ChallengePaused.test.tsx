// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, expect, test, vi } from 'vitest'
import { ChallengePaused } from './ChallengePaused'
vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia' }) }))
afterEach(cleanup)

test('tells an enrolled participant calmly that it is paused, their record is safe, and offers no actions', () => {
  render(<ChallengePaused joined />)
  expect(screen.getByRole('heading', { name: 'Your savings challenge is paused' })).toBeTruthy()
  expect(document.body.textContent).toContain('Your record is safe and nothing has been lost')
  expect(document.body.textContent).toContain('continue right where you left off when it resumes')
  expect(document.body.textContent).not.toContain('opens soon')
  expect(screen.queryByRole('button')).toBeNull()
})

test('does not promise a record to someone who has not joined', () => {
  render(<ChallengePaused joined={false} />)
  expect(document.body.textContent).not.toContain('Your record is safe')
  expect(document.body.textContent).toContain('join and continue when it resumes')
})
