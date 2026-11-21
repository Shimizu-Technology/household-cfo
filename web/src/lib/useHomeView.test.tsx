// @vitest-environment jsdom
import { useRef, useState } from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { updateHomeView, type HomeViewChoice } from '../api'
import { useHomeView } from './useHomeView'
vi.mock('../api', () => ({ updateHomeView: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
const month: HomeViewChoice = { chosen: null, effective: 'month', program: 'month' }
const year: HomeViewChoice = { ...month, chosen: 'year', effective: 'year' }
const announce = vi.fn()
function Harness({ refresh }: { refresh?: Promise<HomeViewChoice> }) {
  const [choice, onChoice] = useState(month)
  const generationRef = useRef(0)
  const { changeHomeView, homeViewError, homeViewSaving } = useHomeView({ choice, generationRef, onChoice, announce })
  return <><p>{choice.effective}</p><button disabled={homeViewSaving} onClick={() => void changeHomeView('year')}>Year first</button>{homeViewError && <p>{homeViewError}</p>}<button onClick={() => {
    const captured = generationRef.current
    void refresh?.then(payload => { if (captured === generationRef.current) onChoice(payload) })
  }}>Refresh workspace</button></>
}
it('invalidates a workspace payload started before the Home save', async () => {
  let resolve!: (choice: HomeViewChoice) => void
  const refresh = new Promise<HomeViewChoice>(done => { resolve = done })
  vi.mocked(updateHomeView).mockResolvedValue({ home_view: year })
  render(<Harness refresh={refresh} />)
  fireEvent.click(screen.getByText('Refresh workspace'))
  fireEvent.click(screen.getByText('Year first'))
  await waitFor(() => expect(announce).toHaveBeenCalledWith('Home now shows your year first.'))
  await act(async () => resolve(month))
  expect(screen.getByText('year')).toBeTruthy()
})
it('reverts with a visible error and live announcement, clearing the error on retry', async () => {
  vi.mocked(updateHomeView).mockRejectedValueOnce(new Error('offline'))
  render(<Harness />)
  fireEvent.click(screen.getByText('Year first'))
  const message = 'Home view could not be saved right now. Please try again.'
  expect(await screen.findByText(message)).toBeTruthy()
  expect(screen.getByText('month')).toBeTruthy()
  expect(announce).toHaveBeenCalledWith(message)
  vi.mocked(updateHomeView).mockResolvedValueOnce({ home_view: year })
  fireEvent.click(screen.getByText('Year first'))
  expect(screen.queryByText(message)).toBeNull()
  await waitFor(() => expect(announce).toHaveBeenCalledWith('Home now shows your year first.'))
})
