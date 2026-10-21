import { useId, useState } from 'react'

/**
 * One short line under the composer. The full program disclosure (who the
 * assistant is built from and every kind of advice it does not replace) stays
 * one tap away under "About".
 */
export function MiaDisclaimer({ assistantName, fullText }: { assistantName: string; fullText?: string | null }) {
  const [open, setOpen] = useState(false)
  const detailsId = useId()
  const full = fullText?.trim()
  return (
    <div className="disclaimer mia-disclaimer">
      <p>
        {assistantName} is an AI coaching assistant, not a legal, tax or financial advisor.
        {full && <>
          {' '}
          <button type="button" className="mia-disclaimer-toggle" aria-expanded={open} aria-controls={detailsId} onClick={() => setOpen(current => !current)}>
            About {assistantName}
          </button>
        </>}
      </p>
      {full && <p id={detailsId} className="mia-disclaimer-details" hidden={!open}>{full}</p>}
    </div>
  )
}
