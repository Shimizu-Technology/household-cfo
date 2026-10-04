require "test_helper"
require_relative "../support/savings_daily_test_support"

class SavingsPlanContextTest < ActiveSupport::TestCase
  include SavingsDailyTestSupport
  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
    @baseline_request = { window_start_on: "2026-07-01", window_end_on: "2026-07-31", revision_ids: [], tracked_account_ids: [],
      household_scope_attested: false, cash_coverage: "unknown", category_eligibility: [] }
  end
  teardown { travel_back }

  test "comfortable spending experiment pins optional manual baseline without manufacturing savings" do
    with_daily_operations do
      savings_enroll
      baseline = approve_baseline
      change = { budget_category_id: nil, description: "Bring lunch twice a week when practical", recurrence: "recurring", planned_reduction_cents: 2000 }
      draft = savings_run("plan.stage", { target_cents: 30_000, expected_plan_version_id: nil,
        financial_baseline_version_id: baseline.id, baseline_digest: baseline.digest, spending_changes: [ change ] }).subject
      assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
      assert_nil savings_projection[:reported_cents]
      version = approve_plan(draft)
      assert_equal baseline.id, version.financial_baseline_version_id
      assert_equal baseline.digest, version.baseline_digest
      assert_equal [ change.stringify_keys ], version.spending_changes
      presented = SavingsChallenge::ParticipantSerializer.record(version)
      assert_equal({ "window_start_on" => "2026-07-01", "window_end_on" => "2026-07-31", "coverage_status" => "manual" }, presented["baseline_context"])
      assert_equal "Bring lunch twice a week when practical", presented["spending_changes"].sole["description"]
      assert_nil savings_projection[:reported_cents]
      assert_equal 30_000, savings_projection[:target_cents]
      assert_empty @savings_household.household_transactions
      assert_raises(ActiveRecord::StatementInvalid) do
        SavingsPlanVersion.transaction(requires_new: true) { SavingsPlanVersion.where(id: version.id).update_all(spending_changes: []) }
      end
    end
  end

  test "baseline revision between plan preview and acceptance preserves prior accepted plan" do
    with_daily_operations do
      savings_enroll
      prior_plan = savings_plan
      baseline = approve_baseline
      draft = savings_run("plan.stage", { target_cents: 10_000, expected_plan_version_id: prior_plan.id, reason: "Choose a smaller comfortable target",
        financial_baseline_version_id: baseline.id, baseline_digest: baseline.digest, spending_changes: [] }).subject
      approve_baseline(previous: baseline)
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { approve_plan(draft) }
      assert_equal prior_plan.id, @savings_enrollment.reload.current_accepted_plan_version_id
      assert_equal "pending", draft.reload.status
      assert_equal 1, SavingsPlanVersion.where(savings_enrollment: @savings_enrollment).count
      assert_nil savings_projection[:reported_cents]
    end
  end

  test "checkpoint adopts the accepted plan baseline" do
    with_daily_operations do
      savings_enroll
      baseline = approve_baseline
      draft = savings_run("plan.stage", { target_cents: 30_000, expected_plan_version_id: nil,
        financial_baseline_version_id: baseline.id, baseline_digest: baseline.digest, spending_changes: [] }).subject
      approve_plan(draft)
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      first = checkpoint_approve(checkpoint_stage(30))
      assert_equal baseline.id, first.snapshot.dig("baseline", "version_id")
    end
  end

  test "checkpoint corrections preserve an absent original baseline after a later plan adds one" do
    with_daily_operations do
      savings_enroll
      original_plan = savings_plan
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      first = checkpoint_approve(checkpoint_stage(30))
      assert_nil first.snapshot.dig("baseline", "version_id")
      baseline = approve_baseline
      draft = savings_run("plan.stage", { target_cents: 30_000, expected_plan_version_id: original_plan.id,
        financial_baseline_version_id: baseline.id, baseline_digest: baseline.digest, spending_changes: [], reason: "Choose an affordable experiment" }).subject
      plan = approve_plan(draft)
      correction = checkpoint_approve(checkpoint_stage(30, plan_version_id: plan.id, plan_correction_accepted: true))
      assert_nil correction.snapshot.dig("baseline", "version_id")
      assert_equal "not_provided", correction.snapshot.dig("baseline", "coverage_status")
      assert_equal plan.id, correction.snapshot.dig("savings", "accepted_plan_version_id")
    end
  end

  test "a merchant or stack label does not authorize optional category selection and malformed estimates are rejected" do
    with_daily_operations do
      savings_enroll
      baseline = approve_baseline
      category = @savings_household.budget_categories.create!(name: "Necessary medicine", stack_key: "discretionary")
      input = { target_cents: 5000, expected_plan_version_id: nil, financial_baseline_version_id: baseline.id, baseline_digest: baseline.digest,
        spending_changes: [ { budget_category_id: category.id, description: "Review this choice", recurrence: "unknown", planned_reduction_cents: 1000 } ] }
      assert_raises(ArgumentError) { savings_run("plan.stage", input) }
      input[:financial_baseline_version_id] = nil
      input[:baseline_digest] = nil
      input[:spending_changes][0][:planned_reduction_cents] = 1000.5
      assert_raises(ArgumentError) { savings_run("plan.stage", input) }
      assert_empty SavingsPlanDraft.where(savings_enrollment: @savings_enrollment)
      assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
    end
  end

  private
  def approve_baseline(previous: nil)
    preview = FinancialBaselines::Preview.new(@savings_household, user: @savings_user).call(@baseline_request)
    head = FinancialBaselineHead.find_by(household: @savings_household, participant_user: @savings_user)
    HouseholdFinance::Operations::Runner.new(@savings_household, user: @savings_user).run(operation_key: previous ? "baseline.revise" : "baseline.approve",
      input: { request: @baseline_request, expected_preview_digest: preview[:digest], base_version_id: previous&.id, base_lock_version: head&.lock_version || 0,
        coverage_status: "manual", reason: "Reviewed limited manual window" }, idempotency_key: SecureRandom.uuid).subject
  end
  def approve_plan(draft)
    savings_run("plan.approve", { draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version,
      expected_plan_version_id: draft.base_plan_version_id }).subject
  end
end
