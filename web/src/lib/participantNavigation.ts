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
export type ParticipantModuleNavigation = { moduleOrder?: string[]; independentStatements?: boolean; statementsAvailable?: boolean }

export function participantSectionsForModules(enabledModuleIds: string[], { moduleOrder = [], independentStatements = false, statementsAvailable }: ParticipantModuleNavigation = {}) {
  const enabled = PARTICIPANT_SECTIONS.filter((section) => enabledModuleIds.includes(SECTION_CAPABILITY_IDS[section]))
  if (statementsAvailable !== false && (enabledModuleIds.includes('statements') || (!independentStatements && enabledModuleIds.includes('profile')))) enabled.push('Statements')
  if (!moduleOrder.length) return enabled

  // Unspecified modules retain their historical relative order after the chosen ones.
  const orderedIds = [...new Set([...moduleOrder, ...enabled.map(section => SECTION_CAPABILITY_IDS[section])])]
  return orderedIds.flatMap(id => enabled.filter(section => SECTION_CAPABILITY_IDS[section] === id))
}

// The bottom bar holds four destinations plus More. Budget is the core of the
// method, so it stays one tap away; My Money fills in when a program hides Budget.
const PRIMARY_PRIORITY = ['Home', 'Ask Mia', 'Budget', 'Review', 'My Money']
const SAVINGS_SECTIONS = ['Home', 'Ask Mia', 'Statements', 'My Profile']
const STAFF_SECTIONS = ['Coach Studio', 'Admin']
const SAVINGS_PRIMARY_PRIORITY = ['Home', 'Ask Mia', 'Statements']
const PRIMARY_LIMIT = 4

/** Splits participant sections into primary destinations and the More menu. */
export function partitionParticipantSections(sections: string[], savingsChallenge = false, customOrder = false) {
  // The savings challenge shows only what it needs by default. A coach's explicit
  // module order is a deliberate choice and wins; staff areas always stay reachable.
  const visible = savingsChallenge && !customOrder
    ? sections.filter(section => SAVINGS_SECTIONS.includes(section) || STAFF_SECTIONS.includes(section))
    : sections
  const priority = savingsChallenge ? SAVINGS_PRIMARY_PRIORITY : PRIMARY_PRIORITY
  const primary = customOrder
    ? visible.filter((section) => !STAFF_SECTIONS.includes(section)).slice(0, PRIMARY_LIMIT)
    : priority.filter((section) => visible.includes(section)).slice(0, PRIMARY_LIMIT)
  const secondary = visible.filter((section) => !primary.includes(section))
  return { primary, secondary }
}

/** Shared displayed labels for participant navigation and the coach's review. */
export function participantSectionLabel(section: string, savingsChallenge = false, assistantName = 'Mia', compact = false) {
  if (savingsChallenge && section === 'Home') return 'Savings'
  if (section === 'Ask Mia') {
    const trimmed = assistantName.trim()
    return compact ? trimmed.length <= 10 ? trimmed : trimmed.split(/\s+/)[0] || trimmed : `Ask ${assistantName}`
  }
  if (compact && section === 'My Profile') return 'Profile'
  if (compact && section === 'My Money') return 'Money'
  return section
}
