import { miaReviewResult } from '../lib/miaReviewResult'
import { useEffect, useRef, useState } from 'react'
import type { MiaActionDraft } from '../api'
import './MiaDailyCheckIn.css'

type Props = {
  draft: MiaActionDraft
  action: string | null
  disabled: boolean
  onApply: (draft: MiaActionDraft) => void
  onCancel: (draft: MiaActionDraft) => void
  onChoose: (draft: MiaActionDraft, option: number) => Promise<boolean>
}

// Mia's card for a purchase she already confirmed: which one, then exactly
// what changes and how Budget moves. Nothing changes until she taps Yes.
export function MiaPurchaseChangeCard({ draft, action, disabled, onApply, onCancel, onChoose }: Props) {
  const change = draft.purchase_change
  const heading = useRef<HTMLHeadingElement>(null)
  const card = useRef<HTMLElement>(null)
  const [choosing, setChoosing] = useState<number | null>(null)
  const [error, setError] = useState('')
  const mode = change?.mode
  const first = useRef(true)
  // A card Mia just made scrolls into view; one reloaded with the history stays where it is.
  const createdAt = draft.created_at
  useEffect(() => {
    const fresh = createdAt ? Date.now() - Date.parse(createdAt) < 90_000 : false
    if (fresh) card.current?.scrollIntoView?.({ block: 'nearest' })
  }, [createdAt])
  // The card turns into the change card after a choice; keep her place on it.
  useEffect(() => {
    if (first.current) { first.current = false; return }
    heading.current?.focus({ preventScroll: true })
  }, [mode])
  if (!change) return null
  const locked = disabled || action !== null
  const applying = action === `apply-mia-action:${draft.id}`
  const canceling = action === `cancel-mia-action:${draft.id}`
  const title = change.mode === 'choose' ? 'Which purchase do you mean?' : change.void ? `Take ${change.merchant} out of your spending?` : `Change your ${change.merchant} purchase?`

  if (draft.status !== 'pending' && draft.status !== 'partially_applied') return <section className="mia-daily-card ui-card is-finished" aria-label={change.mode === 'choose' ? 'Which purchase' : title}>
    <h3 ref={heading} tabIndex={-1}>{title}</h3>
    <p className="mia-review-result" role="status">{miaReviewResult(draft)}</p>
  </section>

  if (change.mode === 'choose') {
    return (
      <section ref={card} className="mia-daily-card mia-action-card mia-purchase-card ui-card" aria-label="Which purchase" aria-busy={choosing !== null}>
        <h3 ref={heading} tabIndex={-1}>Which purchase do you mean?</h3>
        <ul className="mia-purchase-options">
          {change.options.map((option) => (
            <li key={option.index}>
              <button type="button" className="secondary-button ui-btn ui-btn--tonal" disabled={locked || choosing !== null} onClick={async () => {
                setChoosing(option.index); setError('')
                const ok = await onChoose(draft, option.index)
                if (!ok) setError('I couldn’t open that one. Please try again. Nothing changed.')
                setChoosing(null)
              }}>{option.label}</button>
            </li>
          ))}
        </ul>
        {error && <p role="alert">{error}</p>}
        <p className="mia-daily-footnote">Nothing has changed yet.</p>
        <div className="mia-daily-actions ui-actions">
          <button type="button" className="mia-daily-dismiss ui-btn ui-btn--text" disabled={locked} onClick={() => onCancel(draft)}>{canceling ? 'Closing…' : 'Not now'}</button>
        </div>
      </section>
    )
  }

  return (
    <section ref={card} className="mia-daily-card mia-action-card mia-purchase-card ui-card" aria-label={title} aria-busy={applying}>
      <h3 ref={heading} tabIndex={-1}>{title}</h3>
      <p className="mia-purchase-which">{change.date_label}{change.void ? ` · ${change.amount}` : ''}</p>
      {change.rows.length > 0 && (
        <dl className="mia-purchase-rows">
          {change.rows.map((row) => (
            <div key={row.label}><dt>{row.label}</dt><dd><span className="mia-purchase-before">{row.before}</span><span aria-hidden="true"> → </span><span className="sr-only"> becomes </span><strong>{row.after}</strong></dd></div>
          ))}
        </dl>
      )}
      {change.effects.length > 0 && (
        <div className="mia-purchase-effects">
          <p className="mia-daily-status">How Budget moves</p>
          <ul>{change.effects.map((line) => <li key={line}>{line}</li>)}</ul>
        </div>
      )}
      {draft.stale && <p className="mia-action-stale-note" role="status">That purchase changed after this card was made, so it can’t be applied. Nothing was changed.</p>}
      <div className="mia-daily-actions ui-actions">
        <button type="button" className="mia-daily-save ui-btn ui-btn--primary" disabled={locked || Boolean(draft.stale)} onClick={() => onApply(draft)}>{applying ? 'Saving…' : change.void ? 'Yes, take it out' : 'Yes, change it'}</button>
        <button type="button" className="mia-daily-dismiss ui-btn ui-btn--text" disabled={locked} onClick={() => onCancel(draft)}>{canceling ? 'Closing…' : 'Not now'}</button>
      </div>
      <p className="mia-daily-footnote">Nothing changes until you tap Yes. {change.note}</p>
    </section>
  )
}
