import { useState } from 'react'
import { removeBill, saveBill, type AnnualBudgetPlan, type ScheduledBill } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'

const cash = (value: number | null) => value == null ? 'Not known yet' : formatReviewMoney(value)
const date = (value: string) => {
  const parsed = new Date(`${value}T00:00:00Z`)
  return Number.isNaN(parsed.getTime()) ? 'date not entered' : new Intl.DateTimeFormat('en', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(parsed)
}
export function BillsForecast({ plan }: { plan: AnnualBudgetPlan }) {
  const forecast = plan.year_forecast!
  const [editing, setEditing] = useState<ScheduledBill | null>(null)
  const [form, setForm] = useState(false)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  async function save(data: FormData) {
    setBusy(true); setError('')
    try {
      await saveBill(editing?.id ?? null, { name: data.get('name'), amount: data.get('amount'), due_on: data.get('due_on'), repeat_months: data.get('repeat_months') || null, budget_category_id: data.get('category') || null, must_pay: data.get('must_pay') === 'on', estimate: data.get('estimate') === 'on' })
      window.location.reload()
    } catch (err) { setError(err instanceof Error ? err.message : 'Could not save the bill.'); setBusy(false) }
  }
  return <div className="bills-forecast">
    <h4>Cash through December</h4>
    <p>Uses opening cash balances dated at the end of the previous month. If those dates or balances are missing, ending cash stays unknown.</p>
    <p>Starting cash: {cash(forecast.starting_cash_cents)}</p>
    <p role="status">{forecast.first_short_month ? `First month that runs short: ${forecast.first_short_month.label}. Planned costs include ${forecast.first_short_month.reasons.join(', ')}.` : forecast.status === 'no_short_month' ? 'No month runs short in this plan.' : 'We need the missing numbers before we can say whether a month runs short.'}</p>
    <details><summary>How this forecast works</summary><p>{forecast.rule}</p></details>
    <div className="forecast-table-wrap"><table className="forecast-table"><caption>Month-by-month cash forecast</caption><thead><tr><th>Month</th><th>Starting cash</th><th>Money in</th><th>Planned out</th><th>Ending cash</th></tr></thead><tbody>{forecast.months.map(month => <tr key={month.starts_on}><th>{month.label}<small>{month.bills.map(bill => bill.name).join(', ')}</small></th><td>{cash(month.opening_cents)}</td><td>{cash(month.income_cents)}<small>{month.income_basis}{month.actual_partial ? ' · incomplete' : ''}</small></td><td>{cash(month.outflow_cents)}</td><td>{cash(month.ending_cents)}</td></tr>)}</tbody></table></div>
    <details><summary>Bills and due dates</summary>
      <p>Debt minimums are read from My Money. To change one, edit the debt there. Adding a bill saves it only when you press Save bill.</p>
      <ul>{forecast.bills.map(bill => <li key={bill.id}><strong>{bill.name}: {cash(bill.amount_cents)}{bill.estimate ? ' estimated' : ''}</strong><p>{!bill.repeat_months && bill.due_on < new Date().toLocaleDateString('en-CA', { timeZone: 'Pacific/Guam' }) ? 'Past due · ' : ''}Due {date(bill.due_on)} · {bill.repeat_months ? `every ${bill.repeat_months} month${bill.repeat_months === 1 ? '' : 's'}` : 'one time'}{bill.must_pay ? ' · must pay' : ''}</p><div className="bill-actions"><button type="button" className="secondary-button" onClick={() => { setEditing(bill); setForm(true); setMessage('') }}>Edit {bill.name}</button><button type="button" className="secondary-button" disabled={busy} onClick={() => { setEditing(bill); setMessage(`Remove ${bill.name}?`) }}>Remove {bill.name}</button></div></li>)}</ul>
      {forecast.debt_bills.map((bill, index) => <p key={index}>{bill.name}: {cash(bill.amount_cents)} monthly minimum · must pay · {bill.due_on ? `due ${date(bill.due_on)}` : 'due date not entered'}</p>)}
      {message && <div role="alert"><p>{message}</p><div className="bill-actions"><button disabled={busy} type="button" onClick={async () => { setBusy(true); try { await removeBill(editing!.id); window.location.reload() } catch { setError('Could not remove this bill.'); setBusy(false) } }}>Confirm removal</button><button type="button" onClick={() => setMessage('')}>Keep bill</button></div></div>}
      <button type="button" className="secondary-button" onClick={() => { setEditing(null); setForm(true); setMessage('') }}>Add bill</button>
      {error && <p role="alert">{error}</p>}
      {form && <form key={editing?.id ?? 'new'} className="annual-category-form" action={save}>
        <label>Bill name<input name="name" required maxLength={80} defaultValue={editing?.name} /></label>
        <label>Bill amount<input name="amount" type="number" required min="0" step="0.01" defaultValue={editing ? editing.amount_cents / 100 : ''} /></label>
        <label>First due date<input name="due_on" type="date" required defaultValue={editing?.due_on} /></label>
        <label>Repeat every how many months? (blank for one time)<input name="repeat_months" type="number" min="1" max="120" defaultValue={editing?.repeat_months ?? ''} /></label>
        <label>Category<select name="category" defaultValue={editing?.budget_category_id ?? ''}><option value="">Extra cost outside the category plan</option>{plan.rows.filter(row => row.active !== false && row.id > 0).map(row => <option key={row.id} value={row.id}>{row.name}</option>)}</select></label>
        <label><input type="checkbox" name="must_pay" defaultChecked={editing?.must_pay ?? true} />Must pay</label>
        <label><input type="checkbox" name="estimate" defaultChecked={editing?.estimate} />Amount is an estimate</label>
        <div className="bill-actions"><button disabled={busy} type="submit">Save bill</button><button type="button" disabled={busy} onClick={() => setForm(false)}>Cancel</button></div>
      </form>}
    </details>
  </div>
}
