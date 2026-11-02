// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { CurrentUser } from './api'

const state = vi.hoisted(() => ({
  onUpload: vi.fn(),
  auth: { isAuthEnabled: true, isSignedIn: true, isLoading: false, isVerifyingApi: false, authRecoveryRequired: false, authProvider: 'workos', authIdentityId: 'participant-one' as string | null, activeCoachWorkspaceId: null, currentUser: { id: 12, auth_provider: 'workos', auth_subject: 'participant-one', is_participant: true } as CurrentUser | null },
}))
vi.mock('./contexts/authContextValue', () => ({ useAuthContext: () => state.auth }))
// Exercise App's actual retention boundary while access recovery remounts its child.
vi.mock('./components/ParticipantProgramSession', () => ({ ParticipantProgramSession: ({ identity }: { identity: string }) => state.auth.currentUser
  ? <DocumentUploadCard key={identity} retentionSlot="participant:default:statement" card={{ kind: 'statement', label: 'Bank statement', eyebrow: '', accepts: '.csv', helper: '', formats: 'CSV', sizeGuidance: '' }} uploading={false} disabled={false} onUpload={state.onUpload} />
  : <p>Checking access</p>,
}))
import { DocumentUploadRetentionBoundary } from './components/DocumentUploadRetention'
import { IdentityBoundary } from './components/IdentityBoundary'
import App, { DocumentUploadCard } from './App'

beforeEach(() => {
  vi.resetAllMocks()
  state.onUpload.mockResolvedValue(false)
  state.auth.authIdentityId = 'participant-one'
  state.auth.authRecoveryRequired = false
  state.auth.currentUser = { id: 12, auth_provider: 'workos', auth_subject: 'participant-one', is_participant: true } as CurrentUser
})
afterEach(cleanup)
const app = () => <DocumentUploadRetentionBoundary><IdentityBoundary><App /></IdentityBoundary></DocumentUploadRetentionBoundary>
const choose = () => {
  const file = new File(['fictional'], 'same-actor.csv', { type: 'text/csv' })
  fireEvent.change(document.querySelector('input[type=file]')!, { target: { files: [file] } })
  return file
}
it('retains the original File through authentication recovery and clears it after successful retry', async () => {
  const view = render(app())
  const file = choose()
  await screen.findByText('same-actor.csv is still selected.')
  state.auth.currentUser = null
  state.auth.authIdentityId = null
  state.auth.authRecoveryRequired = true
  view.rerender(app())
  expect(screen.getByText('Checking access')).toBeTruthy()
  expect(screen.queryByText('same-actor.csv is still selected.')).toBeNull()
  state.auth.authIdentityId = 'participant-one'
  state.auth.authRecoveryRequired = false
  state.auth.currentUser = { id: 12, auth_provider: 'workos', auth_subject: 'participant-one', is_participant: true } as CurrentUser
  view.rerender(app())
  expect(screen.getByText('same-actor.csv is still selected.')).toBeTruthy()
  state.onUpload.mockResolvedValueOnce(true)
  fireEvent.click(screen.getByRole('button', { name: 'Try this file again' }))
  await waitFor(() => expect(screen.queryByText('same-actor.csv is still selected.')).toBeNull())
  expect(state.onUpload).toHaveBeenNthCalledWith(1, file)
  expect(state.onUpload).toHaveBeenNthCalledWith(2, file)
  expect(state.onUpload.mock.calls[1][0]).toBe(file)
})
it('discards retained private files when a different actor signs in', async () => {
  const view = render(app())
  choose()
  await screen.findByText('same-actor.csv is still selected.')
  state.auth.authIdentityId = null
  state.auth.authRecoveryRequired = true
  state.auth.currentUser = null
  view.rerender(app())
  state.auth.authIdentityId = 'participant-two'
  state.auth.authRecoveryRequired = false
  state.auth.currentUser = { id: 13, auth_provider: 'workos', auth_subject: 'participant-two', is_participant: true } as CurrentUser
  view.rerender(app())
  expect(screen.queryByText('same-actor.csv is still selected.')).toBeNull()
  expect(screen.queryByRole('button', { name: 'Try this file again' })).toBeNull()
  state.auth.authIdentityId = 'participant-one'
  state.auth.currentUser = { id: 12, auth_provider: 'workos', auth_subject: 'participant-one', is_participant: true } as CurrentUser
  view.rerender(app())
  expect(screen.queryByText('same-actor.csv is still selected.')).toBeNull()
})

it('clears private files on sign-out without recovery', async () => {
  const view = render(app())
  choose()
  await screen.findByText('same-actor.csv is still selected.')
  state.auth.currentUser = null
  state.auth.authIdentityId = null
  view.rerender(app())
  state.auth.authIdentityId = 'participant-one'
  state.auth.currentUser = { id: 12, auth_provider: 'workos', auth_subject: 'participant-one', is_participant: true } as CurrentUser
  view.rerender(app())
  expect(screen.queryByText('same-actor.csv is still selected.')).toBeNull()
})
