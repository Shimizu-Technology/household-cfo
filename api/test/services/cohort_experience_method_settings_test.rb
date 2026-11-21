# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

# Each method setting goes live through the ordinary path (draft, preview, publish,
# seal, launch). A default and a changed value each prove what the participant
# sees and what Mia says, from the Rails facts Mia uses.
class CohortExperienceMethodSettingsTest < ActiveSupport::TestCase
  include PersonaTestHelper

  teardown { CohortReleases::RuntimeIntegrityCache.clear! }

  DEFAULTS = CohortExperience::MethodSettings::DEFAULTS

  test "schema five validates the method and keeps it compact and canonical" do
    schema = CohortExperience::Schema
    assert_empty schema.errors(schema::DEFAULT_CONFIG)
    assert_operator JSON.generate(schema::DEFAULT_CONFIG).bytesize, :<, 1_024
    shuffled = schema::DEFAULT_CONFIG.merge("method" => DEFAULTS.merge("protected" => DEFAULTS.fetch("protected").reverse).to_a.reverse.to_h)
    assert_equal schema.digest(schema::DEFAULT_CONFIG), schema.digest(shuffled)
    refute_equal schema.digest(schema::DEFAULT_CONFIG), schema.digest(method_config("priorities" => %w[debt emergency_fund wealth experiences]))

    {
      "status" => DEFAULTS.fetch("status").merge("target_yellow_months" => 12),
      "emergency_fund_months" => 0,
      "protected" => %w[housing housing],
      "priorities" => %w[emergency_fund debt wealth],
      "windfall" => %w[surplus surplus consumer_debt],
      "income_split" => { "emergency_fund" => 50, "debt" => 25, "surplus" => 20 }
    }.each do |key, value|
      refute_empty schema.errors(method_config(key => value)), key
    end
    refute_empty schema.errors(schema::DEFAULT_CONFIG.merge("method" => DEFAULTS.merge("extra" => 1)))
    refute_empty schema.errors(schema::DEFAULT_CONFIG.except("method"))
    refute_empty schema.errors(schema::DEFAULT_CONFIG.merge("schema_version" => 4))
    assert_empty schema.errors(method_config("protected" => []))
  end

  test "older schemas read as Mrs. Mel's defaults and upgrade to them" do
    schema = CohortExperience::Schema
    v4 = schema::DEFAULT_CONFIG.except("method").merge("schema_version" => 4, "module_order" => %w[budget home])
    assert_empty schema.errors(v4)
    assert_equal DEFAULTS, schema.method_for(v4)
    assert_equal DEFAULTS, schema.method_for(schema::LEGACY_CONFIG)
    upgraded = schema.upgrade(v4)
    assert_equal 5, upgraded.fetch("schema_version")
    assert_equal %w[budget home], upgraded.fetch("module_order")
    assert_equal v4.fetch("optional_modules"), upgraded.fetch("optional_modules")
    assert_equal DEFAULTS, upgraded.fetch("method")
    assert_equal DEFAULTS, CohortExperience::EffectiveCapabilitiesResolver.payload_for(config: v4, source: "preview", cohort_membership: nil, version: nil).fetch(:method)
  end

  test "status colours: the default rule, then a stricter rule after Go live" do
    participant, household = launch
    assert_equal [ "green", "yellow" ], tones(participant, household)
    assert_includes mia(household, "Why is my readiness green?"), "Your approved readiness is Green."
    assert_includes context(participant, household).dig("coaching_method", "status_colours"), "within 12 months, Yellow within 36 months"

    status = { "target_green_months" => 3, "target_yellow_months" => 5, "surplus_green_cents" => 80_000, "surplus_yellow_cents" => 40_000 }
    participant, household = launch("status" => status)
    assert_equal [ "red", "green" ], tones(participant, household)
    answer = mia(household, "Why is my readiness green?")
    assert_includes answer, "Your approved readiness is Red, not Green."
    assert_includes answer, "Green when it is within 3 months at your surplus, Yellow within 5 months"
    facts = context(participant, household)
    assert_includes facts.dig("coaching_method", "status_colours"), "within 3 months, Yellow within 5 months"
    assert_equal "Green — monthly surplus at or above $800", facts.dig("metrics", "monthly_surplus_status")
  end

  test "emergency fund target: three months by default, the program's months after Go live, the household's own goal over both" do
    participant, household = launch
    path = dashboard(participant, household).fetch(:readiness_path)
    assert_equal [ 3.0, "program", 5_300.0 ], [ path.fetch(:target_runway_months), path.fetch(:target_runway_source), path.dig(:emergency_fund, :gap) ]
    assert_includes mia(household, "Why is my readiness green?"), "3 months emergency fund target ($6,300) still needs $5,300"

    participant, household = launch("emergency_fund_months" => 6)
    path = dashboard(participant, household).fetch(:readiness_path)
    assert_equal [ 6.0, "program", 11_600.0, "yellow" ], [ path.fetch(:target_runway_months), path.fetch(:target_runway_source), path.dig(:emergency_fund, :gap), path.dig(:emergency_fund, :tone) ]
    assert_includes mia(household, "Why is my readiness yellow?"), "6 months emergency fund target ($12,600) still needs $11,600"
    assert_equal 6.0, context(participant, household).dig("metrics", "emergency_fund_target_months")

    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 4, priority: 1, record_kind: "policy", source_type: "setup")
    path = dashboard(participant, household.reload).fetch(:readiness_path)
    assert_equal [ 4.0, "household", 7_400.0 ], [ path.fetch(:target_runway_months), path.fetch(:target_runway_source), path.dig(:emergency_fund, :gap) ]
    assert_equal "household", context(participant, household).dig("metrics", "emergency_fund_target_set_by")
  end

  test "protected categories: family support is never a cut by default, and can be after Go live, while care stores stay protected" do
    participant, household = launch
    spend(household)
    assert_equal [ "Reef Coffee Co" ], SpendingPatterns::Analyzer.new(household, today: Date.new(2026, 11, 2)).call[:candidate_changes].pluck(:merchant)
    cut = cut_answer(household)
    refute_includes cut, "Island Fun Center"
    assert_includes cut, "I left out stores and categories that look like rent, bills, medical care, childcare or money for family."
    assert_includes context(participant, household).dig("coaching_method", "protected_categories"), "Family support"

    participant, household = launch("protected" => DEFAULTS.fetch("protected") - %w[family_support medical])
    spend(household)
    merchants = SpendingPatterns::Analyzer.new(household, today: Date.new(2026, 11, 2)).call[:candidate_changes].pluck(:merchant)
    assert_equal [ "Island Fun Center", "Reef Coffee Co" ], merchants
    # The clinic's store name keeps it protected even with medical categories unprotected.
    refute_includes merchants, "Harbor Family Clinic"
    cut = cut_answer(household)
    assert_includes cut, "Island Fun Center"
    assert_includes cut, "the categories your program protects: housing, utilities, childcare and school, and debt minimums"
    refute_includes context(participant, household).dig("coaching_method", "protected_categories"), "Family support"
  end

  test "priorities and windfalls: Mrs. Mel's order by default, the program's order after Go live" do
    participant, household = launch
    filter = presenter(participant, household).cfo_filter
    assert_equal [ "Emergency fund", "Debt acceleration", "Wealth building", "Experiences and life" ], filter.fetch(:priority_stack)
    assert_equal "Fill the emergency fund gap", filter.fetch(:windfall_steps).first
    assert_equal [ "50% to emergency fund", "25% to extra debt payments", "25% to surplus" ], filter.fetch(:income_split)
    assert_includes mia(household, "Emergency fund or debt first?"), "Savings comes first"
    windfall = mia(household, "I got a $6,000 bonus. What should I do with the bonus?")
    assert_includes windfall, "For $6,000, that is $5,300 to the emergency fund and $700 to consumer debt."
    assert_equal({ "Emergency fund" => "50%", "Debt acceleration" => "25%", "Surplus" => "25%" }, context(participant, household).dig("coaching_method", "new_monthly_income_split"))

    participant, household = launch("priorities" => %w[debt emergency_fund wealth experiences], "windfall" => %w[consumer_debt emergency_fund surplus],
      "income_split" => { "emergency_fund" => 20, "debt" => 60, "surplus" => 20 })
    filter = presenter(participant, household).cfo_filter
    assert_equal "Debt acceleration", filter.fetch(:priority_stack).first
    assert_equal [ "20% to emergency fund", "60% to extra debt payments", "20% to surplus" ], filter.fetch(:income_split)
    assert_includes mia(household, "Emergency fund or debt first?"), "So extra debt payments come before topping up savings."
    windfall = mia(household, "I got a $6,000 bonus. What should I do with the bonus?")
    assert_includes windfall, "1) pay down consumer debt (cards and loans, not the mortgage), 2) fill the emergency fund gap"
    assert_includes windfall, "For $6,000, that is $1,500 to consumer debt and $4,500 to the emergency fund."
    assert_equal [ "Debt acceleration", "Emergency fund", "Wealth building", "Experiences and life" ], context(participant, household).dig("coaching_method", "priority_order")
  end

  test "Home's month card shows both colours from the published rule" do
    participant, household = launch
    answer = dashboard(participant, household).fetch(:month_answer)
    assert_equal [ "green", "yellow" ], [ answer.fetch(:readiness_tone), answer.fetch(:surplus_tone) ]
    assert_match(/\AGreen: at this pace your emergency fund target is about 6 months away, within 12 months;/, answer.fetch(:readiness_guidance))

    participant, household = launch("status" => DEFAULTS.fetch("status").merge("target_green_months" => 3, "target_yellow_months" => 5))
    answer = dashboard(participant, household).fetch(:month_answer)
    assert_equal "red", answer.fetch(:readiness_tone)
    assert_match(/\ARed: at this pace your emergency fund target is about 6 months away, more than 5 months/, answer.fetch(:readiness_guidance))
    assert_match(/Red: at this pace/, HouseholdFinance::MiaMonthAnswer.for_question(household, "How am I doing this month?").response)
  end

  private

  def method_config(changes)
    CohortExperience::Schema::DEFAULT_CONFIG.merge("method" => DEFAULTS.merge(changes))
  end

  # A participant in a group whose method went live with the given changes.
  # Their household: $3,000 in, $2,100 planned out ($100 card minimum), $1,000 saved, $1,500 card debt.
  def launch(changes = {})
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(name: "Method group #{SecureRandom.hex(3)}", status: "active", created_by_user: owner, coach_workspace: workspace)
    persona = create_persona(creator: owner, workspace: workspace)
    CohortPersonaAssignment.create!(cohort: cohort, coach_workspace: workspace, coach_persona: persona,
      coach_persona_version: publish_persona(persona, actor: owner), assigned_by_user: owner)
    config = method_config(changes)
    configuration = cohort.cohort_experience_configuration
    configuration.update!(draft_config: config, last_edited_by_user: owner)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision, upgrade_to_current: true)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision,
      expected_current_version_id: configuration.current_published_version_id)
    participant = persona_user(role: "participant")
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    release = seal(cohort, owner)
    assert_equal 7, release.tool_registry_version
    launcher = CohortReleases::InitialLauncher.new(cohort: cohort, actor: owner)
    launcher.call!(release_id: release.id, preview_digest: launcher.preview.fetch(:preview_digest), request_key: "launch-#{SecureRandom.hex(4)}")
    assert_equal DEFAULTS.merge(changes), Mia::ParticipantRuntimeResolver.new(user: participant).call.capabilities.fetch(:method)
    [ participant, household_for(participant) ]
  end

  def seal(cohort, owner)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.release.seal", operation_version: 2,
      input: {
        expected_assignment_id: candidate.assignment.id, expected_bundle_digest: candidate.bundle_digest,
        expected_experience_version_id: candidate.experience_version.id,
        expected_latest_release_id: cohort.cohort_releases.order(release_number: :desc).pick(:id),
        expected_persona_version_id: candidate.persona_version.id, expected_brand_version_id: candidate.brand_version&.id,
        expected_tool_registry_digest: CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
        expected_tool_registry_version: candidate.tool_registry_snapshot.fetch("schema_version")
      }, request_key: "seal-#{SecureRandom.hex(4)}"
    ).release
  end

  def household_for(participant)
    household = Household.create!(created_by_user: participant, name: "Talun household", primary_goal: "Build the emergency fund",
      confirmed_setup_fields: HouseholdFinance::SetupStatus::REQUIRED_FIELDS.map(&:to_s))
    household.household_memberships.create!(user: participant, role: "owner")
    household.income_sources.create!(label: "Primary income", source_type: "job", amount_cents: 300_000, cadence: "monthly")
    household.expense_items.create!(label: "Fixed essentials", stack_key: "non_discretionary", amount_cents: 200_000, cadence: "monthly")
    household.accounts.create!(label: "Emergency fund", account_type: "emergency_fund", balance_cents: 100_000)
    household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 150_000, debt_summary_minimum_payment_cents: 10_000,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true)
    household
  end

  def presenter(participant, household)
    HouseholdFinance::DataPresenter.new(household, user: participant)
  end

  def dashboard(participant, household) = presenter(participant, household).dashboard

  def tones(participant, household)
    path = dashboard(participant, household).fetch(:readiness_path)
    [ path.dig(:emergency_fund, :tone), path.dig(:surplus, :tone) ]
  end

  def mia(household, message)
    HouseholdFinance::MiaCoachAnswerer.new(household, message).call.to_s
  end

  def context(participant, household)
    capabilities = Mia::ParticipantRuntimeResolver.new(user: participant).call.capabilities
    JSON.parse(HouseholdFinance::MiaContextBuilder.new(household, experience_capabilities: capabilities).call)
  end

  def cut_answer(household)
    travel_to(Time.zone.local(2026, 11, 2, 12)) do
      SpendingPatterns::Answerer.new(household: household, message: "What should I cut first?", persona: Mia::Persona.neutral, history: [], approved_content: []).call
    end
  end

  # Two months at a family fun center filed under "Family outings", a coffee shop and a clinic, all as flexible spending.
  def spend(household)
    family = household.budget_categories.create!(name: "Family outings", stack_key: "discretionary", sort_order: 1)
    medical = household.budget_categories.create!(name: "Medical visits", stack_key: "discretionary", sort_order: 2)
    dining = household.budget_categories.create!(name: "Eating out", stack_key: "discretionary", sort_order: 3)
    [ Date.new(2026, 9, 14), Date.new(2026, 10, 14) ].each do |date|
      purchase(household, date, "Island Fun Center", 12_000, family)
      purchase(household, date, "Harbor Family Clinic", 20_000, medical)
      purchase(household, date, "Reef Coffee Co", 9_000, dining)
    end
  end

  def purchase(household, date, merchant, cents, category)
    year = household.budget_years.find_or_create_by!(year: date.year)
    period = year.budget_periods.find_or_create_by!(starts_on: date.beginning_of_month) { |row| row.ends_on = date.end_of_month }
    row = household.household_transactions.create!(budget_period: period, occurred_on: date, merchant: merchant, total_amount_cents: cents, source_type: "statement", status: "confirmed")
    row.transaction_splits.create!(budget_category: category, amount_cents: cents)
  end
end
