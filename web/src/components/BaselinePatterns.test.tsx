// @vitest-environment jsdom
import { cleanup,fireEvent,render,screen,within } from '@testing-library/react'
import { afterEach,describe,expect,it } from 'vitest'
import { baselineContext,baselinePreview,baselineRequest } from '../test/baselineFixtures'
import { BaselinePatterns } from './BaselinePatterns'
afterEach(cleanup)
describe('full-window baseline observations',()=>{
 it('uses supplied whole-window aggregates rather than the 50-row sample and keeps prior refunds separate',()=>{render(<BaselinePatterns preview={baselinePreview(baselineRequest(),true)} sources={baselineContext.records}/>);const totals=document.querySelector('.baseline-totals') as HTMLElement;expect(within(totals).getByText('$1,370.00')).toBeTruthy();expect(within(totals).getByText('$1,350.00')).toBeTruthy();expect(within(totals).getByText('$1,360.00')).toBeTruthy();expect(screen.getByText(/0 complete calendar months supported/)).toBeTruthy();fireEvent.click(screen.getByText('Merchant observations (37)'));expect(screen.getByText('Fictional merchant 20')).toBeTruthy();expect(screen.queryByText('Fictional merchant 21')).toBeNull();fireEvent.click(screen.getByRole('button',{name:'Next merchants'}));expect(screen.getByText('Fictional merchant 37')).toBeTruthy();expect(screen.queryByText('Fictional merchant 1')).toBeNull();fireEvent.click(screen.getByText('Observation sample (50 of 137)'));expect(screen.getByText(/All totals and patterns use the entire period/)).toBeTruthy()})
})
