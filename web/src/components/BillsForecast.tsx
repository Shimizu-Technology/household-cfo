import { useEffect, useRef, useState, type FormEvent } from 'react'
import { markBillPaid, removeBill, saveBill, type AnnualBudgetPlan, type ForecastMonth, type ScheduledBill } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'
import { billDate, forecastHeadline } from '../lib/yearForecast'

const SINKING = new Set(['sinking_expected', 'sinking_unexpected'])
const NO_CATEGORY = 'none'
const cash = (value: number | null) => value == null ? 'Not known yet' : formatReviewMoney(value)
const repeats = (months: number | null) => months == null ? 'one time' : months === 1 ? 'every month' : months === 12 ? 'every year' : `every ${months} months`

function incomeLabel(month: ForecastMonth) {
  const after = month.from_on ? billDate(month.from_on, false) : ''
  switch (month.income_basis) {
    case 'after_balance': return `Still expected after ${after}`
    case 'estimated_after_balance': return `Estimated after ${after}; pay dates aren’t saved`
    case 'approved_so_far': return 'Approved so far; more may come'
    case 'approved': return 'Approved'
    default: return month.approved_so_far_cents != null ? `Planned · ${formatReviewMoney(month.approved_so_far_cents)} approved so far` : 'Planned'
  }
}

/** Budget's year forecast: every month through December and the bills she saved. Saving refetches the plan in place. */
export function BillsForecast({ plan, canEdit = true, onChanged }: { plan: AnnualBudgetPlan; canEdit?: boolean; onChanged?: () => Promise<void> }) {
  const forecast = plan.year_forecast!
  const categories = plan.rows.filter(row => row.active !== false && row.id > 0)
  const [editing, setEditing] = useState<ScheduledBill | 'new' | null>(null)
  const [removing, setRemoving] = useState<number | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const [draft, setDraft] = useState({ name: '', amount: '', category: '' })
  const confirmRef = useRef<HTMLButtonElement>(null)
  const formRef = useRef<HTMLFormElement>(null)
  const addRef = useRef<HTMLButtonElement>(null)
  useEffect(() => { if (removing != null) confirmRef.current?.focus() }, [removing])
  useEffect(() => { if (editing) formRef.current?.querySelector<HTMLInputElement>('input[name="name"]')?.focus() }, [editing])
  // Back to Add bill once the save finishes; it is disabled while busy, so focusing earlier drops focus to the page.
  const returnFocus = useRef(false)
  useEffect(() => { if (!busy && returnFocus.current) { returnFocus.current = false; addRef.current?.focus() } }, [busy])

  async function refresh(message: string) {
    setNotice(message)
    try { await onChanged?.() } catch { setError(`${message} The forecast could not refresh. Reload to see it.`) }
  }
  function openForm(bill: ScheduledBill | 'new') {
    setEditing(bill); setRemoving(null); setError(''); setNotice('')
    setDraft(bill === 'new' ? { name: '', amount: '', category: '' } : { name: bill.name, amount: String(bill.amount_cents / 100), category: bill.budget_category_id == null ? NO_CATEGORY : String(bill.budget_category_id) })
  }
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const data = new FormData(event.currentTarget)
    const category = String(data.get('category') ?? '')
    if (!category) { setError('Choose the category this bill belongs to, or choose “Not in any category plan”.'); return }
    setBusy(true); setError('')
    try {
      const name = String(data.get('name'))
      await saveBill(editing === 'new' || editing == null ? null : editing.id, { name, amount: String(data.get('amount')), due_on: String(data.get('due_on')), repeat_months: String(data.get('repeat_months') ?? '') || null, budget_category_id: category === NO_CATEGORY ? null : Number(category), must_pay: data.get('must_pay') === 'on', estimate: data.get('estimate') === 'on' })
      setEditing(null)
      returnFocus.current = true
      await refresh(`Saved ${name}.`)
    } catch (err) { setError(err instanceof Error ? err.message : 'Could not save the bill.') } finally { setBusy(false) }
  }
  async function act(bill: ScheduledBill, action: 'remove' | 'paid' | 'unpaid') {
    setBusy(true); setError('')
    try {
      if (action === 'remove') await removeBill(bill.id)
      else await markBillPaid(bill.id, action === 'paid')
      setRemoving(null)
      returnFocus.current = true
      await refresh(action === 'remove' ? `Removed ${bill.name}.` : action === 'paid' ? `Marked ${bill.name} paid. It no longer counts.` : `${bill.name} counts again.`)
    } catch { setError(action === 'remove' ? 'Could not remove this bill.' : 'Could not change this bill.') } finally { setBusy(false) }
  }

  const chosen = categories.find(row => String(row.id) === draft.category)
  const debtMatch = forecast.debt_bills.find(debt => {
    const words = (text: string) => text.toLowerCase().match(/[a-z0-9]+/g)?.filter(word => word.length >= 3 && !['the', 'and', 'for', 'bill', 'bills', 'payment', 'payments', 'monthly', 'pay', 'due', 'my', 'our'].includes(word)) ?? []
    const amount = Math.round(Number(draft.amount) * 100)
    return (debt.amount_cents != null && debt.amount_cents > 0 && amount === debt.amount_cents) || words(debt.name).some(word => words(draft.name).includes(word))
  })
  const form = editing && <form ref={formRef} key={editing === 'new' ? 'new' : editing.id} className="annual-category-form bill-form" onSubmit={submit} aria-label={editing === 'new' ? 'Add a bill' : `Edit ${editing.name}`}>
    <label>Bill name<input name="name" required maxLength={80} value={draft.name} onChange={event => setDraft({ ...draft, name: event.currentTarget.value })} /></label>
    <label>Bill amount<input name="amount" type="number" inputMode="decimal" required min="0" step="0.01" value={draft.amount} onChange={event => setDraft({ ...draft, amount: event.currentTarget.value })} /></label>
    {debtMatch && <p className="bill-warning" role="status">This looks like your {debtMatch.name} payment. Debt payments already count from My Money, so saving it here counts it twice. Leave debt payments in My Money.</p>}
    <label>First due date<input name="due_on" type="date" required defaultValue={editing === 'new' ? '' : editing.due_on} /></label>
    <label>Repeat every how many months? (blank for one time)<input name="repeat_months" type="number" inputMode="numeric" min="1" max="120" defaultValue={editing === 'new' ? '' : editing.repeat_months ?? ''} /></label>
    <label>Category<select name="category" required value={draft.category} onChange={event => setDraft({ ...draft, category: event.currentTarget.value })}>
      <option value="" disabled>Choose a category</option>
      {categories.map(row => <option key={row.id} value={row.id}>{row.name}</option>)}
      <option value={NO_CATEGORY}>Not in any category plan</option>
    </select></label>
    {draft.category === NO_CATEGORY && <p className="bill-hint">This bill isn’t part of any category plan, so it adds to your planned costs when it’s due.</p>}
    {chosen && SINKING.has(chosen.stack_key) && <p className="bill-hint">{chosen.name} is money you set aside for a planned cost. Once this bill is saved, the monthly set-aside stays in your savings and the bill counts when it’s due.</p>}
    {chosen && !SINKING.has(chosen.stack_key) && <p className="bill-hint">Counts inside {chosen.name}: the larger of the plan or this bill, not both.</p>}
    <label className="bill-check"><input type="checkbox" name="must_pay" defaultChecked={editing === 'new' ? true : editing.must_pay} />Must pay</label>
    <label className="bill-check"><input type="checkbox" name="estimate" defaultChecked={editing === 'new' ? false : editing.estimate} />Amount is an estimate</label>
    {error && <p className="form-error" role="alert">{error}</p>}
    <div className="bill-actions"><button className="ui-btn ui-btn--primary" disabled={busy} type="submit">{busy ? 'Saving…' : 'Save bill'}</button><button type="button" className="secondary-button" disabled={busy} onClick={() => { setEditing(null); setError('') }}>Cancel</button></div>
  </form>

  return <div className="bills-forecast">
    <h4>Cash through December</h4>
    <p>{forecast.starting_note}</p>
    <p role="status" className={forecast.first_short_month ? 'forecast-headline is-short' : 'forecast-headline'}>{forecastHeadline(forecast)}{forecast.first_short_month ? ` Costs that month: ${forecast.first_short_month.reasons.join(', ')}.${forecast.first_short_month.includes_estimates ? ' Some amounts are estimates.' : ''}` : ''}{forecast.status === 'unknown' && forecast.missing.length ? ` Still needed: ${forecast.missing.join(', ')}.` : ''}</p>
    <details><summary>How this forecast works</summary><ul className="forecast-rules">
      <li>It starts from your checking and savings balances when they all share one date this month or the last day of last month. Other dates leave ending cash unknown.</li>
      <li>From a balance in the middle of the month, only what comes after that day counts: income still expected, bills due later, and what’s left of each category’s plan.</li>
      <li>Each category counts the larger of its plan or its bills due that month, never both. This month, spending already recorded counts if it’s more.</li>
      <li>Money set aside for planned yearly costs or surprises stays in your savings. Once you save the bill, it counts when it’s due.</li>
      <li>Debt payments count once a month from My Money. A one-time bill you mark paid stops counting.</li>
      <li>It shows each month’s end, not day-to-day dips inside a month.</li>
    </ul></details>
    <table className="forecast-table"><caption className="sr-only">Cash forecast by month</caption>
      <thead><tr><th scope="col">Month</th><th scope="col">Starting cash</th><th scope="col">Money in</th><th scope="col">Planned out</th><th scope="col">Ending cash</th></tr></thead>
      <tbody>{forecast.months.map(month => <tr key={month.starts_on} className={month.ending_cents != null && month.ending_cents < 0 ? 'is-short' : undefined}>
        <th scope="row">{month.label}{month.from_on && <small>From {billDate(month.from_on, false)}</small>}{month.bills.length > 0 && <small>{month.bills.map(bill => bill.was_this_paid ? `${bill.name} (was this paid?)` : bill.name).join(', ')}</small>}{month.higher_costs && <small>Higher costs than usual</small>}</th>
        <td data-label="Starting cash">{cash(month.opening_cents)}</td>
        <td data-label="Money in">{cash(month.income_cents)}<small>{incomeLabel(month)}</small></td>
        <td data-label="Planned out">{cash(month.outflow_cents)}</td>
        <td data-label="Ending cash">{cash(month.ending_cents)}</td>
      </tr>)}</tbody>
    </table>
    <details className="bills-list"><summary>Bills and due dates</summary>
      <p>Debt payments come from My Money; change them there. A bill is saved only when you press Save bill.</p>
      {notice && <p role="status" className="bill-notice">{notice}</p>}
      {forecast.bills.length === 0 && <p>No bills saved yet.</p>}
      <ul>{forecast.bills.map(bill => {
        const category = categories.find(row => row.id === bill.budget_category_id)
        return <li key={bill.id}>
          <strong>{bill.name}: {cash(bill.amount_cents)}{bill.estimate ? ' (estimate)' : ''}</strong>
          <p>{bill.paid_on ? `Paid ${billDate(bill.paid_on)}` : `Due ${billDate(bill.due_on)}`} · {repeats(bill.repeat_months)}{bill.must_pay ? ' · must pay' : ''}</p>
          {!bill.paid_on && <p>{category ? `Counts in ${category.name}` : 'Outside your category plan: adds to planned costs'}</p>}
          {bill.was_this_paid && <p className="bill-warning">Past its date. Was this paid? It still counts until you mark it paid.</p>}
          {bill.looks_like_debt && <p className="bill-warning">This looks like your {bill.looks_like_debt} payment, which already counts from My Money. If it’s the same payment, remove this bill.</p>}
          {canEdit && removing === bill.id ? <div className="bill-confirm" role="group" aria-label={`Remove ${bill.name}?`}>
            <p>Remove {bill.name}? It will stop counting in the forecast.</p>
            <div className="bill-actions"><button ref={confirmRef} type="button" className="ui-btn ui-btn--primary" disabled={busy} onClick={() => void act(bill, 'remove')}>Remove bill</button><button type="button" className="secondary-button" disabled={busy} onClick={() => setRemoving(null)}>Keep bill</button></div>
          </div> : canEdit && <div className="bill-actions">
            {bill.repeat_months == null && !bill.paid_on && <button type="button" className={bill.was_this_paid ? 'ui-btn ui-btn--primary' : 'secondary-button'} disabled={busy} aria-label={bill.was_this_paid ? `Yes, ${bill.name} was paid` : `Mark ${bill.name} paid`} onClick={() => void act(bill, 'paid')}>{bill.was_this_paid ? 'Yes, it was paid' : 'Mark paid'}</button>}
            {bill.paid_on && <button type="button" className="secondary-button" disabled={busy} aria-label={`${bill.name} was not paid after all`} onClick={() => void act(bill, 'unpaid')}>Not paid after all</button>}
            <button type="button" className="secondary-button" disabled={busy} onClick={() => openForm(bill)}>Edit<span className="sr-only"> {bill.name}</span></button>
            <button type="button" className="secondary-button" disabled={busy} onClick={() => { setRemoving(bill.id); setError('') }}>Remove<span className="sr-only"> {bill.name}</span></button>
          </div>}
          {editing !== 'new' && editing?.id === bill.id && form}
        </li>
      })}</ul>
      {forecast.debt_bills.map(debt => <p key={debt.name}>{debt.name}: {cash(debt.amount_cents)} a month · counts from My Money</p>)}
      {error && !editing && <p className="form-error" role="alert">{error}</p>}
      {canEdit && <button ref={addRef} type="button" className="secondary-button bill-add" disabled={busy} onClick={() => openForm('new')}>Add bill</button>}
      {editing === 'new' && form}
    </details>
  </div>
}
