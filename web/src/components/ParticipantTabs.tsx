import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

type ParticipantTabsProps = {
  sections: string[]
  activeSection: string
  onChange: (section: string) => void
}

const primarySections = new Set(['Home', 'Ask Mia', 'My Profile', 'Budget'])

const sectionDescriptions: Record<string, string> = {
  Activity: 'Review transactions and recent household changes.',
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

export function ParticipantTabs({ sections, activeSection, onChange }: ParticipantTabsProps) {
  const [moreOpen, setMoreOpen] = useState(false)
  const shellRef = useRef<HTMLDivElement | null>(null)
  const moreButtonRef = useRef<HTMLButtonElement | null>(null)
  const secondaryRef = useRef<HTMLDivElement | null>(null)
  const primary = sections.filter((section) => primarySections.has(section))
  const secondary = sections.filter((section) => !primarySections.has(section))
  const secondaryIsActive = secondary.includes(activeSection)

  useEffect(() => {
    if (!moreOpen) return

    const closeOnOutsidePointer = (event: PointerEvent) => {
      const target = event.target as Node
      if (!shellRef.current?.contains(target) && !secondaryRef.current?.contains(target)) setMoreOpen(false)
    }
    const closeOnEscape = (event: globalThis.KeyboardEvent) => {
      if (event.key !== 'Escape') return
      setMoreOpen(false)
      moreButtonRef.current?.focus()
    }

    document.addEventListener('pointerdown', closeOnOutsidePointer)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('pointerdown', closeOnOutsidePointer)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [moreOpen])

  const chooseSection = (section: string) => {
    setMoreOpen(false)
    onChange(section)
    if (secondary.includes(section)) {
      window.requestAnimationFrame(() => moreButtonRef.current?.focus({ preventScroll: true }))
    }
  }

  const toggleTools = () => {
    setMoreOpen((current) => {
      const next = !current
      if (next) {
        window.requestAnimationFrame(() => secondaryRef.current?.querySelector<HTMLButtonElement>('.tabs-tools-list button')?.focus())
      }
      return next
    })
  }

  return (
    <div className={`tabs-shell${moreOpen ? ' is-tools-open' : ''}`} ref={shellRef}>
      <nav className="tabs" aria-label="Household CFO participant sections">
        {primary.map((section) => (
          <button
            key={section}
            type="button"
            className={activeSection === section ? 'active' : ''}
            aria-label={section}
            aria-current={activeSection === section ? 'page' : undefined}
            onClick={() => chooseSection(section)}
          >
            <span className="tabs-label-full">{section}</span>
            <span className="tabs-label-short" aria-hidden="true">{compactLabels[section] ?? section}</span>
          </button>
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
            onClick={() => {
              setMoreOpen(false)
              moreButtonRef.current?.focus({ preventScroll: true })
            }}
          />
          <div
            ref={secondaryRef}
            className="tabs-secondary"
            id="participant-more-sections"
            aria-label="Household financial tools"
          >
            <header>
              <div>
                <span>Household tools</span>
                <strong>Go deeper when you need to.</strong>
              </div>
              <button
                type="button"
                className="tabs-tools-close"
                aria-label="Close tools"
                onClick={() => {
                  setMoreOpen(false)
                  moreButtonRef.current?.focus({ preventScroll: true })
                }}
              >
                <span aria-hidden="true">×</span>
              </button>
            </header>
            <div className="tabs-tools-list">
              {secondary.map((section) => (
                <button
                  key={section}
                  type="button"
                  className={activeSection === section ? 'active' : ''}
                  aria-label={section}
                  aria-current={activeSection === section ? 'page' : undefined}
                  onClick={() => chooseSection(section)}
                >
                  <span>
                    <strong>{section}</strong>
                    <small>{sectionDescriptions[section] ?? 'Open this Household CFO workspace.'}</small>
                  </span>
                  <ArrowIcon />
                </button>
              ))}
            </div>
          </div>
        </>,
        document.body,
      )}
    </div>
  )
}
