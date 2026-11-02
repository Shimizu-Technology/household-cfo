import {expect,it} from 'vitest'
import {formatRunway} from './runway'
it('rounds normal cushions and caps very large balances in plain words',()=>{
 expect(formatRunway(2.56)).toBe('2.6 months of breathing room')
 expect(formatRunway(1)).toBe('1 month of breathing room')
 expect(formatRunway(60)).toBe('60 months of breathing room')
 expect(formatRunway(60.01)).toBe('More than 5 years of breathing room')
 expect(formatRunway(2472.6)).toBe('More than 5 years of breathing room')
 expect(formatRunway(0)).toBe('0 months of breathing room')
})
