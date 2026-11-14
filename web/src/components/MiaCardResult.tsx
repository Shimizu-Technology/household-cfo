import { useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'

/** The result stays exposed; only extra detail folds away. Restored history is silent. */
export function MiaCardResult({ title, status, children, onDone, headingRef, live = false }: {
  title: string
  status?: string
  children?: ReactNode
  onDone?: () => void
  headingRef?: RefObject<HTMLHeadingElement | null>
  live?: boolean
}) {
  const ownHeading = useRef<HTMLHeadingElement>(null)
  const resultHeading = headingRef ?? ownHeading
  const [announce] = useState(live)
  const focused = useRef(false)
  useLayoutEffect(() => {
    if (!live || focused.current) return
    focused.current = true
    const active = document.activeElement
    if (active && active !== document.body && !resultHeading.current?.parentElement?.contains(active)) return
    resultHeading.current?.focus({ preventScroll: true })
  }, [live, resultHeading])
  return <>
    {status ? <>
      <h3 ref={resultHeading} tabIndex={-1}>{title}</h3>
      <p role="status" aria-live={announce ? 'polite' : 'off'}>{status}</p>
    </> : <div role="status" aria-live={announce ? 'polite' : 'off'}>
      <h3 ref={resultHeading} tabIndex={-1}>{title}</h3>
    </div>}
    {children && <details className="ui-disclosure">
      <summary>See details</summary>
      <div>{children}</div>
    </details>}
    {onDone && <button type="button" className="mia-daily-dismiss ui-btn ui-btn--text" onClick={onDone}>Done</button>}
  </>
}
