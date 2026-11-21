// @vitest-environment jsdom
import { useCallback, useState } from 'react'
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
  const [choice, setChoice] = useState(month)
  const [money, setMoney] = useState('old money')
  const onChoice = useCallback((next: HomeViewChoice) => setChoice(next), [])
  const { changeHomeView, homeViewError, homeViewSaving } = useHomeView({ choice, onChoice, announce })
  return <><p>{choice.effective}</p><p>{money}</p><button disabled={homeViewSaving} onClick={() => void changeHomeView('year')}>Year first</button>{homeViewError && <p>{homeViewError}</p>}<button onClick={() => {
    // A reload started before the save: it carries fresh money and the old preference.
    void refresh?.then(payload => { setMoney('fresh money'); setChoice(payload) })
  }}>Refresh workspace</button></>
}
it('applies a workspace reload started before the Home save but keeps her saved choice', async () => {
  let resolve!: (choice: HomeViewChoice) => void
  const refresh = new Promise<HomeViewChoice>(done => { resolve = done })
  vi.mocked(updateHomeView).mockResolvedValue({ home_view: year })
  render(<Harness refresh={refresh} />)
  fireEvent.click(screen.getByText('Refresh workspace'))
  fireEvent.click(screen.getByText('Year first'))
  await waitFor(() => expect(announce).toHaveBeenCalledWith('Home now shows your year first.'))
  await act(async () => resolve(month))
  expect(screen.getByText('fresh money')).toBeTruthy()
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
