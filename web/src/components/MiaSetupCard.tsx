import { useId, useRef, useState } from 'react'
import type { MiaActionDraft, MiaSetupCardEdit, MiaSetupCardPart, MiaSetupCardRow } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'

type Editing = { key: string; row: MiaSetupCardRow; part?: MiaSetupCardPart }

const STATUS_TEXT: Record<string, string> = {
  missing: 'Not entered yet',
  skipped: 'Skipped for now',
  needs_monthly: 'Needs a monthly amount',
}

function rowValue(row: MiaSetupCardRow) {
  if (row.value_text) return row.value_text
  if (row.total_cents != null) return formatReviewMoney(row.total_cents)
  if (row.kind === 'debts' && row.status === 'needs_monthly') return 'Needs a minimum'
  return STATUS_TEXT[row.status] ?? STATUS_TEXT.missing
}

export function MiaSetupCard({
  draft,
  isRealWorkspace,
  action,
  disabled,
  onApply,
  onCancel,
  onEdit,
}: {
  draft: MiaActionDraft
  isRealWorkspace: boolean
  action: string | null
  disabled: boolean
  onApply: (draft: MiaActionDraft) => void
  onCancel: (draft: MiaActionDraft) => void
  onEdit: (draft: MiaActionDraft, edit: MiaSetupCardEdit) => Promise<boolean>
}) {
  const card = draft.setup_card
  const headingId = useId()
  const [editing, setEditing] = useState<Editing | null>(null)
  const [value, setValue] = useState('')
  const [saving, setSaving] = useState(false)
  const rowButtons = useRef(new Map<string, HTMLButtonElement>())
  if (!card) return null
  const locked = !isRealWorkspace || disabled || Boolean(action) || saving

  function open(row: MiaSetupCardRow, part?: MiaSetupCardPart) {
    const key = `${row.key}:${part?.id ?? ''}`
    if (editing?.key === key) {
      setEditing(null)
      return
    }
    setEditing({ key, row, part })
    if (row.kind === 'text') setValue(row.value_text ?? '')
    else {
      const cents = part ? part.cents : row.total_cents
      setValue(cents == null ? '' : String(cents / 100))
    }
  }

  async function submit(edit: MiaSetupCardEdit) {
    const key = editing?.key
    setSaving(true)
    try {
      if (!await onEdit(draft, edit)) return
      setEditing(null)
      // The form is gone, so focus returns to the row it came from.
      if (key) requestAnimationFrame(() => rowButtons.current.get(key)?.focus())
    } finally {
      setSaving(false)
    }
  }

  const rowOf = (row: MiaSetupCardRow, part?: MiaSetupCardPart) => {
    const isOpen = editing?.key === `${row.key}:${part?.id ?? ''}`
    const label = part ? part.label : row.label
    const shown = part
      ? (part.cents != null ? formatReviewMoney(part.cents) : part.note ?? STATUS_TEXT.needs_monthly)
      : rowValue(row)
    const note = part && part.cents != null ? part.note : null
    const rowKey = `${row.key}:${part?.id ?? ''}`
    // Named debts are changed one at a time, so their total is not a control.
    const isStatic = !part && row.kind === 'debts' && row.parts.length > 0
    return (
      <div className={`setup-card-line${part ? ' is-part' : ''}${!part && row.status === 'missing' ? ' is-empty' : ''}`}>
        {isStatic ? (
          <div className="setup-card-row is-static">
            <span className="setup-card-label">{label}</span>
            <span className="setup-card-value">{shown}</span>
          </div>
        ) : (
          <button
            type="button"
            ref={(element) => { if (element) rowButtons.current.set(rowKey, element); else rowButtons.current.delete(rowKey) }}
            className="setup-card-row"
            aria-expanded={isOpen}
            disabled={locked}
            onClick={() => open(row, part)}
            aria-label={`Change ${label}: ${shown}`}
          >
            <span className="setup-card-label">{label}{note && <small>{note}</small>}</span>
            <span className="setup-card-value">{shown}</span>
          </button>
        )}
        {isOpen && (
          <form className="setup-card-edit" onSubmit={(event) => {
            event.preventDefault()
            void submit({ field: row.key, action_name: 'set', part_id: part?.id, value })
          }}>
            <label>
              <span className="sr-only">{label}</span>
              <input
                autoFocus
                value={value}
                inputMode={row.kind === 'text' ? 'text' : 'decimal'}
                placeholder={row.kind === 'text' ? '' : 'Monthly amount'}
                onChange={(event) => setValue(event.target.value)}
              />
            </label>
            <div className="setup-card-edit-actions">
              <button type="submit" disabled={locked || !value.trim()}>{saving ? 'Saving' : 'Save'}</button>
              {part
                ? <button type="button" className="secondary-button" disabled={locked} onClick={() => void submit({ field: row.key, action_name: 'remove', part_id: part.id })}>Remove</button>
                : row.status === 'missing'
                  ? <button type="button" className="secondary-button" disabled={locked} onClick={() => void submit({ field: row.key, action_name: 'skip' })}>Skip for now</button>
                  : row.status === 'entered'
                    ? <button type="button" className="secondary-button" disabled={locked} onClick={() => void submit({ field: row.key, action_name: 'remove' })}>Remove</button>
                    : null}
            </div>
          </form>
        )}
      </div>
    )
  }

  return (
    <article className="setup-card" aria-labelledby={headingId}>
      <h4 id={headingId}>{card.title}</h4>
      <div className="setup-card-rows">
        {card.rows.map((row) => (
          <div className="setup-card-group" key={row.key}>
            {rowOf(row)}
            {row.parts.map((part) => <div key={part.id}>{rowOf(row, part)}</div>)}
            {row.note && <p className="setup-card-note">{row.note}</p>}
          </div>
        ))}
      </div>
      {draft.stale && <p className="mia-action-stale-note" role="status">Your numbers changed after this card was made, so it can’t be applied. Nothing was changed.</p>}
      <p className="setup-card-promise">Nothing saves until you tap Apply.</p>
      <div className="mia-action-draft-actions">
        <button type="button" disabled={locked || !card.can_apply || Boolean(draft.stale) || Boolean(editing)} onClick={() => onApply(draft)}>
          {action === `apply-mia-action:${draft.id}` ? 'Applying' : 'Apply'}
        </button>
        <button type="button" className="secondary-button" disabled={locked} onClick={() => onCancel(draft)}>
          {action === `cancel-mia-action:${draft.id}` ? 'Canceling' : 'Not now'}
        </button>
      </div>
    </article>
  )
}
