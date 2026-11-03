// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import * as api from '../api'
import { askedConfirm } from '../test/confirmDialog'
import { ConfirmHost } from './ConfirmHost'
import { MiaMemoryPanel } from './MiaMemoryPanel'

vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ brand: { product_name: 'Household CFO' }, assistantName: 'Mia' }) }))
vi.mock('../api', async original => ({
  ...await original<typeof import('../api')>(),
  fetchHouseholdMemories: vi.fn(), forgetHouseholdMemory: vi.fn(),
}))

const memory: api.HouseholdMemory = {
  id: 7, category: 'preference', status: 'user_confirmed', sensitivity: 'ordinary', visibility: 'private',
  display_value: 'Ask one question at a time.', structured_value: {}, owned_by_current_user: true, owner_name: 'QA',
  source_kind: 'manual_profile', confirmation_fingerprint: null, confirmed_at: '2026-10-01T00:00:00Z', expires_at: null,
  created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z',
}
const forgetQuestion = {
  title: 'Forget this memory?', message: 'Mia will stop using it immediately.',
  confirmLabel: 'Forget it', cancelLabel: 'Keep it', caution: true,
}
const withMemory: api.MiaMemoryData = { memories: [memory], personalization: { paused: false, paused_at: null }, policy: { source: 'manual', financial_truth: 'records', coach_visibility: false } }
const withoutMemory: api.MiaMemoryData = { ...withMemory, memories: [] }

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(api.fetchHouseholdMemories).mockResolvedValue(withMemory)
  vi.mocked(api.forgetHouseholdMemory).mockResolvedValue(undefined)
})
afterEach(cleanup)

function renderPanel() { render(<><ConfirmHost /><MiaMemoryPanel enabled /></>) }
async function pressForget() { fireEvent.click(await screen.findByRole('button', { name: /^Forget memory:/ })) }

test('forgetting a memory asks first, and keeping it sends nothing', async () => {
  renderPanel()
  await pressForget()
  const question = await askedConfirm(forgetQuestion)
  question.cancel()
  await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull())
  expect(api.forgetHouseholdMemory).not.toHaveBeenCalled()
  expect(screen.getByText('Ask one question at a time.')).toBeTruthy()
  expect(screen.queryByText('Memory forgotten.')).toBeNull()
})

test('confirming forgets exactly that memory once and shows the result', async () => {
  vi.mocked(api.fetchHouseholdMemories).mockResolvedValueOnce(withMemory).mockResolvedValue(withoutMemory)
  renderPanel()
  await pressForget()
  const question = await askedConfirm(forgetQuestion)
  question.confirm()
  await screen.findByText('Memory forgotten.')
  expect(api.forgetHouseholdMemory).toHaveBeenCalledTimes(1)
  expect(api.forgetHouseholdMemory).toHaveBeenCalledWith(7)
  await waitFor(() => expect(screen.queryByText('Ask one question at a time.')).toBeNull())
})

test('Escape on the question counts as keeping the memory', async () => {
  renderPanel()
  await pressForget()
  await askedConfirm(forgetQuestion)
  fireEvent.keyDown(document, { key: 'Escape' })
  await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull())
  expect(api.forgetHouseholdMemory).not.toHaveBeenCalled()
})
