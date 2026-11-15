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
        {assistantName}<span className="mia-disclaimer-verb"> is an</span><span className="mia-disclaimer-colon">:</span> AI coach, not a financial advisor.
        {full && <>
          {' '}
          <button type="button" className="mia-disclaimer-toggle" aria-label={`About ${assistantName}`} aria-expanded={open} aria-controls={detailsId} onClick={() => setOpen(current => !current)}>
            About<span className="mia-disclaimer-name"> {assistantName}</span>
          </button>
        </>}
      </p>
      {full && <><p id={detailsId} className="mia-disclaimer-details" hidden={!open}>{full}</p><p className="mia-disclaimer-details" hidden={!open}><a target="_blank" rel="noopener noreferrer" href="/third-party/heic-to-NOTICE.txt">Photo converter notices</a>{' · '}<a target="_blank" rel="noopener noreferrer" href="/third-party/heic-to-LICENSE.txt">LGPL licence</a>{' · '}<a target="_blank" rel="noopener noreferrer" href="/third-party/GPL-3.0.txt">GPL licence</a>{' · '}<a target="_blank" rel="noopener noreferrer" href="/third-party/libheif-COPYING.txt">libheif licence</a>{' · '}<a target="_blank" rel="noopener noreferrer" href="/third-party/libde265-COPYING.txt">libde265 licence</a>{' · '}<a target="_blank" rel="noopener noreferrer" href="/third-party/Emscripten-LICENSE.txt">Emscripten licence</a></p></>}
    </div>
  )
}
