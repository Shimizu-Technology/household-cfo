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

export type WorkspaceData = {
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
  publication_digest: string
  published_at: string
  published_by: AdminPersonaUser
  config?: PersonaConfiguration
  restored_from_version?: null | {
    id: number
    number: number
  }
  content_packs?: AdminContentPackVersion[]
}

export type AdminContentItemKind = 'guidance' | 'script' | 'example' | 'phrase' | 'culture' | 'finance_reference'
export type AdminContentPackKind = 'voice_culture' | 'coaching_method' | 'finance_reference'
export type AdminContentScope = 'coach' | 'platform'
export type AdminContentSourceStatus = 'upload_cleanup_failed' | 'queued' | 'processing' | 'needs_review' | 'failed' | 'deletion_pending' | 'deletion_failed' | 'source_deleted'

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
}

export type AdminPersonaRollbackInput = {
  draft_revision: number
  expected_published_version_id: number | null
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
}

export type PilotFeedbackReceipt = {
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
  permissions: { edit: boolean; publish: boolean; rollback: boolean }
}

export type CohortExperiencePreview = {
  digest: string
  draft_revision: number
  generated_at: string
  modules: ExperienceCapability[]
}

export type AdminInviteEmailStatus = 'hidden' | 'not_sent' | 'skipped' | 'sent' | 'failed'

export type AdminUser = CurrentUser & {
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
const MIA_REQUEST_TIMEOUT_MS = 90_000
const FILE_UPLOAD_TIMEOUT_MS = 180_000
const EXTRACTION_REQUEST_TIMEOUT_MS = 300_000
let authTokenGetter: AuthTokenGetter | null = null
let activeCoachWorkspaceId = readStoredCoachWorkspaceId()

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
  authTokenGetter = getter
}

export function setActiveCoachWorkspaceId(workspaceId: number | null) {
  activeCoachWorkspaceId = workspaceId
  if (typeof window === 'undefined') return

  if (workspaceId) window.localStorage.setItem('household-cfo:coach-workspace-id', String(workspaceId))
  else window.localStorage.removeItem('household-cfo:coach-workspace-id')
}

function readStoredCoachWorkspaceId() {
  if (typeof window === 'undefined') return null

  const parsed = Number.parseInt(window.localStorage.getItem('household-cfo:coach-workspace-id') ?? '', 10)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null
}

async function authHeaders(): Promise<Record<string, string>> {
  if (!authTokenGetter) return {}

  const token = await authTokenGetter()
  return token ? { Authorization: `Bearer ${token}` } : {}
}

async function withDeadline<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  timeoutMs: number,
  timeoutMessage: string,
  callerSignal?: AbortSignal | null,
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
      reject(new ApiDeadlineError(`${timeoutMessage} Please try again.`))
      controller.abort()
    }, timeoutMs)
  })

  try {
    return await Promise.race([operation(controller.signal), deadlinePromise])
  } catch (error) {
    if (error instanceof ApiDeadlineError) throw error
    if (deadlineReached) {
      throw new ApiDeadlineError(`${timeoutMessage} Please try again.`, { cause: error })
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
  try {
    const headers = {
      ...(await authHeaders()),
      ...(activeCoachWorkspaceId ? { 'X-Coach-Workspace-Id': String(activeCoachWorkspaceId) } : {}),
      ...(options.headers as Record<string, string> | undefined),
    }
    return fetch(`${API_BASE}${path}`, {
      ...options,
      headers,
      ...(signal ? { signal } : {}),
    })
  } catch (error) {
    throw new Error(apiNetworkErrorMessage('API request could not reach the server'), { cause: error })
  }
}

async function apiOperation<T>(
  path: string,
  options: RequestInit,
  settings: ApiFetchSettings,
  consume: (response: Response) => Promise<T>,
) {
  const request = async (signal?: AbortSignal) => consume(await apiFetch(path, options, signal))

  const method = (options.method ?? 'GET').toUpperCase()
  const safeReadTimeoutMs = method === 'GET' || method === 'HEAD'
    ? SAFE_READ_REQUEST_TIMEOUT_MS
    : undefined
  const timeoutMs = settings.timeoutMs ?? safeReadTimeoutMs

  return timeoutMs === undefined
    ? request()
    : withDeadline(
        request,
        timeoutMs,
        settings.timeoutMessage ?? 'This request took too long.',
        options.signal,
      )
}

async function fetchJsonResponse<T>(path: string, options: RequestInit = {}, settings: ApiFetchSettings = {}) {
  return apiOperation(path, options, settings, async (response) => {
    if (!response.ok) {
      throw await apiRequestError(response, 'API request failed')
    }

    if (response.status === 204) return { status: response.status, payload: undefined as T }

    return { status: response.status, payload: await response.json() as T }
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
  const maximumPolls = 60
  for (let poll = 0; poll < maximumPolls; poll += 1) {
    const response = await fetchJsonResponse<T | { code?: string; retry_after_ms?: number }>(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }, {
      timeoutMs: MIA_REQUEST_TIMEOUT_MS,
      timeoutMessage: 'Mia took too long to finish this request.',
    })

    if (response.status === 202) {
      const payload = response.payload as { code?: string; retry_after_ms?: number }
      if (payload.code !== 'mia_request_processing') {
        throw new Error('Mia returned an unexpected processing response. Please try again.')
      }

      const retryAfter = Math.max(100, Math.min(payload.retry_after_ms ?? 500, 2_000))
      await new Promise((resolve) => globalThis.setTimeout(resolve, retryAfter))
      continue
    }

    return response.payload as T
  }

  throw new Error('Mia is still working on that exact request. Wait a moment, then try again; your retry will not create a duplicate.')
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

export async function fetchCurrentUser(): Promise<CurrentUser> {
  try {
    const payload = await fetchJson<{ user: CurrentUser }>('/api/v1/auth/me')
    return payload.user
  } catch (error) {
    if (!(error instanceof ApiRequestError) || error.status !== 404 || !activeCoachWorkspaceId) throw error

    setActiveCoachWorkspaceId(null)
    const payload = await fetchJson<{ user: CurrentUser }>('/api/v1/auth/me')
    return payload.user
  }
}

export async function submitPilotFeedback(values: PilotFeedbackInput): Promise<PilotFeedbackReceipt> {
  const formData = new FormData()
  formData.append('feedback_report[workflow]', values.workflow)
  formData.append('feedback_report[attempted]', values.attempted)
  formData.append('feedback_report[expected]', values.expected)
  formData.append('feedback_report[actual]', values.actual)
  if (values.screenshot) formData.append('screenshot', values.screenshot)

  let response: Response
  try {
    response = await fetch(`${API_BASE}/api/v1/pilot_feedback_reports`, {
      method: 'POST',
      headers: await authHeaders(),
      body: formData,
    })
  } catch (error) {
    throw new Error(apiNetworkErrorMessage('Feedback submission could not reach the API'), { cause: error })
  }

  if (!response.ok) throw new Error(await responseErrorMessage(response, 'Feedback submission failed'))

  const payload = (await response.json()) as { feedback_report: PilotFeedbackReceipt }
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

export async function rollbackAdminPersonaVersion(
  personaId: number,
  versionId: number,
  values: AdminPersonaRollbackInput,
): Promise<AdminPersonaPublicationResponse> {
  return postJson<AdminPersonaPublicationResponse>(
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
  filters: { query?: string; accountId?: number | null; reviewYear?: number } = {},
): Promise<PlaidTransactionsPage> {
  const query = new URLSearchParams({ limit: '50', page: String(page), view })
  if (filters.query) query.set('query', filters.query)
  if (filters.accountId) query.set('account_id', String(filters.accountId))
  if (filters.reviewYear) query.set('review_year', String(filters.reviewYear))
  return fetchJson<PlaidTransactionsPage>(`/api/v1/plaid/transactions?${query}`)
}

export async function updatePlaidItemPreferences(itemId: number, values: { auto_confirm_trusted_merchants: boolean }): Promise<PlaidOverview> {
  return fetchJson<PlaidOverview>(`/api/v1/plaid/items/${itemId}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(values),
  })
}

export async function stagePlaidTransactions(transactionIds: number[]): Promise<{ drafted_count: number; transaction_draft_ids: number[] }> {
  return postJson('/api/v1/plaid/transactions/stage', { transaction_ids: transactionIds })
}

export async function ignorePlaidTransactions(transactionIds: number[]): Promise<{ ignored_count: number }> {
  return postJson('/api/v1/plaid/transactions/ignore', { transaction_ids: transactionIds })
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
        timeoutMessage: 'Mia took too long to finish this request.',
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

export async function uploadDocumentImport(file: File, documentKind: DocumentImportKind, origin: 'profile' | 'mia' = 'profile', uploadContext = '', documentKindExplicit = origin === 'profile'): Promise<FinancialDocumentImport> {
  const uploadRequestId = clientRequestId()
  const contentType = uploadContentType(file)
  const checksumSha256 = await fileSha256(file)
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
    other_assets: wealth.summary.net_worth ?? 0,
    credit_card_debt: Math.abs(dashboard.accounts.find((account) => account.type === 'debt')?.balance ?? 0),
    debt_payment: dashboard.summary.debt_payments,
    target_runway_months: 6,
  }
}
