import type { MiaAnswerPresentation } from '../api'

const PRESENTATION_BASES = new Set<MiaAnswerPresentation['basis']>([
  'saved_household',
  'saved_household_plus_scenario',
  'scenario_only',
])
const SECTION_ID_PATTERN = /^[a-z0-9][a-z0-9_-]{0,63}$/i
const MAX_SECTIONS = 6
const MAX_SCENARIO_VALUES = 10
const MAX_LEAD_LENGTH = 2_000
const MAX_TITLE_LENGTH = 120
const MAX_BODY_LENGTH = 2_000
const MAX_VALUE_LENGTH = 160

export function parseMiaAnswerPresentation(value: unknown): MiaAnswerPresentation | null {
  if (!isRecord(value) || value.version !== 1 || value.kind !== 'read_only_answer') return null
  if (typeof value.basis !== 'string' || !PRESENTATION_BASES.has(value.basis as MiaAnswerPresentation['basis'])) return null

  const lead = boundedText(value.lead, MAX_LEAD_LENGTH)
  if (!lead || !Array.isArray(value.sections) || value.sections.length === 0 || value.sections.length > MAX_SECTIONS) return null

  const sectionIds = new Set<string>()
  const sections: MiaAnswerPresentation['sections'] = []
  for (const candidate of value.sections) {
    if (!isRecord(candidate)) return null
    const id = boundedText(candidate.id, 64)
    const title = boundedText(candidate.title, MAX_TITLE_LENGTH)
    const body = boundedText(candidate.body, MAX_BODY_LENGTH)
    if (!id || !SECTION_ID_PATTERN.test(id) || sectionIds.has(id) || !title || !body) return null
    sectionIds.add(id)
    sections.push({ id, title, body })
  }

  const scenario = parseScenario(value.scenario)
  const requiresScenario = value.basis === 'saved_household_plus_scenario' || value.basis === 'scenario_only'
  if ((requiresScenario && !scenario) || (!requiresScenario && value.scenario !== undefined)) return null

  return {
    version: 1,
    kind: 'read_only_answer',
    basis: value.basis as MiaAnswerPresentation['basis'],
    lead,
    sections,
    ...(scenario ? { scenario } : {}),
  }
}

function parseScenario(value: unknown): MiaAnswerPresentation['scenario'] | null {
  if (value === undefined) return null
  if (!isRecord(value) || !Array.isArray(value.values) || value.values.length === 0 || value.values.length > MAX_SCENARIO_VALUES) return null

  const values: NonNullable<MiaAnswerPresentation['scenario']>['values'] = []
  for (const candidate of value.values) {
    if (!isRecord(candidate)) return null
    const label = boundedText(candidate.label, MAX_VALUE_LENGTH)
    const displayValue = boundedText(candidate.display_value, MAX_VALUE_LENGTH)
    if (!label || !displayValue) return null
    values.push({ label, display_value: displayValue })
  }
  return { values }
}

function boundedText(value: unknown, maximum: number) {
  if (typeof value !== 'string') return null
  const normalized = value.trim()
  return normalized.length > 0 && normalized.length <= maximum ? normalized : null
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
