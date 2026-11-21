import type { MethodOptionalProtectedCategory, MethodSettings } from '../api'
import { Button } from './Button'
import { coreProtected, debtOrderChoices, defaultMethod, groupNameChoices, homeViewChoices, methodProblems, optionalProtected, priorityLabels, protectedLabels, splitLabels, windfallLabels } from '../lib/methodSettings'

type Props = {
  method: MethodSettings
  disabled: boolean
  onChange: (method: MethodSettings) => void
}

const wholeNumber = (value: string) => (value.trim() === '' ? Number.NaN : Number(value))

function move<T>(list: T[], index: number, direction: -1 | 1): T[] {
  const next = [...list]
  const target = index + direction
  if (target < 0 || target >= next.length) return list
  ;[next[index], next[target]] = [next[target], next[index]]
  return next
}

/** The coaching method for a group. Plain words for coaches; it reaches people through Go live. */
export function MethodSettingsEditor({ method, disabled, onChange }: Props) {
  const problems = methodProblems(method)
  const status = method.status
  const setStatus = (key: keyof MethodSettings['status'], value: number) => onChange({ ...method, status: { ...status, [key]: value } })
  const setDollars = (key: 'surplus_green_cents' | 'surplus_yellow_cents', value: string) => setStatus(key, Math.round(wholeNumber(value) * 100))
  // The core list always stays; only the optional ones toggle, kept in the API's order.
  const toggleProtected = (key: MethodOptionalProtectedCategory) => {
    const chosen = method.protected.includes(key) ? method.protected.filter(item => item !== key) : [...method.protected, key]
    onChange({ ...method, protected: [...coreProtected, ...optionalProtected.filter(item => chosen.includes(item))] })
  }
  const isDefault = JSON.stringify(method) === JSON.stringify(defaultMethod)

  return (
    <article className="panel experience-method" aria-labelledby="experience-method-heading">
      <header><h3 id="experience-method-heading">Method</h3></header>
      <p>How Mia and the app judge progress for this group. The usual method is already set; change it only if you coach differently. People get changes after Go live.</p>
      <fieldset disabled={disabled}>
        <legend>Status colours</legend>
        <div className="experience-method-fields">
          <MethodNumber label="A goal is green if it can be reached within" unit="months" min={1} value={status.target_green_months} onChange={value => setStatus('target_green_months', wholeNumber(value))} />
          <MethodNumber label="Yellow within" unit="months" min={2} value={status.target_yellow_months} onChange={value => setStatus('target_yellow_months', wholeNumber(value))} />
          <MethodNumber label="Monthly surplus is green from" prefix="$" unit="a month" value={status.surplus_green_cents / 100} onChange={value => setDollars('surplus_green_cents', value)} />
          <MethodNumber label="Yellow from" prefix="$" unit="a month" value={status.surplus_yellow_cents / 100} onChange={value => setDollars('surplus_yellow_cents', value)} />
        </div>
        <small>Anything slower or smaller is red.</small>
      </fieldset>
      <fieldset disabled={disabled}>
        <legend>Emergency fund</legend>
        <div className="experience-method-fields">
          <MethodNumber label="Target" unit="months of planned costs" min={1} value={method.emergency_fund_months} onChange={value => onChange({ ...method, emergency_fund_months: wholeNumber(value) })} />
        </div>
        <small>A household that sets its own goal keeps it.</small>
      </fieldset>
      <fieldset disabled={disabled}>
        <legend>Never suggested as cuts</legend>
        <p className="experience-method-fixed"><strong>Always protected:</strong> {coreProtected.map(key => protectedLabels[key]).join(', ')}.</p>
        <span className="experience-method-subhead">Also protect</span>
        <div className="experience-method-checks">
          {optionalProtected.map(key => (
            <label key={key}><input type="checkbox" checked={method.protected.includes(key)} onChange={() => toggleProtected(key)} />{protectedLabels[key]}</label>
          ))}
        </div>
        <small>These always still count in spending. Care and bill stores stay protected too.</small>
      </fieldset>
      <fieldset disabled={disabled}>
        <legend>Priority order</legend>
        <MethodOrder items={method.priorities.map(key => [key, priorityLabels[key]])} label="Priority order" onMove={(index, direction) => onChange({ ...method, priorities: move(method.priorities, index, direction) })} />
      </fieldset>
      <fieldset disabled={disabled}>
        <legend>One-time money (bonus, tax refund) goes to</legend>
        <MethodOrder items={method.windfall.map(key => [key, windfallLabels[key]])} label="One-time money order" onMove={(index, direction) => onChange({ ...method, windfall: move(method.windfall, index, direction) })} />
      </fieldset>
      <fieldset disabled={disabled}>
        <legend>New monthly income (a raise or new job) splits</legend>
        <div className="experience-method-fields">
          {(Object.keys(splitLabels) as Array<keyof typeof splitLabels>).map(key => (
            <MethodNumber key={key} label={splitLabels[key]} unit="%" value={method.income_split[key]} onChange={value => onChange({ ...method, income_split: { ...method.income_split, [key]: wholeNumber(value) } })} />
          ))}
        </div>
        <small>Adds up to {[method.income_split.emergency_fund, method.income_split.debt, method.income_split.surplus].reduce((sum, value) => sum + (Number.isFinite(value) ? value : 0), 0)}%.</small>
      </fieldset>
      <MethodChoice legend="Spending group names" name="group_names" choices={groupNameChoices} value={method.group_names} disabled={disabled} onChange={group_names => onChange({ ...method, group_names })} note="Names only. Categories and totals stay the same." />
      <MethodChoice legend="Home leads with" name="home_view" choices={homeViewChoices} value={method.home_view} disabled={disabled} onChange={home_view => onChange({ ...method, home_view })} note="Each person can still switch Home for themselves." />
      <MethodChoice legend="Debt payoff" name="debt_order" choices={debtOrderChoices} value={method.debt_order} disabled={disabled} onChange={debt_order => onChange({ ...method, debt_order })} note="Mia always keeps every minimum paid first." />
      {problems.length > 0 && <ul className="experience-method-problems" role="alert">{problems.map(problem => <li key={problem}>{problem}</li>)}</ul>}
      <Button variant="ghost" disabled={disabled || isDefault} onClick={() => onChange(defaultMethod)}>Use the usual method</Button>
    </article>
  )
}

function MethodChoice<T extends string>({ legend, name, choices, value, disabled, onChange, note }: { legend: string; name: string; choices: Array<[T, string, string]>; value: T; disabled: boolean; onChange: (value: T) => void; note: string }) {
  return (
    <fieldset disabled={disabled}>
      <legend>{legend}</legend>
      <div className="experience-method-choices">
        {choices.map(([key, label, detail]) => (
          <label key={key}>
            <input type="radio" name={`method-${name}`} value={key} checked={value === key} onChange={() => onChange(key)} />
            <span><strong>{label}</strong><small>{detail}</small></span>
          </label>
        ))}
      </div>
      <small>{note}</small>
    </fieldset>
  )
}

function MethodNumber({ label, unit, prefix, value, min = 0, onChange }: { label: string; unit: string; prefix?: string; value: number; min?: number; onChange: (value: string) => void }) {
  return (
    <label className="experience-method-field">
      <span>{label}</span>
      <span className="experience-method-input">
        {prefix && <span aria-hidden="true">{prefix}</span>}
        <input className="ui-field" type="number" inputMode="numeric" min={min} step="1" value={Number.isFinite(value) ? value : ''} onChange={event => onChange(event.target.value)} />
        <span>{unit}</span>
      </span>
    </label>
  )
}

function MethodOrder({ items, label, onMove }: { items: Array<[string, string]>; label: string; onMove: (index: number, direction: -1 | 1) => void }) {
  return (
    <ol className="experience-tool-list experience-method-order" aria-label={label}>
      {items.map(([key, text], index) => (
        <li key={key} className="experience-module-row">
          <span><strong>{index + 1}. {text}</strong></span>
          <span className="experience-move">
            <Button variant="secondary" disabled={index === 0} onClick={() => onMove(index, -1)} aria-label={`Move ${text} up`}>↑</Button>
            <Button variant="secondary" disabled={index === items.length - 1} onClick={() => onMove(index, 1)} aria-label={`Move ${text} down`}>↓</Button>
          </span>
        </li>
      ))}
    </ol>
  )
}
