import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { usePlaidLink, type PlaidLinkOnExit, type PlaidLinkOnSuccess } from 'react-plaid-link'
import {
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
import './PlaidConnections.css'

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

export function PlaidConnections({ userId, onDraftsCreated, variant = 'connections', refreshKey = '', reviewYear = new Date().getFullYear(), onOpenBudget }: Props) {
  const onDraftsCreatedRef = useRef(onDraftsCreated)
  const [oauthSession] = useState(() => readPlaidOAuthSession(userId))
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
        if (!cancelled) setPlaidScriptReady(true)
      })
      .catch((reason) => {
        if (cancelled) return
        setError(reason instanceof Error ? reason.message : 'Plaid Link could not be loaded.')
        setBusy(null)
        setLaunchLink(false)
      })

    return () => { cancelled = true }
  }, [linkToken])

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
    const [nextOverview, nextTransactionsPage] = await Promise.all([
      fetchPlaidOverview(),
      fetchPlaidTransactions(1, activityView, { query: activityQuery, accountId: activityAccountId, reviewYear }),
    ])
    const nextTransactions = nextTransactionsPage.transactions
    setOverview(nextOverview)
    setTransactions(nextTransactions)
    setTransactionPage(1)
    setHasMoreTransactions(nextTransactionsPage.pagination.has_more)
    setActivityTotal(nextTransactionsPage.pagination.total)
    setActivitySummary(nextTransactionsPage.summary)
    setSelected((current) => current.filter((id) => nextTransactions.some((transaction) => transaction.id === id && transaction.stageable)))
  }, [activityAccountId, activityQuery, activityView, reviewYear])

  useEffect(() => {
    if (syncWatchItemId == null) return

    let cancelled = false
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
        const nextOverview = await fetchPlaidOverview()
        if (cancelled) return

        setOverview(nextOverview)
        const item = nextOverview.items.find((candidate) => candidate.id === syncWatchItemId)
        const outcome = plaidSyncOutcome(item, syncWatchBaselineLastSyncedAt)

        if (outcome === 'complete') {
          await Promise.all([refresh(), onDraftsCreatedRef.current()])
          if (cancelled) return
          setSyncWatch(null)
          setNotice('Sync complete. Posted expenses are ready for household review, and Mia can read the updated bank activity now.')
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
          setNotice('The bank accepted the sync request, but the final update is taking longer than expected. You can keep using Household CFO and retry Sync now if the feed does not update.')
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
  }, [refresh, syncWatchBaselineLastSyncedAt, syncWatchItemId])

  useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const [nextOverview, nextTransactionsPage] = await Promise.all([
          fetchPlaidOverview(),
          fetchPlaidTransactions(1, activityView, { query: activityQuery, accountId: activityAccountId, reviewYear }),
        ])
        if (cancelled) return
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
  }, [activityAccountId, activityQuery, activityView, refresh, refreshKey, reviewYear])

  const onSuccess = useCallback<PlaidLinkOnSuccess>(async (publicToken, metadata) => {
    setBusy('link')
    setError(null)
    try {
      if (updateItemId) {
        const nextOverview = await syncPlaidItem(updateItemId)
        const item = nextOverview.items.find((candidate) => candidate.id === updateItemId)
        setOverview(nextOverview)
        setSyncWatch({ itemId: updateItemId, baselineLastSyncedAt: item?.last_synced_at ?? null })
        setNotice('Bank sign-in updated. Transaction sync is running.')
      } else {
        const result = await exchangePlaidPublicToken({
          public_token: publicToken,
          institution_id: metadata.institution?.institution_id,
          institution_name: metadata.institution?.name,
        })
        setOverview(result.plaid)
        setSyncWatch({ itemId: result.item.id, baselineLastSyncedAt: result.item.last_synced_at })
        setNotice('Bank connected. Preparing transaction history now; official actuals will not change until you approve them.')
      }
      await refresh()
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not finish the bank connection.')
    } finally {
      finishOAuthSession()
      setBusy(null)
      setLinkToken(null)
      setUpdateItemId(null)
      setLaunchLink(false)
    }
  }, [finishOAuthSession, refresh, updateItemId])

  const onExit = useCallback<PlaidLinkOnExit>((linkError, metadata) => {
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
  }, [finishOAuthSession])

  const connect = async () => {
    setBusy('connect')
    setError(null)
    try {
      const result = await createPlaidLinkToken(consent)
      savePlaidOAuthSession({ userId, linkToken: result.link_token, updateItemId: null })
      setLinkToken(result.link_token)
      setLaunchLink(true)
      setBusy('link')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not start Plaid Link.')
      setBusy(null)
    }
  }

  const repair = async (item: PlaidItem) => {
    setBusy(`repair-${item.id}`)
    setError(null)
    try {
      const result = await createPlaidUpdateLinkToken(item.id)
      savePlaidOAuthSession({ userId, linkToken: result.link_token, updateItemId: item.id })
      setUpdateItemId(item.id)
      setLinkToken(result.link_token)
      setLaunchLink(true)
      setBusy('link')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not start the bank sign-in update.')
      setBusy(null)
    }
  }

  const runItemAction = async (item: PlaidItem, action: 'sync' | 'disconnect') => {
    if (action === 'disconnect' && !window.confirm(`Disconnect ${item.institution_name}? Plaid access and unapproved imported bank data will be removed. Approved actuals will stay in your household record.`)) return
    setBusy(`${action}-${item.id}`)
    setError(null)
    try {
      if (action === 'sync') {
        const nextOverview = await syncPlaidItem(item.id)
        setOverview(nextOverview)
        setSyncWatch({ itemId: item.id, baselineLastSyncedAt: item.last_synced_at })
        setNotice('Sync is running. Posted expenses will move into household review as the bank feed finishes updating.')
      } else {
        await disconnectPlaidItem(item.id)
        setNotice('Bank disconnected and Plaid source data removed.')
        await refresh()
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : `Could not ${action} this bank.`)
    } finally {
      setBusy(null)
    }
  }

  const updateReviewPreference = async (item: PlaidItem, enabled: boolean) => {
    setBusy(`preference-${item.id}`)
    setError(null)
    try {
      setOverview(await updatePlaidItemPreferences(item.id, { auto_confirm_trusted_merchants: enabled }))
      setNotice(enabled
        ? 'Trusted-merchant automation is on. Only familiar posted amounts with a proven category rule can confirm automatically.'
        : 'Trusted-merchant automation is off. Posted expenses will wait for your review.')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not update the transaction review preference.')
    } finally {
      setBusy(null)
    }
  }

  const applySelection = async (action: 'stage' | 'ignore') => {
    setBusy(action)
    setError(null)
    try {
      if (action === 'stage') {
        const result = await stagePlaidTransactions(selected)
        setNotice(`${result.drafted_count} bank transaction${result.drafted_count === 1 ? '' : 's'} moved to review. Actuals have not changed.`)
        await onDraftsCreated()
      } else {
        const result = await ignorePlaidTransactions(selected)
        setNotice(`${result.ignored_count} bank transaction${result.ignored_count === 1 ? '' : 's'} ignored.`)
      }
      setSelected([])
      await refresh()
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not update the selected transactions.')
    } finally {
      setBusy(null)
    }
  }

  const loadOlderTransactions = async () => {
    setBusy('older')
    setError(null)
    try {
      const next = await fetchPlaidTransactions(transactionPage + 1, activityView, { query: activityQuery, accountId: activityAccountId, reviewYear })
      setTransactions((current) => [...current, ...next.transactions])
      setTransactionPage(next.pagination.page)
      setHasMoreTransactions(next.pagination.has_more)
      setActivityTotal(next.pagination.total)
      setActivitySummary(next.summary)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not load older bank activity.')
    } finally {
      setBusy(null)
    }
  }

  const activeItems = overview?.items.filter((item) => item.status !== 'disconnected') ?? []
  const activeAccounts = activeItems.flatMap((item) => item.accounts.filter((account) => account.active))
  const stageable = useMemo(() => transactions.filter((transaction) => transaction.stageable), [transactions])
  const plaidLinkLauncher = linkToken && plaidScriptReady ? (
    <PlaidLinkLauncher
      token={linkToken}
      receivedRedirectUri={receivedRedirectUri}
      launch={launchLink}
      onSuccess={onSuccess}
      onExit={onExit}
    />
  ) : null

  if (variant === 'connections') {
    return (
      <section className="panel plaid-workspace" aria-labelledby="bank-connections-heading">
        {plaidLinkLauncher}
        <div className="plaid-heading">
          <div>
            <span className="eyebrow">Bank connections</span>
            <h2 id="bank-connections-heading">Connect the source. Keep control of the truth.</h2>
            <p>Mia can read authorized bank activity immediately. Only confirmed transactions become categorized budget actuals.</p>
          </div>
          {overview?.environment && <span className="plaid-environment">{overview.environment}</span>}
        </div>

        {error && <p className="form-error" role="alert">{error}</p>}
        {notice && <p className="form-notice" role="status">{notice}</p>}

        {!overview?.configured ? (
          <div className="plaid-empty"><strong>Plaid setup is not enabled on this server yet.</strong><p>Add server-side Plaid credentials and a separate data-encryption key.</p></div>
        ) : (
          <>
            <div className="plaid-consent">
              <label>
                <input type="checkbox" checked={consent} onChange={(event) => setConsent(event.target.checked)} />
                <span>I authorize Household CFO Method to retrieve read-only balances and transactions through Plaid and use limited transaction summaries to answer my Mia questions. I can disconnect at any time.</span>
              </label>
              <a href="/privacy.html" target="_blank" rel="noreferrer">Privacy and bank-data notice</a>
              <button type="button" className="primary-button" disabled={!consent || Boolean(busy)} onClick={() => void connect()}>Connect a bank</button>
            </div>

            <div className="plaid-items">
              {activeItems.map((item) => (
                <article className="plaid-item" key={item.id}>
                  <div>
                    <strong>{item.institution_name}</strong>
                    <span className={`plaid-status is-${item.status}`}>{item.status.replace('_', ' ')}</span>
                    <p>{syncWatch?.itemId === item.id ? 'Preparing transaction history now. You can keep using Household CFO while this finishes.' : item.last_synced_at ? `Last synced ${new Date(item.last_synced_at).toLocaleString()}` : 'Initial history is still being prepared.'}</p>
                  </div>
                  <div className="plaid-item-actions">
                    {item.status === 'update_required' && <button type="button" onClick={() => void repair(item)} disabled={Boolean(busy)}>Reconnect</button>}
                    <button type="button" onClick={() => void runItemAction(item, 'sync')} disabled={Boolean(busy) || syncWatch?.itemId === item.id || item.status === 'disconnecting'}>{syncWatch?.itemId === item.id ? 'Syncing…' : 'Sync now'}</button>
                    <button type="button" className="danger-button" onClick={() => void runItemAction(item, 'disconnect')} disabled={Boolean(busy)}>{item.status === 'disconnecting' ? 'Finish disconnect' : 'Disconnect'}</button>
                  </div>
                  <div className={`plaid-health-strip is-${item.health.state}`} role={item.health.requires_attention ? 'alert' : 'status'}>
                    <span className="plaid-health-mark" aria-hidden="true" />
                    <span><strong>{item.health.label}</strong><small>{item.health.message}</small></span>
                  </div>
                  <div className="plaid-accounts">
                    {item.accounts.filter((account) => account.active).map((account) => (
                      <div key={account.id}><span>{account.name} {account.mask ? `••${account.mask}` : ''}</span><strong>{account.current_balance_cents == null ? 'Balance unavailable' : money.format(account.current_balance_cents / 100)}</strong></div>
                    ))}
                  </div>
                  <label className="plaid-automation-toggle">
                    <span><strong>Auto-confirm familiar merchants</strong><small>After three matching approvals, familiar posted amounts can use that exact merchant-category rule. Unusual amounts and duplicate candidates still wait.</small></span>
                    <input type="checkbox" role="switch" checked={item.auto_confirm_trusted_merchants} disabled={Boolean(busy)} onChange={(event) => void updateReviewPreference(item, event.currentTarget.checked)} />
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
      <div className="plaid-heading">
        <div>
          <span className="eyebrow">Transaction activity</span>
          <h2 id="bank-activity-heading">One feed. Every state made explicit.</h2>
          <p>Bank-observed activity is available to Mia. Confirmation controls category truth and official budget actuals.</p>
        </div>
        {overview?.environment && <span className="plaid-environment">{overview.environment}</span>}
      </div>

      {error && <p className="form-error" role="alert">{error}</p>}
      {notice && <p className="form-notice" role="status">{notice}</p>}

      {activeItems.length === 0 ? (
        <div className="plaid-empty"><strong>No bank activity yet.</strong><p>Connect an account from My Profile. Once authorized, Mia can describe the feed while budget actuals remain under your control.</p></div>
      ) : (
        <>
          {activitySummary && (
            <>
              <div className="plaid-activity-summary" aria-label="Bank activity summary">
                <article className="is-observed"><span>Bank-observed spending</span><strong>{money.format(activitySummary.posted_outflow_cents / 100)}</strong><small>{activitySummary.posted_outflow_count} posted outflows</small></article>
                <article className="is-confirmed"><span>Confirmed actuals</span><strong>{money.format(activitySummary.confirmed_cents / 100)}</strong><small>{activitySummary.confirmed_actual_count} approved ledger transactions</small></article>
                <article className="is-review"><span>Needs review · all history</span><strong>{money.format(activitySummary.needs_review_cents / 100)}</strong><small>{activitySummary.needs_review_count} decisions waiting</small></article>
                <article><span>Bank pending</span><strong>{money.format(activitySummary.pending_cents / 100)}</strong><small>{activitySummary.pending_count} not posted yet</small></article>
              </div>
              <div className="plaid-review-scope" role="status">
                <span><strong>{activitySummary.review_year_needs_review_count ?? activitySummary.needs_review_count} in the {activitySummary.review_year ?? reviewYear} budget-year queue.</strong>{(activitySummary.other_years_needs_review_count ?? 0) > 0 ? ` ${activitySummary.other_years_needs_review_count} older decision${activitySummary.other_years_needs_review_count === 1 ? '' : 's'} remain available in their budget years.` : ' All waiting decisions are in this budget year.'}</span>
                {onOpenBudget && <button type="button" onClick={onOpenBudget}>Review by budget year</button>}
              </div>
            </>
          )}

          <div className="plaid-source-strip">
            <div>{activeItems.map((item) => <span key={item.id}><strong>{item.institution_name}</strong>{syncWatch?.itemId === item.id ? ' · Syncing now' : item.last_synced_at ? ` · Synced ${new Date(item.last_synced_at).toLocaleString()}` : ' · Preparing history'} · {item.health.label}</span>)}</div>
            {activeItems.map((item) => <button type="button" className="secondary-button" key={item.id} onClick={() => void runItemAction(item, 'sync')} disabled={Boolean(busy) || syncWatch?.itemId === item.id}>{syncWatch?.itemId === item.id ? 'Syncing…' : `Sync ${item.institution_name}`}</button>)}
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
                  {transaction.stageable ? (
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
            {selected.length > 0 && (
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
}: {
  token: string
  receivedRedirectUri?: string
  launch: boolean
  onSuccess: PlaidLinkOnSuccess
  onExit: PlaidLinkOnExit
}) {
  const { open, ready } = usePlaidLink({ token, onSuccess, onExit, receivedRedirectUri })

  useEffect(() => {
    if (launch && ready) open()
  }, [launch, open, ready])

  return null
}
