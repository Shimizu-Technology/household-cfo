import { useEffect, useMemo, useState } from 'react'
import './App.css'
import { fetchAppData, sendMiaMessage } from './api'
import type { AppData, MiaMessage } from './api'

const currency = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  maximumFractionDigits: 0,
})

const sections = [
  'Dashboard',
  'Ask Mia',
  'Profile',
  'Optionality',
  'CFO Filter',
  'Cohort',
]

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
      .catch(() => setError('API is not running yet. Start Rails on port 3000 to load live demo data.'))
  }, [])

  const availableToSpend = useMemo(() => {
    if (!data) return 0
    return data.dashboard.summary.next_safe_to_spend_amount
  }, [data])

  async function handleAskMia() {
    if (!question.trim()) return
    setMiaLoading(true)
    const userMessage: MiaMessage = { role: 'user', author: 'You', content: question }
    setMessages((current) => [...current, userMessage])

    try {
      const assistantMessage = await sendMiaMessage(question)
      setMessages((current) => [...current, assistantMessage])
      setQuestion('')
    } catch {
      setMessages((current) => [
        ...current,
        {
          role: 'assistant',
          author: 'Mia',
          content:
            'Mia: I can still help with the framework. First protect bills and runway, then decide what creates real optionality.',
        },
      ])
    } finally {
      setMiaLoading(false)
    }
  }

  if (!data) {
    return (
      <main className="app loading-state">
        <section className="hero-card">
          <p className="eyebrow">Household CFO powered by VERA</p>
          <h1>Building the first cohort experience.</h1>
          <p>{error ?? 'Loading real demo data from the Rails API...'}</p>
        </section>
      </main>
    )
  }

  return (
    <main className="app">
      <section className="hero-card">
        <div>
          <p className="eyebrow">Household CFO powered by VERA</p>
          <h1>Meet Mia, your household money operating system.</h1>
          <p className="hero-copy">
            A calm, guided way for families to understand cash flow, protect runway, and make bigger money
            decisions with confidence.
          </p>
        </div>
        <div className="launch-card">
          <span>Coming soon</span>
          <strong>First cohort preview</strong>
          <p>{data.profile.household.location} families get a guided CFO rhythm before the full launch.</p>
        </div>
      </section>

      <nav className="tabs" aria-label="Household CFO demo sections">
        {sections.map((section) => (
          <button
            key={section}
            type="button"
            className={active === section ? 'active' : ''}
            onClick={() => {
              setActive(section)
              window.history.replaceState(null, '', `#${encodeURIComponent(section)}`)
            }}
          >
            {section}
          </button>
        ))}
      </nav>

      {active === 'Dashboard' && (
        <section className="screen-grid dashboard-screen">
          <div className="screen-heading">
            <p className="eyebrow">Dashboard</p>
            <h2>Your money picture, without the spiral.</h2>
            <p>Demo data only — built to show the first Household CFO experience.</p>
          </div>

          <div className="metric-row">
            <Metric label="Monthly income" value={currency.format(data.dashboard.summary.monthly_income)} />
            <Metric label="Runway" value={`${data.dashboard.summary.runway_months} mo`} />
            <Metric label="Safe to spend" value={currency.format(availableToSpend)} />
          </div>

          <div className="card-list">
            {data.dashboard.alerts.map((alert) => (
              <article className={`insight-card ${alert.tone}`} key={alert.title}>
                <span>{alert.title}</span>
                <p>{alert.body}</p>
              </article>
            ))}
          </div>

          <div className="account-card">
            <h3>Accounts snapshot</h3>
            {data.dashboard.accounts.map((account) => (
              <div className="account-row" key={account.name}>
                <span>{account.name}</span>
                <strong className={account.balance < 0 ? 'negative' : ''}>{currency.format(account.balance)}</strong>
              </div>
            ))}
          </div>
        </section>
      )}

      {active === 'Ask Mia' && (
        <section className="screen-grid mia-screen">
          <div className="screen-heading">
            <p className="eyebrow">Ask Mia</p>
            <h2>AI coaching for household money decisions.</h2>
            <p>Mia uses the CFO framework to turn money anxiety into next steps.</p>
          </div>

          <div className="chat-card">
            {messages.map((message, index) => (
              <div className={`message ${message.role}`} key={`${message.author}-${index}`}>
                <strong>{message.author}</strong>
                <p>{message.content}</p>
              </div>
            ))}
          </div>

          <div className="ask-row">
            <input value={question} onChange={(event) => setQuestion(event.target.value)} aria-label="Ask Mia" />
            <button type="button" onClick={handleAskMia} disabled={miaLoading}>
              {miaLoading ? 'Thinking...' : 'Ask'}
            </button>
          </div>
        </section>
      )}

      {active === 'Profile' && (
        <section className="screen-grid profile-screen">
          <div className="screen-heading">
            <p className="eyebrow">My Profile</p>
            <h2>{data.profile.household.name}</h2>
            <p>{data.profile.household.primary_goal}</p>
          </div>

          <div className="profile-card">
            <h3>Household priorities</h3>
            <ul>
              {data.profile.priorities.map((priority) => (
                <li key={priority}>{priority}</li>
              ))}
            </ul>
          </div>

          <div className="profile-card muted-card">
            <h3>Document vault</h3>
            <p>Uploads and OCR are planned after the Wednesday visual sprint. This preview keeps the flow visible without overpromising parsing.</p>
            <button type="button">Upload placeholder</button>
          </div>
        </section>
      )}

      {active === 'Optionality' && (
        <section className="screen-grid optionality-screen">
          <div className="screen-heading">
            <p className="eyebrow">Optionality</p>
            <h2>{data.optionality.question}</h2>
            <p>
              Current runway: {data.optionality.current_runway_months} months. Target runway:{' '}
              {data.optionality.target_runway_months} months.
            </p>
          </div>

          <div className="choice-grid">
            {data.optionality.choices.map((choice) => (
              <article className="choice-card" key={choice.label}>
                <span>{choice.readiness_score}/100</span>
                <h3>{choice.label}</h3>
                <p>{choice.upside}</p>
                <small>{choice.tradeoff}</small>
              </article>
            ))}
          </div>
        </section>
      )}

      {active === 'CFO Filter' && (
        <section className="screen-grid cfo-screen">
          <div className="screen-heading">
            <p className="eyebrow">CFO Filter</p>
            <h2>Should this money move happen now?</h2>
            <p>{data.cfoFilter.prompt}</p>
          </div>

          <div className="decision-list">
            {data.cfoFilter.decisions.map((decision) => (
              <article className="decision-card" key={decision.item}>
                <div>
                  <span>{decision.recommendation}</span>
                  <h3>{decision.item}</h3>
                </div>
                <strong>{currency.format(decision.amount)}</strong>
                <p>{decision.reason}</p>
              </article>
            ))}
          </div>
        </section>
      )}

      {active === 'Cohort' && (
        <section className="screen-grid cohort-screen">
          <div className="screen-heading">
            <p className="eyebrow">Cohort Admin</p>
            <h2>First cohort command center.</h2>
            <p>A simple view for tracking member readiness, runway, and where Mia should guide next.</p>
          </div>

          <div className="target-grid">
            {data.cfoFilter.targets.map((target) => (
              <article className="target-card" key={target.label}>
                <span>{target.label}</span>
                <strong>{currency.format(target.current)}</strong>
                <p>Target: {currency.format(target.target)}</p>
              </article>
            ))}
          </div>
        </section>
      )}
    </main>
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
