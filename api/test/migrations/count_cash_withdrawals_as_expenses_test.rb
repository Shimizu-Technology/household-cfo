require "test_helper"
require Rails.root.join("db/migrate/20261119090000_count_cash_withdrawals_as_expenses").to_s

class CountCashWithdrawalsAsExpensesTest < ActiveSupport::TestCase
  setup do
    user = User.create!(clerk_id: "cash-migration-#{SecureRandom.hex(8)}", email: "cash-migration-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: user, name: "Tasi Demo")
    @revision = FinancialExtractionRevision.create!(household: @household, revision_number: 1, contract_version: "test", payload_digest: SecureRandom.hex(32), source_document_identity: SecureRandom.hex(32))
    @account = FinancialSourceAccount.create!(household: @household, financial_extraction_revision: @revision, account_basis: "asset", source_key: "tasi-demo")
  end

  test "backfill is idempotent and updates only readable posted negative cash withdrawals with a date and missing expense" do
    eligible = event
    untouched = [
      event(row_kind: "informational"), event(row_kind: "unresolved"),
      event(signed_amount_cents: 8000), event(signed_amount_cents: 0), event(signed_amount_cents: nil),
      event(posted_on: nil), event(limitations: [ "transaction_direction_unclear" ]),
      event(event_type: "purchase"), event(event_type: "transfer"),
      event(expense_amount_cents: 7900)
    ]
    before = untouched.to_h { |row| [ row.id, row.attributes ] }
    migration = CountCashWithdrawalsAsExpenses.new
    migration.migrate(:up)
    assert_equal 8000, eligible.reload.expense_amount_cents
    assert eligible.expense_projection_eligible?
    assert_equal before, untouched.to_h { |row| [ row.id, row.reload.attributes ] }
    after = eligible.attributes
    migration.migrate(:up)
    assert_equal after, eligible.reload.attributes
    assert_equal before, untouched.to_h { |row| [ row.id, row.reload.attributes ] }
    # The migration restores immutability and the expanded constraint permits new withdrawals.
    assert_equal 8000, event(expense_amount_cents: 8000).expense_amount_cents
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        FinancialSourceEvent.where(id: eligible.id).update_all(expense_amount_cents: 9000)
      end
    end
  end

  test "rollback does not erase expense history" do
    assert_raises(ActiveRecord::IrreversibleMigration) { CountCashWithdrawalsAsExpenses.new.migrate(:down) }
  end

  private

  def event(**attributes)
    position = @revision.financial_source_events.count
    FinancialSourceEvent.create!({ household: @household, financial_extraction_revision: @revision, financial_source_account: @account,
      position: position, row_identity: "tasi-demo-#{position}", row_kind: "posted", event_type: "cash_withdrawal",
      signed_amount_cents: -8000, posted_on: Date.new(2026, 10, 4) }.merge(attributes))
  end
end
