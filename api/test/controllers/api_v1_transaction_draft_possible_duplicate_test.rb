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
      assert_equal [ "This looks like Payless Supermarket on Aug 3 ($103.42), which you already have. Is it the same purchase or a different one? Nothing was added to your spending." ], body.fetch("errors")
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

  test "a correction that only then matches is kept with the question, and Same purchase leaves one purchase" do
    travel_to Date.new(2026, 7, 1) do
      bank_line = bank_purchase(merchant: "Tasi Demo Home Store", cents: 3_488, on: Date.new(2026, 6, 23))
      receipt = create_draft(merchant: "Tasi Demo Home Store", amount: "184.88", on: "2026-06-23")
      assert_empty receipt.transaction_draft_matches, "the misread total matches nothing"

      assert_no_difference("HouseholdTransaction.count") do
        post "/api/v1/transaction_drafts/#{receipt.id}/confirm", params: { transaction_draft: { amount: "34.88" } }, headers: auth_headers, as: :json
      end

      assert_response :conflict
      body = response.parsed_body
      assert_equal "possible_duplicate", body.fetch("code")
      assert_equal [ bank_line.id ], body.fetch("possible_matches").map { |match| match.fetch("transaction_id") }
      assert_equal 3_488, body.dig("transaction_draft", "amount_cents"), "the card shows her corrected amount"
      assert_equal "pending", body.dig("transaction_draft", "status")
      card_match = body.dig("transaction_draft", "matches").sole
      assert_equal [ "proposed", bank_line.id ], [ card_match.fetch("status"), card_match.dig("transaction", "id") ]
      receipt.reload
      assert_equal [ "pending", 3_488, [ 3_488 ] ], [ receipt.status, receipt.total_amount_cents, receipt.transaction_draft_splits.pluck(:amount_cents) ]

      post "/api/v1/transaction_drafts/#{receipt.id}/match", params: { match_id: card_match.fetch("id") }, headers: auth_headers, as: :json

      assert_response :success
      assert_equal [ "matched", bank_line.id ], [ receipt.reload.status, receipt.matched_transaction_id ]
      assert_equal [ bank_line.id ], @household.household_transactions.where(status: "confirmed").pluck(:id)
    end
  end

  test "Different purchase with the same correction adds one purchase at the corrected amount" do
    travel_to Date.new(2026, 7, 1) do
      bank_line = bank_purchase(merchant: "Tasi Demo Home Store", cents: 3_488, on: Date.new(2026, 6, 23))
      receipt = create_draft(merchant: "Tasi Demo Home Store", amount: "184.88", on: "2026-06-23")
      post "/api/v1/transaction_drafts/#{receipt.id}/confirm", params: { transaction_draft: { amount: "34.88" } }, headers: auth_headers, as: :json
      assert_response :conflict

      assert_difference("HouseholdTransaction.count", 1) do
        post "/api/v1/transaction_drafts/#{receipt.id}/confirm", params: { transaction_draft: { amount: "34.88", different_purchase: true } }, headers: auth_headers, as: :json
      end

      assert_response :success
      added = receipt.reload.confirmed_transaction
      assert_equal 3_488, added.total_amount_cents
      assert_equal [ bank_line.id, added.id ].sort, @household.household_transactions.where(status: "confirmed").pluck(:id).sort
      assert_equal [ "rejected" ], receipt.transaction_draft_matches.map(&:status)
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

  def bank_purchase(merchant: "Payless Supermarket", cents: 10_342, on: Date.new(2026, 8, 3))
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: on.year).current_period_for(on)
    @household.household_transactions.create!(budget_period: period, occurred_on: on, merchant: merchant,
      total_amount_cents: cents, source_type: "statement", status: "confirmed").tap do |transaction|
      transaction.transaction_splits.create!(budget_category: @groceries, amount_cents: cents)
    end
  end

  def create_draft(merchant: "Payless Supermarket", amount: "103.42", on: "2026-08-03")
    post "/api/v1/transaction_drafts", params: { transaction_draft: { occurred_on: on, merchant: merchant, amount: amount, budget_category_id: @groceries.id } },
      headers: auth_headers, as: :json
    assert_response :created
    @household.transaction_drafts.find(response.parsed_body.dig("transaction_draft", "id"))
  end

  def auth_headers
    { "Authorization" => "Bearer test_token_#{@user.id}", "Idempotency-Key" => SecureRandom.uuid }
  end
end
