require "test_helper"

class HouseholdFinanceMiaEvalHarnessTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  test "curated real-world Mia eval cases pass through deterministic Rails routes" do
    travel_to Time.zone.local(2026, 7, 15, 12) do
      cases = HouseholdFinance::MiaEvalHarness.load_cases
      result = HouseholdFinance::MiaEvalHarness.new(cases: cases, runner: method(:run_controller_case)).call

      assert result.passed?, failure_summary(result)
      assert_equal cases.length, result.total_count
      assert_operator result.passed_count, :>=, 10
    end
  end

  test "harness reports missing expected phrases and forbidden matches" do
    cases = [
      {
        "id" => "sample_failure",
        "prompt" => "Can I buy the thing?",
        "expected_phrases" => [ "expected guardrail" ],
        "forbidden_phrases" => [ "unsafe approval" ]
      }
    ]
    result = HouseholdFinance::MiaEvalHarness.new(cases: cases, runner: ->(_eval_case) { "unsafe approval" }).call
    failure = result.failures.first

    refute result.passed?
    assert_equal "sample_failure", failure.id
    assert_equal [ "expected guardrail" ], failure.missing_phrases
    assert_equal [ "unsafe approval" ], failure.forbidden_matches
  end

  private

  def run_controller_case(eval_case)
    user, household = create_eval_user_and_household
    messages = Array(eval_case["messages"]).presence || [ eval_case.fetch("prompt") ]
    final_content = nil

    messages.each do |message|
      post "/api/v1/mia/messages",
        params: { message: message, year: 2026, month: 7 },
        headers: auth_headers(user),
        as: :json
      assert_response :created
      final_content = JSON.parse(response.body).fetch("assistant_message").fetch("content")
    end

    {
      response: final_content,
      metadata: {
        pending_draft_count: household.transaction_drafts.pending.count,
        confirmed_transaction_count: household.household_transactions.where(status: "confirmed").count
      }
    }
  end

  def failure_summary(result)
    result.failures.map do |failure|
      <<~SUMMARY.squish
        #{failure.id}: missing=#{failure.missing_phrases.inspect} forbidden=#{failure.forbidden_matches.inspect} error=#{failure.error.inspect} response=#{failure.response.inspect}
      SUMMARY
    end.join("\n")
  end

  def create_eval_user_and_household
    user = User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(6)}",
      email: "mia-eval-#{SecureRandom.hex(6)}@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    household = Household.create!(
      created_by_user: user,
      name: "Mia Eval Household",
      primary_goal: "Keep the household calm and honest."
    )
    household.household_memberships.create!(user: user, role: "owner")
    seed_household!(household)
    [ user, household ]
  end

  def seed_household!(household)
    HouseholdFinance::SetupUpdater.new(
      household,
      household_name: "Mia Eval Household",
      primary_goal: "Build a calm money rhythm.",
      primary_income: 8_000,
      business_income: 0,
      fixed_expenses: 4_000,
      flexible_spend: 1_000,
      expected_sinking_fund: 300,
      unexpected_sinking_fund: 200,
      emergency_fund: 8_000,
      credit_card_debt: 2_000,
      debt_payment: 150,
      target_runway_months: 6
    ).call

    manager = HouseholdFinance::AnnualBudgetManager.new(household, year: 2026)
    dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 310)
    software = manager.create_category!(name: "Software", stack_key: "discretionary", monthly_amount: 100)
    manager.create_category!(name: "Car Registration", stack_key: "sinking_expected", monthly_amount: 50)
    create_confirmed_transaction!(household, manager, dining, occurred_on: Date.new(2026, 7, 6), merchant: "Cafe", amount_cents: 4_500)
    create_confirmed_transaction!(household, manager, software, occurred_on: Date.new(2026, 6, 28), merchant: "Netlify", amount_cents: 2_000)
    create_pending_draft!(household, dining, merchant: "Starbucks", amount_cents: 2_200)
  end

  def create_confirmed_transaction!(household, manager, category, occurred_on:, merchant:, amount_cents:)
    period = manager.current_period_for(occurred_on)
    transaction = household.household_transactions.create!(
      budget_period: period,
      occurred_on: occurred_on,
      merchant: merchant,
      total_amount_cents: amount_cents,
      source_type: "manual_ui",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: amount_cents)
    transaction
  end

  def create_pending_draft!(household, category, merchant:, amount_cents:)
    household.transaction_drafts.create!(
      occurred_on: Date.current,
      merchant: merchant,
      total_amount_cents: amount_cents,
      budget_category: category,
      source_type: "manual_chat",
      status: "pending",
      raw_input: "I spent #{amount_cents} at #{merchant}"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
