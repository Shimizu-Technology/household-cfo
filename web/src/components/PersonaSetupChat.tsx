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
import { PhraseUse } from './PhraseUse'
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
  const [focusedReview, setFocusedReview] = useState(false)
  const [acceptedIndexes, setAcceptedIndexes] = useState<number[]>([])
  const [listChoices, setListChoices] = useState<Record<string, number[]>>({})
  const choicesRef = useRef(new Map<string, boolean>())
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
  const failedMessage = latestTurn?.status === 'failed' ? latestTurn.user_message : null
  useLayoutEffect(() => {
    const transcript = transcriptRef.current
    if (!loading && transcript) transcript.scrollTop = transcript.scrollHeight
  }, [loading, latestTurn?.id, latestTurn?.status, error, pending])

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
      setFocusedReview(false)
      choicesRef.current.clear()
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
    queueMicrotask(() => {
      const operations = session?.proposal?.operations ?? []
      setAcceptedIndexes(operations.flatMap((op, index) => choicesRef.current.get(choiceKey(op)) === false ? [] : [index]))
      setListChoices(Object.fromEntries(operations.flatMap((op, index) => {
        const value = proposedValue(session, op)
        return Array.isArray(value) && value.every(item => typeof item === 'string') ? [[String(index), value.flatMap((item, itemIndex) => choicesRef.current.get(choiceKey(op, item)) === false ? [] : [itemIndex])]] : []
      })))
      if (!session?.proposal) setFocusedReview(false)
    })
  }, [session])

  const allSelected = acceptedIndexes.length === session?.proposal?.operations.length && Object.entries(listChoices).every(([index, choices]) => choices.length === (proposedValue(session, session?.proposal?.operations[Number(index)]) as unknown[] | undefined)?.length)
  const groupedChanges = useMemo(() => {
    const groups = new Map<string, AdminPersonaSetupChange[]>()
    for (const group of session?.proposal?.grouped_changes ?? []) {
      for (const change of group.changes) {
        const title = change.path === 'curriculum.examples' ? 'Examples' : group.group === 'Community' ? 'Identity' : group.group === 'Response' ? 'Voice' : group.group === 'Teaching' ? 'Coaching' : group.group
        groups.set(title, [...(groups.get(title) ?? []), change])
      }
    }
    const order = ['Identity', 'Voice', 'Coaching', 'Phrases', 'Examples']
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
      if (!latestTurn || latestTurn.status !== 'ready') {
        if (latestTurn?.status !== 'processing') setRetryKey(null)
        if (latestTurn?.status === 'failed') { setMessage(''); focusTargetRef.current = 'composer' }
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
          if (latestTurn?.status === 'failed') { setMessage(''); focusTargetRef.current = 'composer' }
        }
        const latestTurn = returnedSession?.turns.at(-1)
        setError(latestTurn?.status === 'failed'
          ? latestTurn.assistant_message || 'Mia could not prepare a proposal. Nothing changed. Try describing one change at a time.'
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
    const retrySlot = `${proposal.id}:${action}:${acceptedIndexes.join(',')}:${JSON.stringify(listChoices)}`
    const key = resolutionRetryKeysRef.current.get(retrySlot) ?? requestKey()
    resolutionRetryKeysRef.current.set(retrySlot, key)
    setPending(action)
    setError(null)
    try {
      const selectedLines = Object.fromEntries(Object.entries(listChoices).filter(([index, choices]) => acceptedIndexes.includes(Number(index)) && choices.length !== (proposedValue(session, proposal.operations[Number(index)]) as unknown[]).length))
      const result = await resolveAdminPersonaSetupProposal(personaId, session.id, proposal.id, action, key, action === 'apply' ? acceptedIndexes : undefined, action === 'apply' && Object.keys(selectedLines).length ? selectedLines : undefined)
      if (!isCurrent(sequence, personaId, ticket)) return
      resolutionRetryKeysRef.current.clear()
      resolutionRetryScopeRef.current = null
      setSession(result.session)
      setFocusedReview(false)
      choicesRef.current.clear()
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
    <fieldset className={`persona-setup-layout coach-persona-mutation-lock${focusedReview ? ' is-focused-review' : ''}`} disabled={disabled} aria-busy={disabled}>
      <legend className="sr-only">Setup chat controls</legend>
      {error && <div className="form-error" role="alert">{error}</div>}
      <section hidden={focusedReview} className="persona-setup-chat" aria-labelledby="persona-setup-chat-title">
        <header>

          <h4 id="persona-setup-chat-title">Describe your assistant</h4>
          <p>Describe your assistant, or add two transcripts. Mia will suggest a voice for you to review.</p>
        </header>
        <div className="persona-setup-privacy" role="note">
          <span>Only share your own teaching, without private client details.</span>
          <details><summary>How this works</summary><p>Your words and transcripts go to the assistant service to prepare suggestions. Participant household and financial data are excluded. Nothing changes until you approve it.</p></details>
        </div>
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
        {failedMessage && !message && <Button variant="secondary" disabled={pending !== null} onClick={() => { setMessage(failedMessage); composerRef.current?.focus() }}>Edit failed message</Button>}
        <button className="persona-setup-start-over" type="button" disabled={!session || pending !== null} onClick={() => void updateSession('abandon')}>Start a fresh setup chat</button>
      </section>

      {session?.proposal && <section className="persona-setup-review" aria-labelledby="persona-setup-review-title">
        <header>
          <p>Review before saving</p>
          <h4 id="persona-setup-review-title" ref={proposalHeadingRef} tabIndex={-1}>Your voice suggestions</h4>
          {focusedReview && <p>Keep the suggestions you want. To change the wording, return to chat. Nothing has been saved.</p>}
        </header>
          <>
            <dl className="persona-proposal-summary">
              {groupedChanges.map((group) => <div key={group.group}><dt>{group.group}</dt><dd>{sectionSummary(group.group, group.changes)}{group.group === 'Phrases' && group.changes.map((change, index) => change.phrase ? <PhraseUse key={index} phrase={change.phrase} /> : null)}</dd></div>)}
            </dl>
            <details className="persona-proposal-choices" open={focusedReview || undefined}><summary>Review each suggestion</summary>
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
                    const operation = session.proposal!.operations[operationIndex]
                    if (Array.isArray(change.after) && change.after.length > 0 && change.after.every(item => typeof item === 'string')) return <div key={`${change.path}-${changeIndex}`}><strong>{suggestionLabel(change)}</strong>{change.after.map((item, itemIndex) => <label key={item}><input type="checkbox" checked={acceptedIndexes.includes(operationIndex) && (listChoices[String(operationIndex)] ?? (change.after as string[]).map((_, i) => i)).includes(itemIndex)} disabled={pending !== null} onChange={event => {
                      choicesRef.current.set(choiceKey(operation, item), event.target.checked)
                      const current = listChoices[String(operationIndex)] ?? (change.after as string[]).map((_, i) => i)
                      const next = event.target.checked ? [...current, itemIndex] : current.filter(i => i !== itemIndex)
                      choicesRef.current.set(choiceKey(operation), next.length > 0)
                      setListChoices(values => ({...values, [String(operationIndex)]: next}))
                      setAcceptedIndexes(ids => next.length ? [...new Set([...ids, operationIndex])] : ids.filter(id => id !== operationIndex))
                    }} />Keep: {item}</label>)}<ProposalChange change={change} compact={saveAndPreview} /></div>
                    return <div key={`${change.path}-${changeIndex}`}><label><input type="checkbox" checked={acceptedIndexes.includes(operationIndex)} disabled={pending !== null} onChange={(event) => {
                      choicesRef.current.set(choiceKey(operation), event.target.checked)
                      setAcceptedIndexes((ids) => event.target.checked ? [...ids, operationIndex] : ids.filter((id) => id !== operationIndex))
                    }} />Keep: {suggestionLabel(change)}</label><ProposalChange change={change} compact={saveAndPreview} /></div>
                  })}
                </section>
              ))}
            </div>
            </details>
            {manualDirty && <p className="persona-setup-apply-blocked" role="note">Save or discard your manual form changes before saving these suggestions.</p>}
            {acceptedIndexes.length !== session.proposal.operations.length && <p>{acceptedIndexes.length} of {session.proposal.operations.length} suggestions selected.</p>}
            {saveAndPreview && <p>Save these suggestions, then preview your assistant’s answers.</p>}
            <div className="persona-setup-review-actions">
              <Button disabled={pending !== null || manualDirty || acceptedIndexes.length === 0} onClick={() => void resolveProposal('apply')}>{pending === 'apply' ? 'Saving…' : allSelected ? 'Use all suggestions' : 'Use selected suggestions'}</Button>
              <Button variant="secondary" disabled={pending !== null} onClick={() => { if (saveAndPreview) { setFocusedReview(true); proposalHeadingRef.current?.focus() } else onReviewInForm(session.proposal!.after_state, session.proposal!.operations[0]?.path as string | undefined ?? null, session.proposal!.base_draft_revision) }}>Review in form</Button>
              <Button variant="secondary" disabled={pending !== null} onClick={() => { setFocusedReview(false); requestAnimationFrame(() => composerRef.current?.focus()) }}>Keep chatting</Button>
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
      <header><strong>{suggestionLabel(change)}</strong><span>{proposalSourceLabel(change)}</span></header>
      {change.phrase && <PhraseUse phrase={change.phrase} />}
      {compact && <p className="coach-suggestion-value">{changeValue(change)}</p>}
      {compact ? <details><summary>Original wording and source</summary><p>{displayValue(change.before)}</p>{change.evidence_quote && <blockquote>“{change.evidence_quote}”</blockquote>}</details> : <><dl>
        <div><dt>Before</dt><dd>{displayValue(change.before)}</dd></div>
        <div><dt>After</dt><dd>{changeValue(change)}</dd></div>
      </dl>
      {change.evidence_quote && <blockquote>“{change.evidence_quote}”</blockquote>}</>}
    </article>
  )
}

function changeValue(change: AdminPersonaSetupChange): string {
  const value = displayValue(change.after)
  return change.path === 'response_shape.min_sentences' || change.path === 'response_shape.max_sentences' ? `${value} sentences` : change.path === 'response_shape.max_characters' ? `${value} characters` : value
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
  const min = changes.find(change => change.path === 'response_shape.min_sentences')?.after
  const max = changes.find(change => change.path === 'response_shape.max_sentences')?.after
  if (group === 'Voice' && min != null && max != null) return `Answers: ${min === max ? min : `${min} to ${max}`} sentences`
  const first = changes.find((change) => change.path === 'voice.tone_traits') ?? changes[0]
  if (!first) return ''
  const value = Array.isArray(first.after) ? first.after.map(displayValue).join(', ') : changeValue(first)
  return `${first.path.startsWith('response_shape.') ? `${suggestionLabel(first)}: ` : ''}${value}`.replaceAll('\n', ' ')
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

function proposalSourceLabel(change: AdminPersonaSetupChange): string {
  if (change.source_basis === 'mia_drafted') return 'Mia drafted'
  const values = (value: unknown): string[] => typeof value === 'string' ? [value] : Array.isArray(value) ? value.flatMap(values) : value && typeof value === 'object' ? Object.values(value).flatMap(values) : []
  const wording = values(change.after)
  if (wording.length && wording.every(value => value && change.evidence_quote.includes(value))) return 'Coach said'
  return 'Suggested from what you said'
}

function suggestionLabel(change: AdminPersonaSetupChange): string {
  const labels: Record<string, string> = {
    'response_shape.min_sentences': 'Shortest answer', 'response_shape.max_sentences': 'Longest answer',
    'response_shape.max_characters': 'Answer length limit', 'response_shape.plain_text_only': 'Plain text answers',
    'coaching.do': 'What to do', 'coaching.do_not': 'What to avoid', 'coaching.method': 'How you teach',
    'coaching.principles': 'What matters in your teaching', 'coaching.philosophy': 'Your approach',
    'voice.tone_traits': 'How you sound', 'voice.accountability_style': 'How you encourage follow-through',
    'voice.language_style': 'Words you use', 'voice.energy': 'Your energy',
    'culture.locale_label': 'Where you coach',
    'identity.assistant_name': 'Assistant name', 'identity.human_coach_name': 'Coach name',
    'identity.assistant_relationship': 'Your assistant’s role', 'identity.audience': 'Who you help',
    'identity.human_coach_title': 'Your coaching role', 'identity.client_term': 'What you call the people you help',
  }
  return labels[change.path] ?? change.label
}

function choiceKey(operation: Record<string, unknown>, item?: unknown) {
  return JSON.stringify([operation.op, operation.path, item ?? operation.value])
}

function proposedValue(session: AdminPersonaSetupSession | null, operation?: Record<string, unknown>) {
  return session?.proposal?.grouped_changes.flatMap(group => group.changes).find(change => change.path === operation?.path)?.after ?? operation?.value
}
