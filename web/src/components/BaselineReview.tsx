import { uniqueBaselineAccountLabels } from '../lib/baselineDisplay'
import { useCallback, useEffect, useRef, useState, useMemo, type FormEvent } from 'react'
import { ApiRequestError, fetchBaselineContext, fetchBaselineHistory, fetchFinancialBaseline, previewFinancialBaseline } from '../api'
import { sameBaselineScope, validateBaselineWindow, type BaselineCategoryChoice, type BaselineContext, type BaselineCurrent, type BaselinePreview, type BaselineRequest, type BaselineScope, type BaselineSource, type BaselineVersion, type BaselineReviewedActual, type BaselineReviewedCash } from '../lib/financialBaseline'
import { usePilotDialog } from '../lib/usePilotDialog'
import { useBaselineMutation } from '../lib/useBaselineMutation'
import { isBaselineActor, readBaselineRecovery } from '../lib/baselineRecovery'
import { BaselineObservationReview } from './BaselineObservationReview'
import { BaselinePatterns } from './BaselinePatterns'
import './BaselineReview.css'
type Choice = { eligible: '' | 'yes' | 'no'; recurrence: BaselineCategoryChoice['recurrence']; reason: string }
const errorMessage = (failure: unknown) => failure instanceof Error ? failure.message : 'The private baseline is unavailable. Try again.'
export function BaselineReview({ scope, onClose, onReviewStatements }: { scope: BaselineScope; onClose: () => void; onReviewStatements: () => void }) {
  const dialog = usePilotDialog(onClose)
  const expectedScope = useMemo(() => ({ user_id: scope.user_id, household_id: scope.household_id }), [scope.user_id,scope.household_id])
  const [current, setCurrent] = useState<BaselineCurrent | null>(null)
  const [context, setContext] = useState<BaselineContext | null>(null)
  const [sources, setSources] = useState<BaselineSource[]>([])
  const [decisions,setDecisions] = useState<BaselineReviewedActual[]>([])
  const [allocations,setAllocations] = useState<BaselineReviewedCash[]>([])
  const [observationsOpen,setObservationsOpen] = useState(false)
  const [accountCatalog,setAccountCatalog] = useState<Array<{tracked_account_id:number;label:string}>>([])
  const [accountIds, setAccountIds] = useState<number[]>([])
  const [contextCursor, setContextCursor] = useState<number | null>(null)
  const [contextHistory, setContextHistory] = useState<Array<number | null>>([])
  const [readAttempt, setReadAttempt] = useState(0)
  const [loading, setLoading] = useState(true)
  const [readFailed, setReadFailed] = useState(false)
  const [revoked, setRevoked] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [start, setStart] = useState(''); const [end, setEnd] = useState('')
  const [scopeChecked, setScopeChecked] = useState(false); const [missing, setMissing] = useState('')
  const [cash, setCash] = useState<BaselineRequest['cash_coverage']>('unknown')
  const [choices, setChoices] = useState<Record<string,Choice>>({})
  const [preview, setPreview] = useState<{ record: BaselinePreview; requestKey: string; baseVersion: number | null; lock: number } | null>(null)
  const [previewLoading, setPreviewLoading] = useState(false)
  const [coverage, setCoverage] = useState<'complete' | 'partial' | 'manual'>('partial')
  const [reason, setReason] = useState(''); const [consent, setConsent] = useState(false)
  const [history, setHistory] = useState<{ records: BaselineVersion[]; next_cursor: number | null } | null>(null)
  const [historyCursor, setHistoryCursor] = useState<number | null>(null)
  const [historyPages, setHistoryPages] = useState<Array<number | null>>([])
  const [historyLoading, setHistoryLoading] = useState(false); const [historyError, setHistoryError] = useState<string | null>(null)
  const [historyAttempt, setHistoryAttempt] = useState(0)
  const [historyOpen, setHistoryOpen] = useState(false)
  const epoch = useRef(0); const mounted = useRef(false); const controllers = useRef(new Set<AbortController>())
  const onRevoked = useCallback(() => setRevoked(true), [])
  const initialized = useRef(false); const previewHeading = useRef<HTMLHeadingElement>(null)
  const refresh = useCallback(() => { epoch.current += 1; setPreview(null); setConsent(false); setReadAttempt((value) => value + 1) }, [])
  const mutation = useBaselineMutation({ scope: current && sameBaselineScope(current.actor_scope,expectedScope) ? current.actor_scope : undefined, refresh })
  const privateReady = !revoked && !mutation.accessDenied && current && context && sameBaselineScope(current.actor_scope,expectedScope) && sameBaselineScope(context.actor_scope,expectedScope) && isBaselineActor(expectedScope)
  useEffect(() => { mounted.current = true; const owned = controllers.current; return () => { mounted.current = false; epoch.current += 1; for (const controller of owned) controller.abort(); owned.clear() } }, [])
  useEffect(() => {
    const controller = new AbortController(); const owned = controllers.current; owned.add(controller); let live = true
    Promise.all([fetchFinancialBaseline(controller.signal),fetchBaselineContext(contextCursor,controller.signal)]).then(([head,sourceContext]) => {
      if (!sameBaselineScope(head.actor_scope,expectedScope) || !sameBaselineScope(sourceContext.actor_scope,expectedScope)) { if (live) setRevoked(true); throw new Error('The private workspace changed. Close this view and reopen it in your current workspace.') }
      if (!live) return
      setCurrent(head); setContext(sourceContext); setAccountCatalog((known) => [...new Map([...known,...sourceContext.records.flatMap((source) => source.accounts)].map((account) => [account.tracked_account_id,account])).values()]); setError(null); setReadFailed(false); setLoading(false)
      if (!initialized.current) { initialized.current = true; if (head.approved_version) { setStart(head.approved_version.window_start_on); setEnd(head.approved_version.window_end_on) } }
    }).catch((failure: unknown) => { if (!live) return; setLoading(false); setReadFailed(true); setError(errorMessage(failure)); if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) setRevoked(true) })
    return () => { live = false; controller.abort(); owned.delete(controller) }
  }, [expectedScope,contextCursor,readAttempt])
  useEffect(() => {
    const check = () => { if (!document.hidden && !mutation.busy) { setConsent(false); setPreview(null); setLoading(true); setReadAttempt((value) => value + 1) } }
    window.addEventListener('focus',check); document.addEventListener('visibilitychange',check)
    return () => { window.removeEventListener('focus',check); document.removeEventListener('visibilitychange',check) }
  }, [mutation.busy])
  useEffect(() => {
    if (!historyOpen) return
    const controller = new AbortController(); let live = true
    fetchBaselineHistory(historyCursor,controller.signal).then((page) => { if (!sameBaselineScope(page.actor_scope,expectedScope)) { if (live) setRevoked(true); throw new Error('The private workspace changed. Reopen baseline review.'); } if (live) { setHistory(page); setHistoryError(null); setHistoryLoading(false) } }).catch((failure: unknown) => { if (live) { setHistoryError(errorMessage(failure)); setHistoryLoading(false); if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) setRevoked(true) } })
    return () => { live = false; controller.abort() }
  }, [historyOpen,historyCursor,historyAttempt,expectedScope])
  const categoryChoices: BaselineCategoryChoice[] = Object.entries(choices).filter(([,choice]) => choice.eligible && choice.reason.trim()).map(([id,choice]) => ({ budget_category_id: id === 'uncategorized' ? null : Number(id), eligible: choice.eligible === 'yes', recurrence: choice.recurrence, reason: choice.reason }))
  const request: BaselineRequest = { window_start_on: start, window_end_on: end, revision_ids: sources.map((source) => source.revision_id).sort((a,b) => a-b), tracked_account_ids: [...accountIds].sort((a,b) => a-b), household_scope_attested: scopeChecked, missing_accounts: missing.split('\n').map((line) => line.trim()).filter(Boolean), cash_coverage: cash, category_eligibility: categoryChoices, actual_decisions: decisions.map((item) => item.decision).sort((a,b) => a.transaction_id-b.transaction_id), cash_allocations: allocations.map((item) => item.allocation).sort((a,b) => a.source_review_version_id-b.source_review_version_id || a.transaction_id-b.transaction_id) }
  const requestKey = JSON.stringify(request)
  const fresh = preview && preview.requestKey === requestKey && preview.baseVersion === (current?.approved_version?.id ?? null) && preview.lock === current?.lock_version && !readFailed && !loading && !previewLoading
  const accountChoices = accountCatalog
  function handleProposalChange() { setConsent(false) }
  async function calculate(event: FormEvent) {
    event.preventDefault(); handleProposalChange(); setError(null)
    if (!privateReady || mutation.busy) return
    const sequence = epoch.current; const controller = new AbortController(); controllers.current.add(controller); setPreviewLoading(true)
    try {
      validateBaselineWindow(start,end,context!.local_today)
      if (Object.values(choices).some((choice) => choice.eligible && !choice.reason.trim())) throw new Error('Add an explanation for each category decision, or leave it unreviewed.')
      const record = await previewFinancialBaseline(request,controller.signal)
      if (!mounted.current || epoch.current !== sequence) return
      if (!sameBaselineScope(record.actor_scope,expectedScope)) { setRevoked(true); throw new Error('The private workspace changed. Reopen baseline review.') }
      setPreview({ record,requestKey,baseVersion: current!.approved_version?.id ?? null,lock: current!.lock_version }); setPreviewLoading(false)
      requestAnimationFrame(() => previewHeading.current?.focus())
    } catch (failure) { if (mounted.current && epoch.current === sequence) { setError(errorMessage(failure)); setPreviewLoading(false); if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) setRevoked(true) } }
    finally { controllers.current.delete(controller); if (mounted.current && epoch.current !== sequence) setPreviewLoading(false) }
  }
  async function approve() {
    if (!fresh || !preview || !consent || !reason.trim() || coverage === 'complete' && !preview.record.complete_eligible) return
    const saved = await mutation.mutate(current!.approved_version ? 'revise' : 'approve', { request: preview.record.request, expected_preview_digest: preview.record.digest, base_version_id: preview.baseVersion, base_lock_version: preview.lock, coverage_status: coverage, reason })
    if (!saved && mounted.current) { setConsent(false); if (!readBaselineRecovery(expectedScope)) setPreview((existing) => existing ? { ...existing,requestKey:'' } : null) }
  }
  function sourcePage(cursor: number | null, previous: boolean) { epoch.current += 1; handleProposalChange(); setPreview(null); setLoading(true); setContextCursor(cursor); setContextHistory(previous ? contextHistory.slice(0,-1) : [...contextHistory,contextCursor]) }
  const allCategoryChoices = [...new Map([...(context?.categories ?? []).map((category) => [String(category.id),{ id: category.id,name: category.name }] as const), ...(preview?.record.category_eligibility ?? []).map((category) => [category.budget_category_id === null ? 'uncategorized' : String(category.budget_category_id),{ id: category.budget_category_id,name: category.name }] as const)]).values()]
  return <div className="baseline-overlay"><section ref={dialog} className="baseline-dialog" role="dialog" aria-modal="true" aria-labelledby="baseline-title" tabIndex={-1}><header><div><p className="eyebrow">Optional private spending context</p><h2 id="baseline-title">Review your spending baseline</h2><p>A past-period picture for your savings plan. Statements, a complete budget and debt details are optional. This does not record savings or move money.</p></div><button type="button" onClick={onClose}>Close baseline</button></header>
    {(error || mutation.error) && <div className="baseline-error" role="alert"><p>{error ?? mutation.error}</p>{!mutation.busy && <button type="button" onClick={() => { setLoading(true); refresh() }}>Refresh baseline</button>}</div>}
    {mutation.pendingRequest && <div className="baseline-limit" role="status"><p>An earlier baseline {mutation.pendingRequest.action === 'revise' ? 'revision' : 'approval'} must be resolved before another change. Request identifier: {mutation.pendingRequest.key}</p>{mutation.pendingRequest.input && <p>Reviewed request: {mutation.pendingRequest.input.request.window_start_on} – {mutation.pendingRequest.input.request.window_end_on} · {mutation.pendingRequest.input.coverage_status} context · {mutation.pendingRequest.input.reason}</p>}<button type="button" disabled={mutation.pendingRequest.working} onClick={() => { void mutation.checkStatus?.() }}>Check earlier baseline result</button>{mutation.retry && <button type="button" onClick={() => { void mutation.retry?.() }}>Retry the same baseline request</button>}</div>}
    {revoked || mutation.accessDenied ? <p role="alert">Private baseline access is no longer available. Close this view to continue.</p> : <>
    {loading && <p role="status">Loading current baseline and statement choices…</p>}
    {privateReady && <>
      <section className="baseline-approved" aria-label="Current approved baseline"><h3>{current.approved_version ? `Approved baseline · version ${current.approved_version.version_number}` : 'No approved baseline yet'}</h3>{current.approved_version ? <><p>{current.approved_version.coverage_status === 'complete' ? 'Complete reviewed coverage' : 'Limited ' + current.approved_version.coverage_status + ' context'} · {current.approved_version.reason}</p>{current.needs_revision && <p className="baseline-limit">Current inputs changed. This approved snapshot remains available; review a new preview before replacing it.</p>}<VersionSnapshot version={current.approved_version} sources={sources} title="View the approved snapshot"/></> : <p>You can continue the challenge without a baseline. Build one when it helps.</p>}</section>
      <form className="baseline-form" onSubmit={(event) => { void calculate(event) }}><fieldset disabled={mutation.busy || readFailed || loading || previewLoading}><legend>1. Choose the period and evidence</legend><div className="baseline-fields"><label>Period begins<input type="date" required value={start} max={context.local_today} onChange={(event) => { handleProposalChange(); setStart(event.target.value) }} /></label><label>Period ends<input type="date" required value={end} max={context.local_today} onChange={(event) => { handleProposalChange(); setEnd(event.target.value) }} /></label></div>
        <p>Choose 1–366 past days. Dates alone do not prove complete statement history.</p>
        <details><summary>Choose reviewed statement sources ({sources.length} selected)</summary><p>Choose specific files; no statements are selected automatically. Up to 60 files. Selected files remain selected when you browse other pages.</p>{context.records.length ? context.records.map((source) => <label className="baseline-check" key={source.revision_id}><input type="checkbox" checked={sources.some((item) => item.revision_id === source.revision_id)} disabled={sources.length >= 60 && !sources.some((item) => item.revision_id === source.revision_id)} onChange={(event) => { handleProposalChange(); setSources(event.target.checked ? [...sources,source] : sources.filter((item) => item.revision_id !== source.revision_id)) }} /><span><strong>{source.filename}</strong><small>{source.approved_rows} / {source.total_rows} rows approved · {source.coverage_current ? source.coverage_status ?? 'Coverage unapproved' : 'Coverage needs review'} · {source.source_available ? 'Original available' : 'Original unavailable'}</small>{uniqueBaselineAccountLabels(source.accounts).map((account, index) => <small key={`${account.tracked_account_id}:${index}`}>{account.label} · {account.period_start_on ?? 'Unknown start'} – {account.period_end_on ?? 'Unknown end'}</small>)}</span></label>) : <p>No reviewed statement sources on this page. You can use limited manual context.</p>}<div className="baseline-actions"><button type="button" disabled={!contextHistory.length} onClick={() => sourcePage(contextHistory.at(-1)!,true)}>Previous statement choices</button><button type="button" disabled={context.next_cursor === null} onClick={() => sourcePage(context.next_cursor,false)}>Next statement choices</button></div></details>
        {sources.length > 0 && <section aria-label="Selected baseline statements"><h4>Selected files</h4>{sources.map((source) => <p key={source.revision_id}>{source.filename} <button type="button" onClick={() => { handleProposalChange(); setSources(sources.filter((item) => item.revision_id !== source.revision_id)) }}>Remove {source.filename}</button></p>)}</section>}
        <button type="button" onClick={() => { handleProposalChange(); setSources([]); setAccountIds([]); setCoverage('manual'); setScopeChecked(false); setCash('unknown') }}>Use limited manual context without statements</button>
        <div className="baseline-limit"><p>Source rows must be individually approved in Statements first. This baseline reads current approved facts; it does not approve extraction guesses.</p><button type="button" onClick={onReviewStatements}>Open statement review</button></div>
        <h4>Household accounts in this period</h4>{accountChoices.length ? accountChoices.map((account) => <label className="baseline-check" key={account.tracked_account_id}><input type="checkbox" checked={accountIds.includes(account.tracked_account_id)} onChange={(event) => { handleProposalChange(); setAccountIds(event.target.checked ? [...accountIds,account.tracked_account_id] : accountIds.filter((id) => id !== account.tracked_account_id)) }} />{account.label}</label>) : <p>No recognized statement accounts are available on the pages you’ve reviewed. Without statement accounts, the baseline remains qualified.</p>}<label className="baseline-check"><input type="checkbox" checked={scopeChecked} onChange={(event) => { handleProposalChange(); setScopeChecked(event.target.checked) }} />I checked which household accounts this period should cover, and listed known gaps below.</label><label>Missing account history (one account or gap per line)<textarea maxLength={3000} value={missing} onChange={(event) => { handleProposalChange(); setMissing(event.target.value) }} placeholder="Describe known gaps; leave blank if none are known." /></label>
        <label>Cash coverage<select value={cash} onChange={(event) => { handleProposalChange(); setCash(event.target.value as typeof cash) }}><option value="unknown">Unknown — I have not checked cash</option><option value="partial">Partial — some cash spending is missing</option><option value="complete">Complete — I checked cash spending for this period</option><option value="not_used">I did not use cash in this period</option></select></label>
        <details><summary>2. Review category consideration and recurrence</summary><p>Unreviewed is the default. Choose whether each used category should be considered in spending discussions, then explain your choice. This never declares saved money or a guaranteed cut.</p>{allCategoryChoices.map((category) => { const key = category.id === null ? 'uncategorized' : String(category.id); const choice = choices[key] ?? { eligible: '',recurrence: 'unknown',reason: '' }; const update = (next: Choice) => { handleProposalChange(); setChoices({ ...choices,[key]:next }) }; return <article key={key}><h4>{category.name}</h4><label>Consider {category.name} for spending review<select value={choice.eligible} onChange={(event) => update({ ...choice,eligible: event.target.value as Choice['eligible'] })}><option value="">Unreviewed</option><option value="yes">Yes, consider this category</option><option value="no">No, keep it outside consideration</option></select></label><label>Recurrence for {category.name}<select value={choice.recurrence} onChange={(event) => update({ ...choice,recurrence:event.target.value as Choice['recurrence'] })}>{['unknown','recurring','one_off','seasonal','annual'].map((recurrence) => <option key={recurrence} value={recurrence}>{recurrence.replaceAll('_',' ')}</option>)}</select></label><label>Explanation for {category.name}<input maxLength={500} value={choice.reason} onChange={(event) => update({ ...choice,reason:event.target.value })} /></label></article> })}</details>
        <details onToggle={(event) => { if (event.currentTarget.open) setObservationsOpen(true) }}><summary>Review existing transactions, duplicates and cash allocations</summary>{observationsOpen && start && end && start <= end && end <= context.local_today ? <BaselineObservationReview key={`${start}:${end}`} start={start} end={end} scope={expectedScope} accounts={accountChoices} onRevoked={onRevoked} decisions={decisions} allocations={allocations} onDecisions={(value) => { handleProposalChange(); setDecisions(value) }} onAllocations={(value) => { handleProposalChange(); setAllocations(value) }} disabled={mutation.busy || loading || previewLoading} /> : <p>Choose a valid past period first. Existing records remain unreviewed until you explicitly decide them.</p>}</details>
        <button type="submit">Preview baseline and limitations</button>
      </fieldset></form>
      {preview && <section className="baseline-preview" aria-label="Proposed baseline preview"><h3 ref={previewHeading} tabIndex={-1}>3. Review before approving</h3>{!fresh && <p className="baseline-limit" role="status">This preview is out of date. Preview your current choices again before approval.</p>}<BaselinePatterns key={preview.record.digest} preview={preview.record} sources={sources} /><fieldset disabled={mutation.busy || !fresh}><legend>Separate baseline approval</legend><label>Approved coverage description<select value={coverage} onChange={(event) => { setCoverage(event.target.value as typeof coverage); setConsent(false) }}><option value="partial">Partial — approve with the listed limits</option><option value="manual">Manual — limited context, not complete history</option><option value="complete" disabled={!preview.record.complete_eligible}>Complete — all coverage checks passed</option></select></label><label>Baseline approval explanation<input required maxLength={500} value={reason} onChange={(event) => { setReason(event.target.value); setConsent(false) }} /></label><label className="baseline-check"><input type="checkbox" checked={consent} onChange={(event) => setConsent(event.target.checked)} />I reviewed this period, selected evidence, category choices, patterns and limitations. Approve this exact baseline; it does not record savings.</label><button type="button" disabled={!consent || !reason.trim() || coverage === 'complete' && !preview.record.complete_eligible} onClick={() => { void approve() }}>{current.approved_version ? 'Approve baseline revision' : 'Approve baseline'}</button></fieldset></section>}
      <details onToggle={(event) => { if (event.currentTarget.open && !historyOpen) { setHistoryLoading(true); setHistoryOpen(true) } }}><summary>Previous approved baselines</summary>{historyLoading && <p role="status">Loading baseline history…</p>}{historyError && <div role="alert"><p>{historyError}</p><button type="button" onClick={() => { setHistoryLoading(true); setHistoryAttempt((value) => value + 1) }}>Retry baseline history</button></div>}{history?.records.map((version) => <VersionSnapshot key={version.id} version={version} sources={sources} />)}{history && !historyLoading && history.records.length === 0 && <p>No prior baseline versions.</p>}<div className="baseline-actions"><button type="button" disabled={historyLoading || !historyPages.length} onClick={() => { setHistoryLoading(true); setHistoryCursor(historyPages.at(-1)!); setHistoryPages(historyPages.slice(0,-1)) }}>Previous baseline versions</button><button type="button" disabled={historyLoading || history?.next_cursor == null} onClick={() => { setHistoryLoading(true); setHistoryPages([...historyPages,historyCursor]); setHistoryCursor(history!.next_cursor) }}>Next baseline versions</button></div></details>
      <button type="button" disabled={mutation.busy} onClick={() => { setLoading(true); refresh() }}>Refresh current baseline and choices</button>
    </>}
    </>}
  </section></div>
}

function VersionSnapshot({ version,sources,title }: { version:BaselineVersion;sources:BaselineSource[];title?:string }) { const[open,setOpen]=useState(false);return <details onToggle={(event)=>setOpen(event.currentTarget.open)}><summary>{title ?? `Version ${version.version_number} · ${version.window_start_on} – ${version.window_end_on} · ${version.coverage_status}`}</summary>{open && <><p>{version.reason}</p><BaselinePatterns preview={version.preview} sources={sources}/></>}</details> }
