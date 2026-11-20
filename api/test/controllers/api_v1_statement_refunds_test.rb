require "test_helper"
require_relative "../support/savings_evidence_test_support"

# A refund reduces the category of the purchase it refunds, in the month the refund posts (Leon, 2026-11-19).
# It is never income and never a new purchase, and Budget and Mia read the same netted number.
class ApiV1StatementRefundsTest < ActionDispatch::IntegrationTest
  include SavingsEvidenceTestSupport

  setup do
    @user = User.create!(clerk_id: "refunds-#{SecureRandom.hex(8)}", email: "refunds-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @clothing = @household.budget_categories.create!(name: "Clothing", stack_key: "discretionary", sort_order: 1)
    @household_goods = @household.budget_categories.create!(name: "Household", stack_key: "discretionary", sort_order: 2)
    @groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 3)
  end

  test "a March refund for a February purchase reduces March's category in Budget and in Mia's answers, never February" do
    february = build_source([ [ "Tasi Demo Outfitters", -8425, "purchase", "2026-02-09" ] ])
    approve_all(february, category: @clothing)
    march = build_source([ [ "Tasi Demo Outfitters", 2999, "refund", "2026-03-06" ], [ "Tasi Demo Outfitters", -8425, "purchase", "2026-03-09" ] ])
    refund, purchase = march[:revision].financial_source_events.order(:position).to_a

    row = plan(march).fetch("attention").find { |item| item["event_id"] == refund.id }
    assert_equal "refund", row.fetch("kind")
    assert_equal "Is this a refund? It goes back to Clothing.", row.fetch("question")
    assert_equal "Clothing", row.fetch("category_name")
    assert_nil row.fetch("category_id"), "The purchase decides the category; nothing is saved on the refund line"
    approve(march, [ { event_id: refund.id, decision: "as_read", shown: row.slice("event_type", "category_id") } ])
    approve_all(march, category: @clothing, only: [ purchase ])

    version = SourceReviewHead.find_by!(financial_source_event: refund).approved_version
    assert_equal [ "refund", 2999, nil ], [ version.event_type, version.signed_amount_cents, version.budget_category_id ]
    assert_equal 2, @household.household_transactions.count, "A refund is never a new purchase"
    assert_empty plan(march).fetch("attention")
    assert_equal({ "counted_count" => 1, "counted_cents" => 8425, "refund_count" => 1, "refund_cents" => 2999 }, plan(march).fetch("spending").slice("counted_count", "counted_cents", "refund_count", "refund_cents"))

    assert_equal 8425, budget_actual(@clothing, month: 2)
    assert_equal 8425 - 2999, budget_actual(@clothing, month: 3)
    assert_equal 8425 - 2999, report_actual(@clothing, "2026-03-01", "2026-03-31")
    assert_equal 8425, report_actual(@clothing, "2026-02-01", "2026-02-28")
    patterns = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 4, 2), from: "2026-03-01", to: "2026-03-31").call
    assert_equal 8425 - 2999, patterns.fetch(:observed_spending_cents)
    assert_equal 1, patterns.fetch(:purchase_count)
    assert_equal [ [ "Clothing", 5426 ] ], patterns.fetch(:discretionary_categories).map { |category| category.values_at(:label, :total_cents) }
    assert_equal 8425, SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 4, 2), from: "2026-02-01", to: "2026-02-28").call.fetch(:observed_spending_cents)
    answer = HouseholdFinance::TransactionLookupAnswerer.new(@household, "How much did we spend on clothing in March 2026?", today: Date.new(2026, 4, 2)).call
    assert_includes answer, "$29.99 in refunds came back to Clothing, so it comes to $54.26."
    month = HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).plan_data, month: 3).call
    assert_equal budget_month_total(3), month.fetch(:spent_so_far_cents)
    assert_equal 8425 - 2999, month.fetch(:spent_so_far_cents)
  end

  test "a refund with no purchase to find asks which category it goes back to and counts nowhere until she says" do
    march = build_source([ [ "Merchandise refund from February clothing purchase", 2999, "refund", "2026-03-06" ] ])
    refund = march[:revision].financial_source_events.sole
    row = plan(march).fetch("attention").sole
    assert_equal [ "refund_category", "Which category does this refund go back to?", nil ], row.values_at("kind", "question", "category_id")
    assert_equal %w[edit leave_out], row.fetch("answers").pluck("id")

    approve(march, [ { event_id: refund.id, decision: "as_read", shown: row.slice("event_type", "category_id") } ])
    assert_response :conflict
    assert_nil SourceReviewHead.find_by(financial_source_event: refund)&.approved_version, "Yes with no category saves nothing"

    # Saved without a category it counts nowhere and stays on her list, like a purchase with no category.
    approve(march, [ { event_id: refund.id, decision: "edited", edit: { kind: "refund", amount_cents: 2999, merchant: row["merchant"], posted_on: "2026-03-06", category_id: nil } } ])
    assert_response :success, response.body
    assert_equal 0, budget_actual(@clothing, month: 3)
    saved = plan(march)
    assert_equal [ 1, 1 ], saved.values_at("done", "without_category")
    again = saved.fetch("attention").sole
    assert_equal "refund_category", again.fetch("kind")
    assert_equal 1, FinancialDocuments::SourceReview::ParticipantProgress.new(@household, march[:revision]).call[:without_category]

    head = SourceReviewHead.find_by!(financial_source_event: refund)
    approve(march, [ { event_id: refund.id, expected_head: again.fetch("expected_head"), decision: "edited",
      edit: { kind: "refund", amount_cents: 2999, merchant: again["merchant"], posted_on: "2026-03-06", category_id: @clothing.id } } ])
    assert_response :success, response.body
    assert_equal [ "refund", @clothing.id ], head.reload.approved_version.attributes.values_at("event_type", "budget_category_id")
    assert_equal(-2999, budget_actual(@clothing, month: 3))
    assert_empty plan(march).fetch("attention")
    assert_equal 0, FinancialDocuments::SourceReview::ParticipantProgress.new(@household, march[:revision]).call[:without_category]
  end

  test "an earlier purchase from the same store on the statement fills in the category, and Yes saves exactly that" do
    march = build_source([ [ "Island Demo Shoes", -6000, "purchase", "2026-03-02" ], [ "Island Demo Shoes", 3000, "refund", "2026-03-12" ] ])
    purchase, refund = march[:revision].financial_source_events.order(:position).to_a
    suggest(march, purchase, @clothing)
    row = plan(march).fetch("attention").find { |item| item["event_id"] == refund.id }
    assert_equal [ "refund_category", "Does this refund go back to Clothing?", @clothing.id ], row.values_at("kind", "question", "category_id")
    assert_equal %w[keep edit], row.fetch("answers").pluck("id")
    approve(march, [ { event_id: refund.id, decision: "as_read", shown: row.slice("event_type", "category_id") } ])
    assert_response :success, response.body
    assert_equal @clothing.id, SourceReviewHead.find_by!(financial_source_event: refund).approved_version.budget_category_id
    assert_equal(-3000, budget_actual(@clothing, month: 3), "Only the refund is approved so far")
    approve_all(march, category: @clothing, only: [ purchase ])
    assert_equal 3000, budget_actual(@clothing, month: 3)
  end

  test "a refund of a split purchase gives money back to each category in proportion" do
    purchase = manual_purchase("Island Demo Mart", "2026-02-14", { @groceries => 6000, @household_goods => 4000 })
    march = build_source([ [ "Island Demo Mart", 2500, "refund", "2026-03-04" ] ])
    row = plan(march).fetch("attention").sole
    assert_equal "Is this a refund? It goes back to Groceries and Household.", row.fetch("question")
    approve(march, [ { event_id: row["event_id"], decision: "as_read", shown: row.slice("event_type", "category_id") } ])
    assert_response :success, response.body
    assert_equal [ 6000, 4000 ], [ budget_actual(@groceries, month: 2), budget_actual(@household_goods, month: 2) ]
    assert_equal [ -1500, -1000 ], [ budget_actual(@groceries, month: 3), budget_actual(@household_goods, month: 3) ]
    patterns = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 4, 2), from: "2026-03-01", to: "2026-03-31").call
    assert_equal(-2500, patterns.fetch(:observed_spending_cents))
    assert_equal 0, patterns.fetch(:purchase_count)
    assert_empty patterns.fetch(:discretionary_categories), "A category refunded below zero is not somewhere she is spending"
    assert_equal 10_000, purchase.reload.total_amount_cents, "The purchase itself is never changed"
  end

  test "a refund larger than the month's category spending shows the true negative month" do
    approve_all(build_source([ [ "Tasi Demo Outfitters", -12_000, "purchase", "2026-02-09" ] ]), category: @clothing)
    march = build_source([ [ "Island Demo Socks", -1000, "purchase", "2026-03-02" ], [ "Tasi Demo Outfitters", 12_000, "refund", "2026-03-20" ] ])
    approve_all(march, category: @clothing)
    refund = march[:revision].financial_source_events.order(:position).last
    row = plan(march).fetch("attention").sole
    approve(march, [ { event_id: refund.id, decision: "as_read", shown: row.slice("event_type", "category_id") } ])
    assert_response :success, response.body
    assert_equal(-11_000, budget_actual(@clothing, month: 3))
    cell = budget_row(@clothing).fetch("months")[2]
    assert_equal(-110.0, cell.fetch("actual"))
    assert_equal cell.fetch("planned") + 110.0, cell.fetch("remaining")
    assert_equal(-11_000, report_actual(@clothing, "2026-03-01", "2026-03-31"))
    patterns = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 4, 2), from: "2026-03-01", to: "2026-03-31").call
    assert_equal(-11_000, patterns.fetch(:observed_spending_cents))
    assert_equal(-11_000, patterns.fetch(:coverage).fetch(:months).sole.fetch(:spending_cents))
    refute patterns.fetch(:savings_inferred)
    answer = HouseholdFinance::TransactionLookupAnswerer.new(@household, "How much did we spend on clothing in March 2026?", today: Date.new(2026, 4, 2)).call
    assert_includes answer, "$120 in refunds came back to Clothing, so it comes to -$110."
  end

  test "her answer for the refund's category stands, a link beats both, and a later purchase is never the original" do
    approve_all(build_source([ [ "Tasi Demo Outfitters", -5000, "purchase", "2026-02-09" ] ]), category: @clothing)
    later = build_source([ [ "Island Demo Gifts", -4000, "purchase", "2026-03-25" ] ])
    approve_all(later, category: @household_goods)
    march = build_source([ [ "Island Demo Gifts", 1000, "refund", "2026-03-06" ], [ "Tasi Demo Outfitters", 2000, "refund", "2026-03-07" ] ])
    gifts, outfitters = march[:revision].financial_source_events.order(:position).to_a
    rows = plan(march).fetch("attention").index_by { |item| item["event_id"] }
    assert_equal "refund_category", rows.fetch(gifts.id).fetch("kind"), "A purchase after the refund is not what it refunds"
    approve(march, [ { event_id: gifts.id, decision: "edited", edit: { kind: "refund", amount_cents: 1000, merchant: "Island Demo Gifts", posted_on: "2026-03-06", category_id: @groceries.id } },
      { event_id: outfitters.id, decision: "edited", edit: { kind: "refund", amount_cents: 2000, merchant: "Tasi Demo Outfitters", posted_on: "2026-03-07", category_id: @household_goods.id } } ])
    assert_response :success, response.body
    assert_equal [ -1000, 4000 - 2000, 0 ], [ budget_actual(@groceries, month: 3), budget_actual(@household_goods, month: 3), budget_actual(@clothing, month: 3) ]

    original = SourceReviewVersion.where(household: @household, event_type: "purchase", merchant: "Tasi Demo Outfitters").sole
    credit = SourceReviewHead.find_by!(financial_source_event: outfitters).approved_version
    @savings_household, @savings_user = @household, @user
    source_operation(HouseholdFinance::Operations::SourceReview::EconomicLink, kind: "refund", base_version_id: nil, base_lock_version: 0,
      reason: "Reviewed refund against original order", members: [
        { source_review_version_id: original.id, role: "original_purchase", allocation_cents: 2000 },
        { source_review_version_id: credit.id, role: "refund", allocation_cents: 2000 }
      ])
    assert_equal [ -2000, 4000 ], [ budget_actual(@clothing, month: 3), budget_actual(@household_goods, month: 3) ]
  end

  test "a line she corrected to a refund with no category can take the category it is shown" do
    march = build_source([ [ "Island Demo Shoes", -6000, "purchase", "2026-03-02" ], [ "Island Demo Shoes", 3000, "income", "2026-03-12" ] ])
    purchase, credit = march[:revision].financial_source_events.order(:position).to_a
    suggest(march, purchase, @clothing)
    approve(march, [ { event_id: credit.id, decision: "edited", edit: { kind: "refund", amount_cents: 3000, merchant: "Island Demo Shoes", posted_on: "2026-03-12", category_id: nil } } ])
    assert_response :success, response.body
    row = plan(march).fetch("attention").find { |item| item["event_id"] == credit.id }
    assert_equal [ "refund_category", "refund", @clothing.id ], row.values_at("kind", "event_type", "category_id")
    approve(march, [ { event_id: credit.id, expected_head: row.fetch("expected_head"), decision: "as_read", shown: row.slice("event_type", "category_id") } ])
    assert_response :success, response.body
    assert_equal [ "refund", @clothing.id ], SourceReviewHead.find_by!(financial_source_event: credit).approved_version.attributes.values_at("event_type", "budget_category_id")
  end

  test "the rest of a partly linked refund is never guessed from the same store" do
    approve_all(build_source([ [ "Tasi Demo Outfitters", -5000, "purchase", "2026-02-09" ] ]), category: @clothing)
    march = build_source([ [ "Tasi Demo Outfitters", 3000, "refund", "2026-03-06" ] ])
    refund = march[:revision].financial_source_events.sole
    approve(march, [ { event_id: refund.id, decision: "as_read", shown: plan(march).fetch("attention").sole.slice("event_type", "category_id") } ])
    assert_response :success, response.body
    assert_equal(-3000, budget_actual(@clothing, month: 3), "With nothing linked, the same-store purchase decides")

    original = SourceReviewVersion.where(household: @household, event_type: "purchase", merchant: "Tasi Demo Outfitters").sole
    credit = SourceReviewHead.find_by!(financial_source_event: refund).approved_version
    @savings_household, @savings_user = @household, @user
    source_operation(HouseholdFinance::Operations::SourceReview::EconomicLink, kind: "refund", base_version_id: nil, base_lock_version: 0,
      reason: "Reviewed part of a refund against the original order", members: [
        { source_review_version_id: original.id, role: "original_purchase", allocation_cents: 2000 },
        { source_review_version_id: credit.id, role: "refund", allocation_cents: 2000 }
      ])
    assert_equal 0, budget_actual(@clothing, month: 3), "The unlinked $10 is unknown, so the refund waits for her answer"
    assert_equal "refund_category", plan(march).fetch("attention").sole.fetch("kind")
  end

  test "a month whose refunds cancel its purchases is a known $0, not unknown" do
    march = build_source([ [ "Tasi Demo Outfitters", -3000, "purchase", "2026-03-02" ], [ "Tasi Demo Outfitters", 3000, "refund", "2026-03-20" ] ])
    purchase, refund = march[:revision].financial_source_events.order(:position).to_a
    approve_all(march, category: @clothing, only: [ purchase ])
    approve(march, [ { event_id: refund.id, decision: "as_read", shown: plan(march).fetch("attention").sole.slice("event_type", "category_id") } ])
    assert_response :success, response.body
    get "/api/v1/spending_report", params: { start_on: "2026-03-01", end_on: "2026-03-31" }, headers: headers
    report = response.parsed_body.fetch("spending_report")
    assert_equal true, report.fetch("actual_known")
    assert_equal 0, HouseholdFinance::Money.cents!(report.fetch("totals").fetch("actual")), "A known $0, not a missing total"
  end

  test "a refund she leaves out or calls money in never reduces spending" do
    approve_all(build_source([ [ "Tasi Demo Outfitters", -5000, "purchase", "2026-02-09" ] ]), category: @clothing)
    march = build_source([ [ "Tasi Demo Outfitters", 1000, "refund", "2026-03-06" ], [ "Tasi Demo Outfitters", 700, "refund", "2026-03-07" ] ])
    left, income = march[:revision].financial_source_events.order(:position).to_a
    approve(march, [ { event_id: left.id, decision: "leave_out" },
      { event_id: income.id, decision: "edited", edit: { kind: "money_in", amount_cents: 700, merchant: "Tasi Demo Outfitters", posted_on: "2026-03-07", category_id: @clothing.id } } ])
    assert_response :success, response.body
    assert_nil SourceReviewHead.find_by!(financial_source_event: income).approved_version.budget_category_id
    assert_equal 0, budget_actual(@clothing, month: 3)
    assert_empty HouseholdFinance::RefundCredits.new(@household).call
  end

  private

  def headers = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def plan(source)
    get "/api/v1/document_imports/#{source[:import].id}/source_review", params: { revision_id: source[:revision].id }, headers: headers
    assert_response :success
    response.parsed_body.dig("source_review", "participant_review", "plan")
  end

  def approve(source, lines)
    post "/api/v1/document_imports/#{source[:import].id}/review/approve_lines", params: { revision_id: source[:revision].id, input: { lines: lines } },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
  end

  # Every purchase line on the statement saved with the given category, exactly as a participant would choose it.
  def approve_all(source, category:, only: nil)
    events = only || source[:revision].financial_source_events.order(:position).select { |event| event.signed_amount_cents.negative? }
    approve(source, events.map { |event| { event_id: event.id, decision: "edited", edit: { kind: "spending", amount_cents: -event.signed_amount_cents, merchant: event.financial_source_evidence.payload["merchant"], posted_on: event.posted_on.iso8601, category_id: category.id } } })
    assert_response :success, response.body
  end

  def suggest(source, event, category)
    @household.transaction_drafts.create!(financial_document_import: source[:import], financial_source_event: event, occurred_on: event.posted_on, merchant: event.financial_source_evidence.payload["merchant"],
      total_amount_cents: event.expense_amount_cents, budget_category: category, source_type: "statement", status: "pending")
  end

  def manual_purchase(merchant, on, parts)
    date = Date.iso8601(on)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: date.year).current_period_for(date)
    row = @household.household_transactions.create!(budget_period: period, occurred_on: date, merchant: merchant, total_amount_cents: parts.values.sum, source_type: "receipt", status: "confirmed")
    parts.each { |category, cents| row.transaction_splits.create!(budget_category: category, amount_cents: cents) }
    row
  end

  def budget_row(category)
    get "/api/v1/budget", params: { year: 2026 }, headers: headers
    assert_response :success
    plan = response.parsed_body.fetch("annual_plan")
    plan.fetch("rows").find { |row| row["id"] == category.id }
  end

  def budget_actual(category, month:)
    HouseholdFinance::Money.cents(budget_row(category).fetch("months")[month - 1].fetch("actual"))
  end

  def budget_month_total(month)
    get "/api/v1/budget", params: { year: 2026 }, headers: headers
    response.parsed_body.fetch("annual_plan").fetch("rows").sum { |row| HouseholdFinance::Money.cents(row.fetch("months")[month - 1].fetch("actual")) }
  end

  def report_actual(category, start_on, end_on)
    get "/api/v1/spending_report", params: { start_on: start_on, end_on: end_on }, headers: headers
    assert_response :success
    HouseholdFinance::Money.cents(response.parsed_body.fetch("spending_report").fetch("categories").find { |row| row["id"] == category.id }.fetch("actual"))
  end

  # rows: [merchant, signed cents, kind, posted date]
  def build_source(rows)
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "talun-demo.csv", content_type: "text/csv", byte_size: 10,
      s3_key: "synthetic/#{SecureRandom.hex(8)}.csv", checksum_sha256: SecureRandom.hex(32))
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    events = rows.each_with_index.map do |(name, cents, type, on), index|
      { account_key: "talun-card", row_kind: "posted", limitations: [], event_type: type, signed_amount_cents: cents, posted_on: on, merchant: name, locator: { page: 1, row: index + 1 } }
    end
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "talun-card", account_basis: "liability", label: "Talun Demo Visa" } ], events: events, reported_row_count: events.length },
      coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
    document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: document)
  end
end
