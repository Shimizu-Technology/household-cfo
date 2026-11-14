// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import { useLiveMiaResult } from './useLiveMiaResult'
afterEach(cleanup)
function Card({ complete, ready = true }: { complete: boolean; ready?: boolean }) { return <p data-testid="result" className={useLiveMiaResult(complete, ready)}>Result</p> }
it('fades only a live completion, never mounted or restored finished history', () => {
  const view = render(<Card complete />)
  expect(screen.getByTestId('result').className).toBe('')
  view.rerender(<Card complete={false} />)
  view.rerender(<Card complete />)
  expect(screen.getByTestId('result').className).toContain('is-live-result')
  view.unmount()
  render(<Card complete />)
  expect(screen.getByTestId('result').className).toBe('')
})

it('clears the live marker after the completion fade', async () => {
  const view = render(<Card complete={false} />)
  view.rerender(<Card complete />)
  expect(screen.getByTestId('result').className).toContain('is-live-result')
  await waitFor(() => expect(screen.getByTestId('result').className).toBe(''))
})

it('does not mistake asynchronously loaded finished history or a refresh for a live save', () => {
  const view = render(<Card complete={false} ready={false} />)
  view.rerender(<Card complete ready />)
  expect(screen.getByTestId('result').className).toBe('')
  view.rerender(<Card complete={false} ready={false} />)
  view.rerender(<Card complete ready />)
  expect(screen.getByTestId('result').className).toBe('')
})
