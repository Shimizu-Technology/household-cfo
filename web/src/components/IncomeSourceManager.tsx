import { useEffect, useRef, useState, type FormEvent, type Ref } from 'react'
import type { IncomeTimelineSource, IncomeSourceInput, MiaActionItem } from '../api'
import { payloadHas, proposedText, proposedMoney, proposedChoice } from '../lib/miaManualPrefill'
import { useIncomeForm, type IncomeSourceFocusRequest } from './incomeFormState'
import { currency, titleize, formatMonthYear, guamCurrentMonthIso, cadenceOptions, effectiveIncomeTerms, monthlyIncomeAmount, incomeSourceIsCurrent, nextIncomeChange } from './incomeDisplay'
import './IncomeForms.css'

const incomeSourceTypeOptions = ['job', 'business', 'rental', 'passive', 'bonus', 'other']

type IncomeSourceDraft = {
  label: string
  source_type: string
  amount: string
  cadence: string
  starts_on: string
}

function blankIncomeSourceDraft(): IncomeSourceDraft {
  const currentMonth = guamCurrentMonthIso()
  return {
    label: '',
    source_type: 'job',
    amount: '',
    cadence: 'monthly',
    starts_on: `${currentMonth}-01`,
  }
}

function incomeSourceDraftFor(source: IncomeTimelineSource): IncomeSourceDraft {
  return {
    label: source.label,
    source_type: source.source_type,
    amount: String(source.base_amount),
    cadence: source.base_cadence,
    starts_on: source.starts_on || blankIncomeSourceDraft().starts_on,
  }
}

function incomeSourceDraftWithProposal(base: IncomeSourceDraft, payload: MiaActionItem['payload']): IncomeSourceDraft {
  return {
    label: proposedText(payload, 'label', base.label),
    source_type: proposedChoice(payload, 'source_type', base.source_type, incomeSourceTypeOptions),
    amount: proposedMoney(payload, 'amount_cents', base.amount),
    cadence: proposedChoice(payload, 'cadence', base.cadence, ['weekly', 'biweekly', 'semi_monthly', 'monthly', 'annual']),
    starts_on: proposedText(payload, 'starts_on', base.starts_on),
  }
}

export function IncomeSourceManager({
  sectionRef,
  sources,
  action,
  error,
  onSave,
  onArchive,
  onRestore,
  focusRequest,
  onFocusRequestHandled,
  onUnsavedChangesChange,
}: {
  sectionRef?: Ref<HTMLElement>
  sources: IncomeTimelineSource[]
  action: string | null
  error: string | null
  onSave: (values: IncomeSourceInput, sourceId?: number) => Promise<void>
  onArchive: (source: IncomeTimelineSource, endsOn: string) => Promise<void>
  onRestore: (source: IncomeTimelineSource) => Promise<void>
  focusRequest?: IncomeSourceFocusRequest | null
  onFocusRequestHandled?: () => void
  onUnsavedChangesChange?: (dirty: boolean) => void
}) {
  const { open: formOpen, setOpen: setFormOpen, blocked: editorBlocked } = useIncomeForm('source')
  const { setOpen: setEndingOpen } = useIncomeForm('ending')
  const [draft, setDraft] = useState<IncomeSourceDraft>(() => blankIncomeSourceDraft())
  const [draftBaseline, setDraftBaseline] = useState<IncomeSourceDraft>(() => blankIncomeSourceDraft())
  const [editingId, setEditingId] = useState<number | null>(null)
  const [endingId, setEndingId] = useState<number | null>(null)
  const [endingMonth, setEndingMonth] = useState('')
  const [formError, setFormError] = useState<string | null>(null)
  const sourceFormRef = useRef<HTMLFormElement | null>(null)
  const sourceNameRef = useRef<HTMLInputElement | null>(null)
  const endMonthRef = useRef<HTMLInputElement | null>(null)
  const lastActionTriggerRef = useRef<HTMLButtonElement | null>(null)
  const sourceCardRefs = useRef(new Map<number, HTMLElement>())
  const handledFocusKeyRef = useRef<number | null>(null)

  const hasUnsavedChanges = endingId !== null || Object.entries(draftBaseline).some(([key, value]) => draft[key as keyof IncomeSourceDraft] !== value)
  useEffect(() => {
    onUnsavedChangesChange?.(hasUnsavedChanges)
    return () => onUnsavedChangesChange?.(false)
  }, [hasUnsavedChanges, onUnsavedChangesChange])

  useEffect(() => {
    if (!focusRequest || handledFocusKeyRef.current === focusRequest.key) return
    handledFocusKeyRef.current = focusRequest.key
    const source = sources.find((candidate) => candidate.id === focusRequest.sourceId)
    requestAnimationFrame(() => {
      if (focusRequest.actionType === 'create_income_source') {
        setFormOpen(true)
        setDraftBaseline(blankIncomeSourceDraft()); setDraft(incomeSourceDraftWithProposal(blankIncomeSourceDraft(), focusRequest.payload)); setEditingId(null); setEndingId(null); setFormError(null); lastActionTriggerRef.current = null
        requestAnimationFrame(() => sourceNameRef.current?.focus())
      } else if (focusRequest.actionType === 'update_income_source' && source) {
        setFormOpen(true)
        setEndingId(null); setEditingId(source.id); setDraftBaseline(incomeSourceDraftFor(source)); setDraft(incomeSourceDraftWithProposal(incomeSourceDraftFor(source), focusRequest.payload)); setFormError(null)
        requestAnimationFrame(() => { sourceFormRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' }); sourceNameRef.current?.focus({ preventScroll: true }); sourceNameRef.current?.select() })
      } else if (focusRequest.actionType === 'archive_income_source' && source) {
        setFormOpen(false)
        setEndingOpen(true)
        const blank = blankIncomeSourceDraft()
        setDraftBaseline(blank); setDraft(blank); setEditingId(null); setEndingId(source.id); setEndingMonth(''); setFormError(null)
        requestAnimationFrame(() => endMonthRef.current?.focus())
        if (payloadHas(focusRequest.payload, 'ends_on')) setEndingMonth(proposedText(focusRequest.payload, 'ends_on', '').slice(0, 7))
      } else if (focusRequest.actionType === 'restore_income_source' && source) {
        const target = sourceCardRefs.current.get(source.id)?.querySelector<HTMLButtonElement>('[data-income-source-action="restore"]')
        target?.scrollIntoView({ behavior: 'smooth', block: 'center' })
        target?.focus({ preventScroll: true })
      }
      onFocusRequestHandled?.()
    })
  }, [focusRequest, onFocusRequestHandled, sources, setFormOpen, setEndingOpen])

  function focusSourceCard(sourceId: number) {
    requestAnimationFrame(() => sourceCardRefs.current.get(sourceId)?.focus())
  }

  function resetForm() {
    const blank = blankIncomeSourceDraft()
    setDraftBaseline(blank)
    setDraft(blank)
    setEditingId(null)
    setFormOpen(false)
    setFormError(null)
    lastActionTriggerRef.current = null
  }

  function beginEdit(source: IncomeTimelineSource, trigger?: HTMLButtonElement) {
    if (editorBlocked) return
    if (hasUnsavedChanges) { setFormError('Save or cancel this income draft before editing another source.'); return }
    setFormOpen(true)
    lastActionTriggerRef.current = trigger ?? null
    setEndingId(null)
    setEditingId(source.id)
    setDraftBaseline(incomeSourceDraftFor(source))
    setDraft(incomeSourceDraftFor(source))
    setFormError(null)
    requestAnimationFrame(() => {
      sourceFormRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      sourceNameRef.current?.focus({ preventScroll: true })
      sourceNameRef.current?.select()
    })
  }

  function cancelEdit() {
    const trigger = lastActionTriggerRef.current
    resetForm()
    requestAnimationFrame(() => trigger?.focus())
  }

  function beginEnd(sourceId: number, trigger?: HTMLButtonElement) {
    if (editorBlocked) return
    if (hasUnsavedChanges) { setFormError('Save or cancel this income draft before ending a source.'); return }
    const blank = blankIncomeSourceDraft()
    setDraftBaseline(blank)
    setDraft(blank)
    lastActionTriggerRef.current = trigger ?? null
    setEditingId(null)
    setFormOpen(false)
    setEndingOpen(true)
    setEndingId(sourceId)
    setEndingMonth('')
    setFormError(null)
    requestAnimationFrame(() => endMonthRef.current?.focus())
  }

  function cancelEnd() {
    const trigger = lastActionTriggerRef.current
    setEndingId(null)
    setEndingOpen(false)
    setEndingMonth('')
    setFormError(null)
    requestAnimationFrame(() => trigger?.focus())
  }

  function updateSourceDraft(values: Partial<IncomeSourceDraft>) {
    setDraft((current) => ({ ...current, ...values }))
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!draft.label.trim() || !draft.amount || !draft.starts_on) {
      setFormError('Add a name, amount, and starting month.')
      return
    }

    setFormError(null)
    try {
      await onSave({
        label: draft.label.trim(),
        source_type: draft.source_type,
        amount: draft.amount,
        cadence: draft.cadence,
        starts_on: `${draft.starts_on.slice(0, 7)}-01`,
      }, editingId ?? undefined)
      resetForm()
    } catch {
      // The server-owned validation message is shown above this manager.
    }
  }

  async function confirmEnd(source: IncomeTimelineSource) {
    if (!endingMonth) {
      setFormError('Choose the first month without this income.')
      return
    }

    setFormError(null)
    try {
      await onArchive(source, `${endingMonth.slice(0, 7)}-01`)
      setEndingId(null)
      setEndingOpen(false)
      setEndingMonth('')
      lastActionTriggerRef.current = null
      focusSourceCard(source.id)
    } catch {
      // The server-owned validation message is shown above this manager.
    }
  }

  async function restoreSource(source: IncomeTimelineSource) {
    try {
      await onRestore(source)
      focusSourceCard(source.id)
    } catch {
      // The server-owned validation message is shown above this manager.
    }
  }

  const incomeOperationPending = Boolean(action)
  const saving = action === 'create-income-source' || (editingId !== null && action === `update-income-source:${editingId}`)

  return (
    <section ref={sectionRef} className="panel income-source-manager" aria-labelledby="income-source-manager-title">
      <div className="income-source-manager-heading">
        <div>
          <h3 id="income-source-manager-title">Your income</h3>
          <p>Your usual pay and the next change for each source.</p>
        </div>
        <strong>{sources.length === 0 ? 'Income not entered' : `${currency.format(sources.filter(incomeSourceIsCurrent).reduce((total, source) => total + monthlyIncomeAmount(source), 0))} current monthly`}</strong>
      </div>

      {error && <p className="setup-error" role="alert">{error}</p>}

      {sources.length === 0 ? (
        <p className="income-source-empty">No income sources yet. Add the first one below.</p>
      ) : (
        <div className="income-source-manager-list">
          {sources.map((source) => {
            const upcoming = nextIncomeChange(source)
            const archivedWithoutBoundary = source.timeline_status === 'archived' && !source.ends_on
            const ended = Boolean(source.ends_on) || archivedWithoutBoundary
            const currentMonth = guamCurrentMonthIso()
            const canUndoEnd = Boolean(source.ends_on && source.ends_on.slice(0, 7) >= currentMonth)
            const canceledBeforeStart = Boolean(
              source.timeline_status === 'archived'
              && source.starts_on
              && source.ends_on
              && source.starts_on.slice(0, 7) === source.ends_on.slice(0, 7),
            )
            const effectiveTerms = effectiveIncomeTerms(source)
            return (
              <article
                ref={(node) => {
                  if (node) sourceCardRefs.current.set(source.id, node)
                  else sourceCardRefs.current.delete(source.id)
                }}
                className={`income-source-manager-card${ended && !incomeSourceIsCurrent(source) ? ' is-ended' : ''}`}
                key={source.id}
                tabIndex={-1}
              >
                <div className="income-source-manager-card-heading">
                  <div>
                    <span>{titleize(source.source_type)}</span>
                    <strong>{source.label}</strong>
                  </div>
                  <b>{currency.format(effectiveTerms.amount)} · {titleize(effectiveTerms.cadence)}</b>
                </div>
                <dl>
                  <div><dt>Started</dt><dd>{source.starts_on ? formatMonthYear(source.starts_on) : 'Before timeline'}</dd></div>
                  <div><dt>Status</dt><dd>{archivedWithoutBoundary ? 'Archived' : canceledBeforeStart ? `Canceled before ${formatMonthYear(source.starts_on!)}` : source.ends_on ? `$0 beginning ${formatMonthYear(source.ends_on)}` : source.starts_on && source.starts_on.slice(0, 7) > currentMonth ? `Starts ${formatMonthYear(source.starts_on)}` : 'Current'}</dd></div>
                  <div><dt>Next change</dt><dd>{upcoming ? `${formatMonthYear(upcoming.effective_on)} · ${currency.format(upcoming.amount)}` : 'None scheduled'}</dd></div>
                </dl>
                <div className="income-source-manager-actions">
                  {ended && canUndoEnd ? (
                    <button type="button" data-income-source-action="restore" className="secondary-button" aria-label={`Restore ${source.label}`} disabled={incomeOperationPending || editorBlocked} onClick={() => void restoreSource(source)}>
                      {action === `restore-income-source:${source.id}` ? 'Restoring' : 'Restore source'}
                    </button>
                  ) : ended ? (
                    <small>To receive this income again, add it as a new source below.</small>
                  ) : endingId === source.id ? (
                    <div className="income-source-end-confirmation">
                      <label>
                        <span>First month without this income</span>
                        <input ref={endMonthRef} disabled={incomeOperationPending} type="month" min="2000-01" max="2100-12" value={endingMonth} onChange={(event) => setEndingMonth(event.currentTarget.value)} />
                      </label>
                      {formError && <p className="setup-error" role="alert">{formError}</p>}
                      <button type="button" className="secondary-button" aria-label={`Cancel ending ${source.label}`} disabled={incomeOperationPending} onClick={cancelEnd}>Cancel</button>
                      <button type="button" className="income-schedule-submit" aria-label={`Confirm stop for ${source.label}`} disabled={incomeOperationPending} onClick={() => void confirmEnd(source)}>
                        {action === `archive-income-source:${source.id}` ? 'Ending' : 'Confirm stop'}
                      </button>
                    </div>
                  ) : (
                    <>
                      <details className="income-advanced">
                        <summary>More options for {source.label}</summary>
                        <div className="income-source-advanced-actions">
                      <button type="button" className="secondary-button" aria-label={`Edit ${source.label}`} disabled={incomeOperationPending || editorBlocked} onClick={(event) => beginEdit(source, event.currentTarget)}>Edit</button>
                      <button type="button" className="secondary-button" aria-label={`End ${source.label}`} disabled={incomeOperationPending || editorBlocked} onClick={(event) => beginEnd(source.id, event.currentTarget)}>End source</button>
                        </div>
                      </details>
                    </>
                  )}
                </div>
              </article>
            )
          })}
        </div>
      )}

      {!formOpen && <button type="button" disabled={incomeOperationPending || editorBlocked} className="secondary-button" onClick={() => { setFormOpen(true); requestAnimationFrame(() => sourceNameRef.current?.focus()) }}>Add income source</button>}
      {formOpen && <form ref={sourceFormRef} className="income-source-form" onSubmit={(event) => void submit(event)}>
        <div className="income-source-form-heading">
          <div>
            <span>{editingId === null ? 'Add income source' : 'Edit income source'}</span>
            <strong>{editingId === null ? 'What money comes into this household?' : 'Correct the starting details.'}</strong>
          </div>
          <p>{editingId === null ? 'Your pay repeats from the starting month until you change it.' : 'This corrects the original pay record. For a raise, cancel and choose Plan an income change.'}</p>
        </div>
        <fieldset className="income-source-fields budget-loading-boundary" style={{ border: 0 }} disabled={incomeOperationPending}><legend className="sr-only">Income source fields</legend>
          <label>
            <span>Name</span>
            <input ref={sourceNameRef} name="income_source_label" maxLength={120} value={draft.label} placeholder="Primary salary" onChange={(event) => updateSourceDraft({ label: event.currentTarget.value })} />
          </label>
          <label>
            <span>Type</span>
            <select value={draft.source_type} onChange={(event) => updateSourceDraft({ source_type: event.currentTarget.value })}>
              {incomeSourceTypeOptions.map((type) => <option value={type} key={type}>{titleize(type)}</option>)}
            </select>
          </label>
          <label>
            <span>Starting amount</span>
            <div className="income-schedule-money-input">
              <span aria-hidden="true">$</span>
              <input aria-label="Starting amount" type="number" min="0" step="0.01" value={draft.amount} placeholder="5000" onChange={(event) => updateSourceDraft({ amount: event.currentTarget.value })} />
            </div>
          </label>
          <label>
            <span>How often you're paid</span>
            <select value={draft.cadence} onChange={(event) => updateSourceDraft({ cadence: event.currentTarget.value })}>
              {cadenceOptions.filter((cadence) => cadence !== 'one_time').map((cadence) => <option value={cadence} key={cadence}>{titleize(cadence)}</option>)}
            </select>
          </label>
          <label>
            <span>Starting month</span>
            <input type="month" min="2000-01" max="2100-12" value={draft.starts_on.slice(0, 7)} onChange={(event) => updateSourceDraft({ starts_on: `${event.currentTarget.value}-01` })} />
          </label>
        </fieldset>
        {formError && <p className="setup-error" role="alert">{formError}</p>}
        <div className="income-source-form-actions">
          {endingId === null && <button type="button" className="secondary-button" disabled={incomeOperationPending} onClick={cancelEdit}>Cancel</button>}
          <button type="submit" className="income-schedule-submit" disabled={incomeOperationPending}>{saving ? 'Saving' : editingId === null ? 'Add source' : 'Save source'}</button>
        </div>
      </form>}
    </section>
  )
}

