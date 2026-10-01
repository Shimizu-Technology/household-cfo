require "test_helper"

class HouseholdFinanceMiaAccountActionDraftsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "mia_asset_#{SecureRandom.hex(4)}", email: "mia-asset-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: Date.current.year)
  end

  test "Mia prepares a typed account create and applies it only after review" do
    result = build(type: "create_account", account_name: "Emergency reserve", account_type: "emergency_fund", amount: "unknown")
    assert_equal "asset_plan", result.proposal.draft_type
    assert_empty @household.accounts
    draft = persist(result.proposal)
    item = draft.mia_action_items.sole
    assert_equal "account.record.create", item.operation_key
    assert_equal false, item.prepared_operation.dig("normalized_input", "balance_known")
    review = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields)
    assert_equal "Not entered", review.find { |field| field.fetch(:label) == "Approved balance" }.fetch(:after)

    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call
    assert result.success?, result.errors.to_sentence
    account = @household.accounts.find_by!(label: "Emergency reserve")
    assert_not account.balance_known?
    assert_equal "mia", account.source_type
  end

  test "Mia review distinguishes unknown from known zero" do
    account = @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 0, balance_known: false)
    draft = persist(build(type: "update_account", account_id: account.id, account_name: account.label, amount: "0").proposal)
    field = HouseholdFinance::MiaActionDraftPresenter.new(draft).call.fetch(:items).sole.fetch(:review_fields).find { |item| item.fetch(:label) == "Approved balance" }
    assert_equal [ "Not entered", "$0.00" ], field.values_at(:before, :after)
  end

  test "Mia links reconciles and unlinks a Plaid observation only after each review" do
    account = @household.accounts.create!(label: "Checking", account_type: "checking", balance_cents: 100_00, balance_known: true)
    item = @household.plaid_items.create!(
      connected_by_user: @user, plaid_item_id: "item-#{SecureRandom.hex(4)}", access_token: "token",
      institution_name: "Test Bank", environment: "sandbox", consented_at: Time.current,
      consent_policy_version: "test", last_synced_at: Time.current
    )
    observation = item.plaid_accounts.create!(
      plaid_account_id: "account-#{SecureRandom.hex(4)}", name: "Checking", account_type: "depository",
      account_subtype: "checking", current_balance_cents: 125_00, active: true
    )

    link_draft = persist(build(type: "link_plaid_account", account_id: account.id, account_name: account.label, plaid_account_id: observation.id).proposal)
    assert_nil account.reload.plaid_account_id
    assert HouseholdFinance::MiaActionDraftApplier.new(link_draft, user: @user).call.success?
    assert_equal observation.id, account.reload.plaid_account_id
    assert_equal 100_00, account.balance_cents

    reconcile_draft = persist(build(type: "reconcile_plaid_account", account_id: account.id, account_name: account.label, reconcile_decision: "accept_observed").proposal)
    assert_equal 100_00, account.reload.balance_cents
    assert HouseholdFinance::MiaActionDraftApplier.new(reconcile_draft, user: @user).call.success?
    assert_equal 125_00, account.reload.balance_cents

    unlink_draft = persist(build(type: "unlink_plaid_account", account_id: account.id, account_name: account.label).proposal)
    assert_equal observation.id, account.reload.plaid_account_id
    assert HouseholdFinance::MiaActionDraftApplier.new(unlink_draft, user: @user).call.success?
    assert_nil account.reload.plaid_account_id
    assert_equal 125_00, account.balance_cents
  end

  private

  def build(command)
    HouseholdFinance::MiaActionDraftBuilder.new(@household, user: @user, annual_budget_manager: @manager, raw_input: "account command", command: command).call
  end

  def persist(proposal)
    session = @household.chat_sessions.find_or_create_by!(user: @user) { |record| record.title = "Ask Mia" }
    proposal.create_draft!(source_chat_message: session.chat_messages.create!(role: "user", content: "Update my account"), assistant_chat_message: session.chat_messages.create!(role: "assistant", content: "Review this change"))
  end
end
