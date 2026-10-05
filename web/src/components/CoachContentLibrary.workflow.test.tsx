// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { CurrentUser } from '../api'
import { CoachContentLibrary } from './CoachContentLibrary'
const mocks = vi.hoisted(() => ({ fetchAdminContentItems: vi.fn(), fetchAdminContentPacks: vi.fn() }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), ...mocks }))
vi.mock('../contexts/authContextValue', () => ({ useAuthContext: () => ({ activeCoachWorkspaceId: 2 }) }))
vi.mock('./CoachContentSources', () => ({ CoachContentSources: () => <section>Private source review task</section> }))
beforeEach(() => { vi.clearAllMocks(); mocks.fetchAdminContentItems.mockResolvedValue([]); mocks.fetchAdminContentPacks.mockResolvedValue([]) })
afterEach(cleanup)
it('keeps source, teaching and collection tasks focused while retaining unsaved drafts', async () => {
  const dirty = vi.fn()
  const lifecycle = { pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 2 })), isCurrent: vi.fn(() => true), finish: vi.fn() }
  render(<CoachContentLibrary currentUser={{ id: 10, is_admin: false } as CurrentUser} selectedPersona={null} mutationLifecycle={lifecycle} onDirtyChange={dirty} onPersonaChange={() => undefined} />)
  expect(screen.getByText('Private source review task').closest('[hidden]')).toBeNull()
  await screen.findByRole('button', { name: 'Teaching items' })
  fireEvent.click(screen.getByRole('button', { name: 'Teaching items' }))
  fireEvent.click(screen.getByRole('button', { name: 'New item' }))
  fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Unfinished coach guidance' } })
  fireEvent.click(screen.getByRole('button', { name: 'Published collections' }))
  expect(screen.getByLabelText('Title').closest('[hidden]')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'New pack' }))
  fireEvent.change(screen.getByLabelText('Pack name'), { target: { value: 'Unfinished collection' } })
  fireEvent.click(screen.getByRole('button', { name: 'Teaching items' }))
  expect(screen.getByLabelText('Title')).toHaveProperty('value', 'Unfinished coach guidance')
  expect(dirty).toHaveBeenLastCalledWith(true)
})
