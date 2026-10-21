import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { privacyApi } from '../lib/privacyApi'
import type { PrivacyScope } from '../lib/challengePrivacy'
import { ChallengePrivacyDialog } from './ChallengePrivacyDialog'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { SavingsRowButton } from './SavingsRow'
import { usePilotDialog } from '../lib/usePilotDialog'

// Savings-only controls retain one name across Home, the menu, and Mia.
export const PRIVACY_LABEL = 'Privacy & reminders'

// Resolve self-only control metadata independently of financial workspace
// loading, so paused programs and withdrawn enrollments keep their exits.
export function ParticipantPrivacyAccess({
  userId,
  participant,
  householdId,
  variant,
  description,
  savingsChallenge,
}: {
  savingsChallenge?: boolean
  userId: number | null
  participant: boolean
  householdId?: number | null
  // 'row' renders the entry as a plain list row (savings home); description is its one-line hint.
  variant?: 'button' | 'row'
  description?: string
}) {
  if (!participant || !userId) return null
  return <PrivacyAccess key={`${userId}:${householdId ?? 'metadata'}:${savingsChallenge ?? 'auto'}`} savingsChallenge={savingsChallenge} userId={userId} householdId={householdId} variant={variant} description={description} />
}

function PrivacyAccess({ userId, householdId, variant, description, savingsChallenge }: { savingsChallenge?: boolean; userId: number; householdId?: number | null; variant?: 'button' | 'row'; description?: string }) {
  const [householdOpen, setHouseholdOpen] = useState(false)
  const entryRef = useRef<HTMLDivElement>(null)
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
    // Safari pointer activation does not always focus a button. Keep a return target.
    entryRef.current?.querySelector<HTMLButtonElement>('button')?.focus({ preventScroll: true })
    if (savingsChallenge === false) { setHouseholdOpen(true); return }
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
  function close() {
    setScope(null)
    setHouseholdOpen(false)
    window.requestAnimationFrame(() => {
      const entry = entryRef.current
      const menu = entry?.closest('details')
      const target = menu && !menu.open ? menu.querySelector<HTMLElement>('summary') : entry?.querySelector<HTMLElement>('button')
      target?.focus({ preventScroll: true })
    })
  }
  return (
    <div className="participant-private-access" ref={entryRef}>
      {variant === 'row'
        ? <SavingsRowButton label={savingsChallenge === false ? 'Privacy' : PRIVACY_LABEL} busyLabel={busy ? 'Opening…' : undefined} description={description ?? ''} disabled={busy} onClick={() => void open()} />
        : <button type="button" disabled={busy} onClick={() => void open()}>
          {busy ? 'Opening private controls…' : savingsChallenge === false ? 'Privacy' : PRIVACY_LABEL}
        </button>}
      {error && <p role="alert">{error}</p>}
      {scope && <ChallengePrivacyDialog actorScope={scope} participant onClose={close} />}
      {householdOpen && <HouseholdPrivacyDialog onClose={close} />}
    </div>
  )
}

function HouseholdPrivacyDialog({ onClose }: { onClose: () => void }) {
  const dialog = usePilotDialog(onClose)
  return createPortal(<div className="household-privacy-backdrop"><section ref={dialog} className="challenge-privacy-dialog household-privacy-dialog" role="dialog" aria-modal="true" aria-labelledby="household-privacy-title" tabIndex={-1}>
    <header><h2 id="household-privacy-title">Your household privacy</h2><button type="button" aria-label="Close privacy controls" onClick={onClose}>×</button></header>
    <div className="privacy-scroll">
      <p>Your household money, statements and conversations stay in your private workspace.</p>
      <p>Your coach doesn't see your financial records unless you choose to share them.</p>
      <p>You review financial changes before they are saved. Mia prepares suggestions; you decide.</p>
    </div>
  </section></div>, document.body)
}
