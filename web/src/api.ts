import { checkedSavingsChallenge } from './lib/savingsChallenge'
import type { SavingsChallenge, SavingsEnrollment, SavingsPlanVersion, SavingsPlanDraft, SavingsEntry, SavingsEntryDraft, SavingsEntryVersion, SavingsPage, SavingsMutation, SavingsPlanInput, SavingsPlanApproval, SavingsEntryInput, SavingsEntryApproval } from './lib/savingsChallenge'
import type { SourceReviewAction, TrackedSourceAccount, ReviewedRow } from './lib/participantSourceReview'
import type { SourceReview, SourceReviewFilter } from './lib/sourceReview'
export type WorkspaceSetupValues = {
  household_name: string
  primary_goal: string
  primary_income: number
  business_income: number
  fixed_expenses: number
  flexible_spend: number
  expected_sinking_fund: number
  unexpected_sinking_fund: number
  emergency_fund: number | null
  other_assets: number | null
  credit_card_debt: number | null
  debt_payment: number | null
  target_runway_months: number
}

export type WorkspaceSetupFieldStatus = {
  key: keyof WorkspaceSetupValues
  label: string
  confirmed: boolean
}

export type WorkspaceSetupStatus = {
  complete: boolean
  completed_count: number
  required_count: number
  required_fields: WorkspaceSetupFieldStatus[]
  confirmed_fields: string[]
  missing_fields: WorkspaceSetupFieldStatus[]
}

export type BrandConfig = {
  schema_version: 1
  product_name: string
  short_name: string
  organization_name: string
  participant_role_term: string
  powered_by_name: string | null
  powered_by_placement: 'hidden' | 'header' | 'footer'
  tagline: string | null
  welcome_heading: string | null
  welcome_description: string | null
  logo_url: string | null
  favicon_url: string | null
  support: { label: string | null; email: string | null; url: string | null }
  colors: Record<string, string>
  typography: { display: string; body: string }
  footer: { text: string | null; privacy_url: string | null; terms_url: string | null }
}

export type BrandRuntime = {
  source: string
  mode: string
  version_id: number | null
  digest: string
  available: boolean
  config: BrandConfig
}

export type PublicBrandResponse = {
  brand: BrandConfig
  source: string
  available: boolean
  workspace: null | { slug: string }
  version: null | { number: number; digest: string }
  primary_domain: string | null
}

export type WorkspaceData = {
  financial_generation?: number
  experience_mode?: 'household_cfo' | 'savings_challenge'
  mode: 'demo' | 'real'
  household_id: number | null
  setup_complete: boolean
  setup_status: WorkspaceSetupStatus
  setup_values: WorkspaceSetupValues
  income_sources: IncomeTimelineSource[]
  accounts: AccountRecord[]
  asset_portfolio: AssetPortfolio
  debts: DebtRecord[]
  debt_portfolio: DebtPortfolio
  goals: GoalRecord[]
  goal_portfolio: GoalPortfolio
  cohort: null | {
    id: number
    name: string
    role: 'participant' | 'coach' | 'admin'
    status: AdminCohortStatus
  }
  capabilities: ExperienceCapabilities
  brand: BrandRuntime
}

export type AccountType = 'checking' | 'savings' | 'emergency_fund' | 'retirement' | 'investment' | 'property' | 'other'
export type AccountRecord = {
  id: number
  label: string
  account_type: AccountType
  balance: number | null
  balance_as_of_on: string | null
  active: boolean
  archived_at: string | null
  source_type: 'manual_ui' | 'mia' | 'document_import' | 'setup' | 'plaid'
  source_metadata: Record<string, unknown>
  plaid_link: null | {
    plaid_account_id: number
    institution_name: string
    name: string
    mask: string | null
    current_balance: number | null
    available_balance: number | null
    observed_at: string | null
    active: boolean
    observation_newer_than_saved: boolean
  }
}
export type AccountInput = { label: string; account_type: AccountType; balance: number | null; balance_as_of_on?: string | null; plaid_account_id?: number }
export type AssetPortfolio = {
  liquid_balance: number
  nonliquid_balance: number
  total_balance: number
  liquid_balance_known: boolean
  nonliquid_balance_known: boolean
  total_balance_known: boolean
  active_count: number
  archived_count: number
  liquid_known_count: number
  nonliquid_known_count: number
  total_known_count: number
  unknown_balance_account_ids: number[]
}

export type ExperienceModuleId = 'home' | 'review' | 'ask_mia' | 'budget' | 'profile' | 'wealth' | 'cfo_filter' | 'optionality'

export type ExperienceCapability = {
  id: ExperienceModuleId
  label: string
  enabled: boolean
  core: boolean
  unavailable_message?: string
}

export type ExperienceCapabilities = {
  schema_version: 1
  source: 'published_cohort' | 'standalone_default' | 'safe_default' | 'demo'
  cohort_id: number | null
  experience_version: null | { id: number; number: number }
  modules: ExperienceCapability[]
}

export type DebtType = 'credit_card' | 'student_loan' | 'auto_loan' | 'mortgage' | 'personal_loan' | 'medical' | 'other'

export type DebtRecord = {
  id: number
  label: string
  debt_type: DebtType
  balance: number | null
  minimum_payment: number | null
  interest_rate_percent: number | null
  active: boolean
  archived_at: string | null
  source_type: 'manual_ui' | 'mia' | 'document_import' | 'setup'
  source_metadata: Record<string, unknown>
}

export type DebtInput = Pick<DebtRecord, 'label' | 'debt_type' | 'balance' | 'minimum_payment' | 'interest_rate_percent'>

export type DebtPortfolio = {
  mode: 'summary' | 'individual'
  total_balance: number
  monthly_minimum: number
  balance_known: boolean
  minimum_payment_known: boolean
  active_count: number
  archived_count: number
}

export type GoalType = 'debt_payoff' | 'business_income' | 'purchase' | 'savings' | 'education' | 'business' | 'travel' | 'home' | 'retirement' | 'other'
export type GoalRecord = {
  id: number
  label: string
  goal_type: GoalType
  target_amount: number | null
  current_amount: number | null
  target_on: string | null
  priority: number
  active: boolean
  archived_at: string | null
  source_type: 'manual_ui' | 'mia' | 'document_import' | 'setup'
  source_metadata: Record<string, unknown>
}
export type GoalInput = Pick<GoalRecord, 'label' | 'goal_type' | 'target_amount' | 'current_amount' | 'target_on'>
export type GoalPortfolio = {
  active_count: number
  archived_count: number
  target_total: number
  progress_total: number
  target_known_count: number
  progress_known_count: number
  unknown_target_goal_ids: number[]
  unknown_progress_goal_ids: number[]
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
  interest_rate_percent: number | null
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
  context_paused_by_restart?: boolean
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
    source_accounting_revision_id?: number
    source_accounting_contract_version?: string | number
    source_accounting_review_pending?: boolean
    transaction_draft_count?: number
    transaction_match_count?: number
    upload_origin?: 'profile' | 'mia'
    declared_document_kind?: DocumentImportKind
    document_kind_explicit?: boolean
    routing_detected_kind?: DocumentImportKind
    routing_resolved_kind?: DocumentImportKind
    routing_source?: 'participant_context' | 'participant_selection' | 'mia_detection' | 'file_default'
    routing_conflict?: boolean
    routing_conflict_reason?: 'participant_signals' | 'mia_detection'
    routing_requires_confirmation?: boolean
    routing_destination?: 'transaction_review' | 'household_setup_review' | 'private_document_review'
  }
  items: DocumentImportItem[]
  transaction_drafts: TransactionDraft[]
  attempts: DocumentImportAttempt[]
}

export type DocumentSourceUrl = {
  authenticated_content: true
  source_version?: string
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
  balance?: string | number | null
  payment?: string | number | null
  interest_rate_percent?: string | number | null
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
    monthly_surplus_rate_percent: number
    runway_months: number | null
    next_safe_to_spend_amount: number | null
    readiness_available: boolean
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
    available?: boolean
    unavailable_reason?: string
    current_runway_months: number | null
    target_runway_months: number
    protected_liquid_amount: number
    monthly_surplus: number | null
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
  financial_source_event_id?: number | null
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
  position?: number
  action_type:
    | 'create_category'
    | 'update_category'
    | 'update_allocation'
    | 'archive_category'
    | 'restore_category'
    | 'update_setup_value'
    | 'upsert_income_schedule_entry'
    | 'create_income_source'
    | 'update_income_source'
    | 'archive_income_source'
    | 'restore_income_source'
    | 'create_income_schedule_entry'
    | 'update_income_schedule_entry'
    | 'delete_income_schedule_entry'
    | 'create_debt'
    | 'update_debt'
    | 'archive_debt'
    | 'restore_debt'
    | 'update_debt_tracking'
    | 'create_account'
    | 'update_account'
    | 'archive_account'
    | 'restore_account'
    | 'link_plaid_account'
    | 'reconcile_plaid_account'
    | 'unlink_plaid_account'
    | 'create_goal'
    | 'update_goal'
    | 'archive_goal'
    | 'restore_goal'
    | 'update_runway_policy'
    | 'update_transition_policy'
    | 'update_household_profile'
    | 'confirm_household_setup'
  target_record_type: string | null
  target_record_id: number | null
  label: string
  description: string | null
  payload: Record<string, unknown>
  before_snapshot: Record<string, unknown>
  after_snapshot: Record<string, unknown>
  operation_key: string | null
  operation_version: number | null
  source_text?: string | null
  source_start?: number | null
  source_end?: number | null
  dependencies?: number[]
  applied_at?: string | null
  canceled_at?: string | null
  status?: 'pending' | 'applied' | 'canceled'
  manual_section?: 'Budget' | 'My Profile'
  review_fields?: Array<{
    label: string
    before: string
    after: string
  }> | null
}

export type MiaActionDraft = {
  record_scope?: string
  scope_note?: string | null
  id: number
  status: 'pending' | 'partially_applied' | 'applied' | 'canceled'
  draft_type: 'budget_edit' | 'household_setup' | 'income_schedule' | 'debt_plan' | 'asset_plan' | 'goal_plan' | 'action_plan'
  year: number
  title: string
  summary: string
  rationale: string | null
  source_prompt: string | null
  created_at: string | null
  applied_at: string | null
  canceled_at: string | null
  impact?: {
    scope?: string
    before_monthly_income?: number
    after_monthly_income?: number
    before_monthly_outflow?: number
    after_monthly_outflow?: number
    before_baseline_surplus?: number
    after_baseline_surplus?: number
  } | null
  setup_coverage_after_apply?: WorkspaceSetupStatus | null
  applied_item_count?: number
  canceled_item_count?: number
  remaining_item_count?: number
  suggested_selected_item_ids?: number[]
  items: MiaActionItem[]
}

export type AnnualBudgetPlan = {
  year: number
  months: BudgetMonth[]
  rows: BudgetCategoryRow[]
  monthly_income: Record<number, number>
  monthly_debt_minimums: number
  monthly_debt_minimums_known?: boolean
  income_sources: IncomeTimelineSource[]
  annual_outlook: AnnualOutlook
  pending_transaction_drafts: TransactionDraft[]
  pending_transaction_drafts_meta?: { total_count: number; returned_count: number; limit: number; truncated: boolean }
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
  retained_after_transition?: boolean
  active?: boolean
}

export type IncomeTimelineSource = {
  id: number
  label: string
  source_type: string
  base_amount: number
  base_cadence: string
  starts_on?: string | null
  ends_on?: string | null
  active?: boolean
  timeline_status?: 'current' | 'future' | 'ended' | 'archived'
  current_monthly_amount?: number
  schedule_entries: IncomeScheduleEntry[]
}

export type IncomeSourceInput = {
  label: string
  source_type: string
  amount: number | string
  cadence: string
  starts_on: string
}

export type AnnualOutlookMonth = {
  period_id: number
  label: string
  starts_on: string
  income: number
  category_plan: number
  debt_minimums: number
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
  retained_after_transition?: boolean
}

export type BudgetStackKey = 'non_discretionary' | 'discretionary' | 'sinking_expected' | 'sinking_unexpected'

export type BudgetData = {
  financial_generation?: number
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
    net_worth: number | null
    liquid_net_worth: number | null
    liquid_net_worth_available?: boolean
    debt_balance_known?: boolean
    debt_minimums_known?: boolean
    ten_year_surplus_capacity?: number | null
    monthly_surplus_available?: number | null
    retirement_projection?: number
    monthly_wealth_building?: number
  }
  milestones: Array<{
    kind: 'progress' | 'debt_remaining' | 'status'
    label: string
    current: number
    target: number
    unit: string
    status: string
  }>
  guidance: string
}

export type OptionalityData = {
  available?: boolean
  unavailable_reason?: string
  scenario: string
  question: string
  target_runway_months: number
  current_runway_months: number | null
  monthly_gap: number | null
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

export type MiaAnswerPresentation = {
  version: 1
  kind: 'read_only_answer'
  basis: 'saved_household' | 'saved_household_plus_scenario' | 'scenario_only'
  lead: string
  sections: Array<{
    id: string
    title: string
    body: string
  }>
  scenario?: {
    values: Array<{
      label: string
      display_value: string
    }>
  }
}

export type MiaMessage = {
  setup_help?: { available: boolean } | null
  financial_restart?: { available: boolean; state: 'review_available' | 'owner_required' | 'unavailable' } | null
  id?: number
  client_id?: string
  role: 'assistant' | 'user'
  author: string
  content: string
  attachments?: MiaMessageAttachment[]
  presentation?: MiaAnswerPresentation
  citations?: Array<{
    title: string
    kind: AdminContentItemKind
    item_version: number
    pack_name: string
    pack_version: number
    reason: string
  }>
  created_at?: string
}

export type MiaMessagesData = {
  historical_message_count?: number
  messages: MiaMessage[]
  oldest_message_id: number | null
  older_message_count: number
  has_older_messages: boolean
  quick_prompts: string[]
  disclaimer: string
}

export type HouseholdMemoryCategory = 'goal' | 'preference' | 'constraint' | 'habit' | 'coaching_style' | 'follow_up'
export type HouseholdMemoryStatus = 'pending_confirmation' | 'user_confirmed' | 'rejected' | 'expired'
export type HouseholdMemory = {
  context_paused_by_restart?: boolean
  id: number
  category: HouseholdMemoryCategory
  status: HouseholdMemoryStatus
  sensitivity: 'ordinary' | 'sensitive'
  visibility: 'private'
  display_value: string
  structured_value: Record<string, unknown>
  owned_by_current_user: boolean
  owner_name: string
  source_kind: 'manual_profile' | 'mia_command'
  confirmation_fingerprint: string | null
  confirmed_at: string | null
  expires_at: string | null
  created_at: string
  updated_at: string
}
export type MiaMemoryData = {
  memories: HouseholdMemory[]
  personalization: { paused: boolean; paused_at: string | null }
  policy: { source: string; financial_truth: string; coach_visibility: false }
}
export type HouseholdMemoryInput = {
  category: HouseholdMemoryCategory
  display_value: string
  sensitivity: 'ordinary' | 'sensitive'
  confirmed?: boolean
  request_key?: string
}

export type UserRole = 'admin' | 'coach' | 'participant'
export type InvitationStatus = 'pending' | 'accepted' | 'revoked'
export type AdminCohortStatus = 'draft' | 'enrolling' | 'active' | 'completed' | 'archived'

export type PersonaPhraseContext = 'greeting' | 'verified_milestone' | 'emotional_support' | 'repeated_pattern' | 'routine' | 'general' | 'crisis'
export type PersonaPhraseFrequency = 'very_rare' | 'rare' | 'sparing' | 'as_needed'
export type PersonaToneTrait = 'warm' | 'direct' | 'respectful' | 'calm' | 'encouraging' | 'candid' | 'patient' | 'concise' | 'practical' | 'reassuring' | 'lighthearted' | 'formal' | 'clear' | 'unhurried'
export type PersonaEnergyStyle = 'Calm and focused.' | 'Calm, clear, and concise.' | 'Steady and reassuring.' | 'Warm and encouraging.' | 'Direct and energetic.' | 'Quiet and unhurried.'
export type PersonaAccountabilityStyle = "Name choices and patterns clearly while protecting the participant's dignity." | 'Ask reflective questions before naming a pattern.' | 'Be direct about tradeoffs while staying respectful.' | 'Use gentle accountability and one practical next step.' | 'Keep accountability firm, calm, and specific.'
export type PersonaLanguageStyle = 'Use plain language.' | 'Keep the next step concrete.' | 'Use short sentences and concrete questions.' | 'Prefer conversational language.' | 'Keep the tone professional and formal.' | 'Use light humor only when the situation is not sensitive.' | 'Be concise and avoid unnecessary jargon.' | 'Explain unfamiliar financial terms briefly.'

export type PersonaConfiguration = {
  version: 1
  identity: {
    assistant_name: string
    human_coach_name: string
    human_coach_title: string
    assistant_relationship: string
    disclosure: string
    audience: string
    client_term: string
  }
  voice: {
    tone_traits: PersonaToneTrait[]
    energy: PersonaEnergyStyle
    accountability_style: PersonaAccountabilityStyle
    language_style: PersonaLanguageStyle[]
  }
  coaching: {
    philosophy: string
    method: string
    principles: string[]
    do: string[]
    do_not: string[]
  }
  culture: {
    locale_label: string
    context: string
    local_realities: string[]
    references: string[]
  }
  phrases: Array<{
    artifact_id?: string
    provenance?: 'coach_authored' | 'participant_supplied' | 'approved_source'
    source_user_id?: number
    source_role_at_capture?: UserRole
    fingerprint?: string
    text: string
    meaning: string
    allowed_contexts: PersonaPhraseContext[]
    prohibited_contexts: PersonaPhraseContext[]
    frequency: PersonaPhraseFrequency
    caution: string
  }>
  curriculum: {
    guidance: Array<{ title: string; content: string }>
    scripts: Array<{ title: string; steps: string[] }>
    examples: Array<{ participant: string; assistant: string }>
  }
  response_shape: {
    min_sentences: number
    max_sentences: number
    max_characters: number
    plain_text_only: boolean
    validate_before_coaching: boolean
    next_move_required: boolean
  }
}

export type AdminPersonaStatus = 'draft' | 'published' | 'archived'

export type AdminPersonaUser = {
  full_name: string
  id?: number
  email?: string
}

export type AdminPersonaVersion = {
  id: number
  number: number
  digest: string
  content_manifest_digest: string
  phrase_manifest_digest?: string
  publication_digest: string
  release_gate_version?: 'gate_v1' | 'gate_v2'
  release_manifest_digest?: string | null
  audience_digest?: string | null
  release_evidence_digest?: string | null
  behavioral_preview_digest?: string | null
  phrase_audience_attestation_digests?: string[]
  release_evidence_schema?: 'persona_release_evidence_v2' | 'persona_release_evidence_v3' | null
  published_at: string
  published_by: AdminPersonaUser
  config?: PersonaConfiguration
  restored_from_version?: null | {
    id: number
    number: number
  }
  restore_to_draft_allowed?: boolean
  restore_blocked_reason?: 'current_version' | 'draft_already_matches' | 'draft_unavailable' | 'persona_archived' | 'edit_permission_required' | null
  content_packs?: AdminContentPackVersion[]
}

export type AdminContentItemKind = 'guidance' | 'script' | 'example' | 'phrase' | 'culture' | 'finance_reference'
export type AdminContentPackKind = 'voice_culture' | 'coaching_method' | 'finance_reference'
export type AdminContentScope = 'coach' | 'platform'
export type AdminContentSourceStatus = 'upload_cleanup_failed' | 'queued' | 'processing' | 'needs_review' | 'failed' | 'deletion_pending' | 'deletion_failed' | 'source_deleted'
export type AdminContentSourceUrlIntakeStatus = 'queued' | 'fetching' | 'staged' | 'registering' | 'registered' | 'failed' | 'cleanup_pending' | 'cleanup_failed' | 'deleted'

export type AdminContentSourceCandidate = {
  id: number
  source_id: number
  position: number
  status: 'proposed' | 'accepted' | 'rejected' | 'superseded'
  title: string
  kind: AdminContentItemKind
  content: string
  topics: string[]
  evidence_locator: Record<string, string | number>
  evidence_excerpt: string
  revision: number
  digest: string
  safety_code: string | null
  accepted_content_item_id: number | null
  accepted_content_item_version_id: number | null
  accepted_content_item_version_kind: AdminContentItemKind | null
  accepted_content_item_version_content: string | null
  reviewed_at: string | null
  updated_at: string
}

export type AdminContentSource = {
  id: number
  scope: AdminContentScope
  filename: string
  content_type: string
  byte_size: number
  checksum_sha256: string
  ingestion_method?: 'upload' | 'url_snapshot'
  status: AdminContentSourceStatus
  generation: number
  source_available: boolean
  error: string | null
  error_code: string | null
  source_delete_error_code: string | null
  processing_metadata: Record<string, string | number>
  processed_at: string | null
  source_deleted_at: string | null
  created_at: string
  updated_at: string
  url_snapshot?: null | {
    intake_id: number
    redirect_count: number
    fetched_at: string | null
    cleanup_required: boolean
  }
  permissions: {
    edit_candidates: boolean
    review_candidates: boolean
    download: boolean
    reprocess: boolean
    delete: boolean
  }
  current_attempt: null | {
    id: number
    generation: number
    status: string
    error: string | null
    error_code: string | null
  }
  candidates: AdminContentSourceCandidate[]
}

export type AdminContentSourceCollectionPermissions = {
  upload_coach: boolean
  upload_platform: boolean
  retry_cleanup: boolean
  url_intake_enabled?: boolean
}

export type AdminContentSourceUrlIntake = {
  id: number
  scope: AdminContentScope
  status: AdminContentSourceUrlIntakeStatus
  source_id: number | null
  error_code: string | null
  error: string | null
  cleanup_retryable: boolean
  redaction_allowed?: boolean
  redaction_pending?: boolean
  redirect_count: number
  created_at: string
  completed_at: string | null
}

export type AdminContentSourceUrlIntakeCapability = {
  enabled: boolean
  available?: boolean
}

export type AdminContentSourceUrlIntakeCollection = {
  intakes: AdminContentSourceUrlIntake[]
  url_intake?: AdminContentSourceUrlIntakeCapability
}

export type AdminApprovedPhrase = {
  text: string
  meaning: string
  allowed_contexts: PersonaPhraseContext[]
  prohibited_contexts: PersonaPhraseContext[]
  frequency: PersonaPhraseFrequency
  caution: string
}

export type AdminPhraseProposal = {
  id: number
  source_id: number
  source_label: string
  content_item_version_id: number
  status: 'draft' | 'submitted' | 'rejected' | 'superseded'
  phrase: AdminApprovedPhrase
  revision: number
  digest: string
  submitted_at: string | null
  superseded_at: string | null
  proposed_by: { id: number; full_name: string }
  attestation: null | {
    decision: 'approved' | 'rejected'
    self_review: boolean
    reviewed_at: string
    reviewed_by: { id: number; full_name: string }
  }
  promotion_count: number
  permissions: {
    edit: boolean
    submit: boolean
    review: boolean
    promote: boolean
  }
}

export type AdminPhraseProposalCollectionPermissions = {
  view: boolean
  propose: boolean
  review: boolean
  promote: boolean
}

export type AdminPhrasePromotion = {
  id: number
  persona_id: number
  proposal_id: number
  artifact_id: string
  phrase: AdminApprovedPhrase
  source_label: string
  promoted_at: string
  promoted_by: { id: number; full_name: string }
}

export type AdminContentItemVersion = {
  id: number
  item_id: number
  title: string
  kind: AdminContentItemKind
  content: string
  always_on: boolean
  version: number
  digest: string
  approved_at: string
}

export type AdminContentItem = {
  id: number
  title: string
  scope: AdminContentScope
  kind: AdminContentItemKind
  always_on: boolean
  draft_content: string | null
  draft_revision: number | null
  draft_digest: string | null
  archived: boolean
  editable: boolean
  approvable: boolean
  source_reviewed_phrase: boolean
  current_approved_version: AdminContentItemVersion | null
  versions: AdminContentItemVersion[]
  has_unapproved_changes: boolean
  updated_at: string
}

export type AdminContentPackVersion = {
  id: number
  pack_id: number
  name: string
  description: string
  scope: AdminContentScope
  pack_kind: AdminContentPackKind
  version: number
  digest: string
  published_at: string
  items?: AdminContentItemVersion[]
}

export type AdminContentPack = {
  id: number
  name: string
  description: string
  scope: AdminContentScope
  pack_kind: AdminContentPackKind
  draft_revision: number | null
  draft_manifest_digest: string | null
  archived: boolean
  editable: boolean
  publishable: boolean
  draft_items: AdminContentItemVersion[]
  current_published_version: AdminContentPackVersion | null
  versions: AdminContentPackVersion[]
  has_unpublished_changes: boolean
  item_updates_available: boolean
  update_available: boolean
  updated_at: string
}

export type AdminPersonaAssignment = {
  id: number
  cohort: {
    id: number
    name: string
    status: AdminCohortStatus
  }
  persona: {
    id: number
    name: string
  }
  published_version: AdminPersonaVersion
  assigned_at: string
  updated_at: string
  assigned_by: AdminPersonaUser
}

export type AdminPersonaPermissions = {
  read: boolean
  edit: boolean
  publish: boolean
  assign: boolean
  archive: boolean
  restore: boolean
}

export type AdminPersonaReleasePermissions = {
  manage_cases: boolean
  run_evaluation: boolean
  review_evaluations: boolean
  review_phrase_audiences: boolean
  publish: boolean
  sole_owner_self_review: boolean
  publication_needed: boolean
}

export type AdminPersonaReleaseAudience = {
  schema: string
  audience: string
  client_term: string
  culture: PersonaConfiguration['culture']
}

export type AdminPersonaEvaluationAssertion = {
  type: 'includes' | 'excludes' | 'includes_any' | 'excludes_any' | 'max_chars' | 'not_fallback' | 'excludes_configured_phrases' | 'no_unapproved_cultural_language'
  value?: string | number
  values?: string[]
}

export type AdminPersonaEvaluationCase = {
  id: number | null
  system_key: string | null
  name: string
  kind: 'system' | 'custom'
  prompt: string
  assertions: AdminPersonaEvaluationAssertion[]
  required: boolean
  active: boolean
  retired_at: string | null
  retired_by: AdminPersonaUser | null
  retirement_digest: string | null
  retirement_valid: boolean
  digest: string
  request_id?: string | null
  created_at: string | null
}

export type AdminPersonaEvaluationCaseContract = {
  name_max_chars: number
  prompt_max_chars: number
  max_active_custom_cases: number
  assertion_types: AdminPersonaEvaluationAssertion['type'][]
  assertions_min: number
  assertions_max: number
  assertion_value_max_chars: number
  assertion_values_max: number
  max_chars_range: { min: number; max: number }
}

export type AdminPersonaEvaluationApproval = {
  id: number
  decision: 'approved' | 'rejected'
  run_digest: string
  approval_digest: string
  self_review: boolean
  reviewer: AdminPersonaUser
  reviewer_role?: string
  reviewer_authority_digest?: string
  reviewed_at: string
}

export type AdminPersonaEvaluationResult = {
  id: number
  case: AdminPersonaEvaluationCase
  status: 'passed' | 'failed'
  output: string
  assertion_results: Array<{ type: AdminPersonaEvaluationAssertion['type']; passed: boolean }>
  adapter_metadata: Record<string, unknown>
  fallback_only: boolean
  digest: string
}

export type AdminPersonaEvaluationRun = {
  id: number
  candidate_id: number
  candidate_digest: string
  request_id: string
  status: 'pending' | 'running' | 'passed' | 'failed' | 'error'
  adapter_kind: string
  cases_digest: string
  run_digest: string | null
  passed: boolean
  started_at: string | null
  enqueued_at?: string | null
  completed_at: string | null
  requested_by: AdminPersonaUser | null
  approval: AdminPersonaEvaluationApproval | null
  results?: AdminPersonaEvaluationResult[]
  execution: {
    active_lease: boolean
    recoverable: boolean
    heartbeat_at: string | null
    lease_expires_at: string | null
    poll_after_ms: number | null
    retry_action: 'replay_same_request' | null
  }
}

export type AdminPersonaAudienceReview = {
  artifact_id: string
  artifact_fingerprint: string
  decision: 'approved' | 'rejected' | null
  reviewed: boolean
  review_state: 'approved' | 'rejected' | 'stale_authority' | 'invalid' | 'missing'
  authority_snapshot_valid: boolean
  authority_current: boolean
  refresh_required: boolean
  self_review: boolean
  reviewer: AdminPersonaUser | null
  reviewer_role?: string
  reviewer_authority_digest?: string
  reviewed_at: string | null
  attestation_digest: string | null
  phrase: AdminApprovedPhrase
  provenance: {
    kind: 'coach_authored' | 'participant_supplied' | 'approved_source'
    source_user_id: number | null
    source_role_at_capture: UserRole | null
  }
}

export type AdminPersonaAudienceAttestation = {
  id: number
  candidate_id: number
  artifact_id: string
  artifact_fingerprint: string
  audience_digest: string
  decision: 'approved' | 'rejected'
  self_review: boolean
  reviewer: AdminPersonaUser | null
  reviewer_role?: string
  reviewer_authority_digest?: string
  attestation_digest: string
  reviewed_at: string
}

export type AdminPersonaBehavioralPreviewEvidence = {
  id: number
  candidate_id: number
  candidate_digest: string
  config_digest: string
  content_manifest_digest: string
  phrase_manifest_digest: string
  prompt: string
  output: string
  source: 'live_model'
  model: string
  provider_request_id?: string | null
  privacy_scope: 'no_saved_participant_or_household_data'
  context_digest: string
  generated_by: AdminPersonaUser
  generated_at: string
  digest: string
  valid: boolean
}

export type AdminPersonaReleaseReadiness = {
  gate_version: 'gate_v2'
  ready: boolean
  candidate: null | {
    id: number
    manifest_digest: string
    audience_digest: string
    audience_snapshot: AdminPersonaReleaseAudience
    draft_revision: number
    sealed_at: string
  }
  evaluation_run: null | Pick<AdminPersonaEvaluationRun, 'id' | 'request_id' | 'status' | 'adapter_kind' | 'run_digest' | 'passed' | 'completed_at' | 'requested_by' | 'execution'>
  behavioral_preview_evidence: AdminPersonaBehavioralPreviewEvidence | null
  approval: null | (AdminPersonaEvaluationApproval & { valid: boolean })
  phrase_audience_reviews: AdminPersonaAudienceReview[]
  blockers: string[]
  permissions: AdminPersonaReleasePermissions
  required_evaluation_cases: AdminPersonaEvaluationCase[]
  evaluation_case_contract: AdminPersonaEvaluationCaseContract
}

export type AdminPersonaSummary = {
  id: number
  name: string
  description: string
  role: string | null
  status: AdminPersonaStatus
  owner: AdminPersonaUser
  published_version: AdminPersonaVersion | null
  visible_assignment_count: number
  updated_at: string
  permissions: AdminPersonaPermissions
  draft_revision?: number
  has_unpublished_changes?: boolean
  preview_required?: boolean
  release_gate_version?: 'gate_v1' | 'gate_v2'
  release_readiness?: AdminPersonaReleaseReadiness
}

export type AdminPersonaPreviewRecord = {
  digest: string
  draft_revision: number
  generated_at: string
}

export type AdminPersonaDetail = AdminPersonaSummary & {
  guardrails: {
    editable: false
    source: string
    rules: string[]
  }
  versions: AdminPersonaVersion[]
  assignments: AdminPersonaAssignment[]
  draft?: PersonaConfiguration
  phrase_artifact_access?: {
    can_add: boolean
    artifacts: Array<{
      artifact_id: string
      provenance: 'coach_authored' | 'participant_supplied' | 'approved_source'
      source_role_at_capture: UserRole | null
      source_label: string
      can_edit: boolean
      can_move: boolean
      can_remove: boolean
      locked: boolean
      locked_reason: string | null
    }>
  }
  approved_phrase_promotions?: Array<{
    id: number
    artifact_id: string
    phrase: AdminApprovedPhrase
    source_label: string
    active: boolean
    can_restore: boolean
    promoted_at: string
  }>
  preview?: AdminPersonaPreviewRecord | null
  content_packs?: AdminContentPackVersion[]
}

export type AdminPersonaSetupChange = {
  group: string
  path: string
  label: string
  before: unknown
  after: unknown
  source_basis: 'coach_quote' | 'mia_drafted'
  evidence_quote: string
}

export type AdminPersonaSetupProposal = {
  id: number
  status: 'pending' | 'applied' | 'rejected' | 'superseded' | 'stale'
  base_draft_revision: number
  base_config_digest: string
  proposal_digest: string
  operations: Array<Record<string, unknown>>
  before_state: { description: string; draft_config: PersonaConfiguration }
  after_state: { description: string; draft_config: PersonaConfiguration }
  grouped_changes: Array<{ group: string; changes: AdminPersonaSetupChange[] }>
  created_at: string
  resolved_at: string | null
}

export type AdminPersonaSetupTurn = {
  id: number
  position: number
  status: 'processing' | 'ready' | 'failed' | 'stale'
  user_message: string
  assistant_message: string | null
  error_code: string | null
  created_at: string
}

export type AdminPersonaSetupSession = {
  id: number
  persona_id: number
  workspace_id: number
  status: 'active' | 'completed' | 'abandoned'
  base_draft_revision: number
  base_config_digest: string
  last_activity_at: string
  stale: boolean
  turns_truncated?: boolean
  turns: AdminPersonaSetupTurn[]
  proposal: AdminPersonaSetupProposal | null
}

export type AdminPersonaBehavioralPreviewStatus = 'not_requested' | 'ready' | 'safety_only' | 'unavailable'
export type AdminPersonaBehavioralPreviewSource =
  | 'not_requested'
  | 'live_model'
  | 'deterministic_safety'
  | 'deterministic_fallback'
  | 'verified_deterministic'
  | 'model_unavailable'
  | 'preview_error'

export type AdminPersonaPreview = {
  persona_id: number
  draft_revision: number
  digest: string
  rendered_instructions: string
  status: AdminPersonaBehavioralPreviewStatus
  source: AdminPersonaBehavioralPreviewSource
  sample_prompt: string | null
  sample_reply: string | null
  notice: string
  warnings: string[]
  guardrails_applied: boolean
  generated_at: string
}

export type AdminPersonaPreviewResponse = {
  preview: AdminPersonaPreview
  behavioral_preview_evidence: AdminPersonaBehavioralPreviewEvidence | null
  persona: AdminPersonaDetail
}

export type AdminPersonaPublicationResponse = {
  persona: AdminPersonaDetail
  published_version: AdminPersonaVersion & { config: PersonaConfiguration }
}

export type AdminPersonaVersionResponse = {
  persona: AdminPersonaSummary
  version: AdminPersonaVersion
}

export type AdminPersonaAssignableCohort = {
  id: number
  name: string
  status: AdminCohortStatus
  assignable: boolean
  blocked_reason: string | null
  persona_assignment: AdminPersonaAssignment | null
}

export type AdminPersonaCreateInput = {
  name?: string
  description?: string
  draft_config?: PersonaConfiguration
}

export type AdminPersonaUpdateInput = {
  draft_revision: number
  description?: string
  draft_config?: PersonaConfiguration
}

export type AdminPersonaPublishInput = {
  draft_revision: number
  preview_digest: string
  expected_published_version_id: number | null
  release_candidate_digest: string
  evaluation_run_digest: string
  evaluation_approval_digest: string
  behavioral_preview_digest: string
}

export type AdminPersonaEvaluationRunResponse = {
  evaluation_run: AdminPersonaEvaluationRun
  reconciliation?: { request_id: string; replayed: boolean; enqueued: boolean }
}

export type AdminPersonaDraftRestoreInput = {
  draft_revision: number
  expected_published_version_id: number | null
}

export type AdminPersonaDraftRestore = {
  id: number
  source_version: { id: number; number: number }
  previous_draft_revision: number
  restored_draft_revision: number
  config_digest: string
  content_manifest_digest: string
  phrase_manifest_digest: string
  restored_by: AdminPersonaUser
  restored_at: string
  digest: string
  valid: boolean
}

export type AdminPersonaDraftRestoreResponse = {
  persona: AdminPersonaDetail
  draft_restore: AdminPersonaDraftRestore
}

export type PilotSetupStatus = 'not_started' | 'started' | 'complete'

export type PilotProgress = {
  invited: boolean
  signed_in: boolean
  setup_status: PilotSetupStatus
  setup_complete: boolean
  has_pending_review_work: boolean
  last_safe_activity_at: string | null
}

export type PilotFeedbackWorkflow = 'sign_in' | 'home' | 'setup' | 'ask_mia' | 'voice' | 'budget' | 'transaction_review' | 'receipt_upload' | 'statement_upload' | 'document_upload' | 'private_document' | 'admin' | 'other'
export type PilotFeedbackStatus = 'submitted' | 'reviewed' | 'resolved'

export type PilotFeedbackInput = {
  workflow: PilotFeedbackWorkflow
  attempted: string
  expected: string
  actual: string
  screenshot?: File | null
  share_with_support?: boolean
}

export type PilotFeedbackReceipt = {
  support_sharing_granted?: boolean
  support_access_available?: boolean
  id: number
  workflow: PilotFeedbackWorkflow
  screenshot_attached: boolean
  status: PilotFeedbackStatus
  created_at: string
}

export type AdminPilotFeedbackSummary = PilotFeedbackReceipt & {
  updated_at: string
  reporter: {
    id: number
    email: string
    full_name: string
  }
}

export type AdminPilotFeedbackDetail = AdminPilotFeedbackSummary & {
  attempted: string
  expected: string
  actual: string
  screenshot: null | {
    filename: string
    content_type: string
    byte_size: number
  }
}

export type AdminPilotFeedbackCounts = Record<PilotFeedbackStatus, number>

export type AdminPilotFeedbackScreenshotUrl = {
  url: string
  download_url: string
  expires_in: number
  filename: string
  content_type: string
}

export type CurrentUser = {
  enterprise_access?: { can_configure: boolean; organizations: Array<{ id: number; name: string; it_admin: boolean }> }
  id: number
  auth_provider?: 'clerk' | 'workos'
  auth_subject?: string
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
  coach_workspaces?: CoachWorkspaceSummary[]
  active_coach_workspace?: CoachWorkspaceSummary | null
}

export type CoachWorkspaceSummary = {
  id: number
  name: string
  slug: string
  membership_role: 'owner' | 'editor' | 'reviewer' | 'viewer' | 'platform_admin' | null
  coach_profile: {
    display_name: string
    title: string
    bio: string
  } | null
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
  operational_summary: {
    available: boolean
    period_days: number
    mia_requests: number | null
    mia_failures: number | null
    average_mia_latency_ms: number | null
    uploads: number | null
    upload_failures: number | null
    participants_active: number | null
  }
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
    } & PilotProgress
  }>
}

export type CohortExperienceDraft = {
  schema_version: 1
  optional_modules: {
    cfo_filter: boolean
    optionality: boolean
  }
}

export type CohortExperienceVersion = {
  id: number
  number: number
  digest: string
  published_at: string
  published_by: { id: number; full_name: string }
  config?: CohortExperienceDraft
  restored_from_version?: null | { id: number; number: number }
}

export type CohortExperienceConfiguration = {
  cohort: {
    id: number
    name: string
    status: AdminCohortStatus
    participant_count: number
  }
  draft: CohortExperienceDraft
  draft_revision: number
  preview_required: boolean
  preview: null | { digest: string; draft_revision: number; generated_at: string }
  published_version: CohortExperienceVersion | null
  versions: CohortExperienceVersion[]
  permissions: { edit: boolean; review: boolean; publish: boolean; rollback: boolean }
}

export type CohortExperiencePreview = {
  digest: string
  draft_revision: number
  generated_at: string
  modules: ExperienceCapability[]
}

export type CohortReleaseReadinessCheck = {
  key: string
  label: string
  ready: boolean
  detail: string | null
}

export type CohortReleaseCandidate = {
  manifest_schema: string
  bundle_digest: string
  assignment_id: number | null
  persona_version_id: number | null
  experience_version_id: number | null
  brand_mode: string
  brand_version_id: number | null
  brand_snapshot_digest: string
  registry_digest: string
  registry_version: number | null
  expected_latest_release_id: number | null
  seal_needed: boolean
  ready: boolean
  blockers: string[]
  warnings: string[]
  checks: CohortReleaseReadinessCheck[]
}

export type CohortReleaseRecord = {
  id: number
  release_number: number
  event_type: 'release' | 'restore' | 'reconciliation' | string
  manifest_schema: string
  released_at: string
  actor: null | { id: number; full_name: string }
  actor_user_id: number | null
  bundle_digest: string
  source_release_id: number | null
  persona_version_id: number | null
  experience_version_id: number | null
  brand_mode: string
  brand_version_id: number | null
  brand_snapshot_digest: string
  registry_digest: string
  registry_version: number | null
  restore_allowed: boolean
  restore_reason: string | null
}

export type CohortReleaseStudio = {
  cohort: {
    id: number
    name: string
    status: AdminCohortStatus
  }
  runtime_truth: {
    changes_participant_runtime: false
    message: string
  }
  permissions: {
    view: boolean
    seal: boolean
    restore: boolean
  }
  candidate: CohortReleaseCandidate | null
  latest_release_match: boolean
  history: {
    limit: number
    total_count: number
    truncated: boolean
  }
  releases: CohortReleaseRecord[]
}

export type CohortReleaseMutationInput = {
  expected_bundle_digest: string
  expected_assignment_id: number | null
  expected_persona_version_id: number | null
  expected_experience_version_id: number | null
  expected_brand_version_id: number | null
  expected_tool_registry_digest: string
  expected_tool_registry_version: number | null
  expected_latest_release_id: number | null
}

export type CohortReleaseRestoreInput = {
  expected_latest_release_id: number
  source_bundle_digest: string
  source_persona_version_id: number | null
  source_experience_version_id: number | null
  source_brand_version_id: number | null
}

export type CohortRolloutReadiness = 'ready' | 'awaiting_acceptance' | 'revoked' | 'removed' | string

export type CohortRolloutRelease = {
  id: number
  release_number: number
  bundle_digest: string
  manifest_schema: string
  brand_mode: string
  brand_version_id: number | null
  brand_snapshot_digest: string
  integrity_valid: boolean
  runtime_compatible: boolean
  released_at: string
}

export type CohortRolloutParticipant = {
  user_id: number
  full_name: string
  readiness: CohortRolloutReadiness
  exposed: boolean | null
  effective_release: CohortRolloutRelease | null
}

export type CohortRolloutReadinessCounts = {
  ready: number
  awaiting_acceptance: number
  revoked: number
  removed: number
}

export type CohortRolloutWave = {
  id: number
  position: number
  name: string
  active: boolean
  completed: boolean
  participant_count: number
  exposed_count: number
  exposure_complete: boolean
  counts: CohortRolloutReadinessCounts
  participants: CohortRolloutParticipant[]
}

export type CohortRolloutTransition = {
  id: number
  event_type: string
  from_status: string | null
  to_status: string
  from_wave_position: number
  to_wave_position: number
  rollback_release_id: number | null
  readiness_digest: string | null
  actor: null | { id: number; full_name: string; role: string | null }
  occurred_at: string
  participant_runtime_changed: boolean
}

export type CohortRolloutRecord = {
  id: number
  status: string
  runtime_mode: string
  runtime_blocker: string | null
  target_release: CohortRolloutRelease
  baseline_release: CohortRolloutRelease | null
  rollback_release: CohortRolloutRelease | null
  rollback_candidate: CohortRolloutRelease | null
  planned_by: null | { id: number; full_name: string; role: string | null }
  planned_at: string
  activated_at: string | null
  paused_at: string | null
  completed_at: string | null
  cancelled_at: string | null
  rolled_back_at: string | null
  current_wave_position: number
  wave_count: number
  participant_count: number
  latest_transition_id: number | null
  readiness_digest: string
  next_wave_readiness_digest: string
  next_wave_position: number | null
  permissions: {
    advance: boolean
    pause: boolean
    resume: boolean
    cancel: boolean
    rollback: boolean
    advance_blockers: string[]
    rollback_blockers: string[]
  }
  waves: CohortRolloutWave[]
  transition_history: { limit: number; total_count: number; truncated: boolean }
  transitions: CohortRolloutTransition[]
  participant_runtime_changed: boolean
}

export type CohortRolloutSummary = Omit<CohortRolloutRecord, 'rollback_candidate' | 'readiness_digest' | 'next_wave_readiness_digest' | 'next_wave_position' | 'permissions' | 'waves' | 'transitions'>

export type CohortRolloutStudio = {
  cohort: {
    id: number
    name: string
    status: AdminCohortStatus
    participant_count: number
  }
  runtime_truth: {
    changes_participant_runtime: boolean
    participant_runtime_changed: boolean
    message: string
  }
  permissions: {
    view: boolean
    manage: boolean
    plan: boolean
    actor_role: string | null
    blockers: string[]
    plan_blockers: string[]
  }
  current_roster: {
    digest: string
    readiness_digest: string
    total_count: number
    counts: CohortRolloutReadinessCounts
    participants: CohortRolloutParticipant[]
  }
  latest_release: CohortRolloutRelease | null
  active_release: CohortRolloutRelease | null
  release_history: { limit: number; total_count: number; truncated: boolean }
  releases: CohortRolloutRelease[]
  history: { limit: number; total_count: number; truncated: boolean }
  open_rollout: CohortRolloutRecord | null
  rollouts: CohortRolloutSummary[]
}

export type CohortRolloutPlanInput = {
  target_release_id: number
  expected_latest_release_id: number
  expected_roster_digest: string
  waves: Array<{ name: string; user_ids: number[] }>
}

export type CohortRolloutTransitionInput = {
  expected_status: string
  expected_current_wave_position: number
  expected_latest_transition_id: number
}

export type CohortRolloutMutationResponse = {
  rollout: CohortRolloutRecord
  transition: CohortRolloutTransition
  replayed: boolean
  cohort_rollout_studio: CohortRolloutStudio
}

export type AdminInviteEmailStatus = 'hidden' | 'not_sent' | 'skipped' | 'sent' | 'failed'

export type AdminUser = CurrentUser & {
  can_resend_invitation?: boolean
  invited_by: null | {
    id: number
    email: string
    full_name: string
  }
  invite_email: {
    workspace_scoped?: boolean
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
  workspace: PilotProgress
}

export type AdminCohortInput = {
  name: string
  status: AdminCohortStatus
  starts_on?: string
  ends_on?: string
  notes?: string
  expected_updated_at?: string
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

export type PlaidHealthState = 'healthy' | 'initializing' | 'stale' | 'action_required' | 'error' | 'disconnecting' | 'disconnected'

export type PlaidItemHealth = {
  state: PlaidHealthState
  label: string
  message: string
  requires_attention: boolean
  last_successful_update_at: string | null
  stale_after: string
}

export type AdminPlaidHealth = {
  summary: {
    connected: number
    healthy: number
    attention_required: number
  }
  items: Array<{
    id: number
    household: { id: number; name: string }
    connected_by: { id: number; full_name: string; email: string }
    institution_name: string
    environment: 'sandbox' | 'production'
    status: 'active' | 'update_required' | 'error' | 'disconnecting'
    error_code: string | null
    account_count: number
    connected_at: string
    health: PlaidItemHealth
  }>
}

export type AppData = {
  workspace: WorkspaceData
  profile: ProfileData
  dashboard: DashboardData
  budget: BudgetData
  wealth: WealthData
  optionality?: OptionalityData
  cfoFilter?: CfoFilterData
  mia: MiaMessagesData
}

type AuthTokenGetter = () => Promise<string | null>

const API_BASE = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:3000'
const SAFE_READ_REQUEST_TIMEOUT_MS = 30_000
const MUTATION_REQUEST_TIMEOUT_MS = 90_000
const MIA_REQUEST_TIMEOUT_MS = 90_000
const FILE_UPLOAD_TIMEOUT_MS = 180_000
const EXTRACTION_REQUEST_TIMEOUT_MS = 300_000
const BRAND_HEX_COLOR = /^#[0-9a-f]{6}$/
const BRAND_COLOR_KEYS = [
  'background', 'surface', 'surface_muted', 'text', 'text_muted', 'border', 'primary', 'primary_hover', 'primary_soft',
  'accent', 'on_primary', 'focus',
] as const
const BRAND_DISPLAY_FONTS = new Set(['cormorant_garamond', 'lora', 'merriweather', 'playfair_display', 'source_serif_4', 'system_serif'])
const BRAND_BODY_FONTS = new Set(['inter', 'montserrat', 'nunito_sans', 'source_sans_3', 'system_sans'])
let authTokenGetter: AuthTokenGetter | null = null
let activeCoachWorkspaceId = readStoredCoachWorkspaceId()
let activeParticipantCohortId: number | null = null
let apiActorIdentity: string | null = null
let apiContextGeneration = 0
let apiFinancialGeneration: number | null = null
export function getApiFinancialGeneration() { return apiFinancialGeneration ?? 0 }
const financialPictureListeners = new Set<(generation: number) => void>()
export function subscribeFinancialPictureChanges(listener: (generation: number) => void) {
  financialPictureListeners.add(listener)
  return () => { financialPictureListeners.delete(listener) }
}
class FinancialPictureChangedError extends Error {}
function financialDataPath(path: string) {
  if (/^\/api\/v1\/setup_help(\/|\?|$)/.test(path)) return !path.startsWith('/api/v1/setup_help/restart/')
  return /^\/api\/v1\/(workspace|budget|budget_categories|budget_allocations|income_sources|income_schedule_entries|debts|accounts|goals|profile|household_memories|mia_memory_settings|document_imports|financial_baseline|source_review_accounts|source_reviews|transaction_drafts|mia_action_drafts|spending_report|mia|plaid)(\/|\?|$)/.test(path)
}
function checkedFinancialReply(generation: number | null, expected: number | null) {
  if (generation === null || expected === null || generation === expected) return
  if (generation > expected) for (const listener of financialPictureListeners) listener(generation)
  throw new FinancialPictureChangedError('Your household financial picture changed. Refresh the current workspace before continuing.')
}
function financialResponseGeneration(response: Response) {
  const raw = response.headers.get('X-Financial-Generation')
  if (raw === null || !/^\d+$/.test(raw)) return null
  const value = Number(raw)
  return Number.isSafeInteger(value) ? value : null
}

export function setApiFinancialGeneration(generation: number | null) {
  if (generation !== null && (!Number.isSafeInteger(generation) || generation < 0)) throw new Error('The financial picture version is invalid.')
  if (generation === apiFinancialGeneration) return
  apiFinancialGeneration = generation
  apiContextGeneration += 1
}

type ApiFetchSettings = {
  timeoutMs?: number
  timeoutMessage?: string
}

class ApiDeadlineError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'ApiDeadlineError'
  }
}

export type ApiErrorConflict = Record<string, unknown>

export class ApiRequestError extends Error {
  readonly status: number
  readonly code: string | null
  readonly errors: string[]
  readonly conflicts: ApiErrorConflict[]
  readonly payload: Record<string, unknown>

  constructor(
    message: string,
    options: {
      status: number
      code?: string | null
      errors?: string[]
      conflicts?: ApiErrorConflict[]
      payload?: Record<string, unknown>
    },
  ) {
    super(message)
    this.name = 'ApiRequestError'
    this.status = options.status
    this.code = options.code ?? null
    this.errors = options.errors ?? []
    this.conflicts = options.conflicts ?? []
    this.payload = options.payload ?? {}
  }
}

function browserHostIsLocal() {
  if (typeof window === 'undefined') return true

  return ['localhost', '127.0.0.1', '::1'].includes(window.location.hostname)
}

export function browserBrandHostname() {
  if (typeof window === 'undefined') return 'localhost'

  return window.location.hostname.trim().toLowerCase().replace(/^\[(.*)\]$/, '$1')
}

function optionalString(value: unknown) {
  return value === null || typeof value === 'string'
}

function validHttpsUrl(value: unknown) {
  if (value === null) return true
  if (typeof value !== 'string' || value.length > 2_048) return false

  try {
    const url = new URL(value)
    return url.protocol === 'https:' && Boolean(url.hostname) && !url.username && !url.password && !url.hash
  } catch {
    return false
  }
}

function isBrandConfig(value: unknown): value is BrandConfig {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const config = value as Record<string, unknown>
  const support = config.support as Record<string, unknown> | undefined
  const colors = config.colors as Record<string, unknown> | undefined
  const typography = config.typography as Record<string, unknown> | undefined
  const footer = config.footer as Record<string, unknown> | undefined

  return config.schema_version === 1
    && typeof config.product_name === 'string'
    && typeof config.short_name === 'string'
    && typeof config.organization_name === 'string'
    && typeof config.participant_role_term === 'string'
    && optionalString(config.powered_by_name)
    && ['hidden', 'header', 'footer'].includes(String(config.powered_by_placement))
    && optionalString(config.tagline)
    && optionalString(config.welcome_heading)
    && optionalString(config.welcome_description)
    && validHttpsUrl(config.logo_url)
    && validHttpsUrl(config.favicon_url)
    && Boolean(support)
    && optionalString(support?.label)
    && optionalString(support?.email)
    && validHttpsUrl(support?.url)
    && Boolean(colors)
    && BRAND_COLOR_KEYS.every((key) => typeof colors?.[key] === 'string' && BRAND_HEX_COLOR.test(String(colors[key])))
    && Boolean(typography)
    && BRAND_DISPLAY_FONTS.has(String(typography?.display))
    && BRAND_BODY_FONTS.has(String(typography?.body))
    && Boolean(footer)
    && optionalString(footer?.text)
    && validHttpsUrl(footer?.privacy_url)
    && validHttpsUrl(footer?.terms_url)
}

function parsePublicBrandResponse(value: unknown): PublicBrandResponse {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('The coaching program returned an invalid brand configuration.')
  const payload = value as Record<string, unknown>
  if (!isBrandConfig(payload.brand) || typeof payload.available !== 'boolean' || typeof payload.source !== 'string') {
    throw new Error('The coaching program returned an invalid brand configuration.')
  }

  return {
    brand: payload.brand,
    source: payload.source,
    available: payload.available,
    workspace: payload.workspace && typeof payload.workspace === 'object' && typeof (payload.workspace as Record<string, unknown>).slug === 'string'
      ? { slug: (payload.workspace as { slug: string }).slug }
      : null,
    version: payload.version && typeof payload.version === 'object'
      && Number.isSafeInteger((payload.version as Record<string, unknown>).number)
      && typeof (payload.version as Record<string, unknown>).digest === 'string'
      ? { number: (payload.version as { number: number }).number, digest: (payload.version as { digest: string }).digest }
      : null,
    primary_domain: typeof payload.primary_domain === 'string' ? payload.primary_domain : null,
  }
}

export async function fetchPublicBrand(hostname = browserBrandHostname(), signal?: AbortSignal): Promise<PublicBrandResponse> {
  const normalizedHostname = hostname.trim().toLowerCase().replace(/^\[(.*)\]$/, '$1')
  let response: Response
  try {
    response = await fetch(`${API_BASE}/api/public/brand?hostname=${encodeURIComponent(normalizedHostname)}`, {
      signal,
      credentials: 'omit',
    })
  } catch (error) {
    if (signal?.aborted) throw error
    throw new Error(apiNetworkErrorMessage('Branding could not reach the coaching program'), { cause: error })
  }

  if (response.status !== 200 && response.status !== 404) throw await apiRequestError(response, 'Branding request failed')
  try {
    return parsePublicBrandResponse(await response.json())
  } catch (error) {
    if (error instanceof Error && error.message === 'The coaching program returned an invalid brand configuration.') throw error
    throw new Error('The coaching program returned an invalid brand configuration.', { cause: error })
  }
}

function apiNetworkErrorMessage(action: string) {
  if (import.meta.env.DEV) {
    return `${action}. The web app is configured to use ${API_BASE}. Start that API or update VITE_API_BASE_URL, then try again.`
  }

  if (!browserHostIsLocal() && /localhost|127\.0\.0\.1/.test(API_BASE)) {
    return `${action}. This workspace is temporarily unavailable. Please report the problem so the connection can be restored.`
  }

  return `${action}. Check your connection and try again. If the problem continues, use Report a problem so the team can help.`
}

export function setAuthTokenGetter(getter: AuthTokenGetter | null) {
  if (authTokenGetter !== getter) apiContextGeneration += 1
  authTokenGetter = getter
}

export function setActiveCoachWorkspaceId(workspaceId: number | null) {
  if (activeCoachWorkspaceId !== workspaceId) {
    apiContextGeneration += 1
    activeParticipantCohortId = null
    apiFinancialGeneration = null
  }
  activeCoachWorkspaceId = workspaceId
  if (typeof window === 'undefined') return

  if (workspaceId) window.localStorage.setItem('household-cfo:coach-workspace-id', String(workspaceId))
  else window.localStorage.removeItem('household-cfo:coach-workspace-id')
}

export function setApiActorIdentity(identity: string | null) {
  if (apiActorIdentity === identity) return
  apiActorIdentity = identity
  activeParticipantCohortId = null
  activeCoachWorkspaceId = null
  apiFinancialGeneration = null
  apiContextGeneration += 1
}

// A program choice stays in memory and is cleared on account/workspace changes.
// The server still authorizes every selected cohort independently.
export function setActiveParticipantCohortId(cohortId: number | null) {
  if (activeParticipantCohortId === cohortId) return
  activeParticipantCohortId = cohortId
  apiFinancialGeneration = null
  apiContextGeneration += 1
}

// Capture once before a logical operation, then assert after waits and before
// its next request. A later request must never adopt a different program.
export function captureApiOperation(): () => void {
  const generation = apiContextGeneration
  return function assertApiOperation() {
    if (generation !== apiContextGeneration) {
      throw new ApiContextChangedError('Your account or program changed. Reopen the current program before continuing.')
    }
  }
}

function readStoredCoachWorkspaceId() {
  if (typeof window === 'undefined') return null

  const parsed = Number.parseInt(window.localStorage.getItem('household-cfo:coach-workspace-id') ?? '', 10)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null
}

async function withDeadline<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  timeoutMs: number,
  timeoutMessage: string,
  callerSignal?: AbortSignal | null,
  recoveryMessage = 'Please try again.',
) {
  const controller = new AbortController()
  let deadlineReached = false
  const abortFromCaller = () => controller.abort(callerSignal?.reason)

  if (callerSignal?.aborted) abortFromCaller()
  else callerSignal?.addEventListener('abort', abortFromCaller, { once: true })

  let deadline: ReturnType<typeof globalThis.setTimeout> | undefined
  const deadlinePromise = new Promise<never>((_resolve, reject) => {
    deadline = globalThis.setTimeout(() => {
      deadlineReached = true
      reject(new ApiDeadlineError(`${timeoutMessage} ${recoveryMessage}`))
      controller.abort()
    }, timeoutMs)
  })

  try {
    return await Promise.race([operation(controller.signal), deadlinePromise])
  } catch (error) {
    if (error instanceof ApiDeadlineError) throw error
    if (deadlineReached) {
      throw new ApiDeadlineError(`${timeoutMessage} ${recoveryMessage}`, { cause: error })
    }
    throw error
  } finally {
    if (deadline !== undefined) globalThis.clearTimeout(deadline)
    callerSignal?.removeEventListener('abort', abortFromCaller)
  }
}

async function fetchWithDeadline(
  input: RequestInfo | URL,
  options: RequestInit,
  timeoutMs: number,
  timeoutMessage: string,
) {
  return withDeadline(
    (signal) => fetch(input, { ...options, signal }),
    timeoutMs,
    timeoutMessage,
    options.signal,
  )
}

async function apiFetch(path: string, options: RequestInit = {}, signal?: AbortSignal) {
  const assertCurrentContext = captureApiOperation()
  const getToken = authTokenGetter
  const workspaceId = activeCoachWorkspaceId
  const cohortId = activeParticipantCohortId
  const financialGeneration = apiFinancialGeneration
  try {
    const callerHeaders = options.headers instanceof Headers
      ? Object.fromEntries(options.headers.entries())
      : Array.isArray(options.headers)
        ? Object.fromEntries(options.headers)
        : { ...(options.headers ?? {}) }
    const safeCallerHeaders = Object.fromEntries(Object.entries(callerHeaders).filter(([name]) => !['x-brand-hostname', 'x-financial-generation'].includes(name.toLowerCase())))
    const token = getToken ? await getToken() : null
    assertCurrentContext()
    if (signal?.aborted || options.signal?.aborted) throw new DOMException('Request cancelled', 'AbortError')
    const headers = {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(workspaceId ? { 'X-Coach-Workspace-Id': String(workspaceId) } : {}),
      ...(cohortId ? { 'X-Cohort-Id': String(cohortId) } : {}),
      ...(financialGeneration === null ? {} : { 'X-Financial-Generation': String(financialGeneration) }),
      ...safeCallerHeaders,
      'X-Brand-Hostname': browserBrandHostname(),
    }
    const response = await fetch(`${API_BASE}${path}`, {
      ...options,
      headers,
      ...(signal ? { signal } : {}),
    })
    assertCurrentContext()
    if (response.status === 401 && token && typeof window !== 'undefined') {
      window.dispatchEvent(new Event('household-cfo:auth-expired'))
    }
    if (financialDataPath(path) && !path.startsWith('/api/v1/workspace')) checkedFinancialReply(financialResponseGeneration(response), financialGeneration)
    return response
  } catch (error) {
    if (error instanceof ApiContextChangedError || error instanceof FinancialPictureChangedError) throw error
    throw new Error(apiNetworkErrorMessage('API request could not reach the server'), { cause: error })
  }
}

class ApiContextChangedError extends Error {}

async function apiOperation<T>(
  path: string,
  options: RequestInit,
  settings: ApiFetchSettings,
  consume: (response: Response) => Promise<T>,
) {
  const assertCurrentContext = captureApiOperation()
  const request = async (signal?: AbortSignal) => {
    assertCurrentContext()
    const result = await consume(await apiFetch(path, options, signal))
    assertCurrentContext()
    return result
  }

  const method = (options.method ?? 'GET').toUpperCase()
  const readOnly = method === 'GET' || method === 'HEAD'
  const timeoutMs = settings.timeoutMs ?? (readOnly ? SAFE_READ_REQUEST_TIMEOUT_MS : MUTATION_REQUEST_TIMEOUT_MS)

  return withDeadline(
        request,
        timeoutMs,
        settings.timeoutMessage ?? (readOnly ? 'This request took too long.' : 'The server did not confirm whether this change finished.'),
        options.signal,
        readOnly ? 'Please try again.' : 'Refresh to check the current state before trying again.',
      )
}

async function fetchJsonResponse<T>(path: string, options: RequestInit = {}, settings: ApiFetchSettings = {}) {
  return apiOperation(path, options, settings, async (response) => {
    if (!response.ok) {
      throw await apiRequestError(response, 'API request failed')
    }

    const generationHeader = financialResponseGeneration(response)
    if (response.status === 204) return { status: response.status, payload: undefined as T, financial_generation_header: generationHeader }
    const payload = await response.json() as T
    if (financialDataPath(path) && !path.startsWith('/api/v1/workspace') && payload && typeof payload === 'object' && 'financial_generation' in payload) {
      const value = (payload as { financial_generation: unknown }).financial_generation
      if (typeof value === 'number' && Number.isSafeInteger(value)) checkedFinancialReply(value, apiFinancialGeneration)
    }
    return { status: response.status, payload, financial_generation_header: generationHeader }
  })
}

async function fetchJson<T>(path: string, options: RequestInit = {}, settings: ApiFetchSettings = {}): Promise<T> {
  return (await fetchJsonResponse<T>(path, options, settings)).payload
}

async function postJson<T>(path: string, body: unknown, settings: ApiFetchSettings = {}): Promise<T> {
  return fetchJson<T>(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }, settings)
}

async function postJsonUntilComplete<T>(path: string, body: unknown): Promise<T> {
  const assertCurrentContext = captureApiOperation()
  const maximumPolls = 60
  for (let poll = 0; poll < maximumPolls; poll += 1) {
    assertCurrentContext()
    const response = await fetchJsonResponse<T | { code?: string; retry_after_ms?: number }>(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }, {
      timeoutMs: MIA_REQUEST_TIMEOUT_MS,
      timeoutMessage: 'Your assistant took too long to finish this request.',
    })
    assertCurrentContext()

    if (response.status === 202) {
      const payload = response.payload as { code?: string; retry_after_ms?: number }
      if (payload.code !== 'mia_request_processing') {
        throw new Error('Your assistant returned an unexpected processing response. Please try again.')
      }

      const retryAfter = Math.max(100, Math.min(payload.retry_after_ms ?? 500, 2_000))
      await new Promise((resolve) => globalThis.setTimeout(resolve, retryAfter))
      continue
    }

    return response.payload as T
  }

  throw new Error('Your assistant is still working on that exact request. Wait a moment, then try again; your retry will not create a duplicate.')
}

async function responseErrorMessage(response: Response, fallback: string) {
  try {
    const payload = (await response.json()) as { error?: string; errors?: string[] }
    return payload.error ?? payload.errors?.join(', ') ?? `${fallback}: ${response.status}`
  } catch {
    return `${fallback}: ${response.status}`
  }
}

async function apiRequestError(response: Response, fallback: string) {
  let payload: {
    error?: unknown
    errors?: unknown
    code?: unknown
    conflicts?: unknown
  } = {}

  try {
    payload = (await response.json()) as typeof payload
  } catch {
    // A non-JSON failure still carries a useful HTTP status for the caller.
  }

  const errors = Array.isArray(payload.errors)
    ? payload.errors.filter((error): error is string => typeof error === 'string')
    : []
  const conflicts = Array.isArray(payload.conflicts)
    ? payload.conflicts.filter((conflict): conflict is ApiErrorConflict => (
        typeof conflict === 'object' && conflict !== null && !Array.isArray(conflict)
      ))
    : []
  const message = typeof payload.error === 'string'
    ? payload.error
    : errors.join(', ') || `${fallback}: ${response.status}`

  return new ApiRequestError(message, {
    status: response.status,
    code: typeof payload.code === 'string' ? payload.code : null,
    errors,
    conflicts,
    payload,
  })
}

export async function fetchCurrentUser(signal?: AbortSignal): Promise<CurrentUser> {
  try {
    const payload = await fetchJson<{ user: CurrentUser }>('/api/v1/auth/me', { signal })
    return payload.user
  } catch (error) {
    if (!(error instanceof ApiRequestError) || error.status !== 404 || !activeCoachWorkspaceId) throw error

    setActiveCoachWorkspaceId(null)
    const payload = await fetchJson<{ user: CurrentUser }>('/api/v1/auth/me', { signal })
    return payload.user
  }
}

export async function submitPilotFeedback(values: PilotFeedbackInput): Promise<PilotFeedbackReceipt> {
  const formData = new FormData()
  formData.append('feedback_report[workflow]', values.workflow)
  formData.append('feedback_report[attempted]', values.attempted)
  formData.append('feedback_report[expected]', values.expected)
  formData.append('feedback_report[actual]', values.actual)
  if (values.share_with_support !== undefined) formData.append('feedback_report[share_with_support]', String(values.share_with_support))
  if (values.screenshot) formData.append('screenshot', values.screenshot)

  return withDeadline(async (signal) => {
    let response: Response
    try {
      response = await apiFetch('/api/v1/pilot_feedback_reports', {
        method: 'POST',
        body: formData,
      }, signal)
    } catch (error) {
      throw new Error(apiNetworkErrorMessage('Feedback submission could not reach the API'), { cause: error })
    }

    if (!response.ok) throw new Error(await responseErrorMessage(response, 'Feedback submission failed'))

    const payload = (await response.json()) as { feedback_report: PilotFeedbackReceipt }
    return payload.feedback_report
  }, FILE_UPLOAD_TIMEOUT_MS, 'The server did not confirm whether your report was received.', undefined,
  'It may already be submitted. Keep your details and check with support before submitting again.')
}

export async function fetchMyPilotFeedback(beforeId?: number, signal?: AbortSignal): Promise<{ feedback_reports: PilotFeedbackReceipt[]; next_cursor: number | null }> {
  return fetchJson(`/api/v1/pilot_feedback_reports${beforeId ? `?before_id=${beforeId}` : ''}`, { signal })
}

export async function withdrawPilotFeedbackSupport(id: number): Promise<PilotFeedbackReceipt> {
  const payload = await fetchJson<{ feedback_report: PilotFeedbackReceipt }>(`/api/v1/pilot_feedback_reports/${id}/withdraw_support_access`, { method: 'PATCH' })
  return payload.feedback_report
}

export async function fetchAdminPilotFeedback(status: PilotFeedbackStatus | 'all' = 'submitted'): Promise<{ feedback_reports: AdminPilotFeedbackSummary[]; counts: AdminPilotFeedbackCounts }> {
  return fetchJson(`/api/v1/admin/pilot_feedback_reports?status=${encodeURIComponent(status)}`)
}

export async function fetchAdminPilotFeedbackReport(id: number): Promise<AdminPilotFeedbackDetail> {
  const payload = await fetchJson<{ feedback_report: AdminPilotFeedbackDetail }>(`/api/v1/admin/pilot_feedback_reports/${id}`)
  return payload.feedback_report
}

export async function updateAdminPilotFeedbackStatus(id: number, status: PilotFeedbackStatus): Promise<AdminPilotFeedbackDetail> {
  const payload = await fetchJson<{ feedback_report: AdminPilotFeedbackDetail }>(`/api/v1/admin/pilot_feedback_reports/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ feedback_report: { status } }),
  })
  return payload.feedback_report
}

export async function fetchAdminPilotFeedbackScreenshotUrl(id: number): Promise<AdminPilotFeedbackScreenshotUrl> {
  return fetchJson(`/api/v1/admin/pilot_feedback_reports/${id}/screenshot_url`)
}

export async function fetchAdminUsers(): Promise<AdminUser[]> {
  const payload = await fetchJson<{ users: AdminUser[] }>('/api/v1/admin/users')
  return payload.users
}

export async function fetchAdminCohorts(): Promise<AdminCohort[]> {
  const payload = await fetchJson<{ cohorts: AdminCohort[] }>('/api/v1/admin/cohorts')
  return payload.cohorts
}

export async function fetchCohortExperienceConfiguration(cohortId: number, signal?: AbortSignal): Promise<CohortExperienceConfiguration> {
  const payload = await fetchJson<{ experience_configuration: CohortExperienceConfiguration }>(
    `/api/v1/admin/cohorts/${cohortId}/experience_configuration`,
    { signal },
  )
  return payload.experience_configuration
}

export async function updateCohortExperienceConfiguration(
  cohortId: number,
  draftRevision: number,
  draftConfig: CohortExperienceDraft,
): Promise<CohortExperienceConfiguration> {
  const payload = await fetchJson<{ experience_configuration: CohortExperienceConfiguration }>(`/api/v1/admin/cohorts/${cohortId}/experience_configuration`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ experience_configuration: { draft_revision: draftRevision, draft_config: draftConfig } }),
  })
  return payload.experience_configuration
}

export async function previewCohortExperienceConfiguration(
  cohortId: number,
  draftRevision: number,
): Promise<{ preview: CohortExperiencePreview; experience_configuration: CohortExperienceConfiguration }> {
  return postJson(`/api/v1/admin/cohorts/${cohortId}/experience_configuration/preview`, {
    experience_configuration: { draft_revision: draftRevision },
  })
}

export async function publishCohortExperienceConfiguration(
  cohortId: number,
  values: { draft_revision: number; preview_digest: string; expected_published_version_id: number | null },
): Promise<{ experience_configuration: CohortExperienceConfiguration; published_version: CohortExperienceVersion }> {
  return postJson(`/api/v1/admin/cohorts/${cohortId}/experience_configuration/publish`, { experience_configuration: values })
}

export async function rollbackCohortExperienceConfiguration(
  cohortId: number,
  versionId: number,
  values: { draft_revision: number; expected_published_version_id: number | null },
): Promise<{ experience_configuration: CohortExperienceConfiguration; published_version: CohortExperienceVersion }> {
  return postJson(`/api/v1/admin/cohorts/${cohortId}/experience_configuration/versions/${versionId}/rollback`, { experience_configuration: values })
}

export function createCohortReleaseRequestId() {
  return clientRequestId()
}

export async function fetchCohortReleaseStudio(cohortId: number, signal?: AbortSignal): Promise<CohortReleaseStudio> {
  const payload = await fetchJson<unknown>(`/api/v1/admin/cohorts/${cohortId}/releases`, { signal })
  return normalizeCohortReleaseStudio(payload)
}

export async function sealCohortRelease(
  cohortId: number,
  values: CohortReleaseMutationInput,
  requestId: string,
): Promise<unknown> {
  return fetchJson(`/api/v1/admin/cohorts/${cohortId}/releases`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': requestId },
    body: JSON.stringify({ release: values }),
  })
}

export async function restoreCohortRelease(
  cohortId: number,
  sourceReleaseId: number,
  values: CohortReleaseRestoreInput,
  requestId: string,
): Promise<unknown> {
  return fetchJson(`/api/v1/admin/cohorts/${cohortId}/releases/${sourceReleaseId}/restore`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': requestId },
    body: JSON.stringify({ release: values }),
  })
}

export function createCohortRolloutRequestId() {
  return clientRequestId()
}

export async function fetchCohortRolloutStudio(cohortId: number, signal?: AbortSignal): Promise<CohortRolloutStudio> {
  const payload = await fetchJson<unknown>(`/api/v1/admin/cohorts/${cohortId}/rollouts`, { signal })
  return normalizeCohortRolloutStudio(payload)
}

export async function planCohortRollout(cohortId: number, values: CohortRolloutPlanInput, requestId: string): Promise<CohortRolloutMutationResponse> {
  return mutateCohortRollout(`/api/v1/admin/cohorts/${cohortId}/rollouts`, values, requestId)
}

export async function advanceCohortRollout(
  cohortId: number,
  rolloutId: number,
  values: CohortRolloutTransitionInput & { readiness_digest: string },
  requestId: string,
): Promise<CohortRolloutMutationResponse> {
  return mutateCohortRollout(`/api/v1/admin/cohorts/${cohortId}/rollouts/${rolloutId}/advance`, values, requestId)
}

export async function pauseCohortRollout(cohortId: number, rolloutId: number, values: CohortRolloutTransitionInput, requestId: string): Promise<CohortRolloutMutationResponse> {
  return mutateCohortRollout(`/api/v1/admin/cohorts/${cohortId}/rollouts/${rolloutId}/pause`, values, requestId)
}

export async function resumeCohortRollout(cohortId: number, rolloutId: number, values: CohortRolloutTransitionInput, requestId: string): Promise<CohortRolloutMutationResponse> {
  return mutateCohortRollout(`/api/v1/admin/cohorts/${cohortId}/rollouts/${rolloutId}/resume`, values, requestId)
}

export async function cancelCohortRollout(cohortId: number, rolloutId: number, values: CohortRolloutTransitionInput, requestId: string): Promise<CohortRolloutMutationResponse> {
  return mutateCohortRollout(`/api/v1/admin/cohorts/${cohortId}/rollouts/${rolloutId}/cancel`, values, requestId)
}

export async function rollbackCohortRollout(
  cohortId: number,
  rolloutId: number,
  values: CohortRolloutTransitionInput & { rollback_release_id: number },
  requestId: string,
): Promise<CohortRolloutMutationResponse> {
  return mutateCohortRollout(`/api/v1/admin/cohorts/${cohortId}/rollouts/${rolloutId}/rollback`, values, requestId)
}

async function mutateCohortRollout(path: string, values: CohortRolloutPlanInput | CohortRolloutTransitionInput | (CohortRolloutTransitionInput & { readiness_digest: string }) | (CohortRolloutTransitionInput & { rollback_release_id: number }), requestId: string) {
  const payload = await fetchJson<unknown>(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': requestId },
    body: JSON.stringify({ rollout: values }),
  }, {
    timeoutMs: 30_000,
    timeoutMessage: 'The rollout request took too long. Retry this reviewed action; the same request key prevents a duplicate decision.',
  })
  return normalizeCohortRolloutMutation(payload)
}

export async function fetchAdminPersonas(): Promise<AdminPersonaSummary[]> {
  const payload = await fetchJson<{ personas: AdminPersonaSummary[] }>('/api/v1/admin/personas')
  return payload.personas
}

export async function fetchAdminContentItems(): Promise<AdminContentItem[]> {
  const payload = await fetchJson<{ items: AdminContentItem[] }>('/api/v1/admin/content_items')
  return payload.items
}

export async function fetchAdminContentSources(): Promise<{ sources: AdminContentSource[]; permissions: AdminContentSourceCollectionPermissions }> {
  return fetchJson<{ sources: AdminContentSource[]; permissions: AdminContentSourceCollectionPermissions }>('/api/v1/admin/content_sources')
}

export async function fetchAdminContentSource(id: number): Promise<AdminContentSource> {
  const payload = await fetchJson<{ source: AdminContentSource }>(`/api/v1/admin/content_sources/${id}`)
  return payload.source
}

export async function fetchAdminContentSourceUrl(id: number): Promise<{ url: string; filename: string }> {
  return fetchJson<{ url: string; filename: string }>(`/api/v1/admin/content_sources/${id}/source_url`)
}

export function createAdminContentSourceUrlRequestId() {
  return clientRequestId()
}

export async function fetchAdminContentSourceUrlIntakes(scope: AdminContentScope = 'coach'): Promise<AdminContentSourceUrlIntakeCollection> {
  return fetchJson<AdminContentSourceUrlIntakeCollection>(`/api/v1/admin/content_source_url_intakes?scope=${encodeURIComponent(scope)}`)
}

export async function fetchAdminContentSourceUrlIntake(id: number): Promise<{
  intake: AdminContentSourceUrlIntake
  url_intake?: AdminContentSourceUrlIntakeCapability
}> {
  return fetchJson(`/api/v1/admin/content_source_url_intakes/${id}`)
}

export async function createAdminContentSourceUrlIntake(values: {
  url: string
  requestId: string
  scope?: AdminContentScope
}): Promise<{
  intake: AdminContentSourceUrlIntake
  url_intake?: AdminContentSourceUrlIntakeCapability
}> {
  return postJson('/api/v1/admin/content_source_url_intakes', {
    url: values.url,
    request_id: values.requestId,
    scope: values.scope ?? 'coach',
  }, { timeoutMs: 30_000, timeoutMessage: 'Submitting the secure web source took too long.' })
}

export async function deleteAdminContentSourceUrlIntake(id: number): Promise<{
  intake: AdminContentSourceUrlIntake
  url_intake?: AdminContentSourceUrlIntakeCapability
}> {
  return fetchJson(`/api/v1/admin/content_source_url_intakes/${id}`, { method: 'DELETE' }, {
    timeoutMs: 30_000,
    timeoutMessage: 'Removing the saved address took too long. Checking its current state is recommended.',
  })
}

export async function retryAdminContentSourceUrlIntakeCleanup(id: number): Promise<AdminContentSourceUrlIntake> {
  const payload = await postJson<{ intake: AdminContentSourceUrlIntake }>(`/api/v1/admin/content_source_url_intakes/${id}/retry_cleanup`, {}, {
    timeoutMs: 30_000,
    timeoutMessage: 'Retrying private snapshot cleanup took too long. Checking its current state is recommended.',
  })
  return payload.intake
}

export async function uploadAdminContentSource(file: File, scope: AdminContentScope = 'coach'): Promise<AdminContentSource> {
  const uploadRequestId = clientRequestId()
  const contentType = contentSourceUploadType(file)
  const checksumSha256 = await fileSha256(file)
  if (!checksumSha256) throw new Error('This browser cannot verify a private upload safely.')
  const presign = await postJson<{ upload_url: string; upload_headers: Record<string, string>; upload_token: string }>(
    '/api/v1/admin/content_sources/presign',
    {
      filename: file.name,
      content_type: contentType,
      byte_size: file.size,
      checksum_sha256: checksumSha256,
      upload_request_id: uploadRequestId,
      scope,
    },
    { timeoutMs: 30_000, timeoutMessage: 'Preparing the private source upload took too long.' },
  )

  let uploadResponse: Response
  try {
    uploadResponse = await fetchWithDeadline(presign.upload_url, { method: 'PUT', headers: presign.upload_headers, body: file }, FILE_UPLOAD_TIMEOUT_MS, 'The private source upload took too long.')
  } catch (error) {
    if (error instanceof ApiDeadlineError) throw error
    throw new Error('The private source upload could not reach storage. Check your connection and try again.', { cause: error })
  }
  if (!uploadResponse.ok) throw new Error(`The private source upload failed (${uploadResponse.status}). Try again.`)

  const payload = await postJson<{ source: AdminContentSource }>('/api/v1/admin/content_sources/complete', { upload_token: presign.upload_token }, { timeoutMs: 30_000, timeoutMessage: 'Registering the private source took too long. Your file is still selected; try again.' })
  return payload.source
}

export async function reprocessAdminContentSource(id: number): Promise<AdminContentSource> {
  const payload = await postJson<{ source: AdminContentSource }>(`/api/v1/admin/content_sources/${id}/reprocess`, {})
  return payload.source
}

export async function deleteAdminContentSource(id: number): Promise<AdminContentSource> {
  const payload = await fetchJson<{ source: AdminContentSource }>(`/api/v1/admin/content_sources/${id}/source`, { method: 'DELETE' })
  return payload.source
}

export async function retryAdminContentSourceCleanups(): Promise<number> {
  const payload = await postJson<{ retried_count: number }>('/api/v1/admin/content_sources/retry_upload_cleanups', {})
  return payload.retried_count
}

export async function updateAdminContentSourceCandidate(sourceId: number, candidate: AdminContentSourceCandidate, values: Pick<AdminContentSourceCandidate, 'title' | 'kind' | 'content' | 'topics'>): Promise<AdminContentSourceCandidate> {
  const payload = await fetchJson<{ candidate: AdminContentSourceCandidate }>(`/api/v1/admin/content_sources/${sourceId}/candidates/${candidate.id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ candidate: { ...values, revision: candidate.revision, digest: candidate.digest } }),
  })
  return payload.candidate
}

export async function acceptAdminContentSourceCandidate(sourceId: number, candidate: AdminContentSourceCandidate): Promise<{ candidate: AdminContentSourceCandidate; item: AdminContentItem }> {
  return postJson(`/api/v1/admin/content_sources/${sourceId}/candidates/${candidate.id}/accept`, { candidate: { revision: candidate.revision, digest: candidate.digest } })
}

export async function rejectAdminContentSourceCandidate(sourceId: number, candidate: AdminContentSourceCandidate): Promise<AdminContentSourceCandidate> {
  const payload = await postJson<{ candidate: AdminContentSourceCandidate }>(`/api/v1/admin/content_sources/${sourceId}/candidates/${candidate.id}/reject`, { candidate: { revision: candidate.revision, digest: candidate.digest } })
  return payload.candidate
}

export async function fetchAdminContentSourcePhraseProposals(sourceId: number): Promise<{
  phrase_proposals: AdminPhraseProposal[]
  permissions: AdminPhraseProposalCollectionPermissions
}> {
  return fetchJson(`/api/v1/admin/content_sources/${sourceId}/phrase_proposals`)
}

export async function fetchAdminPhraseProposal(id: number): Promise<AdminPhraseProposal> {
  const payload = await fetchJson<{ phrase_proposal: AdminPhraseProposal }>(`/api/v1/admin/phrase_proposals/${id}`)
  return payload.phrase_proposal
}

export async function createAdminPhraseProposal(sourceId: number, values: {
  candidate_id: number
  content_item_version_id: number
  phrase: AdminApprovedPhrase
}): Promise<AdminPhraseProposal> {
  const payload = await postJson<{ phrase_proposal: AdminPhraseProposal }>(`/api/v1/admin/content_sources/${sourceId}/phrase_proposals`, { phrase_proposal: values })
  return payload.phrase_proposal
}

export async function updateAdminPhraseProposal(proposal: AdminPhraseProposal, phrase: AdminApprovedPhrase): Promise<AdminPhraseProposal> {
  const payload = await fetchJson<{ phrase_proposal: AdminPhraseProposal }>(`/api/v1/admin/phrase_proposals/${proposal.id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ phrase_proposal: { phrase, revision: proposal.revision, digest: proposal.digest } }),
  })
  return payload.phrase_proposal
}

export async function submitAdminPhraseProposal(proposal: AdminPhraseProposal): Promise<AdminPhraseProposal> {
  const payload = await postJson<{ phrase_proposal: AdminPhraseProposal }>(`/api/v1/admin/phrase_proposals/${proposal.id}/submit`, {
    phrase_proposal: { revision: proposal.revision, digest: proposal.digest },
  })
  return payload.phrase_proposal
}

export async function attestAdminPhraseProposal(proposal: AdminPhraseProposal, decision: 'approved' | 'rejected'): Promise<AdminPhraseProposal> {
  const payload = await postJson<{ phrase_proposal: AdminPhraseProposal }>(`/api/v1/admin/phrase_proposals/${proposal.id}/attestation`, {
    attestation: { decision, proposal_digest: proposal.digest },
  })
  return payload.phrase_proposal
}

export async function promoteAdminPhraseProposal(personaId: number, proposalId: number, draftRevision: number): Promise<{
  persona: AdminPersonaDetail
  phrase_promotion: AdminPhrasePromotion
}> {
  return postJson(`/api/v1/admin/personas/${personaId}/phrase_promotions`, {
    phrase_promotion: { proposal_id: proposalId, draft_revision: draftRevision },
  })
}

export async function restoreAdminPhrasePromotion(personaId: number, promotionId: number, draftRevision: number): Promise<{
  persona: AdminPersonaDetail
  phrase_promotion: AdminPhrasePromotion
}> {
  return postJson(`/api/v1/admin/personas/${personaId}/phrase_promotions/${promotionId}/restore`, {
    phrase_promotion: { draft_revision: draftRevision },
  })
}

export async function createAdminContentItem(values: {
  title: string
  scope: AdminContentScope
  kind: AdminContentItemKind
  draft_content: string
  always_on: boolean
}): Promise<AdminContentItem> {
  const payload = await postJson<{ item: AdminContentItem }>('/api/v1/admin/content_items', { item: values })
  return payload.item
}

export async function updateAdminContentItem(id: number, values: {
  title: string
  kind: AdminContentItemKind
  draft_content: string
  always_on: boolean
  draft_revision: number
}): Promise<AdminContentItem> {
  const payload = await fetchJson<{ item: AdminContentItem }>(`/api/v1/admin/content_items/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ item: values }),
  })
  return payload.item
}

export async function approveAdminContentItem(id: number, draftRevision: number, draftDigest: string): Promise<AdminContentItem> {
  const payload = await postJson<{ item: AdminContentItem }>(`/api/v1/admin/content_items/${id}/approve`, {
    item: { draft_revision: draftRevision, draft_digest: draftDigest },
  })
  return payload.item
}

export async function fetchAdminContentPacks(): Promise<AdminContentPack[]> {
  const payload = await fetchJson<{ packs: AdminContentPack[] }>('/api/v1/admin/content_packs')
  return payload.packs
}

export async function createAdminContentPack(values: {
  name: string
  description: string
  scope: AdminContentScope
  pack_kind: AdminContentPackKind
  item_version_ids: number[]
}): Promise<AdminContentPack> {
  const payload = await postJson<{ pack: AdminContentPack }>('/api/v1/admin/content_packs', { pack: values })
  return payload.pack
}

export async function updateAdminContentPack(id: number, values: {
  name: string
  description: string
  pack_kind: AdminContentPackKind
  item_version_ids: number[]
  draft_revision: number
}): Promise<AdminContentPack> {
  const payload = await fetchJson<{ pack: AdminContentPack }>(`/api/v1/admin/content_packs/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ pack: values }),
  })
  return payload.pack
}

export async function publishAdminContentPack(id: number, values: {
  draft_revision: number
  draft_manifest_digest: string
  expected_published_version_id: number | null
}): Promise<AdminContentPack> {
  const payload = await postJson<{ pack: AdminContentPack }>(`/api/v1/admin/content_packs/${id}/publish`, { pack: values })
  return payload.pack
}

export async function updateAdminPersonaContentPacks(personaId: number, draftRevision: number, packVersionIds: number[]): Promise<AdminPersonaDetail> {
  const payload = await fetchJson<{ persona: AdminPersonaDetail }>(`/api/v1/admin/personas/${personaId}/content_packs`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content_packs: { draft_revision: draftRevision, pack_version_ids: packVersionIds } }),
  })
  return payload.persona
}

export async function fetchAdminPersona(id: number): Promise<AdminPersonaDetail> {
  const payload = await fetchJson<{ persona: AdminPersonaDetail }>(`/api/v1/admin/personas/${id}`)
  return payload.persona
}

export async function fetchAdminPersonaReleaseReadiness(personaId: number): Promise<AdminPersonaReleaseReadiness> {
  const payload = await fetchJson<{ readiness: AdminPersonaReleaseReadiness }>(`/api/v1/admin/personas/${personaId}/release_readiness`)
  return payload.readiness
}

export async function fetchAdminPersonaEvaluationCases(personaId: number): Promise<AdminPersonaEvaluationCase[]> {
  const payload = await fetchJson<{ evaluation_cases: AdminPersonaEvaluationCase[] }>(`/api/v1/admin/personas/${personaId}/evaluation_cases`)
  return payload.evaluation_cases
}

export async function createAdminPersonaEvaluationCase(personaId: number, values: {
  request_id: string
  name: string
  prompt: string
  assertions: AdminPersonaEvaluationAssertion[]
}): Promise<{ evaluation_case: AdminPersonaEvaluationCase; reconciliation?: { request_id: string; replayed: boolean } }> {
  return postJson(`/api/v1/admin/personas/${personaId}/evaluation_cases`, { evaluation_case: values }, {
    timeoutMs: 30_000,
    timeoutMessage: 'Saving the evaluation case took too long.',
  })
}

export async function retireAdminPersonaEvaluationCase(personaId: number, caseId: number): Promise<AdminPersonaEvaluationCase> {
  const payload = await fetchJson<{ evaluation_case: AdminPersonaEvaluationCase }>(`/api/v1/admin/personas/${personaId}/evaluation_cases/${caseId}`, {
    method: 'DELETE',
  }, {
    timeoutMs: 30_000,
    timeoutMessage: 'Retiring the evaluation case took too long.',
  })
  return payload.evaluation_case
}

export async function fetchAdminPersonaEvaluationRuns(personaId: number): Promise<AdminPersonaEvaluationRun[]> {
  const payload = await fetchJson<{ evaluation_runs: AdminPersonaEvaluationRun[] }>(`/api/v1/admin/personas/${personaId}/evaluation_runs`)
  return payload.evaluation_runs
}

export async function fetchAdminPersonaEvaluationRun(personaId: number, runId: number): Promise<AdminPersonaEvaluationRun> {
  const payload = await fetchJson<{ evaluation_run: AdminPersonaEvaluationRun }>(`/api/v1/admin/personas/${personaId}/evaluation_runs/${runId}`)
  return payload.evaluation_run
}

export async function runAdminPersonaEvaluation(personaId: number, requestId = clientRequestId()): Promise<AdminPersonaEvaluationRunResponse> {
  return postJson(`/api/v1/admin/personas/${personaId}/evaluation_runs`, {
    evaluation_run: { request_id: requestId },
  }, {
    timeoutMs: 90_000,
    timeoutMessage: 'Starting the release checks took too long.',
  })
}

export async function reviewAdminPersonaEvaluation(
  personaId: number,
  runId: number,
  decision: 'approved' | 'rejected',
  runDigest: string,
): Promise<AdminPersonaEvaluationApproval> {
  const payload = await postJson<{ approval: AdminPersonaEvaluationApproval }>(`/api/v1/admin/personas/${personaId}/evaluation_runs/${runId}/approval`, {
    approval: { decision, run_digest: runDigest },
  }, {
    timeoutMs: 30_000,
    timeoutMessage: 'Saving the evaluation review took too long.',
  })
  return payload.approval
}

export async function reviewAdminPersonaAudience(
  personaId: number,
  values: { candidate_digest: string; artifact_id: string; artifact_fingerprint: string; decision: 'approved' | 'rejected' },
): Promise<AdminPersonaAudienceAttestation> {
  const payload = await postJson<{ audience_attestation: AdminPersonaAudienceAttestation }>(`/api/v1/admin/personas/${personaId}/audience_attestations`, {
    audience_attestation: values,
  }, {
    timeoutMs: 30_000,
    timeoutMessage: 'Saving the phrase audience review took too long.',
  })
  return payload.audience_attestation
}

export async function createAdminPersona(values: AdminPersonaCreateInput): Promise<AdminPersonaDetail> {
  const payload = await postJson<{ persona: AdminPersonaDetail }>('/api/v1/admin/personas', { persona: values })
  return payload.persona
}

export async function updateAdminPersona(id: number, values: AdminPersonaUpdateInput): Promise<AdminPersonaDetail> {
  const payload = await fetchJson<{ persona: AdminPersonaDetail }>(`/api/v1/admin/personas/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ persona: values }),
  })
  return payload.persona
}

export async function createAdminPersonaSetupSession(personaId: number): Promise<AdminPersonaSetupSession> {
  const payload = await postJson<{ session: AdminPersonaSetupSession }>(`/api/v1/admin/personas/${personaId}/setup_sessions`, {})
  return payload.session
}

export async function fetchAdminPersonaSetupSession(personaId: number, sessionId: number): Promise<AdminPersonaSetupSession> {
  const payload = await fetchJson<{ session: AdminPersonaSetupSession }>(`/api/v1/admin/personas/${personaId}/setup_sessions/${sessionId}`)
  return payload.session
}

export async function rebaseAdminPersonaSetupSession(personaId: number, sessionId: number): Promise<AdminPersonaSetupSession> {
  const payload = await postJson<{ session: AdminPersonaSetupSession }>(`/api/v1/admin/personas/${personaId}/setup_sessions/${sessionId}/rebase`, {})
  return payload.session
}

export async function abandonAdminPersonaSetupSession(personaId: number, sessionId: number): Promise<AdminPersonaSetupSession> {
  const payload = await fetchJson<{ session: AdminPersonaSetupSession }>(`/api/v1/admin/personas/${personaId}/setup_sessions/${sessionId}`, { method: 'DELETE' })
  return payload.session
}

export async function createAdminPersonaSetupTurn(
  personaId: number,
  sessionId: number,
  message: string,
  idempotencyKey: string,
): Promise<AdminPersonaSetupSession> {
  const payload = await fetchJson<{ session: AdminPersonaSetupSession }>(`/api/v1/admin/personas/${personaId}/setup_sessions/${sessionId}/turns`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ turn: { message } }),
  }, { timeoutMs: 60_000, timeoutMessage: 'Mia took too long to prepare this proposal. Your message is ready to retry.' })
  return payload.session
}

export async function resolveAdminPersonaSetupProposal(
  personaId: number,
  sessionId: number,
  proposalId: number,
  action: 'apply' | 'reject',
  idempotencyKey: string,
): Promise<{ session: AdminPersonaSetupSession; persona?: AdminPersonaDetail }> {
  return fetchJson(`/api/v1/admin/personas/${personaId}/setup_sessions/${sessionId}/proposals/${proposalId}/${action}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({}),
  })
}

export async function archiveAdminPersona(id: number): Promise<AdminPersonaDetail> {
  const payload = await fetchJson<{ persona: AdminPersonaDetail }>(`/api/v1/admin/personas/${id}`, { method: 'DELETE' })
  return payload.persona
}

export async function restoreAdminPersona(id: number): Promise<AdminPersonaDetail> {
  const payload = await postJson<{ persona: AdminPersonaDetail }>(`/api/v1/admin/personas/${id}/restore`, {})
  return payload.persona
}

export async function previewAdminPersona(id: number, draftRevision: number, samplePrompt?: string): Promise<AdminPersonaPreviewResponse> {
  return postJson<AdminPersonaPreviewResponse>(`/api/v1/admin/personas/${id}/preview`, {
    preview: {
      draft_revision: draftRevision,
      ...(samplePrompt === undefined ? {} : { sample_prompt: samplePrompt }),
    },
  })
}

export async function publishAdminPersona(id: number, values: AdminPersonaPublishInput): Promise<AdminPersonaPublicationResponse> {
  return postJson<AdminPersonaPublicationResponse>(`/api/v1/admin/personas/${id}/publish`, { publish: values })
}

export async function fetchAdminPersonaVersion(personaId: number, versionId: number): Promise<AdminPersonaVersionResponse> {
  return fetchJson<AdminPersonaVersionResponse>(`/api/v1/admin/personas/${personaId}/versions/${versionId}`)
}

export async function restoreAdminPersonaVersionToDraft(
  personaId: number,
  versionId: number,
  values: AdminPersonaDraftRestoreInput,
): Promise<AdminPersonaDraftRestoreResponse> {
  return postJson<AdminPersonaDraftRestoreResponse>(
    `/api/v1/admin/personas/${personaId}/versions/${versionId}/rollback`,
    { rollback: values },
  )
}

export async function fetchAdminPersonaAssignableCohorts(): Promise<AdminPersonaAssignableCohort[]> {
  const payload = await fetchJson<{ cohorts: AdminPersonaAssignableCohort[] }>('/api/v1/admin/personas/assignable_cohorts')
  return payload.cohorts
}

export async function fetchAdminCohortPersonaAssignment(cohortId: number): Promise<AdminPersonaAssignment | null> {
  const payload = await fetchJson<{ persona_assignment: AdminPersonaAssignment | null }>(
    `/api/v1/admin/cohorts/${cohortId}/persona_assignment`,
  )
  return payload.persona_assignment
}

export async function updateAdminCohortPersonaAssignment(
  cohortId: number,
  personaId: number,
  expectedPersonaId: number | null,
): Promise<AdminPersonaAssignment> {
  const payload = await fetchJson<{ persona_assignment: AdminPersonaAssignment }>(
    `/api/v1/admin/cohorts/${cohortId}/persona_assignment`,
    {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        persona_assignment: {
          persona_id: personaId,
          expected_persona_id: expectedPersonaId,
        },
      }),
    },
  )
  return payload.persona_assignment
}

export async function deleteAdminCohortPersonaAssignment(
  cohortId: number,
  expectedPersonaId: number | null,
): Promise<void> {
  return fetchJson<void>(`/api/v1/admin/cohorts/${cohortId}/persona_assignment`, {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ persona_assignment: { expected_persona_id: expectedPersonaId } }),
  })
}

export async function fetchAdminPlaidHealth(): Promise<AdminPlaidHealth> {
  return fetchJson<AdminPlaidHealth>('/api/v1/admin/plaid_health')
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

export type PlaidAccount = {
  financial_generation?: number
  id: number
  name: string
  official_name: string | null
  mask: string | null
  type: string
  subtype: string | null
  current_balance_cents: number | null
  available_balance_cents: number | null
  currency: string | null
  active: boolean
  eligible_for_asset_tracking: boolean
  allowed_account_types: AccountType[]
  suggested_account_type: AccountType | null
  canonical_account_id: number | null
  canonical_balance_known: boolean | null
  canonical_balance_cents: number | null
  observation_newer_than_saved: boolean
}

export type PlaidItem = {
  financial_generation?: number
  context_paused_by_restart?: boolean
  financial_resumed_at?: string | null
  id: number
  institution_name: string
  status: 'active' | 'update_required' | 'error' | 'disconnecting' | 'disconnected'
  environment: 'sandbox' | 'production'
  consented_at: string
  last_synced_at: string | null
  health: PlaidItemHealth
  error_message: string | null
  disconnected_at: string | null
  auto_confirm_trusted_merchants: boolean
  accounts: PlaidAccount[]
}

export type PlaidOverview = {
  configured: boolean
  environment: 'sandbox' | 'production' | null
  consent_policy_version: string
  items: PlaidItem[]
}

export type PlaidTransaction = {
  financial_generation?: number
  context_paused_by_restart?: boolean
  id: number
  account_id: number
  account_name: string
  account_mask: string | null
  name: string
  merchant_name: string | null
  occurred_on: string
  authorized_on: string | null
  amount_cents: number
  pending: boolean
  direction: 'outflow' | 'inflow'
  primary_category: string | null
  detailed_category: string | null
  review_status: 'unreviewed' | 'drafted' | 'ignored'
  stageable: boolean
  transaction_draft_id: number | null
  transaction_draft_status: 'pending' | 'confirmed' | 'corrected' | 'ignored' | 'matched' | null
  confirmed_transaction_id: number | null
  confirmed_amount_cents: number | null
  category_names: string[]
  trust_state: 'bank_observed' | 'needs_review' | 'confirmed' | 'excluded' | 'bank_pending' | 'money_in' | 'source_changed'
  removed: boolean
  source_changed_after_draft: boolean
}

export type PlaidActivityView = 'all' | 'needs_review' | 'confirmed' | 'excluded' | 'pending' | 'inflow'

export type PlaidActivitySummary = {
  all_count: number
  posted_outflow_count: number
  posted_outflow_cents: number
  pending_count: number
  pending_cents: number
  inflow_count: number
  inflow_cents: number
  needs_review_count: number
  needs_review_cents: number
  review_year?: number
  review_year_needs_review_count?: number
  review_year_needs_review_cents?: number
  other_years_needs_review_count?: number
  confirmed_count: number
  confirmed_actual_count: number
  confirmed_cents: number
  excluded_count: number
}

export async function fetchPlaidOverview(): Promise<PlaidOverview> {
  return fetchJson<PlaidOverview>('/api/v1/plaid/items')
}

export async function createPlaidLinkToken(consentAccepted: boolean): Promise<{ link_token: string; consent_policy_version: string }> {
  return postJson('/api/v1/plaid/items/link_token', { consent_accepted: consentAccepted })
}

export async function createPlaidUpdateLinkToken(itemId: number): Promise<{ link_token: string }> {
  return postJson(`/api/v1/plaid/items/${itemId}/update_link_token`, {})
}

export type PlaidExchangeResult = {
  item: PlaidItem
  plaid: PlaidOverview
}

export async function exchangePlaidPublicToken(values: { public_token: string; institution_id?: string | null; institution_name?: string | null }): Promise<PlaidExchangeResult> {
  return postJson<PlaidExchangeResult>('/api/v1/plaid/items/exchange', values)
}

export async function syncPlaidItem(itemId: number): Promise<PlaidOverview> {
  return postJson<PlaidOverview>(`/api/v1/plaid/items/${itemId}/sync`, {})
}

export async function disconnectPlaidItem(itemId: number): Promise<PlaidOverview> {
  return fetchJson<PlaidOverview>(`/api/v1/plaid/items/${itemId}`, { method: 'DELETE' })
}

export type PlaidTransactionsPage = {
  transactions: PlaidTransaction[]
  pagination: { page: number; per_page: number; total: number; has_more: boolean }
  summary: PlaidActivitySummary
}

export async function fetchPlaidTransactions(
  page = 1,
  view: PlaidActivityView = 'all',
  filters: { query?: string; accountId?: number | null; reviewYear?: number; picture?: 'current' | 'history' } = {},
): Promise<PlaidTransactionsPage> {
  const query = new URLSearchParams({ limit: '50', page: String(page), view })
  if (filters.query) query.set('query', filters.query)
  if (filters.accountId) query.set('account_id', String(filters.accountId))
  if (filters.reviewYear) query.set('review_year', String(filters.reviewYear))
  if (filters.picture) query.set('picture', filters.picture)
  return fetchJson<PlaidTransactionsPage>(`/api/v1/plaid/transactions?${query}`)
}

export async function updatePlaidItemPreferences(itemId: number, values: { auto_confirm_trusted_merchants: boolean }): Promise<PlaidOverview> {
  return fetchJson<PlaidOverview>(`/api/v1/plaid/items/${itemId}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(values),
  })
}

export async function resumePlaidItemFinancialPicture(itemId: number, expectedGeneration: number): Promise<PlaidOverview> {
  return postJson(`/api/v1/plaid/items/${itemId}/resume_financial_picture`, { accepted: true, expected_item_financial_generation: expectedGeneration })
}

export async function stagePlaidTransactions(transactionIds: number[]): Promise<{ drafted_count: number; transaction_draft_ids: number[] }> {
  return postJson('/api/v1/plaid/transactions/stage', { transaction_ids: transactionIds })
}

export async function ignorePlaidTransactions(transactionIds: number[]): Promise<{ ignored_count: number }> {
  return postJson('/api/v1/plaid/transactions/ignore', { transaction_ids: transactionIds })
}

export async function fetchAppData(realWorkspace = false): Promise<AppData> {
  if (realWorkspace) {
    const result = await fetchJsonResponse<AppData>('/api/v1/workspace')
    const payload = result.payload
    const generation = payload.workspace.financial_generation ?? 0
    if (result.financial_generation_header !== null && result.financial_generation_header !== generation) {
      checkedFinancialReply(result.financial_generation_header, generation)
    }
    if (apiFinancialGeneration !== null && generation < apiFinancialGeneration) throw new Error('This reply belongs to the earlier financial picture. Refresh the current workspace.')
    setApiFinancialGeneration(generation)
    return payload
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
      setup_status: {
        complete: true,
        completed_count: 5,
        required_count: 5,
        required_fields: [
          { key: 'household_name', label: 'Household name', confirmed: true },
          { key: 'primary_goal', label: 'Primary goal', confirmed: true },
          { key: 'primary_income', label: 'Primary monthly income', confirmed: true },
          { key: 'fixed_expenses', label: 'Fixed essentials', confirmed: true },
          { key: 'flexible_spend', label: 'Flexible spending', confirmed: true },
        ],
        confirmed_fields: ['household_name', 'primary_goal', 'primary_income', 'fixed_expenses', 'flexible_spend'],
        missing_fields: [],
      },
      setup_values: demoWorkspaceSetupValues(profile, dashboard, budget, wealth),
      income_sources: budget.annual_plan?.income_sources ?? [],
      accounts: [],
      asset_portfolio: { liquid_balance: 0, nonliquid_balance: 0, total_balance: 0, liquid_balance_known: false, nonliquid_balance_known: false, total_balance_known: false, active_count: 0, archived_count: 0, liquid_known_count: 0, nonliquid_known_count: 0, total_known_count: 0, unknown_balance_account_ids: [] },
      debts: [],
      debt_portfolio: { mode: 'individual', total_balance: 0, monthly_minimum: 0, balance_known: true, minimum_payment_known: true, active_count: 0, archived_count: 0 },
      goals: [],
      goal_portfolio: { active_count: 0, archived_count: 0, target_total: 0, progress_total: 0, target_known_count: 0, progress_known_count: 0, unknown_target_goal_ids: [], unknown_progress_goal_ids: [] },
      cohort: null,
      capabilities: {
        schema_version: 1,
        source: 'demo',
        cohort_id: null,
        experience_version: null,
        modules: [
          ['home', 'Home'], ['review', 'Review'], ['ask_mia', 'Ask Mia'], ['budget', 'Budget'],
          ['profile', 'My Profile'], ['wealth', 'Wealth'], ['cfo_filter', 'CFO Filter'], ['optionality', 'Optionality'],
        ].map(([id, label]) => ({ id: id as ExperienceModuleId, label, enabled: true, core: !['cfo_filter', 'optionality'].includes(id) })),
      },
      brand: {
        source: 'legacy_household_cfo_default',
        mode: 'legacy_household_cfo_builtin',
        version_id: null,
        digest: '35ded27bda2348d56c1db078c087ed681442a4a7bba86d8924c39a9342fa7eb8',
        available: true,
        config: {
          schema_version: 1,
          product_name: 'Household CFO',
          short_name: 'Household CFO',
          organization_name: 'Household CFO Method',
          participant_role_term: 'household CFO',
          powered_by_name: 'VERA',
          powered_by_placement: 'header',
          tagline: 'Your household finance command center',
          welcome_heading: 'Your household money, in one clear place',
          welcome_description: 'Plan the month, understand what changed, and make confident decisions with your coach’s guidance.',
          logo_url: null,
          favicon_url: null,
          support: { label: 'Contact your coach', email: null, url: null },
          colors: {
            background: '#f7f2ea', surface: '#fffdf8', surface_muted: '#fbf7ef', text: '#1f2421',
            text_muted: '#706d66', border: '#e2d9cb', primary: '#7b4a58', primary_hover: '#633944',
            primary_soft: '#f1e2e3', accent: '#b97352', on_primary: '#ffffff', focus: '#7b4a58',
          },
          typography: { display: 'cormorant_garamond', body: 'montserrat' },
          footer: {
            text: 'Household CFO provides educational guidance and is not a substitute for individualized legal, tax, investment, or accounting advice.',
            privacy_url: null,
            terms_url: null,
          },
        },
      },
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

export async function saveWorkspaceSetup(values: Partial<WorkspaceSetupValues>, idempotencyKey: string): Promise<AppData> {
  return fetchJson<AppData>('/api/v1/workspace/setup', {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ workspace: values }),
  })
}

export async function createDebt(values: DebtInput, idempotencyKey: string): Promise<DebtRecord> {
  const payload = await fetchJson<{ debt: DebtRecord }>('/api/v1/debts', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey }, body: JSON.stringify({ debt: values }) })
  return payload.debt
}

export async function updateDebt(id: number, values: DebtInput, idempotencyKey: string): Promise<DebtRecord> {
  const payload = await fetchJson<{ debt: DebtRecord }>(`/api/v1/debts/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ debt: values }),
  })
  return payload.debt
}

export async function archiveDebt(id: number, idempotencyKey: string): Promise<DebtRecord> {
  const payload = await fetchJson<{ debt: DebtRecord }>(`/api/v1/debts/${id}`, { method: 'DELETE', headers: { 'Idempotency-Key': idempotencyKey } })
  return payload.debt
}

export async function restoreDebt(id: number, idempotencyKey: string): Promise<DebtRecord> {
  const payload = await fetchJson<{ debt: DebtRecord }>(`/api/v1/debts/${id}/restore`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey }, body: JSON.stringify({}) })
  return payload.debt
}

async function accountMutation(path: string, method: string, idempotencyKey: string, body?: Record<string, unknown>): Promise<AccountRecord> {
  const payload = await fetchJson<{ account: AccountRecord }>(path, {
    method,
    headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), 'Idempotency-Key': idempotencyKey },
    body: body ? JSON.stringify(body) : undefined,
  })
  return payload.account
}

export function createAccount(values: AccountInput, idempotencyKey: string) {
  return accountMutation('/api/v1/accounts', 'POST', idempotencyKey, { account: values })
}
export function updateAccount(id: number, values: AccountInput, idempotencyKey: string) {
  return accountMutation(`/api/v1/accounts/${id}`, 'PATCH', idempotencyKey, { account: values })
}
export function archiveAccount(id: number, idempotencyKey: string) {
  return accountMutation(`/api/v1/accounts/${id}`, 'DELETE', idempotencyKey)
}
export function restoreAccount(id: number, idempotencyKey: string) {
  return accountMutation(`/api/v1/accounts/${id}/restore`, 'POST', idempotencyKey, {})
}
export function linkPlaidAccount(id: number, plaidAccountId: number, idempotencyKey: string) {
  return accountMutation(`/api/v1/accounts/${id}/plaid_link`, 'POST', idempotencyKey, { plaid_account_id: plaidAccountId })
}
export function reconcilePlaidAccount(id: number, decision: 'accept_observed' | 'keep_saved', idempotencyKey: string) {
  return accountMutation(`/api/v1/accounts/${id}/plaid_reconcile`, 'POST', idempotencyKey, { decision })
}
export function unlinkPlaidAccount(id: number, idempotencyKey: string) {
  return accountMutation(`/api/v1/accounts/${id}/plaid_link`, 'DELETE', idempotencyKey)
}

async function goalMutation(path: string, method: string, idempotencyKey: string, body?: Record<string, unknown>): Promise<GoalRecord> {
  const payload = await fetchJson<{ goal: GoalRecord }>(path, {
    method,
    headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), 'Idempotency-Key': idempotencyKey },
    body: body ? JSON.stringify(body) : undefined,
  })
  return payload.goal
}

export function createGoal(values: GoalInput, idempotencyKey: string) {
  return goalMutation('/api/v1/goals', 'POST', idempotencyKey, { goal: values })
}
export function updateGoal(id: number, values: GoalInput, idempotencyKey: string) {
  return goalMutation(`/api/v1/goals/${id}`, 'PATCH', idempotencyKey, { goal: values })
}
export function archiveGoal(id: number, idempotencyKey: string) {
  return goalMutation(`/api/v1/goals/${id}`, 'DELETE', idempotencyKey)
}
export function restoreGoal(id: number, idempotencyKey: string) {
  return goalMutation(`/api/v1/goals/${id}/restore`, 'POST', idempotencyKey, {})
}

export async function updateDebtTracking(values: { mode: 'summary' | 'individual'; summary_balance?: number | null; summary_minimum_payment?: number | null }, idempotencyKey: string): Promise<DebtPortfolio> {
  const payload = await fetchJson<{ debt_portfolio: DebtPortfolio }>('/api/v1/debts/tracking', { method: 'PATCH', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey }, body: JSON.stringify({ debt_tracking: values }) })
  return payload.debt_portfolio
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
  setup_help?: { available: boolean } | null
  financial_restart?: { available: boolean; state: 'review_available' | 'owner_required' | 'unavailable' } | null
  savings_intake?: import('./lib/savingsChallenge').SavingsIntake | null
  user_message: MiaMessage
  assistant_message: MiaMessage
  transaction_draft?: TransactionDraft | null
  mia_action_draft?: MiaActionDraft | null
  budget?: BudgetData | null
  spending_report?: SpendingReport | null
}

export type FinancialRestartReview = {
  id: number
  household_name?: string
  status: 'pending' | 'applied' | 'canceled' | 'expired'
  expires_at: string
  financial_generation: number
  shared_member_count: number
  counts: Record<string, number>
  reset_fields: string[]
  preserved: string[]
  paused: string[]
  clears_chat: boolean
  clears_memories: boolean
  applied_at?: string | null
  result_generation?: number | null
}

export type FinancialRestartState = {
  admin_required?: boolean
  household_id: number
  available: boolean
  owner_required: boolean
  financial_generation: number
  household_name?: string
  review?: FinancialRestartReview | null
  latest_review?: FinancialRestartReview | null
  result_generation?: number
  setup_required?: boolean
}

export async function fetchFinancialRestartStatus(reviewId?: number): Promise<FinancialRestartState> {
  const query = reviewId == null ? '' : `?review_id=${encodeURIComponent(reviewId)}`
  const state = (await fetchJson<{ financial_restart: FinancialRestartState }>(`/api/v1/financial_restart/status${query}`, { cache: 'no-store' })).financial_restart
  if (reviewId == null) checkedFinancialReply(state.financial_generation, apiFinancialGeneration)
  return reviewId == null ? state : { ...state, review: state.review ?? state.latest_review }
}

export async function previewFinancialRestart(): Promise<FinancialRestartState> {
  return (await postJson<{ financial_restart: FinancialRestartState }>('/api/v1/financial_restart/preview', {})).financial_restart
}

export async function applyFinancialRestart(reviewId: number, sharedHouseholdAcknowledged: boolean): Promise<FinancialRestartState> {
  return (await postJson<{ financial_restart: FinancialRestartState }>('/api/v1/financial_restart/apply', { review_id: reviewId, confirmation: 'START OVER', shared_household_acknowledged: sharedHouseholdAcknowledged })).financial_restart
}

export async function cancelFinancialRestart(reviewId: number): Promise<FinancialRestartState> {
  return (await postJson<{ financial_restart: FinancialRestartState }>('/api/v1/financial_restart/cancel', { review_id: reviewId })).financial_restart
}

export async function fetchMiaMessages(realWorkspace = false, beforeId?: number | null): Promise<MiaMessagesData> {
  if (!realWorkspace) {
    return { messages: [], oldest_message_id: null, older_message_count: 0, has_older_messages: false, quick_prompts: [], disclaimer: '' }
  }

  const query = beforeId ? `?before_id=${encodeURIComponent(beforeId)}&limit=60` : '?limit=60'
  return fetchJson<MiaMessagesData>(`/api/v1/mia/messages${query}`)
}

export type EarlierMiaMessages = Pick<MiaMessagesData, 'messages' | 'oldest_message_id' | 'older_message_count' | 'has_older_messages'> & { picture: 'history'; read_only: true }
export async function fetchEarlierMiaMessages(beforeId?: number | null, signal?: AbortSignal): Promise<EarlierMiaMessages> {
  const query = new URLSearchParams({ picture: 'history', limit: '60' })
  if (beforeId) query.set('before_id', String(beforeId))
  const result = await fetchJson<EarlierMiaMessages>(`/api/v1/mia/messages?${query}`, { signal, cache: 'no-store' })
  if (result.picture !== 'history' || result.read_only !== true) throw new Error('Earlier conversations could not be verified. Reload and try again.')
  return result
}

export async function fetchHouseholdMemories(): Promise<MiaMemoryData> {
  return fetchJson<MiaMemoryData>('/api/v1/household_memories')
}

export async function createHouseholdMemory(values: HouseholdMemoryInput): Promise<{ memory: HouseholdMemory; personalization: MiaMemoryData['personalization'] }> {
  return postJson('/api/v1/household_memories', { memory: values })
}

export async function updateHouseholdMemory(id: number, values: Partial<HouseholdMemoryInput>): Promise<{ memory: HouseholdMemory; personalization: MiaMemoryData['personalization'] }> {
  return fetchJson(`/api/v1/household_memories/${id}`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ memory: values }),
  })
}

export async function confirmHouseholdMemory(id: number, confirmationFingerprint: string): Promise<{ memory: HouseholdMemory; personalization: MiaMemoryData['personalization'] }> {
  return postJson(`/api/v1/household_memories/${id}/confirm`, { memory: { confirmation_fingerprint: confirmationFingerprint } })
}

export async function rejectHouseholdMemory(id: number): Promise<{ memory: HouseholdMemory; personalization: MiaMemoryData['personalization'] }> {
  return postJson(`/api/v1/household_memories/${id}/reject`, {})
}

export async function forgetHouseholdMemory(id: number): Promise<void> {
  return fetchJson<void>(`/api/v1/household_memories/${id}`, { method: 'DELETE' })
}

export async function setMiaPersonalizationPaused(paused: boolean): Promise<{ personalization: MiaMemoryData['personalization'] }> {
  return fetchJson('/api/v1/mia_memory_settings', {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ personalization: { paused } }),
  })
}

export async function sendMiaMessage(message: string, history: MiaMessage[] = [], realWorkspace = false, year?: number, month?: number, documentImportIds: number[] = [], requestId?: string): Promise<MiaMessageResponse> {
  const path = realWorkspace ? '/api/v1/mia/messages' : '/api/demo/mia/messages'
  const body = {
    message,
    ...(realWorkspace && year ? { year } : {}),
    ...(realWorkspace && month ? { month } : {}),
    ...(realWorkspace && documentImportIds.length > 0 ? { document_import_ids: documentImportIds } : {}),
    ...(realWorkspace && requestId ? { request_id: requestId } : {}),
    messages: history.slice(-32).map((entry) => ({
      role: entry.role,
      content: entry.content,
    })),
  }
  return realWorkspace
    ? postJsonUntilComplete<MiaMessageResponse>(path, body)
    : postJson<MiaMessageResponse>(path, body, {
        timeoutMs: MIA_REQUEST_TIMEOUT_MS,
        timeoutMessage: 'Your assistant took too long to finish this request.',
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

function normalizeCohortReleaseStudio(payload: unknown): CohortReleaseStudio {
  const root = releaseRecord(payload)
  const rawStudio = releaseRecord(root.cohort_release_studio ?? root.release_studio ?? root)
  const rawCohort = releaseRecord(rawStudio.cohort)
  const rawRuntimeTruth = releaseRecord(rawStudio.runtime_truth)
  const rawPermissions = releaseRecord(rawStudio.permissions)
  const rawReadiness = releaseRecord(rawStudio.readiness)
  const rawHistory = releaseRecord(rawStudio.history)
  const rawCandidateValue = rawStudio.candidate ?? rawReadiness.candidate ?? (Object.keys(rawReadiness).length > 0 ? rawReadiness : null)
  const rawCandidate = rawCandidateValue == null ? null : releaseRecord(rawCandidateValue)
  const rawReleases = Array.isArray(rawStudio.releases) ? rawStudio.releases : []
  const cohortId = releaseInteger(rawCohort.id)
  const cohortName = releaseString(rawCohort.name)

  if (!cohortId || !cohortName) throw new Error('Cohort release data was incomplete. Reload Coach Studio and try again.')

  const status = releaseString(rawCohort.status)
  const knownStatuses: AdminCohortStatus[] = ['draft', 'enrolling', 'active', 'completed', 'archived']

  return {
    cohort: {
      id: cohortId,
      name: cohortName,
      status: knownStatuses.includes(status as AdminCohortStatus) ? status as AdminCohortStatus : 'draft',
    },
    runtime_truth: {
      changes_participant_runtime: false,
      message: releaseString(rawRuntimeTruth.message)
        || 'Release records are audit evidence in this phase. Sealing or restoring a record does not change the brand, assistant, or tools participants use.',
    },
    permissions: {
      view: releaseBoolean(rawPermissions.view, true),
      seal: releaseBoolean(rawPermissions.seal),
      restore: releaseBoolean(rawPermissions.restore),
    },
    candidate: rawCandidate ? {
      manifest_schema: releaseString(rawCandidate.manifest_schema) || 'cohort_release_manifest_v2',
      bundle_digest: releaseString(rawCandidate.bundle_digest),
      assignment_id: releaseNullableInteger(rawCandidate.assignment_id),
      persona_version_id: releaseNullableInteger(rawCandidate.persona_version_id ?? rawCandidate.coach_persona_version_id),
      experience_version_id: releaseNullableInteger(rawCandidate.experience_version_id ?? rawCandidate.cohort_experience_version_id),
      brand_mode: releaseString(rawCandidate.brand_mode),
      brand_version_id: releaseNullableInteger(rawCandidate.brand_version_id ?? rawCandidate.workspace_brand_version_id),
      brand_snapshot_digest: releaseString(rawCandidate.brand_snapshot_digest),
      registry_digest: releaseString(rawCandidate.registry_digest ?? rawCandidate.tool_registry_digest),
      registry_version: releaseNullableInteger(rawCandidate.registry_version ?? rawCandidate.tool_registry_version),
      expected_latest_release_id: releaseNullableInteger(rawCandidate.expected_latest_release_id ?? rawReadiness.expected_latest_release_id ?? rawStudio.latest_release_id),
      seal_needed: releaseBoolean(rawCandidate.seal_needed ?? rawReadiness.seal_needed, !releaseBoolean(rawReadiness.latest_release_match ?? rawStudio.latest_release_match)),
      ready: releaseBoolean(rawCandidate.ready ?? rawReadiness.ready),
      blockers: releaseStrings(rawCandidate.blockers ?? rawReadiness.blockers),
      warnings: releaseStrings(rawCandidate.warnings ?? rawReadiness.warnings),
      checks: (Array.isArray(rawCandidate.checks) ? rawCandidate.checks : Array.isArray(rawReadiness.checks) ? rawReadiness.checks : []).map((value, index) => {
        const check = releaseRecord(value)
        return {
          key: releaseString(check.key) || releaseString(check.id) || `check-${index + 1}`,
          label: releaseString(check.label) || releaseString(check.name) || `Readiness check ${index + 1}`,
          ready: releaseBoolean(check.ready, releaseString(check.status) === 'ready'),
          detail: releaseNullableString(check.detail ?? check.message),
        }
      }),
    } : null,
    latest_release_match: releaseBoolean(rawStudio.latest_release_match ?? rawReadiness.latest_release_match),
    history: {
      limit: releaseInteger(rawHistory.limit) ?? rawReleases.length,
      total_count: releaseInteger(rawHistory.total_count) ?? rawReleases.length,
      truncated: releaseBoolean(rawHistory.truncated, (releaseInteger(rawHistory.total_count) ?? rawReleases.length) > rawReleases.length),
    },
    releases: rawReleases.map((value) => {
      const release = releaseRecord(value)
      const actor = releaseRecord(release.actor)
      const personaSnapshot = releaseRecord(release.persona_snapshot)
      const experienceSnapshot = releaseRecord(release.experience_snapshot)
      const registrySnapshot = releaseRecord(release.tool_registry_snapshot ?? release.registry_snapshot)
      const id = releaseInteger(release.id)
      if (!id) return null

      const actorId = releaseInteger(actor.id ?? release.actor_user_id)
      const actorName = releaseString(actor.full_name ?? actor.name)
      const restoreBlockers = releaseStrings(release.restore_blockers)
      return {
        id,
        release_number: releaseInteger(release.release_number) ?? id,
        event_type: releaseString(release.event_type) || 'release',
        manifest_schema: releaseString(release.manifest_schema),
        released_at: releaseString(release.released_at ?? release.created_at),
        actor: actorId && actorName ? { id: actorId, full_name: actorName } : null,
        actor_user_id: actorId,
        bundle_digest: releaseString(release.bundle_digest),
        source_release_id: releaseNullableInteger(release.source_release_id),
        persona_version_id: releaseNullableInteger(release.persona_version_id ?? release.coach_persona_version_id ?? personaSnapshot.version_id),
        experience_version_id: releaseNullableInteger(release.experience_version_id ?? release.cohort_experience_version_id ?? experienceSnapshot.version_id),
        brand_mode: releaseString(release.brand_mode),
        brand_version_id: releaseNullableInteger(release.brand_version_id ?? release.workspace_brand_version_id),
        brand_snapshot_digest: releaseString(release.brand_snapshot_digest),
        registry_digest: releaseString(release.registry_digest ?? release.tool_registry_digest ?? registrySnapshot.digest),
        registry_version: releaseNullableInteger(release.registry_version ?? release.tool_registry_version ?? registrySnapshot.version),
        restore_allowed: releaseBoolean(release.restore_allowed),
        restore_reason: releaseNullableString(release.restore_reason) ?? (restoreBlockers.length > 0 ? restoreBlockers.join(' ') : null),
      } satisfies CohortReleaseRecord
    }).filter((release): release is CohortReleaseRecord => release !== null),
  }
}

function normalizeCohortRolloutStudio(payload: unknown): CohortRolloutStudio {
  const root = releaseRecord(payload)
  const raw = releaseRecord(root.cohort_rollout_studio ?? root)
  const cohort = releaseRecord(raw.cohort)
  const runtimeTruth = releaseRecord(raw.runtime_truth)
  const permissions = releaseRecord(raw.permissions)
  const roster = releaseRecord(raw.current_roster)
  const rawParticipants = Array.isArray(roster.participants) ? roster.participants : []
  const rawRollouts = Array.isArray(raw.rollouts) ? raw.rollouts : []
  const rawReleases = Array.isArray(raw.releases) ? raw.releases : []
  const cohortId = releaseInteger(cohort.id)
  const cohortName = releaseString(cohort.name)
  const changesParticipantRuntime = releaseBoolean(runtimeTruth.changes_participant_runtime)

  if (!cohortId || !cohortName) throw new Error('Cohort rollout data was incomplete. Reload Coach Studio and try again.')
  const status = releaseString(cohort.status)
  const knownStatuses: AdminCohortStatus[] = ['draft', 'enrolling', 'active', 'completed', 'archived']

  return {
    cohort: {
      id: cohortId,
      name: cohortName,
      status: knownStatuses.includes(status as AdminCohortStatus) ? status as AdminCohortStatus : 'draft',
      participant_count: releaseInteger(cohort.participant_count) ?? rawParticipants.length,
    },
    runtime_truth: {
      changes_participant_runtime: changesParticipantRuntime,
      participant_runtime_changed: releaseBoolean(runtimeTruth.participant_runtime_changed),
      message: releaseString(runtimeTruth.message) || (changesParticipantRuntime
        ? 'Each advanced wave receives the sealed Mia persona and participant tools together. Completing the rollout makes that release the cohort default; rollback restores the captured baseline.'
        : 'This pre-cutover rollout is record only and cannot change participant runtime.'),
    },
    permissions: {
      view: releaseBoolean(permissions.view, true),
      manage: releaseBoolean(permissions.manage),
      plan: releaseBoolean(permissions.plan),
      actor_role: releaseNullableString(permissions.actor_role),
      blockers: releaseStrings(permissions.blockers),
      plan_blockers: releaseStrings(permissions.plan_blockers),
    },
    current_roster: {
      digest: releaseString(roster.digest),
      readiness_digest: releaseString(roster.readiness_digest),
      total_count: releaseInteger(roster.total_count) ?? rawParticipants.length,
      counts: normalizeRolloutCounts(roster.counts),
      participants: rawParticipants.map(normalizeRolloutParticipant).filter((participant): participant is CohortRolloutParticipant => participant !== null),
    },
    latest_release: normalizeRolloutRelease(raw.latest_release),
    active_release: normalizeRolloutRelease(raw.active_release),
    release_history: normalizeHistory(raw.release_history, rawReleases.length),
    releases: rawReleases.map(normalizeRolloutRelease).filter((release): release is CohortRolloutRelease => release !== null),
    history: normalizeHistory(raw.history, rawRollouts.length),
    open_rollout: raw.open_rollout ? normalizeRolloutRecord(raw.open_rollout) : null,
    rollouts: rawRollouts.map((value) => normalizeRolloutSummary(value)).filter((rollout): rollout is CohortRolloutSummary => rollout !== null),
  }
}

function normalizeRolloutRecord(value: unknown): CohortRolloutRecord | null {
  const raw = releaseRecord(value)
  const summary = normalizeRolloutSummary(raw)
  const targetRelease = normalizeRolloutRelease(raw.target_release)
  if (!summary || !targetRelease) return null
  const permissions = releaseRecord(raw.permissions)
  const runtimeMode = normalizeRolloutRuntimeMode(raw.runtime_mode)
  const runtimeModeSupported = runtimeMode === 'release_runtime_v2' || runtimeMode === 'legacy_record_only_v1'
  const rawWaves = Array.isArray(raw.waves) ? raw.waves : []
  const rawTransitions = Array.isArray(raw.transitions) ? raw.transitions : []

  return {
    ...summary,
    target_release: targetRelease,
    runtime_mode: runtimeMode,
    runtime_blocker: releaseNullableString(raw.runtime_blocker),
    baseline_release: normalizeRolloutRelease(raw.baseline_release),
    rollback_candidate: normalizeRolloutRelease(raw.rollback_candidate),
    readiness_digest: releaseString(raw.readiness_digest),
    next_wave_readiness_digest: releaseString(raw.next_wave_readiness_digest),
    next_wave_position: releaseNullableInteger(raw.next_wave_position),
    permissions: {
      advance: runtimeModeSupported && releaseBoolean(permissions.advance),
      pause: runtimeModeSupported && releaseBoolean(permissions.pause),
      resume: runtimeModeSupported && releaseBoolean(permissions.resume),
      cancel: runtimeModeSupported && releaseBoolean(permissions.cancel),
      rollback: runtimeModeSupported && releaseBoolean(permissions.rollback),
      advance_blockers: runtimeModeSupported ? releaseStrings(permissions.advance_blockers) : ['This app does not recognize the rollout runtime mode. Reload after updating the app.'],
      rollback_blockers: runtimeModeSupported ? releaseStrings(permissions.rollback_blockers) : ['This app does not recognize the rollout runtime mode. Reload after updating the app.'],
    },
    waves: rawWaves.map((value) => {
      const wave = releaseRecord(value)
      const rawParticipants = Array.isArray(wave.participants) ? wave.participants : []
      const id = releaseInteger(wave.id)
      const position = releaseInteger(wave.position)
      if (!id || !position) return null
      return {
        id,
        position,
        name: releaseString(wave.name) || `Wave ${position}`,
        active: releaseBoolean(wave.active),
        completed: releaseBoolean(wave.completed),
        participant_count: releaseInteger(wave.participant_count) ?? rawParticipants.length,
        exposed_count: releaseInteger(wave.exposed_count) ?? 0,
        exposure_complete: releaseBoolean(wave.exposure_complete),
        counts: normalizeRolloutCounts(wave.counts),
        participants: rawParticipants.map(normalizeRolloutParticipant).filter((participant): participant is CohortRolloutParticipant => participant !== null),
      }
    }).filter((wave): wave is CohortRolloutWave => wave !== null),
    transitions: rawTransitions.map(normalizeRolloutTransition).filter((transition): transition is CohortRolloutTransition => transition !== null),
  }
}

function normalizeRolloutSummary(value: unknown): CohortRolloutSummary | null {
  const raw = releaseRecord(value)
  const targetRelease = normalizeRolloutRelease(raw.target_release)
  const id = releaseInteger(raw.id)
  if (!id || !targetRelease) return null
  const planner = releaseRecord(raw.planned_by)
  const plannerId = releaseInteger(planner.id)
  const transitionHistory = normalizeHistory(raw.transition_history, 0)
  return {
    id,
    status: releaseString(raw.status),
    runtime_mode: normalizeRolloutRuntimeMode(raw.runtime_mode),
    runtime_blocker: releaseNullableString(raw.runtime_blocker),
    target_release: targetRelease,
    baseline_release: normalizeRolloutRelease(raw.baseline_release),
    rollback_release: normalizeRolloutRelease(raw.rollback_release),
    planned_by: plannerId ? { id: plannerId, full_name: releaseString(planner.full_name) || `Workspace member ${plannerId}`, role: releaseNullableString(planner.role) } : null,
    planned_at: releaseString(raw.planned_at),
    activated_at: releaseNullableString(raw.activated_at),
    paused_at: releaseNullableString(raw.paused_at),
    completed_at: releaseNullableString(raw.completed_at),
    cancelled_at: releaseNullableString(raw.cancelled_at),
    rolled_back_at: releaseNullableString(raw.rolled_back_at),
    current_wave_position: releaseInteger(raw.current_wave_position) ?? 0,
    wave_count: releaseInteger(raw.wave_count) ?? 0,
    participant_count: releaseInteger(raw.participant_count) ?? 0,
    latest_transition_id: releaseNullableInteger(raw.latest_transition_id),
    transition_history: transitionHistory,
    participant_runtime_changed: releaseBoolean(raw.participant_runtime_changed),
  }
}

function normalizeRolloutRelease(value: unknown): CohortRolloutRelease | null {
  const raw = releaseRecord(value)
  const id = releaseInteger(raw.id)
  if (!id) return null
  return {
    id,
    release_number: releaseInteger(raw.release_number) ?? id,
    bundle_digest: releaseString(raw.bundle_digest),
    manifest_schema: releaseString(raw.manifest_schema),
    brand_mode: releaseString(raw.brand_mode),
    brand_version_id: releaseNullableInteger(raw.brand_version_id ?? raw.workspace_brand_version_id),
    brand_snapshot_digest: releaseString(raw.brand_snapshot_digest),
    integrity_valid: releaseBoolean(raw.integrity_valid),
    runtime_compatible: releaseBoolean(raw.runtime_compatible),
    released_at: releaseString(raw.released_at),
  }
}

function normalizeRolloutRuntimeMode(value: unknown): CohortRolloutRecord['runtime_mode'] {
  return releaseString(value) || 'unsupported'
}

function normalizeRolloutParticipant(value: unknown): CohortRolloutParticipant | null {
  const raw = releaseRecord(value)
  const userId = releaseInteger(raw.user_id)
  if (!userId) return null
  return {
    user_id: userId,
    full_name: releaseString(raw.full_name) || `Participant ${userId}`,
    readiness: releaseString(raw.readiness) || 'awaiting_acceptance',
    exposed: typeof raw.exposed === 'boolean' ? raw.exposed : null,
    effective_release: normalizeRolloutRelease(raw.effective_release),
  }
}

function normalizeRolloutTransition(value: unknown): CohortRolloutTransition | null {
  const transition = releaseRecord(value)
  const actor = releaseRecord(transition.actor)
  const id = releaseInteger(transition.id)
  if (!id) return null
  const actorId = releaseInteger(actor.id)
  return {
    id,
    event_type: releaseString(transition.event_type),
    from_status: releaseNullableString(transition.from_status),
    to_status: releaseString(transition.to_status),
    from_wave_position: releaseInteger(transition.from_wave_position) ?? 0,
    to_wave_position: releaseInteger(transition.to_wave_position) ?? 0,
    rollback_release_id: releaseNullableInteger(transition.rollback_release_id),
    readiness_digest: releaseNullableString(transition.readiness_digest),
    actor: actorId ? { id: actorId, full_name: releaseString(actor.full_name) || `Workspace member ${actorId}`, role: releaseNullableString(actor.role) } : null,
    occurred_at: releaseString(transition.occurred_at),
    participant_runtime_changed: releaseBoolean(transition.participant_runtime_changed),
  }
}

function normalizeCohortRolloutMutation(payload: unknown): CohortRolloutMutationResponse {
  const root = releaseRecord(payload)
  const studio = normalizeCohortRolloutStudio(root)
  const rollout = normalizeRolloutRecord(root.rollout)
  const transition = normalizeRolloutTransition(root.transition)
  if (!rollout || !transition) throw new Error('The rollout action response was incomplete. Reload Coach Studio before continuing.')
  return { rollout, transition, replayed: releaseBoolean(root.replayed), cohort_rollout_studio: studio }
}

function normalizeRolloutCounts(value: unknown): CohortRolloutReadinessCounts {
  const raw = releaseRecord(value)
  return {
    ready: releaseInteger(raw.ready) ?? 0,
    awaiting_acceptance: releaseInteger(raw.awaiting_acceptance) ?? 0,
    revoked: releaseInteger(raw.revoked) ?? 0,
    removed: releaseInteger(raw.removed) ?? 0,
  }
}

function normalizeHistory(value: unknown, fallbackCount: number) {
  const raw = releaseRecord(value)
  const total = releaseInteger(raw.total_count) ?? fallbackCount
  return {
    limit: releaseInteger(raw.limit) ?? fallbackCount,
    total_count: total,
    truncated: releaseBoolean(raw.truncated, total > fallbackCount),
  }
}

function releaseRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {}
}

function releaseString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function releaseNullableString(value: unknown): string | null {
  const result = releaseString(value)
  return result || null
}

function releaseInteger(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : null
}

function releaseNullableInteger(value: unknown): number | null {
  return value == null ? null : releaseInteger(value)
}

function releaseBoolean(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

function releaseStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : []
}

function yearQuery(year?: number) {
  return year ? `?year=${encodeURIComponent(year)}` : ''
}

export async function createBudgetCategory(values: { name: string; stack_key: BudgetStackKey; monthly_amount?: number | string; month_numbers?: number[] }, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/budget_categories${yearQuery(year)}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey }, body: JSON.stringify({ category: values }),
  })
  return payload.budget
}

export async function updateBudgetCategory(id: number, values: { name: string; stack_key: BudgetStackKey }, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/budget_categories/${id}${yearQuery(year)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ category: values }),
  })
  return payload.budget
}

export async function archiveBudgetCategory(id: number, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/budget_categories/${id}${yearQuery(year)}`, { method: 'DELETE', headers: { 'Idempotency-Key': idempotencyKey } })
  return payload.budget
}

export async function restoreBudgetCategory(id: number, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/budget_categories/${id}/restore${yearQuery(year)}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey }, body: JSON.stringify({}),
  })
  return payload.budget
}

export async function updateBudgetAllocation(id: number, plannedAmount: number | string, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/budget_allocations/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ allocation: { planned_amount: plannedAmount } }),
  })
  return payload.budget
}

export async function createIncomeSource(values: IncomeSourceInput, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_sources${yearQuery(year)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ income_source: values }),
  })
  return payload.budget
}

export async function updateIncomeSource(id: number, values: IncomeSourceInput, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_sources/${id}${yearQuery(year)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ income_source: values }),
  })
  return payload.budget
}

export async function archiveIncomeSource(id: number, endsOn: string, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_sources/${id}${yearQuery(year)}`, {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ income_source: { ends_on: endsOn } }),
  })
  return payload.budget
}

export async function restoreIncomeSource(id: number, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_sources/${id}/restore${yearQuery(year)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({}),
  })
  return payload.budget
}

export async function createIncomeScheduleEntry(values: IncomeScheduleEntryInput, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_schedule_entries${yearQuery(year)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ income_schedule_entry: values }),
  })
  return payload.budget
}

export async function updateIncomeScheduleEntry(id: number, values: IncomeScheduleEntryInput, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_schedule_entries/${id}${yearQuery(year)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ income_schedule_entry: values }),
  })
  return payload.budget
}

export async function deleteIncomeScheduleEntry(id: number, year: number | undefined, idempotencyKey: string): Promise<BudgetData> {
  const payload = await fetchJson<{ budget: BudgetData }>(`/api/v1/income_schedule_entries/${id}${yearQuery(year)}`, {
    method: 'DELETE',
    headers: { 'Idempotency-Key': idempotencyKey },
  })
  return payload.budget
}

export async function applyMiaActionDraft(id: number, idempotencyKey: string, itemIds?: number[]): Promise<AppData> {
  const payload = await fetchJson<{ workspace: AppData }>(`/api/v1/mia_action_drafts/${id}/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify(itemIds ? { item_ids: itemIds } : {}),
  })
  return payload.workspace
}

export async function cancelMiaActionDraft(id: number, idempotencyKey: string): Promise<AppData> {
  const payload = await fetchJson<{ workspace: AppData }>(`/api/v1/mia_action_drafts/${id}/cancel`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({}),
  })
  return payload.workspace
}

export type TransactionDraftUpdateInput = Partial<{ occurred_on: string; merchant: string; amount: number | string; budget_category_id: number | null }> & {
  removed_split_ids?: number[]
  splits?: Array<Partial<{ id: number; amount: number | string; budget_category_id: number | null; category_name: string | null; stack_key: BudgetStackKey | null; notes: string | null }>>
}

export type TransactionDraftCreateInput = { occurred_on: string; merchant: string; amount: number | string; budget_category_id?: number | null }

export async function createTransactionDraft(values: TransactionDraftCreateInput, idempotencyKey: string): Promise<{ transaction_draft: TransactionDraft; workspace: AppData }> {
  return fetchJson<{ transaction_draft: TransactionDraft; workspace: AppData }>('/api/v1/transaction_drafts', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ transaction_draft: values }),
  })
}

export async function updateTransactionDraft(id: number, values: TransactionDraftUpdateInput, idempotencyKey: string): Promise<{ transaction_draft: TransactionDraft; workspace: AppData }> {
  return fetchJson<{ transaction_draft: TransactionDraft; workspace: AppData }>(`/api/v1/transaction_drafts/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ transaction_draft: values }),
  })
}

export async function confirmTransactionDraft(id: number, values: TransactionDraftUpdateInput, idempotencyKey: string): Promise<AppData> {
  const payload = await fetchJson<{ workspace: AppData }>(`/api/v1/transaction_drafts/${id}/confirm`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ transaction_draft: values }),
  })
  return payload.workspace
}

export async function ignoreTransactionDraft(id: number, idempotencyKey: string): Promise<AppData> {
  const payload = await fetchJson<{ workspace: AppData }>(`/api/v1/transaction_drafts/${id}/ignore`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: '{}',
  })
  return payload.workspace
}

export async function bulkConfirmTransactionDrafts(ids: number[], year: number, confirmation: string, idempotencyKey: string): Promise<AppData> {
  const payload = await fetchJson<{ workspace: AppData }>('/api/v1/transaction_drafts/bulk_confirm', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ transaction_draft_ids: ids, year, confirmation }),
  })
  return payload.workspace
}

export async function bulkIgnoreTransactionDrafts(ids: number[], year: number, idempotencyKey: string): Promise<AppData> {
  const payload = await fetchJson<{ workspace: AppData }>('/api/v1/transaction_drafts/bulk_ignore', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ transaction_draft_ids: ids, year }),
  })
  return payload.workspace
}

export async function matchTransactionDraft(id: number, matchId: number | undefined, idempotencyKey: string): Promise<AppData> {
  const payload = await fetchJson<{ workspace: AppData }>(`/api/v1/transaction_drafts/${id}/match`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify(matchId ? { match_id: matchId } : {}),
  })
  return payload.workspace
}

export async function reopenTransactionDraft(id: number, idempotencyKey: string): Promise<AppData> {
  const payload = await fetchJson<{ workspace: AppData }>(`/api/v1/transaction_drafts/${id}/reopen`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: '{}',
  })
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

  return withDeadline(async (signal) => {
    let response: Response
    try {
      response = await apiFetch('/api/v1/mia/transcriptions', {
        method: 'POST',
        body: formData,
      }, signal)
    } catch (error) {
      throw new Error(apiNetworkErrorMessage('Voice transcription could not reach the API'), { cause: error })
    }

    if (!response.ok) {
      throw new Error(await responseErrorMessage(response, 'Voice transcription failed'))
    }

    const payload = (await response.json()) as { transcript: string }
    return payload.transcript
  }, FILE_UPLOAD_TIMEOUT_MS, 'Voice transcription took too long.', undefined, 'Record again or type your note.')
}

export async function fetchDocumentImports(): Promise<FinancialDocumentImport[]> {
  const payload = await fetchJson<{ document_imports: FinancialDocumentImport[] }>('/api/v1/document_imports')
  return payload.document_imports
}

export async function fetchDocumentSourceReview(id: number, revisionId: number, page: number, filter: SourceReviewFilter, signal?: AbortSignal): Promise<SourceReview> {
  const query = new URLSearchParams({ revision_id: String(revisionId), page: String(page), per_page: '50', filter })
  const payload = await fetchJson<{ source_review: SourceReview }>(`/api/v1/document_imports/${id}/source_review?${query}`, { signal })
  return payload.source_review
}

export async function mutateStatementReview<T>(importId: number, revisionId: number, action: SourceReviewAction, input: object, requestId: string, signal?: AbortSignal): Promise<{ record: T; replayed: boolean }> {
  return fetchJson(`/api/v1/document_imports/${importId}/review/${action}`, { method: 'POST', signal,
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': requestId }, body: JSON.stringify({ revision_id: revisionId, input }) })
}
export function fetchTrackedSourceAccounts(cursor: number | null, signal?: AbortSignal): Promise<{ records: TrackedSourceAccount[]; next_cursor: number | null }> {
  return fetchJson(`/api/v1/source_review_accounts?cursor=${cursor ?? 0}`, { signal, cache: 'no-store' })
}

export function fetchSourceDuplicateCandidates(importId: number, eventId: number, cursor: number | null, signal?: AbortSignal, options: { filter?: 'duplicate' | 'link'; signed_amount_cents?: number; posted_on?: string } = {}): Promise<{ records: ReviewedRow[]; next_cursor: number | null }> {
  const query = new URLSearchParams({ event_id: String(eventId), cursor: String(cursor ?? 0), filter: options.filter ?? 'duplicate' })
  if (options.signed_amount_cents !== undefined) query.set('signed_amount_cents', String(options.signed_amount_cents))
  if (options.posted_on) query.set('posted_on', options.posted_on)
  return fetchJson(`/api/v1/document_imports/${importId}/review_candidates?${query}`, { signal, cache: 'no-store' })
}

export async function fetchDocumentImport(id: number): Promise<FinancialDocumentImport> {
  const payload = await fetchJson<{ document_import: FinancialDocumentImport }>(`/api/v1/document_imports/${id}`)
  return payload.document_import
}

export async function uploadDocumentImport(file: File, documentKind: DocumentImportKind, origin: 'profile' | 'mia' = 'profile', uploadContext = '', documentKindExplicit = origin === 'profile'): Promise<FinancialDocumentImport> {
  const assertCurrentContext = captureApiOperation()
  const uploadRequestId = clientRequestId()
  const contentType = uploadContentType(file)
  const checksumSha256 = await fileSha256(file)
  assertCurrentContext()
  const presign = await postJson<{
    upload_url: string
    upload_headers: Record<string, string>
    upload_token: string
  }>('/api/v1/document_imports/presign', {
    filename: file.name,
    content_type: contentType,
    byte_size: file.size,
    checksum_sha256: checksumSha256,
    document_kind: documentKind,
    upload_origin: origin,
    upload_context: uploadContext.trim() || undefined,
    document_kind_explicit: documentKindExplicit,
    upload_request_id: uploadRequestId,
  })
  assertCurrentContext()

  let uploadResponse: Response
  try {
    uploadResponse = await fetchWithDeadline(
      presign.upload_url,
      {
        method: 'PUT',
        headers: presign.upload_headers,
        body: file,
      },
      FILE_UPLOAD_TIMEOUT_MS,
      'The private file upload took too long.',
    )
  } catch (error) {
    if (error instanceof ApiDeadlineError) throw error
    throw new Error('The private file upload could not reach storage. Check your connection and try again.', { cause: error })
  }
  assertCurrentContext()
  if (!uploadResponse.ok) {
    throw new Error(`The private file upload failed (${uploadResponse.status}). Try again or report the problem.`)
  }

  const payload = await postJson<{ document_import: FinancialDocumentImport }>(
    '/api/v1/document_imports/complete',
    { upload_token: presign.upload_token },
    {
      timeoutMs: EXTRACTION_REQUEST_TIMEOUT_MS,
      timeoutMessage: 'Document extraction took too long.',
    },
  )
  assertCurrentContext()
  return payload.document_import
}

function uploadContentType(file: File) {
  const extension = file.name.split('.').pop()?.toLowerCase()
  const types: Record<string, string> = {
    csv: 'text/csv',
    pdf: 'application/pdf',
    xls: 'application/vnd.ms-excel',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    png: 'image/png',
    webp: 'image/webp',
    heic: 'image/heic',
    heif: 'image/heif',
  }
  return types[extension ?? ''] ?? (file.type || 'application/octet-stream')
}

function contentSourceUploadType(file: File) {
  const extension = file.name.split('.').pop()?.toLowerCase()
  const types: Record<string, string> = {
    pdf: 'application/pdf',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    txt: 'text/plain',
    md: 'text/markdown',
    vtt: 'text/vtt',
    srt: 'application/x-subrip',
  }
  return types[extension ?? ''] ?? (file.type || 'application/octet-stream')
}

async function fileSha256(file: File) {
  if (!globalThis.crypto?.subtle) return undefined
  const digest = await globalThis.crypto.subtle.digest('SHA-256', await file.arrayBuffer())
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')
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
  const payload = await postJson<{ document_import: FinancialDocumentImport }>(
    `/api/v1/document_imports/${documentImportId}/reprocess`,
    {},
    {
      timeoutMs: EXTRACTION_REQUEST_TIMEOUT_MS,
      timeoutMessage: 'Document extraction took too long.',
    },
  )
  return payload.document_import
}

export async function deleteDocumentImportSource(documentImportId: number): Promise<FinancialDocumentImport> {
  const payload = await fetchJson<{ document_import: FinancialDocumentImport }>(`/api/v1/document_imports/${documentImportId}/source`, { method: 'DELETE' })
  return payload.document_import
}

export async function deleteDocumentImport(documentImportId: number): Promise<void> {
  await fetchJson<unknown>(`/api/v1/document_imports/${documentImportId}`, { method: 'DELETE' })
}

export async function fetchDocumentImportSourceUrl(documentImportId: number, signal?: AbortSignal): Promise<DocumentSourceUrl> {
  return fetchJson<DocumentSourceUrl>(`/api/v1/document_imports/${documentImportId}/source_url`, { signal, cache: 'no-store' })
}

// Derive this authenticated route from the import ID. Metadata URLs are never
// trusted destinations for Authorization, brand or coach-workspace headers.
export async function fetchDocumentImportSourceContent(documentImportId: number, download = false, signal?: AbortSignal): Promise<Blob> {
  if (!Number.isSafeInteger(documentImportId) || documentImportId < 1) throw new Error('A valid document import is required.')
  const path = `/api/v1/document_imports/${documentImportId}/source_content${download ? '?download=1' : ''}`
  return apiOperation(path, { signal, cache: 'no-store' }, { timeoutMs: 60_000, timeoutMessage: 'Private document content took too long.' }, async (response) => {
    if (!response.ok) throw await apiRequestError(response, 'Private document content could not be loaded.')
    return response.blob()
  })
}

export async function fetchDocumentImportSourcePreview(documentImportId: number, signal?: AbortSignal): Promise<DocumentSourcePreview> {
  return fetchJson<DocumentSourcePreview>(`/api/v1/document_imports/${documentImportId}/source_preview`, { signal, cache: 'no-store' })
}

export async function fetchSharedChallengeSource(enrollmentId: number, sourceId: number, supportAccessId: number | undefined, signal?: AbortSignal): Promise<Blob> {
  if (![enrollmentId, sourceId, ...(supportAccessId === undefined ? [] : [supportAccessId])].every(id => Number.isSafeInteger(id) && id > 0)) throw new Error('Choose an exact shared original.')
  const query = new URLSearchParams({record_type:'document_source',record_id:String(sourceId),download:'1'})
  if (supportAccessId !== undefined) query.set('support_access_id',String(supportAccessId))
  return apiOperation(`/api/v1/shared_challenges/${enrollmentId}/source_content?${query}`, {signal,cache:'no-store'}, {timeoutMs:60_000,timeoutMessage:'Shared original took too long.'}, async response => {
    if (!response.ok) throw await apiRequestError(response,'Shared original is no longer available.')
    return response.blob()
  })
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
    other_assets: wealth.summary.net_worth ?? 0,
    credit_card_debt: Math.abs(dashboard.accounts.find((account) => account.type === 'debt')?.balance ?? 0),
    debt_payment: dashboard.summary.debt_payments,
    target_runway_months: 6,
  }
}

export type CoachWorkspaceSettings = CoachWorkspaceSummary & {
  revision: number
  permissions: { manage: boolean }
}
export type CoachWorkspaceSettingsInput = {
  name: string
  revision?: number
  coach_profile: { display_name: string; title: string; bio: string }
}
export type WorkspaceBrandVersion = {
  id: number
  number: number
  digest: string
  published_at: string
  published_by: { id: number; full_name: string }
  restored_from_version?: { id: number; number: number } | null
  config?: BrandConfig
}
export type WorkspaceBrandConfiguration = {
  workspace: { id: number; name: string; slug: string }
  draft: BrandConfig
  draft_revision: number
  preview_required: boolean
  preview: { digest: string; draft_revision: number; generated_at: string } | null
  published_version: WorkspaceBrandVersion | null
  versions: WorkspaceBrandVersion[]
  permissions: { edit: boolean; preview: boolean; publish: boolean; rollback: boolean }
}
export type WorkspaceBrandPreview = {
  digest: string
  draft_revision: number
  generated_at: string
  brand: BrandConfig
}
export async function fetchCoachWorkspaceSettings(id: number): Promise<CoachWorkspaceSettings> {
  const result = await fetchJson<{ coach_workspace: CoachWorkspaceSettings }>(`/api/v1/admin/coach_workspaces/${id}`)
  return result.coach_workspace
}
export async function createCoachWorkspace(values: CoachWorkspaceSettingsInput, idempotencyKey: string): Promise<CoachWorkspaceSettings> {
  const result = await fetchJson<{ coach_workspace: CoachWorkspaceSettings }>('/api/v1/admin/coach_workspaces', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ coach_workspace: values }),
  })
  return result.coach_workspace
}
export async function updateCoachWorkspaceSettings(id: number, values: CoachWorkspaceSettingsInput): Promise<CoachWorkspaceSettings> {
  const result = await fetchJson<{ coach_workspace: CoachWorkspaceSettings }>(`/api/v1/admin/coach_workspaces/${id}`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ coach_workspace: values }),
  })
  return result.coach_workspace
}
export async function fetchWorkspaceBrand(): Promise<WorkspaceBrandConfiguration> {
  const result = await fetchJson<{ brand_configuration: WorkspaceBrandConfiguration }>('/api/v1/admin/brand')
  return result.brand_configuration
}
export async function saveWorkspaceBrand(draft: BrandConfig, revision: number): Promise<WorkspaceBrandConfiguration> {
  const result = await fetchJson<{ brand_configuration: WorkspaceBrandConfiguration }>('/api/v1/admin/brand', {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ brand_configuration: { draft_config: draft, draft_revision: revision } }),
  })
  return result.brand_configuration
}
export function previewWorkspaceBrand(revision: number): Promise<{ brand_configuration: WorkspaceBrandConfiguration; preview: WorkspaceBrandPreview }> {
  return postJson('/api/v1/admin/brand/preview', { brand_configuration: { draft_revision: revision } })
}
export function publishWorkspaceBrand(values: { draft_revision: number; preview_digest: string; expected_published_version_id: number | null }, idempotencyKey: string): Promise<{ brand_configuration: WorkspaceBrandConfiguration; published_version: WorkspaceBrandVersion }> {
  return fetchJson('/api/v1/admin/brand/publish', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ brand_configuration: values }),
  })
}
export function restoreWorkspaceBrandVersion(id: number, values: { draft_revision: number; expected_published_version_id: number | null }, idempotencyKey: string): Promise<{ brand_configuration: WorkspaceBrandConfiguration; published_version: WorkspaceBrandVersion }> {
  return fetchJson(`/api/v1/admin/brand/versions/${id}/rollback`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ brand_configuration: values }),
  })
}

export type WorkspaceCollaboratorRole = 'owner' | 'editor' | 'reviewer' | 'viewer'
export type WorkspaceCollaborator = {
  id: number; user_id: number; email: string; full_name: string; role: WorkspaceCollaboratorRole
  status: 'pending' | 'accepted' | 'revoked'; platform_admin: boolean; is_self: boolean; cohort_managed: boolean
}
export type WorkspaceCollaboratorsPayload = {
  workspace_id: number; permissions: { manage: boolean }; members: WorkspaceCollaborator[]; sign_in_url: string | null
}
export type CollaboratorDelivery = { sent: boolean; status: 'sent' | 'skipped' | 'failed'; provider_message_id: string | null }

export async function fetchWorkspaceCollaborators(workspaceId: number, signal?: AbortSignal): Promise<WorkspaceCollaboratorsPayload> {
  return fetchJson('/api/v1/admin/collaborators', { headers: { 'X-Coach-Workspace-Id': String(workspaceId) }, signal })
}

export async function addWorkspaceCollaborator(workspaceId: number, email: string, role: WorkspaceCollaboratorRole, sendEmail: boolean): Promise<{
  member: WorkspaceCollaborator; added: boolean; new_user: boolean; delivery: CollaboratorDelivery | null; sign_in_url: string | null
}> {
  return fetchJson('/api/v1/admin/collaborators', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Coach-Workspace-Id': String(workspaceId) },
    body: JSON.stringify({ collaborator: { email, role, send_email: sendEmail } }),
  })
}

export async function changeWorkspaceCollaborator(workspaceId: number, member: WorkspaceCollaborator, role: WorkspaceCollaboratorRole): Promise<{ member: WorkspaceCollaborator }> {
  return fetchJson(`/api/v1/admin/collaborators/${member.id}`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json', 'X-Coach-Workspace-Id': String(workspaceId) },
    body: JSON.stringify({ collaborator: { role, expected_role: member.role } }),
  })
}

export async function removeWorkspaceCollaborator(workspaceId: number, member: WorkspaceCollaborator): Promise<{ removed: boolean; platform_admin: boolean }> {
  return fetchJson(`/api/v1/admin/collaborators/${member.id}`, {
    method: 'DELETE', headers: { 'Content-Type': 'application/json', 'X-Coach-Workspace-Id': String(workspaceId) },
    body: JSON.stringify({ collaborator: { expected_role: member.role } }),
  })
}

export async function sendWorkspaceCollaboratorEmail(workspaceId: number, memberId: number): Promise<{ delivery: CollaboratorDelivery; sign_in_url: string | null }> {
  return fetchJson(`/api/v1/admin/collaborators/${memberId}/send_invitation`, {
    method: 'POST', headers: { 'X-Coach-Workspace-Id': String(workspaceId) },
  })
}

export type CohortInitialLaunch = {
  cohort: { id: number; name: string; participant_count: number }
  active_release_id: number | null
  release: { id: number; release_number: number } | null
  can_launch: boolean
  blockers: string[]
  preview_digest: string
  message: string
}

export async function fetchCohortInitialLaunch(cohortId: number, signal?: AbortSignal): Promise<CohortInitialLaunch> {
  const result = await fetchJson<{ launch: CohortInitialLaunch }>(`/api/v1/admin/cohorts/${cohortId}/launch`, { signal })
  return result.launch
}

export async function launchCohortRelease(
  cohortId: number,
  values: { release_id: number; preview_digest: string },
  requestId: string,
): Promise<{ launch: CohortInitialLaunch; replayed: boolean }> {
  return fetchJson(`/api/v1/admin/cohorts/${cohortId}/launch`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': requestId },
    body: JSON.stringify({ launch: values }),
  })
}

/** Withdraw one program enrollment, preserving the participant's global account. */
export async function removeCoachGroupParticipant(cohortId: number, userId: number, membershipId: number): Promise<{ removed: boolean; cohort_id: number }> {
  return fetchJson(`/api/v1/admin/cohorts/${cohortId}/participants/${userId}`, {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ expected_membership_id: membershipId }),
  })
}

// Participant-only challenge operations. Request identity belongs to the caller
// so an uncertain response can be retried with the exact same key and payload.
export async function fetchSavingsChallenge(signal?: AbortSignal): Promise<SavingsChallenge> {
  return checkedSavingsChallenge(await fetchJson<SavingsChallenge>('/api/v1/savings_challenge', { signal, cache: 'no-store' }))
}
export type SavingsCollection = 'entries' | 'entry_drafts' | 'entry_versions' | 'plan_drafts' | 'plan_versions' | 'zero_attestations'
export async function fetchSavingsPage<T extends SavingsEntry | SavingsEntryDraft | SavingsEntryVersion | SavingsPlanDraft | SavingsPlanVersion>(collection: SavingsCollection, cursor: number | null = null, signal?: AbortSignal): Promise<SavingsPage<T>> {
  const allowed: SavingsCollection[] = ['entries', 'entry_drafts', 'entry_versions', 'plan_drafts', 'plan_versions', 'zero_attestations']
  if (!allowed.includes(collection) || (cursor !== null && (!Number.isSafeInteger(cursor) || cursor < 1))) throw new Error('Invalid savings history page.')
  const page = await fetchJson<SavingsPage<T>>(`/api/v1/savings_challenge/${collection}?limit=10${cursor === null ? '' : `&cursor=${cursor}`}`, { signal, cache: 'no-store' })
  if (!Array.isArray(page.records) || page.records.length > 10 || page.records.some((record) => !Number.isSafeInteger(record.id) || record.id < 1) || new Set(page.records.map((record) => record.id)).size !== page.records.length || (page.next_cursor !== null && (!Number.isSafeInteger(page.next_cursor) || page.next_cursor < 1 || page.next_cursor <= (cursor ?? 0)))) throw new Error('Savings history could not be verified. Retry this page.')
  return page
}
async function savingsMutation<T>(path: string, values: object, requestId: string, signal?: AbortSignal): Promise<SavingsMutation<T>> {
  if (!requestId.trim()) throw new Error('A savings request identity is required.')
  const result = await fetchJson<SavingsMutation<T>>(`/api/v1/savings_challenge/${path}`, { method: 'POST', signal, headers: { 'Content-Type': 'application/json', 'Idempotency-Key': requestId }, body: JSON.stringify(values) })
  checkedSavingsChallenge(result.challenge)
  return result
}
export function enrollSavingsChallenge(values: { participation_accepted: true; policy_version: string; late_start_accepted: boolean; expected_acceptance_digest: string }, requestId: string, signal?: AbortSignal) {
  return savingsMutation<SavingsEnrollment>('enrollment', values, requestId, signal)
}
export function stageSavingsPlan(values: SavingsPlanInput, requestId: string, signal?: AbortSignal) {
  return savingsMutation<SavingsPlanDraft>('plan_drafts', values, requestId, signal)
}
export function approveSavingsPlan(id: number, values: SavingsPlanApproval, requestId: string, signal?: AbortSignal) {
  return savingsMutation<SavingsPlanVersion>(`plan_drafts/${savingsRecordId(id)}/approve`, values, requestId, signal)
}
export function stageSavingsEntry(values: SavingsEntryInput, requestId: string, signal?: AbortSignal) {
  return savingsMutation<SavingsEntryDraft>('entry_drafts', values, requestId, signal)
}
export function approveSavingsEntry(id: number, values: SavingsEntryApproval, requestId: string, signal?: AbortSignal) {
  return savingsMutation<SavingsEntryVersion>(`entry_drafts/${savingsRecordId(id)}/approve`, values, requestId, signal)
}
export function attestSavingsZero(values: { known_zero: true; cutoff_on: string; expected_enrollment_lock_version: number }, requestId: string, signal?: AbortSignal) {
  return savingsMutation<{ id: number; cutoff_on: string; approval_sequence: number; previous_attestation_id: number | null; approved_at: string }>('zero_attestations', values, requestId, signal)
}

function savingsRecordId(id: number): number {
  if (!Number.isSafeInteger(id) || id < 1) throw new Error('A valid savings record is required.')
  return id
}

export function fetchStatementReviewRequestStatus(importId: number, action: SourceReviewAction, key: string, signal?: AbortSignal): Promise<import('./lib/participantSourceReview').StatementReviewRequestStatus> {
  return fetchJson(`/api/v1/document_imports/${importId}/review_request_status?review_action=${action}`, { signal, cache: 'no-store', headers: { 'Idempotency-Key': key } })
}

export function fetchFinancialBaseline(signal?: AbortSignal): Promise<import('./lib/financialBaseline').BaselineCurrent> {
  return fetchJson('/api/v1/financial_baseline', { signal, cache: 'no-store' })
}
export function fetchBaselineContext(cursor: number | null, signal?: AbortSignal): Promise<import('./lib/financialBaseline').BaselineContext> {
  return fetchJson(`/api/v1/financial_baseline/context?cursor=${cursor ?? 0}`, { signal, cache: 'no-store' })
}
export function fetchBaselineHistory(cursor: number | null, signal?: AbortSignal): Promise<{ actor_scope: import('./lib/financialBaseline').BaselineScope; local_today: string; records: import('./lib/financialBaseline').BaselineVersion[]; next_cursor: number | null }> {
  return fetchJson(`/api/v1/financial_baseline/history?cursor=${cursor ?? 0}`, { signal, cache: 'no-store' })
}
export function previewFinancialBaseline(request: import('./lib/financialBaseline').BaselineRequest, signal?: AbortSignal): Promise<import('./lib/financialBaseline').BaselinePreview> {
  return fetchJson('/api/v1/financial_baseline/preview', { method: 'POST', signal, cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ request }) })
}
export function approveFinancialBaseline(action: 'approve' | 'revise', input: import('./lib/financialBaseline').BaselineApproval, key: string): Promise<import('./lib/financialBaseline').BaselineMutation> {
  return fetchJson(`/api/v1/financial_baseline/${action}`, { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key }, body: JSON.stringify(input) })
}
export function fetchBaselineRequestStatus(action: 'approve' | 'revise', key: string, signal?: AbortSignal): Promise<import('./lib/financialBaseline').BaselineStatus> {
  return fetchJson(`/api/v1/financial_baseline/request_status?approval_action=${action}`, { signal, cache: 'no-store', headers: { 'Idempotency-Key': key } })
}
export function fetchBaselineObservations<T extends import('./lib/financialBaseline').BaselineActualRecord | ReviewedRow>(kind: import('./lib/financialBaseline').BaselineObservationKind, start: string, end: string, cursor: number | null, signal?: AbortSignal): Promise<import('./lib/financialBaseline').BaselineObservationPage<T>> {
  const query = new URLSearchParams({ kind, window_start_on: start, window_end_on: end, cursor: String(cursor ?? 0) })
  return fetchJson(`/api/v1/financial_baseline/observations?${query}`, { signal, cache: 'no-store' })
}

export function fetchDailyContext(localOn?: string, signal?: AbortSignal): Promise<import('./lib/dailyChallenge').DailyContext> {
  const query = localOn ? `?${new URLSearchParams({ local_on: localOn })}` : ''
  return fetchJson(`/api/v1/savings_challenge/daily${query}`, { signal, cache: 'no-store' })
}
export function fetchDailyPage<T>(collection: import('./lib/dailyChallenge').DailyCollection, cursor: number | null, parentId?: number, signal?: AbortSignal): Promise<import('./lib/dailyChallenge').DailyPage<T>> {
  const query = new URLSearchParams({ collection })
  if (cursor !== null) query.set('cursor', String(cursor))
  if (parentId !== undefined) query.set('parent_id', String(parentId))
  return fetchJson(`/api/v1/savings_challenge/daily/records?${query}`, { signal, cache: 'no-store' })
}
export function fetchDailyCandidates(localOn: string, cursor: number | null, signal?: AbortSignal): Promise<import('./lib/dailyChallenge').DailyPage<import('./lib/dailyChallenge').DailyCandidate>> {
  return fetchJson(`/api/v1/savings_challenge/daily/candidates?${new URLSearchParams({ local_on: localOn, ...(cursor === null ? {} : { cursor: String(cursor) }) })}`, { signal, cache: 'no-store' })
}
export function mutateDaily<T>(action: Exclude<import('./lib/dailyChallenge').DailyAction, 'reflection_erase'>, input: import('./lib/dailyChallenge').DailyInput, key: string): Promise<import('./lib/dailyChallenge').DailyResult<T>> {
  return fetchJson(`/api/v1/savings_challenge/daily/actions/${action}`, { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key }, body: JSON.stringify(input) })
}
export function fetchDailyRequestStatus(action: Exclude<import('./lib/dailyChallenge').DailyAction, 'reflection_erase'>, key: string): Promise<import('./lib/dailyChallenge').DailyStatus> {
  return fetchJson(`/api/v1/savings_challenge/daily/request_status?review_action=${action}`, { cache: 'no-store', headers: { 'Idempotency-Key': key } })
}
export function eraseDailyReflection(id: number, input: import('./lib/dailyChallenge').DailyInput, key: string): Promise<import('./lib/dailyChallenge').DailyEraseResult> {
  return fetchJson(`/api/v1/savings_challenge/daily/reflections/${id}/erase`, { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key }, body: JSON.stringify(input) })
}
export function fetchDailyEraseStatus(id: number, key: string): Promise<import('./lib/dailyChallenge').DailyEraseStatus> {
  return fetchJson(`/api/v1/savings_challenge/daily/reflections/${id}/erase_status`, { cache: 'no-store', headers: { 'Idempotency-Key': key } })
}

// Scoped modules share the same authenticated, deadline-bounded transport.
export { fetchJson as fetchPrivateJson, postJson as postPrivateJson }

// Plan recovery checks the journal under the current authorized workspace.
export async function fetchSavingsPlanRequestStatus(action: 'plan_stage' | 'plan_approve', requestId: string): Promise<import('./lib/savingsChallenge').SavingsPlanRequestStatus> {
  if (!requestId.trim() || !['plan_stage', 'plan_approve'].includes(action)) throw new Error('A valid plan request identity is required.')
  const result = await fetchJson<import('./lib/savingsChallenge').SavingsPlanRequestStatus>(`/api/v1/savings_challenge/request_status?review_action=${action}`, { cache: 'no-store', headers: { 'Idempotency-Key': requestId } })
  if (result.state === 'committed') checkedSavingsChallenge(result.challenge)
  return result
}

export async function fetchHomeSavingsRequestStatus(action: import('./lib/homeSavingsRecovery').HomeSavingsAction, requestId: string, signal?: AbortSignal): Promise<import('./lib/homeSavingsRecovery').HomeSavingsStatus> {
  if (!requestId.trim() || !['enrollment', 'entry_stage', 'entry_approve', 'zero_attest'].includes(action)) throw new Error('A valid savings request identity is required.')
  const result = await fetchJson<import('./lib/homeSavingsRecovery').HomeSavingsStatus>(`/api/v1/savings_challenge/request_status?review_action=${action}`, { signal, cache: 'no-store', headers: { 'Idempotency-Key': requestId } })
  if (!Number.isSafeInteger(result.cohort_id) || result.cohort_id < 1 || !Number.isSafeInteger(result.actor_scope?.user_id) || !Number.isSafeInteger(result.actor_scope?.household_id) || result.actor_scope.user_id < 1 || result.actor_scope.household_id < 1 || !['committed', 'unknown', 'in_flight'].includes(result.state) || (result.state === 'unknown' && result.can_retry !== true)) throw new Error('The savings request result cannot be verified. Check again before making changes.')
  if (result.state === 'committed') checkedSavingsChallenge(result.challenge)
  return result
}
