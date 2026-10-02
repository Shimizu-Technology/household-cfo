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
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

type AuthoringState = { description: string; draft_config: PersonaConfiguration }

export function PersonaSetupChat({
  persona,
  manualDirty,
  mutationLifecycle,
  onPersonaChange,
  onReviewInForm,
  onDirtyChange,
}: {
  persona: AdminPersonaDetail
  manualDirty: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onPersonaChange: (persona: AdminPersonaDetail) => void
  onReviewInForm: (state: AuthoringState, firstPath: string | null) => void
  onDirtyChange: (dirty: boolean) => void
}) {
  const [session, setSession] = useState<AdminPersonaSetupSession | null>(null)
  const [message, setMessage] = useState('')
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
  const composerRef = useRef<HTMLTextAreaElement | null>(null)
  const proposalHeadingRef = useRef<HTMLHeadingElement | null>(null)
  const resolutionRetryKeysRef = useRef<Map<string, string>>(new Map())
  const resolutionRetryScopeRef = useRef<{ sessionId: number; proposalId: number } | null>(null)
  useLayoutEffect(() => {
    personaIdRef.current = persona.id
  }, [persona.id])

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

  const groupedChanges = useMemo(() => session?.proposal?.grouped_changes ?? [], [session])

  async function sendMessage(event: FormEvent) {
    event.preventDefault()
    const trimmed = message.trim()
    if (!session || !trimmed || pending || session.stale) return
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
      setSession(next)
      const latestTurn = next.turns[next.turns.length - 1]
      if (!latestTurn || latestTurn.status !== 'ready' || !next.proposal) {
        if (latestTurn?.status !== 'processing') setRetryKey(null)
        setError(latestTurn?.assistant_message || (latestTurn?.status === 'processing'
          ? 'Mia is still preparing this proposal. Retry shortly with the same request.'
          : 'Mia could not prepare this proposal. Your message is ready to retry.'))
        return
      }
      setMessage('')
      setRetryKey(null)
      setAnnouncement('Mia prepared a proposal for your review.')
      window.requestAnimationFrame(() => proposalHeadingRef.current?.focus())
    } catch (caught) {
      if (isCurrent(sequence, personaId, ticket)) {
        const returnedSession = setupSessionFromError(caught, session.id)
        if (returnedSession) {
          setSession(returnedSession)
          const latestTurn = returnedSession.turns[returnedSession.turns.length - 1]
          if (latestTurn?.status !== 'processing') setRetryKey(null)
        }
        setError(setupErrorMessage(caught, 'Mia could not prepare this proposal. Try again.'))
      }
    } finally {
      if (isCurrent(sequence, personaId, ticket)) setPending(null)
      finishMutation(ticket)
    }
  }

  async function resolveProposal(action: 'apply' | 'reject') {
    const proposal = session?.proposal
    if (!session || !proposal || pending || (action === 'apply' && manualDirty)) return
    const ticket = beginMutation()
    const sequence = ++requestSequence.current
    const personaId = persona.id
    const retryScope = resolutionRetryScopeRef.current
    if (retryScope?.sessionId !== session.id || retryScope.proposalId !== proposal.id) {
      resolutionRetryKeysRef.current.clear()
      resolutionRetryScopeRef.current = { sessionId: session.id, proposalId: proposal.id }
    }
    const retrySlot = `${proposal.id}:${action}`
    const key = resolutionRetryKeysRef.current.get(retrySlot) ?? requestKey()
    resolutionRetryKeysRef.current.set(retrySlot, key)
    setPending(action)
    setError(null)
    try {
      const result = await resolveAdminPersonaSetupProposal(personaId, session.id, proposal.id, action, key)
      if (!isCurrent(sequence, personaId, ticket)) return
      resolutionRetryKeysRef.current.clear()
      resolutionRetryScopeRef.current = null
      setSession(result.session)
      if (result.persona) onPersonaChange(result.persona)
      setAnnouncement(action === 'apply' ? 'Proposal applied to the saved draft.' : 'Proposal rejected. You can keep chatting.')
      window.requestAnimationFrame(() => composerRef.current?.focus())
    } catch (caught) {
      if (isCurrent(sequence, personaId, ticket)) setError(setupErrorMessage(caught, `The proposal could not be ${action === 'apply' ? 'applied' : 'rejected'}.`))
    } finally {
      if (isCurrent(sequence, personaId, ticket)) setPending(null)
      finishMutation(ticket)
    }
  }

  function retryOpenSession() {
    if (loading || pending) return
    setError(null)
    setLoading(true)
    setLoadAttempt((attempt) => attempt + 1)
  }

  async function updateSession(action: 'rebase' | 'abandon') {
    if (!session || pending) return
    const ticket = beginMutation()
    const sequence = ++requestSequence.current
    const personaId = persona.id
    setPending(action)
    setError(null)
    try {
      if (action === 'abandon') {
        if (session.status === 'active') {
          const abandoned = await abandonAdminPersonaSetupSession(personaId, session.id)
          if (!isCurrent(sequence, personaId, ticket)) return
          setSession(abandoned)
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
        setAnnouncement('Setup chat rebased onto the latest saved draft.')
      }
    } catch (caught) {
      if (isCurrent(sequence, personaId, ticket)) setError(setupErrorMessage(caught, 'The setup chat could not be updated.'))
    } finally {
      if (isCurrent(sequence, personaId, ticket)) setPending(null)
      finishMutation(ticket)
    }
  }

  function isCurrent(sequence: number, personaId: number, ticket: ReturnType<CoachWorkspaceMutationLifecycle['begin']>) {
    return sequence === requestSequence.current && personaIdRef.current === personaId && mutationIsCurrent(ticket)
  }

  if (loading) return <div className="persona-setup-loading" role="status">Opening your private setup chat…</div>

  return (
    <div className="persona-setup-layout">
      <section className="persona-setup-chat" aria-labelledby="persona-setup-chat-title">
        <header>
          <p className="eyebrow">Private coach workspace</p>
          <h4 id="persona-setup-chat-title">Tell Mia how this assistant should work</h4>
          <p>Describe the coach, audience, voice, community context, teaching approach, or response style. Mia will propose exact draft changes for you to review.</p>
        </header>
        <div className="persona-setup-privacy" role="note">
          Your setup messages and this persona draft may be sent to the configured model. Participant household and financial data are excluded. Nothing changes until you apply a reviewed proposal.
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
            <strong>The saved draft changed.</strong>
            <span>Rebase this chat before asking Mia for another proposal.</span>
            <Button variant="secondary" disabled={pending !== null} onClick={() => void updateSession('rebase')}>{pending === 'rebase' ? 'Rebasing…' : 'Rebase chat'}</Button>
          </div>
        )}
        <div className="persona-setup-transcript" role="log" aria-live="polite" aria-relevant="additions text">
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
          )) : <p className="persona-setup-empty">Start with what makes this coach’s approach distinct. Use exact wording for names, local facts, references, and phrases.</p>}
        </div>
        <form className="persona-setup-composer" onSubmit={sendMessage}>
          <label htmlFor={`persona-setup-message-${persona.id}`}>Message Mia</label>
          <textarea
            ref={composerRef}
            id={`persona-setup-message-${persona.id}`}
            rows={4}
            maxLength={4000}
            value={message}
            disabled={!session || pending !== null || session?.stale}
            onChange={(event) => {
              setMessage(event.target.value)
              setRetryKey(null)
            }}
            placeholder="For example: Her name is Mrs. Mel. Please use a warm, direct tone and ask one practical question at a time."
          />
          <div><small>{message.length}/4,000</small><Button type="submit" disabled={!message.trim() || !session || pending !== null || session.stale}>{pending === 'send' ? 'Mia is preparing…' : retryKey ? 'Retry message' : 'Send to Mia'}</Button></div>
        </form>
        <button className="persona-setup-start-over" type="button" disabled={!session || pending !== null} onClick={() => void updateSession('abandon')}>Start a fresh setup chat</button>
      </section>

      <section className="persona-setup-review" aria-labelledby="persona-setup-review-title">
        <header>
          <p className="eyebrow">Review before applying</p>
          <h4 id="persona-setup-review-title" ref={proposalHeadingRef} tabIndex={-1}>Proposed draft changes</h4>
        </header>
        {!session?.proposal ? (
          <div className="persona-setup-no-proposal"><p>No proposal yet.</p><small>Mia will show every suggested change here before anything is saved.</small></div>
        ) : (
          <>
            <div className="persona-proposal-groups">
              {groupedChanges.map((group) => (
                <section key={group.group}>
                  <h5>{group.group}</h5>
                  {group.changes.map((change) => <ProposalChange key={`${change.path}-${change.label}`} change={change} />)}
                </section>
              ))}
            </div>
            {manualDirty && <p className="persona-setup-apply-blocked" role="note">Save or discard your manual form changes before applying this proposal.</p>}
            <div className="persona-setup-review-actions">
              <Button disabled={pending !== null || manualDirty} onClick={() => void resolveProposal('apply')}>{pending === 'apply' ? 'Applying…' : 'Apply to saved draft'}</Button>
              <Button variant="secondary" disabled={pending !== null} onClick={() => onReviewInForm(session.proposal!.after_state, session.proposal!.operations[0]?.path as string | undefined ?? null)}>Review in form</Button>
              <Button variant="secondary" disabled={pending !== null} onClick={() => composerRef.current?.focus()}>Keep chatting</Button>
              <button type="button" className="persona-setup-reject" disabled={pending !== null} onClick={() => void resolveProposal('reject')}>{pending === 'reject' ? 'Rejecting…' : 'Reject proposal'}</button>
            </div>
          </>
        )}
      </section>
      <p className="sr-only" aria-live="assertive">{announcement}</p>
    </div>
  )
}

function ProposalChange({ change }: { change: AdminPersonaSetupChange }) {
  return (
    <article className="persona-proposal-change">
      <header><strong>{change.label}</strong><span>{change.source_basis === 'coach_quote' ? 'Coach said' : 'Mia drafted'}</span></header>
      <dl>
        <div><dt>Before</dt><dd>{displayValue(change.before)}</dd></div>
        <div><dt>After</dt><dd>{displayValue(change.after)}</dd></div>
      </dl>
      {change.evidence_quote && <blockquote>“{change.evidence_quote}”</blockquote>}
    </article>
  )
}

function displayValue(value: unknown) {
  if (value === null || value === undefined || value === '') return 'Not set'
  if (typeof value === 'string') return value
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  if (Array.isArray(value)) return value.length ? value.map((item) => typeof item === 'string' ? item : JSON.stringify(item)).join('\n') : 'None'
  return JSON.stringify(value, null, 2)
}

function requestKey() {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`
}

function setupErrorMessage(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback
}

function setupSessionFromError(error: unknown, expectedSessionId: number) {
  if (!(error instanceof ApiRequestError)) return null
  const value = error.payload.session
  if (!value || typeof value !== 'object' || !('id' in value) || value.id !== expectedSessionId) return null
  return value as AdminPersonaSetupSession
}
