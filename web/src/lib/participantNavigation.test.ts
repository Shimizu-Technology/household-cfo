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
  it('decouples Statements from Profile for schema four', () => {
    expect(participantSectionsForModules(['home', 'ask_mia', 'statements'], { independentStatements: true })).toEqual(['Home', 'Ask Mia', 'Statements'])
    expect(participantSectionsForModules(['home', 'ask_mia', 'profile'], { independentStatements: true })).toEqual(['Home', 'Ask Mia', 'My Money', 'My Profile'])
    expect(participantSectionsForModules(['home', 'ask_mia'], { independentStatements: true })).toEqual(['Home', 'Ask Mia'])
  })

  it('honors custom capability order across primary and secondary destinations', () => {
    const sections = participantSectionsForModules([...allModules, 'statements'], {
      independentStatements: true, moduleOrder: ['statements', 'optionality', 'wealth', 'ask_mia', 'cfo_filter', 'home', 'review', 'budget', 'profile'],
    })
    expect(partitionParticipantSections(sections, false, true)).toEqual({
      primary: ['Statements', 'Optionality', 'Wealth', 'Ask Mia'],
      secondary: ['CFO Filter', 'Home', 'Review', 'Budget', 'My Money', 'My Profile'],
    })
    expect(partitionParticipantSections(sections, true, true).primary).toEqual(['Statements', 'Optionality', 'Wealth', 'Ask Mia'])
    expect(participantSectionsForModules(['home', 'ask_mia', 'budget'], { moduleOrder: ['wealth', 'budget', 'budget'] })).toEqual(['Budget', 'Home', 'Ask Mia'])
  })

})

it('keeps staff sections in More when a custom order enables fewer than four participant tabs', () => {
 expect(partitionParticipantSections(['Ask Mia', 'Home', 'Coach Studio', 'Admin'], false, true)).toEqual({primary:['Ask Mia','Home'],secondary:['Coach Studio','Admin']})
 expect(partitionParticipantSections(['Home','Ask Mia','Statements','Coach Studio'], true, true)).toEqual({primary:['Home','Ask Mia','Statements'],secondary:['Coach Studio']})
})
