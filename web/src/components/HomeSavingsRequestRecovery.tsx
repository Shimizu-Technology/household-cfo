import { useState } from 'react'
import type { useHomeSavingsMutation } from '../lib/useHomeSavingsMutation'
const labels = { enrollment: 'joining the challenge', entry_stage: 'preparing a savings record', entry_approve: 'confirming a savings record', zero_attest: 'confirming you set nothing aside' }
export function HomeSavingsRequestRecovery({ state, onFresh }: { state: ReturnType<typeof useHomeSavingsMutation>; onFresh: () => void }) {
  const [accepted, setAccepted] = useState(false)
  const request = state.pending
  if (!request && !state.error) return null
  return <section className="savings-error" role="alert" aria-label="Savings request recovery"><h3>Check your earlier request</h3><p>{request?.working ? 'Checking or saving your reviewed request…' : request?.error ?? state.error}</p>{request && <><p>Your last change to {labels[request.action]} needs checking before another save. Your amounts aren’t kept on this device.</p>{state.check && <button type="button" onClick={() => void state.check?.()}>Check earlier savings result</button>}{state.retry && <button type="button" onClick={() => void state.retry?.()}>Retry exact savings request</button>}{state.reviewFresh && <><p>We haven’t found a completed save yet. It may still finish.</p><label className="savings-check"><input type="checkbox" checked={accepted} onChange={event => setAccepted(event.target.checked)} />I will review the same change again.</label><button type="button" disabled={!accepted} onClick={() => { state.reviewFresh?.(); setAccepted(false); onFresh() }}>Prepare fresh savings review</button></>}{request.fresh && <p>Review the current details below. Retrying this change won’t save it twice.</p>}</>}</section>
}
