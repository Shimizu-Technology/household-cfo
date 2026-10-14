// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { createRef } from 'react'
import { afterEach, expect, it, vi } from 'vitest'
import { ChatHistory } from './ChatHistory'

vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia' }) }))
afterEach(cleanup)

const baseProps = {
  messages: [],
  totalMessageCount: 0,
  hiddenMessageCount: 0,
  olderMessageCount: 0,
  historyLoading: false,
  miaLoading: false,
  showScrollButton: false,
  chatCardRef: createRef<HTMLElement>(),
  onScroll: () => undefined,
  onLoadEarlier: () => undefined,
  onScrollLatest: () => undefined,
  imports: [],
  onOpenLocal: () => undefined,
  onOpenImport: () => undefined,
  onOpenImportId: () => undefined,
  onReviewImportId: () => undefined,
}

it('greets with starting points that fill the composer instead of sending', () => {
  const choose = vi.fn()
  render(<ChatHistory {...baseProps} starterPrompts={[{ label: 'Update a debt', message: 'Help me update one of my household debts.' }]} onChoosePrompt={choose} />)
  expect(screen.getByRole('heading', { name: 'Hi, I’m Mia.' })).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Update a debt' }))
  expect(choose).toHaveBeenCalledWith('Help me update one of my household debts.')
})

it('omits starting points when none are offered', () => {
  render(<ChatHistory {...baseProps} />)
  expect(screen.queryByRole('group', { name: 'Ways to start' })).toBeNull()
})
