import { useEffect, useRef, useState, type FormEvent, type Ref } from 'react'
import {
  archiveGoal, createGoal, restoreGoal, updateGoal,
  type GoalInput, type GoalPortfolio, type GoalRecord, type GoalType,
} from '../api'
import { OperationIdempotencyKeys } from '../lib/operationIdempotency'
import { proposedChoice, proposedMoney, proposedText, type MiaManualPayload } from '../lib/miaManualPrefill'

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
const goalTypes: GoalType[] = ['savings', 'debt_payoff', 'purchase', 'education', 'business', 'business_income', 'travel', 'home', 'retirement', 'other']
const goalTypeLabels: Record<GoalType, string> = {
  savings: 'Savings', debt_payoff: 'Debt payoff', purchase: 'Purchase', education: 'Education',
  business: 'Business', business_income: 'Business income', travel: 'Travel', home: 'Home', retirement: 'Retirement', other: 'Other',
}
type GoalAction = 'create_goal' | 'update_goal' | 'archive_goal' | 'restore_goal'
export type GoalFocusRequest = { key: number; actionType: GoalAction; goalId: number | null; payload: MiaManualPayload }
type Draft = { label: string; goal_type: GoalType; target_amount: string; current_amount: string; target_on: string }
const emptyDraft: Draft = { label: '', goal_type: 'savings', target_amount: '', current_amount: '', target_on: '' }

function goalDraftWithProposal(base: Draft, payload: MiaManualPayload): Draft {
  return {
    label: proposedText(payload, 'label', base.label),
    goal_type: proposedChoice(payload, 'goal_type', base.goal_type, goalTypes),
    target_amount: proposedMoney(payload, 'target_amount_cents', base.target_amount, 'target_amount_known'),
    current_amount: proposedMoney(payload, 'current_amount_cents', base.current_amount, 'current_amount_known'),
    target_on: proposedText(payload, 'target_on', base.target_on),
  }
}

export function GoalManager({ sectionRef, goals, portfolio, onChanged, focusRequest, onFocusRequestHandled }: {
  sectionRef?: Ref<HTMLElement>
  goals: GoalRecord[]
  portfolio: GoalPortfolio
  onChanged: () => Promise<void>
  focusRequest?: GoalFocusRequest | null
  onFocusRequestHandled?: () => void
}) {
  const [editing, setEditing] = useState<number | 'new' | null>(null)
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const [saving, setSaving] = useState(false)
  const [archiveId, setArchiveId] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)
  const keys = useRef(new OperationIdempotencyKeys())
  const addButtonRef = useRef<HTMLButtonElement | null>(null)
  const labelInputRef = useRef<HTMLInputElement | null>(null)
  const targetInputRef = useRef<HTMLInputElement | null>(null)
  const progressInputRef = useRef<HTMLInputElement | null>(null)
  const returnFocusRef = useRef<HTMLElement | null>(null)
  const handledFocusKeyRef = useRef<number | null>(null)
  const active = goals.filter((goal) => goal.active)
  const archived = goals.filter((goal) => !goal.active)

  useEffect(() => {
    if (!focusRequest || handledFocusKeyRef.current === focusRequest.key) return
    handledFocusKeyRef.current = focusRequest.key
    const goal = goals.find((candidate) => candidate.id === focusRequest.goalId)
    requestAnimationFrame(() => {
      if (focusRequest.actionType === 'create_goal') {
        setDraft(goalDraftWithProposal(emptyDraft, focusRequest.payload)); setEditing('new'); setArchiveId(null); setError(null)
        requestAnimationFrame(() => labelInputRef.current?.focus())
      } else if (focusRequest.actionType === 'update_goal' && goal?.active) {
        setDraft(goalDraftWithProposal({ label: goal.label, goal_type: goal.goal_type, target_amount: goal.target_amount === null ? '' : String(goal.target_amount), current_amount: goal.current_amount === null ? '' : String(goal.current_amount), target_on: goal.target_on ?? '' }, focusRequest.payload))
        setEditing(goal.id); setArchiveId(null); setError(null)
        requestAnimationFrame(() => labelInputRef.current?.focus())
      } else if (focusRequest.actionType === 'archive_goal' || focusRequest.actionType === 'restore_goal') {
        const selector = focusRequest.actionType === 'archive_goal' ? 'archive' : 'restore'
        const control = document.querySelector<HTMLElement>(`[data-goal-id="${focusRequest.goalId}"] [data-goal-action="${selector}"]`)
        if (control) revealAndFocus(control)
        else {
          setError('That goal is no longer in the expected list. Refresh the review before making a change.')
          addButtonRef.current?.focus()
        }
      } else {
        setError('That goal is no longer available to edit. Refresh the review before making a change.')
        addButtonRef.current?.focus()
      }
      onFocusRequestHandled?.()
    })
  }, [focusRequest, goals, onFocusRequestHandled])

  function rememberFocus(element?: HTMLElement | null) { returnFocusRef.current = element ?? document.activeElement as HTMLElement | null }
  function focusLater(selector?: string) {
    requestAnimationFrame(() => {
      const target = selector ? document.querySelector<HTMLElement>(selector) : null
      const fallback = returnFocusRef.current?.isConnected ? returnFocusRef.current : addButtonRef.current
      if (target ?? fallback) revealAndFocus((target ?? fallback) as HTMLElement)
    })
  }
  function beginCreate(trigger?: HTMLElement | null) {
    rememberFocus(trigger); setDraft(emptyDraft); setEditing('new'); setArchiveId(null); setError(null)
    requestAnimationFrame(() => labelInputRef.current?.focus())
  }
  function beginEdit(goal: GoalRecord, trigger?: HTMLElement | null) {
    rememberFocus(trigger)
    setDraft({ label: goal.label, goal_type: goal.goal_type, target_amount: goal.target_amount === null ? '' : String(goal.target_amount), current_amount: goal.current_amount === null ? '' : String(goal.current_amount), target_on: goal.target_on ?? '' })
    setEditing(goal.id); setArchiveId(null); setError(null)
    requestAnimationFrame(() => labelInputRef.current?.focus())
  }
  function cancel() { setEditing(null); setArchiveId(null); setError(null); focusLater() }
  async function refreshAfterCommit(selector?: string) {
    try { await onChanged(); setError(null) }
    catch { setError('The goal change was saved, but the latest goal list could not reload. Reload before making another change.') }
    focusLater(selector)
  }
  async function save(event: FormEvent) {
    event.preventDefault()
    const label = draft.label.trim()
    const target = amountOrNull(draft.target_amount)
    const progress = amountOrNull(draft.current_amount)
    if (!label) { setError('Give this goal a short name you will recognize.'); labelInputRef.current?.focus(); return }
    if (target === 'invalid') { setError('Target amount must be $0 or more, or blank when unknown.'); targetInputRef.current?.focus(); return }
    if (progress === 'invalid') { setError('Current progress must be $0 or more, or blank when unknown.'); progressInputRef.current?.focus(); return }
    const values: GoalInput = { label, goal_type: draft.goal_type, target_amount: target, current_amount: progress, target_on: draft.target_on || null }
    const signature = `${editing === 'new' ? 'create' : `update:${editing}`}:${JSON.stringify(values)}`
    setSaving(true); setError(null)
    try {
      const saved = editing === 'new'
        ? await createGoal(values, keys.current.keyFor(signature))
        : await updateGoal(editing as number, values, keys.current.keyFor(signature))
      keys.current.complete(signature); setEditing(null)
      await refreshAfterCommit(`[data-goal-id="${saved.id}"] [data-goal-action="edit"]`)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'This goal could not be saved.') }
    finally { setSaving(false) }
  }
  async function mutate(signature: string, action: (key: string) => Promise<GoalRecord>, selector: string) {
    setSaving(true); setError(null)
    try {
      await action(keys.current.keyFor(signature)); keys.current.complete(signature); setEditing(null); setArchiveId(null)
      await refreshAfterCommit(selector)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'That goal change could not be saved.') }
    finally { setSaving(false) }
  }
  const displayAmount = (value: number | null) => value === null ? 'Not entered' : money.format(value)
  const knownTargetSummary = portfolio.active_count === 0 ? 'Not entered' : portfolio.target_known_count === 0 ? 'Needs targets' : portfolio.target_known_count === portfolio.active_count ? money.format(portfolio.target_total) : `${money.format(portfolio.target_total)} known so far`
  const knownProgressSummary = portfolio.active_count === 0 ? 'Not entered' : portfolio.progress_known_count === 0 ? 'Needs progress' : portfolio.progress_known_count === portfolio.active_count ? money.format(portfolio.progress_total) : `${money.format(portfolio.progress_total)} known so far`

  return <article ref={sectionRef} className="panel goal-manager">
    <div className="row-between goal-manager-heading"><div><p className="eyebrow">Tracked goals</p><h3>Turn a household priority into a goal you can update.</h3><p>These targets track intent and progress. They never move money or change accounts, debt, the budget, runway, or safe-to-spend.</p></div>{editing === null && <button ref={addButtonRef} type="button" onClick={(event) => beginCreate(event.currentTarget)}>Add a goal</button>}</div>
    <div className="goal-summary" aria-label="Tracked goal totals"><span><small>Known targets</small><strong>{knownTargetSummary}</strong></span><span><small>Known progress</small><strong>{knownProgressSummary}</strong></span><span><small>Active goals</small><strong>{portfolio.active_count}</strong></span></div>
    {active.length === 0 && editing === null && <div className="goal-empty"><strong>No tracked goals yet.</strong><p>Add a goal when you want to name a target and follow its progress. Your primary household focus and runway policy stay separate.</p></div>}
    {active.length > 0 && <div className="goal-list">{active.map((goal) => <div className="goal-row" data-goal-id={goal.id} key={goal.id}>
      <div><strong>{goal.label}</strong><span>{goalTypeLabels[goal.goal_type]}{goal.target_on ? ` · Target ${new Date(`${goal.target_on}T00:00:00`).toLocaleDateString()}` : ' · No target date'}</span></div>
      <div><small>Progress</small><strong>{displayAmount(goal.current_amount)} <span aria-hidden="true">/</span> {displayAmount(goal.target_amount)}</strong></div>
      <div className="goal-row-actions"><button type="button" data-goal-action="edit" className="secondary-button" disabled={saving} onClick={(event) => beginEdit(goal, event.currentTarget)}>Edit</button><button type="button" data-goal-action="archive" className={archiveId === goal.id ? 'danger-button' : 'quiet-button'} disabled={saving} onClick={(event) => { rememberFocus(event.currentTarget); if (archiveId === goal.id) void mutate(`archive:${goal.id}`, (key) => archiveGoal(goal.id, key), `[data-goal-id="${goal.id}"] [data-goal-action="restore"]`); else setArchiveId(goal.id) }}>{archiveId === goal.id ? 'Confirm archive' : 'Archive'}</button></div>
    </div>)}</div>}
    {editing !== null && <form className="goal-form" onSubmit={save}><div className="goal-form-grid">
      <label className="setup-field text-wide"><span>Goal name</span><input ref={labelInputRef} required value={draft.label} onChange={(event) => setDraft((current) => ({ ...current, label: event.target.value }))} placeholder="Family trip" /></label>
      <label className="setup-field"><span>Type</span><select value={draft.goal_type} onChange={(event) => setDraft((current) => ({ ...current, goal_type: event.target.value as GoalType }))}>{goalTypes.map((type) => <option key={type} value={type}>{goalTypeLabels[type]}</option>)}</select></label>
      <label className="setup-field"><span>Target amount</span><span className="money-input-shell"><span aria-hidden="true">$</span><input ref={targetInputRef} type="number" min="0" inputMode="decimal" step="0.01" value={draft.target_amount} onChange={(event) => setDraft((current) => ({ ...current, target_amount: event.target.value }))} placeholder="Unknown" /></span><small>Blank means unknown. Use 0 only when confirmed.</small></label>
      <label className="setup-field"><span>Current progress</span><span className="money-input-shell"><span aria-hidden="true">$</span><input ref={progressInputRef} type="number" min="0" inputMode="decimal" step="0.01" value={draft.current_amount} onChange={(event) => setDraft((current) => ({ ...current, current_amount: event.target.value }))} placeholder="Unknown" /></span><small>Enter the amount you have intentionally assigned to this goal. This does not read or change an account.</small></label>
      <label className="setup-field"><span>Target date</span><input type="date" value={draft.target_on} onChange={(event) => setDraft((current) => ({ ...current, target_on: event.target.value }))} /><small>Optional. Leave blank when timing is undecided.</small></label>
    </div>{error && <p className="setup-error" role="alert">{error}</p>}<div className="debt-form-actions"><button type="button" className="secondary-button" disabled={saving} onClick={cancel}>Cancel</button><button type="submit" disabled={saving}>{saving ? 'Saving' : editing === 'new' ? 'Add goal' : 'Save goal'}</button></div></form>}
    {archived.length > 0 && <details className="debt-archive"><summary>Archived goals ({archived.length})</summary><p>Archived goals keep their history but leave active goal totals.</p>{archived.map((goal) => <div className="goal-row" data-goal-id={goal.id} key={goal.id}><div><strong>{goal.label}</strong><span>{goalTypeLabels[goal.goal_type]}</span></div><strong>{displayAmount(goal.current_amount)} / {displayAmount(goal.target_amount)}</strong><button type="button" data-goal-action="restore" className="secondary-button" disabled={saving} onClick={(event) => { rememberFocus(event.currentTarget); void mutate(`restore:${goal.id}`, (key) => restoreGoal(goal.id, key), `[data-goal-id="${goal.id}"] [data-goal-action="edit"]`) }}>Restore</button></div>)}</details>}
    {error && editing === null && <p className="setup-error" role="alert">{error}</p>}
  </article>
}

function amountOrNull(value: string): number | null | 'invalid' {
  if (!value.trim()) return null
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 'invalid'
}

function revealAndFocus(target: HTMLElement) {
  const details = target.closest('details')
  if (details) details.open = true
  target.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  target.focus({ preventScroll: true })
}
