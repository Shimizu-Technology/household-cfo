import { useEffect, useMemo, useRef, useState, type FormEvent, type Ref } from 'react'
import {
  archiveAccount, createAccount, fetchPlaidOverview, linkPlaidAccount, reconcilePlaidAccount,
  restoreAccount, unlinkPlaidAccount, updateAccount,
  type AccountInput, type AccountRecord, type AccountType, type AssetPortfolio, type PlaidAccount, type PlaidItem,
} from '../api'
import { OperationIdempotencyKeys } from '../lib/operationIdempotency'

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
const accountTypes: AccountType[] = ['checking', 'savings', 'emergency_fund', 'retirement', 'investment', 'property', 'other']
const signedTypes: AccountType[] = ['checking', 'savings']
const titleize = (value: string) => value.replaceAll('_', ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())

type Draft = { label: string; account_type: AccountType; balance: string; balance_as_of_on: string; plaid_account_id: string }
const emptyDraft: Draft = { label: '', account_type: 'checking', balance: '', balance_as_of_on: '', plaid_account_id: '' }

export function AccountManager({ sectionRef, accounts, portfolio, onChanged }: {
  sectionRef?: Ref<HTMLElement>
  accounts: AccountRecord[]
  portfolio: AssetPortfolio
  onChanged: () => Promise<void>
}) {
  const [editing, setEditing] = useState<number | 'new' | null>(null)
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const [plaidItems, setPlaidItems] = useState<PlaidItem[]>([])
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [archiveId, setArchiveId] = useState<number | null>(null)
  const keys = useRef(new OperationIdempotencyKeys())
  const active = accounts.filter((account) => account.active)
  const archived = accounts.filter((account) => !account.active)
  const observations = useMemo(() => plaidItems.flatMap((item) => item.accounts.map((account) => ({ item, account }))), [plaidItems])
  const unlinked = observations.filter(({ account }) => account.active && account.eligible_for_asset_tracking && account.canonical_account_id === null)

  useEffect(() => {
    let canceled = false
    void fetchPlaidOverview().then((payload) => {
      if (!canceled) setPlaidItems(payload.items)
    }).catch(() => { /* Account entry remains available without Plaid. */ })
    return () => { canceled = true }
  }, [accounts])

  function beginCreate(observation?: PlaidAccount) {
    setDraft(observation ? {
      label: observation.name,
      account_type: observation.suggested_account_type ?? 'other',
      balance: observation.current_balance_cents === null ? '' : String(observation.current_balance_cents / 100),
      balance_as_of_on: new Date().toISOString().slice(0, 10),
      plaid_account_id: String(observation.id),
    } : emptyDraft)
    setEditing('new'); setArchiveId(null); setError(null)
  }
  function beginEdit(account: AccountRecord) {
    setDraft({ label: account.label, account_type: account.account_type, balance: account.balance === null ? '' : String(account.balance), balance_as_of_on: account.balance_as_of_on ?? '', plaid_account_id: '' })
    setEditing(account.id); setArchiveId(null); setError(null)
  }
  function cancel() { setEditing(null); setArchiveId(null); setError(null) }

  async function save(event: FormEvent) {
    event.preventDefault()
    const label = draft.label.trim()
    const balance = draft.balance.trim() === '' ? null : Number(draft.balance)
    if (!label) return setError('Give this account a short name you will recognize.')
    if (balance !== null && (!Number.isFinite(balance) || (balance < 0 && !signedTypes.includes(draft.account_type)))) return setError('Only checking and savings accounts can have a negative balance. Leave the balance blank when it is unknown.')
    const values: AccountInput = { label, account_type: draft.account_type, balance, balance_as_of_on: balance === null ? null : (draft.balance_as_of_on || null) }
    if (editing === 'new' && draft.plaid_account_id) values.plaid_account_id = Number(draft.plaid_account_id)
    const signature = `${editing === 'new' ? 'create' : `update:${editing}`}:${JSON.stringify(values)}`
    setSaving(true); setError(null)
    try {
      if (editing === 'new') await createAccount(values, keys.current.keyFor(signature))
      else if (typeof editing === 'number') await updateAccount(editing, values, keys.current.keyFor(signature))
      await onChanged(); keys.current.complete(signature); setEditing(null)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'This account could not be saved.') }
    finally { setSaving(false) }
  }

  async function mutate(signature: string, action: (key: string) => Promise<AccountRecord>) {
    setSaving(true); setError(null)
    try { await action(keys.current.keyFor(signature)); await onChanged(); keys.current.complete(signature); cancel() }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'That account change could not be saved.') }
    finally { setSaving(false) }
  }

  const amount = (value: number | null) => value === null ? 'Unknown' : money.format(value)
  const summary = (value: number, known: boolean) => known ? money.format(value) : `${money.format(value)} known so far`

  return <article ref={sectionRef} className="panel account-manager">
    <div className="row-between account-manager-heading"><div><p className="eyebrow">Accounts & assets</p><h3>Keep one approved balance for each household asset.</h3><p>Blank means unknown. An entered $0 is a confirmed zero. Bank balances stay observations until you accept them.</p></div>{editing === null && <button type="button" onClick={() => beginCreate()}>Add an account</button>}</div>
    <div className="account-summary" aria-label="Asset totals"><span><small>Liquid</small><strong>{summary(portfolio.liquid_balance, portfolio.liquid_balance_known)}</strong></span><span><small>Other assets</small><strong>{summary(portfolio.nonliquid_balance, portfolio.nonliquid_balance_known)}</strong></span><span><small>Total assets</small><strong>{summary(portfolio.total_balance, portfolio.total_balance_known)}</strong></span></div>

    {active.length === 0 && editing === null && <div className="debt-empty"><strong>No active accounts yet.</strong><p>Add checking, savings, emergency funds, investments, property, or another asset. Mia waits for known liquid balances before giving cash guidance.</p></div>}
    {active.length > 0 && <div className="account-list">{active.map((account) => <div className="account-row" key={account.id}>
      <div><strong>{account.label}</strong><span>{titleize(account.account_type)} · {account.balance_as_of_on ? `As of ${new Date(`${account.balance_as_of_on}T00:00:00`).toLocaleDateString()}` : account.balance === null ? 'Balance not entered' : 'Date not entered'}</span></div>
      <div><strong>{amount(account.balance)}</strong>{account.plaid_link ? <span>{account.plaid_link.institution_name}{account.plaid_link.mask ? ` ••${account.plaid_link.mask}` : ''}</span> : <span>Not matched to a bank</span>}</div>
      <div className="account-row-actions"><button type="button" className="secondary-button" disabled={saving} onClick={() => beginEdit(account)}>Edit</button><button type="button" className={archiveId === account.id ? 'danger-button' : 'quiet-button'} disabled={saving} onClick={() => archiveId === account.id ? void mutate(`archive:${account.id}`, (key) => archiveAccount(account.id, key)) : setArchiveId(account.id)}>{archiveId === account.id ? 'Confirm archive' : 'Archive'}</button></div>
      {account.plaid_link && <div className="account-bank-review"><span>Bank observed: <strong>{amount(account.plaid_link.current_balance)}</strong>{account.plaid_link.observed_at ? ` · ${new Date(account.plaid_link.observed_at).toLocaleString()}` : ''}{account.plaid_link.observation_newer_than_saved ? ' · Review available' : ' · Reviewed'}</span><div>{account.plaid_link.observation_newer_than_saved && <><button type="button" className="secondary-button" disabled={saving || account.plaid_link.current_balance === null} onClick={() => void mutate(`reconcile:${account.id}:accept`, (key) => reconcilePlaidAccount(account.id, 'accept_observed', key))}>Accept bank balance</button><button type="button" className="quiet-button" disabled={saving} onClick={() => void mutate(`reconcile:${account.id}:keep`, (key) => reconcilePlaidAccount(account.id, 'keep_saved', key))}>Keep saved</button></>}<button type="button" className="quiet-button" disabled={saving} onClick={() => void mutate(`unlink:${account.id}`, (key) => unlinkPlaidAccount(account.id, key))}>Unmatch</button></div></div>}
      {!account.plaid_link && unlinked.length > 0 && <label className="account-match"><span>Match a bank observation</span><select defaultValue="" disabled={saving} onChange={(event) => { const id = Number(event.target.value); if (id) void mutate(`link:${account.id}:${id}`, (key) => linkPlaidAccount(account.id, id, key)) }}><option value="">Choose an account</option>{unlinked.filter(({ account: item }) => item.allowed_account_types.includes(account.account_type)).map(({ item, account: observed }) => <option key={observed.id} value={observed.id}>{item.institution_name} · {observed.name}{observed.mask ? ` ••${observed.mask}` : ''}</option>)}</select></label>}
    </div>)}</div>}

    {editing !== null && <form className="account-form" onSubmit={save}><div className="account-form-grid">
      <label className="setup-field text-wide"><span>Account name</span><input autoFocus required value={draft.label} onChange={(event) => setDraft((current) => ({ ...current, label: event.target.value }))} placeholder="Everyday checking" /></label>
      <label className="setup-field"><span>Type</span><select value={draft.account_type} onChange={(event) => setDraft((current) => ({ ...current, account_type: event.target.value as AccountType }))}>{accountTypes.map((type) => <option key={type} value={type}>{titleize(type)}</option>)}</select></label>
      <label className="setup-field"><span>Approved balance</span><span className="money-input-shell"><span aria-hidden="true">$</span><input type="number" inputMode="decimal" step="0.01" value={draft.balance} onChange={(event) => setDraft((current) => ({ ...current, balance: event.target.value }))} placeholder="Unknown" /></span><small>Leave blank when unknown. Use 0 only when confirmed.</small></label>
      <label className="setup-field"><span>Balance date</span><input type="date" value={draft.balance_as_of_on} disabled={!draft.balance.trim()} onChange={(event) => setDraft((current) => ({ ...current, balance_as_of_on: event.target.value }))} /></label>
    </div>{draft.plaid_account_id && <p className="account-observation-note">This will match the saved account to the selected bank observation. You can unmatch it later without deleting the account.</p>}{error && <p className="setup-error" role="alert">{error}</p>}<div className="debt-form-actions"><button type="button" className="secondary-button" disabled={saving} onClick={cancel}>Cancel</button><button type="submit" disabled={saving}>{saving ? 'Saving' : editing === 'new' ? 'Add account' : 'Save account'}</button></div></form>}

    {unlinked.length > 0 && editing === null && <details className="account-observations"><summary>Unmatched bank observations ({unlinked.length})</summary><p>These values came from connected institutions. Add one for review before it affects household planning.</p>{unlinked.map(({ item, account }) => <div className="account-observation" key={account.id}><div><strong>{item.institution_name} · {account.name}{account.mask ? ` ••${account.mask}` : ''}</strong><span>{account.current_balance_cents === null ? 'Balance unavailable' : money.format(account.current_balance_cents / 100)}</span></div><button type="button" className="secondary-button" onClick={() => beginCreate(account)}>Review and add</button></div>)}</details>}
    {archived.length > 0 && <details className="debt-archive"><summary>Archived accounts ({archived.length})</summary><p>Archived accounts keep their history and bank match, but do not affect totals.</p>{archived.map((account) => <div className="account-row" key={account.id}><div><strong>{account.label}</strong><span>{titleize(account.account_type)}</span></div><strong>{amount(account.balance)}</strong><button type="button" className="secondary-button" disabled={saving} onClick={() => void mutate(`restore:${account.id}`, (key) => restoreAccount(account.id, key))}>Restore</button></div>)}</details>}
    {error && editing === null && <p className="setup-error" role="alert">{error}</p>}
  </article>
}
