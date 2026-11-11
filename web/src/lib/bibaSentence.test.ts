import { expect, it } from 'vitest'
import { dailySnapshot } from '../test/dailyFixtures'
import { bibaSentence } from './bibaSentence'

const withSavings = (savings: Partial<typeof dailySnapshot.savings>) => ({ ...dailySnapshot, savings: { ...dailySnapshot.savings, ...savings } })

it('names the real amount set aside and the target when it is reached', () => {
  expect(bibaSentence(dailySnapshot)).toBe('You’ve set aside $550, which reaches your $500 target.')
})

it('says how far along the target is when it is not reached yet', () => {
  expect(bibaSentence(withSavings({ reported_cents: 2_500, target_cents: 35_000, achieved: false }))).toBe('You’ve set aside $25 so far, toward your $350 target.')
})

it('leaves the target out when none was accepted', () => {
  expect(bibaSentence(withSavings({ target_cents: null, achieved: null }))).toBe('You’ve set aside $550 so far.')
})

it('never turns an unknown total into $0', () => {
  const sentence = bibaSentence(withSavings({ reported_cents: null, achieved: null }))
  expect(sentence).toBe('Your review is saved.')
  expect(sentence).not.toContain('$')
})
