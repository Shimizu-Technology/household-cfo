import { useEffect, useLayoutEffect, useMemo, useRef, useState, type FormEvent, type Ref } from 'react'
import {
  archiveAccount, createAccount, fetchPlaidOverview, linkPlaidAccount, reconcilePlaidAccount,
  restoreAccount, unlinkPlaidAccount, updateAccount,
  type AccountInput, type AccountRecord, type AccountType, type AssetPortfolio, type PlaidAccount, type PlaidItem,
} from '../api'
import { OperationIdempotencyKeys } from '../lib/operationIdempotency'
import { guamTodayIso } from '../lib/householdDate'
import { proposedChoice, proposedMoney, proposedText, type MiaManualPayload } from '../lib/miaManualPrefill'
import { accountSummaryText } from './accountSummary'
import { useBrand } from '../contexts/brandContextValue'

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
const accountTypes: AccountType[] = ['checking', 'savings', 'emergency_fund', 'retirement', 'investment', 'property', 'other']
const signedTypes: AccountType[] = ['checking', 'savings']
const liquidTypes: AccountType[] = ['checking', 'savings', 'emergency_fund']
const titleize = (value: string) => value.replaceAll('_', ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())

type AccountAction = 'create_account' | 'update_account' | 'archive_account' | 'restore_account' | 'link_plaid_account' | 'reconcile_plaid_account' | 'unlink_plaid_account'
type ReconcileDecision = 'accept_observed' | 'keep_saved'
export type AccountFocusRequest = { key: number; actionType: AccountAction; accountId: number | null; payload: MiaManualPayload; reconcileDecision?: ReconcileDecision }
type Draft = { label: string; account_type: AccountType; balance: string; balance_as_of_on: string; plaid_account_id: string }
const emptyDraft: Draft = { label: '', account_type: 'checking', balance: '', balance_as_of_on: '', plaid_account_id: '' }

function accountDraftWithProposal(base: Draft, payload: MiaManualPayload): Draft {
  return {
    ...base,
    label: proposedText(payload, 'label', base.label),
    account_type: proposedChoice(payload, 'account_type', base.account_type, accountTypes),
    balance: proposedMoney(payload, 'balance_cents', base.balance, 'balance_known'),
    balance_as_of_on: proposedText(payload, 'balance_as_of_on', base.balance_as_of_on),
  }
}

export function AccountManager({ sectionRef, accounts, portfolio, onChanged, focusRequest, onFocusRequestHandled, onUnsavedChangesChange }: {
  sectionRef?: Ref<HTMLElement>
  accounts: AccountRecord[]
  portfolio: AssetPortfolio
  onChanged: () => Promise<void>
  focusRequest?: AccountFocusRequest | null
  onFocusRequestHandled?: () => void
  onUnsavedChangesChange?: (dirty: boolean) => void
}) {
  const { assistantName } = useBrand()
  const [editing, setEditing] = useState<number | 'new' | null>(null)
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const [draftBaseline, setDraftBaseline] = useState<Draft>(emptyDraft)
  const [plaidItems, setPlaidItems] = useState<PlaidItem[]>([])
  const [plaidReload, setPlaidReload] = useState(0)
  const [plaidError, setPlaidError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [archiveId, setArchiveId] = useState<number | null>(null)
  const keys = useRef(new OperationIdempotencyKeys())
  const addButtonRef = useRef<HTMLButtonElement | null>(null)
  const labelInputRef = useRef<HTMLInputElement | null>(null)
  const balanceInputRef = useRef<HTMLInputElement | null>(null)
  const returnFocusRef = useRef<HTMLElement | null>(null)
  const [returnFocusRequest, setReturnFocusRequest] = useState<{ key: number; selector?: string; origin: HTMLElement | null } | null>(null)
  const handledReturnFocusKeyRef = useRef<number | null>(null)
  const handledFocusKeyRef = useRef<number | null>(null)
  const active = accounts.filter((account) => account.active)
  const archived = accounts.filter((account) => !account.active)
  const liquidCount = active.filter((account) => liquidTypes.includes(account.account_type)).length
  const nonliquidCount = active.length - liquidCount
  const observations = useMemo(() => plaidItems.flatMap((item) => item.accounts.map((account) => ({ item, account }))), [plaidItems])
  const unlinked = useMemo(() => observations.filter(({ account }) => account.active && account.eligible_for_asset_tracking && account.canonical_account_id === null), [observations])

  const formDirty = editing !== null && Object.entries(draftBaseline).some(([key, value]) => draft[key as keyof Draft] !== value)
  const hasUnsavedChanges = saving || archiveId !== null || formDirty
  useEffect(() => {
    onUnsavedChangesChange?.(hasUnsavedChanges)
    return () => onUnsavedChangesChange?.(false)
  }, [hasUnsavedChanges, onUnsavedChangesChange])

  useEffect(() => {
    let canceled = false
    void fetchPlaidOverview().then((payload) => {
      if (!canceled) {
        setPlaidItems(payload.items)
        setPlaidError(null)
      }
    }).catch(() => {
      if (!canceled) setPlaidError('Bank connections could not load. Account balances are still available; retry before matching a bank observation.')
    })
    return () => { canceled = true }
  }, [accounts, plaidReload])

  useEffect(() => {
    if (!focusRequest || handledFocusKeyRef.current === focusRequest.key) return
    const account = accounts.find((candidate) => candidate.id === focusRequest.accountId)
    window.requestAnimationFrame(() => {
      if (focusRequest.actionType === 'create_account') {
        setDraftBaseline(emptyDraft); setDraft(accountDraftWithProposal(emptyDraft, focusRequest.payload)); setEditing('new'); setArchiveId(null); setError(null)
        window.requestAnimationFrame(() => labelInputRef.current?.focus())
      } else if (focusRequest.actionType === 'update_account' && account?.active) {
        setDraftBaseline({ label: account.label, account_type: account.account_type, balance: account.balance === null ? '' : String(account.balance), balance_as_of_on: account.balance_as_of_on ?? '', plaid_account_id: '' }); setDraft(accountDraftWithProposal({ label: account.label, account_type: account.account_type, balance: account.balance === null ? '' : String(account.balance), balance_as_of_on: account.balance_as_of_on ?? '', plaid_account_id: '' }, focusRequest.payload))
        setEditing(account.id); setArchiveId(null); setError(null)
        window.requestAnimationFrame(() => labelInputRef.current?.focus())
      } else if (focusRequest.actionType === 'update_account' && account && !account.active) {
        const row = document.querySelector<HTMLElement>(`[data-account-id="${account.id}"]`)
        const target = row?.querySelector<HTMLElement>('[data-account-action="restore"]') ?? addButtonRef.current
        if (target) revealAndFocus(target)
      } else {
        const action = accountActionControl(focusRequest)
        const row = document.querySelector<HTMLElement>(`[data-account-id="${focusRequest.accountId}"]`)
        const target = action ? row?.querySelector<HTMLElement>(`[data-account-action="${action}"]`) : null
        if (!target) return
        revealAndFocus(target)
      }
      handledFocusKeyRef.current = focusRequest.key
      onFocusRequestHandled?.()
    })
  }, [accounts, focusRequest, onFocusRequestHandled, unlinked])

  function rememberFocus(element?: HTMLElement | null) {
    // Safari pointer activation may keep focus on the previous control. Claim
    // the action's origin before waiting, so only a later deliberate move wins.
    element?.focus({ preventScroll: true })
    returnFocusRef.current = element ?? document.activeElement as HTMLElement | null
  }
  function focusLater(selector?: string) {
    const origin = returnFocusRef.current
    setReturnFocusRequest((current) => ({ key: (current?.key ?? 0) + 1, selector, origin }))
  }
  useLayoutEffect(() => {
    if (!returnFocusRequest || handledReturnFocusKeyRef.current === returnFocusRequest.key || saving || editing !== null) return
    const activeElement = document.activeElement
    if (activeElement && activeElement !== document.body && activeElement !== returnFocusRequest.origin) {
      // A deliberate focus move while the refreshed list is pending takes priority.
      handledReturnFocusKeyRef.current = returnFocusRequest.key
      return
    }
    const target = returnFocusRequest.selector ? document.querySelector<HTMLElement>(returnFocusRequest.selector) : null
    // The refresh Promise may resolve before its parent commits the updated list.
    // Keep an exact destination pending until that control exists in committed DOM.
    if (returnFocusRequest.selector && !target) return
    const fallback = returnFocusRequest.origin?.isConnected ? returnFocusRequest.origin : addButtonRef.current
    const focusTarget = target ?? fallback
    if (!focusTarget) return
    handledReturnFocusKeyRef.current = returnFocusRequest.key
    revealAndFocus(focusTarget)
  }, [accounts, editing, returnFocusRequest, saving, unlinked])
  function beginCreate(observation?: PlaidAccount, trigger?: HTMLElement | null) {
    if (formDirty || saving) { setError('Save or cancel this account draft before opening another record.'); return }
    rememberFocus(trigger)
    setDraftBaseline(emptyDraft)
    setDraft(observation ? {
      label: observation.name,
      account_type: observation.suggested_account_type ?? 'other',
      balance: observation.current_balance_cents === null ? '' : String(observation.current_balance_cents / 100),
      balance_as_of_on: guamTodayIso(),
      plaid_account_id: String(observation.id),
    } : emptyDraft)
    setEditing('new'); setArchiveId(null); setError(null)
  }
  function beginEdit(account: AccountRecord, trigger?: HTMLElement | null) {
    if (formDirty || saving) { setError('Save or cancel this account draft before opening another record.'); return }
    rememberFocus(trigger)
    setDraftBaseline({ label: account.label, account_type: account.account_type, balance: account.balance === null ? '' : String(account.balance), balance_as_of_on: account.balance_as_of_on ?? '', plaid_account_id: '' }); setDraft({ label: account.label, account_type: account.account_type, balance: account.balance === null ? '' : String(account.balance), balance_as_of_on: account.balance_as_of_on ?? '', plaid_account_id: '' })
    setEditing(account.id); setArchiveId(null); setError(null)
  }
  function cancel() { setEditing(null); setArchiveId(null); setError(null); focusLater() }

  async function refreshAfterCommit(focusSelector?: string) {
    try {
      await onChanged()
      setError(null)
      focusLater(focusSelector)
    } catch {
      focusLater()
      setError('The account change was saved, but the latest account list could not reload. Reload this page before making another change.')
    }
  }

  async function save(event: FormEvent) {
    event.preventDefault()
    const label = draft.label.trim()
    const balance = draft.balance.trim() === '' ? null : Number(draft.balance)
    if (!label) { setError('Give this account a short name you will recognize.'); labelInputRef.current?.focus(); return }
    if (balance !== null && (!Number.isFinite(balance) || (balance < 0 && !signedTypes.includes(draft.account_type)))) {
      setError('Only checking and savings accounts can have a negative balance. Leave the balance blank when it is unknown.'); balanceInputRef.current?.focus(); return
    }
    const values: AccountInput = { label, account_type: draft.account_type, balance, balance_as_of_on: balance === null ? null : (draft.balance_as_of_on || null) }
    if (editing === 'new' && draft.plaid_account_id) values.plaid_account_id = Number(draft.plaid_account_id)
    const accountId = typeof editing === 'number' ? editing : null
    const signature = `${editing === 'new' ? 'create' : `update:${editing}`}:${JSON.stringify(values)}`
    setSaving(true); setError(null)
    try {
      const saved = editing === 'new'
        ? await createAccount(values, keys.current.keyFor(signature))
        : await updateAccount(accountId as number, values, keys.current.keyFor(signature))
      keys.current.complete(signature); setEditing(null)
      await refreshAfterCommit(`[data-account-id="${saved.id}"] [data-account-action="edit"]`)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'This account could not be saved.')
    } finally { setSaving(false) }
  }

  async function mutate(signature: string, action: (key: string) => Promise<AccountRecord>, focusSelector?: string) {
    if (formDirty || saving) { setError('Save or cancel this account draft before making another change.'); return }
    setSaving(true); setError(null)
    try {
      await action(keys.current.keyFor(signature))
      keys.current.complete(signature); setEditing(null); setArchiveId(null)
      await refreshAfterCommit(focusSelector)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'That account change could not be saved.')
    } finally { setSaving(false) }
  }

  const amount = (value: number | null) => value === null ? 'Not entered' : money.format(value)

  return <article ref={sectionRef} className="panel account-manager">
    <div className="row-between account-manager-heading"><div><p className="eyebrow">Accounts & assets</p><h3>Keep one approved balance for each household asset.</h3><p>Blank means unknown. An entered $0 is a confirmed zero. Bank balances stay observations until you accept them.</p></div>{editing === null && <button ref={addButtonRef} type="button" disabled={saving} onClick={(event) => beginCreate(undefined, event.currentTarget)}>Add an account</button>}</div>
    <div className="account-summary" aria-label="Asset totals"><span><small>Liquid</small><strong>{accountSummaryText(portfolio.liquid_balance, portfolio.liquid_balance_known, portfolio.liquid_known_count, liquidCount)}</strong></span><span><small>Other assets</small><strong>{accountSummaryText(portfolio.nonliquid_balance, portfolio.nonliquid_balance_known, portfolio.nonliquid_known_count, nonliquidCount)}</strong></span><span><small>Total assets</small><strong>{accountSummaryText(portfolio.total_balance, portfolio.total_balance_known, portfolio.total_known_count, active.length)}</strong></span></div>

    {active.length === 0 && editing === null && <div className="account-empty"><strong>No active accounts yet.</strong><p>Add checking, savings, emergency funds, investments, property, or another asset. {assistantName} waits for known liquid balances before giving cash guidance.</p></div>}
    {active.length > 0 && <div className="account-list">{active.map((account) => <div className="account-row" data-account-id={account.id} key={account.id}>
      <div><strong>{account.label}</strong><span>{titleize(account.account_type)} · {account.balance_as_of_on ? `As of ${new Date(`${account.balance_as_of_on}T00:00:00`).toLocaleDateString()}` : account.balance === null ? 'Balance not entered' : 'Date not entered'}</span></div>
      <div><strong>{amount(account.balance)}</strong>{account.plaid_link ? <span>{account.plaid_link.institution_name}{account.plaid_link.mask ? ` ••${account.plaid_link.mask}` : ''}</span> : <span>Not matched to a bank</span>}</div>
      <div className="account-row-actions"><button type="button" data-account-action="edit" className="secondary-button" disabled={saving} onClick={(event) => beginEdit(account, event.currentTarget)}>Edit</button><button type="button" data-account-action="archive" className={archiveId === account.id ? 'danger-button' : 'quiet-button'} disabled={saving} onClick={(event) => { rememberFocus(event.currentTarget); if (archiveId === account.id) void mutate(`archive:${account.id}`, (key) => archiveAccount(account.id, key), `[data-account-id="${account.id}"] [data-account-action="restore"]`); else setArchiveId(account.id) }}>{archiveId === account.id ? 'Confirm archive' : 'Archive'}</button>{archiveId === account.id && <button type="button" className="secondary-button" aria-label={`Cancel archiving ${account.label}`} disabled={saving} onClick={() => { setArchiveId(null); focusLater(`[data-account-id="${account.id}"] [data-account-action="archive"]`) }}>Cancel</button>}</div>
      {account.plaid_link && <div className={`account-bank-review${account.plaid_link.active ? '' : ' is-inactive'}`}><span>{account.plaid_link.active ? <>Bank observed: <strong>{amount(account.plaid_link.current_balance)}</strong>{account.plaid_link.observed_at ? ` · ${new Date(account.plaid_link.observed_at).toLocaleString()}` : ''}{account.plaid_link.observation_newer_than_saved ? ' · Review available' : ' · Reviewed'}</> : <>Bank observation unavailable. Reconnect or sync this institution under Bank connections before reconciling.</>}</span><div>{account.plaid_link.active && account.plaid_link.observation_newer_than_saved && <><button type="button" data-account-action="reconcile-accept" className="secondary-button" disabled={saving || account.plaid_link.current_balance === null} onClick={(event) => { rememberFocus(event.currentTarget); void mutate(`reconcile:${account.id}:accept`, (key) => reconcilePlaidAccount(account.id, 'accept_observed', key), `[data-account-id="${account.id}"] [data-account-action="edit"]`) }}>Accept bank balance</button><button type="button" data-account-action="reconcile-keep" className="quiet-button" disabled={saving} onClick={(event) => { rememberFocus(event.currentTarget); void mutate(`reconcile:${account.id}:keep`, (key) => reconcilePlaidAccount(account.id, 'keep_saved', key), `[data-account-id="${account.id}"] [data-account-action="edit"]`) }}>Keep saved</button></>}{!account.plaid_link.active && <button type="button" data-account-action="reconcile-accept" className="secondary-button" disabled>Accept bank balance</button>}<button type="button" data-account-action="unlink" className="quiet-button" disabled={saving} onClick={(event) => { rememberFocus(event.currentTarget); void mutate(`unlink:${account.id}`, (key) => unlinkPlaidAccount(account.id, key), `[data-account-id="${account.id}"] [data-account-action="link"]`) }}>Unmatch</button></div></div>}
      {!account.plaid_link && unlinked.length > 0 && <label className="account-match"><span>Match a bank observation</span><select data-account-action="link" defaultValue="" disabled={saving} onChange={(event) => { const id = Number(event.target.value); if (id) { rememberFocus(event.currentTarget); void mutate(`link:${account.id}:${id}`, (key) => linkPlaidAccount(account.id, id, key), `[data-account-id="${account.id}"] [data-account-action="unlink"]`) } }}><option value="">Choose an account</option>{unlinked.filter(({ account: item }) => item.allowed_account_types.includes(account.account_type)).map(({ item, account: observed }) => <option key={observed.id} value={observed.id}>{item.institution_name} · {observed.name}{observed.mask ? ` ••${observed.mask}` : ''}</option>)}</select></label>}
    </div>)}</div>}

    {editing !== null && <form className="account-form" onSubmit={save}><fieldset className="account-form-grid" disabled={saving} style={{ border: 0, margin: 0, padding: 0, minWidth: 0 }}><legend className="sr-only">Account fields</legend>
      <label className="setup-field text-wide"><span>Account name</span><input ref={labelInputRef} autoFocus required value={draft.label} onChange={(event) => setDraft((current) => ({ ...current, label: event.target.value }))} placeholder="Everyday checking" /></label>
      <label className="setup-field"><span>Type</span><select value={draft.account_type} onChange={(event) => setDraft((current) => ({ ...current, account_type: event.target.value as AccountType }))}>{accountTypes.map((type) => <option key={type} value={type}>{titleize(type)}</option>)}</select></label>
      <label className="setup-field"><span>Approved balance</span><span className="money-input-shell"><span aria-hidden="true">$</span><input ref={balanceInputRef} type="number" inputMode="decimal" step="0.01" value={draft.balance} onChange={(event) => setDraft((current) => ({ ...current, balance: event.target.value }))} placeholder="Unknown" /></span><small>Leave blank when unknown. Use 0 only when confirmed.</small></label>
      <label className="setup-field"><span>Balance date</span><input type="date" value={draft.balance_as_of_on} disabled={!draft.balance.trim()} onChange={(event) => setDraft((current) => ({ ...current, balance_as_of_on: event.target.value }))} /></label>
    </fieldset>{draft.plaid_account_id && <p className="account-observation-note">This will match the saved account to the selected bank observation. You can unmatch it later without deleting the account.</p>}{error && <p className="setup-error" role="alert">{error}</p>}<div className="debt-form-actions"><button type="button" className="secondary-button" disabled={saving} onClick={cancel}>Cancel</button><button type="submit" disabled={saving}>{saving ? 'Saving' : editing === 'new' ? 'Add account' : 'Save account'}</button></div></form>}

    {plaidError && <div className="account-observation-error" role="status"><span>{plaidError}</span><button type="button" className="secondary-button" onClick={() => setPlaidReload((value) => value + 1)}>Retry bank connections</button></div>}
    {unlinked.length > 0 && editing === null && <details className="account-observations"><summary>Unmatched bank observations ({unlinked.length})</summary><p>These values came from connected institutions. Add one for review before it affects household planning.</p>{unlinked.map(({ item, account }) => <div className="account-observation" key={account.id}><div><strong>{item.institution_name} · {account.name}{account.mask ? ` ••${account.mask}` : ''}</strong><span>{account.current_balance_cents === null ? 'Balance unavailable' : money.format(account.current_balance_cents / 100)}</span></div><button type="button" className="secondary-button" onClick={(event) => beginCreate(account, event.currentTarget)}>Review and add</button></div>)}</details>}
    {archived.length > 0 && <details className="debt-archive"><summary>Archived accounts ({archived.length})</summary><p>Archived accounts keep their history and bank match, but do not affect totals.</p>{archived.map((account) => <div className="account-row" data-account-id={account.id} key={account.id}><div><strong>{account.label}</strong><span>{titleize(account.account_type)}</span></div><strong>{amount(account.balance)}</strong><button type="button" data-account-action="restore" className="secondary-button" disabled={saving} onClick={(event) => { rememberFocus(event.currentTarget); void mutate(`restore:${account.id}`, (key) => restoreAccount(account.id, key), `[data-account-id="${account.id}"] [data-account-action="edit"]`) }}>Restore</button></div>)}</details>}
    {error && editing === null && <p className="setup-error" role="alert">{error}</p>}
  </article>
}

function accountActionControl(request: AccountFocusRequest) {
  switch (request.actionType) {
    case 'archive_account': return 'archive'
    case 'restore_account': return 'restore'
    case 'link_plaid_account': return 'link'
    case 'reconcile_plaid_account': return request.reconcileDecision === 'accept_observed' ? 'reconcile-accept' : request.reconcileDecision === 'keep_saved' ? 'reconcile-keep' : null
    case 'unlink_plaid_account': return 'unlink'
    default: return null
  }
}

function revealAndFocus(target: HTMLElement) {
  const disclosure = target.closest('details')
  if (disclosure) disclosure.open = true
  target.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  target.focus({ preventScroll: true })
}
