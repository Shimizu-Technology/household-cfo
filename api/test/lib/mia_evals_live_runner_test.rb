require "test_helper"
require_relative "../support/workos_auth_test_support"
require Rails.root.join("lib/tasks/mia_evals/live_runner").to_s

class MiaEvalsLiveRunnerTest < ActiveSupport::TestCase
  include WorkosAuthTestSupport

  RUNNER_ENV_KEYS = %w[MIA_LIVE_EVALS CI OPENROUTER_API_KEY DATABASE_URL MIA_LIVE_EVALS_NIGHTLY_WORKFLOW GITHUB_WORKFLOW SET].freeze

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

  test "preflight still explains refusal when Ruby warnings are disabled" do
    previous_verbose = $VERBOSE
    $VERBOSE = nil
    ENV["DATABASE_URL"] = "postgres://example.invalid/household_cfo_production"
    assert_preflight false, /Unset DATABASE_URL/
  ensure
    $VERBOSE = previous_verbose
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

  test "in CI only the nightly live-eval workflow may run, and only with its own opt-in" do
    ENV["CI"] = "true"
    ENV["GITHUB_WORKFLOW"] = MiaEvals::LiveRunner::NIGHTLY_WORKFLOW
    assert_preflight false, /do not run in CI, except in the nightly/

    ENV["MIA_LIVE_EVALS_NIGHTLY_WORKFLOW"] = "1"
    assert_preflight true

    ENV["GITHUB_WORKFLOW"] = "CI"
    assert_preflight false, /do not run in CI/

    ENV["GITHUB_WORKFLOW"] = MiaEvals::LiveRunner::NIGHTLY_WORKFLOW
    ENV.delete("MIA_LIVE_EVALS")
    assert_preflight false, /MIA_LIVE_EVALS=1/
  end

  test "SET picks a known case set" do
    ENV["SET"] = "cfo"
    assert_preflight true
    assert_equal "cfo", @runner.send(:case_set)
    ENV["SET"] = "everything"
    assert_preflight false, /SET must be one of default, cfo/
  end

  test "the nightly workflow's name matches the runner's opt-in" do
    workflow = YAML.safe_load_file(Rails.root.join("../.github/workflows/mia-live-evals.yml"))
    assert_equal MiaEvals::LiveRunner::NIGHTLY_WORKFLOW, workflow.fetch("name")
    assert_equal "1", workflow.dig("jobs", "live", "env", MiaEvals::LiveRunner::NIGHTLY_OPT_IN).to_s
  end

  test "the nightly workflow gives the OpenRouter key only to the steps that use it and pins third-party actions" do
    workflow = YAML.safe_load_file(Rails.root.join("../.github/workflows/mia-live-evals.yml"))
    job = workflow.dig("jobs", "live")
    assert_not job.fetch("env").key?("OPENROUTER_API_KEY")
    keyed = job.fetch("steps").select { |step| step.dig("env", "OPENROUTER_API_KEY") }.pluck("name")
    assert_equal [ "Check for the OpenRouter key", "Run live Mia evals" ], keyed
    job.fetch("steps").filter_map { |step| step["uses"] }.each do |action|
      assert_match(/@[0-9a-f]{40}\z/, action, "#{action} is not pinned to a commit")
    end
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

  test "a run exits non-zero when a case fails, including a known gap failing a check it doesn't name" do
    gap = { "id" => "gap", "prompt" => "Should we cut back on the prenatal clinic visits?", "expected_phrases" => [ "protect" ],
      "known_gap" => { "checks" => [ "expected_phrases" ], "reason" => "Deflects." } }
    regular = { "id" => "regular", "prompt" => "Hi", "expected_phrases" => [ "hello" ] }
    run = ->(cases, reply) do
      result = HouseholdFinance::MiaEvalHarness.new(cases: cases, mode: :live,
        runner: ->(_eval_case) { { response: reply, metadata: { turns: [ { status: 201 } ] } } }).call
      @runner.run_problems(result, { provider_errors: 0 })
    end

    assert_empty run.call([ gap, regular ], "hello, one step at a time")
    assert_equal [ "1 case(s) failed: regular." ], run.call([ regular ], "hi there")
    assert_equal [ "1 case(s) failed: gap." ], run.call([ gap ], "Cut back on medical visits.")
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
    # Keep these unit cases independent of each worker's isolated database name.
    # The actual name predicate is exercised separately, including unsafe names.
    err = nil
    stub_method(ActiveRecord::Base.connection, :current_database, "household_cfo_api_test") do
      _out, err = capture_io { passed = @runner.send(:preflight) }
    end
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
