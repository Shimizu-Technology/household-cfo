import { useCallback, useEffect, useRef, useState, type CSSProperties, type MouseEvent } from 'react'
import { createPortal } from 'react-dom'
import { useBrand } from '../contexts/brandContextValue'
import { partitionParticipantSections, PARTICIPANT_TOOL_SECTIONS } from '../lib/participantNavigation'

import '../styles/participantNavigation.css'

export type ParticipantTabsProps = {
  sections: string[]
  activeSection: string
  onChange: (section: string) => void
  staffOnly?: boolean
  savingsChallenge?: boolean
  onToday?: () => void
}


const sectionDescriptions: Record<string, string> = {
  'My Profile': 'Your household details and preferences.',
  'My Money': 'Find and update income, spending, debt, accounts, goals, and statements.',
  Statements: 'Upload privately and review accounts, periods, and statement rows.',
  Review: 'Review and confirm transactions.',
  Budget: 'Plan your money across the year.',
  Wealth: 'See debt, assets, and long-range capacity.',
  'CFO Filter': 'Pressure-test a purchase before money moves.',
  Optionality: 'Compare choices against stability and runway.',
  'Coach Studio': 'Daily coaching and program settings.',
  Admin: 'Manage pilot access and cohort operations.',
}

const compactLabels: Record<string, string> = {
  'My Profile': 'Profile',
  'My Money': 'Money',
  Statements: 'Files',
}

const sectionIconPaths: Record<string, string> = {
  Home: 'M4 11.2 12 4.5l8 6.7V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z',
  'Ask Mia': 'M5 5.5h14a1.5 1.5 0 0 1 1.5 1.5v8.5A1.5 1.5 0 0 1 19 17h-8.5L6 20.5V17H5a1.5 1.5 0 0 1-1.5-1.5V7A1.5 1.5 0 0 1 5 5.5zM8 10h8M8 13h5',
  Budget: 'M12 3.5a8.5 8.5 0 1 0 8.5 8.5H12zM15 3.9A8.5 8.5 0 0 1 20.1 9H15z',
  Review: 'M8 6h11M8 12h11M8 18h11M3.8 6l1 1 1.8-2M3.8 12l1 1 1.8-2M3.8 18l1 1 1.8-2',
  'My Money': 'M4 7.5A1.5 1.5 0 0 1 5.5 6h12A1.5 1.5 0 0 1 19 7.5V9h1v7h-1v1.5a1.5 1.5 0 0 1-1.5 1.5h-12A1.5 1.5 0 0 1 4 17.5zM15 12.5h5',
  Statements: 'M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10A.5.5 0 0 1 7 20zM14 3.5V8h4M9.5 12h6M9.5 15.5h6',
  More: 'M5 5h5v5H5zM14 5h5v5h-5zM5 14h5v5H5zM14 14h5v5h-5z',
}

function SectionIcon({ section }: { section: string }) {
  const path = sectionIconPaths[section] ?? sectionIconPaths.More
  return (
    <svg className="tabs-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d={path} />
    </svg>
  )
}

function TodayIcon() {
  return (
    <svg className="tabs-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 6v12M6 12h12" />
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

// A long branded assistant name ("Mia for Mrs. Mel BOG") is cut off in the
// narrow tab bar, so the compact label keeps only its first word.
function shortAssistantName(name: string) {
  const trimmed = name.trim()
  return trimmed.length <= 10 ? trimmed : trimmed.split(/\s+/)[0] || trimmed
}

function sectionHref(section: string) {
  return `#${encodeURIComponent(section)}`
}

export function ParticipantTabs(props: ParticipantTabsProps) {
  return props.staffOnly ? <StaffNavigation sections={props.sections} activeSection={props.activeSection} onChange={props.onChange} /> : <ParticipantNavigation {...props} />
}

/** W5 supplies role-filtered routes and the initial staff route; this component only renders navigation. */
export function StaffNavigation({ sections, activeSection, onChange }: Pick<ParticipantTabsProps, 'sections' | 'activeSection' | 'onChange'>) {
  const destinations = sections.filter(section => section === 'Coach Studio' || section === 'Admin')
  return <nav className="staff-navigation" aria-label="Staff sections">
    {destinations.map(section => <a key={section} href={sectionHref(section)} aria-current={activeSection === section ? 'page' : undefined} onClick={event => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      event.preventDefault()
      onChange(section)
    }}>{section}</a>)}
  </nav>
}

function ParticipantNavigation({ sections, activeSection, onChange, savingsChallenge = false, onToday }: ParticipantTabsProps) {
  const { assistantName, brand } = useBrand()
  const [moreOpen, setMoreOpen] = useState(false)
  const [toolsPosition, setToolsPosition] = useState({ top: 0, right: 16 })
  const shellRef = useRef<HTMLDivElement | null>(null)
  const moreButtonRef = useRef<HTMLButtonElement | null>(null)
  const secondaryRef = useRef<HTMLDivElement | null>(null)
  const { primary, secondary } = partitionParticipantSections(sections, savingsChallenge)
  const secondaryIsActive = secondary.includes(activeSection)
  const tools = secondary.filter(section => PARTICIPANT_TOOL_SECTIONS.includes(section))
  const destinations = secondary.filter(section => !PARTICIPANT_TOOL_SECTIONS.includes(section))

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
      const focusable = Array.from(dialog?.querySelectorAll<HTMLElement>('a[href], button:not(:disabled), summary') ?? []).filter(element => !element.closest('details:not([open])') || element.matches('summary'))
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

    window.requestAnimationFrame(() => secondaryRef.current?.querySelector<HTMLElement>('.tabs-tools-list > a, .tabs-tools-list summary')?.focus())
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

  const sectionLabel = (section: string, compact = false) => {
    if (savingsChallenge && section === 'Home') return 'Savings'
    if (savingsChallenge && section === 'Review') return 'Transactions'
    if (section === 'Ask Mia') return compact ? shortAssistantName(assistantName) : `Ask ${assistantName}`
    return compact ? compactLabels[section] ?? section : section
  }

  return (
    <div className={`tabs-shell${savingsChallenge ? ' is-savings-navigation' : ''}${moreOpen ? ' is-tools-open' : ''}`} ref={shellRef}>
      <nav className="tabs" aria-label={`${brand.short_name} participant sections`}>
        {savingsChallenge && onToday && <button type="button" className="tabs-today-action" onClick={event => { event.currentTarget.focus({ preventScroll: true }); onToday() }}><TodayIcon /><span className="tabs-label">Today</span></button>}
        {primary.map((section) => (
          <a
            key={section}
            href={sectionHref(section)}
            className={activeSection === section ? 'active' : ''}
            aria-label={sectionLabel(section)}
            aria-current={activeSection === section ? 'page' : undefined}
            onClick={(event) => chooseSection(event, section)}
          >
            <SectionIcon section={section} />
            <span className="tabs-label-full">{sectionLabel(section)}</span>
            <span className="tabs-label-short" aria-hidden="true">{sectionLabel(section, true)}</span>
          </a>
        ))}
        {secondary.length > 0 && (
          <button
            ref={moreButtonRef}
            type="button"
            className={`tabs-more-toggle${secondaryIsActive ? ' active' : ''}`}
            aria-label="More"
            aria-description={secondaryIsActive ? `Current section: ${sectionLabel(activeSection)}` : undefined}
            aria-expanded={moreOpen}
            aria-controls="participant-more-sections"
            onClick={toggleTools}
          >
            <SectionIcon section="More" />
            <span className="tabs-label">More</span>

          </button>
        )}
      </nav>
      {moreOpen && secondary.length > 0 && createPortal(
        <>
          <button
            type="button"
            className="tabs-tools-backdrop"
            aria-label="Close menu"
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
                <strong id="participant-tools-title">More</strong>
              </div>
              <button
                type="button"
                className="tabs-tools-close"
                aria-label="Close menu"
                onClick={closeTools}
              >
                <span aria-hidden="true">×</span>
              </button>
            </header>
            <div className="tabs-tools-list">
              {destinations.map((section) => (
                <a
                  key={section}
                  href={sectionHref(section)}
                  className={activeSection === section ? 'active' : ''}
                  aria-label={sectionLabel(section)}
                  aria-current={activeSection === section ? 'page' : undefined}
                  onClick={(event) => chooseSection(event, section)}
                >
                  <span>
                    <strong>{sectionLabel(section)}</strong>
                    <small>{sectionDescriptions[section] ?? `Open this ${brand.short_name} workspace.`}</small>
                  </span>
                  <ArrowIcon />
                </a>
              ))}
              {tools.length > 0 && <details className="tabs-tools-group" open={tools.includes(activeSection) || undefined}>
                <summary>Tools</summary>
                {tools.map(section => <a key={section} href={sectionHref(section)} aria-label={sectionLabel(section)} aria-current={activeSection === section ? 'page' : undefined} className={activeSection === section ? 'active' : ''} onClick={event => chooseSection(event, section)}>
                  <span><strong>{sectionLabel(section)}</strong><small>{sectionDescriptions[section]}</small></span><ArrowIcon />
                </a>)}
              </details>}
            </div>
          </div>
        </>,
        document.body,
      )}
    </div>
  )
}
