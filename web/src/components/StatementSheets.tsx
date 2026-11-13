import { useState, type FormEvent } from 'react'
import { createPortal } from 'react-dom'
import { usePilotDialog } from '../lib/usePilotDialog'
import { Button } from './Button'
import type { SourceAccount } from '../lib/sourceReview'
import type { ReviewedSourceAccount } from '../lib/participantSourceReview'
import { LINE_KIND_OPTIONS, accountSentence, amountInputText, parseLineAmount, type AccountChange, type AccountLabel, type LineEdit, type LineKind, type SheetLine } from '../lib/statementReview'
import './StatementSheets.css'

export type { SheetLine }

type Category = { id: number; name: string }

export function StatementLineSheet({ line, categories, busy, canClose = !busy, error, onSave, onLeaveOut, onClose }: {
  line: SheetLine; categories: Category[]; busy: boolean; canClose?: boolean; error: string | null
  onSave: (edit: LineEdit) => void; onLeaveOut: () => void; onClose: () => void
}) {
  const { dialogRef: ref, requestClose } = usePilotDialog(() => { if (canClose) onClose() })
  const [kind, setKind] = useState<LineKind>(line.kind)
  const [merchant, setMerchant] = useState(line.merchant)
  const [postedOn, setPostedOn] = useState(line.postedOn)
  const [amount, setAmount] = useState(amountInputText(line.amountCents))
  const [categoryId, setCategoryId] = useState(line.categoryId ? String(line.categoryId) : '')
  const [problem, setProblem] = useState<string | null>(null)

  function save(event: FormEvent) {
    event.preventDefault()
    const cents = parseLineAmount(amount)
    if (cents == null) return setProblem('Enter the amount, like 12.50.')
    if (!postedOn) return setProblem('Choose the date.')
    if (kind === 'spending' && !merchant.trim()) return setProblem('Add where the money went.')
    setProblem(null)
    onSave({ kind, merchant: merchant.trim(), posted_on: postedOn, amount_cents: cents, category_id: kind === 'spending' && categoryId ? Number(categoryId) : null })
  }

  return createPortal(<div className="pilot-dialog-overlay statement-sheet-overlay" data-dialog-surface="true" role="presentation">
    <section ref={ref} data-dialog-panel="true" data-dialog-private="true" className="pilot-dialog statement-sheet" role="dialog" aria-modal="true" aria-labelledby="statement-line-title" tabIndex={-1}>
      <header><h2 id="statement-line-title">{line.merchant || 'This line'}</h2><Button variant="secondary" disabled={!canClose} onClick={requestClose}>Close</Button></header>
      <form className="statement-sheet-form" onSubmit={save}>
        <label>What was this?
          <select value={kind} onChange={(event) => setKind(event.target.value as LineKind)}>
            {LINE_KIND_OPTIONS.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>
        <label>Name
          <input value={merchant} maxLength={120} onChange={(event) => setMerchant(event.target.value)} />
        </label>
        <div className="statement-sheet-pair">
          <label>Date<input type="date" value={postedOn} onChange={(event) => setPostedOn(event.target.value)} /></label>
          <label>Amount<input inputMode="decimal" autoComplete="off" value={amount} onChange={(event) => setAmount(event.target.value)} placeholder="0.00" /></label>
        </div>
        {kind === 'spending' && <label>Category
          <select value={categoryId} onChange={(event) => setCategoryId(event.target.value)}>
            <option value="">No category yet</option>
            {categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
          </select>
          {!categoryId && <small>Without a category, this won’t count toward your spending.</small>}
        </label>}
        {(problem || error) && <p role="alert" className="statement-sheet-error">{problem ?? error}</p>}
        {busy && canClose && <p>Close this window to check whether your change saved or try it again.</p>}
        <div className="statement-sheet-actions">
          <Button type="submit" disabled={busy}>{busy ? 'Saving' : 'Save'}</Button>
          {!line.leftOut && <Button variant="secondary" disabled={busy} onClick={onLeaveOut}>Leave this line out</Button>}
        </div>
      </form>
    </section>
  </div>, document.body)
}

type AccountDraft = { source_account_id: number; label: string; account_basis: '' | 'asset' | 'liability'; period_start_on: string; period_end_on: string }

export function StatementAccountSheet({ accounts, reviewed, names, busy, canClose = !busy, error, onSave, onClose }: {
  accounts: SourceAccount[]; reviewed: ReviewedSourceAccount[]; names: Record<number, AccountLabel>; busy: boolean; canClose?: boolean; error: string | null
  onSave: (changes: AccountChange[]) => void; onClose: () => void
}) {
  const { dialogRef: ref, requestClose } = usePilotDialog(() => { if (canClose) onClose() })
  const [drafts, setDrafts] = useState<AccountDraft[]>(() => accounts.map((account) => ({
    source_account_id: account.id, label: names[account.id]?.name ?? '',
    account_basis: reviewed.find((row) => row.source_account_id === account.id)?.approved?.tracked_account.account_basis ?? (account.account_basis === 'unknown' ? '' : account.account_basis),
    period_start_on: account.period_start_on ?? '', period_end_on: account.period_end_on ?? '',
  })))
  const [problem, setProblem] = useState<string | null>(null)
  const update = (index: number, patch: Partial<AccountDraft>) => setDrafts((rows) => rows.map((row, at) => (at === index ? { ...row, ...patch } : row)))

  function save(event: FormEvent) {
    event.preventDefault()
    if (drafts.some((row) => !row.account_basis)) return setProblem('Choose bank account or credit card.')
    if (drafts.some((row) => row.period_start_on && row.period_end_on && row.period_start_on > row.period_end_on)) return setProblem('The statement can’t end before it starts.')
    setProblem(null)
    onSave(drafts.map((row) => ({ source_account_id: row.source_account_id, label: row.label.trim() || undefined, account_basis: row.account_basis as 'asset' | 'liability',
      period_start_on: row.period_start_on || undefined, period_end_on: row.period_end_on || undefined })))
  }

  return createPortal(<div className="pilot-dialog-overlay statement-sheet-overlay" data-dialog-surface="true" role="presentation">
    <section ref={ref} data-dialog-panel="true" data-dialog-private="true" className="pilot-dialog statement-sheet" role="dialog" aria-modal="true" aria-labelledby="statement-account-title" tabIndex={-1}>
      <header><h2 id="statement-account-title">{accounts.length > 1 ? 'Your accounts' : 'Your account'}</h2><Button variant="secondary" disabled={!canClose} onClick={requestClose}>Close</Button></header>
      <form className="statement-sheet-form" onSubmit={save}>
        {drafts.map((row, index) => <fieldset key={row.source_account_id}>
          {drafts.length > 1 && <legend>{row.label || accountSentence(names[row.source_account_id]) || `Account ${index + 1}`}</legend>}
          <label>Name<input value={row.label} maxLength={120} placeholder="Optional, like Bank of Guam checking" onChange={(event) => update(index, { label: event.target.value })} /></label>
          <label>Type
            <select value={row.account_basis} onChange={(event) => update(index, { account_basis: event.target.value as AccountDraft['account_basis'] })}>
              <option value="">Choose one</option><option value="asset">Bank account</option><option value="liability">Credit card</option>
            </select>
          </label>
          <div className="statement-sheet-pair">
            <label>Starts<input type="date" value={row.period_start_on} onChange={(event) => update(index, { period_start_on: event.target.value })} /></label>
            <label>Ends<input type="date" value={row.period_end_on} onChange={(event) => update(index, { period_end_on: event.target.value })} /></label>
          </div>
        </fieldset>)}
        {(problem || error) && <p role="alert" className="statement-sheet-error">{problem ?? error}</p>}
        {busy && canClose && <p>Close this window to check whether your change saved or try it again.</p>}
        <div className="statement-sheet-actions"><Button type="submit" disabled={busy}>{busy ? 'Saving' : 'Save'}</Button></div>
      </form>
    </section>
  </div>, document.body)
}
