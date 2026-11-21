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
  const [direction, setDirection] = useState(line.moneyDirection)
  const [kind, setKind] = useState<LineKind | ''>(line.recipientQuestion && line.moneyDirection !== 'in' ? '' : line.directionRequired && line.kind === 'spending' && !line.moneyDirection ? '' : line.kind)
  const [merchant, setMerchant] = useState(line.merchant)
  const [postedOn, setPostedOn] = useState(line.postedOn)
  const [amount, setAmount] = useState(amountInputText(line.amountCents))
  const [categoryId, setCategoryId] = useState(line.categoryId ? String(line.categoryId) : '')
  const [categorySpending, setCategorySpending] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const recipientQuestion = line.recipientQuestion && direction !== 'in'

  function save(event: FormEvent) {
    event.preventDefault()
    if (line.directionRequired && !direction) return setProblem('Choose whether this was money out or money in.')
    if (recipientQuestion && kind === 'spending' && categorySpending && !categoryId) return setProblem('Choose a category for this spending.')
    if (!kind) return setProblem(recipientQuestion ? 'Choose your own account or someone else.' : 'Choose what this line was.')
    const cents = parseLineAmount(amount)
    if (cents == null) return setProblem('Enter the amount, like 12.50.')
    if (!postedOn) return setProblem('Choose the date.')
    if ((kind === 'spending' || kind === 'cash') && !merchant.trim()) return setProblem('Add where the money went.')
    setProblem(null)
    onSave({ ...(direction ? { money_direction: direction } : {}), kind, merchant: merchant.trim(), posted_on: postedOn, amount_cents: cents, category_id: (!recipientQuestion || categorySpending) && (kind === 'spending' || kind === 'cash' || kind === 'refund') && categoryId ? Number(categoryId) : null })
  }

  return createPortal(<div className="pilot-dialog-overlay statement-sheet-overlay" data-dialog-surface="true" role="presentation">
    <section ref={ref} data-dialog-panel="true" data-dialog-private="true" className="pilot-dialog statement-sheet" role="dialog" aria-modal="true" aria-labelledby="statement-line-title" tabIndex={-1}>
      <header><h2 id="statement-line-title">{line.merchant || 'This line'}</h2><Button variant="secondary" disabled={!canClose} onClick={requestClose}>Close</Button></header>
      <form className="statement-sheet-form" onSubmit={save}>
        {line.leftOut && <p>This line is left out of spending and income.</p>}
        {line.rawDescription && <details><summary>Original bank text</summary><p>{line.rawDescription}</p></details>}
        {line.directionRequired && <fieldset><legend>Was this money out or money in?</legend>
          <div className="statement-answers">{(['out', 'in'] as const).map(value => <Button key={value} variant={direction === value ? 'primary' : 'secondary'} aria-pressed={direction === value} disabled={busy} onClick={() => { setDirection(value); if (line.recipientQuestion) setKind(value === 'in' ? 'money_in' : direction === 'in' ? '' : kind); else if (!kind || line.kind === 'spending' || line.kind === 'money_in' || (value === 'out' && kind === 'refund') || (value === 'in' && (kind === 'spending' || kind === 'cash'))) setKind(value === 'in' ? 'money_in' : 'spending') }}>{value === 'out' ? 'Money out' : 'Money in'}</Button>)}</div>
        </fieldset>}
        {recipientQuestion ? <fieldset><legend>Your own account or someone else?</legend>
          <div className="statement-answers">
            <Button variant={kind === 'moved' || kind === 'card' ? 'primary' : 'secondary'} aria-pressed={kind === 'moved' || kind === 'card'} disabled={busy} onClick={() => setKind(line.kind === 'card' ? 'card' : 'moved')}>Your own account</Button>
            <Button variant={kind === 'spending' && !categorySpending ? 'primary' : 'secondary'} aria-pressed={kind === 'spending' && !categorySpending} disabled={busy} onClick={() => { setKind('spending'); setCategorySpending(false) }}>Someone else</Button>
            <Button variant={kind === 'spending' && categorySpending ? 'primary' : 'secondary'} aria-pressed={kind === 'spending' && categorySpending} disabled={busy} onClick={() => { setKind('spending'); setCategorySpending(true) }}>Spending</Button>
          </div>
        </fieldset> : <label>What was this?
          <select value={kind} onChange={(event) => setKind(event.target.value as LineKind)}>
            {!kind && <option value="">Choose what this was</option>}
            {LINE_KIND_OPTIONS.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>}
        <label>Name
          <input value={merchant} maxLength={120} onChange={(event) => setMerchant(event.target.value)} />
        </label>
        <div className="statement-sheet-pair">
          <label>Date<input type="date" value={postedOn} onChange={(event) => setPostedOn(event.target.value)} /></label>
          <label>Amount<input inputMode="decimal" autoComplete="off" value={amount} onChange={(event) => setAmount(event.target.value)} placeholder="0.00" /></label>
        </div>
        {recipientQuestion && !categorySpending && kind === 'spending' && <p>This counts as Family support spending.</p>}
        {(!recipientQuestion || categorySpending) && (kind === 'spending' || kind === 'cash') && <label>Category
          <select value={categoryId} onChange={(event) => setCategoryId(event.target.value)}>
            <option value="">No category yet</option>
            {categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
          </select>
          {!categoryId && <small>Without a category, this won’t count toward your spending.</small>}
        </label>}
        {kind === 'refund' && <label>Goes back to
          <select value={categoryId} onChange={(event) => setCategoryId(event.target.value)}>
            <option value="">The purchase’s category</option>
            {categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}
          </select>
          <small>A refund lowers the category of what you bought, in the month the money came back. If we can’t find the purchase, we’ll ask.</small>
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

type AccountDraft = { source_account_id: number; choice: string; label: string; account_basis: '' | 'asset' | 'liability'; period_start_on: string; period_end_on: string }

export function StatementAccountSheet({ accounts, reviewed, names, busy, canClose = !busy, error, onSave, onClose }: {
  accounts: SourceAccount[]; reviewed: ReviewedSourceAccount[]; names: Record<number, AccountLabel>; busy: boolean; canClose?: boolean; error: string | null
  onSave: (changes: AccountChange[]) => void; onClose: () => void
}) {
  const { dialogRef: ref, requestClose } = usePilotDialog(() => { if (canClose) onClose() })
  const [drafts, setDrafts] = useState<AccountDraft[]>(() => accounts.map((account) => {
    const saved = reviewed.find((row) => row.source_account_id === account.id)
    return {
      source_account_id: account.id, label: names[account.id]?.name ?? '',
      choice: saved?.suggested ? String(saved.suggested.id) : '',
      account_basis: saved?.approved?.tracked_account.account_basis ?? (account.account_basis === 'unknown' ? '' : account.account_basis),
      period_start_on: saved?.approved?.statement_facts?.period_start_on ?? account.period_start_on ?? '',
      period_end_on: saved?.approved?.statement_facts?.period_end_on ?? account.period_end_on ?? '',
    }
  }))
  const [problem, setProblem] = useState<string | null>(null)
  const update = (index: number, patch: Partial<AccountDraft>) => setDrafts((rows) => rows.map((row, at) => (at === index ? { ...row, ...patch } : row)))

  function save(event: FormEvent) {
    event.preventDefault()
    if (drafts.some(row => !row.choice && reviewed.some(account => account.source_account_id === row.source_account_id && !account.approved && account.choices?.length))) return setProblem('Choose a saved account or a new account.')
    if (drafts.some((row) => !row.account_basis)) return setProblem('Choose bank account or credit card.')
    if (drafts.some((row) => row.period_start_on && row.period_end_on && row.period_start_on > row.period_end_on)) return setProblem('The statement can’t end before it starts.')
    setProblem(null)
    onSave(drafts.map((row) => {
      const reviewedAccount = reviewed.find(account => account.source_account_id === row.source_account_id)
      const choice = row.choice || (reviewedAccount?.needs_choice && !reviewedAccount.choices?.length ? 'new' : '')
      return {
        source_account_id: row.source_account_id,
        label: (!choice || choice === 'new') && row.label.trim() !== names[row.source_account_id]?.name ? row.label.trim() || undefined : undefined,
        tracked_account_id: choice === 'new' ? null : choice ? Number(choice) : undefined,
        account_basis: row.account_basis as 'asset' | 'liability',
        period_start_on: row.period_start_on || undefined, period_end_on: row.period_end_on || undefined,
      }
    }))
  }

  return createPortal(<div className="pilot-dialog-overlay statement-sheet-overlay" data-dialog-surface="true" role="presentation">
    <section ref={ref} data-dialog-panel="true" data-dialog-private="true" className="pilot-dialog statement-sheet" role="dialog" aria-modal="true" aria-labelledby="statement-account-title" tabIndex={-1}>
      <header><h2 id="statement-account-title">{accounts.length > 1 ? 'Your accounts' : 'Your account'}</h2><Button variant="secondary" disabled={!canClose} onClick={requestClose}>Close</Button></header>
      <form className="statement-sheet-form" onSubmit={save}>
        {drafts.map((row, index) => {
          const account = reviewed.find(item => item.source_account_id === row.source_account_id)
          const choices = account?.choices ?? []
          const selected = choices.find(choice => String(choice.id) === row.choice)
          return <fieldset key={row.source_account_id}>
            {drafts.length > 1 && <legend>{accountSentence(names[row.source_account_id]) || `Account ${index + 1}`}</legend>}
            {choices.length > 0 && <label>Account
              <select value={row.choice} onChange={event => {
                const choice = choices.find(item => String(item.id) === event.target.value)
                update(index, { choice: event.target.value, account_basis: choice?.account_basis ?? account?.approved?.tracked_account.account_basis ?? row.account_basis })
              }}>
                <option value="">{account?.approved ? 'This account' : 'Choose one'}</option>
                {choices.map(choice => <option key={choice.id} value={choice.id}>{accountSentence({ name: choice.name ?? '', last4: choice.last4 ?? '' }) || (choice.account_basis === 'asset' ? 'Bank account' : 'Credit card')}</option>)}
                <option value="new">New account</option>
              </select>
            </label>}
            {!selected && <label>Name<input value={row.label} maxLength={120} placeholder="Optional, like Bank of Guam checking" onChange={(event) => update(index, { label: event.target.value })} /></label>}
            {!selected && <label>Type
              <select value={row.account_basis} onChange={(event) => update(index, { account_basis: event.target.value as AccountDraft['account_basis'] })}>
                <option value="">Choose one</option><option value="asset">Bank account</option><option value="liability">Credit card</option>
              </select>
            </label>}
            <div className="statement-sheet-pair">
              <label>Starts<input type="date" value={row.period_start_on} onChange={(event) => update(index, { period_start_on: event.target.value })} /></label>
              <label>Ends<input type="date" value={row.period_end_on} onChange={(event) => update(index, { period_end_on: event.target.value })} /></label>
            </div>
          </fieldset>
        })}
        {reviewed.some(row => row.approved) && <p>Changing this account means its lines need a quick look again.</p>}
        {(problem || error) && <p role="alert" className="statement-sheet-error">{problem ?? error}</p>}
        {busy && canClose && <p>Close this window to check whether your change saved or try it again.</p>}
        <div className="statement-sheet-actions"><Button type="submit" disabled={busy}>{busy ? 'Saving' : 'Save'}</Button></div>
      </form>
    </section>
  </div>, document.body)
}
