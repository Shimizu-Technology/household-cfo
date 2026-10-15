require "test_helper"
require_relative "../support/workos_auth_test_support"
require Rails.root.join("lib/tasks/mia_evals/live_runner").to_s

class MiaEvalsLiveRunnerTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  RUNNER_ENV_KEYS = %w[MIA_LIVE_EVALS CI OPENROUTER_API_KEY DATABASE_URL].freeze

  setup do
    @previous_env = (RUNNER_ENV_KEYS + WORKOS_ENV_KEYS).to_h { |key| [ key, ENV[key] ] }
    (RUNNER_ENV_KEYS + WORKOS_ENV_KEYS).each { |key| ENV.delete(key) }
    ENV["MIA_LIVE_EVALS"] = "1"
    ENV["OPENROUTER_API_KEY"] = "sk-or-test"
    @runner = MiaEvals::LiveRunner.new
  end

  teardown do
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "preflight passes only for the local test database with no sign-in provider" do
    assert_preflight true
  end

  test "preflight refuses an exported DATABASE_URL" do
    ENV["DATABASE_URL"] = "postgres://example.invalid/household_cfo_production"
    assert_preflight false, /Unset DATABASE_URL/
  end

  test "preflight refuses a database that is not named as a test database" do
    stub_method(@runner, :test_database_name?, false) do
      assert_preflight false, /only run against a test database/
    end
  end

  test "preflight refuses when a sign-in provider is configured" do
    with_workos do
      assert_preflight false, /Unset AUTH_PROVIDER/
    end
  end

  test "preflight refuses CI and a missing opt-in" do
    ENV["CI"] = "true"
    assert_preflight false, /do not run in CI/
    ENV.delete("CI")
    ENV.delete("MIA_LIVE_EVALS")
    assert_preflight false, /MIA_LIVE_EVALS=1/
  end

  test "test database names must carry the test suffix" do
    assert @runner.send(:test_database_name?, "household_cfo_api_test")
    assert @runner.send(:test_database_name?, "household_cfo_api_test_ai_review")
    assert @runner.send(:test_database_name?, "household_cfo_api_test-3")
    assert_not @runner.send(:test_database_name?, "household_cfo_api_production")
    assert_not @runner.send(:test_database_name?, "contest_db")
    assert_not @runner.send(:test_database_name?, nil)
  end

  test "a run with crashed cases, failed turns, or provider errors is reported as a failure" do
    ok_turn = { status: 201 }
    clean = result_with(case_result(turns: [ ok_turn ]))
    assert_empty @runner.send(:run_problems, clean, { provider_errors: 0 })

    crashed = result_with(case_result(turns: [ ok_turn ]), case_result(turns: nil, error: "NoMethodError: boom"))
    assert_match(/1 case\(s\) raised/, @runner.send(:run_problems, crashed, { provider_errors: 0 }).join)

    failed_turn = result_with(case_result(turns: [ ok_turn, { status: 500 } ]))
    assert_match(/1 turn\(s\) did not return 201/, @runner.send(:run_problems, failed_turn, { provider_errors: 0 }).join)

    assert_match(/2 model call\(s\) failed/, @runner.send(:run_problems, clean, { provider_errors: 2 }).join)
  end

  test "model calls that time out before a response are recorded as provider errors" do
    timing_out = Class.new(Net::HTTP) do
      private

      def connect
        raise Net::OpenTimeout, "execution expired"
      end
    end
    timing_out.prepend(MiaEvals::LiveRunner::ProviderCallRecorder)
    MiaEvals::LiveRunner.provider_calls.clear

    assert_raises(Net::OpenTimeout) { timing_out.new("openrouter.ai", 443).start { } }

    call = MiaEvals::LiveRunner.provider_calls.sole
    assert_equal 0, call[:status]
    assert_match(/Net::OpenTimeout/, call[:error])
  ensure
    MiaEvals::LiveRunner.provider_calls.clear
  end

  private

  def assert_preflight(expected, message = nil)
    passed = nil
    _out, err = capture_io { passed = @runner.send(:preflight) }
    assert_equal expected, passed, err
    assert_match message, err if message
  end

  def case_result(turns:, error: nil)
    HouseholdFinance::MiaEvalHarness::CaseResult.new(
      id: "case", prompt: "hi", response: turns ? "reply" : "", passed: false,
      missing_phrases: [], forbidden_matches: [], metadata: turns ? { turns: turns } : {}, error: error
    )
  end

  def result_with(*case_results)
    HouseholdFinance::MiaEvalHarness::Result.new(case_results: case_results)
  end
end
