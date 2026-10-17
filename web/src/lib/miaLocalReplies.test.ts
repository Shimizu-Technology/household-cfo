import { expect, it } from 'vitest'
import type { MiaMessage } from '../api'
import { keepLocalOnly, markLocalOnly, onlyLocalMessages } from './miaLocalReplies'

const pair: MiaMessage[] = [{ role: 'user', author: 'You', content: 'I set aside $50' }, { role: 'assistant', author: 'Mia', content: "Your savings challenge isn't open yet" }]

it('keeps an unsaved reply visible across empty server polls until the challenge opens', () => {
  let shown = markLocalOnly(pair)
  expect(shown.every((message) => message.local_only && message.client_id)).toBe(true)
  for (let poll = 0; poll < 3; poll += 1) shown = keepLocalOnly(shown, [], true)
  expect(shown.map((message) => message.content)).toEqual(pair.map((message) => message.content))
  const saved: MiaMessage = { id: 9, role: 'user', author: 'You', content: 'Earlier saved message' }
  expect(keepLocalOnly(shown, [saved], true).map((message) => message.content)).toEqual(['Earlier saved message', ...pair.map((message) => message.content)])
  expect(keepLocalOnly(shown, [], false)).toEqual([])
})

it('clears locally only when every shown message is unsaved', () => {
  const local = markLocalOnly(pair)
  expect(onlyLocalMessages(local)).toBe(true)
  expect(onlyLocalMessages([])).toBe(false)
  expect(onlyLocalMessages([{ id: 3, role: 'user', author: 'You', content: 'Saved earlier' }, ...local])).toBe(false)
})
