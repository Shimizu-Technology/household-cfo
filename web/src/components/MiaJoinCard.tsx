import { useLiveMiaResult } from '../lib/useLiveMiaResult'
import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, enrollSavingsChallenge, fetchSavingsChallenge } from '../api'
import { formatRange } from '../lib/plainDates'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import type { SavingsChallenge } from '../lib/savingsChallenge'
import { MiaCardResult } from './MiaCardResult'
import './MiaDailyCheckIn.css'
import './MiaJoinCard.css'

type Props = { onJoined: () => void; onDone: () => void }

// Joining from the chat: the same dates, terms and consent as the join screen.
// She accepts here; nothing is joined before that.
export function MiaJoinCard({ onJoined, onDone }: Props) {
  const [challenge, setChallenge] = useState<SavingsChallenge | null>(null)
  const [loadFailed, setLoadFailed] = useState(false)
  const [participation, setParticipation] = useState(false)
  const [lateAcceptance, setLateAcceptance] = useState(false)
  const [busy, setBusy] = useState(false)
  const [joined, setJoined] = useState(false)
  const liveResult = useLiveMiaResult(joined)
  const [error, setError] = useState('')
  const [attempt, setAttempt] = useState(0)
  // The offer is being fetched again after it changed: nothing on the old one can be accepted meanwhile.
  const [refreshing, setRefreshing] = useState(false)
  const shownDigest = useRef<string | null>(null)
  // One key per exact offer, so a retry after a dropped connection replays instead of joining twice.
  const requestKey = useRef<{ digest: string; key: string } | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  const card = useRef<HTMLElement>(null)

  useEffect(() => {
    const controller = new AbortController()
    fetchSavingsChallenge(controller.signal).then(result => {
      if (controller.signal.aborted) return
      // Boxes she checked belong to the offer she saw; a different offer starts unchecked.
      const digest = result.offer?.acceptance_digest ?? null
      if (digest !== shownDigest.current) { shownDigest.current = digest; setParticipation(false); setLateAcceptance(false) }
      setChallenge(result); setLoadFailed(false); setRefreshing(false)
    }).catch(() => { if (!controller.signal.aborted) { setLoadFailed(true); setRefreshing(false) } })
    return () => controller.abort()
  }, [attempt])

  const offer = challenge?.offer
  const ready = Boolean(offer)
  useEffect(() => { if (ready) card.current?.scrollIntoView?.({ block: 'nearest' }) }, [ready])
  const alreadyIn = Boolean(challenge?.enrollment) && !joined
  // She joined elsewhere while this was loading: tell the parent once and close, whatever the parent does with it.
  const callbacks = useRef({ onJoined, onDone })
  useEffect(() => { callbacks.current = { onJoined, onDone } })
  const announced = useRef(false)
  useEffect(() => {
    if (!alreadyIn || announced.current) return
    announced.current = true
    callbacks.current.onJoined()
    callbacks.current.onDone()
  }, [alreadyIn])

  async function join() {
    if (!offer || busy) return
    setBusy(true); setError('')
    if (requestKey.current?.digest !== offer.acceptance_digest) requestKey.current = { digest: offer.acceptance_digest, key: crypto.randomUUID() }
    try {
      await enrollSavingsChallenge({ participation_accepted: true, policy_version: offer.policy_version, late_start_accepted: lateAcceptance, expected_acceptance_digest: offer.acceptance_digest }, requestKey.current.key)
      setJoined(true)
      onJoined()
      requestAnimationFrame(() => heading.current?.focus())
    } catch (failure) {
      if (failure instanceof ApiRequestError && failure.status === 409) {
        setError('The joining details were updated. Review them and check the box again.')
        setParticipation(false); setLateAcceptance(false); requestKey.current = null
        setRefreshing(true)
        setAttempt(value => value + 1)
      } else {
        setError(participantErrorMessage(failure, 'We couldn’t finish joining. Try again; you won’t join twice.'))
      }
    } finally {
      setBusy(false)
    }
  }

  if (joined) {
    return <section className={`mia-daily-card ui-card is-saved mia-card-result${liveResult}`} aria-label="You joined the challenge"><MiaCardResult title="You’re in. Welcome to the challenge." headingRef={heading} onDone={onDone}><p role="status">Tell me when you set money aside, or ask me to help you choose a comfortable goal.</p></MiaCardResult></section>
  }
  if (alreadyIn) return null
  if (loadFailed) {
    return <section className="mia-daily-card mia-action-card mia-join-card ui-card" aria-label="Join the challenge"><h3>Join the 90-day savings challenge</h3><p role="alert">We couldn’t load the joining details. Nothing changed.</p><div className="mia-daily-actions"><button type="button" className="secondary-button ui-btn ui-btn--tonal" onClick={() => { setLoadFailed(false); setRefreshing(true); setAttempt(value => value + 1) }}>Try again</button><button type="button" className="mia-daily-dismiss ui-btn ui-btn--text" onClick={onDone}>Not now</button></div></section>
  }
  if (!challenge || !offer) return <section className="mia-daily-card mia-action-card mia-join-card ui-card" aria-label="Join the challenge" aria-busy="true"><h3>Join the 90-day savings challenge</h3><p role="status">Getting your joining details…</p></section>

  const needsLate = Boolean(offer.late_start_acceptance_required)
  return <section ref={card} className="mia-daily-card mia-action-card mia-join-card ui-card" aria-label="Join the challenge" aria-busy={busy}>
    <h3>Join the 90-day savings challenge</h3>
    <p><strong>Your 90 days: {offer.personal_starts_on && offer.personal_ends_on ? formatRange(offer.personal_starts_on, offer.personal_ends_on) : 'dates not set yet'}</strong><br /><span className="mia-daily-hint">{offer.cohort_label}</span></p>
    <p className="mia-daily-hint">You approve each amount; the app doesn’t move money. A bank link, statements and a full budget are optional. Your records stay private unless you share them.</p>
    <fieldset className="mia-card-checks" disabled={busy || refreshing || !offer.accepting_enrollments}>
      <label className="mia-card-check ui-check"><input type="checkbox" checked={participation} onChange={event => setParticipation(event.target.checked)} /><span>I’ve read this and accept joining the challenge.</span></label>
      {needsLate && <label className="mia-card-check ui-check"><input type="checkbox" checked={lateAcceptance} onChange={event => setLateAcceptance(event.target.checked)} /><span>I accept that my 90 days start later than the group’s, as shown above.</span></label>}
    </fieldset>
    {!offer.accepting_enrollments && <p role="status">This group isn’t taking new members right now.</p>}
    {error && <p role="alert">{error}</p>}
    {refreshing && <p role="status">Getting the updated joining details…</p>}
    <div className="mia-daily-actions">
      <button type="button" className="mia-daily-save ui-btn ui-btn--primary" disabled={busy || refreshing || !offer.accepting_enrollments || !participation || (needsLate && !lateAcceptance)} onClick={() => void join()}>{busy ? 'Joining…' : 'Accept and join'}</button>
      <button type="button" className="mia-daily-dismiss ui-btn ui-btn--text" disabled={busy} onClick={onDone}>Not now</button>
    </div>
    <p className="mia-daily-footnote">You’re not joined until you tap Accept and join.</p>
  </section>
}
