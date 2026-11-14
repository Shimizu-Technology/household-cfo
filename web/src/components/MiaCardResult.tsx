import type { ReactNode, RefObject } from 'react'

/** A completed review is a quiet result. Its existing detail remains available. */
export function MiaCardResult({ title, children, onDone, headingRef }: {
  title: string
  children: ReactNode
  onDone: () => void
  headingRef?: RefObject<HTMLHeadingElement | null>
}) {
  return <>
    <details className="ui-disclosure">
      <summary><h3 ref={headingRef} tabIndex={-1}>{title}</h3></summary>
      <div>{children}</div>
    </details>
    <button type="button" className="mia-daily-dismiss ui-btn ui-btn--text" onClick={onDone}>Done</button>
  </>
}
