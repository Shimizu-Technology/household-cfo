import { SignInButton, SignUpButton, UserButton } from '@clerk/clerk-react'
import { useEffect, useMemo, useRef, useState, type FormEvent, type KeyboardEvent } from 'react'
import './App.css'
import { fetchAppData, sendMiaMessage } from './api'
import type { AppData, MiaMessage } from './api'
import { useAuthContext } from './contexts/authContextValue'

const currency = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  maximumFractionDigits: 0,
})

const sections = ['Home', 'Ask Mia', 'My Profile', 'Budget', 'Wealth', 'CFO Filter', 'Optionality']
const MIA_CHAT_STORAGE_PREFIX = 'household-cfo:mia-chat:v1'

const sourceDerivedCopy = [
  'Expense Stack',
  'Non-discretionary',
  'Sinking Fund — Expected',
  'Sinking Fund — Unexpected',
  'Upload spreadsheet',
  'Upload statement',
  'Upload pay stub',
  'Context loaded',
]

const statusCopy = {
  green: 'steady',
  yellow: 'watch',
  red: 'pause',
  blue: 'context',
  gold: 'build',
} as Record<string, string>

function App() {
  const auth = useAuthContext()
  const canLoadWorkspace = !auth.isClerkEnabled || Boolean(auth.currentUser)
  const [data, setData] = useState<AppData | null>(null)
  const [active, setActive] = useState(() => {
    const hashSection = decodeURIComponent(window.location.hash.replace('#', ''))
    return sections.includes(hashSection) ? hashSection : sections[0]
  })
  const [messages, setMessages] = useState<MiaMessage[]>([])
  const [question, setQuestion] = useState('')
  const [miaLoading, setMiaLoading] = useState(false)
  const [isChatExpanded, setIsChatExpanded] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const chatStorageKey = useMemo(() => {
    const owner = auth.currentUser?.id ? `user-${auth.currentUser.id}` : 'preview'
    return `${MIA_CHAT_STORAGE_PREFIX}:${owner}`
  }, [auth.currentUser?.id])
  const [messagesStorageKey, setMessagesStorageKey] = useState(chatStorageKey)
  const chatCardRef = useRef<HTMLElement | null>(null)
  const composerRef = useRef<HTMLTextAreaElement | null>(null)
  const currentMessages = messagesStorageKey === chatStorageKey ? messages : []

  useEffect(() => {
    if (!canLoadWorkspace) return

    let cancelled = false

    fetchAppData()
      .then((payload) => {
        if (cancelled) return
        const storedMessages = loadStoredMiaMessages(chatStorageKey)
        setMessagesStorageKey(chatStorageKey)
        setData(payload)
        setMessages(storedMessages)
      })
      .catch(() => {
        if (cancelled) return
        setError('Mia’s workspace is offline for a moment. Start the Rails API on port 3000 to load preview data.')
      })

    return () => {
      cancelled = true
    }
  }, [canLoadWorkspace, chatStorageKey])

  const surplus = useMemo(() => {
    if (!data) return 0
    return data.budget.monthly_income - data.budget.total_monthly_outflow
  }, [data])

  useEffect(() => {
    if (!data) return
    if (messagesStorageKey !== chatStorageKey) return

    saveStoredMiaMessages(chatStorageKey, messages)
  }, [chatStorageKey, data, messages, messagesStorageKey])

  useEffect(() => {
    document.body.classList.toggle('mia-chat-expanded', isChatExpanded)

    return () => document.body.classList.remove('mia-chat-expanded')
  }, [isChatExpanded])

  useEffect(() => {
    if (!isChatExpanded) return

    function handleEscape(event: globalThis.KeyboardEvent) {
      if (event.key === 'Escape') setIsChatExpanded(false)
    }

    window.addEventListener('keydown', handleEscape)
    return () => window.removeEventListener('keydown', handleEscape)
  }, [isChatExpanded])

  useEffect(() => {
    if (active !== 'Ask Mia') return

    const chatCard = chatCardRef.current
    if (!chatCard) return

    chatCard.scrollTo({ top: chatCard.scrollHeight, behavior: 'smooth' })
  }, [active, currentMessages.length, miaLoading])

  function switchSection(section: string) {
    setActive(section)
    if (section !== 'Ask Mia') setIsChatExpanded(false)
    window.history.replaceState(null, '', `#${encodeURIComponent(section)}`)
  }

  async function handleAskMia(prompt = question) {
    const cleanPrompt = prompt.trim()
    if (!cleanPrompt || miaLoading) return

    setMiaLoading(true)
    setQuestion('')
    const priorMessages = currentMessages
    const userMessage: MiaMessage = { role: 'user', author: 'You', content: cleanPrompt }
    setMessages((current) => [...current, userMessage])

    try {
      const assistantMessage = await sendMiaMessage(cleanPrompt, priorMessages)
      setMessages((current) => [...current, assistantMessage])
    } catch {
      setMessages((current) => [
        ...current,
        {
          role: 'assistant',
          author: 'Mia',
          content:
            'I can still coach the framework. Your next move is to protect fixed bills, keep the Expense Stack honest, then decide what creates real optionality.',
        },
      ])
    } finally {
      setMiaLoading(false)
      requestAnimationFrame(() => composerRef.current?.focus({ preventScroll: true }))
    }
  }

  function handleAskMiaSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    void handleAskMia()
  }

  function handleAskMiaKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key !== 'Enter' || event.shiftKey) return

    event.preventDefault()
    void handleAskMia()
  }

  if (auth.isClerkEnabled && (auth.isLoading || auth.isVerifyingApi)) {
    return <AuthStatePanel title="Verifying your Household CFO access" copy="Mia is checking your secure cohort invitation before opening the workspace." />
  }

  if (auth.isClerkEnabled && !auth.isSignedIn) {
    return <AuthLanding />
  }

  if (auth.isClerkEnabled && auth.authError) {
    return <AccessDenied message={auth.authError} onSignOut={auth.signOut} />
  }

  if (auth.isClerkEnabled && !auth.currentUser) {
    return <AuthStatePanel title="Preparing your workspace" copy="Your Clerk session is ready. Household CFO is waiting for the cohort invitation check to finish." />
  }

  if (!data) {
    return (
      <main className="app loading-state">
        <section className="hero-panel">
          <p className="eyebrow">Household CFO powered by VERA</p>
          <h1>Loading Mia’s first cohort workspace.</h1>
          <p>{error ?? 'Pulling first cohort preview data...'}</p>
        </section>
      </main>
    )
  }

  return (
    <main className="app">
      <header className="shell-header">
        <ul className="sr-only" aria-label="Source-derived design requirements">
          {sourceDerivedCopy.map((item) => <li key={item}>{item}</li>)}
        </ul>
        <div>
          <p className="eyebrow">First cohort preview</p>
          <h1>Mia, your household CFO.</h1>
          <p className="hero-copy">
            Turn budget stress into a simple operating rhythm: know the numbers, choose the next move,
            and protect the dream without living in a spreadsheet.
          </p>
        </div>
        <aside className="mia-status-card">
          <span className="spark" aria-hidden="true"><MiaMark /></span>
          <strong>Mia is ready</strong>
          <p>{data.profile.completeness}% profile complete · {data.dashboard.summary.readiness_label}</p>
          {auth.currentUser && (
            <div className="account-pill">
              <span>{auth.currentUser.full_name}</span>
              <small>{auth.currentUser.role}</small>
              <UserButton afterSignOutUrl="/" />
            </div>
          )}
          <button type="button" onClick={() => switchSection('Ask Mia')}>Ask Mia what this means</button>
        </aside>
      </header>

      <nav className="tabs" aria-label="Household CFO participant sections">
        {sections.map((section) => (
          <button
            key={section}
            type="button"
            className={active === section ? 'active' : ''}
            onClick={() => switchSection(section)}
          >
            {section}
          </button>
        ))}
      </nav>

      {active === 'Home' && (
        <section className="screen-grid home-screen">
          <ScreenHeading
            eyebrow="Home"
            title="Your money picture, without the spiral."
            copy="A calm snapshot first. Details are still there, but Mia leads with what needs attention today."
          />

          <div className="status-ribbon">
            <span>Readiness</span>
            <strong>{data.dashboard.summary.readiness_label}</strong>
          </div>

          <div className="metric-row">
            <Metric label="Monthly income" value={currency.format(data.dashboard.summary.monthly_income)} />
            <Metric label="Runway" value={`${data.dashboard.summary.runway_months} months`} />
            <Metric label="Safe to spend" value={currency.format(data.dashboard.summary.next_safe_to_spend_amount)} />
            <Metric label="Baseline surplus" value={currency.format(surplus)} />
          </div>

          <div className="two-column">
            <article className="panel coach-panel">
              <p className="eyebrow">Mia’s read</p>
              <h3>Plan, don’t gamble.</h3>
              <p>
                You have enough stability to move with intention, but not enough to treat this like a leap of faith.
                The next 90 days should protect runway and prove recurring income.
              </p>
              <button type="button" onClick={() => switchSection('Ask Mia')}>Ask Mia for my next move</button>
            </article>
            <div className="card-list">
              {data.dashboard.alerts.map((alert) => (
                <article className={`insight-card ${alert.tone}`} key={alert.title}>
                  <span>{statusCopy[alert.tone] ?? 'note'}</span>
                  <h3>{alert.title}</h3>
                  <p>{alert.body}</p>
                </article>
              ))}
            </div>
          </div>

          <article className="panel next-steps">
            <h3>This week’s household CFO rhythm</h3>
            <ol>
              {data.dashboard.next_steps.map((step) => <li key={step}>{step}</li>)}
            </ol>
          </article>
        </section>
      )}

      {active === 'Ask Mia' && (
        <section className="screen-grid mia-screen">
          <ScreenHeading
            eyebrow="Ask Mia"
            title="Ask Mia about the next move."
            copy="Mia uses your profile, Expense Stack, runway, debt, and Optionality context."
          />

          <div className="mia-layout">
            <article className="mia-context panel">
              <div className="mia-context-heading">
                <span className="spark" aria-hidden="true"><MiaMark /></span>
                <div>
                  <span>What Mia sees</span>
                  <h3>Context loaded</h3>
                </div>
              </div>
              <p>Profile, Expense Stack, runway, debt pressure, and Optionality scenario are ready for Mia to use.</p>
              <div className="upload-strip" aria-label="Demo-only upload affordances">
                <button type="button" disabled title="Uploads are a demo placeholder until privacy and OCR scope are approved.">
                  <AttachmentIcon />
                  Spreadsheet import demo-only
                </button>
                <button type="button" disabled title="Uploads are a demo placeholder until privacy and OCR scope are approved.">
                  <StatementIcon />
                  Statement import demo-only
                </button>
              </div>
            </article>

            <section className={`mia-chat-shell ${isChatExpanded ? 'is-expanded' : ''}`} aria-label="Ask Mia conversation">
              <div className="chat-shell-header">
                <span className="message-avatar" aria-hidden="true">M</span>
                <div className="chat-shell-copy">
                  <h3>Ask Mia</h3>
                  <p>Quick, plain-English coaching from your Household CFO context.</p>
                </div>
                <div className="chat-actions">
                  {currentMessages.length > 0 && (
                    <button type="button" className="chat-clear-button" onClick={() => setMessages([])}>
                      Clear
                    </button>
                  )}
                  <button
                    type="button"
                    className="chat-expand-button"
                    aria-label={isChatExpanded ? 'Collapse Ask Mia chat' : 'Expand Ask Mia chat'}
                    aria-pressed={isChatExpanded}
                    title={isChatExpanded ? 'Collapse Ask Mia chat' : 'Expand Ask Mia chat'}
                    onClick={() => setIsChatExpanded((expanded) => !expanded)}
                  >
                    {isChatExpanded ? <CollapseIcon /> : <ExpandIcon />}
                  </button>
                </div>
              </div>

              <div className="quick-prompts chat-prompts" aria-label="Suggested questions for Mia">
                {data.mia.quick_prompts.map((prompt) => (
                  <button type="button" key={prompt} onClick={() => void handleAskMia(prompt)} disabled={miaLoading}>
                    {prompt}
                  </button>
                ))}
              </div>

              <article className="chat-card" ref={chatCardRef} aria-live="polite" aria-busy={miaLoading}>
                {currentMessages.length === 0 && !miaLoading && (
                  <div className="empty-chat-state">
                    <span className="message-avatar" aria-hidden="true">M</span>
                    <h3>Mia is ready when you are.</h3>
                    <p>Choose a quick question or ask what you want to decide next. Mia will use the household context already loaded here.</p>
                  </div>
                )}
                {currentMessages.map((message, index) => (
                  <div className={`message-row ${message.role}`} key={`${message.author}-${index}`}>
                    {message.role === 'assistant' && <span className="message-avatar" aria-hidden="true">M</span>}
                    <div className={`message ${message.role}`}>
                      <strong>{message.author}</strong>
                      {messageParagraphs(message).map((paragraph, paragraphIndex) => (
                        <p key={`${message.author}-${index}-${paragraphIndex}`}>{paragraph}</p>
                      ))}
                    </div>
                  </div>
                ))}
                {miaLoading && (
                  <div className="message-row assistant typing-row">
                    <span className="message-avatar" aria-hidden="true">M</span>
                    <div className="message assistant">
                      <strong>Mia</strong>
                      <div className="typing-dots" aria-label="Mia is thinking">
                        <span />
                        <span />
                        <span />
                      </div>
                    </div>
                  </div>
                )}
              </article>

              <form className="ask-row" onSubmit={handleAskMiaSubmit}>
                <button
                  className="composer-attach"
                  type="button"
                  disabled
                  title="Uploads are demo-only until privacy and OCR scope are approved."
                  aria-label="Attach financial document"
                >
                  <AttachmentIcon />
                </button>
                <textarea
                  value={question}
                  onChange={(event) => setQuestion(event.target.value)}
                  onKeyDown={handleAskMiaKeyDown}
                  aria-label="Ask Mia"
                  placeholder="Ask Mia..."
                  rows={1}
                  ref={composerRef}
                />
                <button
                  className="send-button"
                  type="submit"
                  disabled={miaLoading || !question.trim()}
                  aria-label={miaLoading ? 'Mia is thinking' : 'Send message to Mia'}
                >
                  <span>{miaLoading ? 'Thinking' : 'Send'}</span>
                  <SendIcon />
                </button>
              </form>
            </section>
          </div>
          <p className="disclaimer">{data.mia.disclaimer}</p>
        </section>
      )}

      {active === 'My Profile' && (
        <section className="screen-grid profile-screen">
          <ScreenHeading
            eyebrow="My Profile"
            title={data.profile.household.name}
            copy={data.profile.household.primary_goal}
          />

          <article className="panel completeness-card">
            <div>
              <span>Profile completeness</span>
              <strong>{data.profile.completeness}%</strong>
            </div>
            <div className="progress-track"><span style={{ width: `${data.profile.completeness}%` }} /></div>
            <p>Manual entry works today. Uploads are shown as the next natural path so users do not feel trapped in Excel.</p>
          </article>

          <div className="profile-section-grid">
            {data.profile.sections.map((section) => (
              <article className="panel profile-section" key={section.label}>
                <div className="row-between">
                  <h3>{section.label}</h3>
                  <button type="button">Edit</button>
                </div>
                <p>{section.summary}</p>
                {section.items.map((item) => (
                  <div className="money-row" key={item.label}>
                    <span>{item.label}</span>
                    <strong className={item.amount < 0 ? 'negative' : ''}>{currency.format(item.amount)}</strong>
                  </div>
                ))}
              </article>
            ))}
          </div>

          <div className="upload-grid">
            {data.profile.uploads.map((upload) => (
              <article className="upload-card" key={upload.kind}>
                <span>Upload</span>
                <h3>{upload.label}</h3>
                <p>{upload.status}</p>
                <small>{upload.accepts}</small>
              </article>
            ))}
          </div>
        </section>
      )}

      {active === 'Budget' && (
        <section className="screen-grid budget-screen">
          <ScreenHeading
            eyebrow="Budget"
            title="The Expense Stack keeps life from surprising you every month."
            copy={data.budget.intro}
          />

          <div className="metric-row">
            <Metric label="Monthly income" value={currency.format(data.budget.monthly_income)} />
            <Metric label="Monthly outflow" value={currency.format(data.budget.total_monthly_outflow)} />
            <Metric label="Baseline surplus" value={currency.format(data.budget.baseline_surplus)} />
          </div>

          <div className="stack-grid">
            {data.budget.stacks.map((stack) => (
              <article className={`stack-card ${stack.color}`} key={stack.label}>
                <span>{data.budget.framework}</span>
                <h3>{stack.label}</h3>
                <strong>{currency.format(stack.amount)}</strong>
                <p>{stack.description}</p>
                <small>{stack.examples.join(' · ')}</small>
              </article>
            ))}
          </div>

          <article className="panel coach-panel">
            <h3>Custom categories matter</h3>
            <p>{data.budget.custom_categories_note}</p>
          </article>
        </section>
      )}

      {active === 'Wealth' && (
        <section className="screen-grid wealth-screen">
          <ScreenHeading
            eyebrow="Wealth"
            title="Wealth means more options and less panic."
            copy={data.wealth.guidance}
          />

          <div className="metric-row">
            <Metric label="Net worth" value={currency.format(data.wealth.summary.net_worth)} />
            <Metric label="Liquid net worth" value={currency.format(data.wealth.summary.liquid_net_worth)} />
            <Metric label="Retirement projection" value={currency.format(data.wealth.summary.retirement_projection)} />
            <Metric label="Monthly wealth building" value={currency.format(data.wealth.summary.monthly_wealth_building)} />
          </div>

          <div className="milestone-list">
            {data.wealth.milestones.map((milestone) => (
              <article className={`milestone-card ${milestone.status}`} key={milestone.label}>
                <h3>{milestone.label}</h3>
                <div className="progress-track">
                  <span style={{ width: `${Math.min((milestone.current / milestone.target) * 100, 100)}%` }} />
                </div>
                <p>{milestone.current.toLocaleString()} / {milestone.target.toLocaleString()} {milestone.unit}</p>
              </article>
            ))}
          </div>
        </section>
      )}

      {active === 'CFO Filter' && (
        <section className="screen-grid cfo-screen">
          <ScreenHeading
            eyebrow="CFO Filter"
            title="Should this money move happen now?"
            copy={data.cfoFilter.prompt}
          />

          <div className="decision-list">
            {data.cfoFilter.decisions.map((decision) => (
              <article className={`decision-card ${decision.recommendation.toLowerCase()}`} key={decision.item}>
                <div>
                  <span>{decision.recommendation}</span>
                  <h3>{decision.item}</h3>
                </div>
                <strong>{currency.format(decision.amount)}</strong>
                <p>{decision.reason}</p>
              </article>
            ))}
          </div>

          <article className="panel priority-card">
            <h3>Priority stack</h3>
            <ol>
              {data.cfoFilter.priority_stack.map((item) => <li key={item}>{item}</li>)}
            </ol>
          </article>
        </section>
      )}

      {active === 'Optionality' && (
        <section className="screen-grid optionality-screen">
          <ScreenHeading
            eyebrow="Optionality"
            title={data.optionality.question}
            copy={`Current runway: ${data.optionality.current_runway_months} months. Target runway: ${data.optionality.target_runway_months} months.`}
          />

          <div className="lever-row">
            {data.optionality.levers.map((lever) => (
              <Metric key={lever.label} label={lever.label} value={currency.format(lever.amount)} />
            ))}
          </div>

          <div className="choice-grid">
            {data.optionality.choices.map((choice) => (
              <article className="choice-card" key={choice.label}>
                <span>{choice.readiness_score}/100 readiness</span>
                <h3>{choice.label}</h3>
                <p>{choice.upside}</p>
                <small>{choice.tradeoff}</small>
              </article>
            ))}
          </div>
        </section>
      )}
    </main>
  )
}

function AuthLanding() {
  return (
    <main className="app loading-state auth-state">
      <section className="hero-panel auth-panel">
        <span className="spark" aria-hidden="true"><ShieldIcon /></span>
        <p className="eyebrow">Secure cohort access</p>
        <h1>Sign in to open Mia’s Household CFO workspace.</h1>
        <p>
          Household CFO now uses Clerk authentication backed by the Rails/PostgreSQL user table.
          Sign in with the email invited to the first cohort.
        </p>
        <div className="auth-actions">
          <SignInButton mode="modal">
            <button type="button">Sign in</button>
          </SignInButton>
          <SignUpButton mode="modal">
            <button type="button" className="secondary">Create invited account</button>
          </SignUpButton>
        </div>
      </section>
    </main>
  )
}

function AccessDenied({ message, onSignOut }: { message: string; onSignOut?: () => Promise<void> }) {
  return (
    <main className="app loading-state auth-state">
      <section className="hero-panel auth-panel">
        <span className="spark" aria-hidden="true"><ShieldIcon /></span>
        <p className="eyebrow">Access needs an invitation</p>
        <h1>Your Clerk session is active, but this app has not linked your cohort seat.</h1>
        <p>{message}</p>
        <div className="auth-actions">
          <button type="button" onClick={() => void onSignOut?.()}>Sign out</button>
          <div className="user-button-wrap"><UserButton afterSignOutUrl="/" /></div>
        </div>
      </section>
    </main>
  )
}

function AuthStatePanel({ title, copy }: { title: string; copy: string }) {
  return (
    <main className="app loading-state auth-state">
      <section className="hero-panel auth-panel">
        <span className="spark" aria-hidden="true"><MiaMark /></span>
        <p className="eyebrow">Household CFO powered by VERA</p>
        <h1>{title}</h1>
        <p>{copy}</p>
      </section>
    </main>
  )
}

function ScreenHeading({ eyebrow, title, copy }: { eyebrow: string; title: string; copy: string }) {
  return (
    <div className="screen-heading">
      <p className="eyebrow">{eyebrow}</p>
      <h2>{title}</h2>
      <p>{copy}</p>
    </div>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <article className="metric-card">
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  )
}

function loadStoredMiaMessages(storageKey: string) {
  try {
    const stored = window.localStorage.getItem(storageKey)
    if (!stored) return []

    const parsed = JSON.parse(stored) as MiaMessage[]
    if (!Array.isArray(parsed)) return []

    return parsed.filter((message) => (
      (message.role === 'assistant' || message.role === 'user')
      && typeof message.author === 'string'
      && typeof message.content === 'string'
      && message.content.trim().length > 0
    )).slice(-24)
  } catch {
    return []
  }
}

function saveStoredMiaMessages(storageKey: string, messages: MiaMessage[]) {
  try {
    if (messages.length === 0) {
      window.localStorage.removeItem(storageKey)
      return
    }

    window.localStorage.setItem(storageKey, JSON.stringify(messages.slice(-24)))
  } catch {
    // Ignore private browsing/storage quota issues. Chat still works in memory.
  }
}

function messageParagraphs(message: MiaMessage) {
  const speakerlessContent = message.role === 'assistant'
    ? message.content.replace(/^Mia:\s*/i, '')
    : message.content

  return speakerlessContent
    .replace(/\*\*(.*?)\*\*/g, '$1')
    .replace(/^\s*[-*]\s+/gm, '')
    .split(/\n{2,}/)
    .map((paragraph) => paragraph.trim())
    .filter(Boolean)
}

function MiaMark() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Mia mark">
      <path d="M12 2.75 14.42 9.2l6.83 2.8-6.83 2.8L12 21.25 9.58 14.8 2.75 12l6.83-2.8L12 2.75Z" />
    </svg>
  )
}

function ShieldIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Secure access">
      <path d="M12 2.7 19 5.4v5.25c0 4.45-2.8 8.5-7 10.05-4.2-1.55-7-5.6-7-10.05V5.4l7-2.7Z" />
      <path d="m8.9 12.05 2 2 4.2-4.45" className="icon-stroke" />
    </svg>
  )
}

function SendIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M3.75 20.25 21 12 3.75 3.75v6.45L15.8 12 3.75 13.8v6.45Z" />
    </svg>
  )
}

function ExpandIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8 4H4v4" className="icon-stroke" />
      <path d="M4 4l6 6" className="icon-stroke" />
      <path d="M16 20h4v-4" className="icon-stroke" />
      <path d="m20 20-6-6" className="icon-stroke" />
    </svg>
  )
}

function CollapseIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M10 4v6H4" className="icon-stroke" />
      <path d="M4 10 10 4" className="icon-stroke" />
      <path d="M14 20v-6h6" className="icon-stroke" />
      <path d="m20 14-6 6" className="icon-stroke" />
    </svg>
  )
}

function AttachmentIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8 7.5h8M8 11.5h8M8 15.5h5" className="icon-stroke" />
      <path d="M6.5 3.5h8.25L18.5 7.25V20.5h-12v-17Z" className="icon-stroke" />
      <path d="M14.5 3.5v4h4" className="icon-stroke" />
    </svg>
  )
}

function StatementIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M5 7.25A2.25 2.25 0 0 1 7.25 5h9.5A2.25 2.25 0 0 1 19 7.25v9.5A2.25 2.25 0 0 1 16.75 19h-9.5A2.25 2.25 0 0 1 5 16.75v-9.5Z" className="icon-stroke" />
      <path d="M8 9.25h8M8 12h8M8 14.75h4.75" className="icon-stroke" />
    </svg>
  )
}

export default App
