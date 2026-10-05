import { describe, expect, it } from 'vitest'
import { dailyContextMatches, dailyResponseMatches, dailyScopeMatches } from './dailyChallenge'
import { dailyContext } from '../test/dailyFixtures'
import { baselineScope } from '../test/baselineFixtures'
const scope={...baselineScope,enrollment_id:100,cohort_id:55}
const envelope={actor_scope:baselineScope,enrollment_id:100,cohort_id:55}
describe('daily identity boundaries',()=>{
 it('requires exact program metadata for selected callers and preserves cohortless fixtures',()=>{
  expect(dailyResponseMatches(envelope,scope)).toBe(true)
  expect(dailyResponseMatches({actor_scope:baselineScope},scope)).toBe(false)
  expect(dailyResponseMatches({actor_scope:baselineScope},{...baselineScope,enrollment_id:100})).toBe(true)
  expect(dailyResponseMatches({...envelope,enrollment_id:101},{...baselineScope,enrollment_id:100})).toBe(false)
 })
 it.each([{enrollment_id:101},{enrollment_id:null},{cohort_id:56},{cohort_id:null},{actor_scope:{...baselineScope,user_id:999}}])('rejects a different or unresolved identity %j',changes=>{
  expect(dailyResponseMatches({...envelope,...changes},scope)).toBe(false)
 })
 it('requires a positive safe enrollment and validates any pinned head',()=>{
  expect(dailyContextMatches({...dailyContext,cohort_id:55},baselineScope,55,100)).toBe(true)
  expect(dailyContextMatches({...dailyContext,cohort_id:55,enrollment_id:101},baselineScope,55,100)).toBe(false)
  expect(dailyContextMatches({...dailyContext,enrollment_id:0},baselineScope)).toBe(false)
  expect(dailyContextMatches({...dailyContext,enrollment_id:1.5},baselineScope)).toBe(false)
 })
 it('separates recovery actors even when only the selected program changes',()=>{
  expect(dailyScopeMatches(scope,{...scope,cohort_id:56})).toBe(false)
 })
})
