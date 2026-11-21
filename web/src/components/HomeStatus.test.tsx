// @vitest-environment jsdom

import { cleanup, render, screen, within } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import type { DashboardData } from '../api'
import { HomeStatus } from './HomeScreen'

afterEach(cleanup)

const rule = { target_green_months: 12, target_yellow_months: 36, surplus_green_cents: 100_000, surplus_yellow_cents: 50_000 }
const answer = (changes: Partial<NonNullable<DashboardData['month_answer']>>) => ({
  readiness_tone: 'green', surplus_tone: 'yellow', months_to_target: 6, plan_left_cents: 90_000, status_rule: rule, ...changes,
}) as NonNullable<DashboardData['month_answer']>

it('shows each status as a dot and a word with the program’s rule', () => {
  render(<HomeStatus answer={answer({})} />)
  const [fund, surplus] = within(screen.getByRole('list', { name: 'Status' })).getAllByRole('listitem')
  expect(fund.textContent).toBe('Emergency fundGreenAbout 6 months away · green within 12 months, yellow within 36 months')
  expect(fund.querySelector('.ui-dot--green')).not.toBeNull()
  expect(surplus.textContent).toBe('Monthly surplusYellow$900 planned this month · green from $1,000, yellow from $500')
})

it('follows a stricter rule published in Go live', () => {
  render(<HomeStatus answer={answer({ readiness_tone: 'red', surplus_tone: 'green', status_rule: { target_green_months: 3, target_yellow_months: 5, surplus_green_cents: 80_000, surplus_yellow_cents: 40_000 } })} />)
  const [fund, surplus] = within(screen.getByRole('list', { name: 'Status' })).getAllByRole('listitem')
  expect(fund.textContent).toContain('Red')
  expect(fund.textContent).toContain('green within 3 months, yellow within 5 months')
  expect(surplus.textContent).toContain('Green')
  expect(surplus.textContent).toContain('green from $800, yellow from $400')
})

it('never shows a colour for an unknown amount', () => {
  const { container } = render(<HomeStatus answer={answer({ readiness_tone: null, surplus_tone: null, plan_left_cents: null })} />)
  expect(container.textContent).toBe('')
  render(<HomeStatus answer={answer({ months_to_target: null, readiness_tone: 'red', surplus_tone: 'red', plan_left_cents: -20_000 })} />)
  expect(screen.getByText(/Needs a monthly surplus to reach/)).toBeTruthy()
  expect(screen.getByText(/\$200 short in this month’s plan/)).toBeTruthy()
})
