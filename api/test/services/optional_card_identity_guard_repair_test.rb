require "test_helper"
require_relative "../support/savings_debt_test_support"
require_relative "../../db/migrate/20261007060900_ensure_optional_card_household_identity_guard"

class OptionalCardIdentityGuardRepairTest < ActiveSupport::TestCase
  include SavingsDebtTestSupport

  test "repair restores missing historical DDL and still prevents linked household transfers" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_savings_runtime do
        savings_enroll
        debt = @savings_household.debts.create!(label: "Reviewed card", debt_type: "credit_card", balance_cents: 30_000, minimum_payment_cents: 1_000)
        candidate = SavingsChallenge::Debt::HouseholdMapping.new(@savings_household).candidate(debt)
        draft = savings_run("debt.stage", { terms: debt_terms, expected_version_id: nil, expected_head_lock_version: 0,
          household_debt_mapping: { household_debt_id: debt.id, fingerprint: candidate[:fingerprint] } }).subject
        debt_approve(draft)
        other = Household.create!(created_by_user: @savings_user, name: "Other household")
        connection = ActiveRecord::Base.connection
        connection.execute("DROP TRIGGER debts_optional_card_identity_guard ON debts")
        connection.execute("DROP FUNCTION debts_optional_card_identity_guard()")
        assert_nil connection.select_value("SELECT to_regprocedure('debts_optional_card_identity_guard()')")
        EnsureOptionalCardHouseholdIdentityGuard.new.up
        EnsureOptionalCardHouseholdIdentityGuard.new.up
        assert connection.select_value("SELECT to_regprocedure('debts_optional_card_identity_guard()')")
        assert_equal 1, connection.select_value("SELECT COUNT(*) FROM pg_trigger WHERE tgrelid = 'debts'::regclass AND tgname = 'debts_optional_card_identity_guard'").to_i
        assert_raises(ActiveRecord::StatementInvalid) do
          Debt.transaction(requires_new: true) { debt.update_columns(household_id: other.id) }
        end
        assert_equal @savings_household.id, debt.reload.household_id
      end
    end
  end
end
