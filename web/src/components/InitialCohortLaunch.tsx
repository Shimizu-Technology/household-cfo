import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { ApiRequestError, createCohortReleaseRequestId, fetchCohortInitialLaunch, launchCohortRelease, type CohortInitialLaunch } from '../api'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import './InitialCohortLaunch.css'

type LaunchReview = { input: { release_id: number; preview_digest: string }; requestId: string }

export function InitialCohortLaunch({ cohortId, mutationLifecycle, onLaunch, beforeLaunchAction }: {
  cohortId: number | null
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onLaunch: () => void
  beforeLaunchAction?: () => boolean
}) {
  const [state, setState] = useState<CohortInitialLaunch | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [review, setReview] = useState<LaunchReview | null>(null)
  const cohortRef = useRef(cohortId)
  const requestRef = useRef(0)
  const abortRef = useRef<AbortController | null>(null)
  const cardRef = useRef<HTMLElement | null>(null)
  const reviewHeadingRef = useRef<HTMLHeadingElement | null>(null)
  const previousReviewRef = useRef(false)
  useLayoutEffect(() => { cohortRef.current = cohortId }, [cohortId])

  useEffect(() => {
    if (review) reviewHeadingRef.current?.focus()
    else if (previousReviewRef.current) {
      const next = cardRef.current?.querySelector<HTMLElement>('[data-launch-review-trigger]')
        ?? cardRef.current?.querySelector<HTMLElement>('#initial-launch-heading')
      next?.focus()
    }
    previousReviewRef.current = Boolean(review)
  }, [review])

  const load = useCallback(async (id: number) => {
    const request = ++requestRef.current
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller
    setLoading(true)
    setState(null)
    setReview(null)
    setError(null)
    try {
      const next = await fetchCohortInitialLaunch(id, controller.signal)
      if (controller.signal.aborted || request !== requestRef.current || cohortRef.current !== id) return
      if (next.cohort.id !== id) throw new Error('The launch review returned a different cohort. Reload and try again.')
      setState(next)
    } catch (caught) {
      if (controller.signal.aborted || request !== requestRef.current || cohortRef.current !== id) return
      setError(messageFor(caught, 'The cohort launch review could not be loaded.'))
    } finally {
      if (request === requestRef.current) setLoading(false)
    }
  }, [])

  const cancelLoad = useCallback(() => {
    requestRef.current += 1
    abortRef.current?.abort()
  }, [])

  useEffect(() => {
    let cancelled = false
    queueMicrotask(() => {
      if (cancelled) return
      setNotice(null)
      if (cohortId) void load(cohortId)
      else { setState(null); setReview(null) }
    })
    return () => { cancelled = true; cancelLoad() }
  }, [cohortId, load, cancelLoad])

  async function launch() {
    if (!cohortId || !review || state?.cohort.id !== cohortId || mutationLifecycle.pending) return
    const id = cohortId
    const ticket = mutationLifecycle.begin()
    setError(null)
    try {
      const result = await launchCohortRelease(id, review.input, review.requestId)
      if (!mutationLifecycle.isCurrent(ticket) || cohortRef.current !== id) return
      if (result.launch.cohort.id !== id) throw new Error('The launch response returned a different cohort. Reload before continuing.')
      setState(result.launch)
      setReview(null)
      setNotice('Cohort launched. Participants now use the sealed brand, assistant, and tools. Future updates use a rollout.')
      onLaunch()
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(ticket) || cohortRef.current !== id) return
      const message = messageFor(caught, 'The launch could not be confirmed. Reload the current launch state before trying again.')
      await load(id)
      if (mutationLifecycle.isCurrent(ticket) && cohortRef.current === id) setError(message)
    } finally {
      mutationLifecycle.finish(ticket)
    }
  }

  if (!cohortId) return null
  return <article ref={cardRef} className="panel initial-cohort-launch" aria-labelledby="initial-launch-heading">
    <div>
      <p className="eyebrow">First launch</p>
      <h3 id="initial-launch-heading" tabIndex={-1}>{state?.active_release_id ? 'This cohort is launched' : 'Make your first sealed release available'}</h3>
      <p>{state?.active_release_id
        ? `Release activation is recorded. Use the Rollout step for later changes to participants’ brand, assistant, or tools.`
        : 'Seal your ready settings, then review and launch them together. You only do this once per cohort.'}</p>
    </div>
    {loading && <p role="status">Checking launch readiness…</p>}
    {notice && <p className="initial-launch-notice" role="status">{notice}</p>}
    {error && <p role="alert">{error}</p>}
    {state && !state.active_release_id && <>
      {state.blockers.length > 0 && <ul>{state.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul>}
      {!state.can_launch && state.blockers.length === 0 && <p>A workspace owner or reviewer can launch this cohort.</p>}
      {review ? <section className="initial-launch-review" aria-label="Review first cohort launch">
        <h4 ref={reviewHeadingRef} tabIndex={-1}>Review first cohort launch</h4>
        <p><strong>{state.cohort.name} · Release {state.release?.release_number}</strong></p>
        <p>{state.message}</p>
        <p>{state.cohort.participant_count} current {state.cohort.participant_count === 1 ? 'participant' : 'participants'} will use this release. New participants will use it too.</p>
        <div className="initial-launch-actions">
          <Button disabled={mutationLifecycle.pending || !state.can_launch} onClick={() => void launch()}>{mutationLifecycle.pending ? 'Launching…' : 'Launch cohort now'}</Button>
          <Button variant="secondary" disabled={mutationLifecycle.pending} onClick={() => setReview(null)}>Cancel</Button>
        </div>
      </section> : state.can_launch && state.release && <Button data-launch-review-trigger disabled={mutationLifecycle.pending || loading} onClick={() => {
        if (beforeLaunchAction && !beforeLaunchAction()) return
        setReview({ input: { release_id: state.release!.id, preview_digest: state.preview_digest }, requestId: createCohortReleaseRequestId() })
      }}>Review first launch</Button>}
    </>}
    {!review && <Button variant="ghost" disabled={mutationLifecycle.pending || loading} onClick={() => void load(cohortId)}>Refresh launch state</Button>}
  </article>
}

function messageFor(error: unknown, fallback: string) {
  return error instanceof ApiRequestError || error instanceof Error ? error.message : fallback
}
