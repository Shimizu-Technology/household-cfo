export type WorkspaceSetupValues = {
  household_name: string
  primary_goal: string
  primary_income: number
  business_income: number
  fixed_expenses: number
  flexible_spend: number
  expected_sinking_fund: number
  unexpected_sinking_fund: number
  emergency_fund: number
  other_assets: number
  credit_card_debt: number
  debt_payment: number
  target_runway_months: number
}

export type WorkspaceData = {
  mode: 'demo' | 'real'
  household_id: number | null
  setup_complete: boolean
  setup_values: WorkspaceSetupValues
}

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

export type DocumentImportKind = 'spreadsheet' | 'statement' | 'pay_stub' | 'receipt' | 'other'
export type DocumentImportStatus = 'uploaded' | 'processing' | 'needs_review' | 'applied' | 'partially_applied' | 'failed' | 'source_deleted'
export type DocumentImportTargetType = 'income_source' | 'expense_item' | 'account' | 'debt' | 'goal' | 'profile_note'
export type DocumentImportConfidence = 'high' | 'medium' | 'low'
export type TransactionDraftMatchStatus = 'proposed' | 'accepted' | 'rejected'

export type DocumentImportUserReference = {
  id: number
  email: string
  full_name: string
}

export type DocumentImportItem = {
  id: number
  target_type: DocumentImportTargetType
  label: string
  amount: number | null
  amount_cents: number | null
  balance: number | null
  balance_cents: number | null
  payment: number | null
  payment_cents: number | null
  cadence: string | null
  source_type: string | null
  stack_key: string | null
  account_type: string | null
  debt_type: string | null
  confidence: DocumentImportConfidence | null
  evidence: string | null
  selected: boolean
  ignored: boolean
  applied_at: string | null
  applied_record_type: string | null
  applied_record_id: number | null
  metadata: Record<string, unknown>
}

export type DocumentImportAttempt = {
  id: number
  provider: string
  model: string
  status: string
  prompt_version: string
  schema_version: string
  error: string | null
  started_at: string | null
  completed_at: string | null
  metadata: Record<string, unknown>
}

export type TransactionDraftSplit = {
  id: number
  budget_category_id: number | null
  category_name: string | null
  stack_key: BudgetStackKey | null
  stack_label: string | null
  amount: number
  amount_cents: number
  notes: string | null
  confidence: number | string | null
  metadata?: Record<string, unknown>
}

export type TransactionDraftMatch = {
  id: number
  status: TransactionDraftMatchStatus
  confidence: number | string | null
  match_reason: string | null
  transaction: {
    id: number
    occurred_on: string
    merchant: string
    amount: number
    source_type: string
    categories: string[]
  }
}

export type FinancialDocumentImport = {
  id: number
  household_id: number
  document_kind: DocumentImportKind
  status: DocumentImportStatus
  filename: string
  content_type: string
  byte_size: number
  document_date: string | null
  period_start_on: string | null
  period_end_on: string | null
  extracted_summary: string | null
  extraction_error: string | null
  processed_at: string | null
  applied_at: string | null
  source_deleted_at: string | null
  updated_at: string
  source_available: boolean
  details_included: boolean
  uploaded_by: DocumentImportUserReference | null
  applied_by: DocumentImportUserReference | null
  source_deleted_by: DocumentImportUserReference | null
  metadata: {
    confidence?: DocumentImportConfidence
    warnings?: string[]
    original_filename?: string
    upload_request_id?: string
    extraction_model?: string
    extraction_mode?: string
    extraction_page_count?: number
    extraction_batch_count?: number
    last_extracted_at?: string
    last_applied_count?: number
    last_applied_at?: string
    transaction_draft_count?: number
    transaction_match_count?: number
  }
  items: DocumentImportItem[]
  transaction_drafts: TransactionDraft[]
  attempts: DocumentImportAttempt[]
}

export type DocumentSourceUrl = {
  url: string
  download_url: string
  expires_in: number
  filename: string
  content_type: string
  inline_supported: boolean
}

export type DocumentSourcePreviewRow = {
  row: number
  values: string[]
}

export type DocumentSourcePreviewSheet = {
  name: string
  row_count: number
  sampled_row_count: number
  columns_seen: number
  rows: DocumentSourcePreviewRow[]
}

export type DocumentSourcePreview = {
  type: 'spreadsheet' | 'text'
  filename: string
  content_type: string
  sheets?: DocumentSourcePreviewSheet[]
  text?: string
}

export type DocumentImportItemInput = Partial<Pick<
  DocumentImportItem,
  'target_type' | 'label' | 'cadence' | 'source_type' | 'stack_key' | 'account_type' | 'debt_type' | 'confidence' | 'evidence' | 'selected' | 'ignored'
>> & {
  amount?: string | number
  balance?: string | number
  payment?: string | number
}

export type DocumentImportApplyResponse = {
  document_import: FinancialDocumentImport
  applied_count: number
  workspace: AppData
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

export type ReadinessMilestone = {
  tone: 'yellow' | 'green'
  runway_months: number
  protected_liquid_target: number
  protected_liquid_gap: number
  cash_flow_requirement: string
  reached: boolean
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
    readiness_tone: 'red' | 'yellow' | 'green'
    readiness_label: string
  }
  action_center: {
    transaction_review_count: number
    mia_action_review_count: number
    total_review_count: number
    current_month_label: string
    current_month_index: number
    current_year: number
  }
  coach_read: {
    title: string
    body: string
  }
  readiness_path: {
    current_runway_months: number
    target_runway_months: number
    protected_liquid_amount: number
    monthly_surplus: number
    yellow: ReadinessMilestone
    green: ReadinessMilestone
  }
  accounts: Array<{ name: string; type: string; balance: number }>
  alerts: Array<{ tone: string; title: string; body: string }>
  next_steps: string[]
}

export type BudgetMonth = {
  id: number
  label: string
  starts_on: string
  ends_on: string
  status: string
}

export type BudgetCategoryMonth = {
  period_id: number
  allocation_id: number | null
  planned: number
  actual: number
  remaining: number
  allocation_missing?: boolean
}

export type BudgetCategoryRow = {
  id: number
  name: string
  stack_key: BudgetStackKey
  stack_label: string
  active: boolean
  months: BudgetCategoryMonth[]
  planned_total: number
  actual_total: number
}

export type TransactionDraft = {
  id: number
  occurred_on: string
  merchant: string
  amount: number
  amount_cents?: number
  status: string
  source_type?: string
  financial_document_import_id?: number | null
  category_id: number | null
  category_name: string | null
  stack_label?: string | null
  summary?: string
  splits?: TransactionDraftSplit[]
  matches?: TransactionDraftMatch[]
  matched_transaction_id?: number | null
  draft_payload?: Record<string, unknown>
}

export type RecentTransaction = {
  id: number
  occurred_on: string
  merchant: string
  amount: number
  source_type: string
  categories: string[]
}

export type SpendingReportCategory = {
  id: number
  name: string
  stack_key: BudgetStackKey
  stack_label: string
  planned: number
  actual: number
  pending: number
  remaining: number
  active?: boolean
}

export type ArchivedBudgetCategory = {
  id: number
  name: string
  stack_key: BudgetStackKey
  stack_label: string
  active: boolean
}

export type SpendingReport = {
  period_label: string
  start_on: string
  end_on: string
  totals: {
    planned: number
    actual: number
    pending: number
    remaining: number
  }
  categories: SpendingReportCategory[]
  transactions: RecentTransaction[]
  pending_drafts: Array<{
    id: number
    occurred_on: string
    merchant: string
    amount: number
    category_id: number | null
    category_name: string | null
  }>
}

export type MiaActionItem = {
  id: number
  action_type: 'create_category' | 'update_category' | 'update_allocation' | 'archive_category' | 'restore_category'
  target_record_type: string | null
  target_record_id: number | null
  label: string
  description: string | null
  payload: Record<string, unknown>
  before_snapshot: Record<string, unknown>
  after_snapshot: Record<string, unknown>
}

export type MiaActionDraft = {
  id: number
  status: 'pending' | 'applied' | 'canceled'
  draft_type: 'budget_edit'
  year: number
  title: string
  summary: string
  rationale: string | null
  source_prompt: string | null
  created_at: string | null
  applied_at: string | null
  canceled_at: string | null
  items: MiaActionItem[]
}

export type AnnualBudgetPlan = {
  year: number
  months: BudgetMonth[]
  rows: BudgetCategoryRow[]
  monthly_income: Record<number, number>
  income_sources: IncomeTimelineSource[]
  annual_outlook: AnnualOutlook
  pending_transaction_drafts: TransactionDraft[]
  pending_mia_action_drafts?: MiaActionDraft[]
  recent_transactions: RecentTransaction[]
  archived_categories?: ArchivedBudgetCategory[]
}

export type IncomeScheduleEntryType = 'recurring_change' | 'one_time'

export type IncomeScheduleEntry = {
  id: number
  entry_type: IncomeScheduleEntryType
  label: string | null
  amount: number
  cadence: string
  effective_on: string
}

export type IncomeTimelineSource = {
  id: number
  label: string
  source_type: string
  base_amount: number
  base_cadence: string
  schedule_entries: IncomeScheduleEntry[]
}

export type AnnualOutlookMonth = {
  period_id: number
  label: string
  starts_on: string
  income: number
  planned_outflow: number
  baseline_surplus: number
  expected_irregular: number
  expected_contributors: Array<{ name: string; amount: number }>
  amount_above_typical?: number
}

export type AnnualOutlook = {
  typical_monthly_outflow: number
  months: AnnualOutlookMonth[]
  upcoming_spikes: AnnualOutlookMonth[]
  next_irregular_month: AnnualOutlookMonth | null
}

export type IncomeScheduleEntryInput = {
  income_source_id: number
  entry_type: IncomeScheduleEntryType
  label?: string
  amount: number | string
  cadence?: string
  effective_on: string
}

export type BudgetStackKey = 'non_discretionary' | 'discretionary' | 'sinking_expected' | 'sinking_unexpected'

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
  annual_plan?: AnnualBudgetPlan
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
    fit_label: string
    fit_tone: 'red' | 'yellow' | 'green'
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

export type MiaMessageAttachment = {
  document_import_id?: number
  filename: string
  content_type: string
  document_kind: DocumentImportKind
  status: DocumentImportStatus
  source_available: boolean
  preview_url?: string
}

export type MiaMessage = {
  id?: number
  client_id?: string
  role: 'assistant' | 'user'
  author: string
  content: string
  attachments?: MiaMessageAttachment[]
  created_at?: string
}

export type MiaMessagesData = {
  messages: MiaMessage[]
  oldest_message_id: number | null
  older_message_count: number
  has_older_messages: boolean
  quick_prompts: string[]
  disclaimer: string
}

export type UserRole = 'admin' | 'coach' | 'participant'
export type InvitationStatus = 'pending' | 'accepted' | 'revoked'
export type AdminCohortStatus = 'draft' | 'enrolling' | 'active' | 'completed' | 'archived'

export type CurrentUser = {
  id: number
  clerk_id: string
  email: string
  first_name: string | null
  last_name: string | null
  full_name: string
  role: UserRole
  invitation_status: InvitationStatus
  invited_at: string | null
  accepted_at: string | null
  last_sign_in_at: string | null
  created_at: string
  is_admin: boolean
  is_coach: boolean
  is_participant: boolean
  is_staff: boolean
}

export type AdminCohort = {
  id: number
  name: string
  status: AdminCohortStatus
  starts_on: string | null
  ends_on: string | null
  notes: string
  member_count: number
  participant_count: number
  staff_count: number
  setup_complete_count: number
  created_at: string
  updated_at: string
  created_by: {
    id: number
    email: string
    full_name: string
  }
  members?: Array<{
    id: number
    role: 'participant' | 'coach' | 'admin'
    user: {
      id: number
      email: string
      full_name: string
      role: UserRole
      invitation_status: InvitationStatus
      setup_complete: boolean
    }
  }>
}

export type AdminInviteEmailStatus = 'not_sent' | 'skipped' | 'sent' | 'failed'

export type AdminUser = CurrentUser & {
  invited_by: null | {
    id: number
    email: string
    full_name: string
  }
  invite_email: {
    status: AdminInviteEmailStatus
    provider_message_id: string | null
    error: string | null
    last_attempted_at: string | null
    last_sent_at: string | null
    last_sent_by: null | {
      id: number
      email: string
      full_name: string
    }
    delivery_log: Array<{
      id: number
      status: AdminInviteEmailStatus
      attempted_at: string
      sent_at: string | null
      sent_by_user_id: number | null
      sent_by: null | {
        id: number
        email: string
        full_name: string
      }
      provider: string
      provider_message_id: string | null
      error: string | null
    }>
  }
  cohorts: Array<{
    id: number
    role: 'participant' | 'coach' | 'admin'
    cohort: {
      id: number
      name: string
      status: AdminCohortStatus
    }
  }>
  workspace: {
    household_id: number | null
    household_name: string | null
    setup_complete: boolean
    profile_completeness: number
    readiness_label: string
  }
}

export type AdminCohortInput = {
  name: string
  status: AdminCohortStatus
  starts_on?: string
  ends_on?: string
  notes?: string
}

export type AdminUserMutationResponse = {
  user: AdminUser
  created?: boolean
  reactivated?: boolean
  invitation_sent?: boolean
  invitation_status?: AdminInviteEmailStatus
  invitation_error?: string | null
}

export type AdminUserInput = {
  email?: string
  first_name?: string
  last_name?: string
  role?: UserRole
  invitation_status?: InvitationStatus
  cohort_id?: number | string | null
  cohort_ids?: number[]
  send_invitation_email?: boolean
}

export type AppData = {
  workspace?: WorkspaceData
  profile: ProfileData
  dashboard: DashboardData
  budget: BudgetData
  wealth: WealthData
  optionality: OptionalityData
  cfoFilter: CfoFilterData
  mia: MiaMessagesData
}

type AuthTokenGetter = () => Promise<string | null>

const API_BASE = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:3000'
let authTokenGetter: AuthTokenGetter | null = null

function browserHostIsLocal() {
  if (typeof window === 'undefined') return true

  return ['localhost', '127.0.0.1', '::1'].includes(window.location.hostname)
}

function apiNetworkErrorMessage(action: string) {
  if (!browserHostIsLocal() && /localhost|127\.0\.0\.1/.test(API_BASE)) {
    return `${action}. This web deploy is still pointing at ${API_BASE}. Set VITE_API_BASE_URL to the production Render API and redeploy Netlify.`
  }

  return `${action}. Check the production API URL, CORS allowlist, Clerk session, and private S3 configuration.`
}

export function setAuthTokenGetter(getter: AuthTokenGetter | null) {
  authTokenGetter = getter
}

async function authHeaders(): Promise<Record<string, string>> {
  if (!authTokenGetter) return {}

  const token = await authTokenGetter()
  return token ? { Authorization: `Bearer ${token}` } : {}
}

async function fetchJson<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers = {
    ...(await authHeaders()),
    ...(options.headers as Record<string, string> | undefined),
  }

  let response: Response
  try {
    response = await fetch(`${API_BASE}${path}`, {
      ...options,
      headers,
    })
  } catch (error) {
    throw new Error(apiNetworkErrorMessage('API request could not reach the server'), { cause: error })
  }

  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, 'API request failed'))
  }

  if (response.status === 204) return undefined as T

  return response.json() as Promise<T>
}

async function postJson<T>(path: string, body: unknown): Promise<T> {
  return fetchJson<T>(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
}

async function responseErrorMessage(response: Response, fallback: string) {
  try {
    const payload = (await response.json()) as { error?: string; errors?: string[] }
    return payload.error ?? payload.errors?.join(', ') ?? `${fallback}: ${response.status}`
  } catch {
    return `${fallback}: ${response.status}`
  }
}

export async function fetchCurrentUser(): Promise<CurrentUser> {
  const payload = await fetchJson<{ user: CurrentUser }>('/api/v1/auth/me')
  return payload.user
}

export async function fetchAdminUsers(): Promise<AdminUser[]> {
  const payload = await fetchJson<{ users: AdminUser[] }>('/api/v1/admin/users')
  return payload.users
}

export async function fetchAdminCohorts(): Promise<AdminCohort[]> {
  const payload = await fetchJson<{ cohorts: AdminCohort[] }>('/api/v1/admin/cohorts')
  return payload.cohorts
}

export async function createAdminCohort(values: AdminCohortInput): Promise<AdminCohort> {
  const payload = await postJson<{ cohort: AdminCohort }>('/api/v1/admin/cohorts', { cohort: values })
  return payload.cohort
}

export async function updateAdminCohort(id: number, values: AdminCohortInput): Promise<AdminCohort> {
  const payload = await fetchJson<{ cohort: AdminCohort }>(`/api/v1/admin/cohorts/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ cohort: values }),
  })
  return payload.cohort
}

export async function createAdminUser(values: AdminUserInput): Promise<AdminUserMutationResponse> {
  return postJson<AdminUserMutationResponse>('/api/v1/admin/users', { user: values })
}

export async function updateAdminUser(id: number, values: AdminUserInput): Promise<AdminUser> {
  const payload = await fetchJson<{ user: AdminUser }>(`/api/v1/admin/users/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ user: values }),
  })
  return payload.user
}

export async function resendAdminUserInvitation(id: number): Promise<AdminUserMutationResponse> {
  return postJson<AdminUserMutationResponse>(`/api/v1/admin/users/${id}/resend_invitation`, {})
}

export async function fetchAppData(realWorkspace = false): Promise<AppData> {
  if (realWorkspace) {
    return fetchJson<AppData>('/api/v1/workspace')
  }

  const [profile, dashboard, budget, wealth, optionality, cfoFilter, mia] = await Promise.all([
    fetchJson<ProfileData>('/api/demo/profile'),
    fetchJson<DashboardData>('/api/demo/dashboard'),
    fetchJson<BudgetData>('/api/demo/budget'),
    fetchJson<WealthData>('/api/demo/wealth'),
    fetchJson<OptionalityData>('/api/demo/optionality'),
    fetchJson<CfoFilterData>('/api/demo/cfo-filter'),
    fetchJson<MiaMessagesData>('/api/demo/mia/messages'),
  ])

  return {
    workspace: {
      mode: 'demo',
      household_id: null,
      setup_complete: true,
      setup_values: demoWorkspaceSetupValues(profile, dashboard, budget, wealth),
    },
    profile,
    dashboard,
    budget,
    wealth,
    optionality,
    cfoFilter,
    mia,
  }
}

export async function saveWorkspaceSetup(values: WorkspaceSetupValues): Promise<AppData> {
  return fetchJson<AppData>('/api/v1/workspace/setup', {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ workspace: values }),
  })
}

export async function fetchBudget(year?: number): Promise<BudgetData> {
  const query = year ? `?year=${encodeURIComponent(year)}` : ''
  return fetchJson<BudgetData>(`/api/v1/budget${query}`)
}

export async function fetchSpendingReport(startOn: string, endOn: string): Promise<SpendingReport> {
  const query = new URLSearchParams({ start_on: startOn, end_on: endOn })
  const payload = await fetchJson<{ spending_report: SpendingReport }>(`/api/v1/spending_report?${query}`)
  return payload.spending_report
}

export type MiaMessageResponse = {
  user_message: MiaMessage
  assistant_message: MiaMessage
  transaction_draft?: TransactionDraft | null
  mia_action_draft?: MiaActionDraft | null
  budget?: BudgetData | null
  spending_report?: SpendingReport | null
}

export async function fetchMiaMessages(realWorkspace = false, beforeId?: number | null): Promise<MiaMessagesData> {
  if (!realWorkspace) {
    return { messages: [], oldest_message_id: null, older_message_count: 0, has_older_messages: false, quick_prompts: [], disclaimer: '' }
  }

  const query = beforeId ? `?before_id=${encodeURIComponent(beforeId)}&limit=60` : '?limit=60'
  return fetchJson<MiaMessagesData>(`/api/v1/mia/messages${query}`)
}

export async function sendMiaMessage(message: string, history: MiaMessage[] = [], realWorkspace = false, year?: number, month?: number, documentImportIds: number[] = []): Promise<MiaMessageResponse> {
  return postJson<MiaMessageResponse>(realWorkspace ? '/api/v1/mia/messages' : '/api/demo/mia/messages', {
    message,
    ...(realWorkspace && year ? { year } : {}),
    ...(realWorkspace && month ? { month } : {}),
    ...(realWorkspace && documentImportIds.length > 0 ? { document_import_ids: documentImportIds } : {}),
    messages: history.slice(-32).map((entry) => ({
      role: entry.role,
      content: entry.content,
    })),
  })
}

function clientRequestId() {
  const cryptoApi = globalThis.crypto
  if (typeof cryptoApi?.randomUUID === 'function') return cryptoApi.randomUUID()

  if (typeof cryptoApi?.getRandomValues === 'function') {
    const bytes = new Uint8Array(16)
    cryptoApi.getRandomValues(bytes)
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
  }

  return `request-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

function yearQuery(year?: number) {
  return year ? `?year=${encodeURIComponent(year)}` : ''
}

export async function createBudgetCategory(values: { name: string; stack_key: BudgetStackKey; monthly_amount?: number | string }, year?: number): Promise<BudgetData> {
  const payload = await postJson<{ budget: BudgetData }>(`/api/v1/budget_categories${yearQuery(year)}`, { category: values })
  return payload.budget
}

export async function updateBudgetCategory(id: number, values: { name: string; stack_key: BudgetStackKey }, year?: number): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/budget_categories/${id}${yearQuery(year)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ category: values }),
  })
  return payload.budget
}

export async function archiveBudgetCategory(id: number, year?: number): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/budget_categories/${id}${yearQuery(year)}`, { method: 'DELETE' })
  return payload.budget
}

export async function restoreBudgetCategory(id: number, year?: number): Promise<BudgetData> {
  const payload = await postJson<{ budget: BudgetData }>(`/api/v1/budget_categories/${id}/restore${yearQuery(year)}`, {})
  return payload.budget
}

export async function updateBudgetAllocation(id: number, plannedAmount: number | string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/budget_allocations/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ allocation: { planned_amount: plannedAmount } }),
  })
  return payload.budget
}

export async function createIncomeScheduleEntry(values: IncomeScheduleEntryInput, year?: number): Promise<BudgetData> {
  const payload = await postJson<{ budget: BudgetData }>(`/api/v1/income_schedule_entries${yearQuery(year)}`, { income_schedule_entry: values })
  return payload.budget
}

export async function updateIncomeScheduleEntry(id: number, values: IncomeScheduleEntryInput, year?: number): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_schedule_entries/${id}${yearQuery(year)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ income_schedule_entry: values }),
  })
  return payload.budget
}

export async function deleteIncomeScheduleEntry(id: number, year?: number): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_schedule_entries/${id}${yearQuery(year)}`, { method: 'DELETE' })
  return payload.budget
}

export async function applyMiaActionDraft(id: number): Promise<AppData> {
  const payload = await postJson<{ workspace: AppData }>(`/api/v1/mia_action_drafts/${id}/apply`, {})
  return payload.workspace
}

export async function cancelMiaActionDraft(id: number): Promise<AppData> {
  const payload = await postJson<{ workspace: AppData }>(`/api/v1/mia_action_drafts/${id}/cancel`, {})
  return payload.workspace
}

export type TransactionDraftUpdateInput = Partial<{ occurred_on: string; merchant: string; amount: number | string; budget_category_id: number | null }> & {
  splits?: Array<Partial<{ id: number; amount: number | string; budget_category_id: number | null; category_name: string | null; stack_key: BudgetStackKey | null; notes: string | null; confidence: number | string | null }>>
}

export async function updateTransactionDraft(id: number, values: TransactionDraftUpdateInput): Promise<{ transaction_draft: TransactionDraft; workspace: AppData }> {
  return fetchJson<{ transaction_draft: TransactionDraft; workspace: AppData }>(`/api/v1/transaction_drafts/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ transaction_draft: values }),
  })
}

export async function confirmTransactionDraft(id: number, values: TransactionDraftUpdateInput = {}): Promise<AppData> {
  const payload = await postJson<{ workspace: AppData }>(`/api/v1/transaction_drafts/${id}/confirm`, { transaction_draft: values })
  return payload.workspace
}

export async function ignoreTransactionDraft(id: number): Promise<AppData> {
  const payload = await postJson<{ workspace: AppData }>(`/api/v1/transaction_drafts/${id}/ignore`, {})
  return payload.workspace
}

export async function bulkConfirmTransactionDrafts(ids: number[], year: number, confirmation: string): Promise<AppData> {
  const payload = await postJson<{ workspace: AppData }>('/api/v1/transaction_drafts/bulk_confirm', { transaction_draft_ids: ids, year, confirmation })
  return payload.workspace
}

export async function bulkIgnoreTransactionDrafts(ids: number[], year: number): Promise<AppData> {
  const payload = await postJson<{ workspace: AppData }>('/api/v1/transaction_drafts/bulk_ignore', { transaction_draft_ids: ids, year })
  return payload.workspace
}

export async function matchTransactionDraft(id: number, matchId?: number): Promise<AppData> {
  const payload = await postJson<{ workspace: AppData }>(`/api/v1/transaction_drafts/${id}/match`, matchId ? { match_id: matchId } : {})
  return payload.workspace
}

export async function reopenTransactionDraft(id: number): Promise<AppData> {
  const payload = await postJson<{ workspace: AppData }>(`/api/v1/transaction_drafts/${id}/reopen`, {})
  return payload.workspace
}

export async function clearMiaMessages(realWorkspace = false): Promise<void> {
  if (!realWorkspace) return

  await fetchJson<unknown>('/api/v1/mia/messages', { method: 'DELETE' })
}

export async function transcribeMiaVoice(audio: Blob): Promise<string> {
  const formData = new FormData()
  const contentType = audio.type || 'audio/webm'
  const extension = contentType.includes('mp4') ? 'm4a' : contentType.includes('mpeg') ? 'mp3' : contentType.includes('ogg') ? 'ogg' : 'webm'
  formData.append('audio', new File([audio], `mia-voice.${extension}`, { type: contentType }))

  let response: Response
  try {
    response = await fetch(`${API_BASE}/api/v1/mia/transcriptions`, {
      method: 'POST',
      headers: await authHeaders(),
      body: formData,
    })
  } catch (error) {
    throw new Error(apiNetworkErrorMessage('Voice transcription could not reach the API'), { cause: error })
  }

  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, 'Voice transcription failed'))
  }

  const payload = (await response.json()) as { transcript: string }
  return payload.transcript
}

export async function fetchDocumentImports(): Promise<FinancialDocumentImport[]> {
  const payload = await fetchJson<{ document_imports: FinancialDocumentImport[] }>('/api/v1/document_imports')
  return payload.document_imports
}

export async function fetchDocumentImport(id: number): Promise<FinancialDocumentImport> {
  const payload = await fetchJson<{ document_import: FinancialDocumentImport }>(`/api/v1/document_imports/${id}`)
  return payload.document_import
}

export async function uploadDocumentImport(file: File, documentKind: DocumentImportKind, origin: 'profile' | 'mia' = 'profile', uploadContext = ''): Promise<FinancialDocumentImport> {
  const formData = new FormData()
  formData.append('file', file)
  formData.append('document_kind', documentKind)
  formData.append('upload_origin', origin)
  if (uploadContext.trim()) formData.append('upload_context', uploadContext.trim())
  formData.append('upload_request_id', clientRequestId())

  let response: Response
  try {
    response = await fetch(`${API_BASE}/api/v1/document_imports`, {
      method: 'POST',
      headers: await authHeaders(),
      body: formData,
    })
  } catch (error) {
    throw new Error(apiNetworkErrorMessage('Document upload could not reach the API'), { cause: error })
  }

  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, 'Document upload failed'))
  }

  const payload = (await response.json()) as { document_import: FinancialDocumentImport }
  return payload.document_import
}

export async function updateDocumentImportItem(documentImportId: number, itemId: number, values: DocumentImportItemInput): Promise<DocumentImportItem> {
  const payload = await fetchJson<{ item: DocumentImportItem }>(`/api/v1/document_imports/${documentImportId}/items/${itemId}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ item: values }),
  })
  return payload.item
}

export async function applyDocumentImport(documentImportId: number, itemIds: number[]): Promise<DocumentImportApplyResponse> {
  return postJson<DocumentImportApplyResponse>(`/api/v1/document_imports/${documentImportId}/apply`, { item_ids: itemIds })
}

export async function reprocessDocumentImport(documentImportId: number): Promise<FinancialDocumentImport> {
  const payload = await postJson<{ document_import: FinancialDocumentImport }>(`/api/v1/document_imports/${documentImportId}/reprocess`, {})
  return payload.document_import
}

export async function deleteDocumentImportSource(documentImportId: number): Promise<FinancialDocumentImport> {
  const payload = await fetchJson<{ document_import: FinancialDocumentImport }>(`/api/v1/document_imports/${documentImportId}/source`, { method: 'DELETE' })
  return payload.document_import
}

export async function deleteDocumentImport(documentImportId: number): Promise<void> {
  await fetchJson<unknown>(`/api/v1/document_imports/${documentImportId}`, { method: 'DELETE' })
}

export async function fetchDocumentImportSourceUrl(documentImportId: number): Promise<DocumentSourceUrl> {
  return fetchJson<DocumentSourceUrl>(`/api/v1/document_imports/${documentImportId}/source_url`)
}

export async function fetchDocumentImportSourcePreview(documentImportId: number): Promise<DocumentSourcePreview> {
  return fetchJson<DocumentSourcePreview>(`/api/v1/document_imports/${documentImportId}/source_preview`)
}

function demoWorkspaceSetupValues(profile: ProfileData, dashboard: DashboardData, budget: BudgetData, wealth: WealthData): WorkspaceSetupValues {
  return {
    household_name: profile.household.name,
    primary_goal: profile.household.primary_goal,
    primary_income: dashboard.summary.monthly_income,
    business_income: 0,
    fixed_expenses: budget.stacks.find((stack) => stack.label === 'Non-discretionary')?.amount ?? 0,
    flexible_spend: budget.stacks.find((stack) => stack.label === 'Discretionary')?.amount ?? 0,
    expected_sinking_fund: budget.stacks.find((stack) => stack.label === 'Sinking Fund — Expected')?.amount ?? 0,
    unexpected_sinking_fund: budget.stacks.find((stack) => stack.label === 'Sinking Fund — Unexpected')?.amount ?? 0,
    emergency_fund: dashboard.accounts.find((account) => account.name === 'Emergency Fund')?.balance ?? 0,
    other_assets: wealth.summary.net_worth,
    credit_card_debt: Math.abs(dashboard.accounts.find((account) => account.type === 'debt')?.balance ?? 0),
    debt_payment: dashboard.summary.debt_payments,
    target_runway_months: 6,
  }
}
