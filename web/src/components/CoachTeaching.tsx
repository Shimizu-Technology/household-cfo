import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, updateAdminPersona, type AdminPersonaDetail, type CurrentUser, type PersonaConfiguration } from '../api'
import { Button } from './Button'
import { PhraseUse } from './PhraseUse'
import { CoachContentLibrary } from './CoachContentLibrary'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import { confirmDiscard } from '../lib/confirmAction'

export function CoachTeachingWorkspace({ persona, currentUser, lifecycle, onDirtyChange, onPersonaChange, onPreview }: { persona: AdminPersonaDetail | null; currentUser: CurrentUser; lifecycle: CoachWorkspaceMutationLifecycle; onDirtyChange: (dirty: boolean) => void; onPersonaChange: (persona: AdminPersonaDetail) => void; onPreview: () => void }) {
  const [methodDirty, setMethodDirty] = useState(false)
  const [libraryDirty, setLibraryDirty] = useState(false)
  const [saved, setSaved] = useState(false)
  useEffect(() => { onDirtyChange(methodDirty || libraryDirty) }, [methodDirty, libraryDirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])
  async function preview() {
    if (libraryDirty && !(await confirmDiscard('Your teaching method is saved. Your changes to the library are not.'))) return
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
  const [phrase, setPhrase] = useState('')
  const [meaning, setMeaning] = useState('')
  const [frequency, setFrequency] = useState('rare')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const mounted = useRef(true)
  const dirty = method !== persona.draft?.coaching.method || !!phrase.trim() || !!meaning.trim()
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  useEffect(() => { onDirtyChange(dirty); return () => onDirtyChange(false) }, [dirty, onDirtyChange])
  async function save() {
    if (!persona.draft || !persona.permissions.edit || !dirty || busy || lifecycle.pending || persona.draft_revision == null) return
    setBusy(true); setError(null)
    const ticket = lifecycle.begin()
    try {
      const confirmPending = () => confirmDiscard('Saving here will discard pending voice suggestions, including suggestions in another coach’s chat. Review them first, or discard them and save this teaching.', {title:'Discard pending voice suggestions?',confirmLabel:'Discard suggestions and save',cancelLabel:'Keep suggestions'})
      const payload = { draft_revision: persona.draft_revision, draft_config: { ...persona.draft, coaching: { ...persona.draft.coaching, method }, ...(phrase.trim() ? { phrases: [...(persona.draft.phrases ?? []), ...[{ text: phrase.trim(), meaning: meaning.trim() || phrase.trim(), allowed_contexts: ['general'], prohibited_contexts: ['crisis'], frequency, caution: '', provenance: 'coach_authored' } as PersonaConfiguration['phrases'][number]]] } : {}) } }
      let saved: AdminPersonaDetail
      try { saved = await updateAdminPersona(persona.id, payload) }
      catch (caught) {
        if (!(caught instanceof ApiRequestError) || caught.code !== 'persona_pending_suggestions') throw caught
        if (!(await confirmPending())) return
        saved = await updateAdminPersona(persona.id, {...payload, discard_pending_suggestions:true})
      }
      if (mounted.current && lifecycle.isCurrent(ticket)) {
        setMethod(saved.draft?.coaching.method ?? ''); setPhrase(''); setMeaning(''); setFrequency('rare')
        onSaved(saved)
      }
    } catch (caught) { if (mounted.current && lifecycle.isCurrent(ticket)) setError(caught instanceof ApiRequestError && caught.status < 500 ? teachingErrorMessage(caught.message) : 'Your teaching could not be saved. Keep your changes here and try again, or reload if another coach has updated it.') }
    finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }
  return <article className="panel"><h3>How do you help someone decide?</h3><p>Describe your usual teaching method. Preview the answers before your people receive the change.</p>
    {persona.permissions.edit ? <><label>Teaching method<textarea aria-label="Teaching method" rows={5} maxLength={600} value={method} disabled={busy || lifecycle.pending} onChange={(event) => setMethod(event.target.value)} /></label><details className="coach-phrase-entry"><summary>Add a phrase in your own words</summary><p>Use your exact wording. Explain what it means and when it fits. Choose how often it can appear. Phrases are never used during crisis support.</p><label>Phrase<input maxLength={100} value={phrase} disabled={busy || lifecycle.pending} onChange={event => setPhrase(event.target.value)} /></label><label>What it means and when to use it (optional)<textarea maxLength={300} value={meaning} disabled={busy || lifecycle.pending} onChange={event => setMeaning(event.target.value)} /></label><label>How often<select value={frequency} disabled={busy || lifecycle.pending} onChange={event => setFrequency(event.target.value)}><option value="very_rare">Only once in a long while</option><option value="rare">Occasionally</option><option value="sparing">From time to time</option><option value="as_needed">Whenever the situation fits</option></select></label></details>{persona.draft?.phrases?.map(item => <section key={item.artifact_id ?? item.text}><strong>“{item.text}”</strong><PhraseUse phrase={item} /></section>)}<Button disabled={!dirty || busy || lifecycle.pending || (!!meaning.trim() && !phrase.trim())} onClick={() => void save()}>{busy ? 'Saving…' : 'Save and preview answers'}</Button></> : <p>{method || 'Ask your program owner to add a teaching method.'}</p>}
    {error && <p role="alert">{error}</p>}
  </article>
}

function teachingErrorMessage(message: string) {
  if (message.includes('stereotype')) return 'This description could stereotype a group of people. Describe your own coaching approach.'
  return message
}
