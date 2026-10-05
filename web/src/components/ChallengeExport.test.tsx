// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ChallengeExport } from './ChallengeExport'
import { fetchPrivateJson } from '../api'
vi.mock('../api', () => ({ fetchPrivateJson: vi.fn() }))
afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})
beforeEach(() => {
  vi.clearAllMocks()
  vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: vi.fn(() => 'blob:private'), revokeObjectURL: vi.fn() }))
})
it('requires explicit download and defaults feelings off; actor mismatch creates no copy', async () => {
  vi.mocked(fetchPrivateJson).mockResolvedValue({
    schema_version: 1,
    actor_scope: { user_id: 99, household_id: 2 },
    optional_reflections_included: false,
  })
  render(<ChallengeExport cohortId={1} scope={{ user_id: 1, household_id: 2 }} />)
  expect((coachDownload() as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(
    screen.getByLabelText('Download this private file to my device. The app cannot recall downloaded copies.')
  )
  fireEvent.click(coachDownload())
  await screen.findByRole('alert')
  expect(fetchPrivateJson).toHaveBeenCalledWith(
    expect.stringContaining('include_reflections=false'),
    expect.objectContaining({ cache: 'no-store' })
  )
  expect(URL.createObjectURL).not.toHaveBeenCalled()
})
it('does not download an old actor response after account switch', async () => {
  let finish!: (result: unknown) => void
  vi.mocked(fetchPrivateJson).mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve
      })
  )
  const view = render(<ChallengeExport cohortId={1} scope={{ user_id: 1, household_id: 2 }} />)
  fireEvent.click(
    screen.getByLabelText('Download this private file to my device. The app cannot recall downloaded copies.')
  )
  fireEvent.click(coachDownload())
  view.rerender(<ChallengeExport cohortId={1} scope={{ user_id: 3, household_id: 4 }} />)
  await act(async () =>
    finish({ schema_version: 1, actor_scope: { user_id: 1, household_id: 2 }, optional_reflections_included: false })
  )
  expect(URL.createObjectURL).not.toHaveBeenCalled()
})
function coachDownload() {
  return screen.getByRole('button', { name: 'Download reviewed records' })
}
it('clears review choices and ignores a delayed response after the same actor changes cohort', async () => {
  let finish!: (result: unknown) => void
  vi.mocked(fetchPrivateJson).mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve
      })
  )
  const view = render(<ChallengeExport cohortId={1} scope={{ user_id: 1, household_id: 2 }} />)
  fireEvent.click(screen.getByLabelText('Include my optional feeling history. Leave unchecked to exclude feelings.'))
  fireEvent.click(
    screen.getByLabelText('Download this private file to my device. The app cannot recall downloaded copies.')
  )
  fireEvent.click(coachDownload())
  view.rerender(<ChallengeExport cohortId={2} scope={{ user_id: 1, household_id: 2 }} />)
  expect(
    (
      screen.getByLabelText(
        'Include my optional feeling history. Leave unchecked to exclude feelings.'
      ) as HTMLInputElement
    ).checked
  ).toBe(false)
  expect((coachDownload() as HTMLButtonElement).disabled).toBe(true)
  await act(async () =>
    finish({
      schema_version: 1,
      actor_scope: { user_id: 1, household_id: 2 },
      enrollment: { cohort_id: 1 },
      optional_reflections_included: true,
    })
  )
  expect(URL.createObjectURL).not.toHaveBeenCalled()
})
it('rejects a response for another cohort even when the actor matches', async () => {
  vi.mocked(fetchPrivateJson).mockResolvedValue({
    schema_version: 1,
    actor_scope: { user_id: 1, household_id: 2 },
    enrollment: { cohort_id: 2 },
    optional_reflections_included: false,
  })
  render(<ChallengeExport cohortId={1} scope={{ user_id: 1, household_id: 2 }} />)
  fireEvent.click(
    screen.getByLabelText('Download this private file to my device. The app cannot recall downloaded copies.')
  )
  fireEvent.click(coachDownload())
  await screen.findByRole('alert')
  expect(URL.createObjectURL).not.toHaveBeenCalled()
})
