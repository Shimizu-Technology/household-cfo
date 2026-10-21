import { useId } from 'react'

// One plain list row on the savings home: a label, a one-line description and a
// chevron. Used inside <summary> (inline sections) and buttons (dialogs).
export function SavingsRowContent({ label, description, count, labelId, descriptionId }: { label: string; description: string; count?: string; labelId?: string; descriptionId?: string }) {
  return <>
    <span className="savings-row-text">
      <span className="savings-row-label" id={labelId}>{label}{count && <span className="savings-row-count"> · {count}</span>}</span>
      <span className="savings-row-desc" id={descriptionId}>{description}</span>
    </span>
    <svg className="savings-chevron" viewBox="0 0 20 20" aria-hidden="true" focusable="false"><path d="M7.5 4.5 13 10l-5.5 5.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" /></svg>
  </>
}

// A row that opens a dialog. Its accessible name is the label alone; the
// description is announced as a description.
export function SavingsRowButton({ label, description, onClick, busyLabel, disabled }: { label: string; description: string; onClick: () => void; busyLabel?: string; disabled?: boolean }) {
  const id = useId()
  return <button type="button" className="savings-row" disabled={disabled} aria-labelledby={`${id}-label`} aria-describedby={`${id}-desc`} onClick={(event) => { event.currentTarget.focus(); onClick() }}>
    <SavingsRowContent label={busyLabel ?? label} description={description} labelId={`${id}-label`} descriptionId={`${id}-desc`} />
  </button>
}
