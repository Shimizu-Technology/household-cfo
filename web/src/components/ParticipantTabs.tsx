import { useCallback, useId, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type MouseEvent, type ReactNode, type PointerEvent } from 'react'
import { createPortal, flushSync } from 'react-dom'
import { useBrand } from '../contexts/brandContextValue'
import { partitionParticipantSections, participantSectionLabel, PARTICIPANT_TOOL_SECTIONS } from '../lib/participantNavigation'

import { lockBodyScroll } from '../lib/bodyScrollLock'
import { TEXT_ENTRY_SELECTOR } from '../lib/textEntry'
import { dialogExit } from '../lib/dialogExit'
import { useShellSidebar } from '../lib/useShellSidebar'

import '../styles/participantNavigation.css'

export type ParticipantTabsProps = {
  identity?: ReactNode
  account?: ReactNode
  onAccount?: () => void
  reviewCount?: number
  sections: string[]
  activeSection: string
  onChange: (section: string) => void
  savingsChallenge?: boolean
  customModuleOrder?: boolean
}


const sectionDescriptions: Record<string, string> = {
  'My Profile': 'Your household details and preferences.',
  'My Money': 'Update income, spending, debt, accounts, and goals.',
  Statements: 'Upload a statement or receipt and check what Mia found.',
  Review: 'Review and confirm transactions.',
  Budget: 'Plan your money across the year.',
  Wealth: 'See debt, assets, and long-range capacity.',
  'CFO Filter': 'Pressure-test a purchase before money moves.',
  Optionality: 'Compare choices against stability and runway.',
}

const sectionIconPaths: Record<string, string> = {
  Home: 'M4 11.2 12 4.5l8 6.7V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z',
  'Ask Mia': 'M5 5.5h14a1.5 1.5 0 0 1 1.5 1.5v8.5A1.5 1.5 0 0 1 19 17h-8.5L6 20.5V17H5a1.5 1.5 0 0 1-1.5-1.5V7A1.5 1.5 0 0 1 5 5.5zM8 10h8M8 13h5',
  Budget: 'M12 3.5a8.5 8.5 0 1 0 8.5 8.5H12zM15 3.9A8.5 8.5 0 0 1 20.1 9H15z',
  Review: 'M8 6h11M8 12h11M8 18h11M3.8 6l1 1 1.8-2M3.8 12l1 1 1.8-2M3.8 18l1 1 1.8-2',
  'My Money': 'M4 7.5A1.5 1.5 0 0 1 5.5 6h12A1.5 1.5 0 0 1 19 7.5V9h1v7h-1v1.5a1.5 1.5 0 0 1-1.5 1.5h-12A1.5 1.5 0 0 1 4 17.5zM15 12.5h5',
  Statements: 'M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10A.5.5 0 0 1 7 20zM14 3.5V8h4M9.5 12h6M9.5 15.5h6',
  'My Profile': 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8M5 21v-2a7 7 0 0 1 14 0v2',
  Wealth: 'M4 20V9h4v11M10 20V4h4v16M16 20v-7h4v7',
  'CFO Filter': 'M4 5h16l-6 7v7l-4 2v-9z',
  Optionality: 'M5 19V5M5 12h8M13 12l5-6M13 12l5 6',
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


function ArrowIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="m9 5 7 7-7 7" />
    </svg>
  )
}

// A long branded assistant name ("Mia for Mrs. Mel BOG") is cut off in the
// narrow tab bar, so the compact label keeps only its first word.
function sectionHref(section: string) {
  return `#${encodeURIComponent(section)}`
}

export function ParticipantTabs(props: ParticipantTabsProps) {
  return <ParticipantNavigation {...props} />
}

function ParticipantNavigation({ identity, account, onAccount, reviewCount = 0, sections, activeSection, onChange, savingsChallenge = false, customModuleOrder = false }: ParticipantTabsProps) {
  const { assistantName, brand } = useBrand()
  const sidebar = useShellSidebar()
  const reviewDescriptionId = useId()
  const drag = useRef<{ id: number; y: number; time: number; distance: number } | null>(null)
  const [moreOpen, setMoreOpen] = useState(false)
  const [toolsPosition, setToolsPosition] = useState({ top: 0, right: 16 })
  const shellRef = useRef<HTMLDivElement | null>(null)
  const moreButtonRef = useRef<HTMLButtonElement | null>(null)
  const secondaryRef = useRef<HTMLDivElement | null>(null)
  const { primary, secondary } = partitionParticipantSections(sections, savingsChallenge, customModuleOrder)
  const hasMore = secondary.length > 0 || Boolean(onAccount)
  const secondaryIsActive = secondary.includes(activeSection)
  const tools = customModuleOrder ? [] : secondary.filter(section => PARTICIPANT_TOOL_SECTIONS.includes(section))
  const destinations = customModuleOrder ? secondary : secondary.filter(section => !PARTICIPANT_TOOL_SECTIONS.includes(section))

  useEffect(() => {
    let heldRoot: HTMLElement | null = null
    let releaseTimer: number | undefined
    const root = shellRef.current?.closest<HTMLElement>('.participant-app')
    const updateFocus = (event?: FocusEvent) => {
      const active = event?.type === 'focusout' ? event.relatedTarget : document.activeElement
      root?.toggleAttribute('data-text-entry-focus', active instanceof Element && active.matches(TEXT_ENTRY_SELECTOR) && root.contains(active))
    }
    const releaseOnUp = () => {
      if (!heldRoot) return
      // A synthesized click follows pointerup; keep its target uncovered until
      // that dispatch finishes. The bounded fallback also covers legacy delayed
      // touch clicks and releases presses that produce no click.
      window.clearTimeout(releaseTimer)
      releaseTimer = window.setTimeout(release, 350)
    }
    const release = () => {
      window.clearTimeout(releaseTimer)
      releaseTimer = undefined
      const root = heldRoot
      heldRoot = null
      // Click has its target now. Release after its handlers commit, including
      // when animation frames are suspended by a background tab or test clock.
      queueMicrotask(() => root?.removeAttribute('data-field-pointer'))
    }
    const hold = () => {
      const active = document.activeElement
      const root = shellRef.current?.closest<HTMLElement>('.participant-app')
      if (window.innerWidth > 620 || !root || !active || !root.contains(active)
        || !active.matches(TEXT_ENTRY_SELECTOR)) return
      heldRoot = root
      root.setAttribute('data-field-pointer', '')
    }
    updateFocus()
    document.addEventListener('focusin', updateFocus)
    document.addEventListener('focusout', updateFocus)
    window.addEventListener('pointerup', releaseOnUp, true)
    document.addEventListener('pointerdown', hold, true)
    document.addEventListener('click', release, true)
    window.addEventListener('blur', release)
    document.addEventListener('pointercancel', release, true)
    return () => {
      window.clearTimeout(releaseTimer)
      root?.removeAttribute('data-text-entry-focus')
      document.removeEventListener('focusin', updateFocus)
      document.removeEventListener('focusout', updateFocus)
      window.removeEventListener('pointerup', releaseOnUp, true)
      heldRoot?.removeAttribute('data-field-pointer')
      document.removeEventListener('pointerdown', hold, true)
      document.removeEventListener('click', release, true)
      window.removeEventListener('blur', release)
      document.removeEventListener('pointercancel', release, true)
    }
  }, [])

  const closeTools = useCallback((restoreFocus = true) => {
    drag.current = null
    dialogExit(secondaryRef.current, () => flushSync(() => setMoreOpen(false)))
    if (restoreFocus) window.requestAnimationFrame(() => moreButtonRef.current?.focus({ preventScroll: true }))
  }, [])

  useLayoutEffect(() => {
    if (!moreOpen || sidebar) { drag.current = null; return }
    return lockBodyScroll()
  }, [moreOpen, sidebar])

  useEffect(() => {
    if (!sidebar || !moreOpen) return
    // Responsive replacement unmounts the sheet during render; clear its toggle
    // outside React's lifecycle rather than calling flushSync from an effect.
    const frame = window.requestAnimationFrame(() => setMoreOpen(false))
    return () => window.cancelAnimationFrame(frame)
  }, [sidebar, moreOpen])

  const startDrag = (event: PointerEvent<HTMLDivElement>) => {
    if (drag.current || !event.isPrimary || event.button !== 0) return
    drag.current = { id: event.pointerId, y: event.clientY, time: event.timeStamp, distance: 0 }
    event.currentTarget.setPointerCapture(event.pointerId)
    if (secondaryRef.current) secondaryRef.current.style.transition = 'none'
  }
  const moveDrag = (event: PointerEvent<HTMLDivElement>) => {
    const current = drag.current
    if (!current || current.id !== event.pointerId) return
    const delta = event.clientY - current.y
    current.distance = delta
    // Resistance above the resting edge; only the handle owns the gesture.
    const offset = delta < 0 ? -Math.sqrt(-delta) : delta
    if (secondaryRef.current) secondaryRef.current.style.transform = `translateY(${offset}px)`
  }
  const finishDrag = (event: PointerEvent<HTMLDivElement>, cancelled = false) => {
    const current = drag.current
    if (!current || current.id !== event.pointerId) return
    drag.current = null
    event.currentTarget.releasePointerCapture(event.pointerId)
    const velocity = current.distance / Math.max(1, event.timeStamp - current.time)
    if (secondaryRef.current) secondaryRef.current.style.removeProperty('transition')
    if (!cancelled && (current.distance > 80 || (current.distance > 8 && velocity > 0.11))) closeTools()
    else secondaryRef.current?.style.removeProperty('transform')
  }

  const updateToolsPosition = useCallback(() => {
    const triggerBox = moreButtonRef.current?.getBoundingClientRect()
    if (!triggerBox) return

    setToolsPosition({
      top: Math.round(triggerBox.bottom + 8),
      right: Math.max(16, Math.round(window.innerWidth - triggerBox.right)),
    })
  }, [])

  useEffect(() => {
    if (!moreOpen || sidebar) return

    const closeOnOutsidePointer = (event: globalThis.PointerEvent) => {
      // Touch's click is hit-tested on release. Keep the live backdrop until
      // its own click consumes the tap, so it cannot reach a page control.
      if (event.pointerType === 'touch') return
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
  }, [closeTools, moreOpen, sidebar, updateToolsPosition])

  useEffect(() => {
    if (!moreOpen || sidebar) return
    const frame = window.requestAnimationFrame(() => secondaryRef.current?.querySelector<HTMLElement>('.tabs-tools-list > a, .tabs-tools-list summary, .tabs-account-row')?.focus())
    return () => window.cancelAnimationFrame(frame)
  }, [moreOpen, sidebar])

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

  const sectionLabel = (section: string, compact = false) => participantSectionLabel(section, savingsChallenge, assistantName, compact)

  return (
    <>
    {!sidebar && identity && <header className="shell-header">{identity}{account}</header>}
    <div className="tabs-ground" aria-hidden="true" />
    <div className={`tabs-shell${sidebar ? ' shell-sidebar' : ''}${savingsChallenge ? ' is-savings-navigation' : ''}${moreOpen ? ' is-tools-open' : ''}`} ref={shellRef}>
      {sidebar && identity && <header className="shell-header">{identity}</header>}
      {sidebar && reviewCount > 0 && <span id={reviewDescriptionId} className="sr-only">{reviewCount} purchases waiting</span>}
      <nav className="tabs" aria-label={`${brand.short_name} participant sections`}>
        {primary.map((section) => (
          <a
            key={section}
            href={sectionHref(section)}
            className={activeSection === section ? 'active' : ''}
            aria-label={sectionLabel(section)} aria-describedby={sidebar && section === 'Review' && reviewCount > 0 ? reviewDescriptionId : undefined}
            aria-current={activeSection === section ? 'page' : undefined}
            onClick={(event) => chooseSection(event, section)}
          >
            <SectionIcon section={section} />
            <span className="tabs-label-full">{sectionLabel(section)}</span>
            <span className="tabs-label-short" aria-hidden="true">{sectionLabel(section, true)}</span>
            {sidebar && section === 'Review' && reviewCount > 0 && <span className="tabs-review-count" aria-hidden="true">{reviewCount}</span>}
          </a>
        ))}
        {!sidebar && hasMore && (
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
        {sidebar && destinations.map(section => <a key={section} href={sectionHref(section)} aria-label={sectionLabel(section)} aria-describedby={sidebar && section === 'Review' && reviewCount > 0 ? reviewDescriptionId : undefined} aria-current={activeSection === section ? 'page' : undefined} className={activeSection === section ? 'active' : ''} onClick={event => chooseSection(event, section)}><SectionIcon section={section} /><span>{sectionLabel(section)}</span>{section === 'Review' && reviewCount > 0 && <span className="tabs-review-count" aria-hidden="true">{reviewCount}</span>}</a>)}
        {sidebar && tools.length > 0 && <div className="sidebar-tools"><span className="sidebar-group-label">Tools</span>{tools.map(section => <a key={section} href={sectionHref(section)} aria-label={sectionLabel(section)} aria-current={activeSection === section ? 'page' : undefined} className={activeSection === section ? 'active' : ''} onClick={event => chooseSection(event, section)}><SectionIcon section={section} /><span>{sectionLabel(section)}</span></a>)}</div>}
      </nav>
      {sidebar && account && <div className="sidebar-account">{account}</div>}
      {!sidebar && moreOpen && hasMore && createPortal(
        <div className="tabs-tools-surface" data-dialog-surface>
          <button
            type="button"
            className="tabs-tools-backdrop"
            aria-label="Close menu"
            tabIndex={-1}
            onClick={() => closeTools()}
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
            <div className="tabs-sheet-grab" aria-hidden="true" onPointerDown={startDrag} onPointerMove={moveDrag} onPointerUp={event => finishDrag(event)} onPointerCancel={event => finishDrag(event, true)}><span /></div>
            <header>
              <div>
                <strong id="participant-tools-title">More</strong>
              </div>
              <button
                type="button"
                className="tabs-tools-close"
                aria-label="Close menu"
                onClick={() => closeTools()}
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
              {onAccount && <button type="button" className="tabs-account-row ui-row" onClick={() => { closeTools(false); onAccount() }}><span>Account and help</span><ArrowIcon /></button>}
              {tools.length > 0 && <details className="tabs-tools-group" open={tools.includes(activeSection) || undefined}>
                <summary>Tools</summary>
                {tools.map(section => <a key={section} href={sectionHref(section)} aria-label={sectionLabel(section)} aria-current={activeSection === section ? 'page' : undefined} className={activeSection === section ? 'active' : ''} onClick={event => chooseSection(event, section)}>
                  <span><strong>{sectionLabel(section)}</strong><small>{sectionDescriptions[section]}</small></span><ArrowIcon />
                </a>)}
              </details>}
            </div>
          </div>
        </div>,
        document.body,
      )}
    </div>
    </>
  )
}
