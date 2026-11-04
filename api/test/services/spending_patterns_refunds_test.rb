require "test_helper"
require_relative "../support/savings_evidence_test_support"

class SpendingPatternsRefundsTest < ActiveSupport::TestCase
  include SavingsEvidenceTestSupport

  setup do
    @savings_user = User.create!(clerk_id: "refund-#{SecureRandom.hex(8)}", email: "refund-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @savings_household = HouseholdFinance::WorkspaceResolver.new(@savings_user).household
    @category = @savings_household.budget_categories.create!(name: "Everyday spending", stack_key: "discretionary", sort_order: 1)
  end

  test "confirmed merchant refunds change the real top flexible choices without changing approved purchases" do
    purchase("Ross", 5525)
    purchase("Kmart", 3175)
    amazon = purchase("Amazon Marketplace", 3899)
    assert_equal %w[Ross Amazon\ Marketplace Kmart], analyze[:discretionary_merchants].pluck(:label)
    refund = reviewed("Amazon refund order DEMO-8001", 1299)
    result = analyze
    assert_equal [ "Ross", "Kmart", "Amazon Marketplace" ], result[:discretionary_merchants].pluck(:label)
    assert_equal [ 5525, 3175, 2600 ], result[:discretionary_merchants].pluck(:total_cents)
    assert_equal 11_300, result[:observed_spending_cents]
    assert_equal 3899, amazon.reload.total_amount_cents
    assert_equal 1299, refund.reload.signed_amount_cents
    assert_equal 0, SourceEconomicGroupVersion.where(household: @savings_household).count
  end

  test "a linked refund is deducted only once even when more purchases share its merchant" do
    original = reviewed("Amazon Marketplace", -3899, type: "purchase")
    purchase("Amazon Marketplace", 1000)
    refund = reviewed("Amazon refund order DEMO-8001", 1299)
    source_operation(HouseholdFinance::Operations::SourceReview::EconomicLink,
      kind: "refund", base_version_id: nil, base_lock_version: 0, reason: "Reviewed refund against original order", members: [
        { source_review_version_id: original.id, role: "original_purchase", allocation_cents: 1299 },
        { source_review_version_id: refund.id, role: "refund", allocation_cents: 1299 }
      ])
    assert_equal 3600, analyze[:discretionary_merchants].sole[:total_cents]
  end

  test "excluded refunds, income, other merchants and refunds outside the window do not reduce purchases" do
    purchase("Ross", 5525)
    reviewed("Ross", 1000, disposition: "exclude")
    reviewed("Ross", 1000, type: "income")
    reviewed("Ross", 1000, on: Date.new(2026, 7, 4))
    reviewed("Rosslyn Cafe", 1000)
    assert_equal 5525, analyze[:discretionary_merchants].sole[:total_cents]
    # Refunds are capped by matching observed spending; an excess never becomes savings or negative spending.
    reviewed("Ross", 10_000)
    assert_empty analyze[:discretionary_merchants]
    assert_nil analyze[:observed_spending_cents]
    refute analyze[:savings_inferred]
  end

  test "refund reductions preserve exact cents across mixed essential and flexible splits" do
    row = purchase("Island shop", 1000)
    essential = @savings_household.budget_categories.create!(name: "Bills & essentials", stack_key: "non_discretionary", sort_order: 2)
    row.transaction_splits.sole.update!(amount_cents: 500)
    row.transaction_splits.create!(budget_category: essential, amount_cents: 500)
    reviewed("Island shop", 333)
    result = analyze
    assert_equal 667, result[:observed_spending_cents]
    assert_equal 334, result[:discretionary_merchants].sole[:total_cents]
    assert_equal 334, result[:discretionary_categories].sole[:total_cents]
  end

  private

  def analyze = SpendingPatterns::Analyzer.new(@savings_household, today: Date.new(2026, 11, 4)).call

  def purchase(merchant, cents)
    year = @savings_household.budget_years.find_or_create_by!(year: 2026)
    period = year.budget_periods.find_or_create_by!(starts_on: Date.new(2026, 10, 1)) { |row| row.ends_on = Date.new(2026, 10, 31) }
    row = @savings_household.household_transactions.create!(budget_period: period, occurred_on: Date.new(2026, 10, 14), merchant: merchant, total_amount_cents: cents, source_type: "manual_ui", status: "confirmed")
    row.transaction_splits.create!(budget_category: @category, amount_cents: cents)
    row
  end

  def reviewed(merchant, cents, type: "refund", disposition: "include", on: Date.new(2026, 10, 24))
    initial, = evidence_source(cents.abs, type: "income", on: on)
    draft = source_operation(HouseholdFinance::Operations::SourceReview::DraftStage,
      event_id: initial.financial_source_event.id, base_version_id: initial.id, base_lock_version: initial.source_review_head.reload.lock_version,
      reason: "Participant reviewed the merchant and kind", projection: { action: "none" }, facts: {
        source_account_identity_version_id: initial.source_account_identity_version_id, disposition: disposition, event_type: type,
        signed_amount_cents: cents, purchase_amount_cents: type == "purchase" ? cents.abs : nil,
        posted_on: on.iso8601, merchant: merchant, budget_category_id: type == "purchase" ? @category.id : nil,
        overlap_disposition: disposition == "exclude" ? "excluded" : "distinct", matched_version_id: nil
      })
    source_operation(HouseholdFinance::Operations::SourceReview::DraftApprove, draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest)
  end
end
