import { useEffect, useRef, useState } from 'react'
import { updateAdminPersona, type AdminPersonaDetail, type CurrentUser } from '../api'
import { Button } from './Button'
import { CoachContentLibrary } from './CoachContentLibrary'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

export function CoachTeachingWorkspace({ persona, currentUser, lifecycle, onDirtyChange, onPersonaChange, onPreview }: { persona: AdminPersonaDetail | null; currentUser: CurrentUser; lifecycle: CoachWorkspaceMutationLifecycle; onDirtyChange: (dirty: boolean) => void; onPersonaChange: (persona: AdminPersonaDetail) => void; onPreview: () => void }) {
  const [methodDirty, setMethodDirty] = useState(false)
  const [libraryDirty, setLibraryDirty] = useState(false)
  const [saved, setSaved] = useState(false)
  useEffect(() => { onDirtyChange(methodDirty || libraryDirty) }, [methodDirty, libraryDirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])
  function preview() {
    if (libraryDirty && !window.confirm('Leave without saving your library changes? Your teaching method is saved.')) return
    onPreview()
  }
  return <>
    {persona && <CoachTeaching key={persona.id} persona={persona} lifecycle={lifecycle} onDirtyChange={setMethodDirty} onSaved={(next) => { onPersonaChange(next); setSaved(true); preview() }} />}
    {saved && <p role="status">Your teaching method is saved. Save your library changes or leave them behind to preview. <Button variant="secondary" disabled={methodDirty || lifecycle.pending} onClick={preview}>Preview saved teaching</Button></p>}
    <details><summary>Teaching library and sources</summary><CoachContentLibrary currentUser={currentUser} selectedPersona={persona} mutationLifecycle={lifecycle} onDirtyChange={setLibraryDirty} onPersonaChange={onPersonaChange} /></details>
  </>
}

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
      if (mounted.current && lifecycle.isCurrent(ticket)) {
        setMethod(saved.draft?.coaching.method ?? '')
        onSaved(saved)
      }
    } catch { if (mounted.current && lifecycle.isCurrent(ticket)) setError('Your teaching could not be saved. Keep your changes here and try again, or reload if another coach has updated it.') }
    finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }
  return <article className="panel"><h3>How do you help someone decide?</h3><p>Describe your usual teaching method. Preview the answers before your people receive the change.</p>
    {persona.permissions.edit ? <><label>Teaching method<textarea aria-label="Teaching method" rows={5} maxLength={600} value={method} disabled={busy || lifecycle.pending} onChange={(event) => setMethod(event.target.value)} /></label><Button disabled={!dirty || busy || lifecycle.pending} onClick={() => void save()}>{busy ? 'Saving…' : 'Save and preview answers'}</Button></> : <p>{method || 'Ask your program owner to add a teaching method.'}</p>}
    {error && <p role="alert">{error}</p>}
  </article>
}
