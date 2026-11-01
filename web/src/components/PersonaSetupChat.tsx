import { useEffect, useLayoutEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import {
  abandonAdminPersonaSetupSession,
  createAdminPersonaSetupSession,
  createAdminPersonaSetupTurn,
  rebaseAdminPersonaSetupSession,
  resolveAdminPersonaSetupProposal,
  ApiRequestError,
  type AdminPersonaDetail,
  type AdminPersonaSetupChange,
  type AdminPersonaSetupSession,
  type PersonaConfiguration,
} from '../api'
import { Button } from './Button'
import { readCoachVoiceTranscript } from '../enterpriseApi'
import './PersonaVoiceFlow.css'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

type AuthoringState = { description: string; draft_config: PersonaConfiguration }

export function PersonaSetupChat({
  persona,
  disabled = false,
  manualDirty,
  mutationLifecycle,
  onPersonaChange,
  onReviewInForm,
  onDirtyChange,
  saveAndPreview = false,
}: {
  persona: AdminPersonaDetail
  disabled?: boolean
  manualDirty: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onPersonaChange: (persona: AdminPersonaDetail) => void
  onReviewInForm: (state: AuthoringState, firstPath: string | null, draftRevision: number) => void
  onDirtyChange: (dirty: boolean) => void
  saveAndPreview?: boolean
}) {
  const [session, setSession] = useState<AdminPersonaSetupSession | null>(null)
  const [message, setMessage] = useState('')
  const [acceptedIndexes, setAcceptedIndexes] = useState<number[]>([])
  const [uploading, setUploading] = useState(false)
  const [retryKey, setRetryKey] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadFailed, setLoadFailed] = useState(false)
  const [loadAttempt, setLoadAttempt] = useState(0)
  const [pending, setPending] = useState<'send' | 'apply' | 'reject' | 'rebase' | 'abandon' | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [announcement, setAnnouncement] = useState('')
  const beginMutation = mutationLifecycle.begin
  const mutationIsCurrent = mutationLifecycle.isCurrent
  const finishMutation = mutationLifecycle.finish
  const requestSequence = useRef(0)
  const personaIdRef = useRef(persona.id)
  const messageRef = useRef(message)
  useLayoutEffect(() => { messageRef.current = message }, [message])
  const composerRef = useRef<HTMLTextAreaElement | null>(null)
  const transcriptRef = useRef<HTMLDivElement | null>(null)
  const focusTargetRef = useRef<'proposal' | 'composer' | null>(null)
  const proposalHeadingRef = useRef<HTMLHeadingElement | null>(null)
  const resolutionRetryKeysRef = useRef<Map<string, string>>(new Map())
  const resolutionRetryScopeRef = useRef<{ sessionId: number; proposalId: number } | null>(null)
  useLayoutEffect(() => {
    personaIdRef.current = persona.id
  }, [persona.id])

  const latestTurn = session?.turns.at(-1)
  useLayoutEffect(() => {
    const transcript = transcriptRef.current
    if (!loading && transcript) transcript.scrollTop = transcript.scrollHeight
  }, [loading, latestTurn?.id, latestTurn?.status])

  useLayoutEffect(() => {
    if (loading || disabled || pending || mutationLifecycle.pending || !focusTargetRef.current) return
    const target = focusTargetRef.current === 'proposal' ? proposalHeadingRef.current : composerRef.current
    if (target) {
      target.focus()
      focusTargetRef.current = null
    }
  }, [disabled, loading, pending, mutationLifecycle.pending, session?.proposal?.id, latestTurn?.id, latestTurn?.status])

  useEffect(() => {
    onDirtyChange(message.trim().length > 0)
  }, [message, onDirtyChange])

  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  useEffect(() => {
    let cancelled = false
    resolutionRetryKeysRef.current.clear()
    resolutionRetryScopeRef.current = null
    queueMicrotask(() => {
      if (cancelled) return
      setLoading(true)
      setLoadFailed(false)
      setSession(null)
      const sequence = ++requestSequence.current
      const personaId = persona.id
      const ticket = beginMutation()
      createAdminPersonaSetupSession(personaId)
        .then((next) => {
          if (sequence !== requestSequence.current || personaIdRef.current !== personaId || !mutationIsCurrent(ticket)) return
          setSession(next)
          setError(null)
          setLoadFailed(false)
        })
        .catch((caught) => {
          if (sequence === requestSequence.current && personaIdRef.current === personaId && mutationIsCurrent(ticket)) {
            setError(setupErrorMessage(caught, 'Setup chat could not be loaded.'))
            setLoadFailed(true)
          }
        })
        .finally(() => {
          if (sequence === requestSequence.current && personaIdRef.current === personaId && mutationIsCurrent(ticket)) setLoading(false)
          finishMutation(ticket)
        })
    })
    return () => {
      cancelled = true
      requestSequence.current += 1
    }
  }, [beginMutation, finishMutation, loadAttempt, mutationIsCurrent, persona.id])

  useEffect(() => {
    queueMicrotask(() => setAcceptedIndexes(session?.proposal?.operations.map((_, index) => index) ?? []))
  }, [session?.proposal])

  const groupedChanges = useMemo(() => {
    const groups = new Map<string, AdminPersonaSetupChange[]>()
    for (const group of session?.proposal?.grouped_changes ?? []) {
      for (const change of group.changes) {
        const title = group.group === 'Community' ? 'Identity' : group.group === 'Response' ? 'Voice' : change.path === 'curriculum.examples' ? 'Examples' : group.group
        groups.set(title, [...(groups.get(title) ?? []), change])
      }
    }
    const order = ['Identity', 'Voice', 'Coaching', 'Phrases', 'Examples', 'Teaching']
    return [...groups].map(([group, changes]) => ({ group, changes })).sort((a, b) => order.indexOf(a.group) - order.indexOf(b.group))
  }, [session])

  async function sendMessage(event: FormEvent) {
    event.preventDefault()
    const trimmed = message.trim()
    if (disabled || !session || !trimmed || pending || session.stale) return
    const key = retryKey ?? requestKey()
    const ticket = beginMutation()
    const sequence = ++requestSequence.current
    const personaId = persona.id
    setPending('send')
    setError(null)
    setRetryKey(key)
    try {
      const next = await createAdminPersonaSetupTurn(personaId, session.id, trimmed, key)
      if (!isCurrent(sequence, personaId, ticket)) return
      const latestTurn = next.turns[next.turns.length - 1]
      if (latestTurn?.status === 'ready') focusTargetRef.current = next.proposal ? 'proposal' : 'composer'
      setSession(next)
      setAcceptedIndexes(next.proposal?.operations.map((_, index) => index) ?? [])
      if (!latestTurn || latestTurn.status !== 'ready') {
        if (latestTurn?.status !== 'processing') setRetryKey(null)
        setError(latestTurn?.assistant_message || (latestTurn?.status === 'processing'
          ? 'Mia is still preparing this proposal. Retry shortly with the same request.'
          : 'Mia could not prepare this proposal. Your message is ready to retry.'))
        return
      }
      setMessage('')
      setRetryKey(null)
      setAnnouncement(next.proposal ? 'Mia prepared a proposal for your review.' : 'Mia replied. Keep chatting to clarify your changes.')
    } catch (caught) {
      if (isCurrent(sequence, personaId, ticket)) {
        const returnedSession = setupSessionFromError(caught, session.id)
        if (returnedSession) {
          setSession(returnedSession)
          const latestTurn = returnedSession.turns[returnedSession.turns.length - 1]
          if (latestTurn?.status !== 'processing') setRetryKey(null)
        }
        const latestTurn = returnedSession?.turns.at(-1)
        setError(latestTurn?.status === 'failed'
          ? 'Mia could not prepare a proposal. Nothing changed. Try again or use Guided setup.'
          : setupErrorMessage(caught, 'Mia could not prepare this proposal. Try again.'))
      }
    } finally {
      if (isCurrent(sequence, personaId, ticket)) setPending(null)
      finishMutation(ticket)
    }
  }

  async function resolveProposal(action: 'apply' | 'reject') {
    const proposal = session?.proposal
    if (disabled || !session || !proposal || pending || (action === 'apply' && manualDirty)) return
    const ticket = beginMutation()
    const sequence = ++requestSequence.current
    const personaId = persona.id
    const retryScope = resolutionRetryScopeRef.current
    if (retryScope?.sessionId !== session.id || retryScope.proposalId !== proposal.id) {
      resolutionRetryKeysRef.current.clear()
      resolutionRetryScopeRef.current = { sessionId: session.id, proposalId: proposal.id }
    }
    const retrySlot = `${proposal.id}:${action}:${acceptedIndexes.join(',')}`
    const key = resolutionRetryKeysRef.current.get(retrySlot) ?? requestKey()
    resolutionRetryKeysRef.current.set(retrySlot, key)
    setPending(action)
    setError(null)
    try {
      const result = await resolveAdminPersonaSetupProposal(personaId, session.id, proposal.id, action, key, action === 'apply' ? acceptedIndexes : undefined)
      if (!isCurrent(sequence, personaId, ticket)) return
      resolutionRetryKeysRef.current.clear()
      resolutionRetryScopeRef.current = null
      setSession(result.session)
      if (result.persona) onPersonaChange(result.persona)
      setAnnouncement(action === 'apply' ? 'Selected suggestions saved. Next, preview your assistant’s answers.' : 'Proposal rejected. You can keep chatting.')
      window.requestAnimationFrame(() => composerRef.current?.focus())
    } catch (caught) {
      if (isCurrent(sequence, personaId, ticket)) setError(setupErrorMessage(caught, `The proposal could not be ${action === 'apply' ? 'saved' : 'rejected'}.`))
    } finally {
      if (isCurrent(sequence, personaId, ticket)) setPending(null)
      finishMutation(ticket)
    }
  }

  function retryOpenSession() {
    if (disabled || loading || pending) return
    setError(null)
    setLoading(true)
    setLoadAttempt((attempt) => attempt + 1)
  }

  async function updateSession(action: 'rebase' | 'abandon') {
    if (disabled || !session || pending) return
    const ticket = beginMutation()
    const sequence = ++requestSequence.current
    const personaId = persona.id
    setPending(action)
    setError(null)
    let oldChatClosed = session.status !== 'active'
    try {
      if (action === 'abandon') {
        if (session.status === 'active') {
          const abandoned = await abandonAdminPersonaSetupSession(personaId, session.id)
          if (!isCurrent(sequence, personaId, ticket)) return
          setSession(abandoned)
          oldChatClosed = true
        }
        const replacement = await createAdminPersonaSetupSession(personaId)
        if (!isCurrent(sequence, personaId, ticket)) return
        setSession(replacement)
        setMessage('')
        setRetryKey(null)
        setAnnouncement('A fresh private setup chat is ready.')
      } else {
        const next = await rebaseAdminPersonaSetupSession(personaId, session.id)
        if (!isCurrent(sequence, personaId, ticket)) return
        setSession(next)
        setAnnouncement(saveAndPreview ? 'This chat now uses your latest saved voice.' : 'Setup chat rebased onto the latest saved draft.')
      }
    } catch (caught) {
      if (isCurrent(sequence, personaId, ticket)) {
        const fallback = action === 'rebase'
          ? 'The setup chat could not be rebased. Try again.'
          : oldChatClosed
            ? 'The old chat was closed, but a new chat could not be started. Select Open a fresh chat to try again.'
            : 'The setup chat could not be closed. Try again.'
        setError(setupErrorMessage(caught, fallback))
      }
    } finally {
      if (isCurrent(sequence, personaId, ticket)) setPending(null)
      finishMutation(ticket)
    }
  }

  function isCurrent(sequence: number, personaId: number, ticket: ReturnType<CoachWorkspaceMutationLifecycle['begin']>) {
    return sequence === requestSequence.current && personaIdRef.current === personaId && mutationIsCurrent(ticket)
  }

  async function uploadTranscript(file: File | undefined) {
    if (!file || !session || uploading || pending) return
    const sequence = requestSequence.current
    const personaId = persona.id
    setUploading(true); setError(null)
    try {
      const result = await readCoachVoiceTranscript(personaId, session.id, file)
      if (sequence !== requestSequence.current || personaIdRef.current !== personaId) return
      const append = (current: string) => `${current.trim() ? `${current}\n\n` : 'Propose a voice summary, phrases and example replies from these transcripts for my review.\n\n'}Transcript: ${file.name}\n${result.text}`
      if (append(messageRef.current).length > 24000) { setError('These transcripts are long. Use excerpts totalling up to 24,000 characters.'); return }
      setMessage((current) => append(current)); setRetryKey(null)
    } catch (caught) {
      if (sequence === requestSequence.current && personaIdRef.current === personaId) setError(setupErrorMessage(caught, 'This transcript could not be read. Try TXT, DOCX or PDF, or paste its text.'))
    }
    finally { setUploading(false) }
  }

  if (loading) return <div className="persona-setup-loading" role="status">Opening your private setup chat…</div>

  return (
    <fieldset className="persona-setup-layout coach-persona-mutation-lock" disabled={disabled} aria-busy={disabled}>
      <legend className="sr-only">Setup chat controls</legend>
      <section className="persona-setup-chat" aria-labelledby="persona-setup-chat-title">
        <header>

          <h4 id="persona-setup-chat-title">Describe your assistant</h4>
          <p>Describe your assistant, or add two transcripts. Mia will suggest a voice for you to review.</p>
        </header>
        <div className="persona-setup-privacy" role="note">
          <span>Only share your own teaching, without private client details.</span>
          <details><summary>How this works</summary><p>Your words and transcripts go to the assistant service to prepare suggestions. Participant household and financial data are excluded. Nothing changes until you approve it.</p></details>
        </div>
        {error && <div className="form-error" role="alert">{error}</div>}
        {loadFailed && !session ? (
          <div className="persona-setup-stale" role="alert">
            <strong>This setup chat could not be opened.</strong>
            <span>Try loading your private setup chat again.</span>
            <Button variant="secondary" disabled={loading || pending !== null} onClick={retryOpenSession}>Try again</Button>
          </div>
        ) : session?.status !== 'active' ? (
          <div className="persona-setup-stale" role="alert">
            <strong>This setup chat is closed.</strong>
            <span>Open a fresh private chat to continue shaping this assistant.</span>
            <Button variant="secondary" disabled={pending !== null} onClick={() => void updateSession('abandon')}>{pending === 'abandon' ? 'Opening…' : 'Open a fresh chat'}</Button>
          </div>
        ) : session?.stale && (
          <div className="persona-setup-stale" role="alert">
            <strong>Your saved voice changed.</strong>
            <span>{saveAndPreview ? 'Use the latest saved voice before asking for more suggestions.' : 'Rebase this chat before asking Mia for another proposal.'}</span>
            <Button variant="secondary" disabled={pending !== null} onClick={() => void updateSession('rebase')}>{pending === 'rebase' ? 'Updating…' : saveAndPreview ? 'Use latest saved voice' : 'Rebase chat'}</Button>
          </div>
        )}
        <div ref={transcriptRef} className="persona-setup-transcript" role="log" aria-live="polite" aria-relevant="additions text">
          {session?.turns_truncated && <p className="persona-setup-empty">Showing the 100 most recent setup messages.</p>}
          {session?.turns.length ? session.turns.map((turn) => (
            <div className="persona-setup-turn" key={turn.id}>
              <div className="is-coach"><strong>You</strong><p>{turn.user_message}</p></div>
              <div className="is-mia"><strong>Mia</strong><p>{turn.assistant_message || (turn.status === 'failed'
                ? 'I could not prepare that proposal.'
                : turn.status === 'processing'
                  ? 'Mia is still preparing this proposal.'
                  : 'This response is no longer current.')}</p></div>
            </div>
          )) : <p className="persona-setup-empty">Tell Mia how you coach, in your own words.</p>}
        </div>
        <form className="persona-setup-composer" onSubmit={sendMessage}>
          <label htmlFor={`persona-setup-message-${persona.id}`}>Message Mia</label>
          <textarea
            ref={composerRef}
            id={`persona-setup-message-${persona.id}`}
            rows={4}
            maxLength={24000}
            value={message}
            disabled={!session || pending !== null || session?.stale}
            onChange={(event) => {
              setMessage(event.target.value)
              setRetryKey(null)
            }}
            placeholder="For example: Her name is Mrs. Mel. Please use a warm, direct tone and ask one practical question at a time."
          />
          <label className="coach-transcript-upload">Add a transcript (TXT, DOCX or PDF)<input type="file" accept=".txt,.docx,.pdf" disabled={uploading || pending !== null || !session || session.stale} onChange={(event) => { void uploadTranscript(event.target.files?.[0]); event.target.value = '' }} /></label>
          {uploading && <p role="status">Reading your transcript…</p>}
          <div><small>{message.length.toLocaleString()}/24,000</small><Button type="submit" disabled={!message.trim() || !session || pending !== null || session.stale || uploading}>{pending === 'send' ? 'Mia is preparing…' : retryKey ? 'Retry message' : 'Send to Mia'}</Button></div>
        </form>
        <button className="persona-setup-start-over" type="button" disabled={!session || pending !== null} onClick={() => void updateSession('abandon')}>Start a fresh setup chat</button>
      </section>

      {session?.proposal && <section className="persona-setup-review" aria-labelledby="persona-setup-review-title">
        <header>
          <p>Review before saving</p>
          <h4 id="persona-setup-review-title" ref={proposalHeadingRef} tabIndex={-1}>Your voice suggestions</h4>
        </header>
          <>
            <dl className="persona-proposal-summary">
              {groupedChanges.map((group) => <div key={group.group}><dt>{group.group}</dt><dd>{sectionSummary(group.group, group.changes)}</dd></div>)}
            </dl>
            <details className="persona-proposal-choices"><summary>Review each suggestion</summary>
            <div className="persona-proposal-groups">
              {groupedChanges.map((group) => (
                <section key={group.group}>
                  <h5>{group.group}</h5>
                  {group.changes.map((change, changeIndex) => {
                    const index = groupedChanges.slice(0, groupedChanges.indexOf(group)).reduce((sum, item) => sum + item.changes.length, 0) + changeIndex
                    // Groups preserve operation order within a field family; match the sealed operation itself.
                    const matching = session.proposal!.operations.map((op, opIndex) => ({op, opIndex})).filter(({op}) => op.path === change.path)
                    const occurrence = group.changes.slice(0, changeIndex).filter((item) => item.path === change.path).length
                    const operationIndex = matching[occurrence]?.opIndex ?? index
                    return <div key={`${change.path}-${changeIndex}`}><label><input type="checkbox" checked={acceptedIndexes.includes(operationIndex)} disabled={pending !== null} onChange={(event) => setAcceptedIndexes((ids) => event.target.checked ? [...ids, operationIndex] : ids.filter((id) => id !== operationIndex))} />Use this {change.label.toLowerCase()} suggestion</label><ProposalChange change={change} compact={saveAndPreview} /></div>
                  })}
                </section>
              ))}
            </div>
            </details>
            {manualDirty && <p className="persona-setup-apply-blocked" role="note">Save or discard your manual form changes before saving these suggestions.</p>}
            {acceptedIndexes.length !== session.proposal.operations.length && <p>{acceptedIndexes.length} of {session.proposal.operations.length} suggestions selected.</p>}
            {saveAndPreview && <p>Save these suggestions, then preview your assistant’s answers.</p>}
            <div className="persona-setup-review-actions">
              <Button disabled={pending !== null || manualDirty || acceptedIndexes.length === 0} onClick={() => void resolveProposal('apply')}>{pending === 'apply' ? 'Saving…' : acceptedIndexes.length === session.proposal.operations.length ? 'Use all suggestions' : 'Use selected suggestions'}</Button>
              <Button variant="secondary" disabled={pending !== null} onClick={() => onReviewInForm(session.proposal!.after_state, session.proposal!.operations[0]?.path as string | undefined ?? null, session.proposal!.base_draft_revision)}>Review in form</Button>
              <Button variant="secondary" disabled={pending !== null} onClick={() => composerRef.current?.focus()}>Keep chatting</Button>
              <button type="button" className="persona-setup-reject" disabled={pending !== null} onClick={() => void resolveProposal('reject')}>{pending === 'reject' ? 'Rejecting…' : 'Reject proposal'}</button>
            </div>
          </>
      </section>}
      <p className="sr-only" aria-live="assertive">{announcement}</p>
    </fieldset>
  )
}

function ProposalChange({ change, compact = false }: { change: AdminPersonaSetupChange; compact?: boolean }) {
  return (
    <article className="persona-proposal-change">
      <header><strong>{change.label}</strong><span>{change.source_basis === 'coach_quote' ? 'Coach said' : 'Mia drafted'}</span></header>
      {compact && <p className="coach-suggestion-value">{displayValue(change.after)}</p>}
      {compact ? <details><summary>Original wording and source</summary><p>{displayValue(change.before)}</p>{change.evidence_quote && <blockquote>“{change.evidence_quote}”</blockquote>}</details> : <><dl>
        <div><dt>Before</dt><dd>{displayValue(change.before)}</dd></div>
        <div><dt>After</dt><dd>{displayValue(change.after)}</dd></div>
      </dl>
      {change.evidence_quote && <blockquote>“{change.evidence_quote}”</blockquote>}</>}
    </article>
  )
}

function displayValue(value: unknown): string {
  if (value === null || value === undefined || value === '') return 'Not set'
  if (typeof value === 'string') return value
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  if (Array.isArray(value)) return value.length ? value.map(displayValue).join('\n\n') : 'None'
  if (typeof value !== 'object') return String(value)
  return Object.entries(value as Record<string, unknown>).map(([key, item]) => `${key === 'participant' ? 'You' : key === 'assistant' ? 'Your assistant' : key.replaceAll('_', ' ')}: ${displayValue(item)}`).join('\n')
}

function sectionSummary(group: string, changes: AdminPersonaSetupChange[]): string {
  if (group === 'Phrases') return changes.map((change) => change.after == null ? `Remove “${displayValue(change.before)}”` : `“${displayValue(change.after)}”`).join(', ')
  const examples = changes.find((change) => change.path === 'curriculum.examples')?.after
  if (group === 'Examples' && Array.isArray(examples)) return `${examples.length} example ${examples.length === 1 ? 'reply' : 'replies'} for everyday questions`
  const first = changes.find((change) => change.path === 'voice.tone_traits') ?? changes[0]
  if (!first) return ''
  const value = Array.isArray(first.after) ? first.after.map(displayValue).join(', ') : displayValue(first.after)
  return `${first.path.startsWith('response_shape.') ? `${first.label}: ` : ''}${value}`.replaceAll('\n', ' ')
}

function requestKey() {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`
}

function setupErrorMessage(error: unknown, fallback: string) {
  if (error instanceof ApiRequestError && error.status >= 500) return fallback
  return error instanceof Error && error.message ? error.message : fallback
}

function setupSessionFromError(error: unknown, expectedSessionId: number) {
  if (!(error instanceof ApiRequestError)) return null
  const value = error.payload.session
  if (!value || typeof value !== 'object' || !('id' in value) || value.id !== expectedSessionId) return null
  return value as AdminPersonaSetupSession
}
