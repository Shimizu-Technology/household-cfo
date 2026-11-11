// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { CurrentUser } from '../api'
import { ConfirmHost } from './ConfirmHost'
import { UseAppAs } from './UseAppAs'
import { askedConfirm } from '../test/confirmDialog'
import { clearPreviewGroups } from '../lib/previewGroups'

const api = vi.hoisted(() => ({ joinPreviewSeat: vi.fn(), leavePreviewSeat: vi.fn() }))
vi.mock('../api', async importOriginal => ({ ...(await importOriginal<typeof import('../api')>()), ...api }))

const group = (cohort_id: number, name: string, seated = false, challenge_joined = false) => ({ cohort_id, name, status: 'active' as const, program_name: 'Mel program', seated, challenge: true, challenge_joined })
const staff = (groups: NonNullable<CurrentUser['preview_groups']>): CurrentUser => ({
  id: 31, clerk_id: 's', email: 's@example.invalid', full_name: 'Staff', first_name: 'S', last_name: 'T', role: 'admin', invitation_status: 'accepted',
  invited_at: null, accepted_at: null, last_sign_in_at: null, created_at: '', is_admin: true, is_coach: false, is_participant: false, is_staff: true, preview_groups: groups,
})

beforeEach(() => { api.joinPreviewSeat.mockReset(); api.leavePreviewSeat.mockReset(); clearPreviewGroups() })
afterEach(cleanup)

it('shows nothing for someone with no groups to use', () => {
  const view = render(<UseAppAs user={staff([])} onChooseHousehold={vi.fn()} onChooseGroup={vi.fn()} />)
  expect(view.container.textContent).toBe('')
})

it('lists My household first and says plainly which group is being used', () => {
  render(<UseAppAs user={staff([group(7, 'Bank of Guam 90 day savings', true)])} currentCohortId={7} onChooseHousehold={vi.fn()} onChooseGroup={vi.fn()} />)
  const radios = screen.getAllByRole('radio')
  expect(radios.map(radio => radio.closest('label')?.textContent)).toEqual(['My householdYour own money, no group', 'Bank of Guam 90 day savingsPreview'])
  expect((radios[1] as HTMLInputElement).checked).toBe(true)
  expect(screen.getByRole('status').textContent).toBe('Using: Bank of Guam 90 day savings · Preview')
})

it('takes a seat before switching to a group, and goes back to My household without leaving anything', async () => {
  const joined = [group(7, 'Bank of Guam 90 day savings', true)]
  api.joinPreviewSeat.mockResolvedValue({ preview_groups: joined })
  const chooseGroup = vi.fn(); const chooseHousehold = vi.fn()
  const user = staff([group(7, 'Bank of Guam 90 day savings')])
  const view = render(<UseAppAs user={user} onChooseHousehold={chooseHousehold} onChooseGroup={chooseGroup} />)
  fireEvent.click(screen.getByRole('radio', { name: /Bank of Guam 90 day savings/ }))
  await waitFor(() => expect(chooseGroup).toHaveBeenCalledWith(7))
  expect(api.joinPreviewSeat).toHaveBeenCalledWith(7)
  view.rerender(<UseAppAs user={user} currentCohortId={7} onChooseHousehold={chooseHousehold} onChooseGroup={chooseGroup} />)
  fireEvent.click(screen.getByRole('radio', { name: /My household/ }))
  expect(chooseHousehold).toHaveBeenCalled()
  expect(api.leavePreviewSeat).not.toHaveBeenCalled()
})

it('does not switch when the seat cannot be taken, and says nothing changed', async () => {
  api.joinPreviewSeat.mockRejectedValue(new Error('boom'))
  const chooseGroup = vi.fn()
  render(<UseAppAs user={staff([group(7, 'A group')])} onChooseHousehold={vi.fn()} onChooseGroup={chooseGroup} />)
  fireEvent.click(screen.getByRole('radio', { name: /A group/ }))
  expect((await screen.findByRole('alert')).textContent).toContain('Nothing changed')
  expect(chooseGroup).not.toHaveBeenCalled()
})

it('confirms before leaving a group whose challenge was joined, then returns to My household and reports the result', async () => {
  api.leavePreviewSeat.mockResolvedValue({ message: 'You left this group’s preview and your challenge preview ended. It can’t be restarted. Your own household is unchanged.', preview_groups: [group(7, 'BOG', false, true)] })
  const chooseHousehold = vi.fn()
  render(<><ConfirmHost /><UseAppAs user={staff([group(7, 'BOG', true, true)])} currentCohortId={7} onChooseHousehold={chooseHousehold} onChooseGroup={vi.fn()} /></>)
  fireEvent.click(screen.getByRole('button', { name: 'Leave' }))
  const answer = await askedConfirm({ title: 'Leave BOG?', message: 'This ends your savings challenge preview in BOG. It counts as leaving and can’t be restarted. Your own household isn’t changed.', confirmLabel: 'Leave preview', cancelLabel: 'Stay', caution: true })
  answer.cancel()
  await waitFor(() => expect(api.leavePreviewSeat).not.toHaveBeenCalled())
  fireEvent.click(screen.getByRole('button', { name: 'Leave' }))
  const again = await askedConfirm({ title: 'Leave BOG?', message: 'This ends your savings challenge preview in BOG. It counts as leaving and can’t be restarted. Your own household isn’t changed.', confirmLabel: 'Leave preview', cancelLabel: 'Stay', caution: true })
  again.confirm()
  await waitFor(() => expect(chooseHousehold).toHaveBeenCalled())
  expect(screen.getAllByRole('status').map(item => item.textContent).join(' ')).toContain('challenge preview ended')
})
