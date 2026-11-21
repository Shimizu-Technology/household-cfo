import { useEffect, useRef, useState } from 'react'
import { applyStatementBalance, fetchStatementBalanceOffers, type StatementBalanceOffer } from '../api'
import { OperationIdempotencyKeys } from '../lib/operationIdempotency'
import { participantErrorMessage } from '../lib/participantErrorMessage'
import { currentBalance, offerQuestion, type BalanceChoice as Choice } from '../lib/statementBalanceOffer'

const DISMISSED_KEY = 'hcfo.statement-balance.not-now'
const DISMISSED_EVENT = 'hcfo:statement-balance-not-now'
// Any approval made from one place (Home, My Money, Statements) refreshes the others.
const CHANGED_EVENT = 'hcfo:statement-balance-changed'

// "Not now" hides one exact offer on this device. A newer statement is a new offer.
function readDismissed(): string[] {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(DISMISSED_KEY) ?? '[]')
    return Array.isArray(value) ? value.filter((key): key is string => typeof key === 'string').slice(-50) : []
  } catch {
    return []
  }
}

function writeDismissed(keys: string[]) {
  try {
    globalThis.localStorage?.setItem(DISMISSED_KEY, JSON.stringify(keys.slice(-50)))
  } catch {
    // Storage can be unavailable; the offer simply stays hidden for this page.
  }
}

// "Not now" belongs to one statement's balance for one account, so a change to
// an account's balance elsewhere does not bring the same offer back.
function dismissalKey(offer: StatementBalanceOffer) {
  return `${offer.kind}:${offer.tracked_account_id}:${offer.as_of_on}:${offer.balance_cents}`
}

function initialChoice(offer: StatementBalanceOffer): Choice {
  if (offer.target) return offer.target.id
  if (offer.choices.length === 0 && offer.can_add_new) return 'new'
  return null
}

function OfferCard({ offer, onApplied, onDismiss, blockedReason }: {
  offer: StatementBalanceOffer
  onApplied: (offers: StatementBalanceOffer[]) => Promise<void>
  onDismiss: () => void
  blockedReason?: string | null
}) {
  const [choice, setChoice] = useState<Choice>(() => initialChoice(offer))
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const keys = useRef(new OperationIdempotencyKeys())
  const linked = offer.target != null && offer.choices.length === 0
  const options = [...(offer.target && !linked && !offer.choices.some((row) => row.id === offer.target?.id) ? [offer.target] : []), ...offer.choices]
  const chosen = [offer.target, ...offer.choices].find((row) => row?.id === choice) ?? null
  const name = `statement-balance-${offer.tracked_account_id}`

  async function approve() {
    if (choice == null || blockedReason) return
    const signature = `${offer.key}:${choice}`
    setSaving(true)
    setError(null)
    try {
      const next = await applyStatementBalance(offer, choice, keys.current.keyFor(signature))
      keys.current.complete(signature)
      await onApplied(next)
    } catch (caught) {
      setError(participantErrorMessage(caught, 'We couldn’t update this balance. Nothing changed. Try again.'))
      setSaving(false)
    }
  }

  return <article className="statement-balance-offer" aria-label={`Balance from your statement for ${offer.statement_label}`}>
    <p className="statement-balance-question">{offerQuestion(offer, choice)}</p>
    {chosen && <p className="statement-balance-now">Now: {currentBalance(chosen)}</p>}
    {!linked && options.length > 0 && <fieldset className="statement-balance-choices" disabled={saving}>
      <legend>{offer.kind === 'debt' ? 'Which card is this?' : 'Which account is this?'}</legend>
      {options.map((row) => <label className="ui-check" key={row.id}>
        <input type="radio" name={name} checked={choice === row.id} onChange={() => setChoice(row.id)} />
        <span>{row.label} <span className="statement-balance-amount">({currentBalance(row)})</span></span>
      </label>)}
      {offer.can_add_new && <label className="ui-check">
        <input type="radio" name={name} checked={choice === 'new'} onChange={() => setChoice('new')} />
        <span>{offer.kind === 'debt' ? 'Add it as a new card' : 'Add it as a new account'}</span>
      </label>}
    </fieldset>}
    {error && <p className="form-error" role="alert">{error}</p>}
    {blockedReason && <p className="statement-balance-now">{blockedReason}</p>}
    <div className="statement-balance-actions">
      <button type="button" className="ui-btn ui-btn--primary" disabled={saving || choice == null || !!blockedReason} onClick={approve}>
        {saving ? 'Saving…' : choice === 'new' ? (offer.kind === 'debt' ? 'Add card' : 'Add account') : 'Update balance'}
      </button>
      <button type="button" className="ui-btn ui-btn--text" disabled={saving} onClick={onDismiss}>Not now</button>
    </div>
  </article>
}

// Balances offered from her approved statements. Listing changes nothing; a
// balance changes only after she approves that one offer.
export function StatementBalanceOffers({ onChanged, className = '', refreshKey, blockedReason = null }: {
  onChanged: () => Promise<void>
  className?: string
  refreshKey?: unknown
  // An unsaved edit elsewhere on the page; approving would reload and lose it.
  blockedReason?: string | null
}) {
  const [offers, setOffers] = useState<StatementBalanceOffer[]>([])
  const [dismissed, setDismissed] = useState<string[]>(readDismissed)
  const [notice, setNotice] = useState<string | null>(null)
  const [reloads, setReloads] = useState(0)
  const [loadFailed, setLoadFailed] = useState(false)
  const self = useRef({})

  useEffect(() => {
    let current = true
    fetchStatementBalanceOffers()
      .then((rows) => { if (current) { setOffers(rows); setLoadFailed(false) } })
      // An offer is optional; the rest of the page works without it, and she can try again.
      .catch(() => { if (current) { setOffers([]); setLoadFailed(true) } })
    return () => { current = false }
  }, [refreshKey, reloads])
  useEffect(() => {
    // The keys travel with the event, so a failed storage write cannot undo "Not now".
    const sync = (event: Event) => { const keys: unknown = (event as CustomEvent).detail; setDismissed(Array.isArray(keys) ? keys as string[] : readDismissed()) }
    // The list that approved an offer already has the server's latest offers.
    const reload = (event: Event) => { if ((event as CustomEvent).detail !== self.current) setReloads((count) => count + 1) }
    globalThis.addEventListener(DISMISSED_EVENT, sync)
    globalThis.addEventListener(CHANGED_EVENT, reload)
    return () => {
      globalThis.removeEventListener(DISMISSED_EVENT, sync)
      globalThis.removeEventListener(CHANGED_EVENT, reload)
    }
  }, [])

  const visible = offers.filter((offer) => !dismissed.includes(dismissalKey(offer)))
  if (loadFailed) {
    return <section className={`statement-balance-offers ui-card ${className}`.trim()} aria-label="Balances from your statements">
      <p className="statement-balance-now" role="status">We couldn’t check your statements for balance updates.</p>
      <div className="statement-balance-actions"><button type="button" className="ui-btn ui-btn--tonal" onClick={() => setReloads((count) => count + 1)}>Try again</button></div>
    </section>
  }
  if (visible.length === 0 && !notice) return null

  async function applied(next: StatementBalanceOffer[]) {
    setOffers(next)
    setNotice('Balance updated.')
    globalThis.dispatchEvent(new CustomEvent(CHANGED_EVENT, { detail: self.current }))
    try {
      await onChanged()
    } catch {
      setNotice('Balance updated. Refresh to see it everywhere.')
    }
  }

  function dismiss(offer: StatementBalanceOffer) {
    const key = dismissalKey(offer)
    const keys = [...dismissed.filter((value) => value !== key), key].slice(-50)
    writeDismissed(keys)
    setDismissed(keys)
    globalThis.dispatchEvent(new CustomEvent(DISMISSED_EVENT, { detail: keys }))
  }

  return <section className={`statement-balance-offers ui-card ${className}`.trim()} aria-label="Balances from your statements">
    <h3 className="ui-section">{visible.length > 1 ? 'Balances from your statements' : 'Balance from your statement'}</h3>
    {notice && <p className="statement-balance-notice" role="status">{notice}</p>}
    {visible.map((offer) => <OfferCard key={offer.key} offer={offer} onApplied={applied} onDismiss={() => dismiss(offer)} blockedReason={blockedReason} />)}
  </section>
}
