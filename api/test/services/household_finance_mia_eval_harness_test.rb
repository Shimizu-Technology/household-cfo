require "test_helper"

class HouseholdFinanceMiaEvalHarnessTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  test "curated real-world Mia eval cases pass through deterministic Rails routes" do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time do
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

  test "live mode uses live expectations, any-of lists, regex boundaries, and curly apostrophes" do
    cases = [
      {
        "id" => "live_case",
        "prompt" => "Will this help my loan?",
        "expected_phrases" => [ "deterministic only phrase" ],
        "forbidden_phrases" => [ "guaranteed approval" ],
        "live_expected" => [ [ "can't promise", "loan officer" ] ],
        "live_forbidden" => [ "/\\bpar\\b/" ]
      }
    ]
    passing = HouseholdFinance::MiaEvalHarness.new(cases: cases, mode: :live, runner: ->(_eval_case) { "I can’t promise approval; compare it with your part of the plan." }).call
    assert passing.passed?, passing.failures.map(&:to_h).inspect

    failing = HouseholdFinance::MiaEvalHarness.new(cases: cases, mode: :live, runner: ->(_eval_case) { "Par, guaranteed approval is coming." }).call.failures.sole
    assert_equal [ [ "can't promise", "loan officer" ] ], failing.missing_phrases
    assert_equal [ "guaranteed approval", "/\\bpar\\b/" ], failing.forbidden_matches

    deterministic = HouseholdFinance::MiaEvalHarness.new(cases: cases, runner: ->(_eval_case) { "Par." }).call.failures.sole
    assert_equal [ "deterministic only phrase" ], deterministic.missing_phrases
    assert_empty deterministic.forbidden_matches
  end

  private

  def run_controller_case(eval_case)
    user, household = HouseholdFinance::MiaEvalHousehold.create!
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

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
