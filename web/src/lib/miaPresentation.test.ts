import { describe, expect, it } from 'vitest'
import { parseMiaAnswerPresentation } from './miaPresentation'

const validPresentation = {
  version: 1,
  kind: 'read_only_answer',
  basis: 'saved_household_plus_scenario',
  lead: 'Protect the required minimums before directing extra money to debt.',
  sections: [
    { id: 'avalanche', title: 'Avalanche', body: 'Card A comes first.' },
    { id: 'next-move', title: 'Next move', body: 'Keep runway protected.' },
  ],
  scenario: {
    values: [{ label: 'Personal loan balance', display_value: '$8,000' }],
  },
}

describe('parseMiaAnswerPresentation', () => {
  it('returns a normalized version-one read-only presentation', () => {
    expect(parseMiaAnswerPresentation({ ...validPresentation, ignored: 'not exposed' })).toEqual(validPresentation)
  })

  it('preserves markup-like text as inert strings', () => {
    const parsed = parseMiaAnswerPresentation({
      ...validPresentation,
      sections: [{ id: 'safe', title: '<b>Plan</b>', body: '<script>not executable</script>' }],
    })

    expect(parsed?.sections[0]).toEqual({
      id: 'safe',
      title: '<b>Plan</b>',
      body: '<script>not executable</script>',
    })
  })

  it.each([
    { ...validPresentation, version: 2 },
    { ...validPresentation, sections: [] },
    { ...validPresentation, sections: [validPresentation.sections[0], validPresentation.sections[0]] },
    { ...validPresentation, scenario: undefined },
    { ...validPresentation, basis: 'saved_household', scenario: validPresentation.scenario },
  ])('rejects malformed or internally inconsistent presentations', (candidate) => {
    expect(parseMiaAnswerPresentation(candidate)).toBeNull()
  })
})
