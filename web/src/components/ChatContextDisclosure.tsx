import { useRef, type ReactNode } from 'react'

/** Secondary chat context remains native, nonmodal, and independent of conversation state. */
export function ChatContextDisclosure({ children }: { children: ReactNode }) {
  const disclosureRef = useRef<HTMLDetailsElement>(null)
  const close = () => {
    const disclosure = disclosureRef.current
    if (!disclosure) return
    disclosure.open = false
    disclosure.querySelector('summary')?.focus({ preventScroll: true })
  }
  return (
    <details ref={disclosureRef} className="mia-context-disclosure" onKeyDown={(event) => {
      if (event.key === 'Escape' && disclosureRef.current?.open) {
        event.stopPropagation()
        close()
      }
    }}>
      <summary>Context &amp; help</summary>
      <div className="mia-context-drawer" role="region" aria-label="Chat context and help">
        <button type="button" className="secondary-button mia-context-close" onClick={close}>Close context</button>
        {children}
      </div>
    </details>
  )
}
