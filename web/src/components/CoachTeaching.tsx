import { useEffect, useRef, useState } from 'react'
import { updateAdminPersona, type AdminPersonaDetail } from '../api'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

export function CoachTeaching({ persona, lifecycle, onDirtyChange, onSaved }: { persona: AdminPersonaDetail; lifecycle: CoachWorkspaceMutationLifecycle; onDirtyChange: (dirty: boolean) => void; onSaved: (persona: AdminPersonaDetail) => void }) {
  const [method, setMethod] = useState(persona.draft?.coaching.method ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const mounted = useRef(true)
  const dirty = method !== persona.draft?.coaching.method
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  useEffect(() => { onDirtyChange(dirty); return () => onDirtyChange(false) }, [dirty, onDirtyChange])
  async function save() {
    if (!persona.draft || !persona.permissions.edit || !dirty || busy || lifecycle.pending || persona.draft_revision == null) return
    const ticket = lifecycle.begin()
    setBusy(true); setError(null)
    try {
      const saved = await updateAdminPersona(persona.id, { draft_revision: persona.draft_revision, draft_config: { ...persona.draft, coaching: { ...persona.draft.coaching, method } } })
      if (mounted.current && lifecycle.isCurrent(ticket)) onSaved(saved)
    } catch { if (mounted.current && lifecycle.isCurrent(ticket)) setError('Your teaching could not be saved. Keep your changes here and try again, or reload if another coach has updated it.') }
    finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }
  return <article className="panel"><h3>How do you help someone decide?</h3><p>Describe your usual teaching method. Preview the answers before your people receive the change.</p>
    {persona.permissions.edit ? <><label>Teaching method<textarea aria-label="Teaching method" rows={5} maxLength={600} value={method} disabled={busy || lifecycle.pending} onChange={(event) => setMethod(event.target.value)} /></label><Button disabled={!dirty || busy || lifecycle.pending} onClick={() => void save()}>{busy ? 'Saving…' : 'Save and preview answers'}</Button></> : <p>{method || 'Ask your program owner to add a teaching method.'}</p>}
    {error && <p role="alert">{error}</p>}
  </article>
}
