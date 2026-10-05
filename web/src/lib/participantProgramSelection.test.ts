// @vitest-environment jsdom
import { beforeEach, expect, it, vi } from 'vitest'
import { readParticipantProgram, storeParticipantProgram, verifiedParticipantProgram } from './participantProgramSelection'
beforeEach(() => { localStorage.clear(); vi.restoreAllMocks() })
it('restores only the same authenticated actor’s program without storing private data', () => {
  storeParticipantProgram('clerk-a', 1, 42)
  expect(readParticipantProgram('clerk-a', 1)).toBe(42)
  expect(readParticipantProgram('clerk-a', 2)).toBeUndefined()
  expect(readParticipantProgram('clerk-b', 1)).toBeUndefined()
  expect(readParticipantProgram(null, 1)).toBeUndefined()
  expect([...Array(localStorage.length)].map((_, i) => localStorage.getItem(localStorage.key(i)!))).toEqual(['42'])
})
it('removes denied and malformed selections and tolerates unavailable storage', () => {
  storeParticipantProgram('clerk-a', 1, 42)
  storeParticipantProgram('clerk-a', 1, undefined)
  expect(readParticipantProgram('clerk-a', 1)).toBeUndefined()
  localStorage.setItem('household-cfo:participant-program:v1:clerk-a:1', '2.5')
  expect(readParticipantProgram('clerk-a', 1)).toBeUndefined()
  expect(localStorage.length).toBe(0)
  vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('Blocked') })
  vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('Blocked') })
  expect(() => storeParticipantProgram('clerk-a', 1, 42)).not.toThrow()
  expect(readParticipantProgram('clerk-a', 1)).toBeUndefined()
})

it('clears only an explicitly unavailable membership, never an unverified actor or response', () => {
  const programs = { actor_id: 1, current_cohort_id: 42, current_program: { id: 42, name: 'BOG', status: 'active' as const }, selection_unavailable: false, programs: [], next_cursor: null }
  expect(verifiedParticipantProgram(programs, 1, 42)).toBe(true)
  expect(verifiedParticipantProgram({ ...programs, selection_unavailable: true, current_cohort_id: null, current_program: null }, 1, 42)).toBe(false)
  expect(() => verifiedParticipantProgram(programs, 2, 42)).toThrow('different account')
  expect(() => verifiedParticipantProgram(programs, 1, 43)).toThrow('could not be verified')
})
