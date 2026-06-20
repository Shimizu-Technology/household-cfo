import { useEffect, useMemo, useState } from 'react'
import './App.css'
import { fetchAppData, sendMiaMessage } from './api'
import type { AppData, MiaMessage } from './api'

const currency = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  maximumFractionDigits: 0,
})

const sections = ['Home', 'Ask Mia', 'My Profile', 'Budget', 'Wealth', 'CFO Filter', 'Optionality']

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
  const [data, setData] = useState<AppData | null>(null)
  const [active, setActive] = useState(() => {
    const hashSection = decodeURIComponent(window.location.hash.replace('#', ''))
    return sections.includes(hashSection) ? hashSection : sections[0]
  })
  const [messages, setMessages] = useState<MiaMessage[]>([])
  const [question, setQuestion] = useState('Can I take the leap?')
  const [miaLoading, setMiaLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    fetchAppData()
      .then((payload) => {
        setData(payload)
        setMessages(payload.mia.messages)
      })
      .catch(() => setError('Mia’s workspace is offline for a moment. Start the Rails API on port 3000 to load preview data.'))
  }, [])

  const surplus = useMemo(() => {
    if (!data) return 0
    return data.budget.monthly_income - data.budget.total_monthly_outflow
  }, [data])

  function switchSection(section: string) {
    setActive(section)
    window.history.replaceState(null, '', `#${encodeURIComponent(section)}`)
  }

  async function handleAskMia(prompt = question) {
    if (!prompt.trim()) return
    setMiaLoading(true)
    const userMessage: MiaMessage = { role: 'user', author: 'You', content: prompt }
    setMessages((current) => [...current, userMessage])

    try {
      const assistantMessage = await sendMiaMessage(prompt)
      setMessages((current) => [...current, assistantMessage])
      setQuestion('')
    } catch {
      setMessages((current) => [
        ...current,
        {
          role: 'assistant',
          author: 'Mia',
          content:
            'Mia: I can still coach the framework. Your next move is to protect fixed bills, keep the Expense Stack honest, then decide what creates real optionality.',
        },
      ])
    } finally {
      setMiaLoading(false)
    }
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
          <h1>Meet Mia, your calm household money coach.</h1>
          <p className="hero-copy">
            Turn budget stress into a simple operating rhythm: know the numbers, choose the next move,
            and protect the dream without living in a spreadsheet.
          </p>
        </div>
        <aside className="mia-status-card">
          <span className="spark">✦</span>
          <strong>Context loaded</strong>
          <p>{data.profile.completeness}% profile complete · {data.dashboard.summary.readiness_label}</p>
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
            title="Coaching that starts with your real household context."
            copy="Mia validates first, then helps you choose one next money move. No shame, no spreadsheet spiral."
          />

          <div className="mia-layout">
            <article className="mia-context panel">
              <span className="spark">✦</span>
              <h3>Context loaded</h3>
              <p>Profile, Expense Stack, runway, debt pressure, and Optionality scenario are ready for Mia to use.</p>
              <div className="upload-strip">
                <button type="button">📎 Upload spreadsheet</button>
                <button type="button">📷 Upload statement</button>
              </div>
            </article>

            <article className="chat-card">
              {messages.map((message, index) => (
                <div className={`message ${message.role}`} key={`${message.author}-${index}`}>
                  <strong>{message.author}</strong>
                  <p>{message.content}</p>
                </div>
              ))}
            </article>
          </div>

          <div className="quick-prompts">
            {data.mia.quick_prompts.map((prompt) => (
              <button type="button" key={prompt} onClick={() => handleAskMia(prompt)} disabled={miaLoading}>
                {prompt}
              </button>
            ))}
          </div>

          <div className="ask-row">
            <input value={question} onChange={(event) => setQuestion(event.target.value)} aria-label="Ask Mia" />
            <button type="button" onClick={() => handleAskMia()} disabled={miaLoading}>
              {miaLoading ? 'Thinking...' : 'Ask Mia'}
            </button>
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

export default App
