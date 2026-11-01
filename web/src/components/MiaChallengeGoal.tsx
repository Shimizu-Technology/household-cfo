import { useState } from 'react'
import { updateChallengeChatCard } from '../api'
import type { ChallengeChatCard } from '../lib/challengeChatCards'
import { savingsDollars, savingsInputCents, savingsInputDollars } from '../lib/savingsChallenge'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import './MiaDailyCheckIn.css'

export function MiaChallengeGoal({ card, onDone, onChangeAmount }: { card: ChallengeChatCard; onDone: () => void; onChangeAmount: (amount: string) => void }) {
  const target = 'target_cents' in card.input ? card.input.target_cents : 0
  const [busy, setBusy] = useState(false)
  const [saved, setSaved] = useState(false)
  const [editing, setEditing] = useState(false)
  const [amount, setAmount] = useState(savingsInputDollars(target))
  const [error, setError] = useState('')
  async function act(action: 'dismiss' | 'approve_goal') {
    if (busy) return
    setBusy(true); setError('')
    try {
      const result = await updateChallengeChatCard(card.id, { action, expected_lock_version: card.lock_version, ...(action === 'approve_goal' ? { accepted: true } : {}) })
      if (action === 'approve_goal') {
        if (!result.record.state.approved_plan_version_id) throw new Error('This goal was replaced or closed. Reopen Ask Mia to review the current goal.')
        setSaved(true)
      } else onDone()
    }
    catch (failure) { setError(participantErrorMessage(failure, 'We couldn’t confirm your choice. Try again; it won’t save twice.')) }
    finally { setBusy(false) }
  }
  if (saved) return <section className="mia-daily-card is-saved" aria-label="Your challenge goal"><h3>Goal saved: {savingsDollars(target)}</h3><p role="status">This is now your goal for the whole 90 days. You can see it in Savings.</p><button type="button" className="mia-daily-dismiss" onClick={onDone}>Done</button></section>
  return <section className="mia-daily-card" aria-label="Your challenge goal" aria-busy={busy}>
    <h3>{savingsDollars(target)} over your 90 days?</h3>
    <p>A cushion to keep surprises off the card. Choose an amount that leaves room for essentials and required payments.</p>
    {editing && <form onSubmit={event => {
      event.preventDefault()
      try { savingsInputCents(amount); onChangeAmount(amount) } catch { setError('Enter an amount like 400.') }
    }}><label>New goal in dollars<input inputMode="decimal" value={amount} onChange={event => setAmount(event.target.value)} disabled={busy} /></label><button type="submit" className="secondary-button" disabled={busy}>Review this amount</button></form>}
    {error && <p role="alert">{error}</p>}
    <div className="mia-daily-actions">
      <button type="button" className="mia-daily-save" disabled={busy} onClick={() => void act('approve_goal')}>{busy ? 'Saving…' : `Yes, set my goal to ${savingsDollars(target)}`}</button>
      <button type="button" className="secondary-button" disabled={busy} onClick={() => setEditing(value => !value)}>Change amount</button>
      <button type="button" className="mia-daily-dismiss" disabled={busy} onClick={() => void act('dismiss')}>Not now</button>
    </div>
    <p className="mia-daily-footnote">Your target changes only when you choose Yes. This doesn’t add saved money.</p>
  </section>
}
