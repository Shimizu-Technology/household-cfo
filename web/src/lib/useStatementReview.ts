import { useEffect, useRef, useState } from 'react'
import { fetchDocumentSourceReview } from '../api'
import { participantErrorMessage } from './participantErrorMessage'
import { validateSourceReview, type SourceReview } from './sourceReview'
import {
  accountNames, accountsNeedingBasis, answerInput, approveRestInput, statementCounts,
  type ApproveLinesInput, type CoverageAnswer, type PlanAnswerId, type PlanAttention,
} from './statementReview'
import { isStatementReviewActor } from './statementReviewRecovery'
import { useStatementReviewMutation } from './useStatementReviewMutation'

export type UnsavedAnswer = { input: ApproveLinesInput; index: number | null; eventId?: number; choice?: PlanAnswerId; categoryId?: number; accountId?: number; basis?: 'asset' | 'liability' }

/**
 * One statement's review as the server plans it: what looks right, the few lines that need her answer, and the saves
 * that answer them. The Statements screen and the chat card both use this, so they save exactly the same things the same way.
 */
export function useStatementReview({ importId, revisionId, refreshKey, page = 1, onSaved, onChanged }: {
  importId: number; revisionId: number; refreshKey: string; page?: number
  /** Every line is saved and nothing is left to ask (also true when the statement was already finished on open). */
  onSaved?: () => void
  /** Something she did was saved, even if the statement is not finished: the numbers that read from it have moved. */
  onChanged?: () => void
}) {
  const [attempt, setAttempt] = useState(0)
  const [savingLines, setSavingLines] = useState(0)
  // What she said about missing lines. It rides along with every save, and the server records it only when the statement is finished.
  const [coverageAnswer, setCoverageAnswer] = useState<CoverageAnswer | null>(null)
  const coverageVersion = useRef<number | null>(null)
  // Her answer is kept on screen if saving it fails, with a plain way to try again; nothing moves on until it is recorded.
  const [coverageFailed, setCoverageFailed] = useState(false)
  const [unsavedAnswer, setUnsavedAnswer] = useState<UnsavedAnswer | null>(null)
  const [result, setResult] = useState<{ key: string; data?: SourceReview; error?: string } | null>(null)
  const savedCallback = useRef(onSaved)
  const changedCallback = useRef(onChanged)
  useEffect(() => { savedCallback.current = onSaved; changedCallback.current = onChanged }, [onSaved, onChanged])
  /** Where keyboard focus goes once a saved answer is read back: the next question's index, or null for the summary. */
  const focusAfter = useRef<number | null | undefined>(undefined)
  const viewKey = `${importId}:${revisionId}:${page}`
  const requestKey = `${viewKey}:${attempt}:${refreshKey}`
  const mutation = useStatementReviewMutation({ importId, revisionId, scope: result?.data?.participant_review?.actor_scope, refresh: () => { setUnsavedAnswer(null); setAttempt((value) => value + 1) } })
  const clearMutationError = mutation.clearError
  const scoped = result?.data?.participant_review
  const actorReady = !scoped || Boolean(scoped.actor_scope && isStatementReviewActor(scoped.actor_scope))
  // The summary and the questions belong to the whole statement, so they stay while another page of lines loads
  // or a saved answer is read back. Callers key this by upload and revision, so nothing here can be another statement's.
  const data = !mutation.accessDenied && actorReady ? result?.data : undefined
  const error = result?.key === requestKey ? result.error : undefined
  // What is on screen was read for an earlier request: a newer read is on its way. Answering from it could use out-of-date lines.
  const refreshing = Boolean(result) && result?.key !== requestKey && !result?.error

  useEffect(() => {
    const controller = new AbortController()
    let live = true
    fetchDocumentSourceReview(importId, revisionId, page, 'all', controller.signal).then((payload) => {
      validateSourceReview(payload, importId, revisionId, page, 'all')
      const review = payload.participant_review
      if (!review?.plan || !review.actor_scope || !Number.isSafeInteger(review.actor_scope.user_id) || !Number.isSafeInteger(review.actor_scope.household_id)) throw new Error('This statement review isn’t available right now. Refresh to continue.')
      if (live) { setResult({ key: requestKey, data: payload }); clearMutationError(); if ((review.plan.coverage.version_id ?? null) !== coverageVersion.current) { setCoverageAnswer(null); setCoverageFailed(false) } }
    }).catch((failure: unknown) => {
      if (live) setResult((previous) => ({ key: requestKey, data: previous?.data, error: participantErrorMessage(failure, 'Could not load this statement.') }))
    })
    return () => { live = false; controller.abort() }
  }, [importId, revisionId, page, requestKey, viewKey, clearMutationError])

  useEffect(() => {
    if (!unsavedAnswer && !coverageFailed) return
    const prevent = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', prevent)
    return () => window.removeEventListener('beforeunload', prevent)
  }, [unsavedAnswer, coverageFailed])

  const review = data?.participant_review
  const plan = review?.plan
  const categories = review?.categories ?? []
  const names = data && review ? accountNames(data.accounts, review.accounts) : {}
  const needBasis = data && review ? accountsNeedingBasis(data.accounts, review.accounts) : []
  const counts = plan ? statementCounts(plan) : null
  const said = coverageAnswer ?? plan?.coverage.answer ?? null
  // Only what the server recorded counts as answered: the next step opens after the save that records it.
  const recorded = plan?.coverage.answer ?? null
  const finished = Boolean(plan && plan.total > 0 && plan.done === plan.total && plan.attention.length === 0 && plan.ready.length === 0 && (!plan.coverage.question || recorded))
  useEffect(() => { if (finished) savedCallback.current?.() }, [finished, recorded])
  const askCoverage = Boolean(plan?.coverage.question) && plan?.total !== 0

  async function save(input: ApproveLinesInput, focusIndex: number | null = null): Promise<boolean> {
    focusAfter.current = focusIndex
    const answer = input.coverage_answer ?? coverageAnswer
    const saved = await mutation.mutate('approve_lines', answer ? { ...input, coverage_answer: answer, expected_coverage_id: coverageVersion.current } : input)
    if (!saved) focusAfter.current = undefined
    else changedCallback.current?.()
    return saved
  }
  async function approveRest(): Promise<boolean> {
    if (!plan) return false
    // A long statement goes a page at a time: the lines of this page are exactly what the request saves.
    // Each line goes with the kind and category she was shown for it; the server saves nothing if any of them has changed.
    const { input, count } = approveRestInput(plan)
    setSavingLines(count)
    try { return await save(input) } finally { setSavingLines(0) }
  }
  // The question is hers to answer. If every line is already saved the answer is saved now; otherwise it goes with the next save.
  function answerCoverage(value: CoverageAnswer) {
    coverageVersion.current = plan?.coverage.version_id ?? null
    setCoverageAnswer(value)
    setCoverageFailed(false)
    if (counts && counts.open === 0 && counts.attention === 0 && plan && plan.total > 0) void save({ lines: [], coverage_answer: value }).then((saved) => setCoverageFailed(!saved))
  }
  function chooseBasis(account: number, basis: 'asset' | 'liability') {
    const pending = { input: { lines: [], accounts: [{ source_account_id: account, account_basis: basis }] }, index: null, accountId: account, basis }
    void save(pending.input).then((saved) => setUnsavedAnswer(saved ? null : pending))
  }
  /** One tap on a question's answer. A line she wants to rewrite ("edit" with no category) is for the line sheet, not this. */
  function answer(item: PlanAttention, index: number, id: PlanAnswerId, categoryId?: number) {
    const pending = { input: answerInput(item, id, categoryId), index, eventId: item.event_id, choice: id, categoryId }
    void save(pending.input, index).then((saved) => setUnsavedAnswer(saved ? null : pending))
  }
  function retryUnsaved() {
    if (unsavedAnswer) void save(unsavedAnswer.input, unsavedAnswer.index).then((saved) => { if (saved) setUnsavedAnswer(null) })
  }
  function reload() { setAttempt((value) => value + 1) }
  function resetAndReload() {
    setUnsavedAnswer(null); setCoverageAnswer(null); setCoverageFailed(false); coverageVersion.current = null
    reload()
  }

  return {
    data, error, refreshing, review, plan, categories, names, needBasis, counts, mutation, busy: mutation.busy,
    coverage: { ask: askCoverage, said, recorded, failed: coverageFailed, answer: answerCoverage, answerAgain: () => { if (coverageAnswer) answerCoverage(coverageAnswer) } },
    finished, savingLines, unsavedAnswer, focusAfterRef: focusAfter,
    save, approveRest, chooseBasis, answer, retryUnsaved, reload, resetAndReload,
  }
}
