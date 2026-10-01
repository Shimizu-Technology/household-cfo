import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import {
  confirmHouseholdMemory,
  createHouseholdMemory,
  fetchHouseholdMemories,
  forgetHouseholdMemory,
  rejectHouseholdMemory,
  setMiaPersonalizationPaused,
  updateHouseholdMemory,
  type HouseholdMemory,
  type HouseholdMemoryCategory,
  type MiaMemoryData,
} from '../api'
import { resolveMemoryRequestKey, type MemoryRequestKeyState } from '../lib/memoryRequestKey'

const categoryLabels: Record<HouseholdMemoryCategory, string> = {
  goal: 'Personal goal',
  preference: 'Preference',
  constraint: 'Constraint',
  habit: 'Habit',
  coaching_style: 'How Mia should coach me',
  follow_up: 'Something to follow up on',
}

type MemoryForm = {
  category: HouseholdMemoryCategory
  display_value: string
  sensitivity: 'ordinary' | 'sensitive'
}

const initialForm: MemoryForm = {
  category: 'preference',
  display_value: '',
  sensitivity: 'ordinary',
}

export function MiaMemoryPanel({ enabled }: { enabled: boolean }) {
  const [data, setData] = useState<MiaMemoryData | null>(null)
  const [form, setForm] = useState<MemoryForm>(initialForm)
  const [editing, setEditing] = useState<HouseholdMemory | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const createRequestRef = useRef<MemoryRequestKeyState | null>(null)

  function updateForm(next: MemoryForm) {
    createRequestRef.current = null
    setForm(next)
  }

  const load = useCallback(async () => {
    if (!enabled) return
    try {
      const next = await fetchHouseholdMemories()
      setData(next)
      setError(null)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Mia’s saved memories could not be loaded.')
    }
  }, [enabled])

  useEffect(() => {
    if (!enabled) return
    let current = true
    void fetchHouseholdMemories().then((next) => {
      if (!current) return
      setData(next)
      setError(null)
    }).catch((caught: unknown) => {
      if (current) setError(caught instanceof Error ? caught.message : 'Mia’s saved memories could not be loaded.')
    })
    return () => { current = false }
  }, [enabled])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!form.display_value.trim()) return
    setBusy(editing ? `edit-${editing.id}` : 'create')
    setError(null)
    setNotice(null)
    try {
      if (editing) {
        const result = await updateHouseholdMemory(editing.id, form)
        setNotice(result.memory.status === 'pending_confirmation'
          ? 'Memory updated and waiting for confirmation before Mia can use it.'
          : 'Memory updated. Mia will use the confirmed version on your next message.')
      } else {
        const request = resolveMemoryRequestKey(
          createRequestRef.current,
          form,
          () => globalThis.crypto?.randomUUID?.() ?? `memory-${Date.now()}`,
        )
        createRequestRef.current = request
        const result = await createHouseholdMemory({
          ...form,
          display_value: form.display_value.trim(),
          confirmed: form.sensitivity === 'ordinary',
          request_key: request.requestKey,
        })
        setNotice(result.memory.status === 'pending_confirmation'
          ? 'Saved for your confirmation. Mia will not use this sensitive memory yet.'
          : 'Saved. Mia can use this on your next message.')
      }
      createRequestRef.current = null
      setEditing(null)
      setForm(initialForm)
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'That memory could not be saved.')
    } finally {
      setBusy(null)
    }
  }

  async function act(label: string, action: () => Promise<unknown>, message: string) {
    setBusy(label)
    setError(null)
    setNotice(null)
    try {
      await action()
      setNotice(message)
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'That memory action could not be completed.')
    } finally {
      setBusy(null)
    }
  }

  function beginEdit(memory: HouseholdMemory) {
    createRequestRef.current = null
    setEditing(memory)
    setForm({
      category: memory.category,
      display_value: memory.display_value,
      sensitivity: memory.sensitivity,
    })
    setNotice(null)
    setError(null)
  }

  if (!enabled) {
    return (
      <article id="mia-memory" className="panel mia-memory-panel">
        <div className="mia-memory-heading"><div><span className="eyebrow">Personalization</span><h2>What Mia remembers</h2></div></div>
        <p>Sign in to choose what Mia remembers between conversations.</p>
      </article>
    )
  }

  const paused = data?.personalization.paused ?? false
  const memories = data?.memories ?? []
  const loading = data === null && error === null
  const controlsUnavailable = loading || Boolean(error)

  return (
    <article id="mia-memory" className="panel mia-memory-panel" aria-labelledby="mia-memory-title" aria-busy={loading}>
      <div className="mia-memory-heading">
        <div>
          <span className="eyebrow">Personalization you control</span>
          <h2 id="mia-memory-title">What Mia remembers</h2>
          <p>Only items you explicitly save appear here. Mia uses your approved financial records for money facts.</p>
        </div>
        <button
          type="button"
          className="secondary-button"
          disabled={controlsUnavailable || Boolean(busy)}
          aria-pressed={paused}
          onClick={() => void act('pause', () => setMiaPersonalizationPaused(!paused), paused ? 'Personalization resumed.' : 'Personalization paused. Saved memories remain here but Mia will not use them.')}
        >
          {paused ? 'Resume personalization' : 'Pause personalization'}
        </button>
      </div>

      {loading && <div className="mia-memory-loading" role="status" aria-live="polite">Loading Mia’s memories…</div>}
      {paused && <div className="mia-memory-paused" role="status"><strong>Personalization is paused.</strong> Financial facts and manual tools still work. Mia will not use or add memories until you resume.</div>}
      {error && <div className="form-error" role="alert"><p>{error}</p><button type="button" className="secondary-button" onClick={() => { setError(null); void load() }}>Try again</button></div>}
      {notice && <p className="form-success" role="status">{notice}</p>}

      <form className="mia-memory-form" onSubmit={submit}>
        <label>
          <span>What should Mia remember?</span>
          <textarea
            aria-label="Memory for Mia"
            value={form.display_value}
            maxLength={500}
            rows={3}
            disabled={controlsUnavailable || paused || Boolean(busy)}
            placeholder="For example: Ask one question at a time, and check in on our emergency fund goal each month."
            onChange={(event) => updateForm({ ...form, display_value: event.target.value })}
          />
          <small>{form.display_value.length}/500</small>
        </label>
        <div className="mia-memory-form-grid">
          <label><span>Type</span><select aria-label="Memory type" value={form.category} disabled={controlsUnavailable || paused || Boolean(busy)} onChange={(event) => updateForm({ ...form, category: event.target.value as HouseholdMemoryCategory })}>{Object.entries(categoryLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
          <div className="mia-memory-private-note"><strong>Private to you</strong><span>Other household participants and coaches cannot see or use these memories.</span></div>
        </div>
        <label className="mia-memory-sensitive"><input type="checkbox" checked={form.sensitivity === 'sensitive'} disabled={controlsUnavailable || paused || Boolean(busy)} onChange={(event) => updateForm({ ...form, sensitivity: event.target.checked ? 'sensitive' : 'ordinary' })} /><span>This feels sensitive. Save it for a separate confirmation before Mia can use it.</span></label>
        <div className="mia-memory-form-actions">
          <button type="submit" disabled={controlsUnavailable || paused || Boolean(busy) || !form.display_value.trim()}>{busy === 'create' || busy?.startsWith('edit-') ? 'Saving…' : editing ? 'Save changes' : 'Remember this'}</button>
          {editing && <button type="button" className="secondary-button" disabled={controlsUnavailable || Boolean(busy)} onClick={() => { createRequestRef.current = null; setEditing(null); setForm(initialForm) }}>Cancel edit</button>}
        </div>
      </form>

      <div className="mia-memory-list" aria-live="polite">
        {data && memories.length === 0 && <div className="mia-memory-empty"><strong>Nothing saved yet.</strong><p>Mia does not mine your chat history. Add only the context you want carried forward.</p></div>}
        {memories.map((memory) => (
          <section className={`mia-memory-item status-${memory.status}`} key={memory.id} aria-label={`${categoryLabels[memory.category]} memory`}>
            <div className="mia-memory-item-copy">
              <div className="mia-memory-badges"><span>{categoryLabels[memory.category]}</span><span>Only me</span>{memory.sensitivity === 'sensitive' && <span>Sensitive</span>}<span>{memory.status === 'user_confirmed' ? 'Active' : memory.status.replaceAll('_', ' ')}</span></div>
              <p>{memory.display_value}</p>
            </div>
            <div className="mia-memory-item-actions">
              {memory.status === 'pending_confirmation' && memory.confirmation_fingerprint && <button type="button" disabled={controlsUnavailable || paused || Boolean(busy)} onClick={() => void act(`confirm-${memory.id}`, () => confirmHouseholdMemory(memory.id, memory.confirmation_fingerprint!), 'Memory confirmed. Mia can use it now.')}>Confirm</button>}
              {memory.status === 'pending_confirmation' && <button type="button" className="secondary-button" disabled={controlsUnavailable || Boolean(busy)} onClick={() => void act(`reject-${memory.id}`, () => rejectHouseholdMemory(memory.id), 'Memory rejected. Mia will not use it.')}>Reject</button>}
              <button type="button" className="secondary-button" disabled={controlsUnavailable || Boolean(busy) || paused} onClick={() => beginEdit(memory)}>Edit</button>
              <button type="button" className="danger-button" disabled={controlsUnavailable || Boolean(busy)} onClick={() => { if (window.confirm('Forget this memory? Mia will stop using it immediately.')) void act(`forget-${memory.id}`, () => forgetHouseholdMemory(memory.id), 'Memory forgotten.') }}>Forget</button>
            </div>
          </section>
        ))}
      </div>
      <p className="mia-memory-policy"><strong>Privacy:</strong> This list is private to you. Other household participants and coaches cannot see it. Clearing chat does not erase these choices; use Forget here when you want Mia to stop using one.</p>
    </article>
  )
}
