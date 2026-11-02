import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { DocumentReadingProgress } from './DocumentReadingProgress'

describe('DocumentReadingProgress', () => {
  it('shows actual page progress and explains that leaving is safe', () => {
    render(<DocumentReadingProgress progress={{ stage: 'reading', page: 2, page_count: 3 }} />)
    expect(screen.getByText(/Reading your statement… 2 of 3 pages/).textContent).toContain('nothing changes until you review it')
  })
  it.each([undefined, { page: 0, page_count: 3 }, { page: 4, page_count: 3 }, { page: 1, page_count: NaN }])('never invents a page count for %s', (progress) => {
    render(<DocumentReadingProgress progress={progress} />)
    expect(screen.getByText(/Reading your saved file/)).toBeTruthy()
  })
  it('names the initial checking step', () => {
    render(<DocumentReadingProgress progress={{ stage: 'checking' }} />)
    expect(screen.getByText(/Checking your saved file/)).toBeTruthy()
  })
})
