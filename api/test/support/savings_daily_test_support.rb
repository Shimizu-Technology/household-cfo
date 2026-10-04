require_relative "savings_challenge_test_support"

module SavingsDailyTestSupport
  include SavingsChallengeTestSupport

  def with_daily_operations
    registry = HouseholdFinance::Operations::Registry
    original = registry.method(:operations)
    daily = HouseholdFinance::Operations::Savings::Daily
    classes = [ daily::PurchaseStage, daily::PurchaseApprove, daily::ReflectionSave, daily::ReflectionErase, daily::CheckInSave,
      HouseholdFinance::Operations::Savings::CheckpointStage, HouseholdFinance::Operations::Savings::CheckpointApprove,
      HouseholdFinance::Operations::Baseline::Approve, HouseholdFinance::Operations::Baseline::Revise ]
    with_savings_runtime do
      registry.define_singleton_method(:operations) { original.call.merge(classes.index_by { |klass| klass::KEY }) }
      yield
    end
  ensure
    registry.define_singleton_method(:operations, original) if original
  end

  def daily_stage(amount = 2500, purchase: nil, on: @savings_enrollment.local_today, **extra)
    purchase&.reload
    savings_run("daily.purchase.stage", { amount_cents: amount, merchant: "Synthetic Cafe", purchased_on: on.iso8601,
      splits: [ { budget_category_id: @daily_category.id, amount_cents: amount } ], link_kind: "manual_new",
      purchase_id: purchase&.id, expected_version_id: purchase&.current_version_id, expected_head_lock_version: purchase&.lock_version || 0,
      reason: purchase&.current_version_id ? "Corrected the daily purchase" : "" }.merge(extra)).subject
  end

  def daily_approve(draft, token: SecureRandom.uuid)
    savings_run("daily.purchase.approve", { draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version,
      expected_version_id: draft.base_version_id, expected_head_lock_version: draft.base_head_lock_version }, token: token)
  end

  def daily_check_in(state, on: @savings_enrollment.local_today, reason: "Corrected my daily report")
    head = SavingsDailyCheckIn.find_by(savings_enrollment: @savings_enrollment, local_on: on)
    savings_run("daily.check_in.save", { local_on: on.iso8601, spending_state: state, accepted: true,
      expected_version_id: head&.current_version_id, expected_head_lock_version: head&.lock_version || 0,
      reason: head&.current_version_id ? reason : "" }).subject
  end

  def daily_reflection(purchase, feeling_then: "Hopeful", feeling_now: "Calm", token: SecureRandom.uuid)
    head = SavingsDailyReflection.find_by(savings_daily_purchase: purchase)
    savings_run("daily.reflection.save", { purchase_id: purchase.id, expected_version_id: head&.current_version_id,
      expected_head_lock_version: head&.lock_version || 0, feeling_then: feeling_then, feeling_now: feeling_now }, token: token)
  end

  def daily_erase(version, token: SecureRandom.uuid, head_lock: nil)
    head = version.savings_daily_reflection.reload
    savings_run("daily.reflection.erase", { reflection_id: head.id, erase_accepted: true, expected_version_id: head.current_version_id,
      expected_head_lock_version: head_lock || head.lock_version }, token: token)
  end

  def checkpoint_stage(day, **extra)
    head = SavingsCheckpoint.find_by(savings_enrollment: @savings_enrollment, milestone_day: day)
    savings_run("checkpoint.stage", { milestone_day: day, expected_version_id: head&.current_version_id,
      expected_head_lock_version: head&.lock_version || 0, reason: head&.current_version_id ? "Explained later approved correction" : "" }.merge(extra)).subject
  end

  def checkpoint_approve(draft)
    savings_run("checkpoint.approve", { draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version,
      expected_version_id: draft.base_version_id, expected_head_lock_version: draft.base_head_lock_version }).subject
  end
end
