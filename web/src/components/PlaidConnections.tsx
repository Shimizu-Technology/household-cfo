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
  type PlaidItem,
  type PlaidOverview,
  type PlaidTransaction,
} from '../api'
import './PlaidConnections.css'

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

type Props = {
  onDraftsCreated: () => Promise<void> | void
}

export function PlaidConnections({ onDraftsCreated }: Props) {
  const [overview, setOverview] = useState<PlaidOverview | null>(null)
  const [transactions, setTransactions] = useState<PlaidTransaction[]>([])
  const [transactionPage, setTransactionPage] = useState(1)
  const [hasMoreTransactions, setHasMoreTransactions] = useState(false)
  const [selected, setSelected] = useState<number[]>([])
  const [consent, setConsent] = useState(false)
  const [linkToken, setLinkToken] = useState<string | null>(null)
  const [updateItemId, setUpdateItemId] = useState<number | null>(null)
  const [launchLink, setLaunchLink] = useState(false)
  const [busy, setBusy] = useState<string | null>('loading')
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    const [nextOverview, nextTransactionsPage] = await Promise.all([fetchPlaidOverview(), fetchPlaidTransactions()])
    const nextTransactions = nextTransactionsPage.transactions
    setOverview(nextOverview)
    setTransactions(nextTransactions)
    setTransactionPage(1)
    setHasMoreTransactions(nextTransactionsPage.pagination.has_more)
    setSelected((current) => current.filter((id) => nextTransactions.some((transaction) => transaction.id === id && transaction.stageable)))
  }, [])

  useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const [nextOverview, nextTransactionsPage] = await Promise.all([fetchPlaidOverview(), fetchPlaidTransactions()])
        if (cancelled) return
        setOverview(nextOverview)
        setTransactions(nextTransactionsPage.transactions)
        setTransactionPage(1)
        setHasMoreTransactions(nextTransactionsPage.pagination.has_more)
      } catch (reason) {
        if (!cancelled) setError(reason instanceof Error ? reason.message : 'Could not load bank connections.')
      } finally {
        if (!cancelled) setBusy(null)
      }
    }
    void load()
    return () => { cancelled = true }
  }, [refresh])

  const onSuccess = useCallback<PlaidLinkOnSuccess>(async (publicToken, metadata) => {
    setBusy('link')
    setError(null)
    try {
      if (updateItemId) {
        await syncPlaidItem(updateItemId)
        setNotice('Bank sign-in updated and transactions synced.')
      } else {
        await exchangePlaidPublicToken({
          public_token: publicToken,
          institution_id: metadata.institution?.institution_id,
          institution_name: metadata.institution?.name,
        })
        setNotice('Bank connected. Synced expenses stay pending until you draft and approve them.')
      }
      await refresh()
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not finish the bank connection.')
    } finally {
      setBusy(null)
      setLinkToken(null)
      setUpdateItemId(null)
      setLaunchLink(false)
    }
  }, [refresh, updateItemId])

  const onExit = useCallback<PlaidLinkOnExit>(() => {
    setLinkToken(null)
    setUpdateItemId(null)
    setLaunchLink(false)
    setBusy(null)
  }, [])

  const { open, ready } = usePlaidLink({ token: linkToken, onSuccess, onExit })
  useEffect(() => {
    if (launchLink && ready) open()
  }, [launchLink, open, ready])

  const connect = async () => {
    setBusy('connect')
    setError(null)
    try {
      const result = await createPlaidLinkToken(consent)
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
      } else {
        await disconnectPlaidItem(item.id)
      }
      setNotice(action === 'sync' ? 'Sync started. New bank activity will appear here shortly.' : 'Bank disconnected and Plaid source data removed.')
      await refresh()
      if (action === 'sync') window.setTimeout(() => void refresh(), 2_500)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : `Could not ${action} this bank.`)
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
      const next = await fetchPlaidTransactions(transactionPage + 1)
      setTransactions((current) => [...current, ...next.transactions])
      setTransactionPage(next.pagination.page)
      setHasMoreTransactions(next.pagination.has_more)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Could not load older bank activity.')
    } finally {
      setBusy(null)
    }
  }

  const activeItems = overview?.items.filter((item) => item.status !== 'disconnected') ?? []
  const reviewable = useMemo(() => transactions.filter((transaction) => transaction.review_status === 'unreviewed'), [transactions])

  return (
    <section className="panel plaid-workspace" aria-labelledby="bank-connections-heading">
      <div className="plaid-heading">
        <div>
          <span className="eyebrow">Bank connections</span>
          <h2 id="bank-connections-heading">Bring in transactions without giving up the CFO call.</h2>
          <p>Plaid is read-only here. Pending activity, income, transfers, and expenses never become actuals automatically.</p>
        </div>
        {overview?.environment && <span className="plaid-environment">{overview.environment}</span>}
      </div>

      {error && <p className="form-error" role="alert">{error}</p>}
      {notice && <p className="form-notice" role="status">{notice}</p>}

      {!overview?.configured ? (
        <div className="plaid-empty">
          <strong>Plaid setup is not enabled on this server yet.</strong>
          <p>Add the server-side Plaid credentials and a separate data-encryption key. Secrets never belong in the browser.</p>
        </div>
      ) : (
        <>
          <div className="plaid-consent">
            <label>
              <input type="checkbox" checked={consent} onChange={(event) => setConsent(event.target.checked)} />
              <span>I authorize Household CFO Method to retrieve read-only account balances and transactions through Plaid for budgeting and review. I can disconnect at any time.</span>
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
              </article>
            ))}
          </div>

          {activeItems.length > 0 && (
            <div className="plaid-review">
              <div className="row-between">
                <div><span className="eyebrow">Review before drafting</span><h3>Synced bank activity</h3></div>
                <span>{reviewable.length} unreviewed</span>
              </div>
              <p className="plaid-review-note">Only posted expenses can be drafted. Pending charges wait for posting; money in remains informational.</p>
              <div className="plaid-transaction-list">
                {reviewable.map((transaction) => (
                  <label className={`plaid-transaction${transaction.pending ? ' is-pending' : ''}`} key={transaction.id}>
                    <input type="checkbox" disabled={transaction.pending} checked={selected.includes(transaction.id)} onChange={(event) => setSelected((current) => event.target.checked ? [...current, transaction.id] : current.filter((id) => id !== transaction.id))} />
                    <span className="plaid-transaction-copy"><strong>{transaction.merchant_name || transaction.name}</strong><small>{transaction.occurred_on} · {transaction.account_name}{transaction.pending ? ' · Pending' : transaction.direction === 'inflow' ? ' · Money in' : ''}</small></span>
                    <strong className={transaction.direction === 'inflow' ? 'positive' : ''}>{transaction.direction === 'inflow' ? '+' : ''}{money.format(Math.abs(transaction.amount_cents) / 100)}</strong>
                  </label>
                ))}
                {reviewable.length === 0 && <p className="plaid-empty">No unreviewed posted expenses right now.</p>}
              </div>
              {hasMoreTransactions && <button type="button" className="plaid-load-more" onClick={() => void loadOlderTransactions()} disabled={Boolean(busy)}>Load older activity</button>}
              <div className="plaid-review-actions">
                <button type="button" onClick={() => void applySelection('ignore')} disabled={selected.length === 0 || Boolean(busy)}>Ignore selected</button>
                <button type="button" className="primary-button" onClick={() => void applySelection('stage')} disabled={selected.length === 0 || selected.some((id) => !transactions.find((transaction) => transaction.id === id)?.stageable) || Boolean(busy)}>Draft {selected.length || ''} for review</button>
              </div>
            </div>
          )}
        </>
      )}
    </section>
  )
}
