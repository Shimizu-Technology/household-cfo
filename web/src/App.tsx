import { SignInButton, SignUpButton, UserButton } from '@clerk/clerk-react'
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type KeyboardEvent } from 'react'
import './App.css'
import {
  clearMiaMessages,
  createAdminCohort,
  createAdminUser,
  fetchAdminCohorts,
  fetchAdminUsers,
  fetchAppData,
  resendAdminUserInvitation,
  saveWorkspaceSetup,
  sendMiaMessage,
  updateAdminCohort,
  updateAdminUser,
} from './api'
import type {
  AdminCohort,
  AdminCohortInput,
  AdminCohortStatus,
  AdminUser,
  AdminUserInput,
  AdminUserMutationResponse,
  AppData,
  CurrentUser,
  InvitationStatus,
  MiaMessage,
  UserRole,
  WorkspaceSetupValues,
} from './api'
import { useAuthContext } from './contexts/authContextValue'

const currency = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  maximumFractionDigits: 0,
})

const sections = ['Home', 'Ask Mia', 'My Profile', 'Budget', 'Wealth', 'CFO Filter', 'Optionality']
const ADMIN_SECTION = 'Admin'
const allSections = [...sections, ADMIN_SECTION]
const MIA_CHAT_STORAGE_PREFIX = 'household-cfo:mia-chat:v1'
const MIA_MESSAGE_MAX_LENGTH = 2_000

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
  const [setupDraft, setSetupDraft] = useState<WorkspaceSetupValues | null>(null)
  const [setupSaving, setSetupSaving] = useState(false)
  const [setupError, setSetupError] = useState<string | null>(null)
  const [active, setActive] = useState(() => {
    const hashSection = decodeURIComponent(window.location.hash.replace('#', ''))
    return allSections.includes(hashSection) ? hashSection : sections[0]
  })
  const [messages, setMessages] = useState<MiaMessage[]>([])
  const [question, setQuestion] = useState('')
  const [miaLoading, setMiaLoading] = useState(false)
  const [miaClearing, setMiaClearing] = useState(false)
  const [miaError, setMiaError] = useState<string | null>(null)
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
  const shouldUseRealWorkspace = auth.isClerkEnabled
  const isRealWorkspace = data?.workspace?.mode === 'real'
  const visibleSections = useMemo(() => (auth.currentUser?.is_admin ? [...sections, ADMIN_SECTION] : sections), [auth.currentUser?.is_admin])
  const activeSection = active === ADMIN_SECTION && auth.currentUser && !auth.currentUser.is_admin ? sections[0] : active

  useEffect(() => {
    if (!canLoadWorkspace) return

    let cancelled = false

    fetchAppData(shouldUseRealWorkspace)
      .then((payload) => {
        if (cancelled) return
        const realWorkspace = payload.workspace?.mode === 'real'
        const restoredMessages = realWorkspace ? payload.mia.messages : loadStoredMiaMessages(chatStorageKey)
        setMessagesStorageKey(chatStorageKey)
        setData(payload)
        setSetupDraft(payload.workspace?.setup_values ?? null)
        setMessages(restoredMessages)
      })
      .catch(() => {
        if (cancelled) return
        setError('Mia’s workspace is offline for a moment. Start the Rails API on port 3000 to load preview data.')
      })

    return () => {
      cancelled = true
    }
  }, [canLoadWorkspace, chatStorageKey, shouldUseRealWorkspace])

  const surplus = useMemo(() => {
    if (!data) return 0
    return data.budget.monthly_income - data.budget.total_monthly_outflow
  }, [data])

  useEffect(() => {
    if (!data || isRealWorkspace) return
    if (messagesStorageKey !== chatStorageKey) return

    saveStoredMiaMessages(chatStorageKey, messages)
  }, [chatStorageKey, data, isRealWorkspace, messages, messagesStorageKey])

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
    if (activeSection !== 'Ask Mia') return

    const chatCard = chatCardRef.current
    if (!chatCard) return

    chatCard.scrollTo({ top: chatCard.scrollHeight, behavior: 'smooth' })
  }, [activeSection, currentMessages.length, miaLoading])

  function switchSection(section: string) {
    setActive(section)
    if (section !== 'Ask Mia') setIsChatExpanded(false)
    window.history.replaceState(null, '', `#${encodeURIComponent(section)}`)
  }

  async function handleAskMia(prompt = question) {
    const cleanPrompt = prompt.trim()
    if (!cleanPrompt || miaLoading) return
    if (cleanPrompt.length > MIA_MESSAGE_MAX_LENGTH) {
      setMiaError(`Mia messages must stay under ${MIA_MESSAGE_MAX_LENGTH.toLocaleString()} characters.`)
      return
    }

    setMiaLoading(true)
    setMiaError(null)
    setQuestion('')
    const priorMessages = currentMessages
    const userMessage: MiaMessage = { role: 'user', author: 'You', content: cleanPrompt }
    setMessages((current) => [...current, userMessage])

    try {
      const assistantMessage = await sendMiaMessage(cleanPrompt, priorMessages, isRealWorkspace)
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

  async function handleClearMessages() {
    if (miaClearing) return

    setMiaClearing(true)
    setMiaError(null)
    try {
      if (isRealWorkspace) await clearMiaMessages(true)
      setMessages([])
    } catch (caught) {
      setMiaError(caught instanceof Error ? caught.message : 'Mia chat could not be cleared. Please try again.')
    } finally {
      setMiaClearing(false)
    }
  }

  async function handleSetupSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!setupDraft || setupSaving) return

    setSetupSaving(true)
    setSetupError(null)
    try {
      const payload = await saveWorkspaceSetup(setupDraft)
      setData(payload)
      setSetupDraft(payload.workspace?.setup_values ?? setupDraft)
      setMessages(payload.mia.messages)
      setMessagesStorageKey(chatStorageKey)
    } catch (caught) {
      setSetupError(caught instanceof Error ? caught.message : 'Your numbers could not be saved. Please try again.')
    } finally {
      setSetupSaving(false)
    }
  }

  function updateSetupDraft(key: keyof WorkspaceSetupValues, value: string) {
    setSetupError(null)
    setSetupDraft((current) => {
      if (!current) return current
      if (key === 'household_name' || key === 'primary_goal') return { ...current, [key]: value }

      return { ...current, [key]: Number(value) || 0 }
    })
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
        {visibleSections.map((section) => (
          <button
            key={section}
            type="button"
            className={activeSection === section ? 'active' : ''}
            onClick={() => switchSection(section)}
          >
            {section}
          </button>
        ))}
      </nav>

      {activeSection === 'Home' && (
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

      {activeSection === 'Ask Mia' && (
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
                    <button type="button" className="chat-clear-button" onClick={() => void handleClearMessages()} disabled={miaClearing}>
                      {miaClearing ? 'Clearing' : 'Clear'}
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

              {miaError && <p className="chat-error" role="alert">{miaError}</p>}

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
                  onChange={(event) => {
                    setMiaError(null)
                    setQuestion(event.target.value)
                  }}
                  onKeyDown={handleAskMiaKeyDown}
                  aria-label="Ask Mia"
                  placeholder="Ask Mia..."
                  rows={1}
                  maxLength={MIA_MESSAGE_MAX_LENGTH}
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

      {activeSection === 'My Profile' && (
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
            <p>{isRealWorkspace ? 'These are your saved household numbers. Update them anytime and Mia will use the new context.' : 'Manual entry works in the real workspace. Uploads are shown as the next natural path so users do not feel trapped in Excel.'}</p>
          </article>

          {isRealWorkspace && setupDraft && (
            <WorkspaceSetupForm
              values={setupDraft}
              saving={setupSaving}
              error={setupError}
              onChange={updateSetupDraft}
              onSubmit={handleSetupSubmit}
            />
          )}

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

      {activeSection === 'Budget' && (
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

      {activeSection === 'Wealth' && (
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

      {activeSection === 'CFO Filter' && (
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

      {activeSection === 'Optionality' && (
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

      {activeSection === ADMIN_SECTION && auth.currentUser?.is_admin && (
        <AdminConsole currentUser={auth.currentUser} />
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

type AdminUserDraft = {
  role: UserRole
  invitation_status: InvitationStatus
  cohort_ids: string[]
}

const cohortStatuses: AdminCohortStatus[] = ['draft', 'enrolling', 'active', 'completed', 'archived']
const userRoles: UserRole[] = ['participant', 'coach', 'admin']
const invitationStatuses: InvitationStatus[] = ['pending', 'accepted', 'revoked']

function AdminConsole({ currentUser }: { currentUser: CurrentUser }) {
  const [cohorts, setCohorts] = useState<AdminCohort[]>([])
  const [users, setUsers] = useState<AdminUser[]>([])
  const [selectedCohortId, setSelectedCohortId] = useState<number | null>(null)
  const [createDraft, setCreateDraft] = useState<AdminCohortInput>({
    name: '',
    status: 'enrolling',
    starts_on: '',
    ends_on: '',
    notes: '',
  })
  const [editDraft, setEditDraft] = useState<AdminCohortInput | null>(null)
  const [inviteDraft, setInviteDraft] = useState<AdminUserInput>({
    email: '',
    first_name: '',
    last_name: '',
    role: 'participant',
    cohort_id: '',
  })
  const [userDrafts, setUserDrafts] = useState<Record<number, AdminUserDraft>>({})
  const [loading, setLoading] = useState(true)
  const [cohortSaving, setCohortSaving] = useState(false)
  const [inviteSaving, setInviteSaving] = useState(false)
  const [savingUserId, setSavingUserId] = useState<number | null>(null)
  const [resendingUserId, setResendingUserId] = useState<number | null>(null)
  const [roleMatrixOpen, setRoleMatrixOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const selectedCohortIdRef = useRef<number | null>(null)

  const selectedCohort = useMemo(
    () => cohorts.find((cohort) => cohort.id === selectedCohortId) ?? null,
    [cohorts, selectedCohortId],
  )

  const visibleUsers = useMemo(() => {
    if (!selectedCohortId) return users

    return users.filter((user) => user.cohorts.some((membership) => membership.cohort.id === selectedCohortId))
  }, [selectedCohortId, users])

  const adminStats = useMemo(() => ({
    cohorts: cohorts.length,
    users: users.length,
    pending: users.filter((user) => user.invitation_status === 'pending').length,
    setupComplete: users.filter((user) => user.workspace.setup_complete).length,
  }), [cohorts.length, users])

  const loadAdminData = useCallback(async (preferredCohortId?: number | null) => {
    setLoading(true)
    setError(null)
    try {
      const [nextCohorts, nextUsers] = await Promise.all([fetchAdminCohorts(), fetchAdminUsers()])
      const requestedCohortId = preferredCohortId === undefined ? selectedCohortIdRef.current : preferredCohortId
      const nextSelectedId = requestedCohortId && nextCohorts.some((cohort) => cohort.id === requestedCohortId)
        ? requestedCohortId
        : nextCohorts[0]?.id ?? null
      const nextSelectedCohort = nextCohorts.find((cohort) => cohort.id === nextSelectedId) ?? null

      selectedCohortIdRef.current = nextSelectedId
      setCohorts(nextCohorts)
      setUsers(nextUsers)
      setUserDrafts(adminDraftsForUsers(nextUsers))
      setSelectedCohortId(nextSelectedId)
      setEditDraft(nextSelectedCohort ? cohortDraftFor(nextSelectedCohort) : null)
      setInviteDraft((current) => ({
        ...current,
        cohort_id: current.cohort_id || (nextSelectedId ? String(nextSelectedId) : ''),
      }))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Admin data could not be loaded.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    let cancelled = false

    queueMicrotask(() => {
      if (!cancelled) void loadAdminData()
    })

    return () => {
      cancelled = true
    }
  }, [loadAdminData])

  function selectCohort(cohortId: number | null) {
    selectedCohortIdRef.current = cohortId
    setSelectedCohortId(cohortId)
    setEditDraft(cohortId ? cohortDraftFor(cohorts.find((cohort) => cohort.id === cohortId) ?? null) : null)
    setNotice(null)
    setInviteDraft((current) => ({ ...current, cohort_id: cohortId ? String(cohortId) : '' }))
  }

  async function handleCreateCohort(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!createDraft.name.trim()) {
      setError('Cohort name is required.')
      return
    }

    setCohortSaving(true)
    setError(null)
    setNotice(null)
    try {
      const cohort = await createAdminCohort(cleanCohortDraft(createDraft))
      setNotice(`${cohort.name} is ready for invites.`)
      setCreateDraft({ name: '', status: 'enrolling', starts_on: '', ends_on: '', notes: '' })
      await loadAdminData(cohort.id)
      setInviteDraft((current) => ({ ...current, cohort_id: String(cohort.id) }))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Cohort could not be created.')
    } finally {
      setCohortSaving(false)
    }
  }

  async function handleUpdateCohort(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!selectedCohort || !editDraft) return

    setCohortSaving(true)
    setError(null)
    setNotice(null)
    try {
      const cohort = await updateAdminCohort(selectedCohort.id, cleanCohortDraft(editDraft))
      setNotice(`${cohort.name} settings saved.`)
      await loadAdminData(cohort.id)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Cohort could not be saved.')
    } finally {
      setCohortSaving(false)
    }
  }

  async function handleInviteUser(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const inviteRole = inviteDraft.role ?? 'participant'
    const cohortId = String(inviteDraft.cohort_id ?? '')

    if (!inviteDraft.email?.trim()) {
      setError('Email is required before creating an invite.')
      return
    }
    if (roleRequiresCohort(inviteRole) && !cohortId) {
      setError(`${titleize(inviteRole)} users must be assigned to at least one cohort.`)
      return
    }

    setInviteSaving(true)
    setError(null)
    setNotice(null)
    try {
      const response = await createAdminUser({
        email: inviteDraft.email.trim(),
        first_name: inviteDraft.first_name?.trim(),
        last_name: inviteDraft.last_name?.trim(),
        role: inviteRole,
        cohort_id: cohortId || undefined,
      })
      setNotice(`${response.user.email} is invited${cohortId ? ' and assigned to the selected cohort' : ' as an admin'}. ${inviteDeliveryNotice(response)}`)
      setInviteDraft({ email: '', first_name: '', last_name: '', role: 'participant', cohort_id: selectedCohortId ? String(selectedCohortId) : '' })
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Invite could not be created.')
    } finally {
      setInviteSaving(false)
    }
  }

  async function handleSaveUser(user: AdminUser) {
    const draft = userDrafts[user.id]
    if (!draft || savingUserId) return
    if (roleRequiresCohort(draft.role) && draft.cohort_ids.length === 0) {
      setError(`${titleize(draft.role)} users must be assigned to at least one cohort before saving.`)
      return
    }

    setSavingUserId(user.id)
    setError(null)
    setNotice(null)
    try {
      const updatedUser = await updateAdminUser(user.id, {
        role: draft.role,
        invitation_status: draft.invitation_status,
        cohort_ids: draft.cohort_ids.map(Number),
      })
      setNotice(`${updatedUser.email} was updated.`)
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'User could not be saved.')
    } finally {
      setSavingUserId(null)
    }
  }

  async function handleResendInvitation(user: AdminUser) {
    if (resendingUserId) return

    setResendingUserId(user.id)
    setError(null)
    setNotice(null)
    try {
      const response = await resendAdminUserInvitation(user.id)
      setNotice(`${response.user.email} invitation refreshed. ${inviteDeliveryNotice(response)}`)
      await loadAdminData()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Invitation email could not be resent.')
    } finally {
      setResendingUserId(null)
    }
  }

  function updateUserDraft(userId: number, key: 'role' | 'invitation_status', value: string) {
    setUserDrafts((current) => {
      const nextDraft = { ...current[userId] }
      if (key === 'role') nextDraft.role = value as UserRole
      if (key === 'invitation_status') nextDraft.invitation_status = value as InvitationStatus

      return {
        ...current,
        [userId]: nextDraft,
      }
    })
  }

  function toggleUserCohort(userId: number, cohortId: number) {
    const cohortIdValue = String(cohortId)
    setUserDrafts((current) => {
      const nextDraft = { ...current[userId] }
      const currentCohortIds = nextDraft.cohort_ids ?? []
      nextDraft.cohort_ids = currentCohortIds.includes(cohortIdValue)
        ? currentCohortIds.filter((id) => id !== cohortIdValue)
        : [...currentCohortIds, cohortIdValue]

      return {
        ...current,
        [userId]: nextDraft,
      }
    })
  }

  const inviteRole = inviteDraft.role ?? 'participant'
  const inviteRequiresCohort = roleRequiresCohort(inviteRole)

  return (
    <section className="screen-grid admin-screen">
      <ScreenHeading
        eyebrow="Admin"
        title="Cohorts and invitations, without terminal commands."
        copy="Create the pilot cohorts, invite participants, and keep each user tied to the right Household CFO group before they sign in with Clerk."
      />

      {error && <p className="admin-alert error" role="alert">{error}</p>}
      {notice && <p className="admin-alert success">{notice}</p>}

      <div className="admin-stat-row">
        <AdminStat label="Cohorts" value={adminStats.cohorts.toString()} />
        <AdminStat label="Invited users" value={adminStats.users.toString()} />
        <AdminStat label="Pending" value={adminStats.pending.toString()} />
        <AdminStat label="Setup complete" value={adminStats.setupComplete.toString()} />
      </div>

      <RoleMatrix open={roleMatrixOpen} onToggle={setRoleMatrixOpen} />

      <div className="admin-layout">
        <article className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><CohortIcon /></span>
            <div>
              <p className="eyebrow">Cohorts</p>
              <h3>Create the next group</h3>
            </div>
          </div>

          <form className="admin-form" onSubmit={handleCreateCohort}>
            <label className="admin-field wide">
              <span>Cohort name</span>
              <input value={createDraft.name} onChange={(event) => setCreateDraft((current) => ({ ...current, name: event.target.value }))} placeholder="Tuesday pilot cohort" />
            </label>
            <label className="admin-field">
              <span>Status</span>
              <select value={createDraft.status} onChange={(event) => setCreateDraft((current) => ({ ...current, status: event.target.value as AdminCohortStatus }))}>
                {cohortStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
              </select>
            </label>
            <label className="admin-field">
              <span>Starts</span>
              <input type="date" value={createDraft.starts_on ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, starts_on: event.target.value }))} />
            </label>
            <label className="admin-field">
              <span>Ends</span>
              <input type="date" value={createDraft.ends_on ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, ends_on: event.target.value }))} />
            </label>
            <label className="admin-field wide">
              <span>Notes</span>
              <textarea value={createDraft.notes ?? ''} onChange={(event) => setCreateDraft((current) => ({ ...current, notes: event.target.value }))} placeholder="Pilot focus, meeting cadence, or setup notes" rows={3} />
            </label>
            <button type="submit" disabled={cohortSaving}>{cohortSaving ? 'Saving' : 'Create cohort'}</button>
          </form>
        </article>

        <article className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><UsersIcon /></span>
            <div>
              <p className="eyebrow">Cohort list</p>
              <h3>Select a group to manage</h3>
            </div>
          </div>

          {loading && cohorts.length === 0 ? (
            <p className="admin-muted">Loading cohorts and invitations...</p>
          ) : (
            <div className="cohort-list">
              <button type="button" className={`cohort-list-card ${selectedCohortId === null ? 'active' : ''}`} onClick={() => selectCohort(null)}>
                <strong>All users</strong>
                <span>Full invitation list</span>
              </button>
              {cohorts.map((cohort) => (
                <button type="button" className={`cohort-list-card ${selectedCohortId === cohort.id ? 'active' : ''}`} key={cohort.id} onClick={() => selectCohort(cohort.id)}>
                  <strong>{cohort.name}</strong>
                  <span>{titleize(cohort.status)} · {cohort.member_count} users · {cohort.setup_complete_count} ready</span>
                </button>
              ))}
            </div>
          )}
        </article>
      </div>

      <div className="admin-layout">
        <article className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><CohortIcon /></span>
            <div>
              <p className="eyebrow">Selected cohort</p>
              <h3>{selectedCohort ? selectedCohort.name : 'No cohort selected'}</h3>
            </div>
          </div>

          {selectedCohort && editDraft ? (
            <form className="admin-form" onSubmit={handleUpdateCohort}>
              <div className="admin-cohort-summary">
                <AdminBadge value={titleize(selectedCohort.status)} tone={selectedCohort.status === 'active' ? 'green' : selectedCohort.status === 'archived' ? 'red' : 'gold'} />
                <span>{selectedCohort.participant_count} participants</span>
                <span>{selectedCohort.staff_count} staff</span>
                <span>{cohortDateRange(selectedCohort)}</span>
              </div>
              <label className="admin-field wide">
                <span>Name</span>
                <input value={editDraft.name} onChange={(event) => setEditDraft((current) => current ? { ...current, name: event.target.value } : current)} />
              </label>
              <label className="admin-field">
                <span>Status</span>
                <select value={editDraft.status} onChange={(event) => setEditDraft((current) => current ? { ...current, status: event.target.value as AdminCohortStatus } : current)}>
                  {cohortStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
                </select>
              </label>
              <label className="admin-field">
                <span>Starts</span>
                <input type="date" value={editDraft.starts_on ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, starts_on: event.target.value } : current)} />
              </label>
              <label className="admin-field">
                <span>Ends</span>
                <input type="date" value={editDraft.ends_on ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, ends_on: event.target.value } : current)} />
              </label>
              <label className="admin-field wide">
                <span>Notes</span>
                <textarea value={editDraft.notes ?? ''} onChange={(event) => setEditDraft((current) => current ? { ...current, notes: event.target.value } : current)} rows={3} />
              </label>
              <button type="submit" disabled={cohortSaving}>{cohortSaving ? 'Saving' : 'Save cohort'}</button>
            </form>
          ) : (
            <p className="admin-muted">Create a cohort, then select it here to update dates, status, and notes.</p>
          )}
        </article>

        <article className="panel admin-card">
          <div className="admin-card-heading">
            <span className="spark" aria-hidden="true"><ShieldIcon /></span>
            <div>
              <p className="eyebrow">Invite user</p>
              <h3>Add admin, coach, or participant</h3>
            </div>
          </div>

          <form className="admin-form" onSubmit={handleInviteUser}>
            <label className="admin-field wide">
              <span>Email</span>
              <input type="email" value={inviteDraft.email ?? ''} onChange={(event) => setInviteDraft((current) => ({ ...current, email: event.target.value }))} placeholder="name@example.com" />
            </label>
            <label className="admin-field">
              <span>First name</span>
              <input value={inviteDraft.first_name ?? ''} onChange={(event) => setInviteDraft((current) => ({ ...current, first_name: event.target.value }))} />
            </label>
            <label className="admin-field">
              <span>Last name</span>
              <input value={inviteDraft.last_name ?? ''} onChange={(event) => setInviteDraft((current) => ({ ...current, last_name: event.target.value }))} />
            </label>
            <label className="admin-field">
              <span>Role</span>
              <select value={inviteRole} onChange={(event) => setInviteDraft((current) => ({ ...current, role: event.target.value as UserRole }))}>
                {userRoles.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
              </select>
            </label>
            <label className="admin-field">
              <span>Cohort {inviteRequiresCohort ? '(required)' : '(optional)'}</span>
              <select required={inviteRequiresCohort} value={String(inviteDraft.cohort_id ?? '')} onChange={(event) => setInviteDraft((current) => ({ ...current, cohort_id: event.target.value }))}>
                <option value="">{inviteRequiresCohort ? 'Select a cohort' : 'No cohort for admin'}</option>
                {cohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name}</option>)}
              </select>
            </label>
            <p className="admin-field-note wide">Admins can manage across cohorts without assignment. Coaches and participants must belong to at least one cohort.</p>
            <button type="submit" disabled={inviteSaving}>{inviteSaving ? 'Creating invite' : 'Create invite'}</button>
          </form>
        </article>
      </div>

      <article className="panel admin-card admin-users-panel">
        <div className="admin-card-heading row-between">
          <div>
            <p className="eyebrow">Users</p>
            <h3>{selectedCohort ? `${selectedCohort.name} members` : 'All invited users'}</h3>
          </div>
          <button type="button" className="admin-refresh" onClick={() => void loadAdminData()} disabled={loading}>{loading ? 'Refreshing' : 'Refresh'}</button>
        </div>

        {visibleUsers.length === 0 ? (
          <p className="admin-muted">No users in this view yet. Create an invite above to start the cohort.</p>
        ) : (
          <div className="admin-user-list">
            {visibleUsers.map((user) => {
              const draft = userDrafts[user.id] ?? adminDraftForUser(user)
              const isSelf = user.id === currentUser.id

              const draftNeedsCohort = roleRequiresCohort(draft.role) && draft.cohort_ids.length === 0
              const canResendInvite = user.invitation_status === 'pending'

              return (
                <article className="admin-user-row" key={user.id}>
                  <div className="admin-user-main">
                    <div>
                      <strong>{user.full_name}</strong>
                      <span>{user.email}</span>
                    </div>
                    <div className="admin-badge-row">
                      <AdminBadge value={titleize(user.role)} tone={user.role === 'admin' ? 'green' : user.role === 'coach' ? 'gold' : 'neutral'} />
                      <AdminBadge value={titleize(user.invitation_status)} tone={user.invitation_status === 'accepted' ? 'green' : user.invitation_status === 'revoked' ? 'red' : 'gold'} />
                      <AdminBadge value={`Email ${titleize(user.invite_email.status)}`} tone={inviteEmailTone(user.invite_email.status)} />
                      <AdminBadge value={`${user.workspace.profile_completeness}% setup`} tone={user.workspace.setup_complete ? 'green' : 'neutral'} />
                    </div>
                    <p>{user.cohorts.map((membership) => membership.cohort.name).join(', ') || (user.role === 'admin' ? 'No cohort assigned; admin can work across cohorts' : 'No cohort assigned yet')}</p>
                    {user.invite_email.last_attempted_at && (
                      <p className="admin-email-line">Last email attempt: {shortDateTime(user.invite_email.last_attempted_at)}{user.invite_email.error ? ` · ${user.invite_email.error}` : ''}</p>
                    )}
                  </div>

                  <div className="admin-user-controls">
                    <label className="admin-field compact">
                      <span>Role</span>
                      <select value={draft.role} disabled={isSelf} onChange={(event) => updateUserDraft(user.id, 'role', event.target.value)}>
                        {userRoles.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
                      </select>
                    </label>
                    <label className="admin-field compact">
                      <span>Status</span>
                      <select value={draft.invitation_status} disabled={isSelf} onChange={(event) => updateUserDraft(user.id, 'invitation_status', event.target.value)}>
                        {invitationStatuses.map((status) => <option key={status} value={status}>{titleize(status)}</option>)}
                      </select>
                    </label>
                    <div className={`admin-field compact cohort-select ${draftNeedsCohort ? 'needs-attention' : ''}`}>
                      <span>Cohorts {roleRequiresCohort(draft.role) ? '(required)' : '(optional)'}</span>
                      <div className="admin-cohort-checks">
                        {cohorts.length === 0 && <small>No cohorts yet. Create one before adding coaches or participants.</small>}
                        {cohorts.map((cohort) => (
                          <label className="admin-cohort-check" key={cohort.id}>
                            <input
                              type="checkbox"
                              checked={draft.cohort_ids.includes(String(cohort.id))}
                              onChange={() => toggleUserCohort(user.id, cohort.id)}
                            />
                            <span>{cohort.name}</span>
                          </label>
                        ))}
                      </div>
                      {draftNeedsCohort && <small className="admin-field-warning">Required before saving.</small>}
                    </div>
                    <div className="admin-user-actions">
                      <button type="button" onClick={() => void handleSaveUser(user)} disabled={savingUserId === user.id || draftNeedsCohort}>{savingUserId === user.id ? 'Saving' : 'Save'}</button>
                      <button type="button" className="secondary-action" onClick={() => void handleResendInvitation(user)} disabled={!canResendInvite || resendingUserId === user.id}>{resendingUserId === user.id ? 'Sending' : 'Resend email'}</button>
                    </div>
                  </div>
                </article>
              )
            })}
          </div>
        )}
      </article>
    </section>
  )
}

function AdminStat({ label, value }: { label: string; value: string }) {
  return (
    <article className="metric-card admin-stat-card">
      <span>{label}</span>
      <strong>{value}</strong>
    </article>
  )
}

function AdminBadge({ value, tone }: { value: string; tone: 'green' | 'gold' | 'red' | 'neutral' }) {
  return <span className={`admin-badge ${tone}`}>{value}</span>
}

function RoleMatrix({ open, onToggle }: { open: boolean; onToggle: (open: boolean) => void }) {
  return (
    <details className="role-matrix panel" open={open} onToggle={(event) => onToggle(event.currentTarget.open)}>
      <summary>
        <span>
          <strong>Role and cohort rules</strong>
          <small>Backend-enforced policy for admin, coach, and participant users.</small>
        </span>
      </summary>
      <div className="role-matrix-grid">
        <article>
          <strong>Admin</strong>
          <span>May have no cohort</span>
          <p>Can manage cohorts, users, invitations, and staff access. Admins are not limited to a single participant group.</p>
        </article>
        <article>
          <strong>Coach</strong>
          <span>Requires at least one cohort</span>
          <p>Supports assigned groups and can create participant invites, but cannot manage admin or coach accounts.</p>
        </article>
        <article>
          <strong>Participant</strong>
          <span>Requires at least one cohort</span>
          <p>Uses the household workspace and Mia coaching flow. Their detailed financial rows stay out of admin lists.</p>
        </article>
      </div>
    </details>
  )
}

function adminDraftsForUsers(users: AdminUser[]) {
  return users.reduce<Record<number, AdminUserDraft>>((drafts, user) => {
    drafts[user.id] = adminDraftForUser(user)
    return drafts
  }, {})
}

function adminDraftForUser(user: AdminUser): AdminUserDraft {
  return {
    role: user.role,
    invitation_status: user.invitation_status,
    cohort_ids: user.cohorts.map((membership) => String(membership.cohort.id)),
  }
}

function roleRequiresCohort(role: UserRole) {
  return role !== 'admin'
}

function inviteDeliveryNotice(response: AdminUserMutationResponse) {
  if (response.invitation_sent) return 'Invite email sent through Resend.'
  if (response.invitation_status === 'failed') return `Invite saved, but email delivery failed${response.invitation_error ? `: ${response.invitation_error}` : '.'}`
  if (response.invitation_status === 'skipped') return 'Invite saved; email delivery is skipped until Resend is configured.'

  return 'Invite saved.'
}

function inviteEmailTone(status: AdminUser['invite_email']['status']): 'green' | 'gold' | 'red' | 'neutral' {
  if (status === 'sent') return 'green'
  if (status === 'failed') return 'red'
  if (status === 'skipped') return 'gold'

  return 'neutral'
}

function shortDateTime(value: string) {
  return new Intl.DateTimeFormat('en-US', {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(value))
}

function cleanCohortDraft(draft: AdminCohortInput): AdminCohortInput {
  return {
    name: draft.name.trim(),
    status: draft.status,
    starts_on: draft.starts_on || '',
    ends_on: draft.ends_on || '',
    notes: draft.notes?.trim() ?? '',
  }
}

function cohortDraftFor(cohort: AdminCohort | null): AdminCohortInput | null {
  if (!cohort) return null

  return {
    name: cohort.name,
    status: cohort.status,
    starts_on: cohort.starts_on ?? '',
    ends_on: cohort.ends_on ?? '',
    notes: cohort.notes ?? '',
  }
}

function titleize(value: string) {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function cohortDateRange(cohort: AdminCohort) {
  if (cohort.starts_on && cohort.ends_on) return `${formatShortDate(cohort.starts_on)} – ${formatShortDate(cohort.ends_on)}`
  if (cohort.starts_on) return `Starts ${formatShortDate(cohort.starts_on)}`
  if (cohort.ends_on) return `Ends ${formatShortDate(cohort.ends_on)}`

  return 'Dates not set'
}

function formatShortDate(value: string) {
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${value}T00:00:00`))
}

function WorkspaceSetupForm({
  values,
  saving,
  error,
  onChange,
  onSubmit,
}: {
  values: WorkspaceSetupValues
  saving: boolean
  error: string | null
  onChange: (key: keyof WorkspaceSetupValues, value: string) => void
  onSubmit: (event: FormEvent<HTMLFormElement>) => void
}) {
  return (
    <form className="panel setup-form" onSubmit={onSubmit}>
      <div className="row-between setup-form-heading">
        <div>
          <p className="eyebrow">Real workspace</p>
          <h3>Plug in your household numbers</h3>
          <p>Mia will recalculate the screens and use these numbers as context.</p>
        </div>
        <button type="submit" disabled={saving}>{saving ? 'Saving' : 'Save numbers'}</button>
      </div>

      <div className="setup-field-grid">
        <label className="setup-field text-wide">
          <span>Household name</span>
          <input value={values.household_name} onChange={(event) => onChange('household_name', event.target.value)} />
        </label>
        <label className="setup-field text-wide">
          <span>Primary goal</span>
          <input value={values.primary_goal} onChange={(event) => onChange('primary_goal', event.target.value)} />
        </label>
        <MoneyInput label="Primary monthly income" value={values.primary_income} onChange={(value) => onChange('primary_income', value)} />
        <MoneyInput label="Business monthly income" value={values.business_income} onChange={(value) => onChange('business_income', value)} />
        <MoneyInput label="Fixed essentials" value={values.fixed_expenses} onChange={(value) => onChange('fixed_expenses', value)} />
        <MoneyInput label="Flexible spending" value={values.flexible_spend} onChange={(value) => onChange('flexible_spend', value)} />
        <MoneyInput label="Expected sinking fund" value={values.expected_sinking_fund} onChange={(value) => onChange('expected_sinking_fund', value)} />
        <MoneyInput label="Unexpected sinking fund" value={values.unexpected_sinking_fund} onChange={(value) => onChange('unexpected_sinking_fund', value)} />
        <MoneyInput label="Emergency fund" value={values.emergency_fund} onChange={(value) => onChange('emergency_fund', value)} />
        <MoneyInput label="Other assets" value={values.other_assets} onChange={(value) => onChange('other_assets', value)} />
        <MoneyInput label="Credit card debt" value={values.credit_card_debt} onChange={(value) => onChange('credit_card_debt', value)} />
        <MoneyInput label="Debt minimum payment" value={values.debt_payment} onChange={(value) => onChange('debt_payment', value)} />
        <label className="setup-field">
          <span>Target runway months</span>
          <input
            type="number"
            min="0"
            step="0.5"
            value={values.target_runway_months}
            onChange={(event) => onChange('target_runway_months', event.target.value)}
          />
        </label>
      </div>

      {error && <p className="setup-error" role="alert">{error}</p>}
    </form>
  )
}

function MoneyInput({ label, value, onChange }: { label: string; value: number; onChange: (value: string) => void }) {
  return (
    <label className="setup-field">
      <span>{label}</span>
      <input type="number" min="0" step="1" value={value} onChange={(event) => onChange(event.target.value)} />
    </label>
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

function CohortIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Cohort">
      <path d="M4.5 6.5A2.5 2.5 0 0 1 7 4h10a2.5 2.5 0 0 1 2.5 2.5v11A2.5 2.5 0 0 1 17 20H7a2.5 2.5 0 0 1-2.5-2.5v-11Z" className="icon-stroke" />
      <path d="M8 9h8M8 12h5M8 15h7" className="icon-stroke" />
    </svg>
  )
}

function UsersIcon() {
  return (
    <svg viewBox="0 0 24 24" role="img" aria-label="Users">
      <path d="M9.2 11.1a3.1 3.1 0 1 0 0-6.2 3.1 3.1 0 0 0 0 6.2ZM4.4 19.1c.55-3.1 2.2-4.65 4.8-4.65 2.58 0 4.22 1.55 4.78 4.65" className="icon-stroke" />
      <path d="M16.2 11.4a2.55 2.55 0 1 0 0-5.1M15.7 14.45c2.05.18 3.35 1.58 3.9 4.2" className="icon-stroke" />
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
