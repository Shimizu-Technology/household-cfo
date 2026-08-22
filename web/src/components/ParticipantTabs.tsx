import { useRef, useState } from 'react'

type ParticipantTabsProps = {
  sections: string[]
  activeSection: string
  onChange: (section: string) => void
}

const primarySections = new Set(['Home', 'Ask Mia', 'My Profile', 'Budget'])

export function ParticipantTabs({ sections, activeSection, onChange }: ParticipantTabsProps) {
  const [moreOpen, setMoreOpen] = useState(false)
  const moreButtonRef = useRef<HTMLButtonElement | null>(null)
  const primary = sections.filter((section) => primarySections.has(section))
  const secondary = sections.filter((section) => !primarySections.has(section))
  const secondaryIsActive = secondary.includes(activeSection)

  const chooseSection = (section: string) => {
    setMoreOpen(false)
    onChange(section)
    if (secondary.includes(section)) {
      window.requestAnimationFrame(() => moreButtonRef.current?.focus({ preventScroll: true }))
    }
  }

  return (
    <div className="tabs-shell">
      <nav className={`tabs${moreOpen ? ' is-more-open' : ''}`} aria-label="Household CFO participant sections">
        {primary.map((section) => (
          <button
            key={section}
            type="button"
            className={activeSection === section ? 'active' : ''}
            aria-current={activeSection === section ? 'page' : undefined}
            onClick={() => chooseSection(section)}
          >
            {section}
          </button>
        ))}
        {secondary.length > 0 && (
          <button
            ref={moreButtonRef}
            type="button"
            className={`tabs-more-toggle${secondaryIsActive ? ' active' : ''}`}
            aria-expanded={moreOpen}
            aria-controls="participant-more-sections"
            onClick={() => setMoreOpen((current) => !current)}
          >
            More <span aria-hidden="true">{moreOpen ? '−' : '+'}</span>
          </button>
        )}
        <div className="tabs-secondary" id="participant-more-sections">
          {secondary.map((section) => (
            <button
              key={section}
              type="button"
              className={activeSection === section ? 'active' : ''}
              aria-current={activeSection === section ? 'page' : undefined}
              onClick={() => chooseSection(section)}
            >
              {section}
            </button>
          ))}
        </div>
      </nav>
    </div>
  )
}
