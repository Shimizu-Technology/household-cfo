import { useEffect, useRef, useState } from 'react'
import { privacyApi } from '../lib/privacyApi'
import type { PrivacyScope } from '../lib/challengePrivacy'
import { ChallengePrivacyDialog } from './ChallengePrivacyDialog'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { SavingsRowButton } from './SavingsRow'

// One name for this entry everywhere (menu, Home, dialog title, Mia's text).
export const PRIVACY_LABEL = 'Privacy & reminders'

// Resolve self-only control metadata independently of financial workspace
// loading, so paused programs and withdrawn enrollments keep their exits.
export function ParticipantPrivacyAccess({
  userId,
  participant,
  householdId,
  variant,
  description,
}: {
  userId: number | null
  participant: boolean
  householdId?: number | null
  // 'row' renders the entry as a plain list row (savings home); description is its one-line hint.
  variant?: 'button' | 'row'
  description?: string
}) {
  if (!participant || !userId) return null
  return <PrivacyAccess key={`${userId}:${householdId ?? 'metadata'}`} userId={userId} householdId={householdId} variant={variant} description={description} />
}

function PrivacyAccess({ userId, householdId, variant, description }: { userId: number; householdId?: number | null; variant?: 'button' | 'row'; description?: string }) {
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
        setError(participantErrorMessage(failure, 'Private controls are unavailable. Try again.'))
      }
    } finally {
      if (live.current && !owned.signal.aborted) setBusy(false)
    }
  }
  return (
    <div className="participant-private-access">
      {variant === 'row'
        ? <SavingsRowButton label={PRIVACY_LABEL} busyLabel={busy ? 'Opening…' : undefined} description={description ?? ''} disabled={busy} onClick={() => void open()} />
        : <button type="button" disabled={busy} onClick={() => void open()}>
          {busy ? 'Opening private controls…' : PRIVACY_LABEL}
        </button>}
      {error && <p role="alert">{error}</p>}
      {scope && <ChallengePrivacyDialog actorScope={scope} participant onClose={() => setScope(null)} />}
    </div>
  )
}
