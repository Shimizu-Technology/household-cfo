# frozen_string_literal: true

require "test_helper"
require_relative "../support/savings_challenge_test_support"
require Rails.root.join("db/migrate/20261121120000_add_challenge_rules_to_savings_enrollments").to_s

class AddChallengeRulesToSavingsEnrollmentsTest < ActiveSupport::TestCase
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
  end

  teardown do
    travel_back
    SavingsEnrollment.reset_column_information
  end

  test "down and up again backfill an existing enrollment with today's fixed rules" do
    with_savings_runtime do
      enrollment = savings_enroll
      migration = AddChallengeRulesToSavingsEnrollments.new
      ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
      SavingsEnrollment.reset_column_information
      refute SavingsEnrollment.column_names.include?("challenge_length_days")
      assert_equal enrollment.starts_on + 89, SavingsEnrollment.find(enrollment.id).ends_on

      ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      SavingsEnrollment.reset_column_information
      enrollment = SavingsEnrollment.find(enrollment.id)
      assert_equal [ 90, [ 30, 60, 90 ], 50_000, "savings" ], enrollment.attributes.values_at("challenge_length_days", "checkpoint_days", "suggested_goal_cents", "goal_counts")
      error = assert_raises(ActiveRecord::StatementInvalid) do
        ApplicationRecord.transaction(requires_new: true) { SavingsEnrollment.where(id: enrollment.id).update_all(checkpoint_days: [ 30, 60 ]) }
      end
      assert_match(/identity is frozen|savings_enrollment_rules_valid/, error.message)
    end
  end

  test "rollback refuses once an enrollment or entry uses rules the fixed schema cannot hold" do
    with_savings_runtime do
      publish_savings_challenge_rules({ "length_days" => 60, "checkpoints" => "thirds", "suggested_goal_cents" => 50_000, "counts" => "savings" })
      savings_enroll
      error = assert_raises(ActiveRecord::IrreversibleMigration) do
        ActiveRecord::Migration.suppress_messages { AddChallengeRulesToSavingsEnrollments.new.down }
      end
      assert_match(/fixed 90-day schema/, error.message)
      assert_includes error.message, "an enrollment uses a challenge length"
      assert_includes error.message, "Nothing was changed."
      assert SavingsEnrollment.column_names.include?("challenge_length_days")
    end
  end

  test "rollback refuses a saved sponsor report off Day 30, 60 and 90 and a pending extra debt payment" do
    with_savings_runtime do
      savings_enroll
      draft = savings_draft(5_000, funding: "extra_debt_payment")
      assert_equal "pending", draft.status
      ChallengeSponsorExport.create!(cohort: @savings_cohort, checkpoint_day: 45, policy_version: ChallengePrivacy::SponsorExports::POLICY_VERSION,
        approved_by_user: @savings_owner, resolved_cutoff_on: @savings_cohort.starts_on + 44, private_provenance: {}, report: {}, digest: "c" * 64, created_at: Time.current)
      error = assert_raises(ActiveRecord::IrreversibleMigration) do
        ActiveRecord::Migration.suppress_messages { AddChallengeRulesToSavingsEnrollments.new.down }
      end
      assert_includes error.message, "a saved sponsor report is for a day other than 30, 60 or 90"
      assert_includes error.message, "a savings entry waiting for review is an extra debt payment"
      refute_includes error.message, "an enrollment uses"
    end
  end

  test "check-in days must be strictly increasing with no empty entries" do
    with_savings_runtime do
      enrollment = savings_enroll
      # The identity guard freezes an accepted enrollment, so check the rule on a fresh copy of its row.
      columns = SavingsEnrollment.column_names - %w[id]
      attributes = enrollment.attributes.slice(*columns)
      [ [ 30, 30, 90 ], [ 60, 30, 90 ], [ 30, nil, 90 ], [ 0, 90 ] ].each do |days|
        values = attributes.merge("checkpoint_days" => days, "status" => "withdrawn", "staff_preview" => true)
        error = assert_raises(ActiveRecord::StatementInvalid, days.inspect) do
          ApplicationRecord.transaction(requires_new: true) do
            ApplicationRecord.connection.exec_query("SET CONSTRAINTS ALL IMMEDIATE")
            SavingsEnrollment.insert!(values)
          end
        end
        assert_match(/savings_enrollment_rules_valid/, error.message, days.inspect)
      end
    end
  end
end
