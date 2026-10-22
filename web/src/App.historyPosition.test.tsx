// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { createRef } from 'react'
import { afterEach, expect, it, vi } from 'vitest'
import { useMiaHistoryPosition } from './components/useMiaHistoryPosition'

afterEach(() => { cleanup(); vi.resetAllMocks() })

function setup() {
  const chatRef = createRef<HTMLDivElement>()
  const queued = vi.fn()
  function History({ count, older = 3, scope = 'household', loading = false }: { count: number; older?: number; scope?: string; loading?: boolean }) {
    const queue = useMiaHistoryPosition({ chatRef, visibleMessageCount: count, olderMessageCount: older, scope })
    return <><button onClick={() => queued(queue())}>Load earlier</button><div ref={chatRef}>{Array.from({ length: count }, (_, i) => <p key={i}>Message {i}</p>)}{older > 0 && <span>Earlier history</span>}</div>{loading && <p>Loading</p>}</>
  }
  const view = render(<History count={2} />)
  const chat = chatRef.current!
  Object.defineProperty(chat, 'scrollHeight', { get: () => chat.querySelectorAll('p').length * 100 + (chat.querySelector('span') ? 50 : 0) })
  chat.scrollTop = 80
  return { view, chat, History, queued }
}

it('waits through the loading render and restores against the committed prepend height', () => {
  const { view, chat, History, queued } = setup()
  fireEvent.click(screen.getByRole('button', { name: 'Load earlier' }))
  expect(queued).toHaveBeenCalledWith(true)
  view.rerender(<History count={2} loading />)
  expect(chat.scrollTop).toBe(80)
  view.rerender(<History count={5} older={0} />)
  expect(chat.scrollTop).toBe(330)
})

it('restores when an exhausted history response removes the control without adding messages', () => {
  const { view, chat, History } = setup()
  fireEvent.click(screen.getByRole('button', { name: 'Load earlier' }))
  view.rerender(<History count={2} older={0} />)
  expect(chat.scrollTop).toBe(30)
})

it('discards a queued position when the conversation scope changes', () => {
  const { view, chat, History } = setup()
  fireEvent.click(screen.getByRole('button', { name: 'Load earlier' }))
  view.rerender(<History count={5} scope="another household" />)
  expect(chat.scrollTop).toBe(80)
})
