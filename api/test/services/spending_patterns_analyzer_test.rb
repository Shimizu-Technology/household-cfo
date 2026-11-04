require "test_helper"
require_relative "../support/savings_evidence_test_support"

class SpendingPatternsAnalyzerTest < ActiveSupport::TestCase
  include SavingsEvidenceTestSupport
  setup do
    @user = User.create!(clerk_id: "patterns-#{SecureRandom.hex(8)}", email: "patterns-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @category = @household.budget_categories.create!(name: "Optional shopping", stack_key: "discretionary", sort_order: 1)
  end

  test "coaching groups location parenthetical and store number variants with short names" do
    originals = [ "Island Table - Tamuning (includes tip)", "Island Table - Dededo", "Island Table (includes tip) #123" ]
    originals.each { |name| purchase(Date.new(2026, 10, 5), name, 2240) }
    purchase(Date.new(2026, 10, 6), "Ross #123", 5525)
    result = analyze
    assert_equal [ [ "Island Table", 6720 ], [ "Ross", 5525 ] ], result[:discretionary_merchants].map { |row| [ row[:label], row[:total_cents] ] }
    assert_equal "Island Table", result[:candidate_changes].first[:merchant]
    assert_equal 3360, result[:candidate_changes].first[:monthly_impact_cents]
    originals.each { |name| assert @household.household_transactions.exists?(merchant: name) }
  end

  test "three full months use exact reviewed amounts and ignore the current month, ignored purchases and other households" do
    [ 8, 9, 10 ].each { |month| purchase(Date.new(2026, month, 5), "POS DEBIT 1234 ROSS STORES #567 XXXX1234", 20_000) }
    purchase(Date.new(2026, 11, 1), "Current month", 999_999)
    purchase(Date.new(2026, 10, 2), "Ignored", 888_888, status: "ignored")
    other_user = User.create!(clerk_id: "patterns-other-#{SecureRandom.hex(8)}", email: "patterns-other-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    other = HouseholdFinance::WorkspaceResolver.new(other_user).household
    other_category = other.budget_categories.create!(name: "Optional shopping", stack_key: "discretionary", sort_order: 1)
    purchase(Date.new(2026, 9, 9), "Other household Ross", 777_777, household: other, category: other_category)
    result = analyze
    assert_equal({ start_on: "2026-08-01", end_on: "2026-10-31" }, result[:window])
    assert_equal 60_000, result[:observed_spending_cents]
    assert_equal "Ross", result[:discretionary_merchants].sole[:label]
    assert_equal 20_000, result[:discretionary_merchants].sole[:monthly_average_cents]
    assert_equal 10_000, result[:candidate_changes].sole[:monthly_impact_cents]
    assert_empty result[:possible_subscriptions], "Repeated retail visits are not subscriptions"
    assert_equal "partial", result[:coverage][:status]
    assert_equal "unknown", result[:coverage][:account_completeness]
    refute result[:savings_inferred]
  end

  test "missing months and no purchases stay unknown without dividing by missing months" do
    purchase(Date.new(2026, 8, 5), "Ross", 20_000)
    purchase(Date.new(2026, 10, 5), "Ross", 10_000)
    result = analyze
    assert_nil result[:coverage][:months][1][:spending_cents]
    assert_equal 15_000, result[:merchants].sole[:monthly_average_cents]
    assert_empty result[:coverage][:accounts]
    @household.household_transactions.update_all(status: "ignored")
    assert_nil analyze[:observed_spending_cents]
    assert_empty analyze[:candidate_changes]
  end

  test "real bank descriptors retain the Ross 600 and Kmart 360 comparison" do
    [ 8, 9, 10 ].each do |month|
      purchase(Date.new(2026, month, 5), "POS DEBIT 1234 ROSS STORES #567 XXXX1234", 20_000)
      purchase(Date.new(2026, month, 9), "POS DEBIT 1234 KMART #101 XXXX1234", 12_000)
    end
    merchants = analyze[:discretionary_merchants].to_h { |row| [ row[:label], row[:total_cents] ] }
    assert_equal({ "Ross" => 60_000, "Kmart" => 36_000 }, merchants)
  end

  test "a long account number in a merchant never reaches what Mia quotes, while the stored wording stays" do
    stored = purchase(Date.new(2026, 10, 5), "Coast360 payment 00009900", 4500)
    labels = analyze[:merchants].pluck(:label)
    assert_equal [ "Coast360 payment ····9900" ], labels
    assert_equal "Coast360 payment 00009900", stored.reload.merchant
  end

  test "grouping normalizes locations without rewriting participant merchant wording or numeric names" do
    [ "Ross Dress for Less", "ROSS DRESS FOR LESS #123 DEDEDO GU", "ROSS STORES #456 HAGATNA GU", "ROSS DRESS FOR LESS #123 HONOLULU HI" ].each do |merchant|
      purchase(Date.new(2026, 10, 5), merchant, 1000)
    end
    coffee = purchase(Date.new(2026, 10, 6), "CARD PURCHASE 1776 COFFEE", 500)
    merchants = analyze[:merchants].to_h { |row| [ row[:label], row[:total_cents] ] }
    assert_equal({ "Ross" => 4000, "1776 COFFEE" => 500 }, merchants)
    assert_equal "CARD PURCHASE 1776 COFFEE", coffee.reload.merchant
    assert @household.household_transactions.exists?(merchant: "Ross Dress for Less")
  end

  test "a selected window loads only the transactions it analyzes" do
    purchase(Date.new(2025, 1, 5), "Old purchase", 90_000)
    purchase(Date.new(2026, 10, 5), "Ross", 20_000)
    purchase(Date.new(2026, 11, 1), "Current month", 80_000)
    loaded = 0
    observer = lambda do |*args|
      payload = args.last
      loaded += payload[:record_count] if payload[:class_name] == "HouseholdTransaction"
    end
    result = ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") do
      SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: "2026-10-01", to: "2026-10-31").call
    end
    assert_equal 1, loaded
    assert_equal 20_000, result[:observed_spending_cents]
    assert_equal "Ross", result[:merchants].sole[:label]
  end

  test "small purchases reveal weekday and end-of-month clusters without guessing motivation" do
    [ Date.new(2026, 10, 23), Date.new(2026, 10, 24), Date.new(2026, 10, 30) ].each { |date| purchase(date, "Kopi", 650) }
    result = analyze
    cluster = result[:small_purchase_clusters].find { |row| row[:label] == "Friday through Sunday" }
    assert_equal 3, cluster[:purchase_count]
    assert_equal 1950, cluster[:total_cents]
    assert result[:small_purchase_clusters].any? { |row| row[:label] == "the end of the month" }
  end

  test "repeated same-date same-amount purchases are possible subscriptions, never confirmed subscriptions" do
    [ 8, 9, 10 ].each { |month| purchase(Date.new(2026, month, 8), "Stream service", 1599) }
    result = analyze
    assert_equal({ merchant: "Stream service", typical_amount_cents: 1599, observed_payments: 3, confirmed_subscription: false }, result[:possible_subscriptions].sole)
    assert_raises(ArgumentError) { SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: "2026-11-01", to: "2026-12-01").call }
  end

  test "essential categories and merchant names alone never become discretionary cuts" do
    @category.update!(stack_key: "non_discretionary")
    purchase(Date.new(2026, 10, 8), "Ross", 20_000)
    assert_equal 20_000, analyze[:observed_spending_cents]
    assert_empty analyze[:discretionary_merchants]
    assert_empty analyze[:candidate_changes]
  end

  test "reviewed statement heads count once beside their projection and retained old financial pictures are excluded" do
    @savings_household, @savings_user = @household, @user
    source, _import = evidence_source(2_000, type: "income", on: Date.new(2026, 10, 5))
    identity = source.source_account_identity_version
    draft = source_operation(HouseholdFinance::Operations::SourceReview::DraftStage,
      event_id: source.financial_source_event.id, base_version_id: source.id, base_lock_version: source.source_review_head.reload.lock_version,
      reason: "Reviewed synthetic category and expense", projection: { action: "create" }, facts: {
        source_account_identity_version_id: identity.id, disposition: "include", event_type: "purchase", signed_amount_cents: -2_000,
        purchase_amount_cents: 2_000, posted_on: "2026-10-05", merchant: "Kmart", budget_category_id: @category.id,
        overlap_disposition: "distinct", matched_version_id: nil })
    source_operation(HouseholdFinance::Operations::SourceReview::DraftApprove, draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest)
    assert_equal 1, @household.household_transactions.count
    result = analyze
    assert_equal 2_000, result[:observed_spending_cents]
    assert_equal 1, result[:purchase_count]
    assert_equal [ "Synthetic reserve account" ], result[:coverage][:accounts]
    @household.update!(financial_generation: 1)
    FinancialPicture.set(household_id: @household.id, generation: 1) do
      assert_nil analyze[:observed_spending_cents]
      assert_empty analyze[:coverage][:accounts]
    end
  end

  test "subscription wording needs near-identical amounts and a regular monthly cadence" do
    [ 8, 9, 10 ].each { |month| purchase(Date.new(2026, month, 8), "Island Gym", 5000) }
    assert_equal "Island Gym", analyze[:possible_subscriptions].sole[:merchant]
    @household.household_transactions.find_by(occurred_on: Date.new(2026, 9, 8)).update!(total_amount_cents: 5400)
    assert_empty analyze[:possible_subscriptions]
    @household.household_transactions.find_by(occurred_on: Date.new(2026, 9, 8)).update!(total_amount_cents: 5000, occurred_on: Date.new(2026, 9, 22))
    assert_empty analyze[:possible_subscriptions]
  end

  test "same day-of-month in nonconsecutive months is not a monthly subscription" do
    [ 6, 8, 10 ].each { |month| purchase(Date.new(2026, month, 8), "Software subscription", 1599) }
    result = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: "2026-06-01").call
    assert_empty result[:possible_subscriptions]
  end

  private
  def analyze = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2)).call
  def purchase(date, merchant, cents, status: "confirmed", household: @household, category: @category)
    year = household.budget_years.find_or_create_by!(year: date.year)
    period = year.budget_periods.find_or_create_by!(starts_on: date.beginning_of_month) { |row| row.ends_on = date.end_of_month }
    row = household.household_transactions.create!(budget_period: period, occurred_on: date, merchant: merchant, total_amount_cents: cents, source_type: "statement", status: status)
    row.transaction_splits.create!(budget_category: category, amount_cents: cents)
    row
  end
end
