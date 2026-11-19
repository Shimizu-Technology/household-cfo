require "test_helper"

# Confirm must ask "Same purchase as …?" instead of counting a purchase twice.
# Fictional Talun household data only.
class ApiV1TransactionDraftPossibleDuplicateTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = User.create!(clerk_id: "clerk_possible_duplicate_#{SecureRandom.hex(4)}", email: "possible-duplicate-#{SecureRandom.hex(4)}@example.com",
      role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Talun Household", location: "Guam", stage: "First cohort", primary_goal: "Count each purchase once.")
    @household.household_memberships.create!(user: @user, role: "owner")
    @groceries = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 600)
  end

  test "confirm asks, then Same purchase leaves one purchase" do
    travel_to Date.new(2026, 8, 10) do
      draft = create_draft
      # The bank line is approved after she logged the purchase, so nothing was suggested yet.
      assert_empty draft.transaction_draft_matches
      bank_line = bank_purchase

      assert_no_difference("HouseholdTransaction.count") do
        post "/api/v1/transaction_drafts/#{draft.id}/confirm", headers: auth_headers, as: :json
      end

      assert_response :conflict
      body = response.parsed_body
      assert_equal "possible_duplicate", body.fetch("code")
      assert_equal [ "This looks like Payless Supermarket on Aug 3 ($103.42), which you already have. Is it the same purchase or a different one? Nothing changed." ], body.fetch("errors")
      assert_equal [ bank_line.id ], body.fetch("possible_matches").map { |match| match.fetch("transaction_id") }
      card_match = body.dig("transaction_draft", "matches").sole
      assert_equal "proposed", card_match.fetch("status")
      assert_equal "pending", draft.reload.status

      post "/api/v1/transaction_drafts/#{draft.id}/match", params: { match_id: card_match.fetch("id") }, headers: auth_headers, as: :json

      assert_response :success
      assert_equal "matched", draft.reload.status
      assert_equal [ bank_line.id ], @household.household_transactions.where(status: "confirmed").pluck(:id)
    end
  end

  test "Different purchase adds a second purchase on purpose" do
    travel_to Date.new(2026, 8, 10) do
      bank_line = bank_purchase
      draft = create_draft
      match = draft.transaction_draft_matches.proposed.sole

      assert_difference("HouseholdTransaction.count", 1) do
        post "/api/v1/transaction_drafts/#{draft.id}/confirm", params: { transaction_draft: { different_purchase: true } }, headers: auth_headers, as: :json
      end

      assert_response :success
      assert_equal "confirmed", draft.reload.status
      assert_equal "rejected", match.reload.status
      assert_equal [ bank_line.id, draft.confirmed_transaction_id ].sort, @household.household_transactions.where(status: "confirmed").pluck(:id).sort
    end
  end

  test "bulk confirm refuses a group that includes a possible duplicate" do
    travel_to Date.new(2026, 8, 10) do
      bank_purchase
      draft = create_draft

      assert_no_difference("HouseholdTransaction.count") do
        post "/api/v1/transaction_drafts/bulk_confirm", params: { transaction_draft_ids: [ draft.id ], confirmation: "CONFIRM 1", year: 2026 }, headers: auth_headers, as: :json
      end

      assert_response :unprocessable_entity
      assert_includes response.parsed_body.fetch("errors").sole, "may be a purchase you already have"
      assert_equal "pending", draft.reload.status
    end
  end

  private

  def bank_purchase
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 8, 3))
    @household.household_transactions.create!(budget_period: period, occurred_on: Date.new(2026, 8, 3), merchant: "Payless Supermarket",
      total_amount_cents: 10_342, source_type: "statement", status: "confirmed").tap do |transaction|
      transaction.transaction_splits.create!(budget_category: @groceries, amount_cents: 10_342)
    end
  end

  def create_draft
    post "/api/v1/transaction_drafts", params: { transaction_draft: { occurred_on: "2026-08-03", merchant: "Payless Supermarket", amount: "103.42", budget_category_id: @groceries.id } },
      headers: auth_headers, as: :json
    assert_response :created
    @household.transaction_drafts.find(response.parsed_body.dig("transaction_draft", "id"))
  end

  def auth_headers
    { "Authorization" => "Bearer test_token_#{@user.id}", "Idempotency-Key" => SecureRandom.uuid }
  end
end
