require "test_helper"
require_relative "../../db/migrate/20261004310000_create_optional_savings_debt"
require_relative "../support/savings_debt_test_support"

class SavingsDebtPostgresqlTest < ActiveSupport::TestCase
  include SavingsDebtTestSupport
  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "PostgreSQL rejects mutation deletion cross-actor and head rollback of immutable approved terms" do
    with_savings_runtime do
      savings_enroll
      version = debt_approve(debt_stage)
      card = version.savings_debt_card
      [ -> { SavingsDebtVersion.where(id: version.id).update_all(terms: version.terms.merge("balance_cents" => 0)) },
        -> { SavingsDebtVersion.where(id: version.id).delete_all }, -> { SavingsDebtCard.where(id: card.id).update_all(current_version_id: nil) },
        -> { SavingsDebtCard.where(id: card.id).update_all(user_id: @savings_owner.id) } ].each do |action|
        assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { action.call } }
      end
      assert_equal version.id, card.reload.current_version_id
    end
  end

  test "PostgreSQL terms contract rejects float currency hidden fields and false paid-off claims" do
    normalized = SavingsChallenge::Debt::Terms.normalize(debt_terms)
    bad = [ normalized.merge("balance_cents" => 1.5), normalized.merge("apr_bps" => -1), normalized.merge("status" => nil), normalized.merge("status" => "paid_off"), normalized.merge("currency" => "USD"), normalized.merge("as_of_on" => "2026-02-30") ]
    bad.each do |value|
      result = ApplicationRecord.connection.select_value("SELECT savings_debt_terms_valid(#{ApplicationRecord.connection.quote(value.to_json)}::jsonb)")
      assert_equal false, result
    end
    assert ApplicationRecord.connection.select_value("SELECT savings_debt_terms_valid(#{ApplicationRecord.connection.quote(normalized.to_json)}::jsonb)")
  end

  test "migration reversal refuses retained private card history without losing tables or heads" do
    with_savings_runtime do
      savings_enroll
      version = debt_approve(debt_stage)
      migration = CreateOptionalSavingsDebt.new
      migration.verbose = false
      assert_raises(ActiveRecord::IrreversibleMigration) do
        ApplicationRecord.transaction(requires_new: true) { migration.down }
      end
      assert_equal version.id, version.savings_debt_card.reload.current_version_id
      assert_equal 30_000, version.reload.terms["balance_cents"]
      assert ApplicationRecord.connection.table_exists?(:savings_debt_drafts)
    end
  end

  test "PostgreSQL freezes staged reviewed input and only exact approved version can close its draft" do
    with_savings_runtime do
      savings_enroll
      draft = debt_stage
      [ -> { SavingsDebtDraft.where(id: draft.id).update_all(terms: draft.terms.merge("balance_cents" => 0)) },
        -> { SavingsDebtDraft.where(id: draft.id).update_all(status: "approved") }, -> { SavingsDebtDraft.where(id: draft.id).delete_all } ].each do |action|
        assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { action.call } }
      end
      version = debt_approve(draft)
      assert_equal version.id, draft.reload.approved_version_id
    end
  end
end
