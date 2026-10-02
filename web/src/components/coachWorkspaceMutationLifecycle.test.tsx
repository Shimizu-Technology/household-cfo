// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminContentPack, AdminPersonaDetail } from '../api'
import { PersonaContentPacksPanel } from './CoachContentLibrary'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const apiMocks = vi.hoisted(() => ({
  fetchAdminContentPacks: vi.fn(),
  updateAdminPersonaContentPacks: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  ...apiMocks,
}))

const packVersion = { id: 31, pack_id: 21, version: 1, name: 'Workspace pack' }
const pack = {
  id: 21,
  name: 'Workspace pack',
  pack_kind: 'voice_culture',
  archived: false,
  current_published_version: packVersion,
} as AdminContentPack

function persona(name: string) {
  return {
    id: 81,
    name,
    draft_revision: 1,
    content_packs: [],
    permissions: { edit: true },
  } as unknown as AdminPersonaDetail
}

function Harness({ workspaceId, onPersonaChange }: { workspaceId: number; onPersonaChange: (value: AdminPersonaDetail) => void }) {
  const lifecycle = useCoachWorkspaceMutationLifecycle(workspaceId)
  return <>
    <select aria-label="Workspace" disabled={lifecycle.pending} value={workspaceId} onChange={() => undefined}>
      <option value={workspaceId}>Workspace {workspaceId}</option>
    </select>
    <PersonaContentPacksPanel
      key={workspaceId}
      persona={persona(`Workspace ${workspaceId} persona`)}
      dirty={false}
      mutationLifecycle={lifecycle}
      onDirtyChange={() => undefined}
      onPersonaChange={onPersonaChange}
    />
  </>
}

describe('coach workspace mutation lifecycle', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiMocks.fetchAdminContentPacks.mockResolvedValue([pack])
  })
  afterEach(cleanup)

  it('blocks workspace switching and rejects a delayed content-pack response from the prior workspace', async () => {
    let release!: (value: AdminPersonaDetail) => void
    apiMocks.updateAdminPersonaContentPacks.mockReturnValue(new Promise<AdminPersonaDetail>((resolve) => { release = resolve }))
    const onPersonaChange = vi.fn()
    const view = render(<Harness workspaceId={1} onPersonaChange={onPersonaChange} />)

    await userEvent.click(await screen.findByLabelText(/Workspace pack/))
    await userEvent.click(screen.getByRole('button', { name: 'Save source selection' }))
    expect((screen.getByLabelText('Workspace') as HTMLSelectElement).disabled).toBe(true)

    view.rerender(<Harness workspaceId={2} onPersonaChange={onPersonaChange} />)
    release(persona('Delayed workspace 1 response'))

    await vi.waitFor(() => expect((screen.getByLabelText('Workspace') as HTMLSelectElement).disabled).toBe(false))
    expect(onPersonaChange).not.toHaveBeenCalled()
    expect(screen.getByText('Workspace 2')).toBeTruthy()
  })
})
