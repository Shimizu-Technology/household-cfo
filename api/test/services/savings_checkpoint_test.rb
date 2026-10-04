require "test_helper"
require_relative "../support/savings_daily_test_support"

class SavingsCheckpointTest < ActiveSupport::TestCase
  include SavingsDailyTestSupport

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
    @daily_category = @savings_household.budget_categories.create!(name: "Reviewed Food", stack_key: "discretionary", sort_order: 1)
  end

  teardown { travel_back }

  test "future milestones fail and Guam milestone midnight becomes available with explicit unknown progress" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 11, 29).in_time_zone("Pacific/Guam").end_of_day
      assert_raises(ArgumentError) { checkpoint_stage(30) }
      assert_empty SavingsCheckpointDraft.all
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").beginning_of_day
      version = checkpoint_approve(checkpoint_stage(30))
      assert_equal "2026-11-30", version.snapshot["cutoff_on"]
      assert_nil version.snapshot.dig("savings", "reported_cents")
      assert_equal 30, version.snapshot.dig("daily", "unknown_unreported_days")
      assert_nil version.snapshot.dig("daily", "reported_spend_cents")
      assert_equal "not_provided", version.snapshot.dig("baseline", "coverage_status")
      assert_equal "unknown", version.snapshot.dig("daily", "all_account_completeness")
    end
  end

  test "frozen snapshots retain approved sequences while explained revisions replay corrected current heads" do
    with_daily_operations do
      savings_enroll
      savings_plan
      entry = savings_approve(savings_draft(10_000))
      daily_approve(daily_stage)
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      first = checkpoint_approve(checkpoint_stage(30))
      original = first.snapshot.deep_dup
      travel_to Date.new(2026, 12, 1).in_time_zone("Pacific/Guam").noon
      savings_approve(savings_draft(20_000, entry: entry.savings_entry, on: Date.new(2026, 11, 1)))
      assert_equal original, first.reload.snapshot
      revised = checkpoint_approve(checkpoint_stage(30))
      assert_equal first.id, revised.previous_version_id
      assert_equal 10_000, first.snapshot.dig("savings", "reported_cents")
      assert_equal 20_000, revised.snapshot.dig("savings", "reported_cents")
      assert_operator revised.snapshot["financial_approval_sequence"], :>, first.snapshot["financial_approval_sequence"]
      assert_raises(ArgumentError) { checkpoint_stage(30, reason: "") }
      assert_raises(ActiveRecord::StatementInvalid) do
        SavingsCheckpointVersion.transaction(requires_new: true) { SavingsCheckpointVersion.where(id: first.id).update_all(snapshot: {}) }
      end
      assert_raises(ActiveRecord::StatementInvalid) do
        SavingsCheckpoint.transaction(requires_new: true) { SavingsCheckpoint.where(id: revised.savings_checkpoint_id).update_all(current_version_id: first.id) }
      end
    end
  end

  test "late milestone creation uses target accepted by cutoff and revisions retain it unless explicitly corrected" do
    with_daily_operations do
      savings_enroll
      original_plan = savings_plan(50_000)
      savings_approve(savings_draft(30_000))
      travel_to Date.new(2026, 12, 10).in_time_zone("Pacific/Guam").noon
      later_plan = savings_plan(30_000)
      first = checkpoint_approve(checkpoint_stage(30))
      assert_equal original_plan.id, first.snapshot.dig("savings", "accepted_plan_version_id")
      assert_equal 50_000, first.snapshot.dig("savings", "target_cents")
      retained = checkpoint_approve(checkpoint_stage(30))
      assert_equal original_plan.id, retained.snapshot.dig("savings", "accepted_plan_version_id")
      corrected = checkpoint_approve(checkpoint_stage(30, plan_version_id: later_plan.id, plan_correction_accepted: true))
      assert_equal later_plan.id, corrected.snapshot.dig("savings", "accepted_plan_version_id")
      assert_equal "explicit_correction", corrected.snapshot["plan_selection"]
      assert_equal 50_000, first.reload.snapshot.dig("savings", "target_cents")
    end
  end

  test "a draft is stale after savings or check-in approval while optional reflections do not invalidate it" do
    with_daily_operations do
      savings_enroll
      purchase = daily_approve(daily_stage).subject.savings_daily_purchase
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      savings_stale = checkpoint_stage(30)
      savings_approve(savings_draft(100))
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { checkpoint_approve(savings_stale) }
      daily_stale = checkpoint_stage(30)
      daily_check_in("spending")
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { checkpoint_approve(daily_stale) }
      valid = checkpoint_stage(30)
      daily_reflection(purchase, feeling_then: "Private sentiment excluded from checkpoints")
      version = checkpoint_approve(valid)
      refute_includes version.snapshot.to_json, "Private sentiment"
      refute_includes version.snapshot.to_json, "feeling"
    end
  end

  test "day ninety pending final confirmation preserves known progress and withdrawals lower final arithmetic without changing earlier snapshots" do
    with_daily_operations do
      savings_enroll
      savings_plan
      savings_approve(savings_draft(50_000))
      travel_to Date.new(2026, 12, 30).in_time_zone("Pacific/Guam").noon
      day60 = checkpoint_approve(checkpoint_stage(60))
      travel_to Date.new(2027, 1, 28).in_time_zone("Pacific/Guam").noon
      savings_approve(savings_draft(-10_000, funding: "withdrawal"))
      travel_to Date.new(2027, 1, 29).in_time_zone("Pacific/Guam").noon
      pending = checkpoint_approve(checkpoint_stage(90))
      assert_equal "pending", pending.snapshot["final_confirmation_status"]
      assert_equal 40_000, pending.snapshot.dig("savings", "reported_cents")
      assert_equal 50_000, day60.reload.snapshot.dig("savings", "reported_cents")
      confirmed = checkpoint_approve(checkpoint_stage(90, final_confirmation_accepted: true))
      assert_equal "confirmed", confirmed.snapshot["final_confirmation_status"]
      assert_equal 40_000, confirmed.snapshot.dig("savings", "reported_cents")
      assert_raises(ArgumentError) { checkpoint_stage(60, final_confirmation_accepted: true) }
    end
  end

  test "explicit zero attestation is cutoff specific and cannot be replaced by missing final reports" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      savings_zero
      day30 = checkpoint_approve(checkpoint_stage(30))
      assert_equal 0, day30.snapshot.dig("savings", "reported_cents")
      travel_to Date.new(2026, 12, 30).in_time_zone("Pacific/Guam").noon
      day60 = checkpoint_approve(checkpoint_stage(60))
      assert_nil day60.snapshot.dig("savings", "reported_cents")
      assert_nil day60.snapshot.dig("daily", "reported_spend_cents")
    end
  end

  test "checkpoint arithmetic respects exact target thresholds and leaves final confirmation separate" do
    with_daily_operations do
      savings_enroll
      savings_plan
      entry = savings_approve(savings_draft(49_999))
      travel_to Date.new(2027, 1, 29).in_time_zone("Pacific/Guam").noon
      below = checkpoint_approve(checkpoint_stage(90))
      assert_equal 49_999, below.snapshot.dig("savings", "reported_cents")
      assert_equal false, below.snapshot.dig("savings", "achieved")
      savings_approve(savings_draft(50_000, entry: entry.savings_entry, on: Date.new(2026, 11, 1)))
      exact = checkpoint_approve(checkpoint_stage(90))
      assert_equal true, exact.snapshot.dig("savings", "achieved")
      assert_equal "pending", exact.snapshot["final_confirmation_status"]
      savings_approve(savings_draft(50_001, entry: entry.savings_entry, on: Date.new(2026, 11, 1)))
      above = checkpoint_approve(checkpoint_stage(90))
      assert_equal 50_001, above.snapshot.dig("savings", "reported_cents")
      assert_equal true, above.snapshot.dig("savings", "achieved")
      assert_equal 0, above.snapshot.dig("savings", "evidence_supported_cents")
      assert_equal 49_999, below.reload.snapshot.dig("savings", "reported_cents")
    end
  end

  test "known negative savings and postponed target do not become unknown or invented percentages" do
    with_daily_operations do
      savings_enroll
      savings_plan(nil)
      savings_approve(savings_draft(-100, funding: "withdrawal"))
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      version = checkpoint_approve(checkpoint_stage(30))
      assert_equal(-100, version.snapshot.dig("savings", "reported_cents"))
      assert_nil version.snapshot.dig("savings", "target_cents")
      assert_nil version.snapshot.dig("savings", "progress_basis_points")
      assert_nil version.snapshot.dig("savings", "achieved")
    end
  end

  test "a real approved manual baseline preserves limited coverage and historical version identity" do
    with_daily_operations do
      savings_enroll
      request = { window_start_on: "2026-08-01", window_end_on: "2026-10-31", revision_ids: [], tracked_account_ids: [],
        cash_coverage: "unknown", household_scope_attested: false }
      preview = FinancialBaselines::Preview.new(@savings_household, user: @savings_user).call(request)
      baseline = HouseholdFinance::Operations::Runner.new(@savings_household, user: @savings_user).run(operation_key: "baseline.approve", idempotency_key: SecureRandom.uuid,
        input: { request: request, base_version_id: nil, base_lock_version: 0, expected_preview_digest: preview[:digest],
          coverage_status: "manual", reason: "Explicit limited baseline; statements not supplied" }).subject
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      checkpoint = checkpoint_approve(checkpoint_stage(30, baseline_version_id: baseline.id))
      assert_equal baseline.id, checkpoint.snapshot.dig("baseline", "version_id")
      assert_equal "manual", checkpoint.snapshot.dig("baseline", "coverage_status")
      assert_equal 0, checkpoint.snapshot.dig("baseline", "supported_complete_calendar_month_count")
      assert_equal false, checkpoint.snapshot.dig("baseline", "observed_spending_known")
      assert_equal "frozen_approved_baseline", checkpoint.snapshot.dig("baseline", "source_evidence_status")
    end
  end

  test "private checkpoint inputs reject client snapshots knownness sequences and unscoped baseline identities" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      [ { snapshot: {} }, { financial_approval_sequence: 0 }, { known_zero: true }, { actor_id: @savings_user.id } ].each do |extra|
        assert_raises(ArgumentError) { checkpoint_stage(30, **extra) }
      end
      assert_raises(ActiveRecord::RecordNotFound) { checkpoint_stage(30, baseline_version_id: 999_999) }
      assert_empty SavingsCheckpointDraft.all
      draft = checkpoint_stage(30)
      tampered = draft.snapshot.deep_dup
      tampered["savings"]["reported_cents"] = 0
      draft.update!(snapshot: tampered)
      assert_raises(ArgumentError) { checkpoint_approve(draft) }
      assert_empty SavingsCheckpointVersion.all
    end
  end

  test "daily void revisions are included only when approved by the captured daily sequence" do
    with_daily_operations do
      savings_enroll
      purchase = daily_approve(daily_stage).subject
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      first = checkpoint_approve(checkpoint_stage(30))
      daily_approve(daily_stage(0, purchase: purchase.savings_daily_purchase, on: purchase.purchased_on, disposition: "void", splits: []))
      revised = checkpoint_approve(checkpoint_stage(30))
      assert_equal 2500, first.reload.snapshot.dig("daily", "reported_spend_cents")
      assert_equal 0, revised.snapshot.dig("daily", "approved_purchase_count")
      assert_nil revised.snapshot.dig("daily", "reported_spend_cents")
    end
  end

  test "a correction moving the purchase beyond a milestone cutoff never resurrects its earlier immutable version" do
    with_daily_operations do
      savings_enroll
      original = daily_approve(daily_stage).subject
      travel_to Date.new(2026, 11, 30).in_time_zone("Pacific/Guam").noon
      first = checkpoint_approve(checkpoint_stage(30))
      travel_to Date.new(2026, 12, 1).in_time_zone("Pacific/Guam").noon
      daily_approve(daily_stage(2500, purchase: original.savings_daily_purchase, on: Date.new(2026, 12, 1)))
      corrected = checkpoint_approve(checkpoint_stage(30))
      assert_equal 2500, first.reload.snapshot.dig("daily", "reported_spend_cents")
      assert_equal 0, corrected.snapshot.dig("daily", "approved_purchase_count")
      assert_nil corrected.snapshot.dig("daily", "reported_spend_cents")
    end
  end
end
