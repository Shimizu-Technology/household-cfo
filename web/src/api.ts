export type ProfileData = {
  household: {
    name: string
    stage: string
    location: string
    primary_goal: string
  }
  coach: {
    name: string
    role: string
    voice: string
  }
  members: Array<{ name: string; role: string; age_range: string }>
  priorities: string[]
}

export type DashboardData = {
  summary: {
    monthly_income: number
    fixed_expenses: number
    flexible_spend: number
    debt_payments: number
    savings_rate_percent: number
    runway_months: number
    next_safe_to_spend_amount: number
  }
  accounts: Array<{ name: string; type: string; balance: number }>
  alerts: Array<{ tone: string; title: string; body: string }>
}

export type OptionalityData = {
  scenario: string
  question: string
  target_runway_months: number
  current_runway_months: number
  monthly_gap: number
  choices: Array<{
    label: string
    readiness_score: number
    upside: string
    tradeoff: string
  }>
}

export type CfoFilterData = {
  framework: string
  prompt: string
  decisions: Array<{
    item: string
    amount: number
    recommendation: string
    reason: string
  }>
  targets: Array<{ label: string; current: number; target: number }>
}

export type MiaMessage = {
  role: 'assistant' | 'user'
  author: string
  content: string
}

export type MiaMessagesData = {
  messages: MiaMessage[]
}

export type AppData = {
  profile: ProfileData
  dashboard: DashboardData
  optionality: OptionalityData
  cfoFilter: CfoFilterData
  mia: MiaMessagesData
}

const API_BASE = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:3000'

async function fetchJson<T>(path: string): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`)
  if (!response.ok) {
    throw new Error(`API request failed: ${response.status}`)
  }
  return response.json() as Promise<T>
}

export async function fetchAppData(): Promise<AppData> {
  const [profile, dashboard, optionality, cfoFilter, mia] = await Promise.all([
    fetchJson<ProfileData>('/api/demo/profile'),
    fetchJson<DashboardData>('/api/demo/dashboard'),
    fetchJson<OptionalityData>('/api/demo/optionality'),
    fetchJson<CfoFilterData>('/api/demo/cfo-filter'),
    fetchJson<MiaMessagesData>('/api/demo/mia/messages'),
  ])

  return { profile, dashboard, optionality, cfoFilter, mia }
}

export async function sendMiaMessage(message: string): Promise<MiaMessage> {
  const response = await fetch(`${API_BASE}/api/demo/mia/messages`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message }),
  })

  if (!response.ok) {
    throw new Error(`Mia request failed: ${response.status}`)
  }

  const body = (await response.json()) as { assistant_message: MiaMessage }
  return body.assistant_message
}
