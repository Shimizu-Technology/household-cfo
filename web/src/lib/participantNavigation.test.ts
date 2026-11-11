import { participantSectionLabel } from './participantNavigation'
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
    expect(partitionParticipantSections(participantSectionsForModules(allModules), true)).toEqual({ primary: ['Home', 'Ask Mia', 'Statements'], secondary: ['My Profile'] })
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

it('uses up to four tabs for a coach\u2019s custom order and keeps the rest in More', () => {
 expect(partitionParticipantSections(['Ask Mia', 'Home', 'Budget', 'Review', 'Wealth'], false, true)).toEqual({primary:['Ask Mia','Home','Budget','Review'],secondary:['Wealth']})
 expect(partitionParticipantSections(['Home','Ask Mia','Statements','Wealth'], true, true)).toEqual({primary:['Home','Ask Mia','Statements','Wealth'],secondary:[]})
})

it('hides Statements on an old profile-based experience when the review contract denies it', () => {
  expect(participantSectionsForModules(['home', 'profile'], { statementsAvailable: false })).not.toContain('Statements')
  expect(participantSectionsForModules(['home', 'profile'], { statementsAvailable: true })).toContain('Statements')
})

it('uses the same compact assistant name in participant navigation and the coach review', () => {
  expect(participantSectionLabel('Ask Mia', true, 'Mia Rose', true)).toBe('Mia Rose')
  expect(participantSectionLabel('Ask Mia', true, 'Mia for Mrs. Mel', true)).toBe('Mia')
  expect(participantSectionLabel('Ask Mia', false, 'Mia Rose')).toBe('Ask Mia Rose')
})
