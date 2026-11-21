# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

# Each method setting goes live through the ordinary path (draft, preview, publish,
# seal, launch). A default and a changed value each prove what the participant
# sees and what Mia says, from the Rails facts Mia uses.
class CohortExperienceMethodSettingsTest < ActiveSupport::TestCase
  include PersonaTestHelper

  teardown { CohortReleases::RuntimeIntegrityCache.clear! }

  DEFAULTS = CohortExperience::MethodSettings.defaults.freeze

  test "schema five validates the method and keeps it compact and canonical" do
    schema = CohortExperience::Schema
    assert_empty schema.errors(schema::DEFAULT_CONFIG)
    assert_operator JSON.generate(schema::DEFAULT_CONFIG).bytesize, :<, 1_024
    stored = CohortExperience::MethodSettings::DEFAULTS
    shuffled = schema::DEFAULT_CONFIG.merge("method" => stored.merge("protected" => stored.fetch("protected").reverse).to_a.reverse.to_h)
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
    # The core protections stay; a program can only add to them.
    assert_includes schema.errors(method_config("protected" => [])), CohortExperience::MethodSettings::PROTECTED_CORE_MESSAGE
    assert_includes schema.errors(method_config("protected" => DEFAULTS.fetch("protected") - %w[medical])), CohortExperience::MethodSettings::PROTECTED_CORE_MESSAGE
    assert_empty schema.errors(method_config("protected" => DEFAULTS.fetch("protected") + %w[groceries giving community]))
    # A list of the wrong types is reported, never raised while sorting.
    [ [ "debt", 1, nil, {} ], [ nil ], [ 1, 2, 3, 4 ] ].each do |value|
      assert_includes schema.errors(method_config("priorities" => value)), "method.priorities must order every priority once"
      assert_includes schema.errors(method_config("windfall" => value)), "method.windfall must order every windfall step once"
    end
    assert_includes schema.errors(method_config("protected" => [ "housing", 1, nil ])), "method.protected must list unique supported categories"
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
    assert_includes mia(household, "Why is my readiness green?"), "3-month emergency fund target ($6,300) still needs $5,300"

    participant, household = launch("emergency_fund_months" => 6)
    path = dashboard(participant, household).fetch(:readiness_path)
    assert_equal [ 6.0, "program", 11_600.0, "yellow" ], [ path.fetch(:target_runway_months), path.fetch(:target_runway_source), path.dig(:emergency_fund, :gap), path.dig(:emergency_fund, :tone) ]
    assert_includes mia(household, "Why is my readiness yellow?"), "6-month emergency fund target ($12,600) still needs $11,600"
    assert_equal 6.0, context(participant, household).dig("metrics", "emergency_fund_target_months")

    household.goals.create!(label: "Runway target", goal_type: "runway", target_months: 4, priority: 1, record_kind: "policy", source_type: "setup")
    path = dashboard(participant, household.reload).fetch(:readiness_path)
    assert_equal [ 4.0, "household", 7_400.0 ], [ path.fetch(:target_runway_months), path.fetch(:target_runway_source), path.dig(:emergency_fund, :gap) ]
    assert_equal "household", context(participant, household).dig("metrics", "emergency_fund_target_set_by")
  end

  test "protected categories: the core list always holds, and a program can add groceries" do
    participant, household = launch
    spend(household)
    assert_equal [ "Payless Market", "Reef Coffee Co" ], cut_candidates(household)
    cut = cut_answer(household)
    refute_includes cut, "Island Fun Center"
    assert_includes cut, "I left out stores and categories that look like rent, bills, medical care, childcare or money for family."
    assert_equal CohortExperience::MethodSettings::CORE_PROTECTED.map { |key| CohortExperience::MethodSettings.label(key) },
      context(participant, household).dig("coaching_method", "protected_categories")

    participant, household = launch("protected" => DEFAULTS.fetch("protected") + %w[groceries])
    spend(household)
    assert_equal [ "Reef Coffee Co" ], cut_candidates(household)
    cut = cut_answer(household)
    refute_includes cut, "Payless Market"
    refute_includes cut, "Island Fun Center"
    assert_includes cut, "money for family, and the groceries your program also protects."
    assert_includes context(participant, household).dig("coaching_method", "protected_categories"), "Groceries"
  end

  test "a published method missing a core protection still protects it" do
    _participant, household = launch
    spend(household)
    analyzer = SpendingPatterns::Analyzer.new(household, today: Date.new(2026, 11, 2), protected: %w[groceries])
    merchants = analyzer.call[:candidate_changes].pluck(:merchant)
    assert_equal [ "Reef Coffee Co" ], merchants
    assert_equal CohortExperience::MethodSettings::CORE_PROTECTED + %w[groceries], analyzer.protected_categories
  end

  test "priorities and windfalls: Mrs. Mel's order by default, the program's order after Go live" do
    participant, household = launch
    filter = presenter(participant, household).cfo_filter
    assert_equal [ "Emergency fund", "Debt acceleration", "Wealth building", "Experiences and life" ], filter.fetch(:priority_stack).map { |entry| entry.split(" · ").first }
    assert_equal %w[green unknown unknown yellow], filter.fetch(:priority_stack).map { |entry| entry.split(" · ").last }
    assert_equal "Fill the emergency fund gap", filter.fetch(:windfall_steps).first
    assert_equal [ "50% to emergency fund", "25% to extra debt payments", "25% to surplus" ], filter.fetch(:income_split)
    assert_includes mia(household, "Emergency fund or debt first?"), "Savings comes first"
    windfall = mia(household, "I got a $6,000 bonus. What should I do with the bonus?")
    assert_includes windfall, "For $6,000, that is $5,300 to the emergency fund and $700 to consumer debt."
    assert_equal({ "Emergency fund" => "50%", "Debt acceleration" => "25%", "Surplus" => "25%" }, context(participant, household).dig("coaching_method", "new_monthly_income_split"))

    participant, household = launch("priorities" => %w[debt emergency_fund wealth experiences], "windfall" => %w[consumer_debt emergency_fund surplus],
      "income_split" => { "emergency_fund" => 20, "debt" => 60, "surplus" => 20 })
    filter = presenter(participant, household).cfo_filter
    assert_equal [ "Debt acceleration", "Emergency fund", "Wealth building", "Experiences and life" ], filter.fetch(:priority_stack).map { |entry| entry.split(" · ").first }
    assert_equal %w[unknown yellow unknown red], filter.fetch(:priority_stack).map { |entry| entry.split(" · ").last }
    assert_equal [ "20% to emergency fund", "60% to extra debt payments", "20% to surplus" ], filter.fetch(:income_split)
    assert_includes mia(household, "Emergency fund or debt first?"), "So extra debt payments come before topping up savings."
    windfall = mia(household, "I got a $6,000 bonus. What should I do with the bonus?")
    assert_includes windfall, "1) pay down consumer debt (cards and loans, not the mortgage), 2) fill the emergency fund gap"
    assert_includes windfall, "For $6,000, that is $1,500 to consumer debt and $4,500 to the emergency fund."
    assert_equal [ "Debt acceleration", "Emergency fund", "Wealth building", "Experiences and life" ], context(participant, household).dig("coaching_method", "priority_order")
  end

  test "a raise: Rails splits the named amount by the program's percentages, Mia never does the arithmetic" do
    _participant, household = launch
    answer = mia(household, "I got a $400 raise, how should I split it?")
    assert_includes answer, "Your program splits new monthly income 50% to the emergency fund, 25% to extra debt payments, and 25% kept as surplus."
    assert_includes answer, "For $400 more a month that is $200 to the emergency fund, $100 to extra debt payments, and $100 kept as surplus."
    assert_includes answer, "set up the $200 transfer to the emergency fund"
    yearly = mia(household, "My husband got a $5,000 a year raise. Where should it go?")
    assert_includes yearly, "For a $5,000 yearly raise, about $416.67 a month, that is $208.35 to the emergency fund, $104.16 to extra debt payments, and $104.16 kept as surplus."
    assert_includes mia(household, "I got a raise! How should I split it?"), "tell me how much more lands in your account each month"
    refute_includes mia(household, "Should I raise the groceries category to $500?").to_s, "new monthly income"

    _participant, household = launch("income_split" => { "emergency_fund" => 0, "debt" => 70, "surplus" => 30 })
    answer = mia(household, "I got a $400 raise, how should I split it?")
    assert_includes answer, "Your program splits new monthly income 70% to extra debt payments and 30% kept as surplus."
    assert_includes answer, "For $400 more a month that is $280 to extra debt payments and $120 kept as surplus."
  end

  test "one-time money waits on the debt step when debts are one summary total or not listed" do
    _participant, household = launch
    household.debts.destroy_all
    household.household_profile.update!(debt_tracking_mode: "summary", debt_summary_balance_cents: 150_000, debt_summary_minimum_payment_cents: 10_000,
      debt_summary_balance_known: true, debt_summary_minimum_payment_known: true)
    windfall = mia(household, "I got a $6,000 bonus. What should I do with the bonus?")
    assert_includes windfall, "For $6,000, that is $5,300 to the emergency fund and $700 waits on the debt step: list your cards and loans (not the mortgage) in My Money so I can size it."

    # A confirmed $0 total (and no minimum, so the target is $6,000 and the gap $5,000) spills to surplus.
    household.household_profile.update!(debt_summary_balance_cents: 0, debt_summary_minimum_payment_cents: 0)
    assert_includes mia(household, "I got a $6,000 bonus. What should I do with the bonus?"), "For $6,000, that is $5,000 to the emergency fund and $1,000 kept as surplus."
  end

  test "Home's month card shows both colours from the published rule" do
    participant, household = launch
    answer = dashboard(participant, household).fetch(:month_answer)
    assert_equal [ "green", "yellow" ], [ answer.fetch(:readiness_tone), answer.fetch(:surplus_tone) ]
    assert_match(/\AGreen: at this pace your emergency fund target is about 6 months away, within 12 months;/, answer.fetch(:readiness_guidance))

    assert_includes dashboard(participant, household).dig(:coach_read, :body), "within 12 months at your current surplus"
    participant, household = launch("status" => DEFAULTS.fetch("status").merge("target_green_months" => 7, "target_yellow_months" => 20))
    assert_includes dashboard(participant, household).dig(:coach_read, :body), "within 7 months at your current surplus"
    refute_includes dashboard(participant, household).dig(:coach_read, :body), "this year"

    participant, household = launch("status" => DEFAULTS.fetch("status").merge("target_green_months" => 3, "target_yellow_months" => 5))
    answer = dashboard(participant, household).fetch(:month_answer)
    assert_equal "red", answer.fetch(:readiness_tone)
    assert_match(/\ARed: at this pace your emergency fund target is about 6 months away, more than 5 months/, answer.fetch(:readiness_guidance))
    assert_match(/Red: at this pace/, HouseholdFinance::MiaMonthAnswer.for_question(household, "How am I doing this month?").response)
  end

  test "a household's program comes from its owner or partner, never a coach viewing it, once per request" do
    participant, own_household = launch("emergency_fund_months" => 6)
    owner = persona_user(role: "participant")
    household = Household.create!(created_by_user: owner, name: "Viewed household", primary_goal: "Build the emergency fund")
    household.household_memberships.create!(user: owner, role: "owner")
    household.household_memberships.create!(user: participant, role: "coach_viewer")
    settings = CohortExperience::MethodSettings
    settings::Current.reset
    assert_equal 3, settings.for_household(household).fetch("emergency_fund_months")

    household.household_memberships.find_by!(user: participant).update!(role: "partner")
    settings::Current.reset
    assert_equal 3, settings.for_household(household).fetch("emergency_fund_months"), "the owner's program comes first"
    assert_equal 6, settings.for_household(household, user: participant).fetch("emergency_fund_months"), "the asking partner's program"

    # The year's income answer reads twelve months; the program is resolved once.
    settings::Current.reset
    HouseholdFinance::MiaIncomeAnswer.new(own_household, message: "How much came in this year?").response
    assert_equal 1, settings::Current.cache.size
  end

  test "display choices are optional in schema five: a block without them keeps its digest and reads as the defaults" do
    schema = CohortExperience::Schema
    stored = schema::DEFAULT_CONFIG
    with_defaults = stored.merge("method" => stored.fetch("method").merge(CohortExperience::MethodSettings::OPTIONAL_DEFAULTS))
    assert_empty schema.errors(with_defaults)
    refute_equal schema.digest(stored), schema.digest(with_defaults), "a block that carries them is its own config"
    assert_equal schema.normalize(stored), schema.normalize(stored.deep_dup), "a block without them normalizes without them"
    refute schema.normalize(stored).fetch("method").key?("group_names")
    assert_equal DEFAULTS, schema.method_for(stored)
    { "group_names" => "fancy", "home_view" => "week", "debt_order" => "biggest" }.each do |key, value|
      assert_includes schema.errors(method_config(key => value)), "method.#{key} must be one of #{CohortExperience::MethodSettings::CHOICES.fetch(key).join(', ')}"
    end
    assert_operator JSON.generate(with_defaults).bytesize, :<, 1_024
  end

  test "challenge rules are optional in schema five: 90 days in thirds, a $500 suggestion, savings only; a coach's values are checked" do
    schema = CohortExperience::Schema
    settings = CohortExperience::MethodSettings
    stored = schema::DEFAULT_CONFIG
    assert_equal settings::CHALLENGE_DEFAULTS, schema.method_for(stored).fetch("challenge")
    refute schema.normalize(stored).fetch("method").key?("challenge"), "a block without it keeps its bytes and digest"
    assert_equal SavingsChallenge::Rules.new(length_days: 90, checkpoint_days: [ 30, 60, 90 ], suggested_goal_cents: 50_000, counts: "savings"), SavingsChallenge::Rules.default
    assert_equal "90-day Savings Challenge", schema.mode_payload(schema::PILOT_SAVINGS_CONFIG).fetch(:label)

    short = { "length_days" => 60, "checkpoints" => "thirds", "suggested_goal_cents" => 30_000, "counts" => "savings_and_debt" }
    config = method_config("challenge" => short).merge("experience_mode" => "savings_challenge")
    assert_empty schema.errors(config)
    assert_equal schema.digest(config), schema.digest(config.merge("method" => config.fetch("method").merge("challenge" => short.to_a.reverse.to_h)))
    assert_equal [ 20, 40, 60 ], SavingsChallenge::Rules.from_setting(short).checkpoint_days
    assert_equal [ 33, 67, 100 ], settings.checkpoint_days(short.merge("length_days" => 100))
    assert_equal [ 10, 20, 30 ], settings.checkpoint_days(short.merge("length_days" => 30))
    assert_equal [ 14, 45, 60 ], SavingsChallenge::Rules.from_setting(short.merge("checkpoints" => [ 14, 45, 60 ])).checkpoint_days
    assert_equal "60-day Savings Challenge", schema.mode_payload(config).fetch(:label)
    assert_equal "Day 20, 40 and 60", SavingsChallenge::Rules.from_setting(short).checkpoint_text

    {
      { "length_days" => 29 } => "method.challenge.length_days must be a whole number of days from 30 to 180",
      { "length_days" => 181 } => "method.challenge.length_days must be a whole number of days from 30 to 180",
      { "checkpoints" => [ 20, 40 ] } => "method.challenge.checkpoints must be thirds or 1 to 6 increasing days that end on the last day",
      { "checkpoints" => [ 40, 20, 60 ] } => "method.challenge.checkpoints must be thirds or 1 to 6 increasing days that end on the last day",
      { "checkpoints" => [ 0, 60 ] } => "method.challenge.checkpoints must be thirds or 1 to 6 increasing days that end on the last day",
      { "checkpoints" => (10..60).step(10).to_a.unshift(5) } => "method.challenge.checkpoints must be thirds or 1 to 6 increasing days that end on the last day",
      { "suggested_goal_cents" => 9_900 } => "method.challenge.suggested_goal_cents must be whole dollars from $100 to $5,000",
      { "suggested_goal_cents" => 30_050 } => "method.challenge.suggested_goal_cents must be whole dollars from $100 to $5,000",
      { "counts" => "everything" } => "method.challenge.counts must be one of savings, savings_and_debt"
    }.each do |change, message|
      assert_includes schema.errors(method_config("challenge" => short.merge(change))), message, change.inspect
    end
    assert_includes schema.errors(method_config("challenge" => short.except("counts"))), "method.challenge must contain length_days, checkpoints, suggested_goal_cents, counts"
    assert_operator JSON.generate(config).bytesize, :<, 1_024
  end

  test "expense group names: plain words by default, her method's terms after Go live, with the same totals" do
    participant, household = launch
    household.budget_categories.create!(name: "Gifts", stack_key: "sinking_expected", sort_order: 1)
    plain = group_view(participant, household)
    assert_equal [ "Must-pay bills", "Flexible spending", "Planned yearly costs", "Surprise fund" ], plain.fetch(:stacks).keys
    assert_equal "Planned yearly costs", plain.fetch(:gifts_group)
    assert_includes mia(household, "Where do planned gifts go in a sinking fund?"), "Planned gifts belong in planned yearly costs; surprise gifts belong in flexible spending."
    assert_equal plain.fetch(:stacks).keys, context(participant, household).dig("coaching_method", "expense_group_names")

    participant, household = launch("group_names" => "method")
    household.budget_categories.create!(name: "Gifts", stack_key: "sinking_expected", sort_order: 1)
    terms = group_view(participant, household)
    assert_equal [ "Non-discretionary", "Discretionary", "Sinking Fund — Expected", "Sinking Fund — Unexpected" ], terms.fetch(:stacks).keys
    assert_equal "Sinking Fund — Expected", terms.fetch(:gifts_group)
    assert_equal plain.fetch(:stacks).values, terms.fetch(:stacks).values, "labels only; every total stays the same"
    assert_includes mia(household, "Where do planned gifts go in a sinking fund?"), "Planned gifts belong in Sinking Fund — Expected; surprise gifts belong in Discretionary."
    assert_equal terms.fetch(:stacks).keys, context(participant, household).dig("coaching_method", "expense_group_names")
  end

  test "home view: month first by default, year first after Go live, and her own saved choice wins" do
    participant, household = launch
    assert_equal({ program: "month", chosen: nil, effective: "month" }, presenter(participant, household).workspace.fetch(:home_view))
    assert_includes context(participant, household).dig("coaching_method", "home_program_default"), "Home leads with this month"

    participant, household = launch("home_view" => "year")
    assert_equal({ program: "year", chosen: nil, effective: "year" }, presenter(participant, household).workspace.fetch(:home_view))
    assert_includes context(participant, household).dig("coaching_method", "home_program_default"), "Home leads with the year outlook"

    household.household_memberships.find_by!(user: participant).update!(home_view: "month")
    assert_equal({ program: "year", chosen: "month", effective: "month" }, presenter(participant, household).workspace.fetch(:home_view))
  end

  test "debt payoff: snowball and avalanche side by side by default; the program's order leads after Go live" do
    participant, household = launch
    two_debts(household)
    answer = mia(household, DEBT_QUESTION)
    assert_includes answer, "Avalanche: Island Visa first, $1,500 balance, 22% APR. Snowball: Marianas Auto Loan first, $800 balance."
    assert_includes answer, "3. Choose one and send a fixed amount from the current monthly surplus. Avalanche: up to $850 to Island Visa for lower interest cost. Snowball: up to $750 to Marianas Auto Loan for the fastest closed balance."
    assert_includes context(participant, household).dig("coaching_method", "debt_payoff_order"), "side by side"

    participant, household = launch("debt_order" => "snowball")
    two_debts(household)
    answer = mia(household, DEBT_QUESTION)
    assert_includes answer, "Snowball: Marianas Auto Loan first, $800 balance. Avalanche: Island Visa first, $1,500 balance, 22% APR."
    assert_includes answer, "3. Send a fixed amount of up to $750 from the current monthly surplus to Marianas Auto Loan; your program starts with snowball (smallest balance first); avalanche would start with Island Visa for lower interest cost."
    assert_includes context(participant, household).dig("coaching_method", "debt_payoff_order"), "Lead with snowball"

    participant, household = launch("debt_order" => "avalanche")
    two_debts(household)
    answer = mia(household, DEBT_QUESTION)
    assert_includes answer, "Avalanche: Island Visa first, $1,500 balance, 22% APR. Snowball: Marianas Auto Loan first, $800 balance."
    assert_includes answer, "3. Send a fixed amount of up to $850 from the current monthly surplus to Island Visa; your program starts with avalanche (highest APR first); snowball would start with Marianas Auto Loan for the fastest closed balance."
  end

  private

  DEBT_QUESTION = "Compare debt avalanche and snowball and tell me which card to pay first."

  # The Island Visa gets an APR, and a smaller, cheaper car loan joins it: avalanche and snowball differ.
  def two_debts(household)
    household.debts.find_by!(label: "Island Visa").update!(interest_rate_percent: 22)
    household.debts.create!(label: "Marianas Auto Loan", debt_type: "auto_loan", balance_cents: 80_000, minimum_payment_cents: 5_000, interest_rate_percent: 6)
  end

  # The Budget groups (name => planned dollars) and the group a category shows under.
  def group_view(participant, household)
    budget = presenter(participant, household).budget
    gifts = budget.dig(:annual_plan, :rows).find { |row| row.fetch(:name) == "Gifts" }
    { stacks: budget.fetch(:stacks).to_h { |stack| [ stack.fetch(:label), stack.fetch(:amount) ] }, gifts_group: gifts.fetch(:stack_label) }
  end

  def method_config(changes)
    CohortExperience::Schema::DEFAULT_CONFIG.merge("method" => DEFAULTS.merge(changes))
  end

  # A participant in a group whose method went live with the given changes.
  # Their household: $3,000 in, $2,100 planned out ($100 card minimum), $1,000 saved, a $1,500 card listed.
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
    household.debts.create!(label: "Island Visa", debt_type: "credit_card", balance_cents: 150_000, minimum_payment_cents: 10_000)
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

  def cut_candidates(household)
    SpendingPatterns::Analyzer.new(household, today: Date.new(2026, 11, 2)).call[:candidate_changes].pluck(:merchant)
  end

  # Two months at a family fun center filed under "Family outings", a clinic, a market under "Groceries"
  # and a coffee shop, all as flexible spending.
  def spend(household)
    family = household.budget_categories.create!(name: "Family outings", stack_key: "discretionary", sort_order: 1)
    medical = household.budget_categories.create!(name: "Medical visits", stack_key: "discretionary", sort_order: 2)
    dining = household.budget_categories.create!(name: "Eating out", stack_key: "discretionary", sort_order: 3)
    groceries = household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 4)
    [ Date.new(2026, 9, 14), Date.new(2026, 10, 14) ].each do |date|
      purchase(household, date, "Island Fun Center", 12_000, family)
      purchase(household, date, "Harbor Family Clinic", 20_000, medical)
      purchase(household, date, "Payless Market", 15_000, groceries)
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
