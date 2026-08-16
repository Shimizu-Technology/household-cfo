import { useCallback, useEffect, useMemo, useState } from 'react'
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
import './PlaidConnections.css'

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

type Props = {
  userId: string
  onDraftsCreated: () => Promise<void> | void
  variant?: 'connections' | 'activity'
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

export function PlaidConnections({ userId, onDraftsCreated, variant = 'connections' }: Props) {
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
  const [updateItemId, setUpdateItemId] = useState<number | null>(oauthSession?.updateItemId ?? null)
  const [launchLink, setLaunchLink] = useState(Boolean(receivedRedirectUri))
  const [busy, setBusy] = useState<string | null>(missingOAuthSession ? null : 'loading')
  const [error, setError] = useState<string | null>(missingOAuthSession ? 'This bank sign-in return could not be resumed. Start the connection again from My Profile.' : null)
  const [notice, setNotice] = useState<string | null>(null)

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
      fetchPlaidTransactions(1, activityView, { query: activityQuery, accountId: activityAccountId }),
    ])
    const nextTransactions = nextTransactionsPage.transactions
    setOverview(nextOverview)
    setTransactions(nextTransactions)
    setTransactionPage(1)
    setHasMoreTransactions(nextTransactionsPage.pagination.has_more)
    setActivityTotal(nextTransactionsPage.pagination.total)
    setActivitySummary(nextTransactionsPage.summary)
    setSelected((current) => current.filter((id) => nextTransactions.some((transaction) => transaction.id === id && transaction.stageable)))
  }, [activityAccountId, activityQuery, activityView])

  useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const [nextOverview, nextTransactionsPage] = await Promise.all([
          fetchPlaidOverview(),
          fetchPlaidTransactions(1, activityView, { query: activityQuery, accountId: activityAccountId }),
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
  }, [activityAccountId, activityQuery, activityView, refresh])

  const onSuccess = useCallback<PlaidLinkOnSuccess>(async (publicToken, metadata) => {
    setBusy('link')
    setError(null)
    try {
      if (updateItemId) {
        await syncPlaidItem(updateItemId)
        setNotice('Bank sign-in updated. Transaction sync is running.')
      } else {
        await exchangePlaidPublicToken({
          public_token: publicToken,
          institution_id: metadata.institution?.institution_id,
          institution_name: metadata.institution?.name,
        })
        setNotice('Bank connected. Posted expenses will enter household review automatically; official actuals will not change until approval.')
      }
      await refresh()
      if (updateItemId) window.setTimeout(() => void refresh(), 2_500)
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

  const { open, ready } = usePlaidLink({ token: linkToken, onSuccess, onExit, receivedRedirectUri })
  useEffect(() => {
    if (launchLink && ready) open()
  }, [launchLink, open, ready])

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
        await syncPlaidItem(item.id)
        setNotice('Sync is running. Posted expenses will move into household review as the bank feed finishes updating.')
        const previousSync = item.last_synced_at
        for (let attempt = 0; attempt < 6; attempt += 1) {
          await new Promise((resolve) => window.setTimeout(resolve, 2_500))
          const nextOverview = await fetchPlaidOverview()
          const syncedItem = nextOverview.items.find((candidate) => candidate.id === item.id)
          if (syncedItem?.last_synced_at && syncedItem.last_synced_at !== previousSync) {
            await Promise.all([refresh(), onDraftsCreated()])
            setNotice('Sync complete. Posted expenses are ready for household review, and Mia can read the updated bank activity now.')
            return
          }
        }
        await Promise.all([refresh(), onDraftsCreated()])
        setNotice('The bank accepted the sync request, but its final update is still processing. This view will refresh when you return.')
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
      const next = await fetchPlaidTransactions(transactionPage + 1, activityView, { query: activityQuery, accountId: activityAccountId })
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

  if (variant === 'connections') {
    return (
      <section className="panel plaid-workspace" aria-labelledby="bank-connections-heading">
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
                <span>I authorize Household CFO Method to retrieve read-only account balances and transactions through Plaid. I can disconnect at any time.</span>
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
                    <p>{item.last_synced_at ? `Last synced ${new Date(item.last_synced_at).toLocaleString()}` : 'Initial history is still being prepared.'}</p>
                  </div>
                  <div className="plaid-item-actions">
                    {item.status === 'update_required' && <button type="button" onClick={() => void repair(item)} disabled={Boolean(busy)}>Reconnect</button>}
                    <button type="button" onClick={() => void runItemAction(item, 'sync')} disabled={Boolean(busy) || item.status === 'disconnecting'}>Sync now</button>
                    <button type="button" className="danger-button" onClick={() => void runItemAction(item, 'disconnect')} disabled={Boolean(busy)}>{item.status === 'disconnecting' ? 'Finish disconnect' : 'Disconnect'}</button>
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
            <div className="plaid-activity-summary" aria-label="Bank activity summary">
              <article className="is-observed"><span>Bank-observed spending</span><strong>{money.format(activitySummary.posted_outflow_cents / 100)}</strong><small>{activitySummary.posted_outflow_count} posted outflows</small></article>
              <article className="is-confirmed"><span>Confirmed actuals</span><strong>{money.format(activitySummary.confirmed_cents / 100)}</strong><small>{activitySummary.confirmed_actual_count} approved ledger transactions</small></article>
              <article className="is-review"><span>Needs review</span><strong>{money.format(activitySummary.needs_review_cents / 100)}</strong><small>{activitySummary.needs_review_count} decisions waiting</small></article>
              <article><span>Bank pending</span><strong>{money.format(activitySummary.pending_cents / 100)}</strong><small>{activitySummary.pending_count} not posted yet</small></article>
            </div>
          )}

          <div className="plaid-source-strip">
            <div>{activeItems.map((item) => <span key={item.id}><strong>{item.institution_name}</strong>{item.last_synced_at ? ` · Synced ${new Date(item.last_synced_at).toLocaleString()}` : ' · Preparing history'}</span>)}</div>
            {activeItems.map((item) => <button type="button" className="secondary-button" key={item.id} onClick={() => void runItemAction(item, 'sync')} disabled={Boolean(busy)}>Sync now</button>)}
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
