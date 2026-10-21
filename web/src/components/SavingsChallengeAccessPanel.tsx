import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, changeSavingsChallengeAccess, createCohortReleaseRequestId } from '../api'
import type { AdminCohort, SavingsChallengeAccess } from '../api'
import { Button } from './Button'
import './SavingsChallengeAccessPanel.css'

type Review = { action: 'open' | 'pause'; requestId: string; expectedState: SavingsChallengeAccess['state'] }

const MIN_REASON = 5
const MAX_REASON = 500

const stateCopy: Record<SavingsChallengeAccess['state'], string> = {
  not_set_up: 'Participants cannot see the challenge yet. These steps are still needed:',
  ready: 'Everything is in place. Participants will not see the challenge until you open it.',
  open: 'Participants can read the terms, join, and record money they set aside.',
  paused: 'The challenge is paused. Participants cannot join or add anything until you reopen it. Nothing already saved is deleted.',
}

/**
 * Status and audited controls for the 90-day Savings Challenge on one cohort.
 * Everyone who can manage the cohort sees the status; only a platform administrator can change it.
 */
export function SavingsChallengeAccessPanel({ cohort, busy, onChanged, onDirtyChange, onPendingChange }: {
  cohort: AdminCohort
  busy: boolean
  onChanged: () => Promise<void> | void
  onDirtyChange?: (dirty: boolean) => void
  onPendingChange?: (pending: boolean) => void
}) {
  const challenge = cohort.savings_challenge
  const [review, setReview] = useState<Review | null>(null)
  const [reason, setReason] = useState('')
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const reviewHeadingRef = useRef<HTMLHeadingElement | null>(null)
  const sectionRef = useRef<HTMLElement | null>(null)

  useEffect(() => { if (review) reviewHeadingRef.current?.focus() }, [review])

  useEffect(() => { onDirtyChange?.(review !== null) }, [review, onDirtyChange])
  useEffect(() => () => onDirtyChange?.(false), [onDirtyChange])
  useEffect(() => { onPendingChange?.(pending) }, [pending, onPendingChange])
  useEffect(() => () => onPendingChange?.(false), [onPendingChange])

  if (!challenge) return null

  const trimmed = reason.trim()
  const reasonValid = trimmed.length >= MIN_REASON && trimmed.length <= MAX_REASON
  const places = `${challenge.participant_count} of ${challenge.capacity} places taken`
  const canChange = Boolean(challenge.can_change)

  function begin(action: 'open' | 'pause') {
    if (!challenge) return
    setError(null)
    setNotice(null)
    setReason('')
    setReview({ action, requestId: createCohortReleaseRequestId(), expectedState: challenge.state })
  }

  function cancel() {
    if (pending) return
    setReview(null)
    setError(null)
    window.requestAnimationFrame(() => sectionRef.current?.querySelector<HTMLElement>('[data-challenge-trigger]')?.focus())
  }

  async function confirm() {
    if (!review || !challenge || !reasonValid || pending || busy) return
    setPending(true)
    setError(null)
    try {
      await changeSavingsChallengeAccess(cohort.id, review.action, {
        reason: trimmed,
        ...(review.action === 'open' ? { expected_state: review.expectedState } : {}),
      }, review.requestId)
      setNotice(review.action === 'open'
        ? 'The challenge is open. Participants can now join.'
        : 'The challenge is paused. Participants cannot add anything until you reopen it.')
      setReview(null)
      await onChanged()
    } catch (caught) {
      setError(caught instanceof ApiRequestError || caught instanceof Error ? caught.message : 'The change could not be confirmed. Reload and check the status before trying again.')
      // Show what is actually true now; the same request id keeps a retry safe.
      await onChanged()
    } finally {
      setPending(false)
    }
  }

  const tone = challenge.state === 'open' ? 'green' : challenge.state === 'not_set_up' ? 'neutral' : 'gold'
  return (
    <section ref={sectionRef} className="challenge-access" aria-labelledby={`challenge-access-${cohort.id}`}>
      <div className="challenge-access-head">
        <div>
          <p>90-day Savings Challenge</p>
          <h4 id={`challenge-access-${cohort.id}`}>Challenge status</h4>
        </div>
        <span className={`admin-badge ${tone}`} role="status">{challenge.label}</span>
      </div>
      <p className="challenge-access-places">{places}</p>
      <p>{stateCopy[challenge.state]}</p>
      {challenge.blockers.length > 0 && challenge.state !== 'paused' && (
        <ul className="challenge-access-blockers">{challenge.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul>
      )}
      {challenge.state === 'open' && challenge.blockers.length > 0 && <p role="alert">Participants may be unable to join until the items above are fixed.</p>}
      {challenge.participant_count > challenge.capacity && <p role="alert">This cohort has more invited participants than the challenge has places.</p>}
      {notice && <p className="challenge-access-notice" role="status">{notice}</p>}
      {error && <p className="challenge-access-error" role="alert">{error}</p>}

      {review ? (
        <div className="challenge-access-review" role="group" aria-labelledby="challenge-access-review-heading">
          <h4 id="challenge-access-review-heading" ref={reviewHeadingRef} tabIndex={-1}>
            {review.action === 'open' ? 'Open the challenge to participants?' : 'Pause the challenge?'}
          </h4>
          {review.action === 'open' ? (
            <>
              <p>The {challenge.participant_count} invited {challenge.participant_count === 1 ? 'participant' : 'participants'} in {cohort.name}, and anyone you invite later, will be able to:</p>
              <ul>
                <li>See the 90-day Savings Challenge, read how it works, and choose to join.</li>
                <li>Pick a comfortable target (suggested $500; smaller or later is fine).</li>
                <li>Record money they set aside, each one reviewed and approved by them first.</li>
              </ul>
              <p>The challenge has {challenge.capacity} places. You can pause it at any time.</p>
            </>
          ) : (
            <>
              <p>Right away, participants in {cohort.name} will no longer be able to:</p>
              <ul>
                <li>Join the challenge, or record and approve new savings.</li>
                <li>Use the challenge screens until it is reopened.</li>
              </ul>
              <p>Nothing already saved is deleted, and you can reopen it later.</p>
            </>
          )}
          <label className="admin-field wide">
            <span>Reason (required, recorded with your name)</span>
            <textarea rows={2} maxLength={MAX_REASON} value={reason} disabled={pending} onChange={(event) => setReason(event.target.value)} placeholder={review.action === 'open' ? 'For example: kickoff session is today' : 'For example: fixing a bug before more people join'} />
            {!reasonValid && <small className="admin-field-warning" id={`challenge-reason-help-${cohort.id}`}>Enter a reason of {MIN_REASON}–{MAX_REASON} characters to confirm this change.</small>}
          </label>
          <div className="challenge-access-actions">
            <Button aria-describedby={!reasonValid ? `challenge-reason-help-${cohort.id}` : undefined} disabled={!reasonValid || pending || busy} onClick={() => void confirm()}>
              {pending ? 'Saving…' : review.action === 'open' ? 'Open the challenge' : 'Pause the challenge'}
            </Button>
            <Button variant="secondary" disabled={pending} onClick={cancel}>Cancel</Button>
          </div>
        </div>
      ) : canChange ? (
        <div className="challenge-access-actions">
          {challenge.can_open && (
            <Button data-challenge-trigger disabled={busy} onClick={() => begin('open')}>
              {challenge.state === 'paused' ? 'Reopen the challenge' : 'Open the challenge to participants'}
            </Button>
          )}
          {challenge.can_pause && (
            <Button data-challenge-trigger variant="secondary" disabled={busy} onClick={() => begin('pause')}>Pause the challenge</Button>
          )}
        </div>
      ) : (
        <p className="admin-muted">Only a platform administrator can open or pause the challenge.</p>
      )}

      {(pending || busy) && <p className="admin-muted" role="status">{pending ? 'Saving the challenge change…' : 'Wait for the current change to finish.'}</p>}

      {challenge.recent_events.length > 0 && (
        <details className="challenge-access-history">
          <summary>Recent changes ({challenge.recent_events.length})</summary>
          <ul>
            {challenge.recent_events.map((event) => (
              <li key={event.id}>
                <strong>{event.action === 'open' ? 'Opened' : 'Paused'}</strong> by {event.actor_name} · {new Date(event.occurred_at).toLocaleString()}
                <small>{event.reason}</small>
              </li>
            ))}
          </ul>
        </details>
      )}
    </section>
  )
}
