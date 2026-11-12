import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

// A participant is in a "group" (or a named program), never a "cohort".
describe('participant wording', () => {
  it('does not call the group a cohort in the app shell', () => {
    const shell = readFileSync(new URL('../App.tsx', import.meta.url), 'utf8')
    expect(shell).not.toMatch(/in this cohort|your cohort|this cohort right now/)
  })
})
