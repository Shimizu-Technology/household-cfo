// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { fetchDailyCandidates, fetchDailyPage } from '../api'
import { dailyContext, dailyVersion } from '../test/dailyFixtures'
import { baselineScope } from '../test/baselineFixtures'
import { DailyPurchaseEditor } from './DailyPurchaseEditor'
import { DailyReflectionEditor } from './DailyReflectionEditor'
vi.mock('../api',async original=>({...await original<typeof import('../api')>(),fetchDailyCandidates:vi.fn(),fetchDailyPage:vi.fn()}))
const scope={...baselineScope,enrollment_id:100,cohort_id:55}
const denied=vi.fn()
afterEach(cleanup)
beforeEach(()=>vi.clearAllMocks())
it('does not render or select another enrollment’s canonical candidate',async()=>{
 vi.mocked(fetchDailyCandidates).mockResolvedValue({actor_scope:baselineScope,enrollment_id:101,cohort_id:55,records:[{id:1,merchant:'Wrong program merchant',amount_cents:1250,posted_on:'2026-09-28',purchased_on_candidates:['2026-09-28'],splits:dailyVersion.splits,digest:'synthetic',source_owned:false}],next_cursor:null})
 render(<DailyPurchaseEditor context={{...dailyContext,cohort_id:55}} scope={scope} selectedDate="2026-09-28" mutate={vi.fn()} busy={false} onDone={vi.fn()} onStatements={vi.fn()} onDenied={denied}/>)
 fireEvent.change(screen.getByLabelText('Purchase source'),{target:{value:'existing_transaction'}})
 await waitFor(()=>expect(denied).toHaveBeenCalledOnce());expect(screen.queryByText(/Wrong program merchant/)).toBeNull()
})
it('does not load optional reflection text from another selected cohort',async()=>{
 vi.mocked(fetchDailyPage).mockResolvedValue({actor_scope:baselineScope,enrollment_id:100,cohort_id:56,records:[{id:600,current_version_id:601,lock_version:1,savings_daily_purchase_id:200,current_version:{id:601,version_number:1,previous_version_id:null,approved_at:'2026-09-28T12:00:00Z',reason:null,savings_daily_reflection_id:600,savings_daily_purchase_id:200,feeling_then:'Other program feelings',feeling_now:null,erased_at:null}}],next_cursor:null})
 render(<DailyReflectionEditor purchaseId={200} scope={scope} refresh={0} mutate={vi.fn()} busy={false} onDenied={denied}/>)
 await waitFor(()=>expect(denied).toHaveBeenCalledOnce());expect(screen.queryByDisplayValue('Other program feelings')).toBeNull()
})
