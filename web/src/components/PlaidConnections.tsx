import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { usePlaidLink, type PlaidLinkOnExit, type PlaidLinkOnSuccess } from 'react-plaid-link'
import {
  captureApiOperation,
  getApiFinancialGeneration,
  resumePlaidItemFinancialPicture,
  createPlaidLinkToken,
  createPlaidUpdateLinkToken,
  disconnectPlaidItem,
  exchangePlaidPublicToken,
  fetchPlaidOverview,
  fetchPlaidTransactions,
  ignorePlaidTransactions,
  stagePlaidTransactions,
  syncPlaidItem,
  updatePlaidItemPreferences,
  type PlaidActivitySummary,
  type PlaidActivityView,
  type PlaidItem,
  type PlaidOverview,
  type PlaidTransaction,
} from '../api'
import {
  clearPlaidOAuthSession,
  completedPlaidOAuthUrl,
  isPlaidOAuthReturn,
  readPlaidOAuthSession,
  savePlaidOAuthSession,
} from '../lib/plaidOAuthSession'
import { plaidSyncOutcome } from '../lib/plaidSyncWatch'
import { useBrand } from '../contexts/brandContextValue'
import { BankActivityResumeDialog } from './BankActivityResumeDialog'
import './PlaidConnections.css'

function hasFreshBankObservation(item: PlaidItem) {
  if (item.context_paused_by_restart) return false
  if (!item.financial_resumed_at) return true
  return Boolean(item.last_synced_at && new Date(item.last_synced_at).getTime() >= new Date(item.financial_resumed_at).getTime())
}

function operationIsCurrent(assertCurrent: () => void) {
  try { assertCurrent(); return true } catch { return false }
}

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
const PLAID_LINK_SCRIPT_URL = 'https://cdn.plaid.com/link/v2/stable/link-initialize.js'
const PLAID_SYNC_POLL_INTERVAL_MS = 2_500
const PLAID_SYNC_MAX_ATTEMPTS = 24

let plaidLinkScriptPromise: Promise<void> | null = null

function plaidLinkIsReady() {
  return Boolean((window as Window & { Plaid?: unknown }).Plaid)
}

function loadPlaidLinkScript() {
  if (plaidLinkIsReady()) return Promise.resolve()
  if (plaidLinkScriptPromise) return plaidLinkScriptPromise

  plaidLinkScriptPromise = new Promise<void>((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${PLAID_LINK_SCRIPT_URL}"]`)
    const script = existing ?? document.createElement('script')

    const cleanup = () => {
      script.removeEventListener('load', handleLoad)
      script.removeEventListener('error', handleError)
    }
    const handleLoad = () => {
      cleanup()
      if (plaidLinkIsReady()) {
        resolve()
      } else {
        plaidLinkScriptPromise = null
        reject(new Error('Plaid Link loaded without becoming available. Refresh and try again.'))
      }
    }
    const handleError = () => {
      cleanup()
      plaidLinkScriptPromise = null
      if (!existing) script.remove()
      reject(new Error('Plaid Link could not be loaded. Check your connection and try again.'))
    }

    script.addEventListener('load', handleLoad, { once: true })
    script.addEventListener('error', handleError, { once: true })

    if (!existing) {
      script.src = PLAID_LINK_SCRIPT_URL
      script.async = true
      document.body.appendChild(script)
    }
  })

  return plaidLinkScriptPromise
}

type Props = {
  userId: string
  householdId?: number | null
  onDraftsCreated: () => Promise<void> | void
  variant?: 'connections' | 'activity'
  refreshKey?: string
  reviewYear?: number
  onOpenBudget?: () => void
}

type PlaidSyncWatch = {
  itemId: number
  baselineLastSyncedAt: string | null
}

const activityViews: Array<{ id: PlaidActivityView; label: string; count: (summary: PlaidActivitySummary) => number }> = [
  { id: 'all', label: 'All activity', count: (summary) => summary.all_count },
  { id: 'needs_review', label: 'Needs review', count: (summary) => summary.needs_review_count },
  { id: 'confirmed', label: 'Confirmed', count: (summary) => summary.confirmed_count },
  { id: 'excluded', label: 'Excluded', count: (summary) => summary.excluded_count },
  { id: 'pending', label: 'Bank pending', count: (summary) => summary.pending_count },
  { id: 'inflow', label: 'Money in', count: (summary) => summary.inflow_count },
]

const trustLabels: Record<PlaidTransaction['trust_state'], string> = {
  bank_observed: 'Bank observed',
  needs_review: 'Needs review',
  confirmed: 'Confirmed actual',
  excluded: 'Excluded',
  bank_pending: 'Bank pending',
  money_in: 'Money in',
  source_changed: 'Source changed',
}

export function PlaidConnections({ userId, householdId, onDraftsCreated, variant = 'connections', refreshKey = '', reviewYear = new Date().getFullYear(), onOpenBudget }: Props) {
  const { brand, assistantName } = useBrand()
  const onDraftsCreatedRef = useRef(onDraftsCreated)
  const [oauthSession] = useState(() => readPlaidOAuthSession(userId, undefined, Date.now(), { financialGeneration: getApiFinancialGeneration(), householdId }))
  const mounted = useRef(false)
  const lifetime = useRef(0)
  const refreshSequence = useRef(0)
  useEffect(() => { mounted.current = true; lifetime.current += 1; return () => { mounted.current = false; lifetime.current += 1 } }, [userId, householdId])
  const captureCurrentOperation = useCallback(() => {
    const assertApi = captureApiOperation()
    const sequence = lifetime.current
    return () => {
      assertApi()
      if (!mounted.current || sequence !== lifetime.current) throw new Error('Your bank workspace changed. Reopen the connection before continuing.')
    }
  }, [])
  const [linkOperation, setLinkOperation] = useState<(() => void) | null>(() => oauthSession ? captureApiOperation() : null)
  const resumeInFlight = useRef(false)
  const [resumeItem, setResumeItem] = useState<PlaidItem | null>(null)
  const oauthReturn = isPlaidOAuthReturn(window.location.href)
  const missingOAuthSession = oauthReturn && !oauthSession
  const receivedRedirectUri = oauthReturn && oauthSession ? window.location.href : undefined
  const [overview, setOverview] = useState<PlaidOverview | null>(null)
  const [transactions, setTransactions] = useState<PlaidTransaction[]>([])
  const [transactionPage, setTransactionPage] = useState(1)
  const [hasMoreTransactions, setHasMoreTransactions] = useState(false)
  const [activityTotal, setActivityTotal] = useState(0)
  const [activitySummary, setActivitySummary] = useState<PlaidActivitySummary | null>(null)
  const [activityView, setActivityView] = useState<PlaidActivityView>('all')
  const [picture, setPicture] = useState<'current' | 'history'>('current')
  const [searchInput, setSearchInput] = useState('')
  const [activityQuery, setActivityQuery] = useState('')
  const [activityAccountId, setActivityAccountId] = useState<number | null>(null)
  const [selected, setSelected] = useState<number[]>([])
  const [consent, setConsent] = useState(false)
  const [linkToken, setLinkToken] = useState<string | null>(oauthSession?.linkToken ?? null)
  const [plaidScriptReady, setPlaidScriptReady] = useState(false)
  const [updateItemId, setUpdateItemId] = useState<number | null>(oauthSession?.updateItemId ?? null)
  const [launchLink, setLaunchLink] = useState(Boolean(receivedRedirectUri))
  const [busy, setBusy] = useState<string | null>(missingOAuthSession ? null : 'loading')
  const [error, setError] = useState<string | null>(missingOAuthSession ? 'This bank sign-in return could not be resumed. Start the connection again from My Profile.' : null)
  const [notice, setNotice] = useState<string | null>(null)
  const [syncWatch, setSyncWatch] = useState<PlaidSyncWatch | null>(null)
  const syncWatchItemId = syncWatch?.itemId ?? null
  const syncWatchBaselineLastSyncedAt = syncWatch?.baselineLastSyncedAt ?? null

  useEffect(() => {
    onDraftsCreatedRef.current = onDraftsCreated
  }, [onDraftsCreated])

  useEffect(() => {
    let cancelled = false
    if (!linkToken) return () => { cancelled = true }

    void loadPlaidLinkScript()
      .then(() => {
        if (!cancelled && linkOperation && operationIsCurrent(linkOperation)) setPlaidScriptReady(true)
      })
      .catch((reason) => {
        if (cancelled) return
        setError(reason instanceof Error ? reason.message : 'Plaid Link could not be loaded.')
        setBusy(null)
        setLaunchLink(false)
      })

    return () => { cancelled = true }
  }, [linkOperation, linkToken])

  const finishOAuthSession = useCallback(() => {
    clearPlaidOAuthSession(userId)
    if (isPlaidOAuthReturn(window.location.href)) {
      window.history.replaceState(null, '', completedPlaidOAuthUrl(window.location.href))
    }
  }, [userId])

  useEffect(() => {
    if (!missingOAuthSession) return

    window.history.replaceState(null, '', completedPlaidOAuthUrl(window.location.href))
  }, [missingOAuthSession])

  const refresh = useCallback(async () => {
    const assertCurrent = captureCurrentOperation()
    const sequence = ++refreshSequence.current
    const [nextOverview, nextTransactionsPage] = await Promise.all([
      fetchPlaidOverview(),
      fetchPlaidTransactions(1, activityView, { query: activityQuery, accountId: activityAccountId, reviewYear, picture }),
    ])
    assertCurrent()
    if (sequence !== refreshSequence.current) return
    const nextTransactions = nextTransactionsPage.transactions
    setOverview(nextOverview)
    setTransactions(nextTransactions)
    setTransactionPage(1)
    setHasMoreTransactions(nextTransactionsPage.pagination.has_more)
    setActivityTotal(nextTransactionsPage.pagination.total)
    setActivitySummary(nextTransactionsPage.summary)
    setSelected((current) => current.filter((id) => nextTransactions.some((transaction) => transaction.id === id && transaction.stageable)))
  }, [activityAccountId, activityQuery, activityView, captureCurrentOperation, picture, reviewYear])

  useEffect(() => {
    if (syncWatchItemId == null) return

    let cancelled = false
    const assertCurrent = captureCurrentOperation()
    let inFlight = false
    let attempts = 0
    let timeoutId: number | null = null

    const stop = () => {
      if (timeoutId != null) window.clearTimeout(timeoutId)
      timeoutId = null
    }
    const schedule = () => {
      stop()
      timeoutId = window.setTimeout(() => void poll(), PLAID_SYNC_POLL_INTERVAL_MS)
    }
    const poll = async () => {
      if (cancelled || inFlight) return
      if (document.visibilityState !== 'visible') return

      inFlight = true
      try {
        assertCurrent()
        const nextOverview = await fetchPlaidOverview()
        if (cancelled) return
        assertCurrent()

        setOverview(nextOverview)
        const item = nextOverview.items.find((candidate) => candidate.id === syncWatchItemId)
        const outcome = plaidSyncOutcome(item, syncWatchBaselineLastSyncedAt)

        if (outcome === 'complete') {
          await Promise.all([refresh(), onDraftsCreatedRef.current()])
          if (cancelled) return
          setSyncWatch(null)
          setNotice(`Sync complete. Posted expenses are ready for household review, and ${assistantName} can read the updated bank activity now.`)
          return
        }

        if (outcome === 'failed' || outcome === 'missing') {
          setSyncWatch(null)
          setError(item?.error_message || 'The bank connection could not finish syncing. Review the connection status and try again.')
          return
        }

        attempts += 1
        if (attempts >= PLAID_SYNC_MAX_ATTEMPTS) {
          await Promise.all([refresh(), onDraftsCreatedRef.current()])
          if (cancelled) return
          setSyncWatch(null)
          setNotice(`The bank accepted the sync request, but the final update is taking longer than expected. You can keep using ${brand.product_name} and retry Sync now if the feed does not update.`)
          return
        }

        schedule()
      } catch (reason) {
        if (cancelled) return
        attempts += 1
        if (attempts >= PLAID_SYNC_MAX_ATTEMPTS) {
          setSyncWatch(null)
          setError(reason instanceof Error ? reason.message : 'Could not verify that the bank sync finished.')
          return
        }
        schedule()
      } finally {
        inFlight = false
      }
    }
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') void poll()
    }

    document.addEventListener('visibilitychange', handleVisibilityChange)
    void poll()

    return () => {
      cancelled = true
      stop()
      document.removeEventListener('visibilitychange', handleVisibilityChange)
    }
  }, [assistantName, brand.product_name, captureCurrentOperation, refresh, syncWatchBaselineLastSyncedAt, syncWatchItemId])

  useEffect(() => {
    let cancelled = false
    const assertCurrent = captureCurrentOperation()
    const sequence = ++refreshSequence.current
    async function load() {
      try {
        const [nextOverview, nextTransactionsPage] = await Promise.all([
          fetchPlaidOverview(),
          fetchPlaidTransactions(1, activityView, { query: activityQuery, accountId: activityAccountId, reviewYear, picture }),
        ])
        if (cancelled || sequence !== refreshSequence.current) return
        assertCurrent()
        setOverview(nextOverview)
        setTransactions(nextTransactionsPage.transactions)
        setTransactionPage(1)
        setHasMoreTransactions(nextTransactionsPage.pagination.has_more)
        setActivityTotal(nextTransactionsPage.pagination.total)
        setActivitySummary(nextTransactionsPage.summary)
      } catch (reason) {
        if (!cancelled) setError(reason instanceof Error ? reason.message : 'Could not load bank connections.')
      } finally {
        if (!cancelled) setBusy(null)
      }
    }
    void load()
    return () => { cancelled = true }
  }, [activityAccountId, activityQuery, activityView, captureCurrentOperation, picture, refresh, refreshKey, reviewYear])

  const onSuccess = useCallback<PlaidLinkOnSuccess>(async (publicToken, metadata) => {
    if (!mounted.current || !linkOperation) return
    try { linkOperation() } catch { return }
    setBusy('link')
    setError(null)
    try {
      if (updateItemId) {
        linkOperation()
        const nextOverview = await syncPlaidItem(updateItemId)
        linkOperation()
        if (!mounted.current) return
        const item = nextOverview.items.find((candidate) => candidate.id === updateItemId)
        setOverview(nextOverview)
        setSyncWatch({ itemId: updateItemId, baselineLastSyncedAt: item?.last_synced_at ?? null })
        setNotice('Bank sign-in updated. Transaction sync is running.')
      } else {
        linkOperation()
        const result = await exchangePlaidPublicToken({
          public_token: publicToken,
          institution_id: metadata.institution?.institution_id,
          institution_name: metadata.institution?.name,
        })
        linkOperation()
        if (!mounted.current) return
        setOverview(result.plaid)
        setSyncWatch({ itemId: result.item.id, baselineLastSyncedAt: result.item.last_synced_at })
        setNotice('Bank connected. Preparing transaction history now; official actuals will not change until you approve them.')
      }
      await refresh()
    } catch (reason) {
      if (!mounted.current) return
      try { linkOperation() } catch { return }
      setError(reason instanceof Error ? reason.message : 'Could not finish the bank connection.')
    } finally {
      if (mounted.current && operationIsCurrent(linkOperation)) {
        finishOAuthSession()
        setBusy(null)
        setLinkToken(null)
        setUpdateItemId(null)
        setLaunchLink(false)
      }
    }
  }, [finishOAuthSession, linkOperation, refresh, updateItemId])

  const onExit = useCallback<PlaidLinkOnExit>((linkError, metadata) => {
    if (!mounted.current || !linkOperation) return
    try { linkOperation() } catch { return }
    if (linkError) {
      const message = linkError.display_message || 'The bank connection could not be completed.'
      const reference = metadata.request_id ? ` Plaid reference: ${metadata.request_id}.` : ''
      setError(`${message}${reference}`)
    }
    finishOAuthSession()
    setLinkToken(null)
    setUpdateItemId(null)
    setLaunchLink(false)
    setBusy(null)
  }, [finishOAuthSession, linkOperation])

  const connect = async () => {
    const assertCurrent = captureCurrentOperation()
    const financialGeneration = getApiFinancialGeneration()
    setBusy('connect')
    setError(null)
    try {
      const result = await createPlaidLinkToken(consent)
      assertCurrent()
      savePlaidOAuthSession({ userId, householdId, financialGeneration, linkToken: result.link_token, updateItemId: null })
      setLinkOperation(() => assertCurrent)
      setLinkToken(result.link_token)
      setLaunchLink(true)
      setBusy('link')
    } catch (reason) {
      try { assertCurrent() } catch { return }
      setError(reason instanceof Error ? reason.message : 'Could not start Plaid Link.')
      setBusy(null)
    }
  }

  const repair = async (item: PlaidItem) => {
    if (item.context_paused_by_restart) return
    const assertCurrent = captureCurrentOperation()
    const financialGeneration = getApiFinancialGeneration()
    setBusy(`repair-${item.id}`)
    setError(null)
    try {
      const result = await createPlaidUpdateLinkToken(item.id)
      assertCurrent()
      savePlaidOAuthSession({ userId, householdId, financialGeneration, linkToken: result.link_token, updateItemId: item.id })
      setLinkOperation(() => assertCurrent)
      setUpdateItemId(item.id)
      setLinkToken(result.link_token)
      setLaunchLink(true)
      setBusy('link')
    } catch (reason) {
      try { assertCurrent() } catch { return }
      setError(reason instanceof Error ? reason.message : 'Could not start the bank sign-in update.')
      setBusy(null)
    }
  }

  const runItemAction = async (item: PlaidItem, action: 'sync' | 'disconnect') => {
    if (action === 'sync' && item.context_paused_by_restart) return
    if (action === 'disconnect' && !window.confirm(`Disconnect ${item.institution_name}? Plaid access and unapproved imported bank data will be removed. Approved actuals will stay in your household record.`)) return
    const assertCurrent = captureCurrentOperation()
    setBusy(`${action}-${item.id}`)
    setError(null)
    try {
      if (action === 'sync') {
        const nextOverview = await syncPlaidItem(item.id)
        assertCurrent()
        setOverview(nextOverview)
        setSyncWatch({ itemId: item.id, baselineLastSyncedAt: item.last_synced_at })
        setNotice('Sync is running. Posted expenses will move into household review as the bank feed finishes updating.')
      } else {
        await disconnectPlaidItem(item.id)
        assertCurrent()
        setNotice('Bank disconnected and Plaid source data removed.')
        await refresh()
      }
    } catch (reason) {
      if (operationIsCurrent(assertCurrent)) setError(reason instanceof Error ? reason.message : `Could not ${action} this bank.`)
    } finally {
      if (operationIsCurrent(assertCurrent)) setBusy(null)
    }
  }

  const updateReviewPreference = async (item: PlaidItem, enabled: boolean) => {
    if (item.context_paused_by_restart) return
    const assertCurrent = captureCurrentOperation()
    setBusy(`preference-${item.id}`)
    setError(null)
    try {
      const next = await updatePlaidItemPreferences(item.id, { auto_confirm_trusted_merchants: enabled })
      assertCurrent(); setOverview(next)
      setNotice(enabled
        ? 'Trusted-merchant automation is on. Only familiar posted amounts with a proven category rule can confirm automatically.'
        : 'Trusted-merchant automation is off. Posted expenses will wait for your review.')
    } catch (reason) {
      if (operationIsCurrent(assertCurrent)) setError(reason instanceof Error ? reason.message : 'Could not update the transaction review preference.')
    } finally {
      if (operationIsCurrent(assertCurrent)) setBusy(null)
    }
  }

  const applySelection = async (action: 'stage' | 'ignore') => {
    if (picture === 'history') return
    const assertCurrent = captureCurrentOperation()
    setBusy(action)
    setError(null)
    try {
      if (action === 'stage') {
        const result = await stagePlaidTransactions(selected)
        assertCurrent()
        setNotice(`${result.drafted_count} bank transaction${result.drafted_count === 1 ? '' : 's'} moved to review. Actuals have not changed.`)
        await onDraftsCreatedRef.current()
        assertCurrent()
      } else {
        const result = await ignorePlaidTransactions(selected)
        assertCurrent()
        setNotice(`${result.ignored_count} bank transaction${result.ignored_count === 1 ? '' : 's'} ignored.`)
      }
      setSelected([])
      await refresh()
    } catch (reason) {
      if (operationIsCurrent(assertCurrent)) setError(reason instanceof Error ? reason.message : 'Could not update the selected transactions.')
    } finally {
      if (operationIsCurrent(assertCurrent)) setBusy(null)
    }
  }

  const loadOlderTransactions = async () => {
    const assertCurrent = captureCurrentOperation()
    const sequence = refreshSequence.current
    setBusy('older')
    setError(null)
    try {
      const next = await fetchPlaidTransactions(transactionPage + 1, activityView, { query: activityQuery, accountId: activityAccountId, reviewYear, picture })
      assertCurrent()
      if (sequence !== refreshSequence.current) return
      setTransactions((current) => [...current, ...next.transactions])
      setTransactionPage(next.pagination.page)
      setHasMoreTransactions(next.pagination.has_more)
      setActivityTotal(next.pagination.total)
      setActivitySummary(next.summary)
    } catch (reason) {
      if (operationIsCurrent(assertCurrent)) setError(reason instanceof Error ? reason.message : 'Could not load older bank activity.')
    } finally {
      if (operationIsCurrent(assertCurrent)) setBusy(null)
    }
  }

  const resumeBankActivity = async (item: PlaidItem) => {
    if (resumeInFlight.current) return
    resumeInFlight.current = true
    const assertCurrent = captureCurrentOperation()
    setBusy(`resume-${item.id}`); setError(null)
    try {
      const resumed = await resumePlaidItemFinancialPicture(item.id, item.financial_generation ?? 0)
      assertCurrent(); setOverview(resumed); setResumeItem(null)
      setNotice('New bank activity is enabled. Preparing a fresh sync; older activity remains in History. Automatic approvals remain off.')
      const baseline = resumed.items.find(candidate => candidate.id === item.id)?.last_synced_at ?? null
      const next = await syncPlaidItem(item.id)
      assertCurrent(); setOverview(next)
      setSyncWatch({ itemId: item.id, baselineLastSyncedAt: baseline })
      await refresh()
    } catch (reason) {
      try { assertCurrent() } catch { return }
      setError(reason instanceof Error ? reason.message : 'Could not enable new bank activity. Check the connection status before retrying.')
    } finally {
      resumeInFlight.current = false
      if (operationIsCurrent(assertCurrent)) setBusy(null)
    }
  }
  const resumeDialog = resumeItem ? <BankActivityResumeDialog institutionName={resumeItem.institution_name} busy={busy === `resume-${resumeItem.id}`} error={error} onClose={() => { if (!busy) setResumeItem(null) }} onConfirm={() => void resumeBankActivity(resumeItem)} /> : null

  const activeItems = overview?.items.filter((item) => item.status !== 'disconnected') ?? []
  const activeAccounts = activeItems.flatMap((item) => item.accounts.filter((account) => account.active))
  const stageable = useMemo(() => picture === 'history' ? [] : transactions.filter((transaction) => transaction.stageable && !transaction.context_paused_by_restart), [picture, transactions])
  const plaidLinkLauncher = linkToken && plaidScriptReady ? (
    <PlaidLinkLauncher
      token={linkToken}
      receivedRedirectUri={receivedRedirectUri}
      launch={launchLink}
      onSuccess={onSuccess}
      onExit={onExit}
      assertCurrent={linkOperation ?? undefined}
    />
  ) : null

  if (variant === 'connections') {
    return (
      <section className="panel plaid-workspace" aria-labelledby="bank-connections-heading">
        {plaidLinkLauncher}
        {resumeDialog}
        <div className="plaid-heading">
          <div>
            <span className="eyebrow">{overview && !overview.configured ? 'Manual-first pilot' : 'Bank connections'}</span>
            <h2 id="bank-connections-heading">{overview && !overview.configured ? 'Your workspace works without a bank connection.' : 'Connect the source. Keep control of the truth.'}</h2>
            <p>{overview && !overview.configured ? `Keep planning, coaching with ${assistantName}, uploading documents, and reviewing manual entries as usual.` : `${assistantName} can read authorized bank activity immediately. Only confirmed transactions become categorized budget actuals.`}</p>
          </div>
          {overview?.environment && <span className="plaid-environment">{overview.environment}</span>}
        </div>

        {error && <p className="form-error" role="alert">{error}</p>}
        {notice && <p className="form-notice" role="status">{notice}</p>}

        {!overview ? (
          <div className="plaid-empty"><strong>{busy === 'loading' ? 'Checking bank connection availability…' : 'Bank connection status is temporarily unavailable.'}</strong><p>Your profile, budget, {assistantName} coaching, document uploads, and manual reviews remain available.</p></div>
        ) : !overview.configured ? (
          <div className="plaid-empty"><strong>Bank connection is not part of this pilot yet.</strong><p>Nothing is missing from your setup. Your profile, budget, {assistantName} coaching, document uploads, and manual reviews all work without it.</p></div>
        ) : (
          <>
            <div className="plaid-consent">
              <label>
                <input type="checkbox" checked={consent} onChange={(event) => setConsent(event.target.checked)} />
                <span>I authorize {brand.organization_name} to retrieve read-only balances and transactions through Plaid and use limited transaction summaries to answer my {assistantName} questions. I can disconnect at any time.</span>
              </label>
              <a href={brand.footer.privacy_url ?? '/privacy.html'} target="_blank" rel="noreferrer">Privacy and bank-data notice</a>
              <button type="button" className="primary-button" disabled={!consent || Boolean(busy)} onClick={() => void connect()}>Connect a bank</button>
            </div>

            <div className="plaid-items">
              {activeItems.map((item) => (
                <article className="plaid-item" key={item.id}>
                  <div>
                    <strong>{item.institution_name}</strong>
                    <span className={`plaid-status is-${item.status}`}>{item.status.replace('_', ' ')}</span>
                    <p>{item.context_paused_by_restart ? 'Paused after starting over. Older balances and activity are kept in History and are not part of your new financial picture.' : syncWatch?.itemId === item.id ? `Preparing transaction history now. You can keep using ${brand.product_name} while this finishes.` : item.last_synced_at ? `Last synced ${new Date(item.last_synced_at).toLocaleString()}` : 'Initial history is still being prepared.'}</p>
                  </div>
                  <div className="plaid-item-actions">
                    {item.context_paused_by_restart && <button type="button" className="primary-button" disabled={Boolean(busy) || item.status === 'disconnecting'} onClick={() => { setError(null); setResumeItem(item) }}>Use new bank activity</button>}
                    {item.status === 'update_required' && !item.context_paused_by_restart && <button type="button" onClick={() => void repair(item)} disabled={Boolean(busy)}>Reconnect</button>}
                    <button type="button" onClick={() => void runItemAction(item, 'sync')} disabled={Boolean(busy) || item.context_paused_by_restart || syncWatch?.itemId === item.id || item.status === 'disconnecting'}>{syncWatch?.itemId === item.id ? 'Syncing…' : 'Sync now'}</button>
                    <button type="button" className="danger-button" onClick={() => void runItemAction(item, 'disconnect')} disabled={Boolean(busy)}>{item.status === 'disconnecting' ? 'Finish disconnect' : 'Disconnect'}</button>
                  </div>
                  <div className={`plaid-health-strip is-${item.health.state}`} role={item.health.requires_attention ? 'alert' : 'status'}>
                    <span className="plaid-health-mark" aria-hidden="true" />
                    <span><strong>{item.health.label}</strong><small>{item.health.message}</small></span>
                  </div>
                  <div className="plaid-accounts">
                    {item.accounts.filter((account) => account.active).map((account) => (
                      <div key={account.id}><span>{account.name} {account.mask ? `••${account.mask}` : ''}</span><strong>{!hasFreshBankObservation(item) ? (item.context_paused_by_restart ? 'Previous picture · balance hidden' : 'Awaiting fresh balance') : account.current_balance_cents == null ? 'Balance unavailable' : money.format(account.current_balance_cents / 100)}</strong></div>
                    ))}
                  </div>
                  <label className="plaid-automation-toggle">
                    <span><strong>Auto-confirm familiar merchants</strong><small>After three matching approvals, familiar posted amounts can use that exact merchant-category rule. Unusual amounts and duplicate candidates still wait.</small></span>
                    <input type="checkbox" role="switch" checked={!item.context_paused_by_restart && item.auto_confirm_trusted_merchants} disabled={Boolean(busy) || item.context_paused_by_restart} onChange={(event) => void updateReviewPreference(item, event.currentTarget.checked)} />
                  </label>
                </article>
              ))}
              {activeItems.length === 0 && <div className="plaid-empty"><strong>No bank is connected yet.</strong><p>Accept the notice above, then connect the first household account.</p></div>}
            </div>
          </>
        )}
      </section>
    )
  }

  return (
    <section className="panel plaid-workspace plaid-activity" aria-labelledby="bank-activity-heading">
      {plaidLinkLauncher}
      {resumeDialog}
      <div className="plaid-heading">
        <div>
          <span className="eyebrow">{overview && !overview.configured ? 'Manual activity' : 'Transaction activity'}</span>
          <h2 id="bank-activity-heading">{overview && !overview.configured ? 'Keep your record current without a bank feed.' : 'One feed. Every state made explicit.'}</h2>
          <p>{overview && !overview.configured ? `Report expenses to ${assistantName} or add them during budget review. Nothing changes your official actuals until you confirm it.` : `Bank-observed activity is available to ${assistantName}. Confirmation controls category truth and official budget actuals.`}</p>
        </div>
        {overview?.environment && <span className="plaid-environment">{overview.environment}</span>}
      </div>

      {error && <p className="form-error" role="alert">{error}</p>}
      {notice && <p className="form-notice" role="status">{notice}</p>}

      {!overview ? (
        <div className="plaid-empty"><strong>{busy === 'loading' ? 'Checking activity availability…' : 'Activity status is temporarily unavailable.'}</strong><p>Use Budget and {assistantName} for manual expense review while this status recovers.</p></div>
      ) : activeItems.length === 0 ? (
        overview.configured ? (
          <div className="plaid-empty"><strong>No bank activity yet.</strong><p>Connect an account from My Profile. Once authorized, {assistantName} can describe the feed while budget actuals remain under your control.</p></div>
        ) : (
          <div className="plaid-empty"><strong>Manual activity is ready.</strong><p>Tell {assistantName} about an expense, then review it in Budget before it becomes an official actual. Bank connection is optional and is not needed for this pilot.</p></div>
        )
      ) : (
        <>
          <nav className="plaid-picture-tabs" aria-label="Bank financial picture">
            {(['current', 'history'] as const).map(value => <button type="button" key={value} className={picture === value ? 'is-active' : ''} aria-pressed={picture === value} disabled={Boolean(busy)} onClick={() => { setPicture(value); setSelected([]); setTransactions([]); setActivitySummary(null) }}>{value === 'current' ? 'Current picture' : 'History'}</button>)}
          </nav>
          {picture === 'history' && <p className="plaid-history-note" role="status">Activity from before you started over. View only: it cannot be added to your current budget or approved again here.</p>}
          {activitySummary && (
            <>
              <div className="plaid-activity-summary" aria-label="Bank activity summary">
                <article className="is-observed"><span>Bank-observed spending</span><strong>{money.format(activitySummary.posted_outflow_cents / 100)}</strong><small>{activitySummary.posted_outflow_count} posted outflows</small></article>
                <article className="is-confirmed"><span>{picture === 'history' ? 'Previously confirmed' : 'Confirmed actuals'}</span><strong>{money.format(activitySummary.confirmed_cents / 100)}</strong><small>{activitySummary.confirmed_actual_count} approved ledger transactions</small></article>
                <article className="is-review"><span>{picture === 'history' ? 'Previous review status' : 'Needs review'}</span><strong>{money.format(activitySummary.needs_review_cents / 100)}</strong><small>{activitySummary.needs_review_count} decisions waiting</small></article>
                <article><span>{picture === 'history' ? 'Previous bank pending' : 'Bank pending'}</span><strong>{money.format(activitySummary.pending_cents / 100)}</strong><small>{activitySummary.pending_count} not posted yet</small></article>
              </div>
              <div className="plaid-review-scope" role="status" hidden={picture === 'history'}>
                <span><strong>{activitySummary.review_year_needs_review_count ?? activitySummary.needs_review_count} in the {activitySummary.review_year ?? reviewYear} budget-year queue.</strong>{(activitySummary.other_years_needs_review_count ?? 0) > 0 ? ` ${activitySummary.other_years_needs_review_count} older decision${activitySummary.other_years_needs_review_count === 1 ? '' : 's'} remain available in their budget years.` : ' All waiting decisions are in this budget year.'}</span>
                {picture === 'current' && onOpenBudget && <button type="button" onClick={onOpenBudget}>Review by budget year</button>}
              </div>
            </>
          )}

          <div className="plaid-source-strip">
            <div>{activeItems.map((item) => <span key={item.id}><strong>{item.institution_name}</strong>{item.context_paused_by_restart ? ' · Paused after starting over' : syncWatch?.itemId === item.id ? ' · Syncing now' : item.last_synced_at ? ` · Synced ${new Date(item.last_synced_at).toLocaleString()}` : ' · Preparing history'} · {item.health.label}</span>)}</div>
            {activeItems.filter(item => item.context_paused_by_restart).map(item => <button type="button" className="primary-button" key={`resume-${item.id}`} disabled={Boolean(busy)} onClick={() => { setError(null); setResumeItem(item) }}>Use new activity from {item.institution_name}</button>)}
            {activeItems.map((item) => <button type="button" className="secondary-button" key={item.id} onClick={() => void runItemAction(item, 'sync')} disabled={Boolean(busy) || item.context_paused_by_restart || syncWatch?.itemId === item.id}>{syncWatch?.itemId === item.id ? 'Syncing…' : `Sync ${item.institution_name}`}</button>)}
          </div>

          <nav className="plaid-activity-tabs" aria-label="Transaction activity filters">
            {activityViews.map((view) => (
              <button type="button" className={activityView === view.id ? 'is-active' : ''} aria-current={activityView === view.id ? 'page' : undefined} key={view.id} onClick={() => { setActivityView(view.id); setSelected([]) }}>
                <span>{view.label}</span>{activitySummary && <strong>{view.count(activitySummary)}</strong>}
              </button>
            ))}
          </nav>

          <form className="plaid-activity-tools" onSubmit={(event) => { event.preventDefault(); setActivityQuery(searchInput.trim()); setSelected([]) }}>
            <label>
              <span>Search activity</span>
              <input type="search" value={searchInput} placeholder="Merchant or transaction name" onChange={(event) => setSearchInput(event.target.value)} />
            </label>
            <label>
              <span>Account</span>
              <select value={activityAccountId ?? ''} onChange={(event) => { setActivityAccountId(event.target.value ? Number(event.target.value) : null); setSelected([]) }}>
                <option value="">All accounts</option>
                {activeAccounts.map((account) => <option key={account.id} value={account.id}>{account.name}{account.mask ? ` ••${account.mask}` : ''}</option>)}
              </select>
            </label>
            <button type="submit" className="secondary-button">Search</button>
            {(activityQuery || activityAccountId) && <button type="button" onClick={() => { setSearchInput(''); setActivityQuery(''); setActivityAccountId(null); setSelected([]) }}>Clear</button>}
          </form>

          <div className="plaid-review">
            <div className="row-between">
              <div><span className="eyebrow">{activityViews.find((view) => view.id === activityView)?.label}</span><h3>{activityTotal} transaction{activityTotal === 1 ? '' : 's'}</h3></div>
              {stageable.length > 0 && <span>{stageable.length} still preparing for review</span>}
            </div>
            <div className="plaid-transaction-list">
              {transactions.map((transaction) => (
                <article className={`plaid-transaction is-${transaction.trust_state}`} key={transaction.id}>
                  {picture === 'current' && transaction.stageable && !transaction.context_paused_by_restart ? (
                    <input aria-label={`Select ${transaction.merchant_name || transaction.name}`} type="checkbox" checked={selected.includes(transaction.id)} onChange={(event) => setSelected((current) => event.target.checked ? [...current, transaction.id] : current.filter((id) => id !== transaction.id))} />
                  ) : <span className="plaid-state-mark" aria-hidden="true" />}
                  <span className="plaid-transaction-copy">
                    <strong>{transaction.merchant_name || transaction.name}</strong>
                    <small>{transaction.occurred_on} · {transaction.account_name}{transaction.account_mask ? ` ••${transaction.account_mask}` : ''}</small>
                    {transaction.category_names.length > 0 && <small>{transaction.category_names.join(' + ')}</small>}
                    {transaction.source_changed_after_draft && <small className="plaid-source-warning">Plaid changed this source after review. Reconcile it before relying on the actual.</small>}
                    {transaction.removed && <small className="plaid-source-warning">The institution removed this source transaction after it entered your household record.</small>}
                  </span>
                  <span className={`plaid-trust-state is-${transaction.trust_state}`}>{trustLabels[transaction.trust_state]}</span>
                  <strong className={transaction.direction === 'inflow' ? 'positive' : ''}>{transaction.direction === 'inflow' ? '+' : ''}{money.format(Math.abs(transaction.amount_cents) / 100)}</strong>
                </article>
              ))}
              {transactions.length === 0 && <div className="plaid-empty"><strong>Nothing in this view.</strong><p>Try another activity state or sync the connected account.</p></div>}
            </div>
            {hasMoreTransactions && <button type="button" className="plaid-load-more" onClick={() => void loadOlderTransactions()} disabled={Boolean(busy)}>Load older activity</button>}
            {picture === 'current' && selected.length > 0 && (
              <div className="plaid-review-actions">
                <button type="button" onClick={() => void applySelection('ignore')} disabled={Boolean(busy)}>Exclude selected</button>
                <button type="button" className="primary-button" onClick={() => void applySelection('stage')} disabled={Boolean(busy)}>Prepare {selected.length} for review</button>
              </div>
            )}
          </div>
        </>
      )}
    </section>
  )
}

function PlaidLinkLauncher({
  token,
  receivedRedirectUri,
  launch,
  onSuccess,
  onExit,
  assertCurrent,
}: {
  token: string
  receivedRedirectUri?: string
  launch: boolean
  onSuccess: PlaidLinkOnSuccess
  onExit: PlaidLinkOnExit
  assertCurrent?: () => void
}) {
  const { open, ready } = usePlaidLink({ token, onSuccess, onExit, receivedRedirectUri })

  useEffect(() => {
    if (launch && ready && assertCurrent && operationIsCurrent(assertCurrent)) open()
  }, [assertCurrent, launch, open, ready])

  return null
}
