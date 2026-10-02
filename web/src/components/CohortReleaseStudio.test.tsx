// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { CohortReleaseStudio as CohortReleaseStudioData } from '../api'
import { CohortReleaseStudio } from './CohortReleaseStudio'

const apiMocks = vi.hoisted(() => ({
  createCohortReleaseRequestId: vi.fn(() => 'release-request-1'),
  fetchCohortReleaseStudio: vi.fn(),
  restoreCohortRelease: vi.fn(),
  sealCohortRelease: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  ...apiMocks,
}))

const studioFixture: CohortReleaseStudioData = {
  cohort: { id: 12, name: 'Tuesday cohort', status: 'active' },
  runtime_truth: { changes_participant_runtime: false, message: 'Release records preserve audit evidence without changing participant runtime.' },
  permissions: { view: true, seal: true, restore: true },
  candidate: {
    bundle_digest: 'bundle-next-1234567890',
    assignment_id: 31,
    persona_version_id: 6,
    experience_version_id: 8,
    registry_digest: 'registry-v3',
    registry_version: 3,
    expected_latest_release_id: 44,
    seal_needed: true,
    ready: true,
    blockers: [],
    warnings: [],
    checks: [
      { key: 'assistant_voice', label: 'Assistant voice', ready: true, detail: 'Version 6 is published.' },
      { key: 'participant_tools', label: 'Participant tools', ready: true, detail: 'Version 8 is published.' },
      { key: 'system_controls', label: 'System controls', ready: true, detail: 'Registry version 3 is ready.' },
      { key: 'participant_cohort', label: 'Participant cohort check', ready: true, detail: 'No ambiguous participants.' },
    ],
  },
  latest_release_match: false,
  history: { limit: 25, total_count: 1, truncated: false },
  releases: [{
    id: 44,
    release_number: 4,
    event_type: 'release',
    released_at: '2026-10-03T01:00:00Z',
    actor: { id: 7, full_name: 'Coach Mel' },
    actor_user_id: 7,
    bundle_digest: 'bundle-old',
    source_release_id: null,
    persona_version_id: 5,
    experience_version_id: 7,
    registry_digest: 'registry-v2',
    registry_version: 2,
    restore_allowed: true,
    restore_reason: null,
  }],
}

const cohorts = [{
  id: 12,
  name: 'Tuesday cohort',
  status: 'active' as const,
  assignable: true,
  blocked_reason: null,
  persona_assignment: null,
}]

function renderStudio() {
  const mutationLifecycle = {
    pending: false,
    begin: vi.fn(() => ({ id: 1, workspaceId: 2 })),
    isCurrent: vi.fn(() => true),
    finish: vi.fn(),
  }
  render(
    <CohortReleaseStudio
      cohorts={cohorts}
      cohortsLoading={false}
      mutationLifecycle={mutationLifecycle}
      selectedCohortId={12}
      onSelectedCohortIdChange={vi.fn()}
    />,
  )
  return mutationLifecycle
}

beforeEach(() => {
  vi.clearAllMocks()
  apiMocks.createCohortReleaseRequestId.mockReturnValue('release-request-1')
  apiMocks.fetchCohortReleaseStudio.mockResolvedValue(studioFixture)
  apiMocks.sealCohortRelease.mockResolvedValue({ release: { id: 45 } })
  apiMocks.restoreCohortRelease.mockResolvedValue({ release: { id: 46 } })
})

afterEach(cleanup)

describe('CohortReleaseStudio', () => {
  it('shows exact readiness, immutable history, and persistent runtime truth', async () => {
    renderStudio()

    expect(await screen.findByRole('heading', { name: 'Ready to seal' })).toBeTruthy()
    expect(screen.getByText('Release records are audit evidence.')).toBeTruthy()
    expect(screen.getByText(/without changing participant runtime/)).toBeTruthy()
    for (const label of ['Assistant voice', 'Participant tools', 'System controls', 'Participant cohort check']) {
      expect(screen.getByText(label)).toBeTruthy()
    }
    expect(screen.getByText('Latest sealed record')).toBeTruthy()
    for (const control of screen.getAllByRole('button')) {
      expect(control.textContent).not.toMatch(/\b(Current|Live|Activate|Deploy|Publish)\b/i)
    }
  })

  it('focuses Cancel first, traps focus, closes on Escape, and returns focus', async () => {
    const user = userEvent.setup()
    renderStudio()
    const sealButton = await screen.findByRole('button', { name: 'Review and seal record' })
    await user.click(sealButton)

    const dialog = screen.getByRole('dialog', { name: 'Seal this release record?' })
    const cancel = within(dialog).getByRole('button', { name: 'Cancel' })
    const confirm = within(dialog).getByRole('button', { name: 'Seal release record' })
    expect(document.activeElement).toBe(cancel)
    await user.tab({ shift: true })
    expect(document.activeElement).toBe(confirm)
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    await waitFor(() => expect(document.activeElement).toBe(sealButton))
  })

  it('reuses the same operation key after an uncertain failure and reports truthful success', async () => {
    const user = userEvent.setup()
    apiMocks.sealCohortRelease
      .mockRejectedValueOnce(new Error('Connection interrupted.'))
      .mockResolvedValueOnce({ release: { id: 45 } })
    renderStudio()
    await user.click(await screen.findByRole('button', { name: 'Review and seal record' }))
    const confirm = screen.getByRole('button', { name: 'Seal release record' })

    await user.click(confirm)
    expect((await screen.findByRole('alert')).textContent).toContain('Connection interrupted.')
    await user.click(confirm)

    await waitFor(() => expect(apiMocks.sealCohortRelease).toHaveBeenCalledTimes(2))
    expect(apiMocks.sealCohortRelease.mock.calls.map((call) => call[2])).toEqual(['release-request-1', 'release-request-1'])
    expect((await screen.findByRole('status')).textContent).toContain('Participant runtime did not change.')
  })

  it('submits exact historical evidence when restoring a record', async () => {
    const user = userEvent.setup()
    renderStudio()
    await user.click(await screen.findByRole('button', { name: 'Review restore record' }))
    const dialog = screen.getByRole('dialog', { name: 'Restore record #4' })
    expect(document.activeElement).toBe(within(dialog).getByRole('button', { name: 'Cancel' }))
    await user.click(within(dialog).getByRole('button', { name: 'Seal restore record' }))

    await waitFor(() => expect(apiMocks.restoreCohortRelease).toHaveBeenCalledWith(12, 44, {
      expected_latest_release_id: 44,
      source_bundle_digest: 'bundle-old',
      source_persona_version_id: 5,
      source_experience_version_id: 7,
    }, 'release-request-1'))
  })

  it('blocks restore when the server omits the latest-release precondition', async () => {
    apiMocks.fetchCohortReleaseStudio.mockResolvedValue({
      ...studioFixture,
      candidate: studioFixture.candidate && {
        ...studioFixture.candidate,
        expected_latest_release_id: null,
      },
    })
    renderStudio()

    expect(await screen.findByText(/Restore unavailable: latest release evidence is unavailable/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Review restore record' })).toBeNull()
    expect(apiMocks.restoreCohortRelease).not.toHaveBeenCalled()
  })

  it('keeps read-only review useful without exposing mutation controls', async () => {
    apiMocks.fetchCohortReleaseStudio.mockResolvedValue({
      ...studioFixture,
      permissions: { view: true, seal: false, restore: false },
    })
    renderStudio()

    expect(await screen.findByRole('heading', { name: 'Ready to seal' })).toBeTruthy()
    expect(screen.getByText(/does not allow sealing records/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: /seal record/i })).toBeNull()
    expect(screen.queryByRole('button', { name: /restore record/i })).toBeNull()
  })

  it('reports the full immutable history count when the API returns only the newest records', async () => {
    apiMocks.fetchCohortReleaseStudio.mockResolvedValue({
      ...studioFixture,
      history: { limit: 25, total_count: 100, truncated: true },
    })
    renderStudio()

    expect(await screen.findByRole('heading', { name: '1 of 100 sealed records' })).toBeTruthy()
  })
})
