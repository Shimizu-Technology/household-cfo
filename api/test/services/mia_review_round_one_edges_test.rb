require "test_helper"
require_relative "../support/persona_test_helper"

class MiaReviewRoundOneEdgesTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    travel_to Time.zone.local(2026, 11, 5, 12)
    @user = User.create!(clerk_id: "edges_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Cruz", primary_goal: "Build a cushion", primary_income: "2000", fixed_expenses: "2100", flexible_spend: "900", debt_payment: "95").call
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household)
  end
  teardown { travel_back }

  test "review one roster loads debt records without multiplying its participant join" do
    coach = User.create!(clerk_id: "coach_#{SecureRandom.hex(8)}", email: "#{SecureRandom.hex(8)}@example.invalid", role: "coach", invitation_status: "accepted")
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    cohort = Cohort.create!(name: "Review roster", status: "active", created_by_user: coach, coach_workspace: workspace)
    cohort.cohort_memberships.create!(user: @user, role: "participant")
    queries = []
    capture = ->(*args) { queries << args.last[:sql] }
    result = ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { ChallengePrivacy::CoachDailyRoster.new(cohort, user: coach).call }
    assert_equal 1, result[:counts]["setup_done"]
    refute queries.any? { |sql| sql.match?(/JOIN "debts"/) }, queries.grep(/JOIN "debts"/).join("\n")
  end

  test "recurring bills savings and job changes never become a one time purchase" do
    [ "Can I afford $300 a month for a car payment?", "Can I afford rent of $900?", "Can I afford to quit my job for $300?", "Can I afford to save $300?", "Can I afford a $400 monthly car lease?" ].each do |message|
      answer = HouseholdFinance::MiaCoachAnswerer.new(@household, message).call
      refute_match(/The \$.*purchase|plan figure for Monthly/i, answer.to_s, message)
      result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: "").deterministic_scenario_result
      assert_nil result, message
    end
  end

  test "negative plan names its shortfall without a negative leaves figure" do
    answer = HouseholdFinance::MiaHypotheticalScenarioAnswerer.new(@household, scenario_type: "purchase", amount: "300", label: "Stroller", annual_budget_manager: @manager, reference_month: 11).call.body
    assert_includes answer, "short by $1,095"
    refute_match(/leaves -\$|plan figure for Stroller/, answer)
  end

  test "food verb forms and contractions recognize hunger but meeting lunch does not" do
    [ "I've been skipping meals so the kids could eat", "I haven't eaten in two days", "I skip meals to feed my kids", "We’ve been missing meals so our children can eat" ].each do |text|
      assert HouseholdFinance::MoneyMovementText.food_insecurity?(text), text
    end
    refute HouseholdFinance::MoneyMovementText.food_insecurity?("I skipped lunch for a meeting")
  end

  test "partly covered year names coverage without a whole year comparison" do
    report = HouseholdFinance::SpendingReport.new(@household, start_on: Date.new(2026, 1, 1), end_on: Date.new(2026, 12, 31), ensure_plans: false).as_json
    answer = HouseholdFinance::SpendingReportNarrator.new(report, prompt: "How did I do this year?").call
    assert_includes answer, "partly covered"
    assert_includes answer, "November 2026"
    refute_includes answer, "2026 has no plan"
  end

  test "pending only merchant and category questions preserve the requested pending detail" do
    category = @household.budget_categories.active.find_by!(stack_key: "discretionary")
    @household.transaction_drafts.create!(merchant: "Penny Cafe", total_amount_cents: 1250, occurred_on: Date.current, budget_category: category, status: "pending", source_type: "manual_chat")
    report = HouseholdFinance::SpendingReport.new(@household, start_on: Date.current.beginning_of_month, end_on: Date.current, ensure_plans: false).as_json
    [ "How much at Penny Cafe?", "What about #{category.name}?" ].each do |question|
      answer = HouseholdFinance::SpendingReportNarrator.new(report, prompt: question).call
      assert_includes answer, "$12.50", question
      assert_match(/review/, answer)
      refute_match(/\$0.*confirmed spending|confirmed spending.*\$0/, answer)
    end
  end

  test "explicit household category is not part of the merchant even for an unknown store" do
    category = @household.budget_categories.active.find_by!(stack_key: "discretionary")
    category.update!(name: "Everyday spending")
    [ "Penny Cafe", "Village Market" ].each do |merchant|
      draft = HouseholdFinance::TransactionDraftBuilder.new(@household, "I spent $12.50 at #{merchant} for Everyday spending today", user: @user).call
      assert draft
      assert_equal merchant, draft.merchant
      assert_equal category.id, draft.budget_category_id
      assert_equal 1250, draft.total_amount_cents
    end
    assert_empty @household.household_transactions
  end

  test "preview length rejection names length and never invents the chosen method" do
    responder = Object.new
    responder.define_singleton_method(:call) { |*_, **_| "unused" }
    responder.define_singleton_method(:response_source) { "deterministic_fallback" }
    responder.define_singleton_method(:fallback_reason) { :reply_rejected }
    responder.define_singleton_method(:rejection_reason) { :persona_response_shape }
    result = Mia::PersonaPreviewer.new(persona: create_persona, sample_prompt: "Help me decide", responder: responder).call
    assert_includes result[:notice], "response length"
    assert_includes result[:notice], "one rewrite"
    refute_includes result[:notice], "direct-answer-first"
    refute_includes result[:notice], "safety and accuracy"
  end
end
