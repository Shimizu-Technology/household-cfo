require "test_helper"

class HouseholdFinanceAccountOperationsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "account_ops_#{SecureRandom.hex(4)}", email: "account-ops-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
  end

  test "unknown and explicit zero balances stay distinct" do
    unknown = @runner.run(operation_key: "account.record.create", input: { label: "Savings", account_type: "savings", balance: nil }, idempotency_key: "unknown").subject
    zero = @runner.run(operation_key: "account.record.create", input: { label: "Checking", account_type: "checking", balance: 0 }, idempotency_key: "zero").subject

    assert_not unknown.balance_known?
    assert_nil unknown.balance_as_of_on
    assert zero.balance_known?
    assert_equal 0, zero.balance_cents
    assert_equal [ unknown.id ], HouseholdFinance::AssetPortfolio.new(@household).as_json.fetch(:unknown_balance_account_ids)
  end

  test "only active records count and restore blocks a case insensitive duplicate" do
    account = @household.accounts.create!(label: "Reserve", account_type: "savings", balance_cents: 25_000)
    @runner.run(operation_key: "account.record.archive", input: { account_id: account.id }, idempotency_key: "archive")
    assert_equal 0, HouseholdFinance::AssetPortfolio.new(@household.reload).liquid_balance_cents

    @household.accounts.create!(label: "reserve", account_type: "savings", balance_cents: 10_000)
    error = assert_raises(ArgumentError) do
      @runner.run(operation_key: "account.record.restore", input: { account_id: account.id }, idempotency_key: "restore")
    end
    assert_match(/active account already uses/i, error.message)
    assert_not account.reload.active?
  end

  test "portfolio knowledge requires complete liquid and nonliquid records" do
    @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 5_000, balance_known: true)
    property = @household.accounts.create!(label: "Home", account_type: "property", balance_cents: 0, balance_known: false)
    portfolio = HouseholdFinance::AssetPortfolio.new(@household)

    assert portfolio.liquid_balance_known?
    assert_not portfolio.nonliquid_balance_known?
    assert_not portfolio.total_balance_known?
    assert_equal 5_000, portfolio.total_balance_cents

    property.update!(balance_cents: 0, balance_known: true)
    assert HouseholdFinance::AssetPortfolio.new(@household.reload).total_balance_known?
  end

  test "Plaid link is observation only until a reviewed reconcile accepts it" do
    observed = create_plaid_account(current_balance_cents: 123_45)
    canonical = @household.accounts.create!(label: "Everyday", account_type: "checking", balance_cents: 100_00, balance_known: true)

    @runner.run(operation_key: "account.plaid.link", input: { account_id: canonical.id, plaid_account_id: observed.id }, idempotency_key: "link")
    assert_equal 100_00, canonical.reload.balance_cents
    assert_equal observed.id, canonical.plaid_account_id

    @runner.run(operation_key: "account.plaid.reconcile", input: { account_id: canonical.id, decision: "accept_observed" }, idempotency_key: "accept")
    assert_equal 123_45, canonical.reload.balance_cents
    assert canonical.balance_known?
    assert_equal "plaid", canonical.source_type
    assert canonical.plaid_reconciled_at.present?
  end

  test "creating from a reviewed Plaid balance records Plaid provenance and observation date" do
    observed = create_plaid_account(current_balance_cents: 250_00)
    synced_on = observed.plaid_item.last_synced_at.to_date

    account = @runner.run(
      operation_key: "account.record.create",
      input: { label: "Bank checking", account_type: "checking", balance_cents: 250_00, balance_known: true, plaid_account_id: observed.id },
      idempotency_key: "plaid-create"
    ).subject

    assert_equal "plaid", account.source_type
    assert_equal synced_on, account.balance_as_of_on
    assert_equal observed.plaid_item.last_synced_at.to_i, account.plaid_reconciled_at.to_i
  end

  test "prepared reconciliation fails when the observation changes" do
    observed = create_plaid_account(current_balance_cents: 100_00)
    canonical = @household.accounts.create!(label: "Everyday", account_type: "checking", balance_cents: 90_00, plaid_account: observed)
    operation = HouseholdFinance::Operations::Account::PlaidReconcile.new(@household)
    prepared = operation.prepare(account_id: canonical.id, decision: "accept_observed")
    observed.update!(current_balance_cents: 110_00)

    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) do
      @runner.run_prepared(prepared: prepared.as_json, prepared_fingerprint: prepared.fingerprint, idempotency_key: "stale", source: "mia")
    end
    assert_equal 90_00, canonical.reload.balance_cents
  end

  test "unlinking and relinking an older observation always requires a new reconciliation" do
    newer = create_plaid_account(current_balance_cents: 140_00)
    older = create_plaid_account(current_balance_cents: 120_00)
    older.plaid_item.update!(last_synced_at: 2.days.ago)
    canonical = @household.accounts.create!(
      label: "Everyday", account_type: "checking", balance_cents: 140_00, balance_known: true,
      plaid_account: newer, plaid_reconciled_at: Time.current
    )

    @runner.run(operation_key: "account.plaid.unlink", input: { account_id: canonical.id }, idempotency_key: "unlink-newer")
    assert_nil canonical.reload.plaid_reconciled_at

    @runner.run(operation_key: "account.plaid.link", input: { account_id: canonical.id, plaid_account_id: older.id }, idempotency_key: "link-older")
    assert_equal older.id, canonical.reload.plaid_account_id
    assert_nil canonical.plaid_reconciled_at
  end

  private

  def create_plaid_account(current_balance_cents:)
    item = @household.plaid_items.create!(
      connected_by_user: @user, plaid_item_id: "item-#{SecureRandom.hex(4)}", access_token: "token",
      institution_name: "Test Bank", environment: "sandbox", consented_at: Time.current,
      consent_policy_version: "test", last_synced_at: Time.current
    )
    item.plaid_accounts.create!(
      plaid_account_id: "account-#{SecureRandom.hex(4)}", name: "Checking", account_type: "depository",
      account_subtype: "checking", current_balance_cents: current_balance_cents, active: true
    )
  end
end
