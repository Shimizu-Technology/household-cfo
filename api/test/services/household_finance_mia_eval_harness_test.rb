require "test_helper"
require_relative "../support/participant_reader_test_support"

class HouseholdFinanceMiaEvalHarnessTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers
  include ParticipantReaderTestSupport

  test "curated real-world Mia eval cases pass through deterministic Rails routes" do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time do
      cases = HouseholdFinance::MiaEvalHarness.load_cases
      result = HouseholdFinance::MiaEvalHarness.new(cases: cases, runner: method(:run_controller_case)).call

      assert result.passed?, failure_summary(result)
      assert_equal cases.length, result.total_count
      assert_operator result.passed_count, :>=, 10
    end
  end

  # The CFO cases the app can't answer yet, pinned so a new known_gap can't hide a
  # regression. When one closes, take it off here and in the YAML; if it regresses
  # later, it fails as an ordinary case.
  CFO_KNOWN_GAPS = %w[
    cfo_where_it_went_against_plan cfo_where_most_money_goes cfo_cut_first cfo_cut_prenatal_clinic
    cfo_stop_family_support cfo_one_off_every_month
    cfo_savings_goal_by_march cfo_make_it_to_payday
    cfo_make_it_to_payday_with_numbers cfo_runway_if_job_lost
  ].freeze

  test "CFO question set answers with the ledger's numbers and keeps the rules" do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time do
      cases = HouseholdFinance::MiaEvalHarness.load_cases(HouseholdFinance::MiaEvalHarness::CFO_QUESTION_SET_PATH)
      result = HouseholdFinance::MiaEvalHarness.new(cases: cases, runner: method(:run_controller_case)).call

      puts "\nCFO question set: #{result.passed_count}/#{result.total_count} pass; #{result.known_gaps.length} known gaps"
      if ENV["MIA_EVAL_VERBOSE"].present?
        result.known_gaps.each { |gap| puts "  #{gap.id}: #{gap.problems.join(' | ')}\n    reply: #{gap.response.squish.truncate(400)}" }
      end
      assert result.passed?, failure_summary(result)
      assert_operator cases.length, :>=, 25
      assert cases.all? { |eval_case| eval_case["household"] == "cfo" }
      assert_equal CFO_KNOWN_GAPS.sort, cases.select { |eval_case| eval_case["known_gap"] }.pluck("id").sort, "known_gap cases changed; update CFO_KNOWN_GAPS"
      closed = result.closed_gaps.map { |gap| "#{gap.id}: #{gap.closed_gap_checks.join(', ')} now pass" }
      assert_empty closed, "Known gaps closed. Check each reply, then narrow or remove its known_gap here and in the YAML:\n#{closed.join("\n")}"
      assert_equal CFO_KNOWN_GAPS.sort, result.known_gaps.map(&:id).sort
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
    user, household = HouseholdFinance::MiaEvalHousehold.for_case(eval_case).create!
    messages = Array(eval_case["messages"]).presence || [ eval_case.fetch("prompt") ]

    replies = messages.map do |message|
      request = -> { post "/api/v1/mia/messages", params: { message: message, year: 2026, month: 7 }, headers: auth_headers(user), as: :json }
      if eval_case["id"].in?(%w[mel_weekly_grocery_win mel_stuck_to_budget win_extra_card_payment])
        with_participant_reader_response({ care: "none", facts: [], question: false, reply_intent: "win", setup_answer: { field: "none", value: "" }, correction: false, spending_preferences: [] }, &request)
      else
        request.call
      end
      assert_response :created
      { prompt: message, response: JSON.parse(response.body).fetch("assistant_message").fetch("content") }
    end

    {
      response: replies.last.fetch(:response),
      replies: replies,
      metadata: {
        pending_draft_count: household.transaction_drafts.pending.count,
        confirmed_transaction_count: household.household_transactions.where(status: "confirmed").count
      },
      ledger: HouseholdFinance::MiaEvalLedger.snapshot(household, eval_case)
    }
  end

  def failure_summary(result)
    result.failures.map do |failure|
      <<~SUMMARY.squish
        #{failure.id}: unexpected failures=#{failure.unexpected_failures.inspect} missing=#{failure.missing_phrases.inspect} forbidden=#{failure.forbidden_matches.inspect}
        missing_amounts=#{failure.missing_amounts.inspect} unexpected_amounts=#{failure.unexpected_amounts.inspect}
        rules=#{failure.rule_violations.inspect} error=#{failure.error.inspect} response=#{failure.response.inspect}
      SUMMARY
    end.join("\n")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
