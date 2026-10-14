export const PARTICIPANT_SECTIONS = ['Home', 'Review', 'Ask Mia', 'My Money', 'Budget', 'My Profile', 'Wealth', 'CFO Filter', 'Optionality']

export const SECTION_CAPABILITY_IDS: Record<string, string> = {
  Home: 'home',
  Review: 'review',
  'Ask Mia': 'ask_mia',
  Budget: 'budget',
  'My Profile': 'profile',
  'My Money': 'profile',
  Statements: 'profile',
  Wealth: 'wealth',
  'CFO Filter': 'cfo_filter',
  Optionality: 'optionality',
}

/** Participant sections a cohort exposes for its enabled capability modules, in navigation order. */
export function participantSectionsForModules(enabledModuleIds: string[]) {
  const enabled = PARTICIPANT_SECTIONS.filter((section) => enabledModuleIds.includes(SECTION_CAPABILITY_IDS[section]))
  return enabled.includes('My Profile') ? [...enabled, 'Statements'] : enabled
}

// The bottom bar holds four destinations plus More. Budget is the core of the
// method, so it stays one tap away; My Money fills in when a program hides Budget.
const PRIMARY_PRIORITY = ['Home', 'Ask Mia', 'Budget', 'Review', 'My Money']
const SAVINGS_PRIMARY_PRIORITY = ['Home', 'Ask Mia', 'Statements']
const PRIMARY_LIMIT = 4

/** Splits participant sections into primary destinations and the More menu. */
export function partitionParticipantSections(sections: string[], savingsChallenge = false) {
  const priority = savingsChallenge ? SAVINGS_PRIMARY_PRIORITY : PRIMARY_PRIORITY
  const primary = priority.filter((section) => sections.includes(section)).slice(0, PRIMARY_LIMIT)
  const secondary = sections.filter((section) => !primary.includes(section))
  return { primary, secondary }
}
