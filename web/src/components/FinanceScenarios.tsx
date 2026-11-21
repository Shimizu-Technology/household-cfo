import { useRef, useState } from 'react'
import { fetchPrivateJson } from '../api'
import { Button } from './Button'

export type FilterScenario = {
  base_surplus_cents: number | null
  after_spend_surplus_cents: number | null
  before: FilterState
  after: FilterState
  targets: Array<{ label: string; months: number | null; tone: string | null; yellow: Requirement; green: Requirement }>
  windfall: Array<{ key: string; cents: number; room_known: boolean }>
  cut_choices: Array<{ id: string; label: string; monthly_impact_cents: number; assumption: string }>
}
type FilterState = { emergency_months: number | null; emergency_tone: string | null; surplus_tone: string | null }
type Requirement = { surplus_cents: number | null; income_cents: number | null; extra_cents: number | null }
export type RunwayScenario = {
  inputs: { savings_cents: number | null; monthly_costs_cents: number | null; replacement_income_cents: number | null }
  monthly_gap_cents: number | null; monthly_draw_cents: number | null
  months: number | null; sustainable?: boolean; tone: string | null; label: string
}
const money = (cents: number | null) => cents === null ? 'Unknown' : new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(cents / 100)
const cents = (value: string) => /^\d+(\.\d{1,2})?$/.test(value) && Number(value) <= 9999999.99 ? Math.round(Number(value) * 100) : null
const months = (state: FilterState) => state.emergency_months === null ? state.emergency_tone ? 'Not reached at this surplus' : 'Unknown' : `${state.emergency_months} months`
const initialMoney = (value: number | null) => value === null ? '' : String(value / 100)

function Amount({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return <label className="scenario-field">{label}<input inputMode="decimal" value={value} onChange={event => onChange(event.target.value)} placeholder="Unknown" /></label>
}

export function CfoScenarios({ initial, onAsk }: { initial: FilterScenario; onAsk?: (prompt: string) => void }) {
  const [result, setResult] = useState(initial)
  const [spend, setSpend] = useState('')
  const [windfall, setWindfall] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const request = useRef(0)
  async function calculate(kind: 'spend_cents' | 'windfall_cents') {
    const amount = cents(kind === 'spend_cents' ? spend : windfall)
    if (amount === null) { setError('Enter an amount of $0 or more, with up to two decimal places.'); return }
    const id = ++request.current
    setBusy(true); setError('')
    try {
      const response = await fetchPrivateJson<FilterScenario>(`/api/v1/cfo-filter?scenario=1&${kind}=${amount}`)
      if (id === request.current) setResult(previous => kind === 'windfall_cents' ? { ...previous, windfall: response.windfall } : { ...response, windfall: previous.windfall })
    } catch { if (id === request.current) setError('Could not calculate this possibility. Try again; nothing changed.') }
    finally { if (id === request.current) setBusy(false) }
  }
  return <div className="finance-scenarios">
    <article className="ui-card">
      <h3>I am considering spending…</h3>
      <p>What if this purchase came from this month’s surplus? Savings stay untouched. The pace below assumes the remaining surplus each month; this is a comparison, not a saved plan.</p>
      <form onSubmit={event => { event.preventDefault(); void calculate('spend_cents') }}>
        <Amount label="Purchase amount ($)" value={spend} onChange={value => { setSpend(value); setError('') }} />
        <Button type="submit" disabled={busy}>Compare this spend</Button>
      </form>
      <p>Base surplus, without bonuses: <strong>{money(result.base_surplus_cents)}</strong></p>
      <div aria-live="polite">
        <p>Emergency fund: {months(result.before)} ({result.before.emergency_tone ?? 'unknown'}) → {months(result.after)} ({result.after.emergency_tone ?? 'unknown'})</p>
        <p>Surplus after spending: <strong>{money(result.after_spend_surplus_cents)}</strong> ({result.before.surplus_tone ?? 'unknown'} → {result.after.surplus_tone ?? 'unknown'})</p>
      </div>
    </article>
    <article className="ui-card">
      <h3>What does it take to flip the light?</h3>
      <p>Each target uses the full surplus independently. Debt is a principal-only estimate for consumer debt, excluding the mortgage; interest and fees can extend payoff.</p>
      {result.targets.map(target => <div className="scenario-target" key={target.label}>
        <h4><span aria-hidden="true" className={`ui-dot ui-dot--${target.tone ?? 'neutral'}`} /> {target.label} · {target.tone ?? 'unknown'}</h4>
        {(['yellow', 'green'] as const).map(tone => <p key={tone}>{tone === 'yellow' ? 'Yellow' : 'Green'}: {money(target[tone].surplus_cents)} monthly surplus · {money(target[tone].income_cents)} total monthly income · {money(target[tone].extra_cents)} more than now</p>)}
      </div>)}
    </article>
    <article className="ui-card">
      <h3>One-time money</h3>
      <form onSubmit={event => { event.preventDefault(); void calculate('windfall_cents') }}>
        <Amount label="Windfall amount ($)" value={windfall} onChange={setWindfall} />
        <Button type="submit" disabled={busy}>Split this windfall</Button>
      </form>
      <ul aria-live="polite">{result.windfall.map(step => <li key={step.key}>{step.key === 'emergency_fund' ? 'Emergency fund' : step.key === 'consumer_debt' ? 'Consumer debt' : 'Surplus'}: {money(step.cents)}{!step.room_known && ' held here until the missing balance is known'}</li>)}</ul>
    </article>
    <article className="ui-card">
      <h3>Three ways to create room</h3>
      <ol><li>Grow recurring income. Use the monthly income targets above.</li><li>Cut flexible spending, keeping care, bills and family support protected.
        {result.cut_choices.length ? <ul>{result.cut_choices.map(choice => <li key={choice.id}>{choice.label}: about {money(choice.monthly_impact_cents)} a month. {choice.assumption}.</li>)}</ul> : <p>No repeatable cut found in approved spending yet. That is unknown savings, not $0 available to cut.</p>}
      </li><li>Use one-time money in your program’s order.</li></ol>
      {onAsk && <Button onClick={() => onAsk('Where could I cut flexible spending without touching protected needs?')}>Ask Mia where to cut</Button>}
    </article>
    {error && <p role="alert">{error}</p>}
    <p>What if only. Nothing financial is saved or approved here.</p>
  </div>
}

export function OptionalityScenario({ initial }: { initial: RunwayScenario }) {
  const [result, setResult] = useState(initial)
  const [savings, setSavings] = useState(initialMoney(initial.inputs.savings_cents))
  const [costs, setCosts] = useState(initialMoney(initial.inputs.monthly_costs_cents))
  const [income, setIncome] = useState(initialMoney(initial.inputs.replacement_income_cents))
  const [draw, setDraw] = useState(initialMoney(initial.monthly_draw_cents))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function calculate() {
    const values = { savings_cents: cents(savings), monthly_costs_cents: cents(costs), replacement_income_cents: cents(income), ...(draw !== '' ? { monthly_draw_cents: cents(draw) } : {}) }
    if (Object.values(values).some(value => value === null)) { setError('Enter each missing amount, with up to two decimal places.'); return }
    setBusy(true); setError('')
    try { setResult(await fetchPrivateJson<RunwayScenario>(`/api/v1/optionality?scenario=1&${new URLSearchParams(Object.entries(values).map(([key, value]) => [key, String(value)]))}`)) }
    catch { setError('Could not calculate this possibility. Try again; nothing changed.') }
    finally { setBusy(false) }
  }
  return <article className="ui-card finance-scenarios">
    <h3>How long could we last if I quit?</h3>
    <p>Start with your approved savings, planned household costs and income continuing after the transition, including business income. Change these fields to explore a possibility.</p>
    <form onSubmit={event => { event.preventDefault(); void calculate() }}>
      <Amount label="Savings available ($)" value={savings} onChange={setSavings} />
      <Amount label="Monthly household costs ($)" value={costs} onChange={setCosts} />
      <Amount label="Monthly replacement income ($)" value={income} onChange={setIncome} />
      <Amount label="Monthly savings draw ($; blank uses the gap)" value={draw} onChange={setDraw} />
      <p>Draw from the gap: {money(cents(costs) !== null && cents(income) !== null ? Math.max(cents(costs)! - cents(income)!, 0) : null)}</p>
      <Button type="submit" disabled={busy}>Explore this runway</Button>
    </form>
    {error && <p role="alert">{error}</p>}
    <div aria-live="polite"><p><strong>{result.months === null ? result.sustainable ? 'Savings do not run out in this model' : 'Runway unknown' : `${result.months} fully funded months`}</strong></p><p><span aria-hidden="true" className={`ui-dot ui-dot--${result.tone ?? 'neutral'}`} /> {result.label}{result.tone && ` (${result.tone})`}</p><p>Monthly gap: {money(result.monthly_gap_cents)} · Draw: {money(result.monthly_draw_cents)}</p></div>
    <p>Assumes 5% yearly savings growth, compounded monthly before withdrawals, with steady costs and income. Returns are uncertain. 36+ months: comfortable; 18–35: workable; under 18: tight.</p>
    <p>What if only. Nothing financial is saved or approved here.</p>
  </article>
}
