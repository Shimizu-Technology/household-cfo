import { describe, expect, it } from 'vitest'
import { partitionParticipantSections, participantSectionsForModules } from './participantNavigation'

const allModules = ['home', 'review', 'ask_mia', 'budget', 'profile', 'wealth', 'cfo_filter', 'optionality']

describe('participant navigation', () => {
  it('exposes profile tools, including Statements, only when the profile module is enabled', () => {
    expect(participantSectionsForModules(allModules)).toEqual(['Home', 'Review', 'Ask Mia', 'My Money', 'Budget', 'My Profile', 'Wealth', 'CFO Filter', 'Optionality', 'Statements'])
    expect(participantSectionsForModules(['home', 'ask_mia', 'review'])).toEqual(['Home', 'Review', 'Ask Mia'])
  })

  it('keeps Home, Mia, Budget, and Review primary and everything else in More', () => {
    expect(partitionParticipantSections(participantSectionsForModules(allModules))).toEqual({
      primary: ['Home', 'Ask Mia', 'Budget', 'Review'],
      secondary: ['My Money', 'My Profile', 'Wealth', 'CFO Filter', 'Optionality', 'Statements'],
    })
  })

  it('promotes My Money when Budget is hidden and needs no More menu for a small program', () => {
    expect(partitionParticipantSections(participantSectionsForModules(['home', 'ask_mia', 'review', 'profile'])).primary).toEqual(['Home', 'Ask Mia', 'Review', 'My Money'])
    expect(partitionParticipantSections(['Home', 'Ask Mia', 'Review'])).toEqual({ primary: ['Home', 'Ask Mia', 'Review'], secondary: [] })
  })

  it('uses the savings challenge destinations for challenge programs', () => {
    expect(partitionParticipantSections(participantSectionsForModules(allModules), true).primary).toEqual(['Home', 'Ask Mia', 'Statements'])
  })
})
