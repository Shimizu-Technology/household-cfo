import { describe, expect, it } from 'vitest'
import { parseInviteEmails } from './inviteEmails'

describe('parseInviteEmails', () => {
  it('reads commas, spaces and lines, lowercases and keeps each address once', () => {
    const { emails, problems } = parseInviteEmails('Ana@Example.com, bo@example.com\nana@example.com  cy@example.com')
    expect(emails).toEqual(['ana@example.com', 'bo@example.com', 'cy@example.com'])
    expect(problems).toEqual(['ana@example.com is listed twice. It will be invited once.'])
  })
  it('reads "Name <address>" and says which entries are not email addresses', () => {
    const { emails, problems } = parseInviteEmails('Dee Lee <dee@example.com>; not-an-email')
    expect(emails).toEqual(['dee@example.com'])
    expect(problems).toEqual(['“not-an-email” isn’t a complete email address.'])
  })
  it('keeps a bare address typed before a named one', () => {
    const { emails, problems } = parseInviteEmails('ana@example.com Bo <bo@example.com>')
    expect(emails).toEqual(['ana@example.com', 'bo@example.com'])
    expect(problems).toEqual([])
    expect(parseInviteEmails('Cy Lee <cy@example.com> dee@example.com, ed@example.com Fay <fay@example.com>').emails).toEqual(['cy@example.com', 'dee@example.com', 'ed@example.com', 'fay@example.com'])
  })
  it('returns nothing for an empty box', () => {
    expect(parseInviteEmails('  \n ')).toEqual({ emails: [], problems: [] })
  })
})
