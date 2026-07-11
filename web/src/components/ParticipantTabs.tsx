type ParticipantTabsProps = {
  sections: string[]
  activeSection: string
  onChange: (section: string) => void
}

export function ParticipantTabs({ sections, activeSection, onChange }: ParticipantTabsProps) {
  return (
    <div className="tabs-shell">
      <nav className="tabs" aria-label="Household CFO participant sections">
        {sections.map((section) => (
          <button
            key={section}
            type="button"
            className={activeSection === section ? 'active' : ''}
            aria-current={activeSection === section ? 'page' : undefined}
            onClick={() => onChange(section)}
          >
            {section}
          </button>
        ))}
      </nav>
      <span className="tabs-scroll-cue" aria-hidden="true">Swipe for more →</span>
    </div>
  )
}
