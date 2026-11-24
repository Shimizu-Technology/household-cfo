import { useEffect, useRef, useState, type FormEvent } from 'react'
import { ApiRequestError, markBillPaid, newBillRequestKey, removeBill, saveBill, type AnnualBudgetPlan, type ForecastMonth, type ScheduledBill } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'
import { billDate, forecastEstimates, forecastHeadline } from '../lib/yearForecast'
import { ordinalDay } from '../lib/debtArrears'

const SINKING = new Set(['sinking_expected', 'sinking_unexpected'])
const NO_CATEGORY = 'none'
const cash = (value: number | null) => value == null ? 'Not known yet' : formatReviewMoney(value)
const repeats = (months: number | null) => months == null ? 'one time' : months === 1 ? 'every month' : months === 12 ? 'every year' : `every ${months} months`
const EMPTY_DRAFT = { name: '', amount: '', category: '', due_on: '', repeat_months: '', must_pay: true, estimate: false, past_due: '' }

/** What a month counts besides the plan: its bills, what is past due (owed now, once) and dated debt payments. */
function monthItems(month: ForecastMonth) {
  const bills = month.bills.map(bill => bill.past_due ? `${bill.name} (past due)` : bill.was_this_paid ? `${bill.name} (was this paid?)` : bill.name)
  const debts = (month.debts ?? []).map(debt => debt.past_due ? `${debt.name} (past due)` : debt.due_on ? `${debt.name} on the ${ordinalDay(Number(debt.due_on.slice(8, 10)))}` : null)
  return [...bills, ...debts].filter((item): item is string => item != null)
}

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

const SWITCH_REMINDER = 'You have unsaved bill changes. Save or cancel them before opening another bill.'
const ALREADY_SAVED = 'An earlier Save already added this bill. Press Save bill again to update it with these changes.'

/** Budget's year forecast: every month through December and the bills she saved. Saving refetches the plan in place.
 * onPendingChange tells the parent's navigation and unload guards about a changed bill form or a save in progress.
 * stale: a bill change was saved but the forecast didn't refresh, so its totals and bills aren't shown as current. */
export function BillsForecast({ plan, canEdit = true, stale = false, onChanged, onPendingChange }: { plan: AnnualBudgetPlan; canEdit?: boolean; stale?: boolean; onChanged?: () => Promise<void>; onPendingChange?: (pending: boolean) => void }) {
  const forecast = plan.year_forecast!
  const categories = plan.rows.filter(row => row.active !== false && row.id > 0)
  const [editing, setEditing] = useState<ScheduledBill | 'new' | null>(null)
  const [removing, setRemoving] = useState<number | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const [draft, setDraft] = useState(EMPTY_DRAFT)
  const [dirty, setDirty] = useState(false)
  const [reminder, setReminder] = useState('')
  const [reloadError, setReloadError] = useState('')
  const requestKey = useRef<string | null>(null)
  // A retried Add whose first Save already landed: the next Save updates that bill instead of dropping the edits.
  const savedId = useRef<number | null>(null)
  const pending = busy || (editing != null && dirty)
  useEffect(() => { onPendingChange?.(pending) }, [pending, onPendingChange])
  useEffect(() => () => onPendingChange?.(false), [onPendingChange])
  const confirmRef = useRef<HTMLButtonElement>(null)
  const formRef = useRef<HTMLFormElement>(null)
  const addRef = useRef<HTMLButtonElement>(null)
  useEffect(() => { if (removing != null) confirmRef.current?.focus() }, [removing])
  useEffect(() => { if (editing) formRef.current?.querySelector<HTMLInputElement>('input[name="name"]')?.focus() }, [editing])
  // Back to Add bill once the save finishes; it is disabled while busy, so focusing earlier drops focus to the page.
  const returnFocus = useRef(false)
  useEffect(() => { if (!busy && returnFocus.current) { returnFocus.current = false; addRef.current?.focus() } }, [busy])
  // A bill removed while open (here or elsewhere) must not leave a form, or navigation, held on it.
  const editingId = editing != null && editing !== 'new' ? editing.id : null
  useEffect(() => { if (editingId != null && !stale && !forecast.bills.some(bill => bill.id === editingId)) closeForm() }, [editingId, stale, forecast.bills])

  function closeForm() {
    setEditing(null); setDirty(false); setReminder(''); requestKey.current = null; savedId.current = null
  }

  async function refresh(message: string) {
    setNotice(message)
    try { await onChanged?.() } catch { setError(`${message} The forecast could not refresh. Reload to see it.`) }
  }
  function openForm(bill: ScheduledBill | 'new') {
    if (editing != null && dirty) { setReminder(SWITCH_REMINDER); return }
    setEditing(bill); setRemoving(null); setError(''); setNotice(''); setDirty(false); setReminder('')
    requestKey.current = bill === 'new' ? newBillRequestKey() : null
    savedId.current = null
    setDraft(bill === 'new'
      ? EMPTY_DRAFT
      : { name: bill.name, amount: String(bill.amount_cents / 100), category: bill.budget_category_id == null ? NO_CATEGORY : String(bill.budget_category_id), due_on: bill.due_on, repeat_months: bill.repeat_months == null ? '' : String(bill.repeat_months), must_pay: bill.must_pay, estimate: bill.estimate, past_due: bill.past_due_cents == null ? '' : String(bill.past_due_cents / 100) })
  }
  // Sent only when she typed one on a new bill or changed it on a saved one, so an edit never clears it by accident.
  function pastDueChange(): { past_due?: string } {
    const typed = draft.past_due.trim()
    const saved = editing && editing !== 'new' && editing.past_due_cents != null ? editing.past_due_cents : null
    if (editing === 'new' || editing == null) return typed === '' ? {} : { past_due: typed }
    return (typed === '' ? null : Math.round(Number(typed) * 100)) === saved ? {} : { past_due: typed }
  }
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const category = draft.category
    if (!category) { setError('Choose the category this bill belongs to, or choose “Not in any category plan”.'); return }
    setBusy(true); setError(''); setReminder('')
    try {
      const name = draft.name
      await saveBill(savedId.current ?? (editing === 'new' || editing == null ? null : editing.id), { name, amount: draft.amount, due_on: draft.due_on, repeat_months: draft.repeat_months || null, budget_category_id: category === NO_CATEGORY ? null : Number(category), must_pay: draft.must_pay, estimate: draft.estimate, ...pastDueChange() }, requestKey.current ?? undefined)
      closeForm()
      returnFocus.current = true
      await refresh(`Saved ${name}.`)
    } catch (err) {
      const saved = err instanceof ApiRequestError && err.status === 409 ? Number(err.payload.bill_id) : NaN
      if (editing === 'new' && Number.isSafeInteger(saved) && saved > 0) {
        savedId.current = saved
        setError(ALREADY_SAVED)
        void onChanged?.().catch(() => undefined)
      } else setError(err instanceof Error ? err.message : 'Could not save the bill.')
    } finally { setBusy(false) }
  }
  async function act(bill: ScheduledBill, action: 'remove' | 'paid' | 'unpaid') {
    setBusy(true); setError('')
    try {
      if (action === 'remove') await removeBill(bill.id)
      else await markBillPaid(bill.id, action === 'paid')
      setRemoving(null)
      if (action === 'remove' && editingId === bill.id) closeForm()
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
  const form = editing && <form ref={formRef} key={editing === 'new' ? 'new' : editing.id} className="annual-category-form bill-form" onSubmit={submit} onChange={() => setDirty(true)} aria-label={editing === 'new' ? 'Add a bill' : `Edit ${editing.name}`}>
    <label>Bill name<input name="name" required maxLength={80} disabled={busy} value={draft.name} onChange={event => setDraft({ ...draft, name: event.currentTarget.value })} /></label>
    <label>Bill amount<input name="amount" type="number" inputMode="decimal" required min="0" step="0.01" disabled={busy} value={draft.amount} onChange={event => setDraft({ ...draft, amount: event.currentTarget.value })} /></label>
    {debtMatch && <p className="bill-warning" role="status">This looks like your {debtMatch.name} payment. Debt payments already count from My Money, so saving it here counts it twice. Leave debt payments in My Money.</p>}
    <label>First due date<input name="due_on" type="date" required disabled={busy} value={draft.due_on} onChange={event => setDraft({ ...draft, due_on: event.currentTarget.value })} /></label>
    <label>Repeat every how many months? (blank for one time)<input name="repeat_months" type="number" inputMode="numeric" min="1" max="120" disabled={busy} value={draft.repeat_months} onChange={event => setDraft({ ...draft, repeat_months: event.currentTarget.value })} /></label>
    <label>Category<select name="category" required disabled={busy} value={draft.category} onChange={event => setDraft({ ...draft, category: event.currentTarget.value })}>
      <option value="" disabled>Choose a category</option>
      {categories.map(row => <option key={row.id} value={row.id}>{row.name}</option>)}
      <option value={NO_CATEGORY}>Not in any category plan</option>
    </select></label>
    {draft.category === NO_CATEGORY && <p className="bill-hint">This bill isn’t part of any category plan, so it adds to your planned costs when it’s due.</p>}
    {chosen && SINKING.has(chosen.stack_key) && <p className="bill-hint">{chosen.name} is money you set aside for planned costs. The bill counts when it’s due, and the part of the monthly plan it covers stays in your savings. Any part your saved bills don’t cover still counts every month.</p>}
    {chosen && !SINKING.has(chosen.stack_key) && <p className="bill-hint">Counts inside {chosen.name}: the larger of the plan or this bill, not both.</p>}
    <label>Past due now (optional)<input name="past_due" type="number" inputMode="decimal" min="0" step="0.01" disabled={busy} value={draft.past_due} placeholder="Not entered" onChange={event => setDraft({ ...draft, past_due: event.currentTarget.value })} /></label>
    <p className="bill-hint">What you still owe from earlier bills. It counts once, in the first month, on top of this bill. Enter 0 if you are caught up; leave it blank if you are not sure.</p>
    <label className="bill-check"><input type="checkbox" name="must_pay" disabled={busy} checked={draft.must_pay} onChange={event => setDraft({ ...draft, must_pay: event.currentTarget.checked })} />Must pay</label>
    <label className="bill-check"><input type="checkbox" name="estimate" disabled={busy} checked={draft.estimate} onChange={event => setDraft({ ...draft, estimate: event.currentTarget.checked })} />Amount is an estimate</label>
    {reminder && <p className="form-error" role="alert">{reminder}</p>}
    {error && <p className="form-error" role="alert">{error}</p>}
    <div className="bill-actions"><button className="ui-btn ui-btn--primary" disabled={busy} type="submit">{busy ? 'Saving…' : 'Save bill'}</button><button type="button" className="secondary-button" disabled={busy} onClick={() => { closeForm(); setError('') }}>Cancel</button></div>
  </form>

  async function reload() {
    setBusy(true); setReloadError('')
    try { await onChanged?.() } catch { setReloadError('The forecast still could not refresh. Try again in a moment.') } finally { setBusy(false) }
  }

  if (stale) return <div className="bills-forecast">
    <h4>Cash through December</h4>
    <div className="bill-stale" role="status">
      <p>Forecast not available. Its totals and bills are hidden because they may be out of date; reload to see them.</p>
      {onChanged && <button type="button" className="ui-btn ui-btn--primary" disabled={busy} onClick={() => void reload()}>{busy ? 'Reloading…' : 'Reload forecast'}</button>}
    </div>
    {reloadError && <p className="form-error" role="alert">{reloadError}</p>}
  </div>

  return <div className="bills-forecast">
    <h4>Cash through December</h4>
    <p>{forecast.starting_note}</p>
    <p role="status" className={forecast.first_short_month ? 'forecast-headline is-short' : 'forecast-headline'}>{forecastHeadline(forecast)}{forecast.first_short_month ? ` Costs that month: ${forecast.first_short_month.reasons.join(', ')}.` : ''}{forecastEstimates(forecast) ? ` ${forecastEstimates(forecast)}` : ''}{forecast.status === 'unknown' && forecast.missing.length ? ` Still needed: ${forecast.missing.join(', ')}.` : ''}</p>
    <details><summary>How this forecast works</summary><ul className="forecast-rules">
      <li>It starts from your checking and savings balances when they all share one date this month or the last day of last month. Other dates leave ending cash unknown.</li>
      <li>From a balance in the middle of the month, only what comes after that day counts: income still expected, bills due later, and what’s left of each category’s plan.</li>
      <li>Each category counts the larger of its plan or its bills due that month, never both. This month, spending already recorded counts if it’s more.</li>
      <li>Money set aside for planned yearly costs or surprises stays in your savings, and saved bills count when they’re due. Any part of the monthly plan your saved bills don’t cover still counts every month.</li>
      <li>A balance dated the last day of a month already includes that month, so the forecast starts with the next one.</li>
      <li>Debt payments count once a month from My Money. A debt with a saved due day counts on that day (the 29th to 31st fall on a short month’s last day), so from a balance in the middle of the month one already due isn’t counted again. A payment with no due day still counts and may already be paid.</li>
      <li>Anything past due on a debt or a bill is owed now: it counts once, in the first month, on top of that month’s payments. A debt’s past-due amount is part of its balance, so it never counts above it.</li>
      <li>A one-time bill you mark paid stops counting.</li>
      <li>It shows each month’s end, not day-to-day dips inside a month.</li>
    </ul></details>
    <table className="forecast-table"><caption className="sr-only">Cash forecast by month</caption>
      <thead><tr><th scope="col">Month</th><th scope="col">Starting cash</th><th scope="col">Money in</th><th scope="col">Planned out</th><th scope="col">Ending cash</th></tr></thead>
      <tbody>{forecast.months.map(month => <tr key={month.starts_on} className={month.ending_cents != null && month.ending_cents < 0 ? 'is-short' : undefined}>
        <th scope="row">{month.label}{month.from_on && <small>From {billDate(month.from_on, false)}</small>}{monthItems(month).length > 0 && <small>{monthItems(month).join(', ')}</small>}{month.higher_costs && <small>Higher costs than usual</small>}</th>
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
          {!bill.paid_on && bill.past_due_cents != null && <p className={bill.past_due_cents > 0 ? 'bill-past-due' : undefined}>{bill.past_due_cents > 0 ? `${cash(bill.past_due_cents)} past due now · counts once, in the first month` : 'Caught up'}</p>}
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
      {forecast.debt_bills.map(debt => <p key={debt.name}>{debt.name}: {debt.amount_cents == null && debt.past_due_cents != null ? 'past due' : `${cash(debt.amount_cents)} a month`}{debt.due_day != null ? ` · due on the ${ordinalDay(debt.due_day)}` : ''}{debt.past_due_cents != null && debt.past_due_cents > 0 ? ` · ${cash(debt.past_due_cents)} past due, counts once now` : ''} · counts from My Money</p>)}
      {error && !editing && <p className="form-error" role="alert">{error}</p>}
      {canEdit && <button ref={addRef} type="button" className="secondary-button bill-add" disabled={busy} onClick={() => openForm('new')}>Add bill</button>}
      {editing === 'new' && form}
    </details>
  </div>
}
