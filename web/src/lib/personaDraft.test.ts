import { describe, expect, it } from 'vitest'
import {
  appendListItem,
  appendStringListItem,
  arrayToLineList,
  clonePersonaConfiguration,
  createEmptyPersonaExample,
  createEmptyPersonaGuidance,
  createEmptyPersonaPhrase,
  createEmptyPersonaScript,
  firstIncompleteGuidedStep,
  getGuidedStepCompleteness,
  isPersonaDraftDirty,
  lineListToArray,
  moveListItem,
  personaDraftsEqual,
  removeListItem,
  replaceListItem,
  PERSONA_ACCOUNTABILITY_STYLES,
  PERSONA_ENERGY_STYLES,
  PERSONA_LANGUAGE_STYLES,
  PERSONA_TONE_TRAITS,
  updateCultureLocaleLabel,
  updatePersonaConfiguration,
  updatePersonaSection,
  type PersonaConfiguration,
} from './personaDraft'

function configuration(): PersonaConfiguration {
  return {
    version: 1,
    identity: {
      assistant_name: 'Coach Lani',
      human_coach_name: 'Mrs. Mel',
      human_coach_title: 'Financial coach',
      assistant_relationship: 'A digital assistant guided by the human coach.',
      disclosure: 'Be clear that this is a digital assistant.',
      audience: 'People in the financial education program.',
      client_term: 'participant',
    },
    voice: {
      tone_traits: ['warm', 'direct'],
      energy: 'Calm and focused.',
      accountability_style: "Name choices and patterns clearly while protecting the participant's dignity.",
      language_style: ['Use plain language.'],
    },
    coaching: {
      philosophy: 'Make one practical move at a time.',
      method: 'Answer, explain, and give a next step.',
      principles: ['Use confirmed information.'],
      do: [],
      do_not: [],
    },
    culture: {
      locale_label: 'Guam',
      context: 'Use only details the coach explicitly approved.',
      local_realities: [],
      references: [],
    },
    phrases: [],
    curriculum: { guidance: [], scripts: [], examples: [] },
    response_shape: {
      min_sentences: 2,
      max_sentences: 5,
      max_characters: 1_500,
      plain_text_only: true,
      validate_before_coaching: true,
      next_move_required: true,
    },
  }
}

describe('persona draft cloning and updates', () => {
  it('deep clones nested objects and arrays', () => {
    const source = configuration()
    const clone = clonePersonaConfiguration(source)

    clone.identity.assistant_name = 'Changed'
    clone.voice.tone_traits.push('lighthearted')

    expect(source.identity.assistant_name).toBe('Coach Lani')
    expect(source.voice.tone_traits).toEqual(['warm', 'direct'])
  })

  it('updates nested values without mutating the saved draft', () => {
    const source = configuration()
    const updated = updatePersonaConfiguration(source, (draft) => {
      draft.curriculum.guidance.push({ title: 'Budget reset', content: 'Start with confirmed income.' })
    })
    const renamed = updatePersonaSection(source, 'identity', 'assistant_name', 'Coach Kai')

    expect(source.curriculum.guidance).toEqual([])
    expect(updated.curriculum.guidance[0]?.title).toBe('Budget reset')
    expect(source.identity.assistant_name).toBe('Coach Lani')
    expect(renamed.identity.assistant_name).toBe('Coach Kai')
  })

  it('changes a locale label without inferring language or cultural content', () => {
    const source = configuration()
    const updated = updateCultureLocaleLabel(source, 'The American South')

    expect(updated.culture).toEqual({
      ...source.culture,
      locale_label: 'The American South',
    })
    expect(source.culture.locale_label).toBe('Guam')
  })
})

describe('line-list conversion', () => {
  it('normalizes newlines, surrounding whitespace, and blank rows', () => {
    expect(lineListToArray(' warm \r\n\r\n direct\r respectful  ')).toEqual(['warm', 'direct', 'respectful'])
  })

  it('preserves authored order, wording, and repeated entries', () => {
    expect(lineListToArray('Guam\nSouthern\nGuam')).toEqual(['Guam', 'Southern', 'Guam'])
    expect(arrayToLineList(['Use plain language.', 'Ask one question.'])).toBe(
      'Use plain language.\nAsk one question.',
    )
  })
})

describe('dirty comparison', () => {
  it('compares full drafts by value instead of reference', () => {
    const saved = configuration()
    const clone = clonePersonaConfiguration(saved)

    expect(personaDraftsEqual(saved, clone)).toBe(true)
    expect(isPersonaDraftDirty(clone, saved)).toBe(false)

    clone.response_shape.max_characters = 900
    expect(isPersonaDraftDirty(clone, saved)).toBe(true)
  })

  it('handles drafts that have not loaded yet', () => {
    expect(personaDraftsEqual(undefined, undefined)).toBe(true)
    expect(personaDraftsEqual(null, undefined)).toBe(false)
  })
})

describe('safe immutable list operations', () => {
  it('adds normalized strings and respects a maximum', () => {
    const source = ['warm']
    expect(appendStringListItem(source, '  direct  ', 2)).toEqual(['warm', 'direct'])
    expect(appendStringListItem(source, '   ', 2)).toEqual(['warm'])
    expect(appendStringListItem(['warm', 'direct'], 'calm', 2)).toEqual(['warm', 'direct'])
    expect(source).toEqual(['warm'])
  })

  it('clones structured items when appending and replacing', () => {
    const first = { title: 'First', content: 'One' }
    const added = appendListItem([], first, 1)
    first.title = 'Mutated elsewhere'

    const replacement = { title: 'Second', content: 'Two' }
    const replaced = replaceListItem(added, 0, replacement)
    replacement.content = 'Mutated elsewhere'

    expect(added).toEqual([{ title: 'First', content: 'One' }])
    expect(replaced).toEqual([{ title: 'Second', content: 'Two' }])
  })

  it('removes and moves valid items while making invalid indexes harmless', () => {
    const source = ['one', 'two', 'three']

    expect(removeListItem(source, 1)).toEqual(['one', 'three'])
    expect(removeListItem(source, 1, 3)).toEqual(source)
    expect(removeListItem(source, -1)).toEqual(source)
    expect(moveListItem(source, 2, 0)).toEqual(['three', 'one', 'two'])
    expect(moveListItem(source, 4, 0)).toEqual(source)
    expect(replaceListItem(source, 8, 'missing')).toEqual(source)
    expect(source).toEqual(['one', 'two', 'three'])
  })
})

describe('guided editor completeness', () => {
  it('marks a valid base configuration complete, including optional empty collections', () => {
    const draft = configuration()
    expect(getGuidedStepCompleteness(draft)).toEqual({
      identity: true,
      voice: true,
      coaching: true,
      culture: true,
      phrases: true,
      curriculum: true,
      response_shape: true,
    })
    expect(firstIncompleteGuidedStep(draft)).toBeNull()
  })

  it('finds incomplete required fields and partially authored optional records', () => {
    const draft = configuration()
    draft.voice.tone_traits = []
    draft.phrases = [createEmptyPersonaPhrase()]
    draft.curriculum = {
      guidance: [createEmptyPersonaGuidance()],
      scripts: [createEmptyPersonaScript()],
      examples: [createEmptyPersonaExample()],
    }

    expect(getGuidedStepCompleteness(draft)).toMatchObject({
      voice: false,
      phrases: false,
      curriculum: false,
    })
    expect(firstIncompleteGuidedStep(draft)).toBe('voice')
  })

  it('accepts only the reviewed server vocabulary for every voice control', () => {
    const valid = configuration()
    valid.voice.tone_traits = [...PERSONA_TONE_TRAITS]
    valid.voice.energy = PERSONA_ENERGY_STYLES[4]
    valid.voice.accountability_style = PERSONA_ACCOUNTABILITY_STYLES[2]
    valid.voice.language_style = [...PERSONA_LANGUAGE_STYLES]

    expect(getGuidedStepCompleteness(valid).voice).toBe(true)
    expect(PERSONA_TONE_TRAITS).toContain('lighthearted')
    expect(PERSONA_TONE_TRAITS).toContain('formal')
    expect(PERSONA_LANGUAGE_STYLES).toContain('Use light humor only when the situation is not sensitive.')
    expect(PERSONA_LANGUAGE_STYLES).toContain('Keep the tone professional and formal.')
    expect([...PERSONA_TONE_TRAITS, ...PERSONA_LANGUAGE_STYLES].join(' ')).not.toMatch(/Guam|Chamorro|southern/i)

    const invalid = configuration()
    invalid.voice = {
      tone_traits: ['sound Guamanian'],
      energy: 'Guam energy.',
      accountability_style: 'Invent a custom style.',
      language_style: ['Use island lingo.'],
    } as unknown as PersonaConfiguration['voice']
    expect(getGuidedStepCompleteness(invalid).voice).toBe(false)
  })

  it('checks response constraints that the backend requires', () => {
    const draft = configuration()
    draft.response_shape.min_sentences = 6
    draft.response_shape.max_sentences = 5

    expect(getGuidedStepCompleteness(draft).response_shape).toBe(false)
  })
})
