export const PARTICIPANT_TOOL_SECTIONS = ['Wealth', 'CFO Filter', 'Optionality']

export const PARTICIPANT_SECTIONS = ['Home', 'Review', 'Ask Mia', 'My Money', 'Budget', 'My Profile', 'Wealth', 'CFO Filter', 'Optionality']

export const SECTION_CAPABILITY_IDS: Record<string, string> = {
  Home: 'home',
  Review: 'review',
  'Ask Mia': 'ask_mia',
  Budget: 'budget',
  'My Profile': 'profile',
  'My Money': 'profile',
  Statements: 'statements',
  Wealth: 'wealth',
  'CFO Filter': 'cfo_filter',
  Optionality: 'optionality',
}

/** Participant sections a cohort exposes for its enabled capability modules, in navigation order. */
export type ParticipantModuleNavigation = { moduleOrder?: string[]; independentStatements?: boolean }

export function participantSectionsForModules(enabledModuleIds: string[], { moduleOrder = [], independentStatements = false }: ParticipantModuleNavigation = {}) {
  const enabled = PARTICIPANT_SECTIONS.filter((section) => enabledModuleIds.includes(SECTION_CAPABILITY_IDS[section]))
  if (enabledModuleIds.includes('statements') || (!independentStatements && enabledModuleIds.includes('profile'))) enabled.push('Statements')
  if (!moduleOrder.length) return enabled

  // Unspecified modules retain their historical relative order after the chosen ones.
  const orderedIds = [...new Set([...moduleOrder, ...enabled.map(section => SECTION_CAPABILITY_IDS[section])])]
  return orderedIds.flatMap(id => enabled.filter(section => SECTION_CAPABILITY_IDS[section] === id))
}

// The bottom bar holds four destinations plus More. Budget is the core of the
// method, so it stays one tap away; My Money fills in when a program hides Budget.
const PRIMARY_PRIORITY = ['Home', 'Ask Mia', 'Budget', 'Review', 'My Money']
const SAVINGS_PRIMARY_PRIORITY = ['Home', 'Ask Mia', 'Statements']
const PRIMARY_LIMIT = 4

/** Splits participant sections into primary destinations and the More menu. */
export function partitionParticipantSections(sections: string[], savingsChallenge = false, customOrder = false) {
  const priority = savingsChallenge ? SAVINGS_PRIMARY_PRIORITY : PRIMARY_PRIORITY
  const primary = customOrder ? sections.slice(0, PRIMARY_LIMIT) : priority.filter((section) => sections.includes(section)).slice(0, PRIMARY_LIMIT)
  const secondary = sections.filter((section) => !primary.includes(section))
  return { primary, secondary }
}
