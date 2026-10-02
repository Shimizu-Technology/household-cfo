// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { ApiRequestError, type AdminContentSourceUrlIntake } from '../api'
import { CoachUrlSourceIntake } from './CoachUrlSourceIntake'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const apiMocks = vi.hoisted(() => ({
  createAdminContentSourceUrlIntake: vi.fn(),
  createAdminContentSourceUrlRequestId: vi.fn(() => 'stable-request-id'),
  deleteAdminContentSourceUrlIntake: vi.fn(),
  fetchAdminContentSourceUrlIntake: vi.fn(),
  fetchAdminContentSourceUrlIntakes: vi.fn(),
  retryAdminContentSourceUrlIntakeCleanup: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({
  ...await importOriginal<typeof import('../api')>(),
  ...apiMocks,
}))

const mutationLifecycle: CoachWorkspaceMutationLifecycle = {
  pending: false,
  begin: () => ({ id: 1, workspaceId: 1 }),
  isCurrent: () => true,
  finish: () => undefined,
}

function intake(overrides: Partial<AdminContentSourceUrlIntake> = {}): AdminContentSourceUrlIntake {
  return {
    id: 8,
    scope: 'coach',
    status: 'failed',
    source_id: null,
    error_code: 'url_fetch_failed',
    error: 'The source could not be fetched safely.',
    cleanup_retryable: false,
    redaction_allowed: true,
    redaction_pending: false,
    redirect_count: 0,
    created_at: '2026-10-02T01:00:00Z',
    completed_at: '2026-10-02T01:01:00Z',
    ...overrides,
  }
}

function renderIntake(overrides: Partial<ComponentProps<typeof CoachUrlSourceIntake>> = {}) {
  return render(<CoachUrlSourceIntake
    scope="coach"
    canCreate
    permissionEnabled
    disabled={false}
    mutationLifecycle={mutationLifecycle}
    onDirtyChange={() => undefined}
    onBusyChange={() => undefined}
    onSourceReady={() => undefined}
    {...overrides}
  />)
}

describe('CoachUrlSourceIntake', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiMocks.fetchAdminContentSourceUrlIntakes.mockResolvedValue({ intakes: [], url_intake: { enabled: true, available: true } })
  })
  afterEach(cleanup)

  it('submits only HTTPS and reuses the request ID when a response is uncertain', async () => {
    const failed = intake()
    apiMocks.createAdminContentSourceUrlIntake
      .mockRejectedValueOnce(new Error('Connection ended before a response arrived.'))
      .mockResolvedValueOnce({ intake: failed, url_intake: { enabled: true, available: true } })
    renderIntake()

    const input = await screen.findByLabelText('HTTPS address')
    await userEvent.type(input, 'http://example.com/private?token=secret')
    await userEvent.click(screen.getByRole('button', { name: 'Import private snapshot' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Enter a complete HTTPS address')
    expect(apiMocks.createAdminContentSourceUrlIntake).not.toHaveBeenCalled()

    await userEvent.clear(input)
    await userEvent.type(input, 'https://example.com/private?token=secret')
    await userEvent.click(screen.getByRole('button', { name: 'Import private snapshot' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Connection ended')
    await userEvent.click(screen.getByRole('button', { name: 'Import private snapshot' }))

    await waitFor(() => expect(apiMocks.createAdminContentSourceUrlIntake).toHaveBeenCalledTimes(2))
    expect(apiMocks.createAdminContentSourceUrlIntake.mock.calls[0][0]).toEqual(apiMocks.createAdminContentSourceUrlIntake.mock.calls[1][0])
    expect(apiMocks.createAdminContentSourceUrlIntake.mock.calls[1][0]).toEqual({
      url: 'https://example.com/private?token=secret', requestId: 'stable-request-id', scope: 'coach',
    })
    expect((input as HTMLInputElement).value).toBe('')
    expect(screen.queryByText(/token=secret/)).toBeNull()
  })

  it('shows every server lifecycle without rendering the submitted address', async () => {
    const statuses: AdminContentSourceUrlIntake['status'][] = [
      'queued', 'fetching', 'staged', 'registering', 'registered', 'failed', 'cleanup_pending', 'cleanup_failed',
    ]
    apiMocks.fetchAdminContentSourceUrlIntakes.mockResolvedValue({
      intakes: statuses.map((status, index) => intake({ id: index + 1, status, source_id: status === 'registered' ? 77 : null, error: status.includes('failed') ? 'Safe error.' : null })),
      url_intake: { enabled: true, available: true },
    })
    renderIntake()

    expect(await screen.findByText('Queued securely')).toBeTruthy()
    for (const label of ['Fetching privately', 'Snapshot staged', 'Saving snapshot', 'Ready for source review', 'Needs attention', 'Cleaning private snapshot', 'Cleanup needs retry']) {
      expect(screen.getByText(label)).toBeTruthy()
    }
    expect(screen.getAllByText(/address hidden/)).toHaveLength(8)
    expect(document.body.textContent).not.toContain('https://')
  })

  it('redacts a terminal failed request after confirmation', async () => {
    const failed = intake()
    apiMocks.fetchAdminContentSourceUrlIntakes.mockResolvedValue({ intakes: [failed], url_intake: { enabled: true } })
    apiMocks.deleteAdminContentSourceUrlIntake.mockResolvedValue({ intake: intake({ status: 'deleted', redaction_allowed: false }) })
    renderIntake()

    await userEvent.click(await screen.findByRole('button', { name: 'Remove saved address' }))
    expect(screen.getByText(/Remove the encrypted address/)).toBeTruthy()
    await userEvent.click(screen.getByRole('button', { name: 'Remove address' }))

    await waitFor(() => expect(apiMocks.deleteAdminContentSourceUrlIntake).toHaveBeenCalledWith(8))
    expect(screen.queryByText('Secure web snapshot')).toBeNull()
    expect(screen.getByText(/Minimal redacted audit metadata remains/)).toBeTruthy()
  })

  it('reconciles an uncertain redaction response with the committed server state', async () => {
    const failed = intake()
    const pending = intake({ status: 'cleanup_pending', redaction_allowed: false, redaction_pending: true })
    apiMocks.fetchAdminContentSourceUrlIntakes.mockResolvedValue({ intakes: [failed], url_intake: { enabled: true } })
    apiMocks.deleteAdminContentSourceUrlIntake.mockRejectedValue(new Error('Connection ended before a response arrived.'))
    apiMocks.fetchAdminContentSourceUrlIntake.mockResolvedValue({ intake: pending })
    renderIntake()

    await userEvent.click(await screen.findByRole('button', { name: 'Remove saved address' }))
    await userEvent.click(screen.getByRole('button', { name: 'Remove address' }))

    await waitFor(() => expect(apiMocks.fetchAdminContentSourceUrlIntake).toHaveBeenCalledWith(8))
    expect(screen.getByText(/Private snapshot cleanup is in progress/)).toBeTruthy()
    expect(screen.queryByText(/could not be removed/)).toBeNull()
    expect(screen.getByText(/address is already redacted/i)).toBeTruthy()
  })

  it('does not claim an address was removed when redaction reconciliation is inaccessible', async () => {
    const failed = intake()
    apiMocks.fetchAdminContentSourceUrlIntakes.mockResolvedValue({ intakes: [failed], url_intake: { enabled: true } })
    apiMocks.deleteAdminContentSourceUrlIntake.mockRejectedValue(new Error('Connection ended before a response arrived.'))
    apiMocks.fetchAdminContentSourceUrlIntake.mockRejectedValue(new ApiRequestError('Not found', {
      status: 404, code: 'url_intake_not_found',
    }))
    renderIntake()

    await userEvent.click(await screen.findByRole('button', { name: 'Remove saved address' }))
    await userEvent.click(screen.getByRole('button', { name: 'Remove address' }))

    expect(await screen.findByText(/removal could not be confirmed/i)).toBeTruthy()
    expect(screen.queryByText(/Saved address removed/)).toBeNull()
    expect(screen.queryByText('Secure web snapshot')).toBeNull()
  })

  it('stops polling and removes an intake that is no longer accessible', async () => {
    const queued = intake({ status: 'queued', redaction_allowed: false })
    apiMocks.fetchAdminContentSourceUrlIntakes.mockResolvedValue({ intakes: [queued], url_intake: { enabled: true } })
    apiMocks.fetchAdminContentSourceUrlIntake.mockRejectedValue(new ApiRequestError('Not found', {
      status: 404, code: 'url_intake_not_found',
    }))
    renderIntake()

    expect(await screen.findByText('Queued securely')).toBeTruthy()
    await waitFor(() => expect(screen.queryByText('Queued securely')).toBeNull(), { timeout: 3500 })
    expect(screen.getByText(/no longer available/)).toBeTruthy()
    expect(apiMocks.fetchAdminContentSourceUrlIntake).toHaveBeenCalledTimes(1)
  })

  it('offers a working refresh after repeated polling failures', async () => {
    vi.useFakeTimers()
    try {
      const queued = intake({ status: 'queued', redaction_allowed: false })
      apiMocks.fetchAdminContentSourceUrlIntakes
        .mockResolvedValueOnce({ intakes: [queued], url_intake: { enabled: true } })
        .mockResolvedValueOnce({ intakes: [], url_intake: { enabled: true } })
      apiMocks.fetchAdminContentSourceUrlIntake.mockRejectedValue(new Error('Temporary network failure'))
      renderIntake()

      await act(async () => { await vi.runAllTicks() })
      expect(screen.getByText('Queued securely')).toBeTruthy()
      for (let attempt = 0; attempt < 4; attempt += 1) {
        await act(async () => { await vi.advanceTimersToNextTimerAsync() })
      }

      const refresh = screen.getByRole('button', { name: 'Refresh secure imports' })
      fireEvent.change(screen.getByLabelText('HTTPS address'), { target: { value: 'https://example.com/another' } })
      expect(screen.getByRole('button', { name: 'Refresh secure imports' })).toBeTruthy()
      fireEvent.click(refresh)
      await act(async () => { await vi.runAllTicks() })

      expect(apiMocks.fetchAdminContentSourceUrlIntakes).toHaveBeenCalledTimes(2)
      expect(screen.queryByRole('button', { name: 'Refresh secure imports' })).toBeNull()
    } finally {
      vi.useRealTimers()
    }
  })

  it('uses an in-memory address only to retry a just-submitted failed request', async () => {
    const failed = intake()
    apiMocks.createAdminContentSourceUrlIntake.mockResolvedValue({ intake: failed, url_intake: { enabled: true } })
    renderIntake()

    await userEvent.type(await screen.findByLabelText('HTTPS address'), 'https://example.com/lesson?private=1')
    await userEvent.click(screen.getByRole('button', { name: 'Import private snapshot' }))
    await userEvent.click(await screen.findByRole('button', { name: 'Retry secure import' }))

    await waitFor(() => expect(apiMocks.createAdminContentSourceUrlIntake).toHaveBeenCalledTimes(2))
    expect(apiMocks.createAdminContentSourceUrlIntake.mock.calls[1][0]).toEqual(apiMocks.createAdminContentSourceUrlIntake.mock.calls[0][0])
    expect(document.body.textContent).not.toContain('private=1')
  })

  it('keeps file upload as the available path when secure intake is disabled', async () => {
    apiMocks.fetchAdminContentSourceUrlIntakes.mockResolvedValue({ intakes: [], url_intake: { enabled: false, available: false } })
    renderIntake({ permissionEnabled: false })

    expect(await screen.findByText('Secure web import is unavailable.')).toBeTruthy()
    expect(screen.queryByLabelText('HTTPS address')).toBeNull()
    expect(screen.getByText(/Upload the source as a file/)).toBeTruthy()
  })
})
