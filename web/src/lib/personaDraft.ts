import type {
  PersonaAccountabilityStyle,
  PersonaConfiguration,
  PersonaEnergyStyle,
  PersonaLanguageStyle,
  PersonaPhraseContext,
  PersonaPhraseFrequency,
  PersonaToneTrait,
} from '../api'

export type { PersonaConfiguration } from '../api'

export const PERSONA_PHRASE_FREQUENCIES = ['very_rare', 'rare', 'sparing', 'as_needed'] as const satisfies readonly PersonaPhraseFrequency[]
export const PERSONA_PHRASE_CONTEXTS = [
  'greeting',
  'verified_milestone',
  'emotional_support',
  'repeated_pattern',
  'routine',
  'general',
  'crisis',
] as const satisfies readonly PersonaPhraseContext[]
export const PERSONA_TONE_TRAITS = [
  'warm',
  'direct',
  'respectful',
  'calm',
  'encouraging',
  'candid',
  'patient',
  'concise',
  'practical',
  'reassuring',
  'lighthearted',
  'formal',
  'clear',
  'unhurried',
] as const satisfies readonly PersonaToneTrait[]
export const PERSONA_ENERGY_STYLES = [
  'Calm and focused.',
  'Calm, clear, and concise.',
  'Steady and reassuring.',
  'Warm and encouraging.',
  'Direct and energetic.',
  'Quiet and unhurried.',
] as const satisfies readonly PersonaEnergyStyle[]
export const PERSONA_ACCOUNTABILITY_STYLES = [
  "Name choices and patterns clearly while protecting the participant's dignity.",
  'Ask reflective questions before naming a pattern.',
  'Be direct about tradeoffs while staying respectful.',
  'Use gentle accountability and one practical next step.',
  'Keep accountability firm, calm, and specific.',
] as const satisfies readonly PersonaAccountabilityStyle[]
export const PERSONA_LANGUAGE_STYLES = [
  'Use plain language.',
  'Keep the next step concrete.',
  'Use short sentences and concrete questions.',
  'Prefer conversational language.',
  'Keep the tone professional and formal.',
  'Use light humor only when the situation is not sensitive.',
  'Be concise and avoid unnecessary jargon.',
  'Explain unfamiliar financial terms briefly.',
] as const satisfies readonly PersonaLanguageStyle[]

type PersonaPhrase = PersonaConfiguration['phrases'][number]
type PersonaGuidance = PersonaConfiguration['curriculum']['guidance'][number]
type PersonaScript = PersonaConfiguration['curriculum']['scripts'][number]
type PersonaExample = PersonaConfiguration['curriculum']['examples'][number]

export type PersonaConfigurationSection = Exclude<keyof PersonaConfiguration, 'version' | 'phrases'>
export type PersonaGuidedStep =
  | 'identity'
  | 'voice'
  | 'coaching'
  | 'culture'
  | 'phrases'
  | 'curriculum'
  | 'response_shape'

export const PERSONA_GUIDED_STEPS: readonly PersonaGuidedStep[] = [
  'identity',
  'voice',
  'coaching',
  'culture',
  'phrases',
  'curriculum',
  'response_shape',
]

export const PERSONA_LIST_LIMITS = {
  tone_traits: PERSONA_TONE_TRAITS.length,
  language_style: 8,
  principles: 16,
  coaching_do: 16,
  coaching_do_not: 16,
  local_realities: 16,
  cultural_references: 16,
  phrases: 24,
  guidance: 20,
  scripts: 20,
  examples: 20,
} as const

export function clonePersonaConfiguration(configuration: PersonaConfiguration): PersonaConfiguration {
  return cloneValue(configuration)
}

/**
 * Creates a deep copy before applying an editor change, so event handlers can
 * update nested values without ever mutating the last saved configuration.
 */
export function updatePersonaConfiguration(
  configuration: PersonaConfiguration,
  update: (draft: PersonaConfiguration) => void,
): PersonaConfiguration {
  const next = clonePersonaConfiguration(configuration)
  update(next)
  return next
}

export function updatePersonaSection<
  Section extends PersonaConfigurationSection,
  Field extends keyof PersonaConfiguration[Section],
>(
  configuration: PersonaConfiguration,
  section: Section,
  field: Field,
  value: PersonaConfiguration[Section][Field],
): PersonaConfiguration {
  return updatePersonaConfiguration(configuration, (draft) => {
    draft[section][field] = cloneValue(value)
  })
}

/**
 * Updates only the coach-authored label. Choosing or typing a place must never
 * infer slang, an accent, community facts, or cultural references.
 */
export function updateCultureLocaleLabel(
  configuration: PersonaConfiguration,
  localeLabel: string,
): PersonaConfiguration {
  return updatePersonaSection(configuration, 'culture', 'locale_label', localeLabel)
}

export function lineListToArray(value: string): string[] {
  return value
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
}

export function arrayToLineList(items: readonly string[]): string {
  return items.join('\n')
}

export function personaDraftsEqual(
  first: PersonaConfiguration | null | undefined,
  second: PersonaConfiguration | null | undefined,
): boolean {
  return deepEqual(first, second)
}

export function isPersonaDraftDirty(
  draft: PersonaConfiguration | null | undefined,
  saved: PersonaConfiguration | null | undefined,
): boolean {
  return !personaDraftsEqual(draft, saved)
}

export function appendListItem<T>(items: readonly T[], item: T, maximum = Number.POSITIVE_INFINITY): T[] {
  if (!Number.isInteger(maximum) || maximum < 0 || items.length >= maximum) return [...items]
  return [...items, cloneValue(item)]
}

export function replaceListItem<T>(items: readonly T[], index: number, item: T): T[] {
  if (!validIndex(items, index)) return [...items]
  return items.map((current, currentIndex) => (currentIndex === index ? cloneValue(item) : current))
}

export function removeListItem<T>(items: readonly T[], index: number, minimum = 0): T[] {
  if (!Number.isInteger(minimum) || minimum < 0 || items.length <= minimum || !validIndex(items, index)) {
    return [...items]
  }
  return items.filter((_, currentIndex) => currentIndex !== index)
}

export function moveListItem<T>(items: readonly T[], fromIndex: number, toIndex: number): T[] {
  if (!validIndex(items, fromIndex) || !validIndex(items, toIndex) || fromIndex === toIndex) return [...items]

  const next = [...items]
  const [moved] = next.splice(fromIndex, 1)
  next.splice(toIndex, 0, moved)
  return next
}

export function appendStringListItem(
  items: readonly string[],
  value: string,
  maximum = Number.POSITIVE_INFINITY,
): string[] {
  const normalized = value.trim()
  if (!normalized) return [...items]
  return appendListItem(items, normalized, maximum)
}

export function createEmptyPersonaPhrase(): PersonaPhrase {
  return {
    text: '',
    meaning: '',
    allowed_contexts: ['general'],
    prohibited_contexts: [],
    frequency: 'rare',
    caution: '',
  }
}

export function createEmptyPersonaGuidance(): PersonaGuidance {
  return { title: '', content: '' }
}

export function createEmptyPersonaScript(): PersonaScript {
  return { title: '', steps: [''] }
}

export function createEmptyPersonaExample(): PersonaExample {
  return { participant: '', assistant: '' }
}

export function getGuidedStepCompleteness(configuration: PersonaConfiguration): Record<PersonaGuidedStep, boolean> {
  const { identity, voice, coaching, culture, phrases, curriculum, response_shape: response } = configuration

  return {
    identity: allNonBlank(Object.values(identity)),
    voice:
      hasOnlyChoices(voice.tone_traits, PERSONA_TONE_TRAITS, 1) &&
      PERSONA_ENERGY_STYLES.includes(voice.energy) &&
      PERSONA_ACCOUNTABILITY_STYLES.includes(voice.accountability_style) &&
      hasOnlyChoices(voice.language_style, PERSONA_LANGUAGE_STYLES, 1),
    coaching:
      isNonBlank(coaching.philosophy) &&
      isNonBlank(coaching.method) &&
      nonBlankList(coaching.principles, 1) &&
      nonBlankList(coaching.do) &&
      nonBlankList(coaching.do_not),
    culture:
      isNonBlank(culture.locale_label) &&
      isNonBlank(culture.context) &&
      nonBlankList(culture.local_realities) &&
      nonBlankList(culture.references),
    phrases: phrases.every(isCompletePhrase),
    curriculum:
      curriculum.guidance.every((item) => allNonBlank([item.title, item.content])) &&
      curriculum.scripts.every((item) => isNonBlank(item.title) && nonBlankList(item.steps, 1)) &&
      curriculum.examples.every((item) => allNonBlank([item.participant, item.assistant])),
    response_shape:
      Number.isInteger(response.min_sentences) &&
      response.min_sentences >= 1 &&
      response.min_sentences <= 10 &&
      Number.isInteger(response.max_sentences) &&
      response.max_sentences >= response.min_sentences &&
      response.max_sentences <= 12 &&
      Number.isInteger(response.max_characters) &&
      response.max_characters >= 200 &&
      response.max_characters <= 4_000,
  }
}

export function isGuidedStepComplete(
  configuration: PersonaConfiguration,
  step: PersonaGuidedStep,
): boolean {
  return getGuidedStepCompleteness(configuration)[step]
}

export function firstIncompleteGuidedStep(configuration: PersonaConfiguration): PersonaGuidedStep | null {
  const completeness = getGuidedStepCompleteness(configuration)
  return PERSONA_GUIDED_STEPS.find((step) => !completeness[step]) ?? null
}

function isCompletePhrase(phrase: PersonaPhrase): boolean {
  return (
    isNonBlank(phrase.text) &&
    isNonBlank(phrase.meaning) &&
    phrase.allowed_contexts.length > 0 &&
    phrase.allowed_contexts.every((context) => PERSONA_PHRASE_CONTEXTS.includes(context)) &&
    phrase.prohibited_contexts.every((context) => PERSONA_PHRASE_CONTEXTS.includes(context)) &&
    PERSONA_PHRASE_FREQUENCIES.includes(phrase.frequency) &&
    typeof phrase.caution === 'string'
  )
}

function isNonBlank(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0
}

function allNonBlank(values: readonly unknown[]): boolean {
  return values.every(isNonBlank)
}

function nonBlankList(values: readonly string[], minimum = 0): boolean {
  return values.length >= minimum && values.every(isNonBlank)
}

function hasOnlyChoices<T extends string>(values: readonly string[], choices: readonly T[], minimum: number): values is T[] {
  return values.length >= minimum && values.every((value) => choices.includes(value as T))
}

function validIndex<T>(items: readonly T[], index: number): boolean {
  return Number.isInteger(index) && index >= 0 && index < items.length
}

function cloneValue<T>(value: T): T {
  if (Array.isArray(value)) return value.map((item) => cloneValue(item)) as T
  if (isRecord(value)) {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, cloneValue(child)])) as T
  }
  return value
}

function deepEqual(first: unknown, second: unknown): boolean {
  if (Object.is(first, second)) return true
  if (Array.isArray(first) || Array.isArray(second)) {
    if (!Array.isArray(first) || !Array.isArray(second) || first.length !== second.length) return false
    return first.every((value, index) => deepEqual(value, second[index]))
  }
  if (!isRecord(first) || !isRecord(second)) return false

  const firstKeys = Object.keys(first)
  const secondKeys = Object.keys(second)
  return (
    firstKeys.length === secondKeys.length &&
    firstKeys.every((key) => Object.hasOwn(second, key) && deepEqual(first[key], second[key]))
  )
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
