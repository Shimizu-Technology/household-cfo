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
  runtime_truth: { changes_participant_runtime: false, message: 'Release records preserve audit evidence without changing participant settings.' },
  permissions: { view: true, seal: true, restore: true },
  candidate: {
    manifest_schema: 'cohort_release_manifest_v2',
    bundle_digest: 'bundle-next-1234567890',
    assignment_id: 31,
    persona_version_id: 6,
    experience_version_id: 8,
    brand_mode: 'published_version',
    brand_version_id: 9,
    brand_snapshot_digest: 'brand-v9',
    registry_digest: 'registry-v3',
    registry_version: 3,
    participant_experience: null,
    expected_latest_release_id: 44,
    seal_needed: true,
    ready: true,
    blockers: [],
    warnings: [],
    checks: [
      { key: 'workspace_brand', label: 'Workspace brand', ready: true, detail: 'Version 9 is published.' },
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
    manifest_schema: 'cohort_release_manifest_v2',
    released_at: '2026-10-03T01:00:00Z',
    actor: { id: 7, full_name: 'Coach Mel' },
    actor_user_id: 7,
    bundle_digest: 'bundle-old',
    source_release_id: null,
    persona_version_id: 5,
    experience_version_id: 7,
    brand_mode: 'published_version',
    brand_version_id: 8,
    brand_snapshot_digest: 'brand-v8',
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

function renderStudio(beforeReleaseAction?: () => boolean) {
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
      beforeReleaseAction={beforeReleaseAction}
    />,
  )
  return mutationLifecycle
}

beforeEach(() => {
  vi.resetAllMocks()
  apiMocks.createCohortReleaseRequestId.mockReturnValue('release-request-1')
  apiMocks.fetchCohortReleaseStudio.mockResolvedValue(studioFixture)
  apiMocks.sealCohortRelease.mockResolvedValue({ release: { id: 45 } })
  apiMocks.restoreCohortRelease.mockResolvedValue({ release: { id: 46 } })
})

afterEach(cleanup)

describe('CohortReleaseStudio', () => {
  it('shows exact readiness, immutable history, and persistent runtime truth', async () => {
    renderStudio()

    expect(await screen.findByRole('heading', { name: 'Ready to prepare' })).toBeTruthy()
    expect(screen.getByText('Saved versions are kept as a record.')).toBeTruthy()
    expect(screen.getByText(/does not change the appearance, assistant, or tools participants use/)).toBeTruthy()
    for (const label of ['Program appearance', 'Assistant voice', 'Participant tools', 'System controls', 'Group membership']) {
      expect(screen.getByText(label)).toBeTruthy()
    }
    expect(screen.getAllByText('Brand version')).toHaveLength(2)
    expect(screen.getByText('Version 9')).toBeTruthy()
    expect(screen.getByText('Latest saved version')).toBeTruthy()
    for (const control of screen.getAllByRole('button')) {
      expect(control.textContent).not.toMatch(/\b(Current|Live|Activate|Deploy|Publish)\b/i)
    }
  })

  it('focuses the review from the top, traps focus, closes on Escape, and returns focus', async () => {
    const user = userEvent.setup()
    renderStudio()
    const sealButton = await screen.findByRole('button', { name: 'Review and prepare version' })
    await user.click(sealButton)

    const dialog = screen.getByRole('dialog', { name: 'Prepare this version?' })
    expect(within(dialog).getByText('Brand version')).toBeTruthy()
    expect(within(dialog).getByText('Version 9')).toBeTruthy()
    const cancel = within(dialog).getByRole('button', { name: 'Cancel' })
    const confirm = within(dialog).getByRole('button', { name: 'Prepare version' })
    expect(document.activeElement).toBe(dialog)
    await user.tab(); expect(document.activeElement).toBe(cancel)
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
    await user.click(await screen.findByRole('button', { name: 'Review and prepare version' }))
    const confirm = screen.getByRole('button', { name: 'Prepare version' })

    await user.click(confirm)
    expect((await screen.findByRole('alert')).textContent).toContain('Connection interrupted.')
    await user.click(confirm)

    await waitFor(() => expect(apiMocks.sealCohortRelease).toHaveBeenCalledTimes(2))
    expect(apiMocks.sealCohortRelease.mock.calls.map((call) => call[2])).toEqual(['release-request-1', 'release-request-1'])
    expect((await screen.findByRole('status')).textContent).toContain('Participant settings did not change.')
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Ready to prepare' })))
  })

  it('submits exact historical evidence when restoring a record', async () => {
    const user = userEvent.setup()
    renderStudio()
    await user.click(await screen.findByRole('button', { name: 'Review restore record' }))
    const dialog = screen.getByRole('dialog', { name: 'Restore version 4' })
    expect(document.activeElement).toBe(dialog)
    await user.click(within(dialog).getByRole('button', { name: 'Save restored version' }))

    await waitFor(() => expect(apiMocks.restoreCohortRelease).toHaveBeenCalledWith(12, 44, {
      expected_latest_release_id: 44,
      source_bundle_digest: 'bundle-old',
      source_persona_version_id: 5,
      source_experience_version_id: 7,
      source_brand_version_id: 8,
    }, 'release-request-1'))
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Ready to prepare' })))
  })

  it('labels historical v1 branding and restores it without a brand version token', async () => {
    const user = userEvent.setup()
    apiMocks.fetchCohortReleaseStudio.mockResolvedValue({
      ...studioFixture,
      releases: studioFixture.releases.map((release) => ({
        ...release,
        manifest_schema: 'cohort_release_manifest_v1',
        brand_mode: 'legacy_household_cfo_builtin',
        brand_version_id: null,
        brand_snapshot_digest: '35ded27bda2348d56c1db078c087ed681442a4a7bba86d8924c39a9342fa7eb8',
      })),
    })
    renderStudio()

    expect(await screen.findByText('Household CFO legacy brand')).toBeTruthy()
    await user.click(screen.getByRole('button', { name: 'Review restore record' }))
    const dialog = screen.getByRole('dialog', { name: 'Restore version 4' })
    expect(within(dialog).getByText('Historical brand')).toBeTruthy()
    expect(within(dialog).getByText('Household CFO legacy brand')).toBeTruthy()
    await user.click(within(dialog).getByRole('button', { name: 'Save restored version' }))
    await waitFor(() => expect(apiMocks.restoreCohortRelease).toHaveBeenCalledWith(12, 44, expect.objectContaining({
      source_brand_version_id: null,
    }), 'release-request-1'))
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

    expect(await screen.findByText(/Restore unavailable: the latest version details are unavailable/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Review restore record' })).toBeNull()
    expect(apiMocks.restoreCohortRelease).not.toHaveBeenCalled()
  })

  it('keeps read-only review useful without exposing mutation controls', async () => {
    apiMocks.fetchCohortReleaseStudio.mockResolvedValue({
      ...studioFixture,
      permissions: { view: true, seal: false, restore: false },
    })
    renderStudio()

    expect(await screen.findByRole('heading', { name: 'Ready to prepare' })).toBeTruthy()
    expect(screen.getByText(/does not allow preparing versions/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: /seal record/i })).toBeNull()
    expect(screen.queryByRole('button', { name: /restore record/i })).toBeNull()
  })

  it('does not open a release review when an unsaved rollout guard declines', async () => {
    const user = userEvent.setup()
    const guard = vi.fn(() => false)
    renderStudio(guard)
    await user.click(await screen.findByRole('button', { name: 'Review and prepare version' }))
    expect(guard).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(apiMocks.sealCohortRelease).not.toHaveBeenCalled()
  })

  it('reports the full immutable history count when the API returns only the newest records', async () => {
    apiMocks.fetchCohortReleaseStudio.mockResolvedValue({
      ...studioFixture,
      history: { limit: 25, total_count: 100, truncated: true },
    })
    renderStudio()

    expect(await screen.findByRole('heading', { name: '1 of 100 saved versions' })).toBeTruthy()
  })
  it('shows the changed settings without treating an already-prepared version as a new task', async () => {
    apiMocks.fetchCohortReleaseStudio.mockResolvedValue({ ...studioFixture, latest_release_match: true, candidate: { ...studioFixture.candidate!, seal_needed: false } })
    renderStudio()
    await screen.findByRole('heading', { name: 'Settings already prepared' })
    expect(screen.getByRole('button', { name: 'Settings already prepared' })).toHaveProperty('disabled', true)
    expect(screen.getByText('Readiness checks').closest('details')).toHaveProperty('open', false)
    expect(screen.queryByRole('heading', { name: 'Ready to prepare' })).toBeNull()
  })

  it('lists only changed appearance, voice, tools and controls from the prepared bundle', async () => {
    const latest = studioFixture.releases[0]
    apiMocks.fetchCohortReleaseStudio.mockResolvedValue({ ...studioFixture, candidate: { ...studioFixture.candidate!, brand_snapshot_digest: latest.brand_snapshot_digest, registry_digest: latest.registry_digest } })
    renderStudio()
    await screen.findByRole('heading', { name: 'Ready to prepare' })
    expect(screen.getByText(/Pending changes:/).closest('p')?.textContent).toBe('Pending changes: Mia voice, Participant tools. Preparing this version does not change what participants use.')
  })

})
