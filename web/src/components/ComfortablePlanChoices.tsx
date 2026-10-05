import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, fetchFinancialBaseline } from '../api'
import { baselineLimit, sameBaselineScope, type BaselineCurrent, type BaselineScope } from '../lib/financialBaseline'
import { savingsDollars, savingsInputCents, savingsInputDollars, type SavingsPlanContext, type SavingsPlanContextInput, type SavingsSpendingChange } from '../lib/savingsChallenge'
export type ComfortablePlanState = { input?: SavingsPlanContextInput; edited: boolean; reviewed: boolean; error?: string }
type Choice = { category: string; description: string; recurrence: SavingsSpendingChange['recurrence']; amount: string; name?: string | null }
const recurrenceLabels = { unknown: 'Not sure yet', recurring: 'Recurring', one_off: 'One-time', seasonal: 'Seasonal', annual: 'Annual' }
export function ComfortablePlanSummary({ plan }: { plan: SavingsPlanContext }) {
  if (!Array.isArray(plan.spending_changes)) return <p className="savings-caption">Spending-choice details are unavailable for this plan. No empty-plan or baseline-completeness assumption is made.</p>
  return <div className="comfortable-summary">
    {plan.financial_baseline_version_id ? <p>Linked approved baseline: {plan.baseline_context ? `${plan.baseline_context.window_start_on} – ${plan.baseline_context.window_end_on} · ${plan.baseline_context.coverage_status} coverage` : 'frozen coverage details unavailable'}. This does not establish current complete history.</p> : <p>No baseline linked. Descriptive choices can stand on their own.</p>}
    {plan.spending_changes.length ? <ul>{plan.spending_changes.map((choice, index) => <li key={index}><strong>{choice.category_name || (choice.budget_category_id ? 'Previously reviewed category — label unavailable' : 'Personal spending choice')}</strong><p>{choice.description}</p><p>{recurrenceLabels[choice.recurrence]} · {choice.planned_reduction_cents === null ? 'Reduction not estimated' : `${savingsDollars(choice.planned_reduction_cents)} estimated reduction over the full 90-day challenge`}</p></li>)}</ul> : <p>No spending changes were included in this reviewed plan.</p>}
    <p className="savings-caption">These are comfortable spending experiments, not money saved. Only separately approved contributions and withdrawals affect reported savings.</p>
  </div>
}
export function ComfortablePlanChoices({ acceptedPlan, scope, disabled, freshness, onChange, onDenied, onBaseline }: { acceptedPlan?: SavingsPlanContext | null; scope?: BaselineScope; disabled: boolean; freshness: number; onChange: (state: ComfortablePlanState) => void; onDenied: () => void; onBaseline?: () => void }) {
  const [editing, setEditing] = useState(false)
  const [choices, setChoices] = useState<Choice[]>([])
  const [baseline, setBaseline] = useState<BaselineCurrent | null>(null)
  const [linked, setLinked] = useState<{id:number;digest:string}|null>(null)
  const [reviewed, setReviewed] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string|null>(null)
  const alive = useRef(true); const request = useRef<AbortController|null>(null)
  const identity = `${scope?.user_id}:${scope?.household_id}`
  useEffect(() => { alive.current = true; return () => { alive.current = false; request.current?.abort() } }, [identity])
  useEffect(() => { if(editing) queueMicrotask(() => setReviewed(false)) }, [freshness, editing])
  useEffect(() => {
    if(!editing) { onChange({edited:false,reviewed:false}); return }
    let input: SavingsPlanContextInput | undefined; let invalid: string | undefined
    try {
      const rows = choices.map(choice => {
        if(!choice.description.trim()) throw new Error('Describe each comfortable change, or remove its row.')
        const amount = choice.amount.trim() ? savingsInputCents(choice.amount) : null
        if(amount!==null&&amount>2147483647)throw new Error('Use an estimate within the supported exact-cent limit.')
        return {budget_category_id:choice.category?Number(choice.category):null,description:choice.description.trim(),recurrence:choice.recurrence,planned_reduction_cents:amount}
      })
      if(new Set(rows.map(row=>`${row.budget_category_id}:${row.description.toLowerCase()}`)).size!==rows.length)throw new Error('Each spending change must be distinct.')
      input={financial_baseline_version_id:linked?.id??null,baseline_digest:linked?.digest??null,spending_changes:rows}
    }catch(failure){invalid=failure instanceof Error?failure.message:'Check the spending choices.'}
    onChange({input,edited:true,reviewed,error:invalid})
  }, [choices,linked,reviewed,editing,onChange])
  function edit() {
    setEditing(true); setReviewed(false)
    setChoices((acceptedPlan?.spending_changes??[]).map(row=>({category:row.budget_category_id===null?'':String(row.budget_category_id),name:row.category_name,description:row.description,recurrence:row.recurrence,amount:row.planned_reduction_cents===null?'':savingsInputDollars(row.planned_reduction_cents)})))
    setLinked(acceptedPlan?.financial_baseline_version_id&&acceptedPlan.baseline_digest?{id:acceptedPlan.financial_baseline_version_id,digest:acceptedPlan.baseline_digest}:null)
  }
  async function load() {
    if(!scope)return
    request.current?.abort(); const controller=new AbortController();request.current=controller
    setLoading(true);setError(null);setReviewed(false)
    try {
      const current=await fetchFinancialBaseline(controller.signal)
      if(controller.signal.aborted||!alive.current)return
      if(!sameBaselineScope(current.actor_scope,scope))throw new ApiRequestError('Private workspace changed.',{status:403})
      setBaseline(current)
      if(linked&&(current.needs_revision||current.approved_version?.id!==linked.id||current.approved_version.digest!==linked.digest))setError('The linked baseline changed or needs revision. Review the current baseline or remove its link before preparing the plan.')
    }catch(failure){if(controller.signal.aborted||!alive.current)return;setBaseline(null);setError(failure instanceof Error?failure.message:'Approved baseline unavailable.');if(failure instanceof ApiRequestError&&[401,403,404].includes(failure.status))onDenied()}
    finally{if(!controller.signal.aborted&&alive.current)setLoading(false)}
  }
  const current=baseline?.approved_version
  const eligible=current?.preview.category_eligibility.filter(row=>row.active&&row.eligible===true&&row.budget_category_id!==null)??[]
  const staleLink=Boolean(linked&&baseline&&(baseline.needs_revision||current?.id!==linked.id||current.digest!==linked.digest))
  function update(index:number,value:Partial<Choice>){setReviewed(false);setChoices(choices.map((row,position)=>position===index?{...row,...value}:row))}
  return <details className="comfortable-plan"><summary>Optional comfortable spending choices</summary><p>Choose up to five changes you can live with. Estimates cover the full 90-day challenge; they never add to reported savings.</p>
    {!editing ? <button type="button" disabled={disabled} onClick={edit}>Edit optional spending choices</button> : <fieldset disabled={disabled||loading}>
      <legend>Proposed spending choices</legend>
      <details><summary>Use an approved spending baseline (optional)</summary><p>A partial or manual baseline can provide limited context. It does not prove complete history, recurrence or future savings.</p>
        <button type="button" disabled={!scope} onClick={()=>void load()}>Check approved baseline</button>{!scope&&<p>Private baseline context is unavailable in this session. Descriptive changes remain optional.</p>}
        {loading&&<p role="status">Checking current approved baseline…</p>}
        {baseline&&(current?<><p>{current.window_start_on} – {current.window_end_on} · {current.coverage_status} coverage · {current.preview.observed_spending_known?'Observed spending context':'Spending unknown'}.</p>{current.preview.deficiencies.length>0&&<ul>{current.preview.deficiencies.map((code,index)=><li key={index}>{baselineLimit(code)}</li>)}</ul>}{baseline.needs_revision&&<p role="status">This baseline needs revision and cannot be connected to a new plan.</p>}
          <label className="savings-check"><input type="checkbox" checked={linked?.id===current.id&&linked.digest===current.digest} disabled={Boolean(baseline.needs_revision)} onChange={event=>{setReviewed(false);setLinked(event.target.checked?{id:current.id,digest:current.digest}:null);setChoices(choices.map(row=>({...row,category:'',name:null})))}}/>Include this exact approved baseline with its stated coverage limits.</label></>:<p>No approved baseline. You can continue with descriptive choices.</p>)}
        {linked&&<><p>A reviewed baseline is linked. Category choices use only participant-approved eligible categories; frequency or merchant names do not establish eligibility.</p><button type="button" onClick={()=>{setLinked(null);setError(null);setReviewed(false);setChoices(choices.map(row=>({...row,category:'',name:null})))}}>Remove baseline link</button></>}{onBaseline&&<button type="button" onClick={onBaseline}>Open baseline review</button>}
      </details>
      {choices.map((choice,index)=><fieldset className="comfortable-choice" key={index}><legend>Change {index+1}</legend><label>Comfortable change {index+1}<textarea maxLength={500} value={choice.description} onChange={event=>update(index,{description:event.target.value})}/></label><label>Category for change {index+1}<select value={choice.category} onChange={event=>update(index,{category:event.target.value})}><option value="">Descriptive choice — no category</option>{choice.category&&!eligible.some(row=>String(row.budget_category_id)===choice.category)&&<option value={choice.category}>{choice.name||'Previously reviewed category — check baseline'}</option>}{linked&&!baseline?.needs_revision&&eligible.map(row=><option key={row.budget_category_id} value={row.budget_category_id!}>{row.name}</option>)}</select></label><label>Timing for change {index+1}<select value={choice.recurrence} onChange={event=>update(index,{recurrence:event.target.value as Choice['recurrence']})}>{Object.entries(recurrenceLabels).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label><label>Estimated reduction for change {index+1} over 90 days (USD, optional)<input inputMode="decimal" value={choice.amount} onChange={event=>update(index,{amount:event.target.value})}/></label><button type="button" onClick={()=>{setReviewed(false);setChoices(choices.filter((_,position)=>position!==index))}}>Remove change {index+1}</button></fieldset>)}
      <button type="button" disabled={choices.length>=5} onClick={()=>{setReviewed(false);setChoices([...choices,{category:'',description:'',recurrence:'unknown',amount:''}])}}>Add comfortable change</button>
      {staleLink&&<p role="alert">The selected baseline is stale. Remove the link or re-review it before continuing.</p>}{error&&<p role="alert">{error}</p>}
      <label className="savings-check"><input type="checkbox" checked={reviewed} disabled={staleLink} onChange={event=>setReviewed(event.target.checked)}/>I reviewed these exact optional choices, recurrence assumptions, estimates and baseline limits.</label>
      <button type="button" onClick={()=>{setEditing(false);setBaseline(null);setError(null)}}>Keep accepted choices unchanged</button>
    </fieldset>}
  </details>
}
