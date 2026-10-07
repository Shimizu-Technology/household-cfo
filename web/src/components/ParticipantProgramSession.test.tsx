// @vitest-environment jsdom
import { useState } from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ParticipantProgramSession } from './ParticipantProgramSession'
import { readParticipantProgram, storeParticipantProgram } from '../lib/participantProgramSelection'
vi.mock('../api', () => ({ setActiveParticipantCohortId: vi.fn() }))
beforeEach(() => { localStorage.clear() })
afterEach(() => { cleanup(); vi.restoreAllMocks() })
function PrivateDraft() {
  const [draft, setDraft] = useState('')
  return <input aria-label="Unsaved budget draft" value={draft} onChange={event => setDraft(event.target.value)} />
}
function view(identity = 'clerk-a:1:participant', actorId = 1) {
  return <ParticipantProgramSession identity={identity} authIdentityId={actorId === 1 ? 'clerk-a' : 'clerk-b'} actorId={actorId} participant>
    {selection => <section>
      <p>Selected: {selection.selectedCohortId ?? 'default'}</p>
      <button onClick={() => selection.onProgramVerified(42)}>Verify default</button>
      <button onClick={() => selection.onChooseProgram(43)}>Choose 43</button>
      <button onClick={selection.onProgramUnavailable}>Membership lost</button>
      {selection.selectionNotice && <p role="status">{selection.selectionNotice}</p>}
      <PrivateDraft key={selection.selectedCohortId ?? 'default'} />
    </section>}
  </ParticipantProgramSession>
}
it('keeps a default workspace and unsaved draft stable after persisting its verified program and rerendering', () => {
  const ui = render(view())
  fireEvent.change(screen.getByLabelText('Unsaved budget draft'), { target: { value: '125.50' } })
  fireEvent.click(screen.getByRole('button', { name: 'Verify default' }))
  expect(readParticipantProgram('clerk-a', 1)).toBe(42)
  ui.rerender(view())
  expect(screen.getByText('Selected: default')).toBeTruthy()
  expect((screen.getByLabelText('Unsaved budget draft') as HTMLInputElement).value).toBe('125.50')
})
it('ignores external storage changes until a new session, while an explicit choice resets the private view', () => {
  storeParticipantProgram('clerk-a', 1, 42)
  const ui = render(view())
  const storageRead = vi.spyOn(Storage.prototype, 'getItem')
  fireEvent.change(screen.getByLabelText('Unsaved budget draft'), { target: { value: '77.25' } })
  storeParticipantProgram('clerk-a', 1, 99)
  window.dispatchEvent(new StorageEvent('storage', { key: 'household-cfo:participant-program:v1:clerk-a:1', newValue: '99' }))
  ui.rerender(view())
  expect(screen.getByText('Selected: 42')).toBeTruthy()
  expect((screen.getByLabelText('Unsaved budget draft') as HTMLInputElement).value).toBe('77.25')
  expect(storageRead).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Choose 43' }))
  expect(screen.getByText('Selected: 43')).toBeTruthy()
  expect((screen.getByLabelText('Unsaved budget draft') as HTMLInputElement).value).toBe('')
})
it('clears revoked membership and restores only a new authenticated actor’s own choice', () => {
  storeParticipantProgram('clerk-a', 1, 42)
  storeParticipantProgram('clerk-b', 2, 91)
  const ui = render(view())
  fireEvent.change(screen.getByLabelText('Unsaved budget draft'), { target: { value: '12' } })
  fireEvent.click(screen.getByRole('button', { name: 'Membership lost' }))
  expect(readParticipantProgram('clerk-a', 1)).toBeUndefined()
  expect(screen.getByText('Selected: default')).toBeTruthy()
  expect(screen.getByRole('status').textContent).toContain('no longer available')
  expect((screen.getByLabelText('Unsaved budget draft') as HTMLInputElement).value).toBe('')
  ui.rerender(view('clerk-b:2:participant', 2))
  expect(screen.getByText('Selected: 91')).toBeTruthy()
  expect(screen.queryByRole('status')).toBeNull()
  expect((screen.getByLabelText('Unsaved budget draft') as HTMLInputElement).value).toBe('')
})

it('restores a verified migrated user’s prior program choice without reading another local user’s key', () => {
  storeParticipantProgram('old-clerk', 1, 42)
  storeParticipantProgram('old-clerk', 2, 99)
  const ui = render(<ParticipantProgramSession identity="workos:user-a:1" authIdentityId="workos:user-a" legacyAuthIdentityId="old-clerk" actorId={1} participant>
    {selection => <><p>Selected: {selection.selectedCohortId}</p><button onClick={() => selection.onProgramVerified(42)}>Confirm program</button></>}
  </ParticipantProgramSession>)
  expect(screen.getByText('Selected: 42')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Confirm program' }))
  expect(readParticipantProgram('workos:user-a', 1)).toBe(42)
  ui.unmount()
})
