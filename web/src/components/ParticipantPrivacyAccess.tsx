import { useEffect, useRef, useState } from 'react'
import { privacyApi } from '../lib/privacyApi'
import type { PrivacyScope } from '../lib/challengePrivacy'
import { ChallengePrivacyDialog } from './ChallengePrivacyDialog'

// Resolve self-only control metadata independently of financial workspace
// loading, so paused programs and withdrawn enrollments keep their exits.
export function ParticipantPrivacyAccess({
  userId,
  participant,
  householdId,
}: {
  userId: number | null
  participant: boolean
  householdId?: number | null
}) {
  if (!participant || !userId) return null
  return <PrivacyAccess key={`${userId}:${householdId ?? 'metadata'}`} userId={userId} householdId={householdId} />
}

function PrivacyAccess({ userId, householdId }: { userId: number; householdId?: number | null }) {
  const [scope, setScope] = useState<PrivacyScope | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const controller = useRef<AbortController | null>(null)
  const live = useRef(true)
  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
      controller.current?.abort()
    }
  }, [])
  async function open() {
    if (busy) return
    const owned = new AbortController()
    controller.current = owned
    setBusy(true)
    setError(null)
    try {
      const result = await privacyApi.controls(null, owned.signal)
      if (!live.current || owned.signal.aborted) return
      const actor = result.actor_scope
      if (
        actor.user_id !== userId ||
        !Number.isSafeInteger(actor.household_id) ||
        actor.household_id < 1 ||
        (householdId && actor.household_id !== householdId)
      )
        throw new Error('The private workspace changed. Reopen your controls in the correct account.')
      setScope(actor)
    } catch (failure) {
      if (live.current && !owned.signal.aborted) {
        setScope(null)
        setError(failure instanceof Error ? failure.message : 'Private controls are unavailable. Try again.')
      }
    } finally {
      if (live.current && !owned.signal.aborted) setBusy(false)
    }
  }
  return (
    <div className="participant-private-access">
      <button type="button" disabled={busy} onClick={() => void open()}>
        {busy ? 'Opening private controls…' : 'Privacy & help'}
      </button>
      {error && <p role="alert">{error}</p>}
      {scope && <ChallengePrivacyDialog actorScope={scope} participant onClose={() => setScope(null)} />}
    </div>
  )
}
