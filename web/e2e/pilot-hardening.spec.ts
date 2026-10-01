import { expect, test, type Page } from '@playwright/test'

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const currentMonth = new Intl.DateTimeFormat('en-US', { month: 'long' }).format(new Date())
const currentShortMonth = new Intl.DateTimeFormat('en-US', { month: 'short' }).format(new Date())
const currentYear = new Date().getFullYear()

async function openSection(page: Page, name: string) {
  const section = page.getByRole('link', { name, exact: true })
  const tools = page.getByRole('button', { name: 'Tools', exact: true })
  await expect(tools).toBeVisible()
  if (!(await section.isVisible())) {
    await tools.click()
    await expect(section).toBeVisible()
  }
  await section.click()
  await expect(tools).toHaveAttribute('aria-expanded', 'false')
  await expect(page.locator('.tabs-tools-backdrop')).toHaveCount(0)
}

const profile = {
  household: { name: 'Pilot Household', stage: 'First cohort', location: 'Guam', primary_goal: 'Build a calm annual rhythm.' },
  coach: { name: 'Mia', role: 'AI coach', voice: 'Warm and direct' },
  members: [], priorities: [], completeness: 100, uploads: [], sections: [],
}

const dashboard = {
  summary: {
    monthly_income: 14_200, fixed_expenses: 6_000, flexible_spend: 1_500, debt_payments: 200,
    monthly_surplus_rate_percent: 38, runway_months: 0.5, next_safe_to_spend_amount: 0,
    readiness_available: true, readiness_tone: 'red', readiness_label: 'Red — pause and stabilize basics',
  },
  action_center: {
    transaction_review_count: 2, mia_action_review_count: 1, total_review_count: 3,
    current_month_label: currentMonth, current_month_index: new Date().getMonth(), current_year: currentYear,
  },
  coach_read: {
    title: 'Protect the baseline and build runway.',
    body: 'The household is Red because essential stability or runway is not protected yet.',
  },
  readiness_path: {
    current_runway_months: 0.5, target_runway_months: 6, protected_liquid_amount: 5_000, monthly_surplus: 4_795,
    yellow: { tone: 'yellow', runway_months: 3, protected_liquid_target: 28_215, protected_liquid_gap: 23_215, cash_flow_requirement: 'Nonnegative monthly cash flow', reached: false },
    green: { tone: 'green', runway_months: 6, protected_liquid_target: 56_430, protected_liquid_gap: 51_430, cash_flow_requirement: 'Positive monthly cash flow', reached: false },
  },
  accounts: [],
  alerts: [{ tone: 'red', title: 'Readiness', body: 'Red — pause and stabilize basics' }],
  next_steps: ['Protect fixed bills first.', 'Pause new wants and direct available surplus to runway.', 'Review pending activity.'],
}

function categoryMonths(categoryId: number, planned: number, currentActual: number, decemberPlanned = planned) {
  return months.map((label, index) => {
    const actual = label === currentShortMonth ? currentActual : 0
    const monthPlanned = index === 11 ? decemberPlanned : planned
    return {
      period_id: index + 1,
      allocation_id: categoryId * 100 + index + 1,
      planned: monthPlanned,
      actual,
      remaining: monthPlanned - actual,
    }
  })
}

const annualOutlookMonths = months.map((label, index) => ({
  period_id: index + 1,
  label,
  starts_on: `${currentYear}-${String(index + 1).padStart(2, '0')}-01`,
  income: index >= 7 ? 15_000 : 14_200,
  category_plan: index === 11 ? 8_300 : 5_300,
  debt_minimums: 200,
  planned_outflow: index === 11 ? 8_500 : 5_500,
  baseline_surplus: (index >= 7 ? 15_000 : 14_200) - (index === 11 ? 8_500 : 5_500),
  expected_irregular: index === 11 ? 3_000 : 0,
  expected_contributors: index === 11 ? [{ name: 'Holiday travel', amount: 3_000 }] : [],
}))

const budget = {
  framework: 'Expense Stack', intro: 'Annual household plan', monthly_income: 14_200,
  total_monthly_outflow: 5_500, baseline_surplus: 8_700,
  stacks: [
    { label: 'Non-discretionary', color: 'red', amount: 4_000, description: 'Fixed', examples: [] },
    { label: 'Discretionary', color: 'yellow', amount: 450, description: 'Flexible', examples: [] },
    { label: 'Sinking Fund — Expected', color: 'green', amount: 600, description: 'Known future costs', examples: [] },
    { label: 'Sinking Fund — Unexpected', color: 'gold', amount: 250, description: 'Life happens', examples: [] },
  ],
  custom_categories_note: 'Use household language.',
  annual_plan: {
    year: currentYear,
    months: months.map((label, index) => ({ id: index + 1, label, starts_on: `${currentYear}-${String(index + 1).padStart(2, '0')}-01`, ends_on: `${currentYear}-${String(index + 1).padStart(2, '0')}-28`, status: 'open' })),
    rows: [
      { id: 1, name: 'Fixed essentials', stack_key: 'non_discretionary', stack_label: 'Non-discretionary', active: true, months: categoryMonths(1, 4_000, 2_800), planned_total: 48_000, actual_total: 2_800 },
      { id: 2, name: 'Dining out', stack_key: 'discretionary', stack_label: 'Discretionary', active: true, months: categoryMonths(2, 450, 475), planned_total: 5_400, actual_total: 475 },
      { id: 3, name: 'Expected sinking fund', stack_key: 'sinking_expected', stack_label: 'Sinking Fund — Expected', active: true, months: categoryMonths(3, 600, 200, 3_600), planned_total: 10_200, actual_total: 200 },
      { id: 4, name: 'Unexpected sinking fund', stack_key: 'sinking_unexpected', stack_label: 'Sinking Fund — Unexpected', active: true, months: categoryMonths(4, 250, 0), planned_total: 3_000, actual_total: 0 },
    ],
    monthly_income: Object.fromEntries(months.map((_, index) => [index + 1, index >= 7 ? 15_000 : 14_200])),
    monthly_debt_minimums: 200,
    income_sources: [{
      id: 1, label: 'Primary income', source_type: 'job', base_amount: 14_200, base_cadence: 'monthly',
      schedule_entries: [{ id: 1, entry_type: 'recurring_change', label: null, amount: 15_000, cadence: 'monthly', effective_on: `${currentYear}-08-01` }],
    }],
    annual_outlook: {
      typical_monthly_outflow: 5_500,
      months: annualOutlookMonths,
      upcoming_spikes: [{ ...annualOutlookMonths[11], amount_above_typical: 3_000 }],
      next_irregular_month: annualOutlookMonths[11],
    },
    pending_transaction_drafts: [
      { id: 91, occurred_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-12`, merchant: 'Dinner with friends', amount: 75, amount_cents: 7_500, status: 'pending', source_type: 'receipt', category_id: 2, category_name: 'Dining out' },
      { id: 92, occurred_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-15`, merchant: 'Storm supplies', amount: 40, amount_cents: 4_000, status: 'pending', source_type: 'manual_chat', category_id: 4, category_name: 'Unexpected sinking fund' },
    ], pending_mia_action_drafts: [], recent_transactions: [], archived_categories: [],
  },
}

const wealth = {
  summary: { net_worth: 12_345_678.9, liquid_net_worth: 1_234_567.89, ten_year_surplus_capacity: 98_765_432.1, monthly_surplus_available: 12_345.67 },
  milestones: [{ kind: 'debt_remaining', label: 'Debt payoff', current: 5_400, target: 0, unit: 'dollars', status: 'yellow' }],
  guidance: 'Protect options.',
}
const optionality = {
  scenario: 'Founder transition', question: 'Can I leave my job?', target_runway_months: 6, current_runway_months: 0.5, monthly_gap: 4_795,
  choices: [
    { label: 'Stay the course', fit_label: 'Best fit now', fit_tone: 'green', upside: 'Protects the baseline.', tradeoff: 'The transition takes longer.' },
    { label: 'Hybrid transition', fit_label: 'Build runway first', fit_tone: 'red', upside: 'Keeps stable income.', tradeoff: 'Runway is not ready yet.' },
    { label: 'Leap now', fit_label: 'Not ready yet', fit_tone: 'red', upside: 'Maximum focus.', tradeoff: 'Close the runway gap first.' },
  ],
  levers: [{ label: 'Green runway gap', amount: 51_430 }, { label: 'Annual income protected', amount: 170_400 }],
}
const cfoFilter = { framework: 'CFO Filter', prompt: 'Pressure-test the move.', decisions: [{ item: 'Large planned purchase', amount: 1_234_567.89, recommendation: 'Wait', reason: 'Protect runway first.' }], targets: [], priority_stack: ['Essential bills', 'Expected expenses', 'Runway'] }

function experienceCapabilities(optionalModules: { cfo_filter?: boolean; optionality?: boolean } = {}) {
  const enabled = { cfo_filter: optionalModules.cfo_filter ?? true, optionality: optionalModules.optionality ?? true }
  return {
    schema_version: 1,
    source: 'published_cohort',
    cohort_id: 41,
    experience_version: { id: 301, number: 1 },
    modules: ([
      ['home', 'Home', true], ['review', 'Review', true], ['ask_mia', 'Ask Mia', true], ['budget', 'Budget', true],
      ['profile', 'My Profile', true], ['wealth', 'Wealth', true], ['cfo_filter', 'CFO Filter', false], ['optionality', 'Optionality', false],
    ] as const).map(([id, label, core]) => {
      const moduleEnabled = core || enabled[id as keyof typeof enabled]
      return {
        id, label, core, enabled: moduleEnabled,
        ...(moduleEnabled ? {} : { unavailable_message: `${label} is not included in this cohort right now. You can still ask Mia about this decision.` }),
      }
    }),
  }
}

const miaBudgetDraft = {
  id: 71, status: 'pending', draft_type: 'budget_edit', year: currentYear,
  title: 'Move more into the unexpected sinking fund',
  summary: 'Mia drafted a planned-budget change for review.', rationale: 'Keep actual spending unchanged.', source_prompt: null,
  created_at: '2026-07-17T00:00:00Z', applied_at: null, canceled_at: null,
  impact: {
    scope: `${currentShortMonth} ${currentYear}`, before_monthly_income: 14_200, after_monthly_income: 14_200,
    before_monthly_outflow: 5_500, after_monthly_outflow: 5_650,
    before_baseline_surplus: 8_700, after_baseline_surplus: 8_550,
  },
  items: [{ id: 711, action_type: 'update_allocation', target_record_type: 'BudgetCategory', target_record_id: 4, label: 'Unexpected sinking fund', description: 'Increase the monthly plan after review.', payload: { changes: [{ month: 8 }] }, before_snapshot: {}, after_snapshot: {} }],
}

const miaHouseholdDraft = {
  id: 72, status: 'pending', draft_type: 'household_setup', year: currentYear,
  title: 'Update an approved household number', summary: 'Mia prepared one household change for your review.',
  rationale: 'These values shape Mia’s coaching and stay unchanged until approved.', source_prompt: 'My emergency fund is now $8,500.',
  created_at: '2026-08-17T00:00:00Z', applied_at: null, canceled_at: null,
  impact: {
    scope: 'Current monthly snapshot', before_monthly_income: 14_200, after_monthly_income: 14_200,
    before_monthly_outflow: 5_500, after_monthly_outflow: 5_500,
    before_baseline_surplus: 8_700, after_baseline_surplus: 8_700,
  },
  setup_coverage_after_apply: {
    complete: true, completed_count: 5, required_count: 5,
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
  items: [{
    id: 721, action_type: 'update_setup_value', target_record_type: 'Household', target_record_id: 77,
    label: 'Emergency fund', description: '$5,000.00 → $8,500.00', payload: { key: 'emergency_fund', value: 8_500 },
    before_snapshot: { key: 'emergency_fund', value: 5_000, display: '$5,000.00' },
    after_snapshot: { key: 'emergency_fund', value: 8_500, display: '$8,500.00' },
  }],
}

const miaIncomeDraft = {
  id: 73, status: 'pending', draft_type: 'income_schedule', year: currentYear,
  title: 'Schedule an income change', summary: `Mia prepared setting Primary income to $15,500 per month beginning October ${currentYear}.`,
  rationale: 'The income timeline changes only after approval.', source_prompt: null,
  created_at: '2026-08-17T00:00:00Z', applied_at: null, canceled_at: null,
  impact: {
    scope: `October ${currentYear}`, before_monthly_income: 15_000, after_monthly_income: 15_500,
    before_monthly_outflow: 5_500, after_monthly_outflow: 5_500,
    before_baseline_surplus: 9_500, after_baseline_surplus: 10_000,
  },
  items: [{
    id: 731, action_type: 'upsert_income_schedule_entry', target_record_type: 'IncomeSource', target_record_id: 1,
    label: 'Set Primary income to $15,500.00 per month', description: `Beginning October ${currentYear}: $15,000.00 → $15,500.00 per month.`,
    payload: { income_source_id: 1, entry_type: 'recurring_change', amount_cents: 1_550_000, effective_on: `${currentYear}-10-01` },
    before_snapshot: { effective_monthly_cents: 1_500_000 }, after_snapshot: { effective_monthly_cents: 1_550_000 },
  }],
}

function realWorkspaceData(setupComplete = false) {
  return {
    workspace: {
      mode: 'real', household_id: 77, setup_complete: setupComplete,
      setup_status: {
        complete: setupComplete,
        completed_count: setupComplete ? 5 : 0,
        required_count: 5,
        required_fields: [
          { key: 'household_name', label: 'Household name', confirmed: setupComplete },
          { key: 'primary_goal', label: 'Primary goal', confirmed: setupComplete },
          { key: 'primary_income', label: 'Primary monthly income', confirmed: setupComplete },
          { key: 'fixed_expenses', label: 'Fixed essentials', confirmed: setupComplete },
          { key: 'flexible_spend', label: 'Flexible spending', confirmed: setupComplete },
        ],
        confirmed_fields: setupComplete ? ['household_name', 'primary_goal', 'primary_income', 'fixed_expenses', 'flexible_spend'] : [],
        missing_fields: setupComplete ? [] : [
          { key: 'household_name', label: 'Household name', confirmed: false },
          { key: 'primary_goal', label: 'Primary goal', confirmed: false },
          { key: 'primary_income', label: 'Primary monthly income', confirmed: false },
          { key: 'fixed_expenses', label: 'Fixed essentials', confirmed: false },
          { key: 'flexible_spend', label: 'Flexible spending', confirmed: false },
        ],
      },
      debts: [],
      cohort: { id: 41, name: 'BOG', role: 'participant', status: 'active' },
      capabilities: experienceCapabilities(),
      setup_values: {
        household_name: 'Test Participant Household', primary_goal: 'Build a calm monthly plan.',
        primary_income: setupComplete ? 5_000 : 0, business_income: 0, fixed_expenses: setupComplete ? 2_500 : 0,
        flexible_spend: setupComplete ? 600 : 0, expected_sinking_fund: 0, unexpected_sinking_fund: 0,
        emergency_fund: 0, other_assets: 0, credit_card_debt: 0, debt_payment: 0, target_runway_months: 6,
      },
    },
    profile: { ...profile, completeness: setupComplete ? 86 : 29 },
    dashboard,
    budget: { ...budget, annual_plan: { ...budget.annual_plan, pending_mia_action_drafts: [miaBudgetDraft] } },
    wealth,
    optionality,
    cfoFilter,
    mia: { messages: chatMessages(), oldest_message_id: 1, older_message_count: 0, has_older_messages: false, quick_prompts: ['Can I buy the purse?'], disclaimer: 'Education only.' },
  }
}

const pilotCohort = {
  id: 41, name: 'Household CFO pilot', status: 'active', starts_on: '2026-07-01', ends_on: '2026-08-31', notes: '',
  member_count: 1, participant_count: 1, staff_count: 0, setup_complete_count: 0,
  operational_summary: { available: true, period_days: 7, mia_requests: 18, mia_failures: 1, average_mia_latency_ms: 840, uploads: 7, upload_failures: 1, participants_active: 1 },
  created_at: '2026-07-01T00:00:00Z', updated_at: '2026-07-01T00:00:00Z',
  created_by: { id: 900, email: 'admin@pilot.test', full_name: 'Pilot Admin' },
}

const pilotAdminUser = {
  id: 901, clerk_id: 'e2e_participant', email: 'participant@pilot.test', first_name: 'Test', last_name: 'Participant', full_name: 'Test Participant',
  role: 'participant', invitation_status: 'accepted', invited_at: '2026-07-01T00:00:00Z', accepted_at: '2026-07-02T00:00:00Z',
  last_sign_in_at: '2026-07-17T00:00:00Z', created_at: '2026-07-01T00:00:00Z',
  is_admin: false, is_coach: false, is_participant: true, is_staff: false,
  invited_by: { id: 900, email: 'admin@pilot.test', full_name: 'Pilot Admin' },
  invite_email: { status: 'sent', provider_message_id: null, error: null, last_attempted_at: '2026-07-01T00:00:00Z', last_sent_at: '2026-07-01T00:00:00Z', last_sent_by: null, delivery_log: [] },
  cohorts: [{ id: 1, role: 'participant', cohort: { id: 41, name: 'Household CFO pilot', status: 'active' } }],
  workspace: { invited: true, signed_in: true, setup_status: 'started', setup_complete: false, has_pending_review_work: true, last_safe_activity_at: '2026-07-17T00:00:00Z' },
}

const personaConfiguration = {
  version: 1 as const,
  identity: {
    assistant_name: 'Coach Lani', human_coach_name: 'Mrs. Mel', human_coach_title: 'Financial coach',
    assistant_relationship: "A digital coaching assistant that applies the human coach's approved teaching without impersonating the human coach.",
    disclosure: "Be clear that this is a digital assistant guided by the human coach's published approach.",
    audience: "People participating in Mrs. Mel's financial education program.", client_term: 'participant',
  },
  voice: {
    tone_traits: ['warm', 'direct', 'respectful'], energy: 'Calm and focused.',
    accountability_style: "Name choices and patterns clearly while protecting the participant's dignity.",
    language_style: ['Use plain language.', 'Keep the next step concrete.'],
  },
  coaching: {
    philosophy: 'Help the participant understand the decision and make one practical move at a time.',
    method: 'Answer the direct question, explain the reasoning, and identify one useful next step.',
    principles: ["Use the participant's confirmed information.", 'Coach decisions and patterns without shame.'],
    do: [], do_not: [],
  },
  culture: {
    locale_label: 'No locale selected',
    context: 'Use only cultural and community context explicitly approved by the human coach.',
    local_realities: [], references: [],
  },
  phrases: [],
  curriculum: { guidance: [], scripts: [], examples: [] },
  response_shape: {
    min_sentences: 2, max_sentences: 5, max_characters: 1500,
    plain_text_only: true, validate_before_coaching: true, next_move_required: true,
  },
}

function personaDetailFixture() {
  return {
    id: 81,
    name: 'Coach Lani',
    description: "Mrs. Mel's first cohort voice",
    role: "A digital coaching assistant that applies the human coach's approved teaching without impersonating the human coach.",
    status: 'draft',
    owner: { id: 900, email: 'admin@pilot.test', full_name: 'Pilot Admin' },
    published_version: null,
    visible_assignment_count: 0,
    updated_at: '2026-10-01T00:00:00Z',
    permissions: { read: true, edit: true, publish: true, assign: true, archive: true, restore: false },
    draft_revision: 1,
    has_unpublished_changes: true,
    preview_required: true,
    guardrails: {
      editable: false,
      source: 'Household CFO system',
      rules: [
        'Use only approved household financial facts.',
        'Keep the participant in control of every financial write.',
        'Do not provide licensed advice or bypass crisis handling.',
        'Do not imitate accents or invent cultural stereotypes.',
      ],
    },
    versions: [],
    assignments: [],
    draft: structuredClone(personaConfiguration),
    content_packs: [] as unknown[],
    preview: null,
  }
}

const pilotFeedbackSummary = {
  id: 72, workflow: 'ask_mia', status: 'submitted', screenshot_attached: true,
  reporter: { id: 901, email: 'participant@pilot.test', full_name: 'Test Participant' },
  created_at: '2026-08-08T02:30:00Z', updated_at: '2026-08-08T02:30:00Z',
}

const pilotFeedbackDetail = {
  ...pilotFeedbackSummary,
  attempted: 'Upload a demo-safe budget spreadsheet in Ask Mia.',
  expected: 'Mia should summarize the spreadsheet and ask what to update.',
  actual: 'The upload stopped with a provider error.',
  screenshot: { filename: 'ask-mia-error.png', content_type: 'image/png', byte_size: 18_432 },
}

const emptyPlaidSummary = {
  all_count: 0, posted_outflow_count: 0, posted_outflow_cents: 0,
  pending_count: 0, pending_cents: 0, inflow_count: 0, inflow_cents: 0,
  needs_review_count: 0, needs_review_cents: 0, confirmed_count: 0,
  confirmed_actual_count: 0, confirmed_cents: 0, excluded_count: 0,
}

function chatMessages(count = 125) {
  return Array.from({ length: count }, (_, index) => ({
    id: index + 1,
    role: index % 2 === 0 ? 'user' : 'assistant',
    author: index % 2 === 0 ? 'You' : 'Mia',
    content: `Message ${index + 1}`,
    attachments: index === count - 1 ? [{
      document_import_id: 42, filename: 'receipt.png', content_type: 'image/png', document_kind: 'receipt', status: 'needs_review',
      source_available: true, preview_url: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    }] : [],
  }))
}

type MockContentItemVersion = {
  id: number
  item_id: number
  title: string
  kind: string
  content: string
  always_on: boolean
  version: number
  digest: string
  approved_at: string
}

type MockContentItem = {
  id: number
  title: string
  scope: string
  kind: string
  always_on: boolean
  draft_content: string | null
  draft_revision: number | null
  draft_digest: string | null
  archived: boolean
  editable: boolean
  current_approved_version: MockContentItemVersion | null
  versions: MockContentItemVersion[]
  has_unapproved_changes: boolean
  updated_at: string
}

type MockContentPackVersion = {
  id: number
  pack_id: number
  name: string
  description: string
  scope: string
  pack_kind: string
  version: number
  digest: string
  published_at: string
  items: MockContentItemVersion[]
}

type MockContentPack = {
  id: number
  name: string
  description: string
  scope: string
  pack_kind: string
  item_version_ids: number[]
  draft_revision: number | null
  draft_manifest_digest: string | null
  archived: boolean
  editable: boolean
  draft_items: MockContentItemVersion[]
  current_published_version: MockContentPackVersion | null
  versions: MockContentPackVersion[]
  has_unpublished_changes: boolean
  item_updates_available: boolean
  update_available: boolean
  updated_at: string
}

async function mockDemoApi(page: Page) {
  let pilotFeedbackStatus = 'submitted'
  let persona = personaDetailFixture()
  let personaAssignment: null | Record<string, unknown> = null
  let experienceDraft = { schema_version: 1 as const, optional_modules: { cfo_filter: true, optionality: true } }
  let experienceDraftRevision = 1
  let experiencePreview: null | { digest: string; draft_revision: number; generated_at: string } = null
  let experiencePublishedVersion: null | Record<string, unknown> = null
  let experienceVersions: Array<Record<string, unknown>> = []
  let memoryPaused = false
  let nextMemoryId = 2
  let memories = [{
    id: 1, category: 'coaching_style', status: 'user_confirmed', sensitivity: 'ordinary', visibility: 'private',
    display_value: 'Give me one clear next step.', structured_value: {}, owned_by_current_user: true, owner_name: 'You',
    source_kind: 'manual_profile', confirmation_fingerprint: null, confirmed_at: '2026-10-01T00:00:00Z', expires_at: null,
    created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z',
  }]
  let contentItems: MockContentItem[] = []
  let contentPacks: MockContentPack[] = []
  const memoryPayload = () => ({
    memories,
    personalization: { paused: memoryPaused, paused_at: memoryPaused ? '2026-10-01T01:00:00Z' : null },
    policy: {
      source: 'Only memories you explicitly saved appear here. Each household participant has a private memory list.',
      financial_truth: 'Mia uses approved household records for financial facts.',
      coach_visibility: false,
    },
  })
  const assignableCohort = () => ({
    id: 41,
    name: 'Household CFO pilot',
    status: 'active',
    assignable: true,
    blocked_reason: null,
    persona_assignment: personaAssignment,
  })
  const experienceConfiguration = () => ({
    cohort: { id: 41, name: 'Household CFO pilot', status: 'active', participant_count: 1 },
    draft: experienceDraft,
    draft_revision: experienceDraftRevision,
    preview_required: experiencePreview === null,
    preview: experiencePreview,
    published_version: experiencePublishedVersion,
    versions: experienceVersions,
    permissions: { edit: true, publish: true, rollback: true },
  })
  const responses: Record<string, unknown> = {
    '/api/demo/profile': profile,
    '/api/demo/dashboard': dashboard,
    '/api/demo/budget': budget,
    '/api/demo/wealth': wealth,
    '/api/demo/optionality': optionality,
    '/api/demo/cfo-filter': cfoFilter,
    '/api/demo/mia/messages': { messages: chatMessages(), oldest_message_id: 1, older_message_count: 0, has_older_messages: false, quick_prompts: ['Can I buy the purse?', 'Why is my readiness Red?', 'Emergency fund or debt first?', 'Can I leave my job?'], disclaimer: 'Education only.' },
    '/api/v1/workspace': realWorkspaceData(false),
    '/api/v1/spending_report': {
      spending_report: {
        period_label: `${currentMonth} ${currentYear}`,
        start_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-01`,
        end_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-28`,
        totals: { planned: 0, actual: 0, pending: 0, remaining: 0 },
        categories: [],
        transactions: [],
        pending_drafts: [],
      },
    },
    '/api/v1/document_imports': { document_imports: [] },
    '/api/v1/household_memories': memoryPayload(),
    '/api/v1/admin/cohorts': { cohorts: [pilotCohort] },
    '/api/v1/admin/users': { users: [pilotAdminUser] },
  }

  await page.route('http://api.test/**', async (route) => {
    const url = new URL(route.request().url())
    const path = url.pathname
    if (path === '/api/v1/household_memories' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: memoryPayload() })
    }
    if (path === '/api/v1/household_memories' && route.request().method() === 'POST') {
      const input = route.request().postDataJSON().memory
      const memory = {
        id: nextMemoryId++, category: input.category, status: input.sensitivity === 'sensitive' ? 'pending_confirmation' : 'user_confirmed',
        sensitivity: input.sensitivity, visibility: 'private', display_value: input.display_value, structured_value: {},
        owned_by_current_user: true, owner_name: 'You', source_kind: 'manual_profile',
        confirmation_fingerprint: input.sensitivity === 'sensitive' ? `memory-fingerprint-${nextMemoryId - 1}` : null,
        confirmed_at: input.sensitivity === 'sensitive' ? null : '2026-10-01T01:00:00Z', expires_at: null,
        created_at: '2026-10-01T01:00:00Z', updated_at: '2026-10-01T01:00:00Z',
      }
      memories = [memory, ...memories]
      return route.fulfill({ status: 201, json: { memory, personalization: memoryPayload().personalization } })
    }
    if (path === '/api/v1/mia_memory_settings' && route.request().method() === 'PATCH') {
      memoryPaused = Boolean(route.request().postDataJSON().personalization.paused)
      return route.fulfill({ status: 200, json: { personalization: memoryPayload().personalization } })
    }
    const memoryMatch = path.match(/^\/api\/v1\/household_memories\/(\d+)(?:\/(confirm|reject))?$/)
    if (memoryMatch) {
      const id = Number(memoryMatch[1])
      const action = memoryMatch[2]
      if (route.request().method() === 'DELETE') {
        memories = memories.filter((memory) => memory.id !== id)
        return route.fulfill({ status: 204, body: '' })
      }
      const index = memories.findIndex((memory) => memory.id === id)
      if (index < 0) return route.fulfill({ status: 404, json: { error: 'Not found' } })
      if (action === 'confirm') memories[index] = { ...memories[index], status: 'user_confirmed', confirmation_fingerprint: null, confirmed_at: '2026-10-01T01:00:00Z' }
      if (action === 'reject') memories[index] = { ...memories[index], status: 'rejected', confirmed_at: null }
      if (!action && route.request().method() === 'PATCH') memories[index] = { ...memories[index], ...route.request().postDataJSON().memory }
      return route.fulfill({ status: 200, json: { memory: memories[index], personalization: memoryPayload().personalization } })
    }
    if (path === '/api/v1/admin/personas' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: { personas: [persona] } })
    }
    if (path === '/api/v1/admin/cohorts/41/experience_configuration' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: { experience_configuration: experienceConfiguration() } })
    }
    if (path === '/api/v1/admin/cohorts/41/experience_configuration' && route.request().method() === 'PATCH') {
      experienceDraft = route.request().postDataJSON().experience_configuration.draft_config
      experienceDraftRevision += 1
      experiencePreview = null
      return route.fulfill({ status: 200, json: { experience_configuration: experienceConfiguration() } })
    }
    if (path === '/api/v1/admin/cohorts/41/experience_configuration/preview' && route.request().method() === 'POST') {
      experiencePreview = { digest: `experience-preview-${experienceDraftRevision}`, draft_revision: experienceDraftRevision, generated_at: '2026-10-01T02:00:00Z' }
      return route.fulfill({
        status: 200,
        json: {
          preview: { ...experiencePreview, modules: experienceCapabilities(experienceDraft.optional_modules).modules },
          experience_configuration: experienceConfiguration(),
        },
      })
    }
    if (path === '/api/v1/admin/cohorts/41/experience_configuration/publish' && route.request().method() === 'POST') {
      const number = experienceVersions.length + 1
      const version = {
        id: 300 + number, number, digest: `experience-version-${number}`, published_at: '2026-10-01T02:05:00Z',
        published_by: { id: 901, full_name: 'Pilot Admin' }, config: experienceDraft,
      }
      experiencePublishedVersion = version
      experienceVersions = [version, ...experienceVersions]
      return route.fulfill({ status: 200, json: { experience_configuration: experienceConfiguration(), published_version: version } })
    }
    const experienceRollback = path.match(/^\/api\/v1\/admin\/cohorts\/41\/experience_configuration\/versions\/(\d+)\/rollback$/)
    if (experienceRollback && route.request().method() === 'POST') {
      const target = experienceVersions.find((version) => version.id === Number(experienceRollback[1]))!
      const number = experienceVersions.length + 1
      const version = { ...target, id: 300 + number, number, digest: `experience-version-${number}`, restored_from_version: { id: target.id, number: target.number } }
      experienceDraft = target.config as typeof experienceDraft
      experiencePublishedVersion = version
      experienceVersions = [version, ...experienceVersions]
      experiencePreview = null
      return route.fulfill({ status: 200, json: { experience_configuration: experienceConfiguration(), published_version: version } })
    }
    if (path === '/api/v1/admin/content_items' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: { items: contentItems } })
    }
    if (path === '/api/v1/admin/content_sources' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: { sources: [] } })
    }
    if (path === '/api/v1/admin/content_items' && route.request().method() === 'POST') {
      const input = route.request().postDataJSON().item as Pick<MockContentItem, 'title' | 'scope' | 'kind' | 'draft_content' | 'always_on'>
      const item: MockContentItem = {
        id: 901, ...input, title: input.title.trim().replace(/\s+/g, ' '), draft_revision: 1, draft_digest: 'item-draft-1', archived: false, editable: true,
        current_approved_version: null, versions: [], has_unapproved_changes: true,
        updated_at: '2026-10-01T01:00:00Z',
      }
      contentItems = [item]
      return route.fulfill({ status: 201, json: { item } })
    }
    const contentItemMatch = path.match(/^\/api\/v1\/admin\/content_items\/(\d+)(?:\/(approve))?$/)
    if (contentItemMatch) {
      const item = contentItems.find((candidate) => candidate.id === Number(contentItemMatch[1]))!
      if (contentItemMatch[2] === 'approve') {
        const version = { id: 911, item_id: item.id, title: item.title, kind: item.kind, content: item.draft_content ?? '', always_on: item.always_on, version: 1, digest: 'item-digest', approved_at: '2026-10-01T01:02:00Z' }
        Object.assign(item, { current_approved_version: version, versions: [version], has_unapproved_changes: false })
        return route.fulfill({ status: 200, json: { item, approved_version: version } })
      }
      if (route.request().method() === 'PATCH') {
        const input = route.request().postDataJSON().item
        const nextRevision = (item.draft_revision ?? 0) + 1
        Object.assign(item, input, { title: input.title.trim().replace(/\s+/g, ' '), draft_revision: nextRevision, draft_digest: `item-draft-${nextRevision}`, has_unapproved_changes: true })
        return route.fulfill({ status: 200, json: { item } })
      }
    }
    if (path === '/api/v1/admin/content_packs' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: { packs: contentPacks } })
    }
    if (path === '/api/v1/admin/content_packs' && route.request().method() === 'POST') {
      const input = route.request().postDataJSON().pack as Pick<MockContentPack, 'name' | 'description' | 'scope' | 'pack_kind' | 'item_version_ids'>
      const selectedItems = contentItems.flatMap((item) => item.versions).filter((version) => input.item_version_ids.includes(version.id))
      const pack: MockContentPack = {
        id: 921, ...input, name: input.name.trim().replace(/\s+/g, ' '), draft_revision: 2, draft_manifest_digest: 'pack-draft-2', archived: false, editable: true, draft_items: selectedItems,
        current_published_version: null, versions: [], has_unpublished_changes: true, item_updates_available: false, update_available: true, updated_at: '2026-10-01T01:03:00Z',
      }
      contentPacks = [pack]
      return route.fulfill({ status: 201, json: { pack } })
    }
    const contentPackMatch = path.match(/^\/api\/v1\/admin\/content_packs\/(\d+)(?:\/(publish))?$/)
    if (contentPackMatch) {
      const pack = contentPacks.find((candidate) => candidate.id === Number(contentPackMatch[1]))!
      if (contentPackMatch[2] === 'publish') {
        const version = { id: 931, pack_id: pack.id, name: pack.name, description: pack.description, scope: pack.scope, pack_kind: pack.pack_kind, version: 1, digest: 'pack-digest', published_at: '2026-10-01T01:04:00Z', items: pack.draft_items }
        Object.assign(pack, { current_published_version: version, versions: [version], has_unpublished_changes: false, item_updates_available: false, update_available: false })
        return route.fulfill({ status: 200, json: { pack, published_version: version } })
      }
      if (route.request().method() === 'PATCH') {
        const input = route.request().postDataJSON().pack as Pick<MockContentPack, 'name' | 'description' | 'pack_kind' | 'item_version_ids'>
        const selectedItems = contentItems.flatMap((item) => item.versions).filter((version) => input.item_version_ids.includes(version.id))
        const nextRevision = (pack.draft_revision ?? 0) + 1
        Object.assign(pack, input, {
          name: input.name.trim().replace(/\s+/g, ' '),
          draft_items: selectedItems,
          draft_revision: nextRevision,
          draft_manifest_digest: `pack-draft-${nextRevision}`,
          has_unpublished_changes: true,
          update_available: true,
        })
        return route.fulfill({ status: 200, json: { pack } })
      }
    }
    if (path === '/api/v1/admin/personas/81/content_packs' && route.request().method() === 'PATCH') {
      const ids = route.request().postDataJSON().content_packs.pack_version_ids
      persona = {
        ...persona,
        content_packs: contentPacks.map((pack) => pack.current_published_version).filter((version) => version && ids.includes(version.id)),
        draft_revision: persona.draft_revision + 1,
        preview: null,
        preview_required: true,
        has_unpublished_changes: true,
      }
      return route.fulfill({ status: 200, json: { persona } })
    }
    if (path === '/api/v1/admin/personas' && route.request().method() === 'POST') {
      const body = route.request().postDataJSON().persona
      persona = { ...personaDetailFixture(), name: body.name, description: body.description ?? '', draft: { ...structuredClone(personaConfiguration), identity: { ...personaConfiguration.identity, assistant_name: body.name } } }
      return route.fulfill({ status: 201, json: { persona } })
    }
    if (path === '/api/v1/admin/personas/assignable_cohorts') {
      return route.fulfill({ status: 200, json: { cohorts: [assignableCohort(), { id: 42, name: 'Completed cohort', status: 'completed', assignable: false, blocked_reason: 'Completed and archived cohorts are read-only.', persona_assignment: null }] } })
    }
    if (path === '/api/v1/admin/personas/81' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: { persona } })
    }
    if (path === '/api/v1/admin/personas/81' && route.request().method() === 'PATCH') {
      const body = route.request().postDataJSON().persona
      persona = {
        ...persona,
        name: body.draft_config.identity.assistant_name,
        description: body.description,
        draft_revision: persona.draft_revision + 1,
        draft: body.draft_config,
        preview: null,
        preview_required: true,
        has_unpublished_changes: true,
      }
      return route.fulfill({ status: 200, json: { persona } })
    }
    if (path === '/api/v1/admin/personas/81' && route.request().method() === 'DELETE') {
      persona = { ...persona, status: 'archived', permissions: { ...persona.permissions, edit: false, publish: false, assign: false, archive: false, restore: true } }
      return route.fulfill({ status: 200, json: { persona } })
    }
    if (path === '/api/v1/admin/personas/81/preview' && route.request().method() === 'POST') {
      const body = route.request().postDataJSON().preview
      const digest = `preview-${persona.draft_revision}`
      persona = { ...persona, preview: { digest, draft_revision: persona.draft_revision, generated_at: '2026-10-01T01:00:00Z' }, preview_required: false }
      return route.fulfill({ status: 200, json: { persona, preview: { persona_id: 81, draft_revision: persona.draft_revision, digest, rendered_instructions: 'Identity: The assistant is Coach Lani. Always disclose that this is a digital assistant.', status: 'ready', source: 'live_model', sample_prompt: body.sample_prompt ?? null, sample_reply: 'Start by deciding whether this is a need or a want, then name the budget category that would cover it.', notice: 'Generated from this exact fictional draft with no participant financial data.', warnings: [], guardrails_applied: true, generated_at: '2026-10-01T01:00:00Z' } } })
    }
    if (path === '/api/v1/admin/personas/81/publish' && route.request().method() === 'POST') {
      const number = (persona.published_version?.number ?? 0) + 1
      const version = { id: 100 + number, number, digest: `version-${number}`, published_at: '2026-10-01T01:05:00Z', published_by: persona.owner, config: persona.draft }
      persona = { ...persona, status: 'published', published_version: version, versions: [version, ...persona.versions], has_unpublished_changes: false, preview_required: false }
      return route.fulfill({ status: 200, json: { persona, published_version: version } })
    }
    if (path === '/api/v1/admin/personas/81/restore' && route.request().method() === 'POST') {
      persona = { ...persona, status: 'draft', permissions: { ...persona.permissions, edit: true, publish: true, assign: true, archive: true, restore: false }, has_unpublished_changes: true, preview_required: true }
      return route.fulfill({ status: 200, json: { persona } })
    }
    const rollbackMatch = path.match(/^\/api\/v1\/admin\/personas\/81\/versions\/(\d+)\/rollback$/)
    if (rollbackMatch && route.request().method() === 'POST') {
      const target = persona.versions.find((version: { id: number }) => version.id === Number(rollbackMatch[1]))
      const number = (persona.published_version?.number ?? 0) + 1
      const version = { ...target, id: 100 + number, number, digest: `version-${number}`, published_at: '2026-10-01T01:20:00Z', published_by: persona.owner, restored_from_version: { id: target.id, number: target.number } }
      persona = { ...persona, status: 'published', name: target.config.identity.assistant_name, draft: target.config, published_version: version, versions: [version, ...persona.versions], has_unpublished_changes: false, preview_required: true, preview: null }
      return route.fulfill({ status: 200, json: { persona, published_version: version } })
    }
    if (path === '/api/v1/admin/cohorts/41/persona_assignment' && route.request().method() === 'PATCH') {
      personaAssignment = { id: 501, cohort: { id: 41, name: 'Household CFO pilot', status: 'active' }, persona: { id: 81, name: persona.name }, published_version: persona.published_version, assigned_at: '2026-10-01T01:10:00Z', updated_at: '2026-10-01T01:10:00Z', assigned_by: persona.owner }
      persona = { ...persona, visible_assignment_count: 1, assignments: [personaAssignment], permissions: { ...persona.permissions, archive: false } }
      return route.fulfill({ status: 200, json: { persona_assignment: personaAssignment } })
    }
    if (path === '/api/v1/admin/cohorts/41/persona_assignment' && route.request().method() === 'DELETE') {
      personaAssignment = null
      persona = { ...persona, visible_assignment_count: 0, assignments: [], permissions: { ...persona.permissions, archive: true } }
      return route.fulfill({ status: 204, body: '' })
    }
    if (path === '/api/v1/workspace/setup' && route.request().method() === 'PATCH') return route.fulfill({ status: 200, json: realWorkspaceData(true) })
    if (path === '/api/v1/pilot_feedback_reports' && route.request().method() === 'POST') {
      return route.fulfill({ status: 201, json: { feedback_report: { id: 55, workflow: 'setup', screenshot_attached: false, status: 'submitted', created_at: '2026-07-17T00:00:00Z' } } })
    }
    if (path === '/api/v1/admin/pilot_feedback_reports' && route.request().method() === 'GET') {
      const filter = url.searchParams.get('status') ?? 'submitted'
      const visible = filter === 'all' || filter === pilotFeedbackStatus
      return route.fulfill({
        status: 200,
        json: {
          feedback_reports: visible ? [{ ...pilotFeedbackSummary, status: pilotFeedbackStatus }] : [],
          counts: { submitted: pilotFeedbackStatus === 'submitted' ? 1 : 0, reviewed: pilotFeedbackStatus === 'reviewed' ? 1 : 0, resolved: pilotFeedbackStatus === 'resolved' ? 1 : 0 },
        },
      })
    }
    if (path === '/api/v1/admin/pilot_feedback_reports/72' && route.request().method() === 'GET') {
      return route.fulfill({ status: 200, json: { feedback_report: { ...pilotFeedbackDetail, status: pilotFeedbackStatus } } })
    }
    if (path === '/api/v1/admin/pilot_feedback_reports/72' && route.request().method() === 'PATCH') {
      pilotFeedbackStatus = route.request().postDataJSON().feedback_report.status
      return route.fulfill({ status: 200, json: { feedback_report: { ...pilotFeedbackDetail, status: pilotFeedbackStatus } } })
    }
    if (path === '/api/v1/admin/pilot_feedback_reports/72/screenshot_url') {
      return route.fulfill({ status: 200, json: { url: 'https://signed.example/inline', download_url: 'https://signed.example/download', expires_in: 300, filename: 'ask-mia-error.png', content_type: 'image/png' } })
    }
    if (/^\/api\/v1\/transaction_drafts\/\d+\/(confirm|ignore|match|reopen)$/.test(path)) {
      return route.fulfill({ status: 200, json: { workspace: realWorkspaceData(true) } })
    }
    if (/^\/api\/v1\/mia_action_drafts\/\d+\/(apply|cancel)$/.test(path)) {
      return route.fulfill({ status: 200, json: { workspace: realWorkspaceData(true) } })
    }
    const body = responses[path]
    if (!body) return route.fulfill({ status: 404, json: { error: `No fixture for ${path}` } })
    return route.fulfill({ status: 200, json: body })
  })
}

async function mockEmptyPlaidState(page: Page, configured: boolean) {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/plaid/items', (route) => route.fulfill({
    status: 200,
    json: { configured, environment: configured ? 'sandbox' : null, consent_policy_version: '2026-08-17', items: [] },
  }))
  await page.route('http://api.test/api/v1/plaid/transactions**', (route) => route.fulfill({
    status: 200,
    json: { transactions: [], pagination: { page: 1, per_page: 100, total: 0, has_more: false }, summary: emptyPlaidSummary },
  }))
}

test.beforeEach(async ({ page }) => {
  await mockDemoApi(page)
  await page.addInitScript((messages) => {
    window.localStorage.setItem('household-cfo:mia-chat:v1:preview', JSON.stringify(messages))
  }, chatMessages(100))
})

test('Mia memory stays explicit, reversible, and usable on mobile and desktop', async ({ page }) => {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'Ask Mia')
  await page.getByRole('button', { name: 'Memory', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'What Mia remembers' })).toBeVisible()
  await expect(page.getByText('Give me one clear next step.')).toBeVisible()

  const input = page.getByRole('textbox', { name: 'Memory for Mia' })
  await input.fill('Check in on our emergency fund goal each month.')
  await page.getByRole('combobox', { name: 'Memory type' }).selectOption('follow_up')
  await expect(page.getByText('Other household participants and coaches cannot see or use these memories.')).toBeVisible()
  await page.getByRole('button', { name: 'Remember this' }).click()
  await expect(page.getByText('Check in on our emergency fund goal each month.')).toBeVisible()
  await expect(page.getByText('Saved. Mia can use this on your next message.')).toBeVisible()

  await input.fill('A sensitive coaching constraint.')
  await page.getByRole('checkbox', { name: /This feels sensitive/ }).check()
  await page.getByRole('button', { name: 'Remember this' }).click()
  const sensitiveMemory = page.locator('.mia-memory-item').filter({ hasText: 'A sensitive coaching constraint.' })
  await expect(sensitiveMemory.getByText('pending confirmation')).toBeVisible()
  await sensitiveMemory.getByRole('button', { name: 'Confirm' }).click()
  await expect(sensitiveMemory.getByText('Active')).toBeVisible()

  await input.fill('A second sensitive coaching constraint.')
  await page.getByRole('checkbox', { name: /This feels sensitive/ }).check()
  await page.getByRole('button', { name: 'Remember this' }).click()
  const pendingWhilePaused = page.locator('.mia-memory-item').filter({ hasText: 'A second sensitive coaching constraint.' })
  await expect(pendingWhilePaused.getByText('pending confirmation')).toBeVisible()

  await page.getByRole('button', { name: 'Pause personalization' }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Personalization is paused.' })).toBeVisible()
  await expect(input).toBeDisabled()
  await expect(pendingWhilePaused.getByRole('button', { name: 'Confirm' })).toBeDisabled()
  await expect(pendingWhilePaused.getByRole('button', { name: 'Reject' })).toBeEnabled()
  await expect(pendingWhilePaused.getByRole('button', { name: 'Forget' })).toBeEnabled()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})

test('Mia memory shows a real initial loading state and keeps controls disabled', async ({ page }) => {
  let releaseMemory: (() => void) | undefined
  const memoryGate = new Promise<void>((resolve) => { releaseMemory = resolve })
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/household_memories', async (route) => {
    await memoryGate
    return route.fulfill({
      status: 200,
      json: {
        memories: [],
        personalization: { paused: false, paused_at: null },
        policy: {
          source: 'Only memories you explicitly saved appear here.',
          financial_truth: 'Mia uses approved household records for financial facts.',
          coach_visibility: false,
        },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'Ask Mia')
  await page.getByRole('button', { name: 'Memory', exact: true }).click()
  await expect(page.getByRole('status').filter({ hasText: 'Loading Mia’s memories…' })).toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Memory for Mia' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Pause personalization' })).toBeDisabled()

  releaseMemory?.()
  await expect(page.getByText('Nothing saved yet.')).toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Memory for Mia' })).toBeEnabled()
})

test('an initial workspace loading failure offers a real retry and restores the participant app', async ({ page }) => {
  let attempts = 0
  let recoveryAllowed = false
  await page.route('http://api.test/api/v1/workspace', (route) => {
    attempts += 1
    return recoveryAllowed
      ? route.fulfill({ status: 200, json: realWorkspaceData(true) })
      : route.fulfill({ status: 503, json: { error: 'The household workspace is temporarily unavailable.' } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await expect(page.getByRole('alert')).toContainText('temporarily unavailable')
  recoveryAllowed = true
  await page.getByRole('button', { name: 'Try again' }).click()

  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
  expect(attempts).toBeGreaterThan(1)
})

test('participant workflow remains usable when Plaid is not configured', async ({ page }) => {
  await mockEmptyPlaidState(page, false)

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await expect(page.getByText('Bank connection is not part of this pilot yet.')).toBeVisible()
  await expect(page.getByText('Nothing is missing from your setup.', { exact: false })).toBeVisible()
  await expect(page.getByText('server-side Plaid credentials', { exact: false })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Connect a bank', exact: true })).toHaveCount(0)

  await openSection(page, 'Review')
  await expect(page.getByText('Manual activity is ready.')).toBeVisible()
  await expect(page.getByText('Connect an account from My Profile.', { exact: false })).toHaveCount(0)
  await expect(page.getByRole('link', { name: 'Budget', exact: true })).toBeVisible()
})

test('configured Plaid clearly supports a participant with no connections', async ({ page }) => {
  await mockEmptyPlaidState(page, true)

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await expect(page.getByText('No bank is connected yet.')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Connect a bank', exact: true })).toBeDisabled()
  await expect(page.getByRole('checkbox', { name: /I authorize Household CFO Method/ })).toBeVisible()

  await openSection(page, 'Review')
  await expect(page.getByText('No bank activity yet.')).toBeVisible()
})

test('account selection keeps activity cards and row totals in the same scope', async ({ page }) => {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/plaid/items', (route) => route.fulfill({
    status: 200,
    json: {
      configured: true,
      environment: 'sandbox',
      consent_policy_version: '2026-08-17',
      items: [{
        id: 7,
        institution_name: 'Sandbox Bank',
        status: 'active',
        environment: 'sandbox',
        consented_at: '2026-08-17T00:00:00Z',
        last_synced_at: '2026-08-17T01:00:00Z',
        health: { state: 'healthy', label: 'Healthy', message: 'Bank activity is current.', requires_attention: false, last_successful_update_at: '2026-08-17T01:00:00Z', stale_after: '2026-08-18T01:00:00Z' },
        error_message: null,
        disconnected_at: null,
        auto_confirm_trusted_merchants: false,
        accounts: [
          { id: 11, name: 'Checking', official_name: null, mask: '1234', type: 'depository', subtype: 'checking', current_balance_cents: 200_000, available_balance_cents: 190_000, currency: 'USD', active: true },
          { id: 12, name: 'Savings', official_name: null, mask: '4321', type: 'depository', subtype: 'savings', current_balance_cents: 500_000, available_balance_cents: 500_000, currency: 'USD', active: true },
        ],
      }],
    },
  }))
  await page.route('http://api.test/api/v1/plaid/transactions**', (route) => {
    const accountId = new URL(route.request().url()).searchParams.get('account_id')
    const checkingOnly = accountId === '11'
    return route.fulfill({
      status: 200,
      json: {
        transactions: [],
        pagination: { page: 1, per_page: 100, total: checkingOnly ? 1 : 2, has_more: false },
        summary: {
          ...emptyPlaidSummary,
          all_count: checkingOnly ? 1 : 2,
          posted_outflow_count: checkingOnly ? 1 : 2,
          posted_outflow_cents: checkingOnly ? 4_200 : 14_100,
          confirmed_count: checkingOnly ? 1 : 2,
          confirmed_actual_count: checkingOnly ? 1 : 2,
          confirmed_cents: checkingOnly ? 4_200 : 14_100,
        },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'Review')
  const summary = page.getByLabel('Bank activity summary')
  await expect(summary.getByText('$141.00')).toHaveCount(2)

  await page.getByLabel('Account').selectOption('11')
  await expect(summary.getByText('$42.00')).toHaveCount(2)
  await expect(page.getByRole('heading', { name: '1 transaction' })).toBeVisible()
})

test('Plaid Link loads once and opens once after explicit consent', async ({ page }) => {

  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/plaid/items', (route) => route.fulfill({
    status: 200,
    json: { configured: true, environment: 'sandbox', consent_policy_version: '2026-08-17', items: [] },
  }))
  await page.route('http://api.test/api/v1/plaid/transactions**', (route) => route.fulfill({
    status: 200,
    json: { transactions: [], pagination: { page: 1, per_page: 100, total: 0, has_more: false }, summary: emptyPlaidSummary },
  }))
  await page.route('http://api.test/api/v1/plaid/items/link_token', (route) => route.fulfill({
    status: 200,
    json: { link_token: 'link-sandbox-test', consent_policy_version: '2026-08-17' },
  }))
  await page.route('https://cdn.plaid.com/link/v2/stable/link-initialize.js', (route) => route.fulfill({
    status: 200,
    contentType: 'text/javascript',
    body: `
      window.__plaidScriptLoads = (window.__plaidScriptLoads || 0) + 1;
      window.Plaid = {
        create: function (config) {
          window.__plaidConfig = config;
          setTimeout(function () { if (config.onLoad) config.onLoad(); }, 0);
          return {
            open: function () { window.__plaidOpenCount = (window.__plaidOpenCount || 0) + 1; },
            submit: function () {},
            exit: function (_options, callback) { if (callback) callback(); },
            destroy: function () {}
          };
        }
      };
    `,
  }))

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await page.getByRole('checkbox', { name: /I authorize Household CFO Method/ }).check()
  await page.getByRole('button', { name: 'Connect a bank', exact: true }).click()

  await expect.poll(() => page.evaluate(() => (window as Window & { __plaidOpenCount?: number }).__plaidOpenCount ?? 0)).toBe(1)
  expect(await page.evaluate(() => document.querySelectorAll('script[src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"]').length)).toBe(1)
  expect(await page.evaluate(() => (window as Window & { __plaidScriptLoads?: number }).__plaidScriptLoads)).toBe(1)
})

test('initial Plaid sync refreshes the workspace when transaction history is ready', async ({ page }) => {
  let workspaceRequests = 0
  let connected = false
  let overviewRequestsAfterExchange = 0
  const initialItem = {
    id: 17,
    institution_name: 'Sandbox Bank',
    status: 'active',
    environment: 'sandbox',
    consented_at: '2026-08-22T00:00:00Z',
    last_synced_at: null,
    health: { state: 'initializing', label: 'Preparing history', message: 'The first transaction history sync is still being prepared.', requires_attention: false, last_successful_update_at: null, stale_after: '2026-08-23T00:00:00Z' },
    error_message: null,
    disconnected_at: null,
    auto_confirm_trusted_merchants: false,
    accounts: [],
  }
  const completedItem = {
    ...initialItem,
    last_synced_at: '2026-08-22T01:00:00Z',
    health: { ...initialItem.health, state: 'healthy', label: 'Feed current', message: 'Plaid has updated this connection within the expected window.', last_successful_update_at: '2026-08-22T01:00:00Z' },
  }

  await page.route('http://api.test/api/v1/workspace', (route) => {
    workspaceRequests += 1
    return route.fulfill({ status: 200, json: realWorkspaceData(true) })
  })
  await page.route('http://api.test/api/v1/plaid/items', (route) => {
    if (!connected) return route.fulfill({ status: 200, json: { configured: true, environment: 'sandbox', consent_policy_version: '2026-08-17', items: [] } })
    overviewRequestsAfterExchange += 1
    const synced = overviewRequestsAfterExchange >= 2
    return route.fulfill({ status: 200, json: { configured: true, environment: 'sandbox', consent_policy_version: '2026-08-17', items: [synced ? completedItem : initialItem] } })
  })
  await page.route('http://api.test/api/v1/plaid/transactions**', (route) => route.fulfill({
    status: 200,
    json: { transactions: [], pagination: { page: 1, per_page: 100, total: 0, has_more: false }, summary: emptyPlaidSummary },
  }))
  await page.route('http://api.test/api/v1/plaid/items/link_token', (route) => route.fulfill({
    status: 200,
    json: { link_token: 'link-sandbox-test', consent_policy_version: '2026-08-17' },
  }))
  await page.route('http://api.test/api/v1/plaid/items/exchange', (route) => {
    connected = true
    return route.fulfill({
      status: 201,
      json: { item: initialItem, plaid: { configured: true, environment: 'sandbox', consent_policy_version: '2026-08-17', items: [initialItem] } },
    })
  })
  await page.route('https://cdn.plaid.com/link/v2/stable/link-initialize.js', (route) => route.fulfill({
    status: 200,
    contentType: 'text/javascript',
    body: `
      window.Plaid = {
        create: function (config) {
          window.__plaidConfig = config;
          setTimeout(function () { if (config.onLoad) config.onLoad(); }, 0);
          return { open: function () {}, submit: function () {}, exit: function (_options, callback) { if (callback) callback(); }, destroy: function () {} };
        }
      };
    `,
  }))

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await page.getByRole('checkbox', { name: /I authorize Household CFO Method/ }).check()
  await page.getByRole('button', { name: 'Connect a bank', exact: true }).click()
  await expect.poll(() => page.evaluate(() => Boolean((window as Window & { __plaidConfig?: unknown }).__plaidConfig))).toBe(true)
  await page.evaluate(() => {
    const plaidConfig = (window as Window & { __plaidConfig?: { onSuccess: (token: string, metadata: { institution: { institution_id: string; name: string } }) => void } }).__plaidConfig
    plaidConfig?.onSuccess('public-sandbox-test', { institution: { institution_id: 'ins_17', name: 'Sandbox Bank' } })
  })

  await expect(page.getByText('Sync complete. Posted expenses are ready for household review, and Mia can read the updated bank activity now.')).toBeVisible()
  await expect(page.getByText(/Last synced/)).toBeVisible()
  await expect.poll(() => workspaceRequests).toBeGreaterThan(1)
})

test('Home centers review work and keeps Red guidance internally consistent', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
  await expect(page.getByText('What needs review?')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Review 2 transactions' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Review 1 Mia change' })).toBeVisible()
  await expect(page.getByText('Month-to-date inside the annual plan')).toBeVisible()
  const monthSummary = page.getByRole('region', { name: `${currentMonth} ${currentYear} plan position` })
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$3,475.00')
  await expect(monthSummary.getByText('Pending review', { exact: true }).locator('..')).toContainText('$115.00')
  await expect(monthSummary).toContainText('Pilot guardrail: 40% of positive baseline surplus in Yellow or Green—not ordinary budget remaining.')
  await expect(monthSummary).toContainText('$1,710.00 remains after pending review')
  const homeOutflowBreakdown = monthSummary.getByRole('group', { name: 'Monthly money out breakdown' })
  await expect(homeOutflowBreakdown).toContainText('Category plan')
  await expect(homeOutflowBreakdown).toContainText('$5,300.00')
  await expect(homeOutflowBreakdown).toContainText('Debt minimums')
  await expect(homeOutflowBreakdown).toContainText('$200.00')
  await expect(homeOutflowBreakdown).toContainText('Total money out')
  await expect(homeOutflowBreakdown).toContainText('$5,500.00')
  await expect(monthSummary.locator('.budget-progress-pending')).toBeVisible()
  await page.getByText('Explore the plan behind this snapshot').click()
  const pressureRows = await page.locator('.home-financial-visuals .category-pressure-row').allTextContents()
  expect(pressureRows[0]).toContain('Dining out')
  expect(pressureRows[0]).toContain('$100.00 over if approved')
  await expect(page.locator('.home-financial-visuals .cash-flow-month')).toHaveCount(12)
  const januaryChartButton = page.getByRole('button', { name: new RegExp(`Jan ${currentYear}:`) }).first()
  await januaryChartButton.focus()
  const chartDetail = page.locator('.home-financial-visuals .cash-flow-detail-panel')
  await expect(chartDetail).toContainText(`Jan ${currentYear}`)
  await expect(chartDetail).toContainText('$14,200.00')
  await expect(chartDetail).toContainText('$5,500.00')
  await expect(chartDetail).toContainText('$8,700.00 remains after planned outflow.')
  await expect(chartDetail).toContainText('No expected irregular categories are planned this month.')
  const decemberChartButton = page.getByRole('button', { name: new RegExp(`Dec ${currentYear}:`) }).first()
  await decemberChartButton.focus()
  await expect(chartDetail).toContainText(`Dec ${currentYear}`)
  await expect(chartDetail).toContainText('Expected irregular plan included in outflow')
  await expect(chartDetail).toContainText('Holiday travel')
  await expect(chartDetail).toContainText('$3,000.00')
  await expect(page.locator('.home-financial-visuals .cash-flow-month-summary')).toHaveCount(12)
  await expect(page.getByRole('heading', { name: 'Your path from Red to Yellow to Green' })).toBeVisible()
  await expect(page.getByText('$23,215.00')).toBeVisible()
  await expect(page.getByText('$51,430.00')).toBeVisible()
  await expect(page.locator('.status-ribbon strong')).toHaveText('Red — pause and stabilize basics')
  await expect(page.getByText('Safe to spend').locator('..').getByText('$0.00')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Protect the baseline and build runway.' })).toBeVisible()
  await expect(page.getByText('enough stability to move with intention')).toHaveCount(0)

  await page.getByRole('button', { name: 'Review 2 transactions' }).click()
  await expect(page).toHaveURL(/#Review$/)
  await expect(page.getByRole('link', { name: 'Review', exact: true })).toHaveAttribute('aria-current', 'page')
  await expect(page.getByRole('heading', { name: 'Review what changed before it becomes household truth.' })).toBeFocused()
})

test('penny-level plans never show a false over-budget warning', async ({ page }) => {
  const pennyRow = {
    ...budget.annual_plan.rows[0],
    name: 'Penny-perfect category',
    months: categoryMonths(1, 0.3, 0.1),
    planned_total: 3.6,
    actual_total: 0.1,
  }
  const pennyBudget = {
    ...budget,
    annual_plan: {
      ...budget.annual_plan,
      rows: [pennyRow],
      monthly_debt_minimums: 0,
      pending_transaction_drafts: [{
        ...budget.annual_plan.pending_transaction_drafts[0],
        amount: 0.2,
        amount_cents: 20,
        category_id: pennyRow.id,
        category_name: pennyRow.name,
      }],
      pending_mia_action_drafts: [],
    },
  }
  await page.route('http://api.test/api/demo/budget', (route) => route.fulfill({ status: 200, json: pennyBudget }))

  await page.goto('/')

  const monthSummary = page.getByRole('region', { name: `${currentMonth} ${currentYear} plan position` })
  await expect(monthSummary).toContainText('$0.00 remains after pending review')
  await expect(monthSummary).not.toContainText('over plan if all pending items are approved')
})

test('large financial values stay on one line and participant screens stay inside the viewport', async ({ page }) => {
  await page.goto('/')
  for (const section of ['Home', 'Review', 'Ask Mia', 'My Profile', 'Budget', 'Wealth', 'CFO Filter', 'Optionality']) {
    if (section !== 'Home') await openSection(page, section)

    const audit = await page.evaluate(() => {
      const selectors = '.metric-card strong, .stack-card strong, .decision-card > strong, .readiness-milestone-card > strong, .outlook-month span, .outlook-month b, .plan-value strong, .month-plan-income strong, .month-plan-decision-row strong, .cash-flow-detail-panel dd, .transaction-draft-impact-row dd, .transaction-draft-impact-title b'
      const values = Array.from(document.querySelectorAll<HTMLElement>(selectors)).filter((element) => element.offsetParent !== null)
      return {
        documentOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        overflowingElements: Array.from(document.querySelectorAll<HTMLElement>('main *')).filter((element) => element.offsetParent !== null).filter((element) => {
          const rect = element.getBoundingClientRect()
          return rect.right > document.documentElement.clientWidth + 1 || rect.left < -1
        }).slice(0, 12).map((element) => {
          const rect = element.getBoundingClientRect()
          return `${element.tagName.toLowerCase()}.${element.className}: left ${Math.round(rect.left)}, right ${Math.round(rect.right)}, width ${Math.round(rect.width)}`
        }),
        cockpitWidths: ['.budget-screen', '.annual-budget-panel', '.annual-outlook', '.annual-cash-flow-visual', '.annual-cash-flow-scroll'].map((selector) => {
          const element = document.querySelector<HTMLElement>(selector)
          if (!element || element.offsetParent === null) return `${selector}: hidden`
          const rect = element.getBoundingClientRect()
          return `${selector}: left ${Math.round(rect.left)}, right ${Math.round(rect.right)}, width ${Math.round(rect.width)}, client ${element.clientWidth}, scroll ${element.scrollWidth}`
        }),
        clippedBoxes: Array.from(document.querySelectorAll<HTMLElement>('.shell-header, .screen-heading, .screen-grid > article, .screen-grid > section, .status-ribbon, .metric-card, .insight-card, .stack-card, .decision-card, .choice-card')).filter((element) => element.offsetParent !== null).filter((element) => {
          const rect = element.getBoundingClientRect()
          return rect.left < -1 || rect.right > document.documentElement.clientWidth + 1
        }).map((element) => `${element.className}: ${element.textContent?.trim().replace(/\s+/g, ' ').slice(0, 60)}`),
        splitValues: values.filter((element) => {
          const style = getComputedStyle(element)
          const lineHeight = Number.parseFloat(style.lineHeight)
          return style.whiteSpace !== 'nowrap' || element.scrollWidth > element.clientWidth + 1 || (Number.isFinite(lineHeight) && element.clientHeight > lineHeight * 1.45)
        }).map((element) => element.textContent?.trim()),
      }
    })

    expect(audit.documentOverflow, `${section} should not overflow horizontally. Offenders: ${audit.overflowingElements.join(' | ')}. Cockpit: ${audit.cockpitWidths.join(' | ')}`).toBeLessThanOrEqual(1)
    expect(audit.clippedBoxes, `${section} cards should not be hidden outside the viewport`).toEqual([])
    expect(audit.splitValues, `${section} should not split or clip financial values`).toEqual([])
  }
})

test('Ask Mia renders bounded history and lazy attachment previews', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  const suggestedQuestion = page.getByRole('button', { name: 'Why is my readiness Red?' })
  if ((page.viewportSize()?.width ?? 0) <= 620) {
    await expect(suggestedQuestion).toBeHidden()
    await page.getByRole('button', { name: 'Prompts', exact: true }).click()
  }
  await expect(suggestedQuestion).toBeVisible()
  if ((page.viewportSize()?.width ?? 0) <= 620) {
    await page.getByRole('button', { name: 'Prompts', exact: true }).click()
  }
  const promptCue = page.getByText('More prompts →')
  if ((page.viewportSize()?.width ?? 0) <= 720) {
    await expect(promptCue).toBeHidden()
  } else {
    await expect(promptCue).toBeVisible()
  }
  await expect(page.locator('.message-row')).toHaveCount(60)
  await expect(page.getByRole('button', { name: 'Load earlier messages (40 remaining)' })).toBeVisible()
  await expect(page.locator('.message-attachment-card img')).toHaveAttribute('loading', 'lazy')
  await expect(page.getByRole('button', { name: 'Review draft' })).toBeVisible()

  const attachmentPreview = page.getByRole('button', { name: 'Preview Receipt screenshot' })
  await attachmentPreview.focus()
  await attachmentPreview.press('Enter')
  const previewDialog = page.getByRole('dialog', { name: 'Receipt screenshot' })
  await expect(previewDialog).toBeVisible()
  await expect(previewDialog.getByRole('button', { name: 'Close', exact: true })).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(previewDialog.getByRole('button', { name: 'Close', exact: true })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(previewDialog).toBeHidden()
  await expect(attachmentPreview).toBeFocused()

  await page.getByRole('button', { name: 'Review draft' }).click()
  await expect(page.getByText('Profile completeness', { exact: true })).toBeVisible()
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()

  await page.getByRole('button', { name: 'Load earlier messages (40 remaining)' }).click()
  await expect(page.locator('.message-row')).toHaveCount(100)
  await expect(page.locator('.chat-history-load')).toHaveCount(0)
})

test('Mia preserves accessible financial lists and emphasis instead of flattening the answer', async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.setItem('household-cfo:mia-chat:v1:preview', JSON.stringify([{
      id: 9901,
      role: 'assistant',
      author: 'Mia',
      content: '**Approved household plan**\n\nOnly approved numbers are included.\n- Groceries: **$300.25** planned\n- Dining Out: **$80.50** confirmed',
      attachments: [],
    }]))
  })

  await page.goto('/#Ask%20Mia')

  const answer = page.locator('.message.assistant')
  await expect(answer.getByRole('list')).toBeVisible()
  await expect(answer.getByRole('listitem')).toHaveCount(2)
  await expect(answer.locator('p')).toHaveCount(2)
  await expect(answer.locator('p strong')).toHaveText('Approved household plan')
  await expect(answer.locator('li strong')).toHaveText(['$300.25', '$80.50'])
})

test('mobile Ask Mia renders ordered read-only answers and isolates scenario values', async ({ page }) => {
  const lead = 'Protect the required minimums before directing extra money to debt.'
  await page.addInitScript(({ leadText }) => {
    window.localStorage.setItem('household-cfo:mia-chat:v1:preview', JSON.stringify([{
      id: 9902,
      role: 'assistant',
      author: 'Mia',
      content: 'RAW FALLBACK CONTENT SHOULD NOT BE DUPLICATED',
      attachments: [],
      presentation: {
        version: 1,
        kind: 'read_only_answer',
        basis: 'saved_household_plus_scenario',
        lead: leadText,
        sections: [
          { id: 'avalanche', title: 'Avalanche', body: 'Card A comes first because its saved APR is highest.\n\nKeep minimums current while directing the extra payment there.' },
          { id: 'snowball', title: 'Snowball', body: '<script>window.miaMarkupExecuted = true</script> remains text in this answer.\n\n- Compare total interest\n- Check the monthly margin' },
          { id: 'next-move', title: 'Next move', body: 'Keep runway protected, then choose one fixed extra payment.' },
        ],
        scenario: {
          values: [
            { label: '<img src=x onerror=alert(1)> personal loan balance', display_value: '$8,000' },
            { label: 'Personal loan APR', display_value: '11.5%' },
            { label: 'Temporary income drop', display_value: '$900 for 3 months' },
          ],
        },
      },
    }]))
  }, { leadText: lead })

  await page.goto('/#Ask%20Mia')

  const answer = page.locator('.message.assistant')
  const structured = answer.getByRole('group', { name: 'Mia read-only answer' })
  await expect(structured).toBeVisible()
  await expect(structured.getByText('Answer basis')).toBeVisible()
  await expect(structured.getByText('Saved household records + your scenario')).toBeVisible()
  await expect(structured.getByText(lead, { exact: true })).toHaveCount(1)

  const sections = structured.getByRole('list', { name: 'Mia answer sections' })
  const sectionItems = sections.locator(':scope > li')
  await expect(sectionItems).toHaveCount(3)
  await expect(sections.getByRole('heading', { level: 4 })).toHaveText(['Avalanche', 'Snowball', 'Next move'])
  const avalancheSection = sectionItems.nth(0)
  await expect(avalancheSection.locator('p')).toHaveText([
    'Card A comes first because its saved APR is highest.',
    'Keep minimums current while directing the extra payment there.',
  ])
  const snowballSection = sectionItems.nth(1)
  await expect(snowballSection.locator('p')).toHaveText(['<script>window.miaMarkupExecuted = true</script> remains text in this answer.'])
  await expect(snowballSection.getByRole('listitem')).toHaveText(['Compare total interest', 'Check the monthly margin'])

  const scenario = structured.getByRole('note', { name: 'Scenario only · not saved' })
  await expect(scenario).toContainText('Mia used these values for this answer. Your saved household records did not change.')
  await expect(scenario).toContainText('<img src=x onerror=alert(1)> personal loan balance')
  await expect(scenario).toContainText('$8,000')
  await expect(scenario).toContainText('11.5%')
  await expect(scenario).toContainText('$900 for 3 months')
  await expect(structured).toContainText('<script>window.miaMarkupExecuted = true</script> remains text in this answer.')
  await expect(structured.locator('script, img')).toHaveCount(0)
  expect(await page.evaluate(() => (window as Window & { miaMarkupExecuted?: boolean }).miaMarkupExecuted)).toBeUndefined()

  await expect(answer).not.toContainText('RAW FALLBACK CONTENT SHOULD NOT BE DUPLICATED')
  await expect(answer.getByRole('button')).toHaveCount(0)
  await expect(answer.getByText(lead, { exact: true })).toHaveCount(1)
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeVisible()

  const layout = await structured.evaluate((element) => {
    const scenarioRow = element.querySelector('.mia-answer-scenario dl > div')
    return {
      documentOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      answerOverflow: element.scrollWidth - element.clientWidth,
      scenarioColumns: scenarioRow ? getComputedStyle(scenarioRow).gridTemplateColumns.split(' ').length : 0,
      viewportWidth: document.documentElement.clientWidth,
    }
  })
  expect(layout.documentOverflow).toBeLessThanOrEqual(1)
  expect(layout.answerOverflow).toBeLessThanOrEqual(1)
  if (layout.viewportWidth <= 420) expect(layout.scenarioColumns).toBe(1)
})

test('Mia falls back to plain content when read-only presentation metadata is malformed', async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.setItem('household-cfo:mia-chat:v1:preview', JSON.stringify([{
      id: 9903,
      role: 'assistant',
      author: 'Mia',
      content: '**Approved answer preserved**\n- Keep minimums current\n- Protect runway',
      attachments: [],
      presentation: {
        version: 1,
        kind: 'read_only_answer',
        basis: 'saved_household_plus_scenario',
        lead: 'This incomplete presentation must not replace the answer.',
        sections: [{ id: 'next', title: 'Next move', body: 'Protect runway.' }],
      },
    }]))
  })

  await page.goto('/#Ask%20Mia')

  const answer = page.locator('.message.assistant')
  await expect(answer.getByRole('group', { name: 'Mia read-only answer' })).toHaveCount(0)
  await expect(answer.getByText('Approved answer preserved', { exact: true })).toBeVisible()
  await expect(answer.getByRole('listitem')).toHaveText(['Keep minimums current', 'Protect runway'])
})

test('chat-first Mia preserves legacy reviews without structured before and after fields', async ({ page }) => {
  const baseWorkspace = realWorkspaceData(true)
  const malformedIncomeDraft = {
    ...miaIncomeDraft,
    items: miaIncomeDraft.items.map((item) => ({ ...item, review_fields: [null, { unexpected: 'shape' }] })),
  }
  const workspace = {
    ...baseWorkspace,
    budget: {
      ...baseWorkspace.budget,
      annual_plan: {
        ...baseWorkspace.budget.annual_plan,
        pending_mia_action_drafts: [miaHouseholdDraft, malformedIncomeDraft, miaBudgetDraft],
      },
    },
  }
  await page.route('http://api.test/api/v1/workspace', async (route) => route.fulfill({ status: 200, json: workspace }))

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  await expect(page.getByRole('heading', { name: 'Tell Mia what changed.' })).toBeVisible()

  if ((page.viewportSize()?.width ?? 0) <= 620) {
    await page.getByRole('button', { name: 'Prompts', exact: true }).click()
  }
  await expect(page.getByText('Nothing changes until you tap Apply.')).toBeVisible()
  const example = page.getByRole('button', { name: 'My take-home pay is now $6,200 a month.' })
  await example.click()
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(composer).toHaveValue('My take-home pay is now $6,200 a month.')
  await expect(composer).toBeFocused()

  const householdCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Update an approved household number' })
  const incomeCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Schedule an income change' })
  const budgetCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Move more into the unexpected sinking fund' })
  await expect(page.getByRole('heading', { name: 'This screen hit an unexpected problem.' })).toHaveCount(0)
  await expect(householdCard).toContainText('Household numbers')
  await expect(householdCard).toContainText('$5,000.00 → $8,500.00')
  await expect(incomeCard).toContainText('Income timeline')
  await expect(incomeCard).toContainText(`October ${currentYear}`)
  await expect(budgetCard).toContainText('Budget plan')
  await expect(budgetCard).toContainText('leave actual spending untouched')

  for (const card of [householdCard, incomeCard, budgetCard]) {
    await expect(card.locator('.mia-action-before-after')).toHaveCount(0)
    await expect(card.getByRole('button', { name: 'Apply reviewed change' })).toBeEnabled()
    await expect(card.getByRole('button', { name: 'Cancel draft' })).toBeEnabled()
    await expect(card.getByRole('button', { name: 'Open manual controls' })).toBeEnabled()
  }

  await householdCard.getByRole('button', { name: 'Open manual controls' }).click()
  await expect(page).toHaveURL(/#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()
})

test('applying an unrelated Mia draft preserves unsaved profile edits', async ({ page }) => {
  const workspace = realWorkspaceData(true)
  const appliedWorkspace = {
    ...workspace,
    budget: {
      ...workspace.budget,
      annual_plan: { ...workspace.budget.annual_plan, pending_mia_action_drafts: [] },
    },
  }
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: workspace }))
  await page.route('http://api.test/api/v1/mia_action_drafts/71/apply', (route) => route.fulfill({
    status: 200,
    json: { workspace: appliedWorkspace },
  }))

  await page.goto('/?pilot_e2e_role=participant#My%20Profile')
  await page.getByRole('button', { name: 'Edit profile' }).click()
  const householdName = page.getByLabel('Household name')
  await householdName.fill('Unsaved family name')

  await openSection(page, 'Ask Mia')
  const budgetCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Move more into the unexpected sinking fund' })
  await budgetCard.getByRole('button', { name: 'Apply reviewed change' }).click()
  await expect(budgetCard).toBeHidden()

  await openSection(page, 'My Profile')
  await expect(page.getByRole('heading', { name: 'Editing household numbers' })).toBeVisible()
  await expect(page.getByLabel('Household name')).toHaveValue('Unsaved family name')
})

test('profile summary edits focus the matching manual field', async ({ page }) => {
  const workspace = realWorkspaceData(true)
  workspace.profile.sections = [
    { label: 'Income', summary: 'Current recurring income.', items: [{ label: 'Primary income', amount: 5_000 }] },
    { label: 'Expenses', summary: 'Current recurring expenses.', items: [{ label: 'Fixed essentials', amount: 2_500 }] },
    { label: 'Savings & Debt', summary: 'Current balances.', items: [{ label: 'Emergency fund', amount: 8_000 }] },
  ]
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: workspace }))

  await page.goto('/?pilot_e2e_role=participant#My%20Profile')
  const incomeCard = page.locator('.profile-section').filter({ hasText: 'Income' })
  const expensesCard = page.locator('.profile-section').filter({ hasText: 'Expenses' })
  const savingsCard = page.locator('.profile-section').filter({ hasText: 'Savings & Debt' })
  await incomeCard.getByRole('button', { name: 'Edit', exact: true }).click()
  await expect(page.getByLabel('Primary monthly income')).toBeFocused()
  await expensesCard.getByRole('button', { name: 'Edit', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Editing household numbers' })).toBeVisible()
  await expect(page.getByLabel('Fixed essentials')).toBeFocused()
  await expect(page.getByLabel('Fixed essentials')).toBeEnabled()

  await savingsCard.getByRole('button', { name: 'Edit', exact: true }).click()
  await expect(page.getByLabel('Total credit card debt')).toBeFocused()
  await expect(page.locator('.setup-optional-fields')).toHaveAttribute('open', '')
})

test('first-session review states what it completes and what Mia still needs', async ({ page }) => {
  const partialSetupDraft = {
    ...miaHouseholdDraft,
    id: 74,
    title: 'Add monthly income to your starting picture',
    summary: 'Mia prepared one starting value for review.',
    setup_coverage_after_apply: {
      complete: false, completed_count: 1, required_count: 5,
      required_fields: [
        { key: 'household_name', label: 'Household name', confirmed: false },
        { key: 'primary_goal', label: 'Primary goal', confirmed: false },
        { key: 'primary_income', label: 'Primary monthly income', confirmed: true },
        { key: 'fixed_expenses', label: 'Fixed essentials', confirmed: false },
        { key: 'flexible_spend', label: 'Flexible spending', confirmed: false },
      ],
      confirmed_fields: ['primary_income'],
      missing_fields: [
        { key: 'household_name', label: 'Household name', confirmed: false },
        { key: 'primary_goal', label: 'Primary goal', confirmed: false },
        { key: 'fixed_expenses', label: 'Fixed essentials', confirmed: false },
        { key: 'flexible_spend', label: 'Flexible spending', confirmed: false },
      ],
    },
    items: [{
      ...miaHouseholdDraft.items[0],
      id: 741,
      label: 'Primary monthly income',
      payload: { key: 'primary_income', value: 6_200 },
    }],
  }
  const baseWorkspace = realWorkspaceData(false)
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({
    status: 200,
    json: {
      ...baseWorkspace,
      budget: {
        ...baseWorkspace.budget,
        annual_plan: { ...baseWorkspace.budget.annual_plan, pending_mia_action_drafts: [partialSetupDraft] },
      },
    },
  }))

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  const card = page.locator('.mia-action-draft-card').filter({ hasText: 'Add monthly income to your starting picture' })
  await expect(card).toContainText('1 of 5 essentials after approval')
  await expect(card).toContainText('Still needed: Household name, Primary goal, Fixed essentials, Flexible spending.')
  await expect(card.getByRole('button', { name: 'Apply these 1 value' })).toBeEnabled()
})

test('a confirmed zero remains available when the rest of setup is completed manually', async ({ page }) => {
  const setupStatus = {
    complete: false, completed_count: 1, required_count: 5,
    required_fields: [
      { key: 'household_name', label: 'Household name', confirmed: false },
      { key: 'primary_goal', label: 'Primary goal', confirmed: false },
      { key: 'primary_income', label: 'Primary monthly income', confirmed: false },
      { key: 'fixed_expenses', label: 'Fixed essentials', confirmed: false },
      { key: 'flexible_spend', label: 'Flexible spending', confirmed: true },
    ],
    confirmed_fields: ['flexible_spend'],
    missing_fields: [
      { key: 'household_name', label: 'Household name', confirmed: false },
      { key: 'primary_goal', label: 'Primary goal', confirmed: false },
      { key: 'primary_income', label: 'Primary monthly income', confirmed: false },
      { key: 'fixed_expenses', label: 'Fixed essentials', confirmed: false },
    ],
  }
  const zeroDraft = {
    ...miaHouseholdDraft,
    id: 75,
    title: 'Confirm zero flexible spending',
    summary: 'Mia prepared one starting value for review.',
    setup_coverage_after_apply: setupStatus,
    items: [{
      ...miaHouseholdDraft.items[0],
      id: 751,
      label: 'Flexible spending',
      description: 'Confirm $0.00 per month.',
      payload: { key: 'flexible_spend', value: 0 },
    }],
  }
  const initialWorkspace = realWorkspaceData(false)
  initialWorkspace.budget.annual_plan.pending_mia_action_drafts = [zeroDraft]
  const partialWorkspace = {
    ...initialWorkspace,
    workspace: {
      ...initialWorkspace.workspace,
      setup_status: setupStatus,
      setup_values: { ...initialWorkspace.workspace.setup_values, flexible_spend: 0 },
    },
    budget: {
      ...initialWorkspace.budget,
      annual_plan: { ...initialWorkspace.budget.annual_plan, pending_mia_action_drafts: [] },
    },
  }
  const processingImport = {
    id: 910,
    household_id: 77,
    document_kind: 'statement',
    status: 'processing',
    filename: 'background-statement.pdf',
    content_type: 'application/pdf',
    byte_size: 1_024,
    document_date: null,
    period_start_on: null,
    period_end_on: null,
    extracted_summary: null,
    extraction_error: null,
    processed_at: null,
    applied_at: null,
    source_deleted_at: null,
    updated_at: `${currentYear}-10-01T00:00:00Z`,
    source_available: true,
    details_included: false,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {},
    items: [],
    transaction_drafts: [],
    attempts: [],
  }
  const reviewedImport = {
    ...processingImport,
    status: 'needs_review',
    processed_at: `${currentYear}-10-01T00:00:05Z`,
    updated_at: `${currentYear}-10-01T00:00:05Z`,
    extracted_summary: 'One purchase is ready for review.',
    transaction_drafts: [{
      id: 911,
      occurred_on: `${currentYear}-10-01`,
      merchant: 'Background purchase',
      amount: 20,
      status: 'pending',
      category_id: null,
      category_name: null,
    }],
  }
  let documentImportRequestCount = 0
  let releaseImportRefresh: (() => void) | undefined
  const importRefreshGate = new Promise<void>((resolve) => {
    releaseImportRefresh = resolve
  })
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: initialWorkspace }))
  await page.route('http://api.test/api/v1/mia_action_drafts/75/apply', (route) => route.fulfill({
    status: 200,
    json: { workspace: partialWorkspace },
  }))
  await page.route('http://api.test/api/v1/document_imports', async (route) => {
    documentImportRequestCount += 1
    if (documentImportRequestCount === 1) {
      return route.fulfill({ status: 200, json: { document_imports: [processingImport] } })
    }

    await importRefreshGate
    return route.fulfill({ status: 200, json: { document_imports: [reviewedImport] } })
  })

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  const card = page.locator('.mia-action-draft-card').filter({ hasText: 'Confirm zero flexible spending' })
  const applyButton = card.getByRole('button', { name: 'Apply these 1 value' })
  await applyButton.focus()
  await applyButton.press('Enter')

  const progress = page.locator('.first-session-setup-progress')
  await expect(progress.getByRole('listitem').filter({ hasText: 'Flexible spending' }).locator('.sr-only')).toHaveText('— Confirmed')
  await expect(progress.getByRole('listitem').filter({ hasText: 'Primary monthly income' }).locator('.sr-only')).toHaveText('— Still needed')
  await progress.getByRole('button', { name: 'Enter manually' }).click()

  await expect(page.getByLabel('Flexible spending')).toHaveValue('0')
  await expect(page.getByLabel('Primary monthly income')).toHaveValue('')
  await expect(page.getByLabel('Fixed essentials')).toHaveValue('')
  await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))))
  await page.getByLabel('Household name').fill('Zero Spend Household')
  await expect(page.getByLabel('Household name')).toHaveValue('Zero Spend Household')
  await page.getByLabel('Primary goal').fill('Keep a calm plan.')
  await expect(page.getByLabel('Primary goal')).toHaveValue('Keep a calm plan.')
  await page.getByLabel('Primary monthly income').fill('6200')
  await expect(page.getByLabel('Primary monthly income')).toHaveValue('6200')
  await page.getByLabel('Fixed essentials').fill('2800')
  await expect(page.getByLabel('Fixed essentials')).toHaveValue('2800')
  await expect(page.getByLabel('Household name')).toHaveValue('Zero Spend Household')
  await expect(page.getByLabel('Primary goal')).toHaveValue('Keep a calm plan.')
  await expect(page.getByLabel('Primary monthly income')).toHaveValue('6200')
  await expect(page.getByLabel('Fixed essentials')).toHaveValue('2800')

  const backgroundWorkspaceRefresh = page.waitForResponse((response) => response.url() === 'http://api.test/api/v1/workspace' && response.request().method() === 'GET', { timeout: 10_000 })
  releaseImportRefresh?.()
  await backgroundWorkspaceRefresh
  await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))))
  await expect(page.getByLabel('Household name')).toHaveValue('Zero Spend Household')
  await expect(page.getByLabel('Primary goal')).toHaveValue('Keep a calm plan.')
  await expect(page.getByLabel('Primary monthly income')).toHaveValue('6200')
  await expect(page.getByLabel('Fixed essentials')).toHaveValue('2800')

  const setupRequestPromise = page.waitForRequest((request) => request.url().endsWith('/api/v1/workspace/setup') && request.method() === 'PATCH')
  await page.getByRole('button', { name: 'Save and talk to Mia' }).click()
  const setupRequest = await setupRequestPromise
  expect(setupRequest.postDataJSON().workspace).toMatchObject({
    household_name: 'Zero Spend Household',
    primary_goal: 'Keep a calm plan.',
    primary_income: 6200,
    fixed_expenses: 2800,
    flexible_spend: 0,
  })
})

test('Ask Mia composer grows, caps, scrolls, and shrinks without losing its controls', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')

  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  const sendButton = page.getByRole('button', { name: 'Send message to Mia' })
  const attachmentButton = page.getByRole('button', { name: 'Attach receipt, screenshot, statement, or budget file' })
  const voiceButton = page.getByRole('button', { name: 'Record voice note for Mia' })
  const initialHeight = await composer.evaluate((element) => element.getBoundingClientRect().height)

  await composer.fill('Change my budget,\nthen show me the effect.')
  const wrappedMetrics = await composer.evaluate((element) => {
    const styles = getComputedStyle(element)
    return {
      height: element.getBoundingClientRect().height,
      maxHeight: Number.parseFloat(styles.maxHeight),
      overflowY: styles.overflowY,
    }
  })
  expect(wrappedMetrics.height).toBeGreaterThan(initialHeight)
  expect(wrappedMetrics.height).toBeLessThanOrEqual(wrappedMetrics.maxHeight)
  expect(wrappedMetrics.overflowY).toBe('hidden')

  const composerLayout = await page.locator('.mia-chat-shell .ask-row').evaluate((row) => {
    const rectFor = (selector: string) => {
      const element = row.querySelector(selector)
      if (!(element instanceof HTMLElement)) throw new Error(`Missing composer element: ${selector}`)
      const rect = element.getBoundingClientRect()
      return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, width: rect.width }
    }
    return {
      viewportWidth: document.documentElement.clientWidth,
      attach: rectFor('.composer-attach'),
      voice: rectFor('.composer-voice'),
      textarea: rectFor('textarea'),
      send: rectFor('.send-button'),
    }
  })
  for (const element of [composerLayout.attach, composerLayout.voice, composerLayout.textarea, composerLayout.send]) {
    expect(element.left).toBeGreaterThanOrEqual(0)
    expect(element.right).toBeLessThanOrEqual(composerLayout.viewportWidth + 1)
  }
  expect(composerLayout.attach.right).toBeLessThanOrEqual(composerLayout.voice.left)
  expect(composerLayout.voice.right).toBeLessThanOrEqual(composerLayout.textarea.left)
  expect(composerLayout.textarea.right).toBeLessThanOrEqual(composerLayout.send.left)
  expect(Math.abs(composerLayout.attach.bottom - composerLayout.textarea.bottom)).toBeLessThanOrEqual(1)
  expect(Math.abs(composerLayout.voice.bottom - composerLayout.textarea.bottom)).toBeLessThanOrEqual(1)
  expect(Math.abs(composerLayout.send.bottom - composerLayout.textarea.bottom)).toBeLessThanOrEqual(1)

  await composer.fill(Array.from({ length: 30 }, (_, index) => `Line ${index + 1}: review this planned change before applying it.`).join('\n'))
  const cappedMetrics = await composer.evaluate((element) => {
    const styles = getComputedStyle(element)
    return {
      clientHeight: element.clientHeight,
      scrollHeight: element.scrollHeight,
      maxHeight: Number.parseFloat(styles.maxHeight),
      overflowY: styles.overflowY,
    }
  })
  expect(cappedMetrics.clientHeight).toBeLessThanOrEqual(cappedMetrics.maxHeight)
  expect(cappedMetrics.scrollHeight).toBeGreaterThan(cappedMetrics.clientHeight)
  expect(cappedMetrics.overflowY).toBe('auto')
  await expect(sendButton).toBeVisible()
  await expect(attachmentButton).toBeVisible()
  await expect(voiceButton).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)

  await composer.fill('x'.repeat(6_999))
  await expect(page.locator('#mia-composer-count')).toHaveCount(0)
  await composer.fill('x'.repeat(7_000))
  await expect(page.locator('#mia-composer-count')).toHaveText('1,000 characters remaining')
  const nearLimitLayout = await page.locator('.mia-chat-shell .ask-row').evaluate((row) => {
    const rowBounds = row.getBoundingClientRect()
    const rect = (selector: string) => {
      const element = row.querySelector(selector)
      if (!(element instanceof HTMLElement)) throw new Error(`Missing composer element: ${selector}`)
      const bounds = element.getBoundingClientRect()
      return { left: bounds.left, right: bounds.right, top: bounds.top, bottom: bounds.bottom }
    }
    return {
      viewportWidth: document.documentElement.clientWidth,
      row: { left: rowBounds.left, right: rowBounds.right, top: rowBounds.top, bottom: rowBounds.bottom },
      field: rect('.composer-message-field'),
      textarea: rect('textarea'),
      count: rect('#mia-composer-count'),
      voice: rect('.composer-voice'),
      send: rect('.send-button'),
    }
  })
  expect(nearLimitLayout.count.top).toBeGreaterThanOrEqual(nearLimitLayout.textarea.bottom - 1)
  expect(nearLimitLayout.field.left).toBeGreaterThanOrEqual(nearLimitLayout.voice.right)
  expect(nearLimitLayout.field.right).toBeLessThanOrEqual(nearLimitLayout.send.left)
  expect(nearLimitLayout.count.right).toBeLessThanOrEqual(nearLimitLayout.viewportWidth)
  expect(nearLimitLayout.row.bottom).toBeGreaterThanOrEqual(nearLimitLayout.count.bottom)
  await composer.fill('x'.repeat(7_999))
  await expect(page.locator('#mia-composer-count')).toHaveText('1 character remaining')
  await composer.fill('x'.repeat(8_001))
  await expect(composer).toHaveValue('x'.repeat(8_000))
  await expect(page.locator('#mia-composer-count')).toHaveText('0 characters remaining')

  await composer.fill('First line')
  await composer.press('Shift+Enter')
  await composer.type('Second line')
  await expect(composer).toHaveValue('First line\nSecond line')

  await composer.fill('')
  const clearedMetrics = await composer.evaluate((element) => ({
    height: element.getBoundingClientRect().height,
    overflowY: getComputedStyle(element).overflowY,
  }))
  expect(clearedMetrics.height).toBeLessThanOrEqual(initialHeight + 1)
  expect(clearedMetrics.overflowY).toBe('hidden')
})

test('Ask Mia preserves one request ID through a network failure and reload so retry cannot duplicate the turn', async ({ page }) => {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  const requestIds: string[] = []
  let attempt = 0
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()

    attempt += 1
    requestIds.push(route.request().postDataJSON().request_id)
    if (attempt === 1) return route.abort('timedout')

    return route.fulfill({
      status: 201,
      json: {
        user_message: { id: 701, role: 'user', author: 'You', content: 'What should I focus on?', attachments: [] },
        assistant_message: { id: 702, role: 'assistant', author: 'Mia', content: 'Protect the baseline first.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: null,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await composer.fill('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(composer).toHaveValue('What should I focus on?')
  await expect(composer).toBeEnabled()
  await expect(page.getByRole('button', { name: 'Send message to Mia' })).toBeEnabled()

  await page.reload()
  const restoredComposer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(restoredComposer).toHaveValue('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(page.getByText('Protect the baseline first.')).toBeVisible()

  expect(requestIds).toHaveLength(2)
  expect(requestIds[0]).toMatch(/^mia-request-/)
  expect(requestIds[1]).toBe(requestIds[0])
})

test('Ask Mia uses a new request ID when the retry targets a different budget month', async ({ page }) => {
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  const requests: Array<{ request_id: string; month: number }> = []
  let attempt = 0
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()

    attempt += 1
    requests.push(route.request().postDataJSON())
    if (attempt === 1) return route.abort('timedout')

    return route.fulfill({
      status: 201,
      json: {
        user_message: { id: 711, role: 'user', author: 'You', content: 'What should I focus on?', attachments: [] },
        assistant_message: { id: 712, role: 'assistant', author: 'Mia', content: 'Use the newly selected month.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: null,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  const composer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await composer.fill('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(composer).toHaveValue('What should I focus on?')

  await openSection(page, 'Budget')
  const nextMonthIndex = (new Date().getMonth() + 1) % 12
  await page.getByLabel('Report month').selectOption(String(nextMonthIndex))
  await openSection(page, 'Ask Mia')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(page.getByText('Use the newly selected month.')).toBeVisible()

  expect(requests).toHaveLength(2)
  expect(requests[1].request_id).not.toBe(requests[0].request_id)
  expect(requests[1].month).toBe(nextMonthIndex + 1)
  expect(requests[1].month).not.toBe(requests[0].month)
})

test('Ask Mia restores uploaded attachment context and its exact request ID after reload', async ({ page }) => {
  const emptySourceErrors: string[] = []
  let presignRequests = 0
  page.on('console', (message) => {
    if (message.type() === 'error' && message.text().includes('empty string ("") was passed to the src attribute')) {
      emptySourceErrors.push(message.text())
    }
  })
  await page.route('http://api.test/api/v1/document_imports/presign', (route) => {
    presignRequests += 1
    return route.fulfill({ status: 500, json: { error: 'A restored attachment must not be uploaded again.' } })
  })
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  const message = 'Please review this receipt.'
  const month = new Date().getMonth() + 1
  const requestId = 'mia-request-attachment-reload-1'
  const signature = JSON.stringify({ message, attachmentIds: [501], year: currentYear, month })
  await page.addInitScript(({ storedRequest }) => {
    window.sessionStorage.setItem('household-cfo:mia-chat:v1:user-901:pending-request', JSON.stringify(storedRequest))
  }, {
    storedRequest: {
      id: requestId,
      signature,
      message,
      attachments: [{
        document_import_id: 501,
        filename: 'saved-receipt.jpg',
        content_type: 'image/jpeg',
        document_kind: 'receipt',
        status: 'needs_review',
        source_available: true,
      }],
    },
  })

  let submittedBody: { request_id?: string; document_import_ids?: number[] } = {}
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()

    submittedBody = route.request().postDataJSON()
    return route.fulfill({
      status: 201,
      json: {
        user_message: { id: 721, role: 'user', author: 'You', content: message, attachments: [] },
        assistant_message: { id: 722, role: 'assistant', author: 'Mia', content: 'I kept the uploaded receipt attached.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: null,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toHaveValue(message)
  await expect(page.getByText('saved-receipt.jpg')).toBeVisible()
  await expect(page.locator('.composer-attachment-card img')).toHaveCount(0)
  await page.getByRole('button', { name: 'Receipt screenshot', exact: true }).click()
  await expect(page.getByText('This restored upload has no local preview. You can still send it to Mia.')).toBeVisible()
  await expect(page.locator('.local-attachment-preview img')).toHaveCount(0)
  expect(emptySourceErrors).toEqual([])
  await page.getByRole('button', { name: 'Close', exact: true }).click()
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(page.getByText('I kept the uploaded receipt attached.')).toBeVisible()

  expect(submittedBody.request_id).toBe(requestId)
  expect(submittedBody.document_import_ids).toEqual([501])
  expect(presignRequests).toBe(0)
})

test('Ask Mia uploads an attachment with its question and renders the grounded reply', async ({ page }) => {
  const requestOrder: string[] = []
  let presignBody: Record<string, unknown> = {}
  let miaBody: Record<string, unknown> = {}
  const documentImport = {
    id: 640,
    household_id: 77,
    document_kind: 'receipt',
    status: 'needs_review',
    filename: 'receipt.png',
    content_type: 'image/png',
    byte_size: 20,
    document_date: null,
    period_start_on: null,
    period_end_on: null,
    extracted_summary: 'Receipt ready for Mia.',
    extraction_error: null,
    processed_at: `${currentYear}-10-01T00:00:05Z`,
    applied_at: null,
    source_deleted_at: null,
    updated_at: `${currentYear}-10-01T00:00:05Z`,
    source_available: true,
    details_included: false,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {},
    items: [],
    transaction_drafts: [],
    attempts: [],
  }

  await page.route('http://api.test/api/v1/document_imports/presign', (route) => {
    requestOrder.push('presign')
    presignBody = route.request().postDataJSON()
    return route.fulfill({
      status: 200,
      json: {
        upload_url: 'https://private-storage.example/receipt-upload',
        upload_headers: { 'Content-Type': 'image/png' },
        upload_token: 'receipt-upload-token',
      },
    })
  })
  await page.route('https://private-storage.example/receipt-upload', (route) => {
    requestOrder.push('storage')
    expect(route.request().method()).toBe('PUT')
    return route.fulfill({ status: 200, body: '' })
  })
  await page.route('http://api.test/api/v1/document_imports/complete', (route) => {
    requestOrder.push('complete')
    expect(route.request().postDataJSON()).toEqual({ upload_token: 'receipt-upload-token' })
    return route.fulfill({ status: 201, json: { document_import: documentImport } })
  })
  await page.route('http://api.test/api/v1/mia/messages', (route) => {
    if (route.request().method() !== 'POST') return route.fallback()
    requestOrder.push('mia')
    miaBody = route.request().postDataJSON()
    return route.fulfill({
      status: 201,
      json: {
        user_message: { id: 741, role: 'user', author: 'You', content: 'Does this grocery receipt fit my plan?', attachments: [{ document_import_id: 640, filename: 'receipt.png', content_type: 'image/png', document_kind: 'receipt', status: 'needs_review', source_available: true }] },
        assistant_message: { id: 742, role: 'assistant', author: 'Mia', content: 'I reviewed the grocery receipt with your question. The draft purchase is ready for your approval.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: null,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')
  await page.locator('.ask-row input[type="file"]').setInputFiles({
    name: 'receipt.png',
    mimeType: 'image/png',
    buffer: Buffer.from('mock-receipt-evidence'),
  })
  await expect(page.getByText('Images and PDFs up to 12 MB · CSV, Excel, and Word up to 20 MB')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Receipt screenshot', exact: true })).toBeVisible()

  await page.getByRole('textbox', { name: 'Ask Mia', exact: true }).fill('Does this grocery receipt fit my plan?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await expect(page.getByText('I reviewed the grocery receipt with your question. The draft purchase is ready for your approval.')).toBeVisible()

  expect(requestOrder).toEqual(['presign', 'storage', 'complete', 'mia'])
  expect(presignBody).toMatchObject({
    filename: 'receipt.png',
    byte_size: 21,
    document_kind: 'receipt',
    upload_origin: 'mia',
    upload_context: 'Does this grocery receipt fit my plan?',
  })
  expect(miaBody).toMatchObject({
    message: 'Does this grocery receipt fit my plan?',
    document_import_ids: [640],
  })
})

test('Budget explains scheduled income changes and upcoming annual pressure', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Money in, money out, and what is left.' })).toBeVisible()
  const outflowBreakdown = page.getByRole('group', { name: 'Monthly money out breakdown' })
  await expect(outflowBreakdown).toContainText('Category plan')
  await expect(outflowBreakdown).toContainText('$5,300.00')
  await expect(outflowBreakdown).toContainText('Debt minimums')
  await expect(outflowBreakdown).toContainText('$200.00')
  await expect(outflowBreakdown).toContainText('Total money out')
  await expect(outflowBreakdown).toContainText('$5,500.00')
  const annualMoneyOut = page.getByLabel('Annual money out breakdown')
  await expect(annualMoneyOut).toContainText('Annual category plan$66,600.00')
  await expect(annualMoneyOut).toContainText('Annual debt minimums$2,400.00')
  await expect(annualMoneyOut).toContainText('Total annual money out$69,000.00')
  await expect(page.getByRole('button', { name: 'Ask Mia to update my plan' })).toBeVisible()
  await expect(page.getByRole('region', { name: 'Annual budget table' })).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Set it once, then schedule what changes.' })).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Every category, ordered by pressure' })).toHaveCount(0)

  await page.getByRole('button', { name: 'Manage manually' }).click()
  const manualManager = page.locator('.budget-manual-manager')
  await expect(manualManager).toBeInViewport()
  await expect(page.getByLabel('New category')).toBeFocused()
  await page.getByRole('button', { name: 'Schedule income' }).click()
  await expect(page.getByRole('heading', { name: 'Set it once, then schedule what changes.' })).toBeVisible()
  await expect(page.getByText('Recurring amount changes')).toBeVisible()
  await expect(page.getByText('$15,000.00 Monthly')).toBeVisible()
  await page.getByRole('button', { name: 'Close manual tools' }).click()

  await expect(page.getByRole('heading', { name: 'See the expensive months before they arrive.' })).toBeVisible()
  await expect(page.getByText('Dec spending spike')).toBeVisible()
  await expect(page.getByText('Holiday travel')).toBeVisible()
  await expect(page.getByRole('heading', { name: 'See which layer is using the plan.' })).toBeVisible()
  await expect(page.locator('.expense-stack-row')).toHaveCount(4)
  await expect(page.getByText('$75.00 pending review—not included in actuals.')).toBeVisible()
  await page.getByText('Monthly activity and transactions').click()
  await expect(page.getByRole('heading', { name: 'Every category, ordered by pressure' })).toBeVisible()
  await expect(page.locator('.annual-outlook .cash-flow-month')).toHaveCount(12)
  const diningDraft = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await expect(diningDraft.getByRole('region', { name: new RegExp(`Budget impact if approved for ${currentShortMonth}`) })).toContainText('$100.00 over plan if approved.')
  await expect(diningDraft).toContainText('Actuals stay unchanged until you confirm.')
})

test('My Profile manages explicit income sources with stable keys on desktop and mobile', async ({ page }) => {
  const workspace = realWorkspaceData(true)
  workspace.budget.annual_plan.income_sources[0] = {
    ...workspace.budget.annual_plan.income_sources[0],
    starts_on: `${currentYear}-01-01`,
    ends_on: null,
    active: true,
  }
  const currentBudget = structuredClone(workspace.budget)
  const requests: Array<{ method: string; key: string | null; body: Record<string, unknown> }> = []

  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: { ...workspace, budget: currentBudget } }))
  await page.route('http://api.test/api/v1/income_sources**', (route) => {
    const request = route.request()
    const method = request.method()
    const body = request.postDataJSON() as Record<string, unknown>
    requests.push({ method, key: request.headers()['idempotency-key'] ?? null, body })
    const url = new URL(request.url())
    const match = url.pathname.match(/\/income_sources\/(\d+)/)
    const sourceId = match ? Number(match[1]) : null
    const input = (body.income_source ?? {}) as Record<string, string>

    if (method === 'POST' && url.pathname.endsWith('/restore') && sourceId) {
      currentBudget.annual_plan.income_sources = currentBudget.annual_plan.income_sources.map((source) => source.id === sourceId ? { ...source, ends_on: null, active: true } : source)
      workspace.workspace.setup_values.business_income = 1_200
      workspace.dashboard.summary.monthly_income = 16_200
    } else if (method === 'POST') {
      currentBudget.annual_plan.income_sources.push({
        id: 2,
        label: input.label,
        source_type: input.source_type,
        base_amount: Number(input.amount),
        base_cadence: input.cadence,
        starts_on: input.starts_on,
        ends_on: null,
        active: true,
        schedule_entries: [{
          id: 91,
          entry_type: 'recurring_change',
          label: null,
          amount: 1_500,
          cadence: 'monthly',
          effective_on: `${currentYear}-12-01`,
          retained_after_transition: false,
        }],
      })
      workspace.workspace.setup_values.primary_income = 15_000
      workspace.workspace.setup_values.business_income = Number(input.amount)
      workspace.dashboard.summary.monthly_income = 15_000 + Number(input.amount)
    } else if (method === 'PATCH' && sourceId) {
      currentBudget.annual_plan.income_sources = currentBudget.annual_plan.income_sources.map((source) => source.id === sourceId ? {
        ...source,
        label: input.label,
        source_type: input.source_type,
        base_amount: Number(input.amount),
        base_cadence: input.cadence,
        starts_on: input.starts_on,
      } : source)
    } else if (method === 'DELETE' && sourceId) {
      currentBudget.annual_plan.income_sources = currentBudget.annual_plan.income_sources.map((source) => source.id === sourceId ? {
        ...source,
        ends_on: input.ends_on,
        active: false,
      } : source)
      workspace.workspace.setup_values.business_income = 0
      workspace.dashboard.summary.monthly_income = 15_000
    }

    return route.fulfill({ status: method === 'POST' && !url.pathname.endsWith('/restore') ? 201 : 200, json: { income_source: {}, budget: currentBudget } })
  })

  await page.clock.setFixedTime(new Date(Date.UTC(currentYear, 8, 30, 15, 30)))
  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  await expect(page.getByRole('spinbutton', { name: 'Job income total (calculated)' })).toBeDisabled()
  await expect(page.getByRole('heading', { name: 'Keep each source clear and editable.' })).toBeVisible()
  await expect(page.locator('.income-source-form').getByLabel('Starting month')).toHaveValue(`${currentYear}-10`)

  await page.getByRole('textbox', { name: 'Name', exact: true }).fill('Side consulting')
  await page.locator('.income-source-form label').filter({ hasText: 'Type' }).locator('select').selectOption('business')
  await page.getByRole('spinbutton', { name: 'Starting amount' }).fill('1200')
  await page.getByRole('button', { name: 'Add source' }).click()

  const consulting = page.locator('.income-source-manager-card').filter({ hasText: 'Side consulting' })
  await expect(consulting).toContainText('$1,200.00')
  await expect(consulting).toContainText('Current')
  await expect(consulting).toContainText(`Dec ${currentYear} · $1,500.00`)
  await expect(page.locator('.income-source-manager-heading')).toContainText('$16,200.00 current monthly')
  await page.getByText('Add details for a stronger CFO read').click()
  await expect(page.getByRole('spinbutton', { name: 'Business income total (calculated)' })).toHaveValue('1200')
  expect(requests[0].key).toBeTruthy()
  expect(requests[0].body).toMatchObject({ income_source: { label: 'Side consulting', source_type: 'business', amount: '1200' } })

  await consulting.getByRole('button', { name: 'Edit Side consulting' }).click()
  await expect(page.getByRole('textbox', { name: 'Name', exact: true })).toBeFocused()
  await page.locator('.income-source-form').getByRole('button', { name: 'Cancel' }).click()
  await expect(consulting.getByRole('button', { name: 'Edit Side consulting' })).toBeFocused()

  await consulting.getByRole('button', { name: 'End Side consulting' }).click()
  await expect(consulting.getByLabel('First $0 month')).toBeFocused()
  await consulting.getByLabel('First $0 month').fill(`${currentYear}-10`)
  await consulting.getByRole('button', { name: 'Confirm stop for Side consulting' }).click()
  await expect(consulting).toBeFocused()
  await expect(consulting).toContainText(`Stops Oct ${currentYear}`)
  await expect(consulting).toContainText('None scheduled')
  await expect(page.getByRole('spinbutton', { name: 'Business income total (calculated)' })).toHaveValue('0')
  expect(requests[1].key).toBeTruthy()
  expect(requests[1].key).not.toBe(requests[0].key)

  await consulting.getByRole('button', { name: 'Restore Side consulting' }).click()
  await expect(consulting).toBeFocused()
  await expect(consulting).toContainText('Current')
  await expect(consulting).toContainText(`Dec ${currentYear} · $1,500.00`)
  await expect(page.getByRole('spinbutton', { name: 'Business income total (calculated)' })).toHaveValue('1200')
  expect(requests[2].key).toBeTruthy()
  expect(requests[2].key).not.toBe(requests[1].key)

  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 844 })
    await expect(page.getByRole('heading', { name: 'Keep each source clear and editable.' })).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  }
})

test('continuing job income is never assumed and requires explicit participant approval', async ({ page }) => {
  const submittedChanges: Array<{ retained_after_transition?: boolean }> = []
  const workspace = realWorkspaceData(true)
  const sources = workspace.budget.annual_plan.income_sources as unknown as Array<Record<string, unknown>>
  sources[0] = { ...sources[0], starts_on: `${currentYear}-01-01`, ends_on: null, active: true }
  sources.push(
    { id: 2, label: 'Ended seasonal work', source_type: 'other', base_amount: 900, base_cadence: 'monthly', starts_on: `${currentYear}-01-01`, ends_on: `${currentYear}-06-01`, active: false, schedule_entries: [] },
    { id: 3, label: 'Future contract', source_type: 'business', base_amount: 2000, base_cadence: 'monthly', starts_on: `${currentYear}-12-01`, ends_on: null, active: true, schedule_entries: [] },
  )
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: workspace }))
  await page.route('http://api.test/api/v1/income_schedule_entries**', (route) => {
    const submitted = route.request().postDataJSON().income_schedule_entry as { retained_after_transition?: boolean; amount: string; effective_on: string }
    submittedChanges.push(submitted)
    const updatedBudget = structuredClone(workspace.budget)
    updatedBudget.annual_plan.income_sources[0].schedule_entries = [{
      id: 27,
      entry_type: 'recurring_change',
      label: null,
      amount: Number(submitted.amount),
      cadence: 'monthly',
      effective_on: submitted.effective_on,
      retained_after_transition: submitted.retained_after_transition === true,
    }]
    workspace.budget = updatedBudget
    return route.fulfill({ status: route.request().method() === 'POST' ? 201 : 200, json: { budget: updatedBudget } })
  })

  await page.clock.setFixedTime(new Date(Date.UTC(currentYear, 8, 30, 15, 30)))
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByRole('button', { name: 'Manage manually' }).click()
  await page.getByRole('button', { name: 'Schedule income' }).click()
  const sourceSelect = page.locator('.income-schedule-form label').filter({ hasText: 'Income source' }).locator('select')
  await expect(sourceSelect.locator('option')).toHaveText(['Primary income'])
  await page.locator('.income-schedule-form label').filter({ hasText: 'Starting month' }).locator('input').fill(`${currentYear}-12`)
  await expect(sourceSelect.locator('option')).toHaveText(['Primary income', 'Future contract'])
  await page.locator('.income-schedule-form label').filter({ hasText: 'Starting month' }).locator('input').fill(`${currentYear}-10`)
  await page.getByRole('spinbutton', { name: 'Amount' }).fill('7500')

  const retention = page.getByRole('checkbox', { name: /This job income will continue after my transition/ })
  await expect(retention).not.toBeChecked()
  await retention.check()
  await page.getByRole('button', { name: 'Schedule income change' }).click()
  await expect(page.getByText('Confirmed to continue after transition')).toBeVisible()
  expect(submittedChanges[0].retained_after_transition).toBe(true)

  await page.locator('.annual-income-planner').getByRole('button', { name: 'Edit', exact: true }).click()
  await expect(retention).toBeChecked()
  await retention.uncheck()
  await page.getByRole('button', { name: 'Save income change' }).click()
  await expect(page.getByText('Confirmed to continue after transition')).toBeHidden()
  expect(submittedChanges[1].retained_after_transition).toBe(false)
})

test('Budget keeps headline, cockpit, and chart on the selected report month', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()

  const reportMonth = page.getByLabel('Report month')
  const headline = page.locator('.budget-period-summary')
  const cockpit = page.locator('.month-plan-summary')
  const chartDetail = page.locator('.annual-outlook .cash-flow-detail-panel')

  await reportMonth.selectOption('11')
  await expect(headline.getByRole('heading', { name: `Dec ${currentYear}` })).toBeVisible()
  await expect(headline).toContainText('Income$15,000.00')
  await expect(headline).toContainText('Planned outflow$8,500.00')
  await expect(headline).toContainText('Baseline surplus$6,500.00')
  await expect(cockpit).toContainText(`Dec ${currentYear}`)
  await expect(cockpit.getByRole('group', { name: 'Monthly money out breakdown' })).toContainText('Total money out$8,500.00')
  await expect(chartDetail).toContainText(`Report monthDec ${currentYear}`)
  await expect(chartDetail).toContainText('Planned outflow$8,500.00')

  await page.locator('.annual-outlook .cash-flow-month-trigger').first().click()
  await expect(chartDetail).toContainText(`Chart previewJan ${currentYear}`)
  await expect(reportMonth).toHaveValue('11')

  await page.getByRole('button', { name: 'This month', exact: true }).click()
  await expect(reportMonth).toHaveValue(String(new Date().getMonth()))
  await expect(headline.getByRole('heading', { name: `${currentShortMonth} ${currentYear}` })).toBeVisible()
  await expect(chartDetail).toContainText(`Report month${currentShortMonth} ${currentYear}`)
})

test('focused manual budget tools expose exact controls without a page hunt and protect dirty edits', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByRole('button', { name: 'Manage manually' }).click()

  const manager = page.locator('.budget-manual-manager')
  await expect(manager).toBeInViewport()
  await expect(page.getByLabel('New category')).toBeFocused()
  await expect(page.getByRole('region', { name: 'Annual budget table' })).toHaveCount(0)

  await page.getByRole('button', { name: 'Edit monthly plan' }).click()
  const table = page.getByRole('region', { name: 'Annual budget table' })
  await expect(table).toBeVisible()
  const januaryDining = page.getByLabel('Dining out planned for Jan')
  await januaryDining.fill('650')
  await expect(manager).toContainText('1 unsaved change. Save or cancel before switching tools.')
  await page.getByRole('button', { name: 'Edit monthly plan' }).click()
  await expect(januaryDining).toHaveValue('650')
  await expect(page.getByRole('button', { name: 'Add a category' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Schedule income' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Close manual tools' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Previous year' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Next year' })).toBeDisabled()
  await expect(page.getByLabel('Report month')).toBeDisabled()
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(manager.getByRole('alert')).toContainText('Save or cancel them before leaving Budget')
  await expect(januaryDining).toHaveValue('650')
  await expect(page.getByRole('heading', { name: 'Money in, money out, and what is left.' })).toBeVisible()
  await page.goBack()
  await expect(page).toHaveURL(/#Budget$/)
  await expect(manager.getByRole('alert')).toContainText('Save or cancel them before leaving Budget')
  await expect(januaryDining).toHaveValue('650')
  await page.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(manager).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Manage manually' })).toBeFocused()

  await page.getByRole('button', { name: 'Ask Mia to update my plan' }).click()
  const composer = page.getByRole('textbox', { name: 'Ask Mia' })
  await expect(composer).toBeFocused()
  await expect(composer).toHaveValue('I want to update my budget. Help me make this change safely: ')
})

test('a partially saved budget keeps the approved change and protects unapplied drafts until retry', async ({ page }) => {
  const savedAmounts = new Map<number, number>()
  let rejectFebruaryOnce = true

  await page.route('http://api.test/api/v1/budget_allocations/*', (route) => {
    const allocationId = Number(new URL(route.request().url()).pathname.split('/').at(-1))
    if (allocationId === 202 && rejectFebruaryOnce) {
      rejectFebruaryOnce = false
      return route.fulfill({ status: 503, json: { error: 'February could not be saved.' } })
    }

    savedAmounts.set(allocationId, Number(route.request().postDataJSON().allocation.planned_amount))
    const updatedBudget = structuredClone(realWorkspaceData(true).budget)
    updatedBudget.annual_plan.rows = updatedBudget.annual_plan.rows.map((row) => ({
      ...row,
      months: row.months.map((month) => ({
        ...month,
        planned: savedAmounts.get(month.allocation_id) ?? month.planned,
      })),
    }))
    return route.fulfill({ status: 200, json: { budget: updatedBudget } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByRole('button', { name: 'Manage manually' }).click()
  await page.getByRole('button', { name: 'Edit monthly plan' }).click()

  const manager = page.locator('.budget-manual-manager')
  const januaryDining = page.getByLabel('Dining out planned for Jan')
  const februaryDining = page.getByLabel('Dining out planned for Feb')
  await januaryDining.fill('650')
  await februaryDining.fill('700')
  await page.getByRole('button', { name: 'Save 2 changes' }).click()

  await expect(manager.getByRole('alert')).toContainText('Earlier changes were saved; your remaining edits are still available to retry.')
  await expect(januaryDining).toHaveValue('650')
  await expect(februaryDining).toHaveValue('700')
  await expect(manager).toContainText('1 unsaved change. Save or cancel before switching tools.')
  await expect(page.getByLabel('Report month')).toBeDisabled()
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(manager.getByRole('alert')).toContainText('Save or cancel them before leaving Budget')
  await expect(februaryDining).toHaveValue('700')

  await page.getByRole('button', { name: 'Save 1 change' }).click()
  await expect(manager).toHaveCount(0)
  expect(savedAmounts.get(201)).toBe(650)
  expect(savedAmounts.get(202)).toBe(700)
})

test('participant navigation remains available after deep scrolling', async ({ page }) => {
  await page.goto('/')
  await page.evaluate(() => document.fonts.ready)
  const homeHeaderHeight = await page.locator('.shell-header').evaluate((element) => element.getBoundingClientRect().height)
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  const budgetHeaderHeight = await page.locator('.shell-header').evaluate((element) => element.getBoundingClientRect().height)
  expect(Math.abs(budgetHeaderHeight - homeHeaderHeight)).toBeLessThanOrEqual(1)
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight))
  await expect(page.locator('.tabs-shell')).toBeInViewport()
  const top = await page.locator('.tabs-shell').evaluate((element) => Math.round(element.getBoundingClientRect().top))
  expect(top).toBe(0)
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(0)
  await expect(page.locator('.shell-header')).toHaveCount(1)
})

test('participant links preserve browser history, heading focus, and section scroll', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop history and focus assertion')
  await page.goto('/#Home')

  const budgetLink = page.getByRole('link', { name: 'Budget', exact: true })
  await expect(budgetLink).toHaveAttribute('href', '#Budget')
  await budgetLink.click()
  await expect(page).toHaveURL(/#Budget$/)
  const budgetHeading = page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })
  await expect(budgetHeading).toBeFocused()

  await page.evaluate(() => window.scrollTo(0, Math.min(900, document.documentElement.scrollHeight - window.innerHeight)))
  const budgetScrollTop = await page.evaluate(() => Math.round(window.scrollY))
  expect(budgetScrollTop).toBeGreaterThan(0)

  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await expect(page).toHaveURL(/#Ask%20Mia$/)
  await expect(page.getByRole('heading', { name: 'Tell Mia what changed.' })).toBeFocused()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(0)

  await page.goBack()
  await expect(page).toHaveURL(/#Budget$/)
  await expect(budgetHeading).toBeFocused()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(budgetScrollTop)

  await page.goBack()
  await expect(page).toHaveURL(/#Home$/)
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeFocused()

  await page.goForward()
  await expect(page).toHaveURL(/#Budget$/)
  await expect(budgetHeading).toBeFocused()
})

test('Review is canonical and legacy Activity links remain compatible', async ({ page }) => {
  await page.goto('/#Review')
  await expect(page).toHaveURL(/#Review$/)
  await expect(page.getByRole('link', { name: 'Review', exact: true })).toHaveAttribute('aria-current', 'page')
  await expect(page.getByRole('heading', { name: 'Review what changed before it becomes household truth.' })).toBeVisible()

  await page.goto('/#Activity')
  await expect(page).toHaveURL(/#Review$/)
  await expect(page.getByRole('link', { name: 'Review', exact: true })).toHaveAttribute('aria-current', 'page')
})

test('unfinished Plaid returns keep Profile and the URL aligned through reload and history', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop history assertion')
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('https://cdn.plaid.com/link/v2/stable/link-initialize.js', (route) => route.fulfill({
    status: 200,
    contentType: 'text/javascript',
    body: `
      window.Plaid = {
        create: function (config) {
          setTimeout(function () { if (config.onLoad) config.onLoad(); }, 0);
          return { open: function () {}, submit: function () {}, exit: function (_options, callback) { if (callback) callback(); }, destroy: function () {} };
        }
      };
    `,
  }))
  await page.addInitScript(() => {
    window.localStorage.setItem('household-cfo:plaid-oauth:v1', JSON.stringify({
      userId: '901',
      linkToken: 'link-oauth-regression',
      updateItemId: null,
      createdAt: Date.now(),
    }))
  })

  await page.goto('/#Home')
  await page.goto('/?pilot_e2e_role=participant&oauth_state_id=unfinished#Budget')
  await expect(page).toHaveURL(/oauth_state_id=unfinished#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()

  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await expect(page).toHaveURL(/oauth_state_id=unfinished#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()

  await page.reload()
  await expect(page).toHaveURL(/oauth_state_id=unfinished#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()

  await page.goBack()
  await expect(page).toHaveURL(/#Home$/)
  await page.goForward()
  await expect(page).toHaveURL(/oauth_state_id=unfinished#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()
})

test('query-only Plaid returns preserve callback state while the workspace loads', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop callback loading assertion')
  let releaseWorkspace!: () => void
  const workspaceReady = new Promise<void>((resolve) => { releaseWorkspace = resolve })
  await page.route('http://api.test/api/v1/workspace', async (route) => {
    await workspaceReady
    await route.fulfill({ status: 200, json: realWorkspaceData(true) })
  })
  await page.route('https://cdn.plaid.com/link/v2/stable/link-initialize.js', (route) => route.fulfill({
    status: 200,
    contentType: 'text/javascript',
    body: `
      window.Plaid = {
        create: function (config) {
          setTimeout(function () { if (config.onLoad) config.onLoad(); }, 0);
          return { open: function () {}, submit: function () {}, exit: function (_options, callback) { if (callback) callback(); }, destroy: function () {} };
        }
      };
    `,
  }))
  await page.addInitScript(() => {
    window.localStorage.setItem('household-cfo:plaid-oauth:v1', JSON.stringify({
      userId: '901',
      linkToken: 'link-oauth-delayed-workspace',
      updateItemId: null,
      createdAt: Date.now(),
    }))
  })

  await page.goto('/?pilot_e2e_role=participant&oauth_state_id=delayed')
  await expect(page).toHaveURL(/oauth_state_id=delayed#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Loading your first cohort workspace.' })).toBeVisible()

  releaseWorkspace()
  await expect(page).toHaveURL(/oauth_state_id=delayed#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeVisible()
})

test('stale Plaid return queries recover normal participant navigation', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop callback recovery assertion')
  await page.goto('/?pilot_e2e_role=participant&oauth_state_id=stale#Budget')

  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#My%20Profile$/)
  await expect(page.getByRole('heading', { name: 'Give Mia the basics for a useful first answer.' })).toBeVisible()

  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Budget$/)
  await expect(page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })).toBeFocused()

  await page.reload()
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Budget$/)
  await expect(page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })).toBeVisible()
})

test('participant history canonicalizes unauthorized Admin routes to Home', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop authorization history assertion')
  await page.goto('/?pilot_e2e_role=participant#Budget')
  await expect(page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })).toBeVisible()

  await page.goto('/?pilot_e2e_role=participant#Admin')
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Home$/)
  const incompleteHomeHeading = page.getByRole('heading', { name: 'Give Mia a useful starting point.' })
  await expect(incompleteHomeHeading).toBeVisible()

  await page.goBack()
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Budget$/)
  await expect(page.getByRole('heading', { name: 'Know what came in, what went out, and what is left.' })).toBeFocused()

  await page.goForward()
  await expect(page).toHaveURL(/\?pilot_e2e_role=participant#Home$/)
  await expect(incompleteHomeHeading).toBeFocused()
})

test('Clerk-enabled route recovery waits for participant authorization before canonicalizing', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop authorization loading assertion')
  await page.goto('/?pilot_e2e_role=delayed_participant#Admin')

  await expect(page).toHaveURL(/#Admin$/)
  await expect(page).toHaveURL(/#Home$/)
  await expect(page.getByRole('heading', { name: 'Give Mia a useful starting point.' })).toBeVisible()

  await page.goto('/?pilot_e2e_role=delayed_participant#Not%20A%20Screen')
  await expect(page).toHaveURL(/#Home$/)
})

test('Wealth and Optionality explain decisions without fake payoff progress or conflicting scores', async ({ page }) => {
  await page.goto('/')
  await openSection(page, 'Wealth')
  const debtCard = page.getByRole('heading', { name: 'Debt payoff' }).locator('..')
  await expect(debtCard.getByText('$5,400.00 remaining')).toBeVisible()
  await expect(debtCard.locator('.progress-track')).toHaveCount(0)
  await expect(debtCard).not.toContainText('0 / 5,400')
  const outlook = page.locator('.metric-card').filter({ hasText: '10-year surplus capacity' })
  await expect(outlook).toContainText('planning capacity—not confirmed savings, an investment contribution, or a forecast')
  await expect(page.getByText('Retirement projection', { exact: true })).toHaveCount(0)

  await openSection(page, 'Optionality')
  await expect(page.getByText('Best fit now')).toBeVisible()
  await expect(page.getByText('Build runway first')).toBeVisible()
  await expect(page.getByText('Not ready yet', { exact: true })).toBeVisible()
  await expect(page.getByText(/\/100 readiness/)).toHaveCount(0)
})

test('Wealth stays accurate while the frontend and API metric contracts roll out', async ({ page }) => {
  await page.route('http://api.test/api/demo/wealth', (route) => route.fulfill({
    status: 200,
    json: {
      ...wealth,
      summary: {
        net_worth: 142_800,
        liquid_net_worth: 17_740,
        retirement_projection: 190_000,
        monthly_wealth_building: 655,
      },
    },
  }))

  await page.goto('/')
  await openSection(page, 'Wealth')

  await expect(page.locator('.metric-card').filter({ hasText: '10-year surplus capacity' })).toContainText('$78,600.00')
  await expect(page.locator('.metric-card').filter({ hasText: 'Monthly surplus available' })).toContainText('$655.00')
  await expect(page.getByText('$190,000.00', { exact: true })).toHaveCount(0)
})

test('desktop Tools stays anchored to its trigger and contains keyboard focus', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop-only popover assertion')
  await page.goto('/')

  const tools = page.getByRole('button', { name: 'Tools', exact: true })
  const triggerBox = await tools.boundingBox()
  await tools.click()

  const dialog = page.getByRole('dialog', { name: 'Go deeper when you need to.' })
  await expect(dialog).toBeVisible()
  await dialog.evaluate(async (element) => {
    await Promise.all(element.getAnimations().map((animation) => animation.finished.catch(() => undefined)))
  })
  const dialogBox = await dialog.boundingBox()
  expect(triggerBox).not.toBeNull()
  expect(dialogBox).not.toBeNull()
  expect(dialogBox?.y ?? 0).toBeGreaterThanOrEqual((triggerBox?.y ?? 0) + (triggerBox?.height ?? 0) + 6)
  expect((dialogBox?.y ?? 0) + (dialogBox?.height ?? 0)).toBeLessThanOrEqual(page.viewportSize()?.height ?? 720)

  await expect(page.getByRole('link', { name: 'My Profile', exact: true })).toBeFocused()
  await page.keyboard.press('Shift+Tab')
  await expect(dialog.getByRole('button', { name: 'Close tools' })).toBeFocused()
  await page.keyboard.press('Shift+Tab')
  await expect(page.getByRole('link', { name: 'Optionality', exact: true })).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(dialog.getByRole('button', { name: 'Close tools' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(dialog).toBeHidden()
  await expect(tools).toBeFocused()

  await tools.click()
  await openSection(page, 'My Profile')
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeFocused()
})

test('compact phone layouts keep a stable shell and overlay secondary tools without page reflow', async ({ page }, testInfo) => {
  test.skip(!testInfo.project.name.includes('mobile'), 'mobile-only responsive assertion')
  await page.goto('/')

  const header = page.locator('.shell-header')
  const homeHeaderBox = await header.boundingBox()
  const homeContentY = await page.locator('.home-welcome-panel').evaluate((element) => Math.round(element.getBoundingClientRect().top))
  const tools = page.getByRole('button', { name: 'Tools', exact: true })
  await expect(tools).toBeVisible()
  await expect(page.getByRole('link', { name: 'Review', exact: true })).toBeVisible()
  await expect(tools).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByRole('link', { name: 'My Profile', exact: true })).toHaveCount(0)
  await tools.click()
  await expect(tools).toHaveAttribute('aria-expanded', 'true')
  await expect(page.getByRole('link', { name: 'My Profile', exact: true })).toBeVisible()
  expect(await page.locator('.home-welcome-panel').evaluate((element) => Math.round(element.getBoundingClientRect().top))).toBe(homeContentY)
  await expect(page.locator('.tabs-secondary')).toHaveCSS('position', 'fixed')
  const primaryNavButtons = page.locator('.tabs > :is(a, button)')
  const touchHeights = await primaryNavButtons.evaluateAll((buttons) => buttons.map((button) => button.getBoundingClientRect().height))
  expect(Math.min(...touchHeights)).toBeGreaterThanOrEqual(44)
  await openSection(page, 'My Profile')
  await expect(tools).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByRole('heading', { name: 'Pilot Household' })).toBeFocused()
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await page.getByText('Explore the plan behind this snapshot').click()
  await expect(page.locator('.home-financial-visuals .cash-flow-month')).toHaveCount(12)
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(0)
  const askMiaHeaderBox = await header.boundingBox()
  expect(Math.abs((askMiaHeaderBox?.height ?? 0) - (homeHeaderBox?.height ?? 0))).toBeLessThan(0.5)
  expect(Math.abs((askMiaHeaderBox?.y ?? 0) - (homeHeaderBox?.y ?? 0))).toBeLessThan(0.5)
  await expect(page.getByText('More prompts →')).toBeHidden()
  await page.locator('.screen-grid').evaluate(async (screen) => {
    await Promise.all(screen.getAnimations().map((animation) => animation.finished.catch(() => undefined)))
  })
  const chatLayout = await page.locator('.mia-chat-shell').evaluate((shell) => {
    const shellBox = shell.getBoundingClientRect()
    const conversationBox = shell.querySelector('.chat-card-wrap')?.getBoundingClientRect()
    const composerBox = shell.querySelector('.ask-row')?.getBoundingClientRect()
    return {
      shell: { x: shellBox.x, y: shellBox.y, width: shellBox.width, height: shellBox.height, bottom: shellBox.bottom },
      conversationHeight: conversationBox?.height ?? 0,
      composerBottom: composerBox?.bottom ?? Number.POSITIVE_INFINITY,
    }
  })
  const promptButtons = page.locator('.chat-prompts button')
  const promptWidths = await promptButtons.evaluateAll((buttons) => buttons.map((button) => button.getBoundingClientRect().width))
  expect(Math.max(...promptWidths)).toBeLessThanOrEqual(chatLayout.shell.width - 20)
  const contextBox = await page.locator('.mia-context').boundingBox()
  expect(chatLayout.conversationHeight).toBeGreaterThan(100)
  expect(chatLayout.composerBottom).toBeLessThanOrEqual(chatLayout.shell.bottom + 1)
  expect(contextBox).not.toBeNull()
  expect(chatLayout.shell.y).toBeLessThan(contextBox?.y ?? 0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('mobile Ask Mia prioritizes conversation and keeps full-screen chat above its backdrop', async ({ page }, testInfo) => {
  test.skip(!testInfo.project.name.includes('mobile'), 'mobile-only chat assertion')
  await page.goto('/#Ask%20Mia')
  await expect(page.getByRole('heading', { name: 'Ask Mia', exact: true })).toBeVisible()

  const suggestionsButton = page.getByRole('button', { name: 'Prompts', exact: true })
  const suggestedQuestion = page.getByRole('button', { name: 'Why is my readiness Red?' })
  await expect(suggestionsButton).toHaveAttribute('aria-expanded', 'false')
  await expect(suggestedQuestion).toBeHidden()

  const compactLayout = await page.locator('.mia-chat-shell').evaluate((shell) => {
    const history = shell.querySelector('.chat-card-wrap')?.getBoundingClientRect()
    const shellBox = shell.getBoundingClientRect()
    return {
      historyHeight: history?.height ?? 0,
      shellHeight: shellBox.height,
    }
  })
  expect(compactLayout.historyHeight).toBeGreaterThan(compactLayout.shellHeight * 0.6)

  await suggestionsButton.focus()
  await suggestionsButton.press('Enter')
  await expect(suggestionsButton).toHaveAttribute('aria-expanded', 'true')
  await expect(suggestedQuestion).toBeVisible()
  const historyWhileOpen = await page.locator('.chat-card-wrap').evaluate((history) => history.getBoundingClientRect().height)
  expect(historyWhileOpen).toBeCloseTo(compactLayout.historyHeight, 0)

  await page.keyboard.press('Escape')
  await expect(suggestionsButton).toHaveAttribute('aria-expanded', 'false')
  await expect(suggestionsButton).toBeFocused()
  await suggestionsButton.click()

  await page.getByRole('button', { name: 'My take-home pay is now $6,200 a month.' }).click()
  await expect(suggestionsButton).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toHaveValue('My take-home pay is now $6,200 a month.')
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeFocused()

  const expandButton = page.getByRole('button', { name: 'Expand Ask Mia chat' })
  await expandButton.focus()
  await expandButton.press('Enter')
  await expect(page.getByRole('dialog', { name: 'Ask Mia' })).toBeVisible()
  const expandedLayout = await page.locator('.mia-chat-shell').evaluate((shell) => {
    const box = shell.getBoundingClientRect()
    const topElement = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2)
    return {
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      shellOwnsViewportCenter: Boolean(topElement && shell.contains(topElement)),
      bodyOverflow: getComputedStyle(document.body).overflow,
    }
  })
  expect(expandedLayout.x).toBeCloseTo(0, 0)
  expect(expandedLayout.y).toBeCloseTo(0, 0)
  expect(expandedLayout.width).toBeCloseTo(expandedLayout.viewportWidth, 0)
  expect(expandedLayout.height).toBeCloseTo(expandedLayout.viewportHeight, 0)
  expect(expandedLayout.shellOwnsViewportCenter).toBe(true)
  expect(expandedLayout.bodyOverflow).toBe('hidden')

  await page.getByRole('link', { name: 'Home', exact: true }).focus()
  expect(await page.locator('.mia-chat-shell').evaluate((shell) => shell.contains(document.activeElement))).toBe(true)

  const sendButton = page.getByRole('button', { name: 'Send message' })
  await sendButton.focus()
  await page.keyboard.press('Tab')
  expect(await page.locator('.mia-chat-shell').evaluate((shell) => shell.contains(document.activeElement))).toBe(true)
  await expect(sendButton).not.toBeFocused()

  await page.keyboard.press('Escape')
  await expect(page.getByRole('button', { name: 'Expand Ask Mia chat' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Expand Ask Mia chat' })).toBeFocused()
})

test('expanded desktop Ask Mia blocks background interaction and restores its trigger', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop-only modal boundary assertion')
  await page.goto('/#Ask%20Mia')

  const expandButton = page.getByRole('button', { name: 'Expand Ask Mia chat' })
  await expandButton.click()
  await expect(page.getByRole('dialog', { name: 'Ask Mia' })).toBeVisible()

  const clearButton = page.getByRole('button', { name: 'Clear', exact: true })
  await clearButton.click()
  const clearDialog = page.getByRole('dialog', { name: 'Clear this chat?' })
  await expect(clearDialog).toBeVisible()
  await expect(clearDialog.getByRole('button', { name: 'Keep chat' })).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(clearDialog.getByRole('button', { name: 'Clear chat' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(clearDialog).toBeHidden()
  await expect(clearButton).toBeFocused()

  await clearButton.click()
  await clearDialog.getByRole('button', { name: 'Clear chat' }).click()
  await expect(clearDialog).toBeHidden()
  await expect(clearButton).toBeHidden()
  await expect(page.getByRole('textbox', { name: 'Ask Mia', exact: true })).toBeFocused()

  await page.getByRole('link', { name: 'Home', exact: true }).focus()
  expect(await page.locator('.mia-chat-shell').evaluate((shell) => shell.contains(document.activeElement))).toBe(true)

  await page.locator('.mia-chat-backdrop').click({ position: { x: 2, y: 2 } })
  await expect(page.getByRole('dialog', { name: 'Ask Mia' })).toBeHidden()
  await expect(expandButton).toBeFocused()
})

test('incomplete participants get a short first session, private feedback, and a recoverable power-user path', async ({ page }) => {
  const guidedSetupPrompt = 'Help me set up my household. Please ask me one simple question at a time.'
  const guidedSetupReply = 'What would you like to call this household?'
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() === 'POST') {
      return route.fulfill({
        status: 201,
        json: {
          user_message: { id: 801, role: 'user', author: 'You', content: guidedSetupPrompt, attachments: [], created_at: '2026-10-01T00:00:00Z' },
          assistant_message: { id: 802, role: 'assistant', author: 'Mia', content: guidedSetupReply, attachments: [], created_at: '2026-10-01T00:00:01Z' },
          transaction_draft: null,
          mia_action_draft: null,
        },
      })
    }

    return route.fulfill({
      status: 200,
      json: { messages: [], oldest_message_id: null, older_message_count: 0, has_older_messages: false, quick_prompts: [], disclaimer: 'Education only.' },
    })
  })
  await page.goto('/?pilot_e2e_role=participant')

  const firstSessionHeading = page.getByRole('heading', { name: 'Start with money in, money out.' })
  await firstSessionHeading.scrollIntoViewIfNeeded()
  await expect(firstSessionHeading).toBeVisible()
  if ((page.viewportSize()?.width ?? 1_000) <= 620) {
    const firstSessionColumns = await page.locator('.first-session-heading').evaluate((element) => getComputedStyle(element).gridTemplateColumns)
    expect(firstSessionColumns.split(' ')).toHaveLength(1)
  }
  await expect(page.getByRole('heading', { name: 'Give Mia a useful starting point.' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Guide', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Feedback', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Memory', exact: true })).toHaveCount(0)

  await page.getByRole('button', { name: 'Read the 3-minute guide' }).click()
  await expect(page.getByRole('heading', { name: 'A clear first Mia session in three moves.' })).toBeVisible()
  await expect(page.getByText(/pending drafts change nothing until you explicitly apply them/i)).toBeVisible()
  await expect(page.getByRole('dialog').getByRole('button', { name: 'Close' })).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(page.getByRole('heading', { name: 'A clear first Mia session in three moves.' })).not.toBeVisible()

  await page.getByRole('button', { name: 'Test a private upload' }).click()
  await expect(page.getByRole('heading', { name: 'Upload evidence. Review draft facts. Apply only what is right.' })).toBeVisible()
  await page.getByRole('link', { name: 'Home', exact: true }).click()

  await page.getByRole('button', { name: 'Feedback', exact: true }).click()
  const feedback = page.getByRole('dialog')
  await feedback.getByLabel('Screen or workflow').selectOption('setup')
  await feedback.getByLabel('What did you attempt?').fill('I tried to save the first session form.')
  await feedback.getByLabel('What did you expect?').fill('I expected to return to Home.')
  await feedback.getByLabel('What happened instead?').fill('The save button stayed busy.')
  await feedback.getByRole('button', { name: 'Submit report' }).click()
  await expect(feedback.getByText('Report received.')).toBeVisible()
  await expect(feedback).toContainText('were not sent to analytics')
  await feedback.getByRole('button', { name: 'Return to Household CFO' }).click()

  await page.getByRole('button', { name: 'Set up with Mia' }).click()
  await expect(page.getByRole('heading', { name: 'Tell Mia what changed.' })).toBeVisible()
  await expect(page.getByText('0 of 5 essentials confirmed')).toBeVisible()
  const guidedComposer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(guidedComposer).toHaveValue(guidedSetupPrompt)
  await expect(guidedComposer).toBeFocused()

  const guidedSetupRequestPromise = page.waitForRequest((request) => request.url().endsWith('/api/v1/mia/messages') && request.method() === 'POST')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  const guidedSetupRequest = await guidedSetupRequestPromise
  expect(guidedSetupRequest.postDataJSON().message).toBe(guidedSetupPrompt)
  await expect(page.getByText(guidedSetupReply, { exact: true })).toBeVisible()

  await page.getByRole('button', { name: 'Share everything at once' }).click()
  await expect(guidedComposer).toHaveValue(/Here is everything I know so far: our household is called ___/)
  await page.getByRole('button', { name: 'Ask me one question at a time' }).click()
  await expect(guidedComposer).toHaveValue(guidedSetupPrompt)

  await page.getByRole('button', { name: 'Enter manually' }).click()
  await expect(page.getByRole('heading', { name: 'Give Mia the basics for a useful first answer.' })).toBeVisible()
  await expect(page.getByText('Essential first-session information')).toBeVisible()
  await expect(page.locator('.setup-optional-fields')).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Upload evidence. Review draft facts. Apply only what is right.' })).toHaveCount(0)
  const incomeInput = page.getByLabel('Primary monthly income')
  await expect(incomeInput).toHaveValue('')
  await incomeInput.click()
  await incomeInput.press('7')
  await expect(incomeInput).toHaveValue('7')
  await incomeInput.fill('7200')
  await expect(incomeInput).toHaveValue('7200')
  const fixedExpensesInput = page.getByLabel('Fixed essentials')
  await fixedExpensesInput.fill('2500')
  await expect(fixedExpensesInput).toHaveValue('2500')
  const flexibleSpendingInput = page.getByLabel('Flexible spending')
  await flexibleSpendingInput.fill('600')
  await expect(flexibleSpendingInput).toHaveValue('600')
  const setupRequestPromise = page.waitForRequest((request) => request.url().endsWith('/api/v1/workspace/setup') && request.method() === 'PATCH')
  await page.getByRole('button', { name: 'Save and talk to Mia' }).click()
  const setupRequest = await setupRequestPromise
  expect(setupRequest.postDataJSON().workspace).toMatchObject({
    primary_income: 7200,
    fixed_expenses: 2500,
    flexible_spend: 600,
    business_income: 0,
  })
  await expect(page.locator('.shell-header')).toHaveCount(1)
  await expect(page.getByRole('heading', { name: 'Tell Mia what changed.' })).toBeVisible()
  const miaComposer = page.getByRole('textbox', { name: 'Ask Mia', exact: true })
  await expect(miaComposer).toHaveValue('Based on my income, spending, and goal, what should I focus on first this month?')
  await expect(miaComposer).toBeFocused()

  await openSection(page, 'My Profile')
  const advancedProfile = page.locator('.setup-optional-fields')
  await expect(advancedProfile).toHaveCount(1)
  expect(await advancedProfile.evaluate((element: HTMLDetailsElement) => element.open)).toBe(false)

  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('Mia explains when starting numbers have not been approved yet', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant#Ask%20Mia')

  const context = page.locator('.mia-context')
  await expect(context.getByRole('heading', { name: 'Build your starting picture with Mia' })).toBeVisible()
  await expect(context).toContainText('ordinary language')
  await expect(context.getByText('Approved data loaded')).toHaveCount(0)
  const progress = page.locator('.first-session-setup-progress')
  await expect(progress).toContainText('0 of 5 essentials confirmed')
  await expect(progress.getByText('Household name')).toBeVisible()
  await expect(progress.getByText('Flexible spending')).toBeVisible()
})

test('ignored-only imports remain pending instead of becoming approved Mia context', async ({ page }) => {
  const ignoredImport = {
    id: 404,
    household_id: 77,
    document_kind: 'statement',
    status: 'applied',
    filename: 'ignored-statement.pdf',
    content_type: 'application/pdf',
    byte_size: 100,
    document_date: `${currentYear}-08-01`,
    period_start_on: `${currentYear}-08-01`,
    period_end_on: `${currentYear}-08-31`,
    extracted_summary: 'One transaction was extracted and ignored.',
    extraction_error: null,
    processed_at: `${currentYear}-08-16T01:00:00Z`,
    applied_at: `${currentYear}-08-16T01:05:00Z`,
    source_deleted_at: null,
    updated_at: `${currentYear}-08-16T01:05:00Z`,
    source_available: true,
    details_included: false,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {},
    items: [],
    transaction_drafts: [{
      id: 405,
      occurred_on: `${currentYear}-08-05`,
      merchant: 'Ignored purchase',
      amount: 20,
      status: 'ignored',
      category_id: null,
      category_name: null,
    }],
    attempts: [],
  }
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/document_imports', (route) => route.fulfill({ status: 200, json: { document_imports: [ignoredImport] } }))
  await page.goto('/?pilot_e2e_role=participant')

  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await expect(page.getByText('No approved document sources yet. Mia will use manual numbers until you apply extracted values.')).toBeVisible()

  await openSection(page, 'My Profile')
  await expect(page.getByText('Approved source', { exact: true }).locator('..')).toContainText('Not approved yet')
  await expect(page.getByText('Freshness', { exact: true }).locator('..')).toContainText('Review pending')
})

test('PDF document preview keeps keyboard focus inside accessible controls', async ({ page }) => {
  const pdfImport = {
    id: 606,
    household_id: 77,
    document_kind: 'statement',
    status: 'needs_review',
    filename: 'checking-statement.pdf',
    content_type: 'application/pdf',
    byte_size: 48_000,
    document_date: `${currentYear}-08-01`,
    period_start_on: `${currentYear}-08-01`,
    period_end_on: `${currentYear}-08-31`,
    extracted_summary: 'Mia found a statement ready for review.',
    extraction_error: null,
    processed_at: `${currentYear}-08-16T01:00:00Z`,
    applied_at: null,
    source_deleted_at: null,
    updated_at: `${currentYear}-08-16T01:00:00Z`,
    source_available: true,
    details_included: true,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {},
    items: [],
    transaction_drafts: [],
    attempts: [],
  }
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/document_imports', (route) => route.fulfill({ status: 200, json: { document_imports: [pdfImport] } }))
  await page.route('http://api.test/api/v1/document_imports/606/source_url', (route) => route.fulfill({
    status: 200,
    json: {
      url: 'https://signed.example/checking-statement.pdf',
      download_url: 'https://signed.example/checking-statement-download.pdf',
      expires_in: 300,
      filename: pdfImport.filename,
      content_type: pdfImport.content_type,
      inline_supported: true,
    },
  }))

  await page.goto('/?pilot_e2e_role=participant#My%20Profile')
  const opener = page.getByRole('button', { name: 'Preview original' })
  await opener.focus()
  await page.keyboard.press('Enter')

  const dialog = page.getByRole('dialog', { name: 'Preview checking-statement.pdf' })
  const downloadLink = dialog.getByRole('link', { name: 'Download source' })
  const closeButton = dialog.getByRole('button', { name: 'Close', exact: true })
  const openPdfLink = dialog.getByRole('link', { name: 'Open PDF in new tab' })
  await expect(dialog).toBeVisible()
  await expect(dialog.locator('iframe')).toHaveCount(0)
  await expect(openPdfLink).toHaveAttribute('href', 'https://signed.example/checking-statement.pdf')
  await expect(closeButton).toBeVisible()
  await expect.poll(() => dialog.evaluate((element) => element.contains(document.activeElement))).toBe(true)

  await openPdfLink.focus()
  await page.keyboard.press('Tab')
  await expect(downloadLink).toBeFocused()
  await page.keyboard.press('Shift+Tab')
  await expect(openPdfLink).toBeFocused()
  await page.keyboard.press('Escape')
  await expect(dialog).toHaveCount(0)
  await expect(opener).toBeFocused()
})

test('import review copy follows extracted results when a selected receipt produces household values', async ({ page }) => {
  const householdValueImport = {
    id: 505,
    household_id: 77,
    document_kind: 'receipt',
    status: 'needs_review',
    filename: 'profile-screenshot.png',
    content_type: 'image/png',
    byte_size: 24_000,
    document_date: null,
    period_start_on: null,
    period_end_on: null,
    extracted_summary: 'Mia found one household setup value.',
    extraction_error: null,
    processed_at: `${currentYear}-08-16T01:00:00Z`,
    applied_at: null,
    source_deleted_at: null,
    updated_at: `${currentYear}-08-16T01:00:00Z`,
    source_available: true,
    details_included: true,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {
      declared_document_kind: 'receipt',
      document_kind_explicit: true,
      routing_resolved_kind: 'receipt',
      routing_source: 'participant_selection',
      routing_destination: 'transaction_review',
    },
    items: [{
      id: 506,
      target_type: 'expense_item',
      label: 'Fixed essentials',
      amount: 3_100,
      amount_cents: 310_000,
      balance: null,
      balance_cents: null,
      payment: null,
      payment_cents: null,
      cadence: 'monthly',
      source_type: null,
      stack_key: 'non_discretionary',
      account_type: null,
      debt_type: null,
      confidence: 'high',
      evidence: 'Profile screenshot',
      selected: true,
      ignored: false,
      applied_at: null,
      applied_record_type: null,
      applied_record_id: null,
      metadata: {},
    }],
    transaction_drafts: [],
    attempts: [],
  }
  let activeImport: unknown = householdValueImport
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: realWorkspaceData(true) }))
  await page.route('http://api.test/api/v1/document_imports', (route) => route.fulfill({ status: 200, json: { document_imports: [activeImport] } }))
  await page.route('http://api.test/api/v1/document_imports/505', (route) => route.fulfill({ status: 200, json: { document_import: activeImport } }))
  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')

  const result = page.locator('.document-routing-summary')
  await expect(result).toContainText('Review result')
  await expect(result).toContainText('1 household value → Household setup review')
  await expect(result).toContainText('You selected receipt/photo.')
  await expect(result).toContainText('sent the reviewable results she actually found to household setup review')
  await expect(result).toContainText('Nothing changed until you approve it.')
  await expect(result).not.toContainText('Mia honored the document type')

  activeImport = {
    ...householdValueImport,
    status: 'applied',
    applied_at: `${currentYear}-08-16T01:05:00Z`,
    items: householdValueImport.items.map((item) => ({ ...item, applied_at: `${currentYear}-08-16T01:05:00Z` })),
  }
  await page.reload()
  const resolvedResult = page.locator('.document-routing-summary')
  await expect(resolvedResult).toContainText('Review complete → Private import history')
  await expect(resolvedResult).toContainText('All extracted results are resolved.')
  await expect(resolvedResult).not.toContainText('Nothing changed until you approve it.')
})

test('admin cohort rows show only safe pilot progress signals', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=admin')
  await openSection(page, 'Admin')

  const inviteForm = page.locator('.admin-form').filter({ has: page.getByLabel('Email') }).first()
  await expect(inviteForm.getByLabel('First name')).toHaveCount(0)
  await expect(inviteForm.getByLabel('Last name')).toHaveCount(0)
  await expect(inviteForm.getByText("Names come from the invited person's Clerk account after first sign-in.")).toBeVisible()

  await expect(page.getByText('Setup started', { exact: true })).toBeVisible()
  await expect(page.getByText('Signed in', { exact: true })).toBeVisible()
  await expect(page.getByText('Review waiting', { exact: true })).toBeVisible()
  await expect(page.getByText(/Last safe activity:/)).toBeVisible()
  const operations = page.locator('.admin-operations')
  await expect(operations).toContainText('Active participants1')
  await expect(operations).toContainText('Mia requests18')
  await expect(operations).toContainText('Typical Mia time0.8s')
  await expect(page.getByText('aggregate operational activity only', { exact: false })).toBeVisible()
  const participantRow = page.locator('.admin-user-row').filter({ hasText: 'participant@pilot.test' })
  await expect(participantRow.getByText(/profile completeness/i)).toHaveCount(0)
  await expect(participantRow.getByText(/readiness/i)).toHaveCount(0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('Coach Studio preserves coach-authored community context through preview, publish, and assignment', async ({ page }) => {
  let initialWorkspaceAuthorization = ''
  await page.route('http://api.test/api/v1/workspace', async (route) => {
    initialWorkspaceAuthorization = route.request().headers().authorization ?? ''
    await route.fallback()
  })
  await page.goto('/?pilot_e2e_role=admin')
  await openSection(page, 'Coach Studio')

  expect(initialWorkspaceAuthorization).toBe('Bearer test_token:e2e_admin:admin@pilot.test:Pilot:Admin')
  await expect(page).toHaveURL(/#Coach%20Studio$/)
  await expect(page.getByRole('heading', { name: 'Shape a coaching assistant people can trust.' })).toBeFocused()
  await expect(page.getByText('Always a digital assistant.')).toBeVisible()

  const identityTab = page.getByRole('tab', { name: /Identity/ })
  await identityTab.focus()
  await identityTab.press('ArrowRight')
  await expect(page.getByRole('tab', { name: /Voice/ })).toBeFocused()
  await expect(page.locator('#coach-step-panel-voice')).toHaveAttribute('aria-labelledby', 'coach-step-tab-voice')
  await page.getByRole('tab', { name: /Community/ }).click()
  await expect(page.getByText('Coach authored only.')).toBeVisible()
  await page.getByLabel('Locale label').fill("Guam families in Mrs. Mel's first cohort")
  const localRealities = page.getByLabel('Local realities')
  await localRealities.fill('')
  await localRealities.pressSequentially('Higher shipping costs')
  await localRealities.press('Enter')
  await localRealities.pressSequentially('Multigenerational household support')
  await expect(localRealities).toHaveValue('Higher shipping costs\nMultigenerational household support')
  await expect(page.getByText('No phrases added. Locale alone will never create them.')).toBeVisible()
  await page.getByRole('button', { name: 'Add phrase' }).click()
  const phraseInput = page.getByLabel('Phrase', { exact: true })
  await phraseInput.fill('')
  await phraseInput.pressSequentially('Pause, name the number, then choose.')
  await expect(phraseInput).toBeFocused()
  await expect(phraseInput).toHaveValue('Pause, name the number, then choose.')

  await page.getByRole('button', { name: /Advanced settings/ }).click()
  await page.getByText('Community', { exact: true }).click()
  await expect(page.getByLabel('Locale label')).toHaveValue("Guam families in Mrs. Mel's first cohort")
  await page.getByRole('button', { name: /Guided setup/ }).click()
  await expect(page.getByLabel('Locale label')).toHaveValue("Guam families in Mrs. Mel's first cohort")
  await page.getByRole('tab', { name: /Teaching & response/ }).click()
  await expect(page.getByLabel('Require one next move')).toHaveCount(0)
  await expect(page.getByText('Fact validation and one concrete next move are always on.')).toBeVisible()

  await page.getByRole('button', { name: 'Save draft' }).click()
  await expect(page.getByRole('status')).toContainText('Draft saved')
  await page.getByRole('button', { name: 'Run exact preview' }).click()

  const preview = page.getByRole('region', { name: 'Exact draft preview' })
  await expect(preview).toContainText('Behavioral sample ready')
  await expect(preview).toContainText('Live Model')
  await expect(preview).toContainText('Guardrails applied: Yes')
  await page.getByText('Locked system guardrails').click()
  await expect(page.getByText('Do not imitate accents or invent cultural stereotypes.')).toBeVisible()

  await page.getByRole('button', { name: 'Publish first version' }).click()
  await expect(page.getByRole('status')).toContainText('version 1 is published')

  const activeCohort = page.locator('.coach-cohort-list article').filter({ hasText: 'Household CFO pilot' })
  await activeCohort.getByRole('button', { name: 'Assign', exact: true }).click()
  await expect(activeCohort).toContainText('Coach Lani assigned')
  await expect(page.getByText('1 visible assignment')).toBeVisible()
  await expect(page.locator('.coach-library-list')).toContainText('1 cohort assignment')
  await expect(page.getByText('Remove this assistant from every draft, enrolling, or active cohort before archiving.')).toBeVisible()

  const completedCohort = page.locator('.coach-cohort-list article').filter({ hasText: 'Completed cohort' })
  await expect(completedCohort.getByRole('button', { name: 'Assign', exact: true })).toBeDisabled()
  await expect(completedCohort).toContainText('Completed and archived cohorts are read-only.')

  page.once('dialog', (dialog) => dialog.accept())
  await activeCohort.getByRole('button', { name: 'Remove', exact: true }).click()
  await expect(activeCohort).toContainText('Neutral product voice')
  await expect(page.locator('.coach-library-list')).toContainText('0 cohort assignments')

  page.once('dialog', (dialog) => dialog.accept())
  await page.getByRole('button', { name: 'Archive assistant', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Restore assistant', exact: true })).toBeVisible()
  await expect(page.getByText('This assistant is read-only for your account or while archived.')).toBeVisible()

  await page.getByRole('button', { name: 'Restore assistant', exact: true }).click()
  await expect(page.getByText('restored as an editable draft')).toBeVisible()

  await page.getByRole('tab', { name: /Identity/ }).click()
  await page.getByLabel('Assistant name').fill('Coach Lani Next')
  await page.getByRole('button', { name: 'Save draft' }).click()
  await page.getByRole('button', { name: 'Run exact preview' }).click()
  await page.getByRole('button', { name: 'Publish next version' }).click()
  await expect(page.getByRole('status')).toContainText('version 2 is published')

  await page.getByText('Version history (2)').click()
  const versionOne = page.locator('.coach-version-list article').filter({ hasText: 'Version 1' })
  page.once('dialog', (dialog) => dialog.accept())
  await versionOne.getByRole('button', { name: 'Restore as new version' }).click()
  await expect(page.getByRole('status')).toContainText('Version 3 is now published from version 1')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('Coach Studio participant tools preview publish and restore the exact cohort navigation', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByRole('tab', { name: /Participant tools/ }).click()

  await expect(page.getByRole('heading', { name: 'Choose what participants can open.' })).toBeVisible()
  await expect(page.getByText('Always on')).toHaveCount(6)
  await expect(page.getByLabel('Include CFO Filter')).toBeChecked()
  await expect(page.getByLabel('Include Optionality')).toBeChecked()

  await page.getByLabel('Include CFO Filter').uncheck()
  await page.getByRole('button', { name: 'Save draft' }).click()
  await expect(page.getByRole('status')).toContainText('draft saved')
  await page.getByRole('button', { name: 'Preview navigation' }).click()

  const preview = page.getByRole('region', { name: 'Exact participant navigation preview' })
  await expect(preview.getByRole('navigation', { name: 'Desktop preview' })).toContainText('Optionality')
  await expect(preview).toContainText('Not included: CFO Filter')

  page.once('dialog', async (dialog) => {
    expect(dialog.message()).toContain('1 participant in Household CFO pilot')
    await dialog.accept()
  })
  await page.getByRole('button', { name: 'Publish to cohort' }).click()
  await expect(page.getByRole('status')).toContainText('version 1 is published')

  await page.getByLabel('Include CFO Filter').check()
  await page.getByRole('button', { name: 'Save draft' }).click()
  await page.getByRole('button', { name: 'Preview navigation' }).click()
  page.once('dialog', (dialog) => dialog.accept())
  await page.getByRole('button', { name: 'Publish to cohort' }).click()
  await expect(page.getByRole('status')).toContainText('version 2 is published')

  await page.getByText('Version history (2)').click()
  const versionOne = page.locator('.coach-version-list article').filter({ hasText: 'Version 1' })
  page.once('dialog', (dialog) => dialog.accept())
  await versionOne.getByRole('button', { name: 'Restore as new version' }).click()
  await expect(page.getByRole('status')).toContainText('Version 1 was restored as version 3')
  await expect(page.getByLabel('Include CFO Filter')).not.toBeChecked()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('Coach Studio shows participant cohorts loading before an empty state', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chrome', 'loading-state regression')
  let releaseCohorts: (() => void) | undefined
  const cohortsGate = new Promise<void>((resolve) => { releaseCohorts = resolve })
  await page.route('http://api.test/api/v1/admin/personas/assignable_cohorts', async (route) => {
    await cohortsGate
    return route.fulfill({
      status: 200,
      json: { cohorts: [{ id: 41, name: 'Household CFO pilot', status: 'active', assignable: true, blocked_reason: null, persona_assignment: null }] },
    })
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByRole('tab', { name: /Participant tools/ }).click()

  await expect(page.getByRole('status').filter({ hasText: 'Loading manageable cohorts…' })).toBeVisible()
  await expect(page.getByText('No manageable cohorts yet.')).toHaveCount(0)
  releaseCohorts?.()
  await expect(page.getByRole('heading', { name: 'Choose what participants can open.' })).toBeVisible()
})

test('Coach Studio ignores a delayed participant-tool response after switching cohorts', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chrome', 'request ordering regression')
  const secondCohort = {
    id: 43, name: 'Second active cohort', status: 'active', assignable: true, blocked_reason: null, persona_assignment: null,
  }
  let releaseSecondLoad: (() => void) | undefined
  const secondLoadGate = new Promise<void>((resolve) => { releaseSecondLoad = resolve })
  const savePaths: string[] = []

  await page.route('http://api.test/api/v1/admin/personas/assignable_cohorts', (route) => route.fulfill({
    status: 200,
    json: { cohorts: [
      { id: 41, name: 'Household CFO pilot', status: 'active', assignable: true, blocked_reason: null, persona_assignment: null },
      secondCohort,
    ] },
  }))
  await page.route('http://api.test/api/v1/admin/cohorts/43/experience_configuration', async (route) => {
    await secondLoadGate
    return route.fulfill({
      status: 200,
      json: {
        experience_configuration: {
          cohort: { id: 43, name: secondCohort.name, status: 'active', participant_count: 4 },
          draft: { schema_version: 1, optional_modules: { cfo_filter: false, optionality: false } },
          draft_revision: 1,
          preview_required: true,
          preview: null,
          published_version: null,
          versions: [],
          permissions: { edit: true, publish: true, rollback: true },
        },
      },
    })
  })
  page.on('request', (request) => {
    if (request.method() === 'PATCH' && request.url().includes('/experience_configuration')) savePaths.push(new URL(request.url()).pathname)
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByRole('tab', { name: /Participant tools/ }).click()
  const cohortSelect = page.getByRole('combobox', { name: 'Cohort' })
  await expect(cohortSelect).toHaveValue('41')
  await expect(page.getByLabel('Include CFO Filter')).toBeChecked()

  await cohortSelect.selectOption('43')
  await expect(page.getByText('Loading participant tools…')).toBeVisible()
  await expect(page.getByLabel('Include CFO Filter')).toHaveCount(0)
  await cohortSelect.selectOption('41')
  await expect(page.getByLabel('Include CFO Filter')).toBeChecked()

  releaseSecondLoad?.()
  await page.waitForTimeout(100)
  await expect(cohortSelect).toHaveValue('41')
  await expect(page.getByLabel('Include CFO Filter')).toBeChecked()

  await page.getByLabel('Include Optionality').uncheck()
  await page.getByRole('button', { name: 'Save draft' }).click()
  await expect(page.getByRole('status')).toContainText('draft saved')
  expect(savePaths).toEqual(['/api/v1/admin/cohorts/41/experience_configuration'])
})

test('Coach Studio clears the prior cohort after a participant-tool load fails', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chrome', 'failed selection regression')
  await page.route('http://api.test/api/v1/admin/personas/assignable_cohorts', (route) => route.fulfill({
    status: 200,
    json: { cohorts: [
      { id: 41, name: 'Household CFO pilot', status: 'active', assignable: true, blocked_reason: null, persona_assignment: null },
      { id: 43, name: 'Unavailable cohort', status: 'active', assignable: true, blocked_reason: null, persona_assignment: null },
    ] },
  }))
  await page.route('http://api.test/api/v1/admin/cohorts/43/experience_configuration', (route) => route.fulfill({
    status: 503,
    json: { error: 'Participant tools are temporarily unavailable.' },
  }))

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByRole('tab', { name: /Participant tools/ }).click()
  const cohortSelect = page.getByRole('combobox', { name: 'Cohort' })
  await expect(page.getByLabel('Include CFO Filter')).toBeChecked()

  await cohortSelect.selectOption('43')

  await expect(page.getByRole('alert')).toContainText('temporarily unavailable')
  await expect(cohortSelect).toHaveValue('43')
  await expect(page.getByLabel('Include CFO Filter')).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Save draft' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Publish to cohort' })).toHaveCount(0)

  await cohortSelect.selectOption('41')
  await expect(page.getByLabel('Include CFO Filter')).toBeChecked()
})

test('participant navigation remains available when a saved optional-tool link is disabled', async ({ page }) => {
  const workspace = realWorkspaceData(true)
  workspace.workspace.capabilities = experienceCapabilities({ cfo_filter: false, optionality: true })
  delete workspace.cfoFilter
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: workspace }))

  await page.goto('/?pilot_e2e_role=participant#CFO%20Filter')

  await expect(page).toHaveURL(/#Home$/)
  const notice = page.getByRole('status').filter({ hasText: 'CFO Filter is not included in this cohort right now.' })
  await expect(notice).toBeVisible()
  await expect(notice).toBeFocused()
  await expect(page.locator('.cfo-screen')).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()

  const tools = page.getByRole('button', { name: 'Tools', exact: true })
  await tools.click()
  await expect(page.getByRole('link', { name: 'CFO Filter', exact: true })).toHaveCount(0)
  await expect(page.getByRole('link', { name: 'Optionality', exact: true })).toBeVisible()
  await expect(page.getByRole('link', { name: 'My Profile', exact: true })).toBeVisible()
  await expect(page.getByRole('link', { name: 'Wealth', exact: true })).toBeVisible()
  await page.getByRole('link', { name: 'Optionality', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Can I leave my job?' })).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('participant navigation keeps a disabled deep link canonical after capabilities refresh', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chrome', 'capability refresh state regression')
  const disabledWorkspace = realWorkspaceData(true)
  disabledWorkspace.workspace.capabilities = experienceCapabilities({ cfo_filter: false, optionality: true })
  delete disabledWorkspace.cfoFilter
  const enabledWorkspace = realWorkspaceData(true)
  let workspaceRequests = 0
  let releaseRefresh: (() => void) | undefined
  const refreshGate = new Promise<void>((resolve) => { releaseRefresh = resolve })

  await page.route('http://api.test/api/v1/workspace', async (route) => {
    workspaceRequests += 1
    if (workspaceRequests === 1) return route.fulfill({ status: 200, json: disabledWorkspace })
    await refreshGate
    return route.fulfill({ status: 200, json: enabledWorkspace })
  })
  await page.route('http://api.test/api/v1/document_imports', (route) => route.fulfill({
    status: 200,
    json: {
      document_imports: [{
        id: 990, household_id: 77, document_kind: 'receipt', status: 'needs_review', filename: 'refresh-trigger.png',
        content_type: 'image/png', byte_size: 20, document_date: null, period_start_on: null, period_end_on: null,
        extracted_summary: null, extraction_error: null, processed_at: null, applied_at: null, source_deleted_at: null,
        updated_at: '2026-10-01T00:00:00Z', source_available: true, details_included: false, uploaded_by: null,
        applied_by: null, source_deleted_by: null, metadata: {}, items: [], attempts: [],
        transaction_drafts: [{ id: 991, status: 'pending', amount_cents: 2_000, amount: 20 }],
      }],
    },
  }))

  await page.goto('/?pilot_e2e_role=participant#CFO%20Filter')

  await expect(page).toHaveURL(/#Home$/)
  await expect(page.getByRole('status').filter({ hasText: 'CFO Filter is not included' })).toBeFocused()
  await expect.poll(() => workspaceRequests).toBeGreaterThan(1)
  releaseRefresh?.()
  await expect(page.getByRole('status').filter({ hasText: 'CFO Filter is not included' })).toHaveCount(0)
  await page.getByRole('button', { name: 'Tools', exact: true }).click()
  await expect(page.getByRole('link', { name: 'CFO Filter', exact: true })).toBeVisible()
  await expect(page).toHaveURL(/#Home$/)
  await expect(page.getByRole('heading', { name: 'CFO snapshot' })).toBeVisible()
  await expect(page.locator('.cfo-screen')).toHaveCount(0)
})

test('Coach Studio builds and pins an exact coach-approved content pack', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByRole('tab', { name: /Coaching Library/ }).click()
  await expect(page.getByRole('heading', { name: 'Build reusable coaching material' })).toBeVisible()
  await expect(page.getByText('Location labels never create slang, accents, or cultural assumptions.')).toBeVisible()

  await page.getByRole('button', { name: 'New item' }).click()
  const itemPanel = page.locator('.coach-content-panel').filter({ has: page.getByRole('heading', { name: 'Coach-authored building blocks' }) })
  await itemPanel.getByLabel('Title').fill('Guam family context')
  await itemPanel.getByLabel('Type').selectOption('culture')
  await itemPanel.getByLabel('Draft wording').fill('Mention extended-family obligations only after the participant raises them.')
  await itemPanel.getByRole('button', { name: 'Create draft' }).click()
  await expect(page.getByRole('status')).toContainText('Content draft created')
  await itemPanel.getByLabel('Title').fill('  Guam   family   context  ')
  await expect(itemPanel.getByRole('button', { name: 'Save draft', exact: true })).toBeDisabled()
  await itemPanel.getByLabel('Draft wording').fill('Mention extended-family obligations only when the participant raises them.')
  await expect(itemPanel.getByRole('button', { name: 'Save draft before approving' })).toBeDisabled()
  page.once('dialog', async (dialog) => {
    expect(dialog.message()).toContain('Discard unsaved Coach Studio changes')
    await dialog.dismiss()
  })
  await page.getByRole('tab', { name: /Assistant voice/ }).click()
  await expect(itemPanel.getByLabel('Draft wording')).toHaveValue('Mention extended-family obligations only when the participant raises them.')
  await itemPanel.getByRole('button', { name: 'Save draft', exact: true }).click()
  await expect(page.getByRole('status')).toContainText('Content draft saved')
  await itemPanel.getByRole('button', { name: 'Approve new version' }).click()
  await expect(page.getByRole('status')).toContainText('immutable version')

  await page.getByRole('button', { name: 'New pack' }).click()
  const packPanel = page.locator('.coach-content-panel').filter({ has: page.getByRole('heading', { name: 'Publish a reusable collection' }) })
  await packPanel.getByLabel('Pack name').fill('Mrs. Mel Guam context')
  await packPanel.getByLabel('Purpose').selectOption('voice_culture')
  await packPanel.getByLabel(/Guam family context/).check()
  await packPanel.getByRole('button', { name: 'Create pack draft' }).click()
  await expect(page.getByRole('status')).toContainText('Content pack draft created')
  await packPanel.getByLabel('Pack name').fill('  Mrs.   Mel Guam   context  ')
  await expect(packPanel.getByRole('button', { name: 'Save pack', exact: true })).toBeDisabled()
  await packPanel.getByLabel('Description').fill('Reviewed Guam family context for participant-led conversations.')
  await expect(packPanel.getByRole('button', { name: 'Save pack before publishing' })).toBeDisabled()
  await packPanel.getByRole('button', { name: 'Save pack', exact: true }).click()
  await expect(page.getByRole('status')).toContainText('Pack draft saved')
  await packPanel.getByRole('button', { name: 'Publish exact version' }).click()
  await expect(page.getByRole('status')).toContainText('immutable version')

  await page.getByRole('tab', { name: /Assistant voice/ }).click()
  const sourcePanel = page.locator('.persona-content-packs')
  await sourcePanel.getByLabel(/Mrs. Mel Guam context/).check()
  await sourcePanel.getByRole('button', { name: 'Save source selection' }).click()
  await expect(page.getByRole('status')).toContainText('fresh preview')
  await expect(sourcePanel).toContainText('v1')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('Coach Studio keeps private source candidates reviewable and mobile-safe before publication', async ({ page }) => {
  const candidateBase = {
    source_id: 701, status: 'proposed', kind: 'guidance', topics: ['planning'], safety_code: null,
    accepted_content_item_id: null, reviewed_at: null, updated_at: '2026-10-01T01:00:00Z',
  }
  const candidates = [
    {
      ...candidateBase, id: 711, position: 0, title: 'One calm next step', content: 'Choose one practical next step and review it together.',
      revision: 1, digest: 'candidate-one', evidence_excerpt: '<script>quoted source text stays inert</script>',
      evidence_locator: { type: 'text', segment: 1, line_start: 2, line_end: 3, excerpt_digest: 'a'.repeat(64) },
    },
    {
      ...candidateBase, id: 712, position: 1, title: 'Protect the baseline', content: 'Protect the household baseline before optional spending.',
      revision: 1, digest: 'candidate-two', evidence_excerpt: 'Protect the baseline.',
      evidence_locator: { type: 'text', segment: 1, line_start: 5, line_end: 5, excerpt_digest: 'b'.repeat(64) },
    },
  ]
  const source = () => ({
    id: 701, scope: 'coach', filename: `${'long-private-filename-'.repeat(6)}guide.txt`, content_type: 'text/plain', byte_size: 4800,
    checksum_sha256: 'c'.repeat(64), status: 'needs_review', generation: 1, source_available: true, error: null, error_code: null,
    source_delete_error_code: null, processing_metadata: { format: 'text', candidate_count: 2 }, processed_at: '2026-10-01T01:00:00Z',
    source_deleted_at: null, created_at: '2026-10-01T00:59:00Z', updated_at: '2026-10-01T01:00:00Z',
    current_attempt: { id: 702, generation: 1, status: 'succeeded', error: null, error_code: null }, candidates,
  })
  const uploadedSource = {
    id: 720, scope: 'coach', filename: 'new-guide.txt', content_type: 'text/plain', byte_size: 32,
    checksum_sha256: 'e'.repeat(64), status: 'queued', generation: 0, source_available: true, error: null, error_code: null,
    source_delete_error_code: null, processing_metadata: {}, processed_at: null, source_deleted_at: null,
    created_at: '2026-10-01T01:02:00Z', updated_at: '2026-10-01T01:02:00Z', current_attempt: null, candidates: [],
  }
  let acceptedItem: MockContentItem | null = null

  let releaseSourceList!: () => void
  const sourceListGate = new Promise<void>((resolve) => { releaseSourceList = resolve })
  await page.route('http://api.test/api/v1/admin/content_sources', async (route) => {
    await sourceListGate
    return route.fulfill({ status: 200, json: { sources: [source()] } })
  })
  await page.route('http://api.test/api/v1/admin/content_sources/701', async (route) => {
    if (route.request().method() === 'GET') return route.fulfill({ status: 200, json: { source: source() } })
    return route.fallback()
  })
  await page.route('http://api.test/api/v1/admin/content_sources/presign', (route) => route.fulfill({
    status: 200,
    json: { upload_url: 'http://storage.test/new-guide', upload_headers: { 'x-amz-server-side-encryption': 'AES256' }, upload_token: 'new-guide-token' },
  }))
  await page.route('http://storage.test/new-guide', (route) => route.fulfill({ status: 200, body: '' }))
  await page.route('http://api.test/api/v1/admin/content_sources/complete', (route) => route.fulfill({ status: 201, json: { source: uploadedSource } }))
  await page.route(/http:\/\/api\.test\/api\/v1\/admin\/content_sources\/701\/candidates\/\d+(?:\/accept)?$/, async (route) => {
    const id = Number(new URL(route.request().url()).pathname.match(/candidates\/(\d+)/)?.[1])
    const index = candidates.findIndex((candidate) => candidate.id === id)
    const input = route.request().postDataJSON().candidate
    if (route.request().url().endsWith('/accept')) {
      candidates[index] = { ...candidates[index], status: 'accepted', accepted_content_item_id: 801 }
      acceptedItem = {
        id: 801, title: candidates[index].title, scope: 'coach', kind: candidates[index].kind, always_on: false,
        draft_content: candidates[index].content, draft_revision: 1, draft_digest: 'draft-item-digest', archived: false, editable: true,
        current_approved_version: null, versions: [], has_unapproved_changes: true, updated_at: '2026-10-01T01:05:00Z',
      }
      return route.fulfill({ status: 200, json: { candidate: candidates[index], item: acceptedItem } })
    }
    candidates[index] = { ...candidates[index], ...input, revision: candidates[index].revision + 1, digest: 'candidate-saved' }
    return route.fulfill({ status: 200, json: { candidate: candidates[index] } })
  })
  await page.route('http://api.test/api/v1/admin/content_items', (route) => route.fulfill({ status: 200, json: { items: acceptedItem ? [acceptedItem] : [] } }))
  await page.route('http://api.test/api/v1/admin/content_items/801', (route) => route.fulfill({ status: 503, json: { error: 'Temporary content save failure.' } }))

  await page.goto('/?pilot_e2e_role=coach#Coach%20Studio')
  await page.getByRole('tab', { name: /Coaching Library/ }).click()
  await expect(page.getByRole('heading', { name: 'Turn private material into reviewable drafts' })).toBeVisible()
  await expect(page.getByLabel('Private source file')).toBeDisabled()
  releaseSourceList()
  await expect(page.getByLabel('Private source file')).toBeEnabled()
  await expect(page.getByText(/no-data-collection routing setting/i)).toBeVisible()
  await expect(page.getByText('Private source → Review candidates')).toHaveCount(0)
  await expect(page.locator('.coach-source-trust li')).toHaveCount(6)
  await page.getByRole('button', { name: /long-private-filename/ }).click()
  await page.getByRole('button', { name: /One calm next step/ }).click()

  if ((page.viewportSize()?.width ?? 1_000) <= 390) {
    const touchTargets = [
      page.getByRole('button', { name: 'Delete source' }),
      page.getByRole('button', { name: 'New item' }),
      page.getByRole('button', { name: 'New pack' }),
    ]
    for (const target of touchTargets) {
      const height = await target.evaluate((element) => element.getBoundingClientRect().height)
      expect(height).toBeGreaterThanOrEqual(44)
    }
  }

  const editor = page.locator('.coach-candidate-editor')
  await expect(editor.getByText('<script>quoted source text stays inert</script>', { exact: true })).toBeVisible()
  await editor.getByLabel('Draft wording').fill('Choose one calm, practical next step and review it together.')
  await page.getByLabel('Private source file').setInputFiles({ name: 'new-guide.txt', mimeType: 'text/plain', buffer: Buffer.from('A separate private coaching source.') })
  await page.getByRole('button', { name: 'Upload and read' }).click()
  await expect(page.getByRole('status')).toContainText('Private upload complete')
  await expect(page.getByRole('button', { name: /new-guide.txt/ })).toBeVisible()
  await expect(editor.getByLabel('Draft wording')).toHaveValue('Choose one calm, practical next step and review it together.')
  await expect(page.getByRole('button', { name: /One calm next step/ })).toHaveAttribute('aria-current', 'true')
  await page.getByRole('button', { name: /Protect the baseline/ }).click()
  await expect(page.getByRole('alert')).toContainText('unsaved candidate edits')
  await page.getByRole('button', { name: 'Keep editing' }).click()
  await expect(editor.getByLabel('Draft wording')).toHaveValue('Choose one calm, practical next step and review it together.')

  const itemPanel = page.locator('.coach-content-panel').filter({ has: page.getByRole('heading', { name: 'Coach-authored building blocks' }) })
  await itemPanel.getByRole('button', { name: 'New item' }).click()
  await itemPanel.getByLabel('Title').fill('Unsaved manual lesson')
  await itemPanel.getByLabel('Draft wording').fill('Keep this exact unsaved manual wording.')
  if ((page.viewportSize()?.width ?? 1_000) <= 390) {
    const alwaysOn = itemPanel.getByLabel(/Supply for every question/)
    const tapLabel = alwaysOn.locator('xpath=ancestor::label')
    expect(await tapLabel.evaluate((element) => element.getBoundingClientRect().height)).toBeGreaterThanOrEqual(44)
    await tapLabel.getByText('Supply for every question').click()
    await expect(alwaysOn).toBeChecked()
  }

  await editor.getByRole('button', { name: 'Save and create draft' }).click()
  await expect(page.getByRole('status')).toContainText('not available to Mia yet')
  await page.getByRole('button', { name: 'Review content draft' }).click()
  await expect(page.getByRole('alert')).toContainText('unsaved content item edits')
  await page.getByRole('button', { name: 'Keep editing' }).click()
  await expect(itemPanel.getByLabel('Title')).toHaveValue('Unsaved manual lesson')
  await expect(itemPanel.getByLabel('Draft wording')).toHaveValue('Keep this exact unsaved manual wording.')
  await page.getByRole('button', { name: 'Review content draft' }).click()
  await page.getByRole('button', { name: 'Discard and review draft' }).click()
  await expect(itemPanel.getByLabel('Title')).toHaveValue('One calm next step')
  await expect(itemPanel.getByLabel('Title')).toBeFocused()
  await itemPanel.getByLabel('Title').fill('Unsaved same-item title')
  await page.getByRole('button', { name: 'Review content draft' }).click()
  await page.getByRole('button', { name: 'Keep editing' }).click()
  await expect(itemPanel.getByLabel('Title')).toHaveValue('Unsaved same-item title')
  await expect(itemPanel.getByLabel('Title')).toBeFocused()
  await page.getByRole('button', { name: 'Review content draft' }).click()
  await page.getByRole('button', { name: 'Discard and review draft' }).click()
  await expect(itemPanel.getByLabel('Title')).toHaveValue('One calm next step')
  await expect(itemPanel.getByLabel('Title')).toBeFocused()
  await itemPanel.getByLabel('Title').fill('Keep this edit through a same-request refresh')
  await itemPanel.getByRole('button', { name: 'Save draft', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('Temporary content save failure.')
  await page.getByRole('button', { name: 'Retry' }).click()
  await expect(itemPanel.getByLabel('Title')).toHaveValue('Keep this edit through a same-request refresh')
  await expect(itemPanel.getByLabel('Title')).not.toBeFocused()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('Coach Studio preserves candidate edits through conflicts and server safety rechecks', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chrome', 'candidate conflict and safety regression')
  let candidate = {
    id: 731, source_id: 730, position: 0, status: 'proposed', title: 'Original candidate', kind: 'guidance',
    content: 'Choose one practical step.', topics: [], safety_code: null as string | null, accepted_content_item_id: null,
    reviewed_at: null, updated_at: '2026-10-01T01:00:00Z', revision: 1, digest: 'candidate-initial',
    evidence_excerpt: 'Choose one practical step.', evidence_locator: { type: 'text', segment: 1, line_start: 1, line_end: 1, excerpt_digest: 'a'.repeat(64) },
  }
  const source = () => ({
    id: 730, scope: 'coach', filename: 'review-guide.txt', content_type: 'text/plain', byte_size: 30,
    checksum_sha256: 'f'.repeat(64), status: 'needs_review', generation: 1, source_available: true, error: null, error_code: null,
    source_delete_error_code: null, processing_metadata: {}, processed_at: '2026-10-01T01:00:00Z', source_deleted_at: null,
    created_at: '2026-10-01T00:59:00Z', updated_at: '2026-10-01T01:00:00Z',
    current_attempt: { id: 729, generation: 1, status: 'succeeded', error: null, error_code: null }, candidates: [candidate],
  })
  let conflictOnce = true
  let lastReviewInput: Record<string, unknown> = {}

  await page.route('http://api.test/api/v1/admin/content_sources', (route) => route.fulfill({ status: 200, json: { sources: [source()] } }))
  await page.route('http://api.test/api/v1/admin/content_sources/730', (route) => route.fulfill({ status: 200, json: { source: source() } }))
  await page.route('http://api.test/api/v1/admin/content_sources/730/candidates/731', (route) => {
    const input = route.request().postDataJSON().candidate
    lastReviewInput = input
    if (conflictOnce) {
      conflictOnce = false
      candidate = { ...candidate, title: 'Server revision', revision: 2, digest: 'candidate-server' }
      return route.fulfill({ status: 409, json: { error: 'This candidate changed; reload it before continuing.', code: 'content_candidate_conflict', candidate } })
    }
    const unsafe = String(input.content).includes('jane@example.com')
    candidate = { ...candidate, ...input, revision: candidate.revision + 1, digest: `candidate-${candidate.revision + 1}`, safety_code: unsafe ? 'personal_information' : null }
    return route.fulfill({
      status: unsafe ? 422 : 200,
      json: unsafe
        ? { error: 'Personal or identifying information must be removed.', code: 'personal_information', candidate }
        : { candidate },
    })
  })

  await page.goto('/?pilot_e2e_role=coach#Coach%20Studio')
  await page.getByRole('tab', { name: /Coaching Library/ }).click()
  await page.getByRole('button', { name: /review-guide.txt/ }).click()
  const editor = page.locator('.coach-candidate-editor')
  await editor.getByLabel('Candidate title').fill('Exact local title')
  await editor.getByRole('button', { name: 'Save edits' }).click()
  await expect(page.getByRole('alert')).toContainText('Your edits are still here')
  await expect(editor.getByLabel('Candidate title')).toHaveValue('Exact local title')
  await page.getByRole('button', { name: 'Keep editing' }).click()
  await expect(editor.getByLabel('Candidate title')).toHaveValue('Exact local title')
  await expect(editor.getByLabel('Draft wording')).toBeFocused()
  await editor.getByRole('button', { name: 'Save edits' }).click()
  expect(lastReviewInput).toMatchObject({ revision: 2, digest: 'candidate-server', title: 'Exact local title' })
  await expect(editor.getByLabel('Candidate title')).toHaveValue('Exact local title')

  await editor.getByLabel('Draft wording').fill('Contact jane@example.com for help.')
  await editor.getByRole('button', { name: 'Save edits' }).click()
  await expect(editor.getByText(/personal or identifying information was found/i)).toBeVisible()
  await expect(editor.getByLabel('Draft wording')).toHaveValue('Contact jane@example.com for help.')
  await expect(editor.getByRole('button', { name: 'Create content draft' })).toBeDisabled()

  await editor.getByLabel('Draft wording').fill('Review the general guidance together.')
  await editor.getByRole('button', { name: 'Save edits' }).click()
  await expect(editor.getByText(/personal or identifying information was found/i)).toHaveCount(0)
  await expect(editor.getByRole('button', { name: 'Create content draft' })).toBeEnabled()
})

test('administrators can see and retry terminal private upload cleanup', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chrome', 'admin cleanup recovery regression')
  let failed = true
  const source = {
    id: 799, scope: 'coach', filename: 'uploaded-source.txt', content_type: 'text/plain', byte_size: 20,
    checksum_sha256: 'd'.repeat(64), status: 'upload_cleanup_failed', generation: 0, source_available: false,
    error: 'Private storage cleanup needs an administrator to retry it.', error_code: 'upload_cleanup_failed',
    source_delete_error_code: null, processing_metadata: {}, processed_at: null, source_deleted_at: null,
    created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:01:00Z', current_attempt: null, candidates: [],
  }
  await page.route('http://api.test/api/v1/admin/content_sources', (route) => route.fulfill({ status: 200, json: { sources: failed ? [source] : [] } }))
  await page.route('http://api.test/api/v1/admin/content_sources/retry_upload_cleanups', (route) => {
    failed = false
    return route.fulfill({ status: 200, json: { retried_count: 1 } })
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByRole('tab', { name: /Coaching Library/ }).click()
  await expect(page.getByText('Upload cleanup needs admin retry')).toBeVisible()
  await page.getByRole('button', { name: 'Retry failed cleanup' }).click()
  await expect(page.getByRole('status')).toContainText('queued to retry')
})

test('Coach Studio keeps failed library drafts and read-only sources do not trigger dirty guards', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chrome', 'library form-state regression')
  const itemVersion: MockContentItemVersion = {
    id: 951, item_id: 941, title: 'Platform baseline', kind: 'guidance', content: 'Keep the participant in control.',
    always_on: true, version: 1, digest: 'platform-item-digest', approved_at: '2026-10-01T01:00:00Z',
  }
  const readonlyItem: MockContentItem = {
    id: 941, title: itemVersion.title, scope: 'platform', kind: 'guidance', always_on: true,
    draft_content: null, draft_revision: null, draft_digest: null, archived: false, editable: false,
    current_approved_version: itemVersion, versions: [itemVersion], has_unapproved_changes: false,
    updated_at: '2026-10-01T01:00:00Z',
  }
  const packVersion: MockContentPackVersion = {
    id: 961, pack_id: 942, name: 'Platform safeguards', description: 'Approved baseline context.', scope: 'platform',
    pack_kind: 'coaching_method', version: 1, digest: 'platform-pack-digest', published_at: '2026-10-01T01:01:00Z', items: [itemVersion],
  }
  const readonlyPack: MockContentPack = {
    id: 942, name: packVersion.name, description: packVersion.description, scope: 'platform', pack_kind: 'coaching_method',
    item_version_ids: [itemVersion.id], draft_revision: null, draft_manifest_digest: null, archived: false, editable: false,
    draft_items: [], current_published_version: packVersion, versions: [packVersion], has_unpublished_changes: false,
    item_updates_available: false, update_available: false, updated_at: '2026-10-01T01:01:00Z',
  }

  await page.route('http://api.test/api/v1/admin/content_items', async (route) => {
    if (route.request().method() === 'POST') {
      return route.fulfill({ status: 422, json: { error: 'The content draft could not be saved.' } })
    }
    return route.fulfill({ status: 200, json: { items: [readonlyItem] } })
  })
  await page.route('http://api.test/api/v1/admin/content_packs', (route) => {
    if (route.request().method() === 'POST') {
      return route.fulfill({ status: 422, json: { error: 'The pack draft could not be saved.' } })
    }
    return route.fulfill({ status: 200, json: { packs: [readonlyPack] } })
  })

  await page.goto('/?pilot_e2e_role=coach#Coach%20Studio')
  await page.getByRole('tab', { name: /Coaching Library/ }).click()
  await page.getByRole('button', { name: /Platform baseline/ }).click()
  let unexpectedPrompt = false
  const acceptUnexpectedPrompt = async (dialog: import('@playwright/test').Dialog) => {
    unexpectedPrompt = true
    await dialog.accept()
  }
  page.on('dialog', acceptUnexpectedPrompt)
  await page.getByRole('tab', { name: /Assistant voice/ }).click()
  await expect(page.getByRole('heading', { name: 'Coach Lani' })).toBeVisible()
  await page.getByRole('tab', { name: /Coaching Library/ }).click()
  await page.getByRole('button', { name: /Platform safeguards/ }).click()
  await page.getByRole('tab', { name: /Participant tools/ }).click()
  await expect(page.getByRole('heading', { name: 'Choose what participants can open.' })).toBeVisible()
  page.off('dialog', acceptUnexpectedPrompt)
  expect(unexpectedPrompt).toBe(false)

  await page.getByRole('tab', { name: /Coaching Library/ }).click()
  await page.getByRole('button', { name: 'New item' }).click()
  const itemPanel = page.locator('.coach-content-panel').filter({ has: page.getByRole('heading', { name: 'Coach-authored building blocks' }) })
  await itemPanel.getByLabel('Title').fill('  Keep   this failed title  ')
  await itemPanel.getByLabel('Draft wording').fill('Preserve this exact draft after the server rejects it.')
  await itemPanel.getByRole('button', { name: 'Create draft' }).click()

  await expect(page.getByRole('alert')).toContainText('The content draft could not be saved.')
  await expect(itemPanel.getByLabel('Title')).toHaveValue('  Keep   this failed title  ')
  await expect(itemPanel.getByLabel('Draft wording')).toHaveValue('Preserve this exact draft after the server rejects it.')
  await expect(itemPanel.getByRole('button', { name: 'Create draft' })).toBeVisible()

  await page.getByRole('button', { name: 'New pack' }).click()
  const packPanel = page.locator('.coach-content-panel').filter({ has: page.getByRole('heading', { name: 'Publish a reusable collection' }) })
  await packPanel.getByLabel('Pack name').fill('  Keep   this failed pack  ')
  await packPanel.getByLabel(/Platform baseline/).check()
  await packPanel.getByRole('button', { name: 'Create pack draft' }).click()
  await expect(page.getByRole('alert')).toContainText('The pack draft could not be saved.')
  await expect(packPanel.getByLabel('Pack name')).toHaveValue('  Keep   this failed pack  ')
  await expect(packPanel.getByLabel(/Platform baseline/)).toBeChecked()
  await expect(packPanel.getByRole('button', { name: 'Create pack draft' })).toBeVisible()
})

test('Coach Studio protects unsaved assistant source selections across tabs and global navigation', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chrome', 'source-selection navigation regression')
  const publishedVersion: MockContentPackVersion = {
    id: 931,
    pack_id: 921,
    name: 'Mrs. Mel Guam context',
    description: 'Reviewed Guam family context for participant-led conversations.',
    scope: 'coach',
    pack_kind: 'voice_culture',
    version: 1,
    digest: 'pack-digest',
    published_at: '2026-10-01T01:04:00Z',
    items: [],
  }
  const pack: MockContentPack = {
    id: 921,
    name: publishedVersion.name,
    description: publishedVersion.description,
    scope: 'coach',
    pack_kind: 'voice_culture',
    item_version_ids: [],
    draft_revision: 1,
    draft_manifest_digest: 'pack-draft-1',
    archived: false,
    editable: true,
    draft_items: [],
    current_published_version: publishedVersion,
    versions: [publishedVersion],
    has_unpublished_changes: false,
    item_updates_available: false,
    update_available: false,
    updated_at: '2026-10-01T01:04:00Z',
  }

  await page.route('http://api.test/api/v1/admin/content_packs', (route) => route.fulfill({ status: 200, json: { packs: [pack] } }))
  await page.route('http://api.test/api/v1/admin/personas/81/content_packs', (route) => {
    const ids = route.request().postDataJSON().content_packs.pack_version_ids as number[]
    return route.fulfill({
      status: 200,
      json: {
        persona: {
          ...personaDetailFixture(),
          draft_revision: 2,
          content_packs: ids.includes(publishedVersion.id) ? [publishedVersion] : [],
        },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  const assistantTab = page.getByRole('tab', { name: /Assistant voice/ })
  const libraryTab = page.getByRole('tab', { name: /Coaching Library/ })
  const participantToolsTab = page.getByRole('tab', { name: /Participant tools/ })
  await expect(assistantTab).toHaveAttribute('id', 'coach-studio-tab-assistants')
  await expect(assistantTab).toHaveAttribute('aria-controls', 'coach-studio-panel-assistants')
  await expect(assistantTab).toHaveAttribute('tabindex', '0')
  await expect(page.locator('#coach-studio-panel-assistants')).toHaveAttribute('aria-labelledby', 'coach-studio-tab-assistants')
  await assistantTab.focus()
  await assistantTab.press('End')
  await expect(participantToolsTab).toBeFocused()
  await expect(participantToolsTab).toHaveAttribute('aria-selected', 'true')
  await expect(page.locator('#coach-studio-panel-participant-tools')).toBeVisible()
  await participantToolsTab.press('ArrowLeft')
  await expect(libraryTab).toBeFocused()
  await expect(libraryTab).toHaveAttribute('aria-selected', 'true')
  await libraryTab.press('Home')
  await expect(assistantTab).toBeFocused()
  await expect(assistantTab).toHaveAttribute('aria-selected', 'true')
  const sourceCheckbox = page.getByLabel(/Mrs. Mel Guam context/)
  await sourceCheckbox.check()

  await assistantTab.focus()
  page.once('dialog', async (dialog) => {
    expect(dialog.message()).toContain('Discard unsaved Coach Studio changes')
    await dialog.dismiss()
  })
  await assistantTab.press('ArrowRight')
  await expect(assistantTab).toBeFocused()
  await expect(assistantTab).toHaveAttribute('aria-selected', 'true')
  await expect(sourceCheckbox).toBeChecked()

  for (const target of [/Coaching Library/, /Participant tools/]) {
    page.once('dialog', async (dialog) => {
      expect(dialog.message()).toContain('Discard unsaved Coach Studio changes')
      await dialog.dismiss()
    })
    await page.getByRole('tab', { name: target }).click()
    await expect(page.getByRole('tab', { name: /Assistant voice/ })).toHaveAttribute('aria-selected', 'true')
    await expect(sourceCheckbox).toBeChecked()
  }

  page.once('dialog', async (dialog) => {
    expect(dialog.message()).toContain('Discard your unsaved Coach Studio changes')
    await dialog.dismiss()
  })
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(page).toHaveURL(/#Coach%20Studio$/)
  await expect(sourceCheckbox).toBeChecked()

  page.once('dialog', (dialog) => dialog.accept())
  await page.getByRole('tab', { name: /Coaching Library/ }).click()
  await expect(page.getByRole('heading', { name: 'Build reusable coaching material' })).toBeVisible()
  await page.getByRole('tab', { name: /Assistant voice/ }).click()
  await expect(page.getByLabel(/Mrs. Mel Guam context/)).not.toBeChecked()

  await page.getByLabel(/Mrs. Mel Guam context/).check()
  page.once('dialog', (dialog) => dialog.accept())
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(page).toHaveURL(/#Home$/)
  await openSection(page, 'Coach Studio')
  await expect(page.getByLabel(/Mrs. Mel Guam context/)).not.toBeChecked()

  await page.getByLabel(/Mrs. Mel Guam context/).check()
  await page.getByRole('button', { name: 'Save source selection' }).click()
  await expect(page.getByRole('status')).toContainText('fresh preview')
  let promptedAfterSave = false
  const acceptUnexpectedPrompt = async (dialog: import('@playwright/test').Dialog) => {
    promptedAfterSave = true
    await dialog.accept()
  }
  page.on('dialog', acceptUnexpectedPrompt)
  await page.getByRole('tab', { name: /Participant tools/ }).click()
  await expect(page.getByRole('heading', { name: 'Choose what participants can open.' })).toBeVisible()
  page.off('dialog', acceptUnexpectedPrompt)
  expect(promptedAfterSave).toBe(false)
})

test('Coach Studio protects unsaved work across mobile back and section navigation', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await expect(page.getByRole('heading', { name: 'Coach Lani' })).toBeVisible()
  await expect(page.locator('.coach-library')).toBeHidden()
  await expect(page.locator('.coach-save-bar')).toHaveCSS('position', 'static')

  await page.getByLabel('Assistant name').fill('Coach Lani with unsaved work')
  await page.getByRole('button', { name: 'All assistants' }).click()
  const backConflict = page.getByRole('alert')
  await expect(backConflict).toContainText('unsaved changes')
  await expect(page.getByLabel('Assistant name')).toHaveValue('Coach Lani with unsaved work')
  await backConflict.getByRole('button', { name: 'Keep editing' }).click()

  page.once('dialog', async (dialog) => {
    expect(dialog.message()).toContain('Discard your unsaved Coach Studio changes')
    await dialog.dismiss()
  })
  await page.getByRole('link', { name: 'Home', exact: true }).click()
  await expect(page).toHaveURL(/#Coach%20Studio$/)
  await expect(page.getByLabel('Assistant name')).toHaveValue('Coach Lani with unsaved work')

  await page.getByRole('button', { name: 'All assistants' }).click()
  await page.getByRole('alert').getByRole('button', { name: 'Discard and show assistants' }).click()
  await expect(page.locator('.coach-library')).toBeVisible()
  await expect(page.getByRole('heading', { name: '1 coaching assistant' })).toBeFocused()
  await expect(page.locator('.coach-editor-column')).toBeHidden()
  const filterHeight = await page.getByRole('button', { name: 'Active', exact: true }).evaluate((element) => element.getBoundingClientRect().height)
  expect(filterHeight).toBeGreaterThanOrEqual(44)
})

test('Coach Studio keeps publishing locked when the behavioral preview is unavailable', async ({ page }) => {
  await page.route('http://api.test/api/v1/admin/personas/81/preview', async (route) => {
    const detail = personaDetailFixture()
    const body = route.request().postDataJSON().preview
    return route.fulfill({
      status: 200,
      json: {
        persona: detail,
        preview: {
          persona_id: 81,
          draft_revision: 1,
          digest: 'compile-only-digest',
          rendered_instructions: 'Compiled safely.',
          status: 'unavailable',
          source: 'model_unavailable',
          sample_prompt: body.sample_prompt,
          sample_reply: null,
          notice: 'The exact draft compiled, but the behavioral model preview is unavailable.',
          warnings: [],
          guardrails_applied: true,
          generated_at: '2026-10-01T01:00:00Z',
        },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await expect(page.getByText('Use fictional details only.', { exact: false })).toBeVisible()
  await page.getByRole('button', { name: 'Run exact preview' }).click()
  await expect(page.getByRole('region', { name: 'Exact draft preview' })).toContainText('Behavioral sample unavailable')
  await expect(page.getByRole('button', { name: 'Publish first version' })).toBeDisabled()
  await expect(page.getByText('A successful behavioral preview is required before publishing.')).toBeVisible()
})

test('Coach Studio shows a crisis boundary without treating it as a publishable persona preview', async ({ page }) => {
  await page.route('http://api.test/api/v1/admin/personas/81/preview', async (route) => {
    const detail = personaDetailFixture()
    const body = route.request().postDataJSON().preview
    return route.fulfill({
      status: 200,
      json: {
        persona: detail,
        preview: {
          persona_id: 81,
          draft_revision: 1,
          digest: 'safety-only-digest',
          rendered_instructions: 'Compiled safely.',
          status: 'safety_only',
          source: 'deterministic_safety',
          sample_prompt: body.sample_prompt,
          sample_reply: 'Call or text 988 now.',
          notice: 'Safety rules took precedence. This cannot authorize publication.',
          warnings: [],
          guardrails_applied: true,
          generated_at: '2026-10-01T01:00:00Z',
        },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByLabel('Behavioral preview question').fill('I want to die')
  await page.getByRole('button', { name: 'Run exact preview' }).click()

  const preview = page.getByRole('region', { name: 'Exact draft preview' })
  await expect(preview).toContainText('Safety response checked')
  await expect(preview).toContainText('Call or text 988 now.')
  await expect(preview).toContainText('cannot authorize publication')
  await expect(page.getByRole('button', { name: 'Publish first version' })).toBeDisabled()
  await expect(page.getByText('The crisis boundary worked, but it did not exercise this persona.')).toBeVisible()
})

test('Coach Studio explains why a saved server preview must be reviewed again after reload', async ({ page }) => {
  const savedPreview = {
    ...personaDetailFixture(),
    preview_required: false,
    preview: { digest: 'saved-preview-digest', draft_revision: 1, generated_at: '2026-10-01T01:00:00Z' },
  }
  await page.route('http://api.test/api/v1/admin/personas', (route) => route.fulfill({ status: 200, json: { personas: [savedPreview] } }))
  await page.route('http://api.test/api/v1/admin/personas/81', (route) => route.fulfill({ status: 200, json: { persona: savedPreview } }))

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')

  await expect(page.getByText('Saved Preview', { exact: true })).toBeVisible()
  await expect(page.getByText('This exact revision passed preview in another session.')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Publish first version' })).toBeDisabled()
})

test('Coach Studio confirms immediate assigned-cohort impact before publishing a new version', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByRole('button', { name: 'Run exact preview' }).click()
  await page.getByRole('button', { name: 'Publish first version' }).click()
  const activeCohort = page.locator('.coach-cohort-list article').filter({ hasText: 'Household CFO pilot' })
  await activeCohort.getByRole('button', { name: 'Assign', exact: true }).click()

  await page.getByLabel('Assistant name').fill('Coach Lani Version Two')
  await page.getByRole('button', { name: 'Save draft' }).click()
  await page.getByRole('button', { name: 'Run exact preview' }).click()
  await expect(page.getByText('Publishing or restoring a version updates future participant messages')).toBeVisible()

  page.once('dialog', async (dialog) => {
    expect(dialog.message()).toContain('Future participant messages in 1 assigned cohort will use it immediately.')
    await dialog.accept()
  })
  await page.getByRole('button', { name: 'Publish next version' }).click()
  await expect(page.getByRole('status')).toContainText('version 2 is published')
})

test('Coach Studio ignores stale assistant detail responses during rapid selection', async ({ page }, testInfo) => {
  test.skip(!['desktop-chrome', 'tablet-1024-chrome'].includes(testInfo.project.name), 'two-pane selection ordering check')
  const first = personaDetailFixture()
  const second = { ...personaDetailFixture(), id: 82, name: 'Coach B', draft: { ...structuredClone(personaConfiguration), identity: { ...personaConfiguration.identity, assistant_name: 'Coach B' } } }
  const third = { ...personaDetailFixture(), id: 83, name: 'Coach C', draft: { ...structuredClone(personaConfiguration), identity: { ...personaConfiguration.identity, assistant_name: 'Coach C' } } }
  await page.route('http://api.test/api/v1/admin/personas', (route) => route.fulfill({ status: 200, json: { personas: [first, second, third] } }))
  await page.route('http://api.test/api/v1/admin/personas/82', async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 250))
    await route.fulfill({ status: 200, json: { persona: second } })
  })
  await page.route('http://api.test/api/v1/admin/personas/83', async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 10))
    await route.fulfill({ status: 200, json: { persona: third } })
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.locator('.coach-library-list').getByRole('button', { name: /Coach B/ }).click()
  await page.locator('.coach-library-list').getByRole('button', { name: /Coach C/ }).click()
  await expect(page.getByRole('heading', { name: 'Coach C' })).toBeVisible()
  await page.waitForTimeout(300)
  await expect(page.getByRole('heading', { name: 'Coach C' })).toBeVisible()
  await expect(page.getByLabel('Assistant name')).toHaveValue('Coach C')
})

test('Coach Studio prevents assistant switches while a mutation is pending', async ({ page }, testInfo) => {
  const first = personaDetailFixture()
  const second = { ...personaDetailFixture(), id: 82, name: 'Coach B', draft: { ...structuredClone(personaConfiguration), identity: { ...personaConfiguration.identity, assistant_name: 'Coach B' } } }
  await page.route('http://api.test/api/v1/admin/personas', (route) => route.fulfill({ status: 200, json: { personas: [first, second] } }))
  await page.route('http://api.test/api/v1/admin/personas/82', (route) => route.fulfill({ status: 200, json: { persona: second } }))
  await page.route('http://api.test/api/v1/admin/personas/81/preview', async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 500))
    await route.fallback()
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await page.getByRole('button', { name: 'Run exact preview' }).click()

  const selectionControl = ['desktop-chrome', 'tablet-1024-chrome'].includes(testInfo.project.name)
    ? page.locator('.coach-library-list').getByRole('button', { name: /Coach B/ })
    : page.getByRole('button', { name: 'All assistants' })
  await expect(selectionControl).toBeDisabled()
  await expect(page.getByRole('region', { name: 'Exact draft preview' })).toContainText('Behavioral sample ready')
  await expect(selectionControl).toBeEnabled()
})

test('Coach Studio retains unsaved work when the server reports a draft conflict', async ({ page }) => {
  let conflictPending = true
  await page.route('http://api.test/api/v1/admin/personas/81', async (route) => {
    if (route.request().method() !== 'PATCH' || !conflictPending) return route.fallback()
    conflictPending = false
    return route.fulfill({
      status: 409,
      json: {
        error: 'This assistant changed on the server. Reload the latest draft before saving again.',
        code: 'persona_draft_conflict',
      },
    })
  })

  await page.goto('/?pilot_e2e_role=admin#Coach%20Studio')
  await expect(page.getByRole('heading', { name: 'Shape a coaching assistant people can trust.' })).toBeVisible()

  await page.getByLabel('Assistant name').fill('Coach Lani — revised locally')
  await page.getByRole('button', { name: 'Save draft' }).click()

  const conflict = page.getByRole('alert')
  await expect(conflict).toContainText('changed on the server')
  await expect(conflict.getByRole('button', { name: 'Reload server draft' })).toBeVisible()
  await expect(page.getByLabel('Assistant name')).toHaveValue('Coach Lani — revised locally')
  await expect(page.getByText('Unsaved changes')).toBeVisible()
})

test('Coach Studio gives assigned coaches a scoped read-only view of another owner’s assistant', async ({ page }) => {
  const version = {
    id: 101,
    number: 1,
    digest: 'version-1',
    published_at: '2026-10-01T01:05:00Z',
    published_by: { full_name: 'Pilot Admin' },
  }
  const assignment = {
    id: 501,
    cohort: { id: 41, name: 'Household CFO pilot', status: 'active' },
    persona: { id: 81, name: 'Coach Lani' },
    published_version: version,
    assigned_at: '2026-10-01T01:10:00Z',
    updated_at: '2026-10-01T01:10:00Z',
    assigned_by: { full_name: 'Pilot Admin' },
  }
  const readOnlyPersona: Record<string, unknown> = {
    ...personaDetailFixture(),
    description: '',
    status: 'published',
    published_version: version,
    versions: [version],
    assignments: [assignment],
    visible_assignment_count: 1,
    permissions: { read: true, edit: false, publish: false, assign: false, archive: false, restore: false },
    preview_required: false,
    has_unpublished_changes: false,
  }
  delete readOnlyPersona.draft
  delete readOnlyPersona.draft_revision
  delete readOnlyPersona.preview

  await page.route('http://api.test/api/v1/admin/personas', (route) => route.fulfill({ status: 200, json: { personas: [readOnlyPersona] } }))
  await page.route('http://api.test/api/v1/admin/personas/81', (route) => route.fulfill({ status: 200, json: { persona: readOnlyPersona } }))

  await page.goto('/?pilot_e2e_role=coach#Coach%20Studio')

  await expect(page.getByRole('heading', { name: 'Coach Lani' })).toBeVisible()
  await expect(page.getByText('Published assistant assigned to a cohort you manage.')).toBeVisible()
  await expect(page.getByText('Private draft settings are visible only to the owning coach and administrators.')).toBeVisible()
  await expect(page.getByRole('group', { name: 'Editing mode' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Save draft' })).toHaveCount(0)
  await expect(page.getByText('Remove this assistant from every draft, enrolling, or active cohort before archiving.')).toHaveCount(0)
  await expect(page.getByRole('link', { name: 'Admin', exact: true })).toHaveCount(0)
})

test('Coach Studio stays private from participant navigation and direct URLs', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name.includes('mobile'), 'desktop authorization history assertion')
  await page.goto('/?pilot_e2e_role=participant#Coach%20Studio')

  await expect(page).toHaveURL(/#Home$/)
  await expect(page.getByRole('heading', { name: 'Give Mia a useful starting point.' })).toBeVisible()
  await expect(page.getByRole('link', { name: 'Coach Studio', exact: true })).toHaveCount(0)
})

test('participant can add edit and explicitly remove individual debt records', async ({ page }) => {
  let debts: Array<{ id: number; label: string; debt_type: string; balance: number; minimum_payment: number; interest_rate_percent: number | null }> = []
  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({
    status: 200,
    json: { ...realWorkspaceData(true), workspace: { ...realWorkspaceData(true).workspace, debts } },
  }))
  await page.route('http://api.test/api/v1/debts**', async (route) => {
    const request = route.request()
    const path = new URL(request.url()).pathname
    if (request.method() === 'POST') {
      const input = request.postDataJSON().debt
      const debt = { id: 88, ...input }
      debts = [debt]
      return route.fulfill({ status: 201, json: { debt } })
    }
    if (request.method() === 'PATCH' && path.endsWith('/88')) {
      const input = request.postDataJSON().debt
      const debt = { id: 88, ...input }
      debts = [debt]
      return route.fulfill({ status: 200, json: { debt } })
    }
    if (request.method() === 'DELETE' && path.endsWith('/88')) {
      debts = []
      return route.fulfill({ status: 204, body: '' })
    }
    return route.fulfill({ status: 404, json: { error: 'Unexpected debt request' } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await expect(page.getByText('BOG cohort', { exact: true })).toBeVisible()
  await openSection(page, 'My Profile')
  const debtPanel = page.locator('.debt-manager')
  await debtPanel.getByRole('button', { name: 'Add a debt' }).click()
  await debtPanel.getByLabel('Debt name').fill('Visa Gold')
  await debtPanel.getByLabel('Current balance').fill('4200.50')
  await debtPanel.getByLabel('Monthly minimum').fill('125')
  await debtPanel.getByLabel('APR').fill('24.99')
  await debtPanel.getByRole('button', { name: 'Add debt' }).click()
  await expect(debtPanel).toContainText('Visa Gold')
  await expect(debtPanel).toContainText('24.99% APR')
  await expect(debtPanel).toContainText('$4,200.50')

  await debtPanel.getByRole('button', { name: 'Edit' }).click()
  await debtPanel.getByLabel('APR').fill('19.75')
  await debtPanel.getByRole('button', { name: 'Save debt' }).click()
  await expect(debtPanel).toContainText('19.75% APR')

  await debtPanel.getByRole('button', { name: 'Remove' }).click()
  await expect(debtPanel.getByRole('button', { name: 'Confirm remove' })).toBeVisible()
  await debtPanel.getByRole('button', { name: 'Confirm remove' }).click()
  await expect(debtPanel).toContainText('No individual debts entered yet.')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('admin can privately review and resolve submitted pilot feedback', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=admin')
  await openSection(page, 'Admin')

  const inbox = page.locator('.pilot-feedback-inbox')
  await expect(inbox.getByText('The upload stopped with a provider error.')).toBeVisible()
  await expect(inbox.getByText('participant@pilot.test', { exact: true })).toBeVisible()

  const statusRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/admin/pilot_feedback_reports/72') && request.method() === 'PATCH')
  await inbox.getByRole('button', { name: 'Mark reviewed' }).click()
  await statusRequest

  await expect(inbox.getByText('Feedback marked reviewed.')).toBeVisible()
  await expect(inbox.getByRole('button', { name: 'Reviewed 1' })).toBeVisible()
  await expect(inbox.getByText('Private Feedback Household')).toHaveCount(0)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('real review controls keep transaction and Mia changes behind explicit participant actions', async ({ page }) => {
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()

  const transactionCard = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await expect(transactionCard).toContainText('Actuals stay unchanged until you confirm.')
  const confirmRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/transaction_drafts/91/confirm') && request.method() === 'POST')
  await transactionCard.getByRole('button', { name: 'Confirm' }).click()
  await confirmRequest

  const miaCard = page.locator('.mia-action-draft-card').filter({ hasText: 'Move more into the unexpected sinking fund' })
  await expect(miaCard.getByRole('button', { name: 'Apply reviewed change' })).toBeEnabled()
  await expect(miaCard.getByRole('button', { name: 'Cancel draft' })).toBeEnabled()
  await expect(miaCard).toContainText('leave actual spending untouched')
  const cancelRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/mia_action_drafts/71/cancel') && request.method() === 'POST')
  await miaCard.getByRole('button', { name: 'Cancel draft' }).click()
  await cancelRequest
})

test('uncertain receipt splits stay reviewable and cannot be confirmed until categorized on mobile', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  let workspace = realWorkspaceData(true)
  const uncertainDraft = {
    id: 191,
    occurred_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-16`,
    merchant: "Tita's Demo Market",
    amount: 70.25,
    amount_cents: 7_025,
    status: 'pending',
    source_type: 'receipt',
    financial_document_import_id: 700,
    category_id: 2,
    category_name: 'Dining out',
    splits: [
      { id: 501, budget_category_id: 2, category_name: 'Dining out', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 42.15, amount_cents: 4_215, notes: 'Food items', confidence: 0.65, metadata: { category_match_status: 'matched', category_match_reason: 'item_text', extracted_category_name: 'Food' } },
      { id: 502, budget_category_id: null, category_name: 'Household supplies', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 13.50, amount_cents: 1_350, notes: 'Cleaning products', confidence: 0.65, metadata: { category_match_status: 'needs_review', category_match_reason: 'no_strong_match', extracted_category_name: 'Household supplies' } },
      { id: 503, budget_category_id: null, category_name: 'Cigarettes', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 11.25, amount_cents: 1_125, notes: 'Tobacco line', confidence: 0.65, metadata: { category_match_status: 'needs_review', category_match_reason: 'no_strong_match', extracted_category_name: 'Cigarettes' } },
      { id: 504, budget_category_id: null, category_name: 'Tax', stack_key: 'discretionary', stack_label: 'Discretionary', amount: 3.35, amount_cents: 335, notes: 'Sales tax', confidence: 0.65, metadata: { category_match_status: 'needs_review', category_match_reason: 'no_strong_match', extracted_category_name: 'Tax' } },
    ],
    matches: [],
  }
  workspace = {
    ...workspace,
    budget: {
      ...workspace.budget,
      annual_plan: {
        ...workspace.budget.annual_plan!,
        pending_transaction_drafts: [uncertainDraft],
      },
    },
  }

  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: workspace }))
  await page.route('http://api.test/api/v1/transaction_drafts/191', async (route) => {
    if (route.request().method() !== 'PATCH') return route.fallback()
    const payload = route.request().postDataJSON().transaction_draft
    const categoryNames = new Map([[1, 'Fixed essentials'], [2, 'Dining out'], [3, 'Expected sinking fund'], [4, 'Unexpected sinking fund']])
    const updatedDraft = {
      ...uncertainDraft,
      category_id: payload.splits[0].budget_category_id,
      category_name: categoryNames.get(payload.splits[0].budget_category_id) ?? null,
      splits: payload.splits.map((split: typeof uncertainDraft.splits[number]) => ({
        ...split,
        budget_category_id: split.budget_category_id,
        category_name: categoryNames.get(Number(split.budget_category_id)) ?? split.category_name,
      })),
    }
    workspace = {
      ...workspace,
      budget: {
        ...workspace.budget,
        annual_plan: {
          ...workspace.budget.annual_plan!,
          pending_transaction_drafts: [updatedDraft],
        },
      },
    }
    return route.fulfill({ status: 200, json: { transaction_draft: updatedDraft, workspace } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  const card = page.locator('.transaction-draft-card').filter({ hasText: "Tita's Demo Market" })
  await expect(card.getByText('3 splits need a category')).toBeVisible()
  await expect(card.getByText('Cleaning products')).toBeVisible()
  await expect(card.locator('.transaction-draft-impact-row.needs-category')).toContainText('Needs category$28.10 in this draft')
  await expect(card.getByRole('button', { name: 'Confirm', exact: true })).toBeDisabled()

  await card.getByRole('button', { name: 'Review categories' }).click()
  const categorySelects = card.getByLabel('Category')
  await expect(categorySelects).toHaveCount(4)
  await expect(categorySelects.nth(1)).toBeFocused()
  await categorySelects.nth(1).selectOption('1')
  await categorySelects.nth(2).selectOption('4')
  await categorySelects.nth(3).selectOption('2')
  const updateRequest = page.waitForRequest((request) => request.url().endsWith('/api/v1/transaction_drafts/191') && request.method() === 'PATCH')
  await card.getByRole('button', { name: 'Save draft' }).click()
  const request = await updateRequest
  expect(request.postDataJSON().transaction_draft.splits.map((split: { budget_category_id: number | null }) => split.budget_category_id)).toEqual([2, 1, 4, 2])
  await expect(card.getByText(/splits? need/)).toHaveCount(0)
  await expect(card.getByRole('button', { name: 'Confirm', exact: true })).toBeEnabled()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('receipt category corrections refresh the selected import immediately', async ({ page }) => {
  const draft = {
    id: 192,
    occurred_on: `${currentYear}-${String(new Date().getMonth() + 1).padStart(2, '0')}-16`,
    merchant: "Tita's Demo Market",
    amount: 3.35,
    amount_cents: 335,
    status: 'pending',
    source_type: 'receipt',
    financial_document_import_id: 701,
    category_id: null,
    category_name: null,
    splits: [{
      id: 505,
      budget_category_id: null,
      category_name: 'Tax',
      stack_key: null,
      stack_label: null,
      amount: 3.35,
      amount_cents: 335,
      notes: 'Sales tax',
      confidence: 0.65,
      metadata: { category_match_status: 'needs_review', category_match_reason: 'no_strong_match', extracted_category_name: 'Tax' },
    }],
    matches: [],
  }
  let workspace = realWorkspaceData(true)
  workspace = {
    ...workspace,
    budget: {
      ...workspace.budget,
      annual_plan: {
        ...workspace.budget.annual_plan!,
        pending_transaction_drafts: [draft],
      },
    },
  }
  const documentImport = {
    id: 701,
    household_id: 77,
    document_kind: 'receipt',
    status: 'needs_review',
    filename: 'receipt.png',
    content_type: 'image/png',
    byte_size: 24_000,
    document_date: draft.occurred_on,
    period_start_on: null,
    period_end_on: null,
    extracted_summary: 'Mia found one transaction draft.',
    extraction_error: null,
    processed_at: `${currentYear}-08-16T01:00:00Z`,
    applied_at: null,
    source_deleted_at: null,
    updated_at: `${currentYear}-08-16T01:00:00Z`,
    source_available: true,
    details_included: true,
    uploaded_by: null,
    applied_by: null,
    source_deleted_by: null,
    metadata: {},
    items: [],
    transaction_drafts: [draft],
    attempts: [],
  }

  await page.route('http://api.test/api/v1/workspace', (route) => route.fulfill({ status: 200, json: workspace }))
  await page.route('http://api.test/api/v1/document_imports', (route) => route.fulfill({ status: 200, json: { document_imports: [documentImport] } }))
  await page.route('http://api.test/api/v1/transaction_drafts/192', async (route) => {
    if (route.request().method() !== 'PATCH') return route.fallback()
    const payload = route.request().postDataJSON().transaction_draft
    const updatedDraft = {
      ...draft,
      category_id: 2,
      category_name: 'Dining out',
      splits: payload.splits.map((split: typeof draft.splits[number]) => ({
        ...split,
        budget_category_id: split.budget_category_id,
        category_name: 'Dining out',
        stack_key: 'discretionary',
        stack_label: 'Discretionary',
      })),
    }
    workspace = {
      ...workspace,
      budget: {
        ...workspace.budget,
        annual_plan: {
          ...workspace.budget.annual_plan!,
          pending_transaction_drafts: [updatedDraft],
        },
      },
    }
    return route.fulfill({ status: 200, json: { transaction_draft: updatedDraft, workspace } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await openSection(page, 'My Profile')
  const card = page.locator('.transaction-draft-card').filter({ hasText: "Tita's Demo Market" })
  await card.getByRole('button', { name: 'Review categories' }).click()
  await card.getByLabel('Category').selectOption('2')
  await card.getByRole('button', { name: 'Save draft' }).click()

  await expect(card.getByText(/splits? need/)).toHaveCount(0)
  await expect(card.locator('.transaction-draft-splits')).toContainText('Dining out')
  await expect(card.getByRole('button', { name: 'Confirm', exact: true })).toBeEnabled()
})

test('a late spending report cannot overwrite the refresh triggered by a transaction decision', async ({ page }) => {
  let requestCount = 0
  let markFirstRequestStarted: (() => void) | undefined
  const firstRequestStarted = new Promise<void>((resolve) => { markFirstRequestStarted = resolve })
  const reportCategory = (id: number, name: string, stackKey: string, stackLabel: string, planned: number, actual: number) => ({
    id, name, stack_key: stackKey, stack_label: stackLabel, planned, actual, pending: 0, remaining: planned - actual, active: true,
  })
  const currentMonthNumber = String(new Date().getMonth() + 1).padStart(2, '0')
  const reportShell = {
    period_label: `${currentMonth} ${currentYear}`,
    start_on: `${currentYear}-${currentMonthNumber}-01`,
    end_on: `${currentYear}-${currentMonthNumber}-28`,
    transactions: [],
    pending_drafts: [],
  }

  await page.route('http://api.test/api/v1/spending_report**', async (route) => {
    requestCount += 1
    if (requestCount === 1) {
      markFirstRequestStarted?.()
      await new Promise((resolve) => setTimeout(resolve, 500))
      return route.fulfill({
        status: 200,
        json: { spending_report: { ...reportShell, totals: { planned: 0, actual: 0, pending: 0, remaining: 0 }, categories: [] } },
      })
    }

    return route.fulfill({
      status: 200,
      json: {
        spending_report: {
          ...reportShell,
          totals: { planned: 5_300, actual: 4_000, pending: 0, remaining: 1_300 },
          categories: [
            reportCategory(1, 'Fixed essentials', 'non_discretionary', 'Non-discretionary', 4_000, 3_500),
            reportCategory(2, 'Dining out', 'discretionary', 'Discretionary', 450, 500),
            reportCategory(3, 'Expected sinking fund', 'sinking_expected', 'Sinking Fund — Expected', 600, 0),
            reportCategory(4, 'Unexpected sinking fund', 'sinking_unexpected', 'Sinking Fund — Unexpected', 250, 0),
          ],
        },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await firstRequestStarted
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  const transactionCard = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await transactionCard.getByRole('button', { name: 'Confirm' }).click()

  const monthSummary = page.getByRole('region', { name: `${currentShortMonth} ${currentYear} plan position` })
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')
  await page.waitForTimeout(600)
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')
  expect(requestCount).toBeGreaterThanOrEqual(2)
})

test('a late Mia response cannot replace the ledger after the participant changes months', async ({ page }) => {
  const currentMonthIndex = new Date().getMonth()
  const targetMonthIndex = currentMonthIndex === 11 ? 10 : currentMonthIndex + 1
  const targetMonthNumber = String(targetMonthIndex + 1).padStart(2, '0')
  const currentMonthNumber = String(currentMonthIndex + 1).padStart(2, '0')
  const reportFor = (monthIndex: number, transactionLabel: string) => ({
    period_label: `${new Intl.DateTimeFormat('en-US', { month: 'long' }).format(new Date(currentYear, monthIndex, 1))} ${currentYear}`,
    start_on: `${currentYear}-${String(monthIndex + 1).padStart(2, '0')}-01`,
    end_on: `${currentYear}-${String(monthIndex + 1).padStart(2, '0')}-28`,
    totals: { planned: 5_300, actual: 125, pending: 0, remaining: 5_175 },
    categories: [],
    transactions: [{ id: monthIndex + 500, occurred_on: `${currentYear}-${String(monthIndex + 1).padStart(2, '0')}-12`, merchant: transactionLabel, amount: 125, amount_cents: 12_500, categories: ['Fixed essentials'], source_type: 'manual' }],
    pending_drafts: [],
  })
  const currentReport = reportFor(currentMonthIndex, 'STALE MIA MONTH')
  const targetReport = reportFor(targetMonthIndex, 'Selected month transaction')
  let releaseMiaResponse: (() => void) | undefined
  const miaResponseReleased = new Promise<void>((resolve) => { releaseMiaResponse = resolve })

  await page.route('http://api.test/api/v1/spending_report**', (route) => {
    const startOn = new URL(route.request().url()).searchParams.get('start_on')
    return route.fulfill({ status: 200, json: { spending_report: startOn?.includes(`-${targetMonthNumber}-`) ? targetReport : currentReport } })
  })
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()
    await miaResponseReleased
    return route.fulfill({
      status: 200,
      json: {
        user_message: { id: 901, role: 'user', author: 'You', content: 'What should I focus on?', attachments: [] },
        assistant_message: { id: 902, role: 'assistant', author: 'Mia', content: 'Protect the baseline first.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: { ...currentReport, start_on: `${currentYear}-${currentMonthNumber}-01`, end_on: `${currentYear}-${currentMonthNumber}-28` },
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await page.getByRole('textbox', { name: 'Ask Mia', exact: true }).fill('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  await page.getByLabel('Report month').selectOption(String(targetMonthIndex))
  await page.getByText('Monthly activity and transactions', { exact: true }).click()
  await expect(page.getByText('Selected month transaction')).toBeVisible()

  const completedMiaResponse = page.waitForResponse((response) => response.url().endsWith('/api/v1/mia/messages') && response.request().method() === 'POST')
  releaseMiaResponse?.()
  await completedMiaResponse
  await expect(page.getByText('Selected month transaction')).toBeVisible()
  await expect(page.getByText('STALE MIA MONTH')).toHaveCount(0)
})

test('a same-month Mia response cannot undo a newer transaction refresh', async ({ page }) => {
  const currentMonthNumber = String(new Date().getMonth() + 1).padStart(2, '0')
  const reportShell = {
    period_label: `${currentMonth} ${currentYear}`,
    start_on: `${currentYear}-${currentMonthNumber}-01`,
    end_on: `${currentYear}-${currentMonthNumber}-28`,
    categories: [],
    transactions: [],
    pending_drafts: [],
  }
  const staleReport = { ...reportShell, totals: { planned: 5_300, actual: 0, pending: 75, remaining: 5_225 } }
  const refreshedReport = {
    ...reportShell,
    totals: { planned: 5_300, actual: 4_000, pending: 0, remaining: 1_300 },
    categories: [
      { id: 1, name: 'Fixed essentials', stack_key: 'non_discretionary', stack_label: 'Non-discretionary', planned: 4_000, actual: 3_500, pending: 0, remaining: 500, active: true },
      { id: 2, name: 'Dining out', stack_key: 'discretionary', stack_label: 'Discretionary', planned: 450, actual: 500, pending: 0, remaining: -50, active: true },
      { id: 3, name: 'Expected sinking fund', stack_key: 'sinking_expected', stack_label: 'Sinking Fund — Expected', planned: 600, actual: 0, pending: 0, remaining: 600, active: true },
      { id: 4, name: 'Unexpected sinking fund', stack_key: 'sinking_unexpected', stack_label: 'Sinking Fund — Unexpected', planned: 250, actual: 0, pending: 0, remaining: 250, active: true },
    ],
  }
  let spendingReportRequests = 0
  let releaseMiaResponse: (() => void) | undefined
  const miaResponseReleased = new Promise<void>((resolve) => { releaseMiaResponse = resolve })

  await page.route('http://api.test/api/v1/spending_report**', (route) => {
    spendingReportRequests += 1
    return route.fulfill({ status: 200, json: { spending_report: spendingReportRequests > 1 ? refreshedReport : staleReport } })
  })
  await page.route('http://api.test/api/v1/mia/messages', async (route) => {
    if (route.request().method() !== 'POST') return route.fallback()
    await miaResponseReleased
    return route.fulfill({
      status: 200,
      json: {
        user_message: { id: 911, role: 'user', author: 'You', content: 'What should I focus on?', attachments: [] },
        assistant_message: { id: 912, role: 'assistant', author: 'Mia', content: 'Review complete.', attachments: [] },
        transaction_draft: null,
        mia_action_draft: null,
        budget: null,
        spending_report: staleReport,
      },
    })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('link', { name: 'Ask Mia', exact: true }).click()
  await page.getByRole('textbox', { name: 'Ask Mia', exact: true }).fill('What should I focus on?')
  await page.getByRole('button', { name: 'Send message to Mia' }).click()
  await page.getByRole('link', { name: 'Budget', exact: true }).click()
  const transactionCard = page.locator('.transaction-draft-card').filter({ hasText: 'Dinner with friends' })
  await transactionCard.getByRole('button', { name: 'Confirm' }).click()
  const monthSummary = page.getByRole('region', { name: `${currentShortMonth} ${currentYear} plan position` })
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')

  const completedMiaResponse = page.waitForResponse((response) => response.url().endsWith('/api/v1/mia/messages') && response.request().method() === 'POST')
  releaseMiaResponse?.()
  await completedMiaResponse
  await expect(monthSummary.getByText('Confirmed actual', { exact: true }).locator('..')).toContainText('$4,000.00')
  await expect(monthSummary.getByText('Pending review', { exact: true }).locator('..')).toContainText('$0.00')
})

test('failed receipt upload leaves the participant on a retryable private-upload state', async ({ page }) => {
  await page.route('http://api.test/api/v1/document_imports/presign', (route) => route.fulfill({
    status: 200,
    json: {
      upload_url: 'https://private-storage.example/failed-upload',
      upload_headers: { 'Content-Type': 'image/png', 'x-amz-server-side-encryption': 'AES256' },
      upload_token: 'signed-upload-token',
    },
  }))
  await page.route('https://private-storage.example/failed-upload', (route) => route.fulfill({ status: 503, body: '' }))
  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('button', { name: 'Test a private upload' }).click()
  await expect(page.getByRole('heading', { name: 'Test one private file without changing your numbers.' })).toBeVisible()

  const receiptCard = page.locator('.document-upload-card').filter({ hasText: 'Receipt or quick evidence' })
  await receiptCard.locator('input[type="file"]').setInputFiles({
    name: 'receipt.png', mimeType: 'image/png', buffer: Buffer.from('not-a-real-financial-document'),
  })
  await expect(page.getByRole('alert')).toContainText('private file upload failed (503)')
  await expect(receiptCard.getByText('Choose file', { exact: true })).toBeVisible()
  await expect(receiptCard.locator('input[type="file"]')).toBeEnabled()
})

test('an empty Profile upload is rejected before private upload work begins', async ({ page }) => {
  let presignRequests = 0
  await page.route('http://api.test/api/v1/document_imports/presign', (route) => {
    presignRequests += 1
    return route.fulfill({ status: 500, json: { error: 'Empty files should not reach presign.' } })
  })

  await page.goto('/?pilot_e2e_role=participant')
  await page.getByRole('button', { name: 'Test a private upload' }).click()
  const receiptCard = page.locator('.document-upload-card').filter({ hasText: 'Receipt or quick evidence' })
  await receiptCard.locator('input[type="file"]').setInputFiles({
    name: 'empty-receipt.png',
    mimeType: 'image/png',
    buffer: Buffer.alloc(0),
  })

  await expect(page.getByRole('alert')).toHaveText('empty-receipt.png is empty. Choose the original file and try again.')
  await expect(receiptCard.getByText('Choose file', { exact: true })).toBeVisible()
  expect(presignRequests).toBe(0)
})
