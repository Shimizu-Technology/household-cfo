import { useEffect, useRef, useState } from 'react'
import { MiaCardResult } from './MiaCardResult'
import { updateChallengeChatCard } from '../api'
import type { ChallengeChatCard } from '../lib/challengeChatCards'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { savingsPlainDollars, type SavingsIntake } from '../lib/savingsChallenge'
import './MiaDailyCheckIn.css'

// "Today", "Yesterday", or "Mon, Oct 20".
function plainDay(iso: string, today?: string): string {
  if (!iso) return 'Choose date'
  if (today && iso === today) return 'Today'
  if (today) {
    const yesterday = new Date(`${today}T00:00:00Z`)
    yesterday.setUTCDate(yesterday.getUTCDate() - 1)
    if (iso === yesterday.toISOString().slice(0, 10)) return 'Yesterday'
  }
  return new Intl.DateTimeFormat('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(`${iso}T00:00:00Z`))
}

type Props = {
  intake: SavingsIntake
  today?: string
  onReview: () => void
  // With the saved card, she can approve right here. Without it (or while the
  // day is still unknown) the card sends her to Savings, as before.
  card?: ChallengeChatCard
  onApproved?: () => void
  onDismissed?: () => void
}

export function MiaSavingsReview({ intake, today, onReview, card, onApproved, onDismissed }: Props) {
  const [busy, setBusy] = useState(false)
  const section = useRef<HTMLElement>(null)
  const [saved, setSaved] = useState(false)
  const [newMoney, setNewMoney] = useState(false)
  const [error, setError] = useState('')
  const amount = savingsPlainDollars(intake.amount_cents)
  const original = intake.correction?.current_approved_version
  const withdrawal = intake.kind === 'withdrawal'
  const title = original ? `Replace ${savingsPlainDollars(original.signed_cents)} with ${amount}` : intake.kind === 'purchase' ? `${amount} at ${intake.merchant}` : withdrawal ? `${amount} taken out` : `${amount} set aside`
  const inPlace = Boolean(card) && intake.kind !== 'purchase' && Boolean(intake.effective_on) && !intake.date_required
  const needsNewMoney = inPlace && !withdrawal && !intake.correction
  // A card Mia just made shows its question and its answer without scrolling.
  useEffect(() => { if (inPlace) section.current?.scrollIntoView?.({ block: 'nearest' }) }, [inPlace])

  async function act(action: 'approve_savings' | 'dismiss') {
    if (!card || busy) return
    setBusy(true); setError('')
    try {
      if (action === 'dismiss') {
        await updateChallengeChatCard(card.id, { action: 'dismiss', expected_lock_version: card.lock_version })
        onDismissed?.()
      } else {
        await updateChallengeChatCard(card.id, { action, expected_lock_version: card.lock_version, accepted: true, ...(needsNewMoney ? { new_money_confirmed: true } : {}) })
        setSaved(true)
      }
    } catch (failure) {
      setError(participantErrorMessage(failure, 'We couldn’t confirm that. Try again; it won’t save twice.'))
    } finally {
      setBusy(false)
    }
  }

  if (saved) {
    return <section className="mia-daily-card ui-card is-saved mia-card-result" aria-label="Savings saved"><MiaCardResult title={withdrawal ? `${amount} taken out` : original ? `Fixed: now ${amount}` : `${amount} added`} onDone={() => onApproved?.()}><p role="status">{withdrawal ? 'Saved. Your total is up to date.' : 'Saved to your challenge. Your total is up to date.'}</p></MiaCardResult></section>
  }

  if (inPlace) {
    return <section ref={section} className="mia-daily-card mia-action-card ui-card" aria-label="Savings to check" aria-busy={busy}>
      <h3>{title} · {plainDay(intake.effective_on, today)}</h3>
      <p>{withdrawal ? 'This takes the money out of your challenge total. Nothing changes until you tap Yes.' : original ? 'This replaces the earlier amount in your total. Nothing changes until you tap Yes.' : 'Only new money you set aside counts. Nothing is saved until you tap Yes.'}</p>
      {needsNewMoney && <label className="mia-card-check ui-check"><input type="checkbox" checked={newMoney} disabled={busy} onChange={event => setNewMoney(event.target.checked)} /><span>This was new money I set aside after expenses, not borrowed or money I already had.</span></label>}
      {error && <p role="alert">{error}</p>}
      <div className="mia-daily-actions ui-actions ui-actions--long">
        <button type="button" className="mia-daily-save ui-btn ui-btn--primary" disabled={busy || (needsNewMoney && !newMoney)} onClick={() => void act('approve_savings')}>{busy ? 'Saving…' : withdrawal ? `Yes, take out ${amount}` : original ? `Yes, change it to ${amount}` : `Yes, add ${amount}`}</button>
        <button type="button" className="secondary-button ui-btn ui-btn--tonal" disabled={busy} onClick={event => { event.currentTarget.focus(); onReview() }}>Open in Savings</button>
        <button type="button" className="mia-daily-dismiss ui-btn ui-btn--text" disabled={busy} onClick={() => void act('dismiss')}>Not now</button>
      </div>
    </section>
  }

  return <section className="daily-note ui-card" aria-label="Savings to check"><strong>{title} · {plainDay(intake.effective_on, today)}</strong><p>{intake.kind==='purchase' ? 'Check it, then save it in Today. Nothing is saved until you do.' : withdrawal ? 'Check it, then save it to your challenge. Nothing changes until you do.' : 'Check it, then save it to your challenge. Only new money you set aside counts, and nothing is saved until you do.'}</p><button type="button" className="secondary-button ui-btn ui-btn--tonal" onClick={event=>{event.currentTarget.focus();onReview()}}>{intake.kind==='purchase'?'Review purchase':'Review savings'}</button></section>
}
