require "test_helper"
require_relative "../support/savings_challenge_test_support"

class SavingsChallengeHistoryTest < ActiveSupport::TestCase
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
  end

  teardown { travel_back }

  test "approved private history cannot be changed or deleted through callbacks or SQL and calendar identity cannot move" do
    with_savings_runtime do
      savings_enroll
      plan = savings_plan
      version = savings_approve(savings_draft(100))
      [ plan, version ].each do |record|
        assert_raises(ActiveRecord::RecordNotSaved) { record.update!(reason: "Rewritten") }
        assert_raises(ActiveRecord::RecordNotDestroyed) { record.destroy! }
        assert_sql_rejected { record.class.where(id: record.id).update_all(reason: "Rewritten") }
        assert_sql_rejected { record.class.where(id: record.id).delete_all }
      end
      assert_sql_rejected { SavingsEnrollment.where(id: @savings_enrollment.id).update_all(starts_on: Date.new(2026, 11, 16), ends_on: Date.new(2027, 2, 13)) }
      assert_sql_rejected { SavingsEnrollment.where(id: @savings_enrollment.id).update_all(user_id: @savings_owner.id) }
      assert_sql_rejected { SavingsEntry.where(id: version.savings_entry_id).update_all(current_approved_version_id: nil) }
      assert_sql_rejected { SavingsEntryDraft.where(id: version.savings_entry.savings_entry_drafts.sole.id).update_all(status: "pending") }
      assert_equal 100, savings_projection[:reported_cents]
    end
  end

  test "cross enrollment heads previous versions and approving actors are rejected even with SQL model validation bypass" do
    with_savings_runtime do
      savings_enroll
      first = savings_approve(savings_draft(100))
      second = savings_approve(savings_draft(200))
      assert_sql_rejected { SavingsEntry.where(id: first.savings_entry_id).update_all(current_approved_version_id: second.id) }
      invalid = first.dup
      invalid.approved_by_user = @savings_owner
      invalid.previous_version = first
      invalid.version_number = 2
      invalid.approval_sequence = @savings_enrollment.reload.approval_sequence + 1
      invalid.reason = "Correction"
      refute invalid.valid?
      assert_includes invalid.errors[:approved_by_user], "must be the participant"
      assert_sql_rejected do
        @savings_enrollment.reload.advance_approval_sequence!
        invalid.save!(validate: false)
      end
      assert_equal 2, @savings_enrollment.savings_entry_versions.count
    end
  end

  test "integer validation rejects silent ORM float coercion and evidence allocations remain zero at database boundary" do
    with_savings_runtime do
      savings_enroll
      draft = savings_draft(100)
      draft.signed_cents = 1.5
      refute draft.valid?
      assert_includes draft.errors[:signed_cents], "must be integer cents"
      plan = SavingsPlanDraft.new(savings_enrollment: @savings_enrollment, created_by_user: @savings_user, target_cents: "50000")
      refute plan.valid?
      version = savings_approve(draft.reload)
      invalid = version.dup
      invalid.previous_version = version
      invalid.version_number = 2
      invalid.approval_sequence = @savings_enrollment.reload.approval_sequence + 1
      invalid.reason = "Unsupported evidence change"
      invalid.evidence_supported_cents = 1
      refute invalid.valid?
      assert_sql_rejected do
        @savings_enrollment.advance_approval_sequence!
        invalid.save!(validate: false)
      end
    end
  end

  test "an immutable approved version must publish its stable head atomically and approval sequences cannot collide across kinds" do
    with_savings_runtime do
      savings_enroll
      draft = savings_draft(100)
      assert_sql_rejected do
        sequence = @savings_enrollment.reload.advance_approval_sequence!
        SavingsEntryVersion.create!(savings_entry: draft.savings_entry, savings_enrollment: @savings_enrollment,
          approved_by_user: @savings_user, version_number: 1, approval_sequence: sequence,
          signed_cents: 100, effective_on: @savings_enrollment.local_today, funding_source: "new_money_reserved", approved_at: Time.current)
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      end
      assert_nil draft.savings_entry.reload.current_approved_version_id
      savings_approve(draft)
      assert_sql_rejected do
        SavingsPlanVersion.create!(savings_enrollment: @savings_enrollment.reload, approved_by_user: @savings_user,
          version_number: 1, approval_sequence: @savings_enrollment.approval_sequence, target_cents: 50_000, approved_at: Time.current)
      end
    end
  end

  test "schema dump preserves private SQL guards scoped heads and deferred publication constraints" do
    path = Rails.root.join("db/schema.rb")
    schema = path.read
    %w[savings_prevent_mutation savings_scope_guard savings_identity_guard savings_draft_guard savings_approval_head_guard].each do |function|
      assert_includes schema, "FUNCTION public.#{function}()"
      assert ActiveRecord::Base.connection.select_value("SELECT to_regprocedure('#{function}()') IS NOT NULL")
    end
    %w[savings_plan_versions_published savings_entry_versions_published].each do |trigger|
      assert_includes schema, "#{trigger}"
      row = ActiveRecord::Base.connection.select_one("SELECT tgdeferrable, tginitdeferred FROM pg_trigger WHERE tgname = '#{trigger}'")
      assert_equal true, row.fetch("tgdeferrable")
      assert_equal true, row.fetch("tginitdeferred")
    end
    assert_includes schema, "savings_entry_head_scope"
    assert_includes schema, "savings_enrollment_plan_scope"
  end

  private

  def assert_sql_rejected(&block)
    assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true, &block) }
  end
end
