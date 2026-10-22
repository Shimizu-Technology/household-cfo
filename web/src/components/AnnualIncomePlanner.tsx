import { useEffect, useRef, useState, type FormEvent } from 'react'
import type { AnnualBudgetPlan, IncomeScheduleEntry, IncomeScheduleEntryInput } from '../api'
import { payloadHas, proposedText, proposedMoney, proposedChoice, proposedBoolean } from '../lib/miaManualPrefill'
import { moneyInputProblem } from '../lib/workspaceSetupForm'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { sumMoney } from '../lib/moneyMath'
import { useBrand } from '../contexts/brandContextValue'
import { useIncomeForm, type BudgetFocusRequest } from './incomeFormState'
import { currency, titleize, formatMonthYear, guamCurrentMonthIso, cadenceOptions, incomeSourceEffectiveInMonth } from './incomeDisplay'
import './IncomeForms.css'

type IncomeScheduleDraft = {
  income_source_id: string
  entry_type: 'recurring_change' | 'one_time'
  label: string
  amount: string
  cadence: string
  effective_on: string
  retained_after_transition: boolean
}

function blankIncomeScheduleDraft(plan: AnnualBudgetPlan): IncomeScheduleDraft {
  const [guamYear, guamMonth] = guamCurrentMonthIso().split('-').map(Number)
  const currentMonth = plan.year === guamYear ? guamMonth : 1
  const effectiveOn = `${plan.year}-${String(currentMonth).padStart(2, '0')}-01`
  const firstEligibleSource = plan.income_sources.find((source) => incomeSourceEffectiveInMonth(source, effectiveOn))
  return {
    income_source_id: firstEligibleSource ? String(firstEligibleSource.id) : '',
    entry_type: 'recurring_change',
    label: '',
    amount: '',
    cadence: 'monthly',
    effective_on: effectiveOn,
    retained_after_transition: false,
  }
}

function incomeScheduleDraftFor(sourceId: number, entry: IncomeScheduleEntry): IncomeScheduleDraft {
  return {
    income_source_id: String(sourceId),
    entry_type: entry.entry_type,
    label: entry.label ?? '',
    amount: String(entry.amount),
    cadence: entry.entry_type === 'one_time' ? 'one_time' : entry.cadence,
    effective_on: entry.effective_on,
    retained_after_transition: entry.retained_after_transition === true,
  }
}

export function AnnualIncomePlanner({
  plan,
  isRealWorkspace,
  action,
  onSave,
  onDelete,
  focusRequest,
  onFocusRequestHandled,
  onUnsavedChangesChange,
}: {
  plan: AnnualBudgetPlan
  isRealWorkspace: boolean
  action: string | null
  onSave: (values: IncomeScheduleEntryInput, entryId?: number) => Promise<void>
  onDelete: (entry: IncomeScheduleEntry) => void
  focusRequest?: BudgetFocusRequest | null
  onFocusRequestHandled?: () => void
  onUnsavedChangesChange?: (dirty: boolean) => void
}) {
  const { assistantName } = useBrand()
  const { open: formOpen, setOpen: setFormOpen, blocked: editorBlocked } = useIncomeForm('schedule')
  const [draft, setDraft] = useState<IncomeScheduleDraft>(() => blankIncomeScheduleDraft(plan))
  const [draftBaseline, setDraftBaseline] = useState<IncomeScheduleDraft>(() => blankIncomeScheduleDraft(plan))
  const [editingId, setEditingId] = useState<number | null>(null)
  const [step, setStep] = useState(0)
  const [changeKind, setChangeKind] = useState<'pay' | 'ending' | 'one_time'>('pay')
  const questionRef = useRef<HTMLHeadingElement | null>(null)
  const editButtonRef = useRef<HTMLButtonElement | null>(null)
  const openButtonRef = useRef<HTMLButtonElement | null>(null)
  const [removingId, setRemovingId] = useState<number | null>(null)
  const [formError, setFormError] = useState<string | null>(null)
  const amountInputRef = useRef<HTMLInputElement | null>(null)
  const handledFocusKeyRef = useRef<number | null>(null)

  const hasUnsavedChanges = removingId !== null || Object.entries(draftBaseline).some(([key, value]) => draft[key as keyof IncomeScheduleDraft] !== value)
  useEffect(() => {
    onUnsavedChangesChange?.(hasUnsavedChanges)
    return () => onUnsavedChangesChange?.(false)
  }, [hasUnsavedChanges, onUnsavedChangesChange])

  useEffect(() => {
    if (hasUnsavedChanges || editingId !== null) return
    const refreshedBlank = blankIncomeScheduleDraft(plan)
    if (draft.income_source_id === refreshedBlank.income_source_id) return
    // A newly added/ended source can change the default of an untouched form.
    // Preserve participant-entered fields; only reconcile the pristine draft.
    queueMicrotask(() => { setDraftBaseline(refreshedBlank); setDraft(refreshedBlank) })
  }, [draft.income_source_id, editingId, hasUnsavedChanges, plan])

  useEffect(() => {
    if (!focusRequest || handledFocusKeyRef.current === focusRequest.key) return
    handledFocusKeyRef.current = focusRequest.key
    const located = plan.income_sources.flatMap((source) => source.schedule_entries.map((entry) => ({ source, entry })))
      .find(({ entry }) => entry.id === focusRequest.incomeScheduleEntryId)
    if (focusRequest.operationKey === 'income.schedule.create') {
      const payload = focusRequest.payload
      const sourceId = Number(payload.income_source_id ?? payload.source_id ?? 0)
      const entryType = payload.entry_type === 'one_time' ? 'one_time' : 'recurring_change'
      const amountCents = Number(payload.amount_cents ?? 0)
      const fallback = blankIncomeScheduleDraft(plan)
      requestAnimationFrame(() => {
        setFormOpen(true)
        setStep(2)
        setChangeKind(entryType === 'one_time' ? 'one_time' : Number(payload.amount_cents) === 0 ? 'ending' : 'pay')
        setRemovingId(null)
        setEditingId(null)
        setFormError(null)
        setDraftBaseline(fallback)
        setDraft({
          income_source_id: sourceId > 0 ? String(sourceId) : fallback.income_source_id,
          entry_type: entryType,
          label: String(payload.label ?? ''),
          amount: Number.isFinite(amountCents) && amountCents >= 0 ? String(amountCents / 100) : '',
          cadence: entryType === 'one_time' ? 'one_time' : String(payload.cadence ?? 'monthly'),
          effective_on: String(payload.effective_on ?? fallback.effective_on),
          retained_after_transition: payload.retained_after_transition === true,
        })
        requestAnimationFrame(() => (amountInputRef.current ?? questionRef.current)?.focus())
        onFocusRequestHandled?.()
      })
    } else if (focusRequest.operationKey === 'income.schedule.update' && located) {
      const payload = focusRequest.payload
      const baseEntryType = located.entry.entry_type
      const entryType = proposedChoice(payload, 'entry_type', baseEntryType, ['one_time', 'recurring_change'] as const)
      requestAnimationFrame(() => {
        setFormOpen(true)
        setStep(2)
        setChangeKind(entryType === 'one_time' ? 'one_time' : Number(proposedMoney(payload, 'amount_cents', String(located.entry.amount))) === 0 ? 'ending' : 'pay')
        setRemovingId(null)
        setEditingId(located.entry.id)
        setDraftBaseline(incomeScheduleDraftFor(located.source.id, located.entry))
        setFormError(null)
        setDraft({
          income_source_id: proposedText(payload, payloadHas(payload, 'income_source_id') ? 'income_source_id' : 'source_id', String(located.source.id)),
          entry_type: entryType,
          label: proposedText(payload, 'label', located.entry.label ?? ''),
          amount: proposedMoney(payload, 'amount_cents', String(located.entry.amount)),
          cadence: entryType === 'one_time' ? 'one_time' : proposedChoice(payload, 'cadence', located.entry.cadence, ['weekly', 'biweekly', 'semi_monthly', 'monthly', 'annual']),
          effective_on: proposedText(payload, 'effective_on', located.entry.effective_on),
          retained_after_transition: proposedBoolean(payload, 'retained_after_transition', located.entry.retained_after_transition === true),
        })
        requestAnimationFrame(() => (amountInputRef.current ?? questionRef.current)?.focus())
        onFocusRequestHandled?.()
      })
    } else if (focusRequest.operationKey === 'income.schedule.delete' && located) {
      requestAnimationFrame(() => {
        const target = document.querySelector<HTMLButtonElement>(`[data-income-entry-id="${located.entry.id}"] [data-income-entry-action="remove"]`)
        target?.scrollIntoView({ behavior: 'smooth', block: 'center' })
        target?.focus({ preventScroll: true })
        onFocusRequestHandled?.()
      })
    } else {
      onFocusRequestHandled?.()
    }
  }, [focusRequest, onFocusRequestHandled, plan, setFormOpen])

  function editEntry(sourceId: number, entry: IncomeScheduleEntry, trigger: HTMLButtonElement) {
    if (editorBlocked) return
    if (hasUnsavedChanges) { setFormError('Save or cancel this income draft before editing another change.'); return }
    editButtonRef.current = trigger
    setFormOpen(true)
    setStep(0)
    requestAnimationFrame(() => questionRef.current?.focus())
    setChangeKind(entry.entry_type === 'one_time' ? 'one_time' : entry.amount === 0 ? 'ending' : 'pay')
    setRemovingId(null)
    setEditingId(entry.id)
    setFormError(null)
    const saved = incomeScheduleDraftFor(sourceId, entry)
    setDraftBaseline(saved)
    setDraft(saved)
  }

  function cancelEdit() {
    setFormOpen(false)
    setStep(0)
    setChangeKind('pay')
    requestAnimationFrame(() => (editButtonRef.current?.isConnected ? editButtonRef.current : openButtonRef.current)?.focus())
    setRemovingId(null)
    setEditingId(null)
    setFormError(null)
    const blank = blankIncomeScheduleDraft(plan)
    setDraftBaseline(blank)
    setDraft(blank)
  }

  function updateIncomeDraft(values: Partial<IncomeScheduleDraft>) {
    setDraft((current) => ({ ...current, ...values }))
  }

  function goToStep(next: number) {
    setStep(next)
    setFormError(null)
    requestAnimationFrame(() => questionRef.current?.focus())
  }

  function continueForm() {
    if (step === 1 && (!/^(20\d{2}|2100)-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(draft.effective_on) || !selectedSource)) {
      setFormError('Choose a month and an income source paid in that month.')
      return
    }
    goToStep(step + 1)
  }

  function chooseChange(kind: typeof changeKind) {
    setChangeKind(kind)
    updateIncomeDraft({
      entry_type: kind === 'one_time' ? 'one_time' : 'recurring_change',
      cadence: kind === 'one_time' ? 'one_time' : draft.cadence === 'one_time' ? 'monthly' : draft.cadence,
      amount: kind === 'ending' ? '0' : changeKind === 'ending' ? '' : draft.amount,
      retained_after_transition: kind === 'pay' ? draft.retained_after_transition : false,
    })
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (step < 2) { continueForm(); return }
    if (!draft.income_source_id || !draft.amount || !draft.effective_on || !selectedSource || !incomeSourceEffectiveInMonth(selectedSource, draft.effective_on)) {
      setFormError('Choose an income source that is active for that month, an amount, and a starting month.')
      return
    }

    const amountProblem = moneyInputProblem('Pay amount', draft.amount)
    if (amountProblem || (draft.entry_type === 'one_time' && Number(draft.amount) <= 0)) {
      setFormError(amountProblem || 'Enter a one-time payment greater than $0.')
      return
    }
    setFormError(null)
    try {
      await onSave({
        income_source_id: Number(draft.income_source_id),
        entry_type: draft.entry_type,
        label: draft.label,
        amount: draft.amount,
        cadence: draft.entry_type === 'one_time' ? 'one_time' : draft.cadence,
        effective_on: draft.effective_on,
        retained_after_transition: draft.entry_type === 'recurring_change'
          && selectedSource?.source_type === 'job'
          && Number(draft.amount) > 0
          && draft.retained_after_transition,
      }, editingId ?? undefined)
      cancelEdit()
    } catch (caught) {
      setFormError(participantErrorMessage(caught, 'This pay change could not be saved. Your entries are still here.'))
    }
  }

  const incomeOperationPending = Boolean(action)
  const saving = action === 'create-income' || (editingId !== null && action === `update-income:${editingId}`)
  const eligibleSources = plan.income_sources.filter((source) => incomeSourceEffectiveInMonth(source, draft.effective_on))
  const selectedSource = eligibleSources.find((source) => String(source.id) === draft.income_source_id)
  const numericAmount = Number(draft.amount)
  const hasPreviewAmount = draft.amount.trim() !== '' && Number.isFinite(numericAmount)
  const previewMonth = draft.effective_on ? formatMonthYear(draft.effective_on) : 'the selected month'
  const previewCopy = !selectedSource || !hasPreviewAmount
    ? 'Complete the fields above to preview how this changes the annual income plan.'
    : draft.entry_type === 'one_time'
      ? `${selectedSource.label} will add ${currency.format(numericAmount)} once in ${previewMonth}.`
      : numericAmount === 0
        ? `${selectedSource.label} will end beginning ${previewMonth}.`
        : `Starting ${previewMonth}, ${selectedSource.label} changes to ${currency.format(numericAmount)} ${titleize(draft.cadence).toLowerCase()}.`
  const submitLabel = saving
    ? 'Saving'
    : editingId !== null
      ? 'Save income change'
      : draft.entry_type === 'one_time'
        ? 'Add one-time income'
        : 'Schedule income change'

  return (
    <section className="annual-income-planner" aria-labelledby="annual-income-title">
      <div className="annual-income-heading">
        <div>
          <h4 id="annual-income-title">Pay changes</h4>
          <p>Set your pay once. It carries forward until you change it.</p>
        </div>
        <span>{plan.income_sources.length === 0 ? 'Annual income not entered' : `${currency.format(sumMoney(Object.values(plan.monthly_income)))} annual income`}</span>
      </div>

      {plan.income_sources.length === 0 ? (
        <p className="annual-edit-hint">Add an income source in My Money before scheduling changes across the year.</p>
      ) : (
        <>
          {plan.income_sources.every(source => source.schedule_entries.length === 0) && <p>No pay changes planned.</p>}
          <div className="income-source-list">
            {plan.income_sources.filter(source => source.schedule_entries.length > 0).map((source) => (
              <article className="income-source-card" key={source.id}>
                <div>
                  <span>{titleize(source.source_type)}</span>
                  <strong>{source.label}</strong>
                </div>
                  <div className="income-schedule-list">
                    {source.schedule_entries.map((entry) => (
                      <div className={`income-schedule-row${entry.active === false ? ' is-inactive' : ''}`} data-income-entry-id={entry.id} key={entry.id}>
                        <div>
                          <strong>{entry.entry_type === 'one_time' ? (entry.label || 'One-time income') : entry.amount === 0 ? 'Income ends' : 'New pay amount'}</strong>
                          <span>{formatMonthYear(entry.effective_on)} · {currency.format(entry.amount)}{entry.entry_type === 'one_time' ? ' once' : ` ${titleize(entry.cadence)}`}</span>
                          {entry.retained_after_transition && <small>Confirmed to continue after transition</small>}
                          {entry.active === false && <small>Not counted because this income has not started or has already ended.</small>}
                        </div>
                        {isRealWorkspace && (
                          <div>
                            {removingId === entry.id ? (
                              <>
                                <span className="income-remove-question">Remove this change?</span>
                                <button type="button" className="secondary-button" onClick={() => setRemovingId(null)}>Keep</button>
                                <button type="button" disabled={action === `delete-income:${entry.id}`} onClick={() => { onDelete(entry); setRemovingId(null) }}>
                                  {action === `delete-income:${entry.id}` ? 'Removing' : 'Confirm remove'}
                                </button>
                              </>
                            ) : (
                              <>
                                <button type="button" className="secondary-button" aria-label={`Edit ${source.label} income change from ${formatMonthYear(entry.effective_on)}`} disabled={incomeOperationPending || editorBlocked} onClick={(event) => editEntry(source.id, entry, event.currentTarget)}>Edit</button>
                                <button type="button" data-income-entry-action="remove" disabled={incomeOperationPending || editorBlocked} className="secondary-button" onClick={() => { if (hasUnsavedChanges) { setFormError('Save or cancel this income draft before removing a change.'); return }; cancelEdit(); setRemovingId(entry.id) }}>Remove</button>
                              </>
                            )}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
              </article>
            ))}
          </div>

          {isRealWorkspace && !formOpen && <button ref={openButtonRef} type="button" disabled={incomeOperationPending || editorBlocked} className="secondary-button" onClick={() => { editButtonRef.current = null; setFormOpen(true); goToStep(0) }}>Plan an income change</button>}
          {isRealWorkspace && formOpen && (
            <form className="income-schedule-form" noValidate onSubmit={(event) => void submit(event)}>
              <h4 ref={questionRef} tabIndex={-1} className="income-question">
                {step === 0 ? 'What changed?' : step === 1 ? 'Starting when?' : changeKind === 'ending' ? 'Check your pay ending' : 'How much, and how often?'}
              </h4>
              <fieldset className="income-questions" disabled={incomeOperationPending}>
                <legend className="sr-only">{editingId === null ? 'Plan an income change' : 'Edit income change'}</legend>
                <div hidden={step !== 0} className="income-change-choices">
                  {([['pay', 'New pay amount'], ['ending', 'Pay ending'], ['one_time', 'A one-time payment']] as const).map(([kind, label]) => (
                    <label key={kind} className="income-change-choice">
                      <input type="radio" name="income-change-kind" value={kind} checked={changeKind === kind} onChange={() => chooseChange(kind)} />
                      <span>{label}</span>
                    </label>
                  ))}
                </div>
                <div hidden={step !== 1} className="income-question-fields">
                  <label>
                    <span>Starting month</span>
                    <input type="month" min="2000-01" max="2100-12" value={draft.effective_on.slice(0, 7)} onChange={(event) => {
                      const effectiveOn = event.currentTarget.value ? `${event.currentTarget.value}-01` : ''
                      const nextEligible = plan.income_sources.filter((source) => incomeSourceEffectiveInMonth(source, effectiveOn))
                      const keepsSource = nextEligible.some((source) => String(source.id) === draft.income_source_id)
                      updateIncomeDraft({ effective_on: effectiveOn, income_source_id: keepsSource ? draft.income_source_id : editingId !== null ? draft.income_source_id : String(nextEligible[0]?.id ?? '') })
                    }} />
                  </label>
                  <label>
                    <span>Income source</span>
                    <select value={draft.income_source_id} disabled={editingId !== null || eligibleSources.length === 0} onChange={(event) => updateIncomeDraft({ income_source_id: event.currentTarget.value })}>
                      {!selectedSource && <option value="">No source active this month</option>}
                      {eligibleSources.map((source) => <option value={source.id} key={source.id}>{source.label}</option>)}
                    </select>
                  </label>
                  <p>{changeKind === 'ending' ? 'Choose the first month you will no longer receive this pay.' : changeKind === 'one_time' ? 'This payment is counted in this month only.' : 'Your new pay starts in this month. Earlier months stay the same.'}</p>
                </div>
                <div hidden={step !== 2}>
                  {changeKind !== 'ending' && <div className="income-question-fields">
                    <label>
                      <span>Amount</span>
                      <div className="income-schedule-money-input">
                        <span aria-hidden="true">$</span>
                        <input ref={amountInputRef} aria-label="Amount" inputMode="decimal" type="number" min={draft.entry_type === 'one_time' ? '0.01' : '0'} step="0.01" value={draft.amount} placeholder={draft.entry_type === 'one_time' ? '500' : '1200'} onChange={(event) => updateIncomeDraft({ amount: event.currentTarget.value })} />
                      </div>
                    </label>
                    {draft.entry_type === 'recurring_change' ? <label>
                      <span>How often you're paid</span>
                      <select value={draft.cadence} onChange={(event) => updateIncomeDraft({ cadence: event.currentTarget.value })}>
                        {cadenceOptions.map(cadence => <option value={cadence} key={cadence}>{titleize(cadence)}</option>)}
                      </select>
                    </label> : <label>
                      <span>Label (optional)</span>
                      <input maxLength={80} value={draft.label} placeholder="Year-end bonus" onChange={(event) => updateIncomeDraft({ label: event.currentTarget.value })} />
                    </label>}
                  </div>}
                  <div className="income-schedule-preview" aria-live="polite">
                    <strong>{previewCopy}</strong>
                    {selectedSource && hasPreviewAmount && <p>{draft.entry_type === 'one_time' ? 'Your regular pay stays the same.' : 'This carries forward until the next saved pay change or the income ends. Earlier months stay the same.'}</p>}
                  </div>
                  {draft.entry_type === 'recurring_change' && <details className="income-advanced" key={`${editingId}-${changeKind}`}>
                    <summary>More income options</summary>
                    <p>For a temporary amount, save this change, then plan another pay change for the month your usual pay returns.</p>
                    {selectedSource?.source_type === 'job' && draft.entry_type === 'recurring_change' && numericAmount > 0 && <label className="income-transition-retention">
                      <input type="checkbox" checked={draft.retained_after_transition} onChange={(event) => updateIncomeDraft({ retained_after_transition: event.currentTarget.checked })} />
                      <span><strong>This job income will continue after my transition</strong><small>Only check this if you will still receive this pay after leaving your main job. Otherwise, {assistantName} leaves it out of your transition plan.</small></span>
                    </label>}
                  </details>}
                </div>
              </fieldset>

              {formError && <p className="setup-error" role="alert">{formError}</p>}

              <div className="income-schedule-form-actions">
                <button type="button" className="secondary-button" disabled={incomeOperationPending} onClick={cancelEdit}>Cancel</button>
                {step > 0 && <button type="button" className="secondary-button" disabled={incomeOperationPending} onClick={() => goToStep(step - 1)}>Back</button>}
                {step < 2 ? <button type="submit" className="income-schedule-submit" disabled={incomeOperationPending}>Continue</button> : <button type="submit" className="income-schedule-submit" disabled={incomeOperationPending || !selectedSource}>{submitLabel}</button>}
              </div>
            </form>
          )}
        </>
      )}
    </section>
  )
}

