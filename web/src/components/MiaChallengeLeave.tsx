import { useEffect, useRef, useState } from 'react'
import { updateChallengeChatCard, type MiaMessage } from '../api'
import type { ChallengeChatCard } from '../lib/challengeChatCards'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import './MiaDailyCheckIn.css'

export function MiaChallengeLeave({ card, onDone, onConfirmed }: { card: ChallengeChatCard; onDone: () => void; onConfirmed: (message: MiaMessage) => void }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const mounted = useRef(true)
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  const intents = 'intents' in card.input ? card.input.intents : []
  async function act(intent?: 'leave' | 'pause') {
    if (busy) return
    setBusy(true); setError('')
    try {
      const result = await updateChallengeChatCard(card.id, intent
        ? { action: 'request_leave', expected_lock_version: card.lock_version, accepted: true, intent }
        : { action: 'dismiss', expected_lock_version: card.lock_version })
      if (!mounted.current) return
      if (intent) {
        if (result.record.state.leave_intent !== intent || !result.assistant_message) throw new Error('We couldn’t confirm your request. Reopen Mia and check before trying again.')
        onConfirmed(result.assistant_message)
      }
      onDone()
    } catch (failure) { if (mounted.current) setError(participantErrorMessage(failure, 'We couldn’t confirm your choice. Try again; it won’t send twice.')) }
    finally { if (mounted.current) setBusy(false) }
  }
  return <section className="mia-daily-card mia-action-card mia-leave-card" aria-label="Talk with your coach" aria-busy={busy}>
    <h3>Would you like your coach to know?</h3>
    <p>Your coach can talk with you about stepping away. Your challenge and saved record stay as they are until then.</p>
    {error && <p role="alert">{error}</p>}
    <div className="mia-daily-actions">
      {intents.map(intent => <button key={intent} type="button" className="mia-daily-save" disabled={busy} onClick={() => void act(intent)}>Tell my coach I’d like to {intent}</button>)}
      <button type="button" className="mia-daily-dismiss" disabled={busy} onClick={() => void act()}>Not now</button>
    </div>
    <p className="mia-daily-footnote">Only your choice is shared. Your private chat stays private.</p>
  </section>
}
