import { useCallback, useEffect, useRef, useState, type CSSProperties, type MouseEvent } from 'react'
import { createPortal } from 'react-dom'

type ParticipantTabsProps = {
  sections: string[]
  activeSection: string
  onChange: (section: string) => void
}

const primarySections = new Set(['Home', 'Review', 'Ask Mia', 'Budget'])

const sectionDescriptions: Record<string, string> = {
  'My Profile': 'Update household context, documents, and bank connections.',
  Wealth: 'See debt, assets, and long-range capacity.',
  'CFO Filter': 'Pressure-test a purchase before money moves.',
  Optionality: 'Compare choices against stability and runway.',
  Admin: 'Manage pilot access and cohort operations.',
}

const compactLabels: Record<string, string> = {
  'Ask Mia': 'Mia',
  'My Profile': 'Profile',
  Budget: 'Plan',
}

function ToolsIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4.5 4.5h6v6h-6zM13.5 4.5h6v6h-6zM4.5 13.5h6v6h-6zM13.5 13.5h6v6h-6z" />
    </svg>
  )
}

function ArrowIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="m9 5 7 7-7 7" />
    </svg>
  )
}

function sectionHref(section: string) {
  return `#${encodeURIComponent(section)}`
}

export function ParticipantTabs({ sections, activeSection, onChange }: ParticipantTabsProps) {
  const [moreOpen, setMoreOpen] = useState(false)
  const [toolsPosition, setToolsPosition] = useState({ top: 0, right: 16 })
  const shellRef = useRef<HTMLDivElement | null>(null)
  const moreButtonRef = useRef<HTMLButtonElement | null>(null)
  const secondaryRef = useRef<HTMLDivElement | null>(null)
  const primary = sections.filter((section) => primarySections.has(section))
  const secondary = sections.filter((section) => !primarySections.has(section))
  const secondaryIsActive = secondary.includes(activeSection)

  const closeTools = useCallback(() => {
    setMoreOpen(false)
    window.requestAnimationFrame(() => moreButtonRef.current?.focus({ preventScroll: true }))
  }, [])

  const updateToolsPosition = useCallback(() => {
    const triggerBox = moreButtonRef.current?.getBoundingClientRect()
    if (!triggerBox) return

    setToolsPosition({
      top: Math.round(triggerBox.bottom + 8),
      right: Math.max(16, Math.round(window.innerWidth - triggerBox.right)),
    })
  }, [])

  useEffect(() => {
    if (!moreOpen) return

    const closeOnOutsidePointer = (event: PointerEvent) => {
      const target = event.target as Node
      if (!shellRef.current?.contains(target) && !secondaryRef.current?.contains(target)) closeTools()
    }
    const closeOnEscape = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape') {
        closeTools()
        return
      }
      if (event.key !== 'Tab') return

      const dialog = secondaryRef.current
      const focusable = Array.from(dialog?.querySelectorAll<HTMLElement>('a[href], button:not(:disabled)') ?? [])
      const first = focusable[0]
      const last = focusable.at(-1)
      if (!first || !last) {
        event.preventDefault()
        return
      }

      if (event.shiftKey && (document.activeElement === first || !dialog?.contains(document.activeElement))) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    updateToolsPosition()
    window.addEventListener('resize', updateToolsPosition)
    window.addEventListener('scroll', updateToolsPosition, true)

    document.addEventListener('pointerdown', closeOnOutsidePointer)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      window.removeEventListener('resize', updateToolsPosition)
      window.removeEventListener('scroll', updateToolsPosition, true)
      document.removeEventListener('pointerdown', closeOnOutsidePointer)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [closeTools, moreOpen, updateToolsPosition])

  useEffect(() => {
    if (!moreOpen) return

    window.requestAnimationFrame(() => secondaryRef.current?.querySelector<HTMLAnchorElement>('.tabs-tools-list a')?.focus())
  }, [moreOpen])

  const chooseSection = (event: MouseEvent<HTMLAnchorElement>, section: string) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    event.preventDefault()
    if (secondary.includes(section)) closeTools()
    else setMoreOpen(false)
    onChange(section)
  }

  const toggleTools = () => {
    if (moreOpen) {
      closeTools()
      return
    }

    updateToolsPosition()
    setMoreOpen(true)
  }

  return (
    <div className={`tabs-shell${moreOpen ? ' is-tools-open' : ''}`} ref={shellRef}>
      <nav className="tabs" aria-label="Household CFO participant sections">
        {primary.map((section) => (
          <a
            key={section}
            href={sectionHref(section)}
            className={activeSection === section ? 'active' : ''}
            aria-label={section}
            aria-current={activeSection === section ? 'page' : undefined}
            onClick={(event) => chooseSection(event, section)}
          >
            <span className="tabs-label-full">{section}</span>
            <span className="tabs-label-short" aria-hidden="true">{compactLabels[section] ?? section}</span>
          </a>
        ))}
        {secondary.length > 0 && (
          <button
            ref={moreButtonRef}
            type="button"
            className={`tabs-more-toggle${secondaryIsActive ? ' active' : ''}`}
            aria-expanded={moreOpen}
            aria-controls="participant-more-sections"
            onClick={toggleTools}
          >
            <ToolsIcon />
            <span>Tools</span>
          </button>
        )}
      </nav>
      {moreOpen && secondary.length > 0 && createPortal(
        <>
          <button
            type="button"
            className="tabs-tools-backdrop"
            aria-label="Close tools"
            tabIndex={-1}
            onClick={closeTools}
          />
          <div
            ref={secondaryRef}
            className="tabs-secondary"
            id="participant-more-sections"
            role="dialog"
            aria-modal="true"
            aria-labelledby="participant-tools-title"
            style={{
              '--tools-top': `${toolsPosition.top}px`,
              '--tools-right': `${toolsPosition.right}px`,
            } as CSSProperties}
          >
            <header>
              <div>
                <span>Household tools</span>
                <strong id="participant-tools-title">Go deeper when you need to.</strong>
              </div>
              <button
                type="button"
                className="tabs-tools-close"
                aria-label="Close tools"
                onClick={closeTools}
              >
                <span aria-hidden="true">×</span>
              </button>
            </header>
            <div className="tabs-tools-list">
              {secondary.map((section) => (
                <a
                  key={section}
                  href={sectionHref(section)}
                  className={activeSection === section ? 'active' : ''}
                  aria-label={section}
                  aria-current={activeSection === section ? 'page' : undefined}
                  onClick={(event) => chooseSection(event, section)}
                >
                  <span>
                    <strong>{section}</strong>
                    <small>{sectionDescriptions[section] ?? 'Open this Household CFO workspace.'}</small>
                  </span>
                  <ArrowIcon />
                </a>
              ))}
            </div>
          </div>
        </>,
        document.body,
      )}
    </div>
  )
}
