import { useEffect, useMemo, useRef, useState } from 'react'
import {
  ApiRequestError,
  attestAdminPhraseProposal,
  createAdminPhraseProposal,
  fetchAdminContentSourcePhraseProposals,
  fetchAdminPhraseProposal,
  promoteAdminPhraseProposal,
  submitAdminPhraseProposal,
  updateAdminPhraseProposal,
} from '../api'
import type {
  AdminApprovedPhrase,
  AdminContentSourceCandidate,
  AdminPersonaDetail,
  AdminPhraseProposal,
  AdminPhraseProposalCollectionPermissions,
  PersonaPhraseContext,
  PersonaPhraseFrequency,
} from '../api'
import { PERSONA_PHRASE_CONTEXTS } from '../lib/personaDraft'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const frequencies: Array<{ value: PersonaPhraseFrequency; label: string }> = [
  { value: 'very_rare', label: 'Very rare' },
  { value: 'rare', label: 'Rare' },
  { value: 'sparing', label: 'Sparing' },
  { value: 'as_needed', label: 'As needed' },
]

const noPermissions: AdminPhraseProposalCollectionPermissions = { view: false, propose: false, review: false, promote: false }

export function CoachPhraseProposalPanel({
  sourceId,
  candidate,
  selectedPersona,
  mutationLifecycle,
  disabled,
  onDirtyChange,
  onBusyChange,
  onPersonaChange,
}: {
  sourceId: number
  candidate: AdminContentSourceCandidate
  selectedPersona: AdminPersonaDetail | null
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  disabled: boolean
  onDirtyChange: (dirty: boolean) => void
  onBusyChange: (busy: boolean) => void
  onPersonaChange: (persona: AdminPersonaDetail) => void
}) {
  const versionId = candidate.accepted_content_item_version_id
  const [proposals, setProposals] = useState<AdminPhraseProposal[]>([])
  const [permissions, setPermissions] = useState(noPermissions)
  const [selectedId, setSelectedId] = useState<number | null>(null)
  const [draft, setDraft] = useState<AdminApprovedPhrase>(() => initialPhrase(candidate))
  const [creating, setCreating] = useState(false)
  const [loading, setLoading] = useState(Boolean(versionId))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [confirmDecision, setConfirmDecision] = useState<'approved' | 'rejected' | null>(null)
  const errorRef = useRef<HTMLDivElement>(null)
  const noticeRef = useRef<HTMLDivElement>(null)
  const confirmRef = useRef<HTMLDivElement>(null)

  const matching = useMemo(
    () => proposals.filter((proposal) => proposal.content_item_version_id === versionId),
    [proposals, versionId],
  )
  const selected = matching.find((proposal) => proposal.id === selectedId) ?? null
  const phraseDirty = Boolean(selected && selected.permissions.edit && !samePhrase(draft, selected.phrase))
  const createDirty = creating && !samePhrase(draft, initialPhrase(candidate))
  const dirty = phraseDirty || createDirty
  const valid = phraseValid(draft)
  const blocked = disabled || busy || loading

  useEffect(() => onDirtyChange(dirty), [dirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])
  useEffect(() => onBusyChange(busy), [busy, onBusyChange])
  useEffect(() => () => onBusyChange(false), [onBusyChange])
  useEffect(() => { if (error) queueMicrotask(() => errorRef.current?.focus()) }, [error])
  useEffect(() => { if (notice) queueMicrotask(() => noticeRef.current?.focus()) }, [notice])
  useEffect(() => { if (confirmDecision) queueMicrotask(() => confirmRef.current?.querySelector<HTMLButtonElement>('button:last-child')?.focus()) }, [confirmDecision])

  useEffect(() => {
    if (!versionId) return
    let cancelled = false
    void fetchAdminContentSourcePhraseProposals(sourceId).then((result) => {
      if (cancelled) return
      const relevant = result.phrase_proposals.filter((proposal) => proposal.content_item_version_id === versionId)
      const preferred = relevant.find((proposal) => proposal.status === 'draft')
        ?? relevant.find((proposal) => proposal.status === 'submitted' && !proposal.attestation)
        ?? relevant[0]
        ?? null
      setProposals(result.phrase_proposals)
      setPermissions(result.permissions)
      setSelectedId(preferred?.id ?? null)
      setCreating(!preferred && result.permissions.propose)
      setDraft(preferred?.phrase ?? initialPhrase(candidate))
    }).catch((caught) => {
      if (!cancelled) setError(messageFor(caught, 'Phrase review could not load.'))
    }).finally(() => {
      if (!cancelled) setLoading(false)
    })
    return () => { cancelled = true }
  }, [candidate, sourceId, versionId])

  if (candidate.kind !== 'phrase' || candidate.status !== 'accepted') return null

  if (!versionId) {
    return (
      <section className="coach-phrase-review" aria-label="Approved phrase review">
        <div className="coach-phrase-review-heading">
          <div><p className="eyebrow">Phrase promotion</p><h5>Approve the content draft first</h5></div>
          <span className="coach-phrase-stage">Waiting for approval</span>
        </div>
        <p>The accepted source candidate is still a content draft. Approve its exact version below before proposing wording for an assistant.</p>
      </section>
    )
  }

  function chooseProposal(proposal: AdminPhraseProposal) {
    if (dirty || blocked) return
    setSelectedId(proposal.id)
    setDraft(proposal.phrase)
    setCreating(false)
    setError(null)
    setNotice(null)
    setConfirmDecision(null)
  }

  function startProposal() {
    if (dirty || blocked) return
    setSelectedId(null)
    setDraft(initialPhrase(candidate))
    setCreating(true)
    setError(null)
    setNotice(null)
  }

  function replaceProposal(next: AdminPhraseProposal) {
    setProposals((current) => [next, ...current.filter((proposal) => proposal.id !== next.id)])
    setSelectedId(next.id)
    setDraft(next.phrase)
    setCreating(false)
  }

  async function saveDraft(): Promise<AdminPhraseProposal | null> {
    if (!valid || !versionId) return null
    return runMutation(async () => {
      const next = selected
        ? await updateAdminPhraseProposal(selected, normalizedPhrase(draft))
        : await createAdminPhraseProposal(sourceId, {
          candidate_id: candidate.id,
          content_item_version_id: versionId,
          phrase: normalizedPhrase(draft),
        })
      replaceProposal(next)
      setNotice('Phrase proposal saved as a private draft. It is not available to any assistant.')
      return next
    }, 'The phrase proposal could not be saved.')
  }

  async function submitForReview() {
    let proposal = selected
    if (!proposal || dirty || creating) proposal = await saveDraft()
    if (!proposal) return
    await runMutation(async () => {
      const next = await submitAdminPhraseProposal(proposal!)
      replaceProposal(next)
      setNotice('Phrase proposal submitted. A reviewer must approve or reject its exact wording and safety settings.')
      return next
    }, 'The phrase proposal could not be submitted.')
  }

  async function attest(decision: 'approved' | 'rejected') {
    if (!selected) return
    setConfirmDecision(null)
    await runMutation(async () => {
      const next = await attestAdminPhraseProposal(selected, decision)
      replaceProposal(next)
      setNotice(decision === 'approved'
        ? 'Exact phrase wording and safety settings approved. It is still unavailable until promoted to an assistant.'
        : 'Phrase proposal rejected. It will remain unavailable to assistants.')
      return next
    }, 'The phrase review decision could not be saved.')
  }

  async function promote() {
    if (!selected || selectedPersona?.draft_revision == null) return
    await runMutation(async () => {
      const result = await promoteAdminPhraseProposal(selectedPersona.id, selected.id, selectedPersona.draft_revision!)
      onPersonaChange(result.persona)
      const latest = await fetchAdminPhraseProposal(selected.id)
      replaceProposal(latest)
      setNotice(`Phrase added to ${result.persona.name} as a locked reviewed artifact. Preview and publish that assistant before participants can use it.`)
      return latest
    }, 'The approved phrase could not be added to the selected assistant.')
  }

  async function reloadProposal() {
    if (!selectedId) return
    setLoading(true)
    setError(null)
    try {
      const latest = await fetchAdminPhraseProposal(selectedId)
      replaceProposal(latest)
      setNotice('Latest server version loaded. Review it before continuing.')
    } catch (caught) {
      setError(messageFor(caught, 'The latest phrase proposal could not load.'))
    } finally {
      setLoading(false)
    }
  }

  async function runMutation<T>(callback: () => Promise<T>, fallback: string): Promise<T | null> {
    if (blocked) return null
    const ticket = mutationLifecycle.begin()
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const result = await callback()
      return mutationLifecycle.isCurrent(ticket) ? result : null
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket)) setError(messageFor(caught, fallback))
      return null
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setBusy(false)
      mutationLifecycle.finish(ticket)
    }
  }

  const editable = creating ? permissions.propose : selected?.permissions.edit === true
  const stage = selected ? stageLabel(selected) : 'New private draft'

  return (
    <section className="coach-phrase-review" aria-label="Approved phrase review" aria-busy={loading || busy}>
      <div className="coach-phrase-review-heading">
        <div><p className="eyebrow">Phrase promotion</p><h5>Review exact wording before any assistant can use it</h5></div>
        <span className={`coach-phrase-stage is-${selected?.attestation?.decision ?? selected?.status ?? 'draft'}`}>{stage}</span>
      </div>
      <p className="coach-phrase-boundary">This proposal carries only the approved phrase and its safety settings. Private source evidence stays out of assistant setup and participant chat.</p>

      {error && <div className="coach-phrase-message is-error" role="alert" tabIndex={-1} ref={errorRef}><span>{error}</span>{selectedId && <button type="button" onClick={() => void reloadProposal()}>Reload latest review</button>}</div>}
      {notice && <div className="coach-phrase-message is-success" role="status" tabIndex={-1} ref={noticeRef}>{notice}</div>}
      {loading && <p role="status">Loading phrase review…</p>}

      {!loading && matching.length > 1 && <div className="coach-phrase-history" aria-label="Phrase proposal history">
        {matching.map((proposal) => <button type="button" key={proposal.id} aria-current={proposal.id === selectedId ? 'true' : undefined} disabled={blocked || dirty} onClick={() => chooseProposal(proposal)}><span>Review {proposal.id}</span><small>{stageLabel(proposal)}</small></button>)}
      </div>}

      {!loading && (creating || selected) && <form className="coach-phrase-form" onSubmit={(event) => { event.preventDefault(); void saveDraft() }}>
        <label className="is-wide"><span>Exact phrase</span><input required maxLength={100} disabled={!editable || blocked} value={draft.text} onChange={(event) => setDraft({ ...draft, text: event.target.value })} /><small>Must match wording in the approved source version exactly.</small></label>
        <label className="is-wide"><span>Meaning and intent</span><textarea required rows={2} maxLength={300} disabled={!editable || blocked} value={draft.meaning} onChange={(event) => setDraft({ ...draft, meaning: event.target.value })} /></label>
        <label><span>Frequency</span><select disabled={!editable || blocked} value={draft.frequency} onChange={(event) => setDraft({ ...draft, frequency: event.target.value as PersonaPhraseFrequency })}>{frequencies.map((frequency) => <option value={frequency.value} key={frequency.value}>{frequency.label}</option>)}</select></label>
        <label className="is-wide"><span>Caution</span><textarea rows={2} maxLength={300} disabled={!editable || blocked} value={draft.caution} onChange={(event) => setDraft({ ...draft, caution: event.target.value })} placeholder="When should the assistant avoid or qualify this phrase?" /></label>
        <ContextField label="Allowed contexts" values={draft.allowed_contexts} disabled={!editable || blocked} onChange={(allowed_contexts) => setDraft({ ...draft, allowed_contexts })} />
        <ContextField label="Prohibited contexts" values={draft.prohibited_contexts} disabled={!editable || blocked} onChange={(prohibited_contexts) => setDraft({ ...draft, prohibited_contexts })} />
        {hasContextOverlap(draft) && <p className="coach-phrase-validation" role="alert">A context cannot be both allowed and prohibited.</p>}
        <div className="coach-phrase-actions">
          {editable && <Button type="submit" variant="secondary" disabled={blocked || !valid || (!dirty && !creating)}>Save private draft</Button>}
          {(creating || selected?.permissions.submit) && <Button type="button" disabled={blocked || !valid} onClick={() => void submitForReview()}>{dirty || creating ? 'Save and submit for review' : 'Submit for review'}</Button>}
          {selected?.permissions.review && !confirmDecision && <><Button type="button" disabled={blocked} onClick={() => setConfirmDecision('approved')}>Approve exact phrase</Button><Button type="button" variant="ghost" disabled={blocked} onClick={() => setConfirmDecision('rejected')}>Reject</Button></>}
        </div>
      </form>}

      {confirmDecision && <div className="coach-phrase-confirm" role="alert" tabIndex={-1} ref={confirmRef}><p>{confirmDecision === 'approved' ? 'Approve this exact wording, meaning, frequency, and context policy?' : 'Reject this proposal and keep it unavailable to assistants?'}</p><Button size="compact" variant="ghost" disabled={blocked} onClick={() => setConfirmDecision(null)}>Cancel</Button><Button size="compact" variant={confirmDecision === 'rejected' ? 'danger' : 'primary'} disabled={blocked} onClick={() => void attest(confirmDecision)}>{confirmDecision === 'approved' ? 'Yes, approve' : 'Yes, reject'}</Button></div>}

      {selected?.permissions.promote && selected.attestation?.decision === 'approved' && <div className="coach-phrase-promote">
        <div><strong>Add the reviewed phrase to an assistant</strong><p>{selectedPersona ? `Selected assistant: ${selectedPersona.name}. The phrase stays locked to this review record.` : 'Choose an assistant in Assistant voice, then return here.'}</p></div>
        <Button disabled={blocked || selectedPersona?.draft_revision == null} onClick={() => void promote()}>{selected.promotion_count > 0 ? 'Add to selected assistant' : 'Promote to selected assistant'}</Button>
      </div>}

      {!loading && !creating && matching.length === 0 && permissions.propose && <Button variant="secondary" disabled={blocked} onClick={startProposal}>Propose reviewed phrase</Button>}
      {!loading && !creating && selected?.attestation?.decision === 'rejected' && permissions.propose && <Button variant="secondary" disabled={blocked || dirty} onClick={startProposal}>Start revised proposal</Button>}
      {!loading && matching.length === 0 && !permissions.propose && <p className="coach-phrase-boundary">An editor must prepare this phrase proposal before review can begin.</p>}
    </section>
  )
}

function ContextField({ label, values, disabled, onChange }: { label: string; values: PersonaPhraseContext[]; disabled: boolean; onChange: (values: PersonaPhraseContext[]) => void }) {
  return <fieldset className="coach-phrase-context"><legend>{label}</legend><div>{PERSONA_PHRASE_CONTEXTS.map((context) => <label key={context}><input type="checkbox" checked={values.includes(context)} disabled={disabled} onChange={(event) => onChange(event.target.checked ? [...values, context] : values.filter((value) => value !== context))} /><span>{titleize(context)}</span></label>)}</div></fieldset>
}

function initialPhrase(candidate: AdminContentSourceCandidate): AdminApprovedPhrase {
  return {
    text: candidate.content.trim().slice(0, 100),
    meaning: '',
    allowed_contexts: ['general'],
    prohibited_contexts: ['crisis'],
    frequency: 'rare',
    caution: '',
  }
}

function normalizedPhrase(phrase: AdminApprovedPhrase): AdminApprovedPhrase {
  return {
    ...phrase,
    text: phrase.text.trim().replace(/\s+/g, ' '),
    meaning: phrase.meaning.trim(),
    caution: phrase.caution.trim(),
    allowed_contexts: [...new Set(phrase.allowed_contexts)],
    prohibited_contexts: [...new Set(phrase.prohibited_contexts)],
  }
}

function phraseValid(phrase: AdminApprovedPhrase) {
  const normalized = normalizedPhrase(phrase)
  return normalized.text.length > 0 && normalized.text.length <= 100 && normalized.meaning.length > 0 &&
    normalized.meaning.length <= 300 && normalized.caution.length <= 300 && normalized.allowed_contexts.length > 0 &&
    !hasContextOverlap(normalized)
}

function hasContextOverlap(phrase: AdminApprovedPhrase) {
  return phrase.allowed_contexts.some((context) => phrase.prohibited_contexts.includes(context))
}

function samePhrase(left: AdminApprovedPhrase, right: AdminApprovedPhrase) {
  return JSON.stringify(normalizedPhrase(left)) === JSON.stringify(normalizedPhrase(right))
}

function stageLabel(proposal: AdminPhraseProposal) {
  if (proposal.attestation?.decision === 'approved') return 'Reviewed and approved'
  if (proposal.attestation?.decision === 'rejected') return 'Reviewed and rejected'
  if (proposal.status === 'submitted') return 'Waiting for reviewer'
  if (proposal.status === 'superseded') return 'Source no longer current'
  return 'Private draft'
}

function messageFor(caught: unknown, fallback: string) {
  if (caught instanceof ApiRequestError) return caught.message
  if (caught instanceof Error && caught.message) return caught.message
  return fallback
}

function titleize(value: string) {
  return value.replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase())
}
