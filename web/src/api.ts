export type ProfileSection = {
  label: string
  summary: string
  items: Array<{ label: string; amount: number }>
}

export type ProfileUpload = {
  label: string
  kind: string
  status: string
  accepts: string
}

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
  completeness: number
  uploads: ProfileUpload[]
  sections: ProfileSection[]
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
    readiness_label: string
  }
  accounts: Array<{ name: string; type: string; balance: number }>
  alerts: Array<{ tone: string; title: string; body: string }>
  next_steps: string[]
}

export type BudgetData = {
  framework: string
  intro: string
  monthly_income: number
  total_monthly_outflow: number
  baseline_surplus: number
  stacks: Array<{
    label: string
    color: string
    amount: number
    description: string
    examples: string[]
  }>
  custom_categories_note: string
}

export type WealthData = {
  summary: {
    net_worth: number
    liquid_net_worth: number
    retirement_projection: number
    monthly_wealth_building: number
  }
  milestones: Array<{
    label: string
    current: number
    target: number
    unit: string
    status: string
  }>
  guidance: string
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
  levers: Array<{ label: string; amount: number }>
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
  priority_stack: string[]
}

export type MiaMessage = {
  role: 'assistant' | 'user'
  author: string
  content: string
}

export type MiaMessagesData = {
  messages: MiaMessage[]
  quick_prompts: string[]
  disclaimer: string
}

export type AppData = {
  profile: ProfileData
  dashboard: DashboardData
  budget: BudgetData
  wealth: WealthData
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
  const [profile, dashboard, budget, wealth, optionality, cfoFilter, mia] = await Promise.all([
    fetchJson<ProfileData>('/api/demo/profile'),
    fetchJson<DashboardData>('/api/demo/dashboard'),
    fetchJson<BudgetData>('/api/demo/budget'),
    fetchJson<WealthData>('/api/demo/wealth'),
    fetchJson<OptionalityData>('/api/demo/optionality'),
    fetchJson<CfoFilterData>('/api/demo/cfo-filter'),
    fetchJson<MiaMessagesData>('/api/demo/mia/messages'),
  ])

  return { profile, dashboard, budget, wealth, optionality, cfoFilter, mia }
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
