require "test_helper"

# A purchase she confirmed before its bank line was approved (a receipt, chat, check-in, form or Plaid purchase) is
# asked about on the statement: "Same purchase as your receipt from …?". "Same purchase" counts it once, with her
# receipt's categories; "Different purchase" counts both on purpose. Nothing is merged or counted twice without her.
class ApiV1StatementConfirmedPurchaseTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "same-purchase-#{SecureRandom.hex(8)}", email: "same-purchase-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    @household_goods = @household.budget_categories.create!(name: "Household", stack_key: "discretionary", sort_order: 2)
    @medical = @household.budget_categories.create!(name: "Medical", stack_key: "discretionary", sort_order: 3)
  end

  test "a receipt confirmed first is asked about on its bank line, and Same purchase counts it once with the receipt's split" do
    receipt = purchase("Payless Supermarkets", "2026-08-03", { @groceries => 7342, @household_goods => 1800, @medical => 1200 })
    statement = build_source([ [ "POS PURCHASE PAYLESS SUPERMARKET #12 TAMUNING GU", -10_342, "purchase", "2026-08-04" ] ])
    line = statement[:revision].financial_source_events.sole

    review = plan(statement)
    row = review.fetch("attention").sole
    assert_equal "same_purchase", row.fetch("kind")
    assert_equal "Same purchase as your receipt from Payless Supermarkets on Aug 3 ($103.42)?", row.fetch("question")
    assert_equal [ [ "same_purchase", "Same purchase" ], [ "different", "Different purchase" ] ], row.fetch("answers").map { |answer| answer.values_at("id", "label") }
    assert_equal({ "transaction_id" => receipt.id, "merchant" => "Payless Supermarkets", "occurred_on" => "2026-08-03", "amount_cents" => 10_342, "source_type" => "receipt",
      "categories" => %w[Groceries Household Medical] }, row.fetch("purchase_match"))
    assert_empty review.fetch("ready_event_ids"), "Approve all never covers a line that may be a purchase she already has"

    # Neither "Approve the rest" nor a plain Yes can count it.
    approve(statement, [ { event_id: line.id, decision: "as_read", shown: row.slice("event_type", "category_id") } ], expect_ready_ids: [ line.id ])
    assert_response :conflict
    approve(statement, [ { event_id: line.id, decision: "as_read", shown: row.slice("event_type", "category_id") } ])
    assert_response :conflict
    # The line sheet can't count it either until she answers.
    approve(statement, [ edit_entry(line, @groceries) ])
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors").join, "Same purchase as your receipt from Payless Supermarkets on Aug 3 ($103.42)? Answer Same purchase or Different purchase first."
    assert_nil SourceReviewHead.find_by(financial_source_event: line)&.approved_version

    same_purchase(statement, line, row)
    assert_response :success, response.body
    version = SourceReviewHead.find_by!(financial_source_event: line).approved_version
    assert_equal [ "match", receipt.id, nil, "match" ], version.attributes.values_at("disposition", "matched_transaction_id", "budget_category_id", "overlap_disposition")
    assert_nil version.source_projection_revision, "No second purchase is made from the bank line"
    assert_equal [ receipt.id ], @household.household_transactions.where(status: %w[confirmed reconciled]).pluck(:id)
    assert_nil receipt.reload.financial_source_event_id, "Her receipt stays her receipt"

    # Budget, the spending report and Mia's spending patterns all read one purchase, split as on the receipt.
    assert_equal [ 7342, 1800, 1200 ], [ @groceries, @household_goods, @medical ].map { |category| budget_actual(category, month: 8) }
    assert_equal 10_342, report_total("2026-08-01", "2026-08-31")
    patterns = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 9, 2), from: "2026-08-01", to: "2026-08-31").call
    assert_equal [ 10_342, 1 ], patterns.values_at(:observed_spending_cents, :purchase_count)

    saved = plan(statement)
    assert_empty saved.fetch("attention")
    assert_equal [ 1, 1 ], saved.values_at("total", "done")
    assert_equal({ "counted_count" => 1, "counted_cents" => 10_342 }, saved.fetch("spending").slice("counted_count", "counted_cents"))
    record = review_rows(statement).fetch(line.id.to_s).fetch("approved")
    assert_equal({ "transaction_id" => receipt.id, "current" => true }, record.fetch("matched_purchase").slice("transaction_id", "current"))
    assert_equal receipt.id, record.dig("facts", "matched_transaction_id")
    state = FinancialDocuments::SourceReview::ApprovalState.new(@household, statement[:revision]).call
    refute_includes state[:deficiencies], "matched_source_fact_changed"

    # The same answer again changes nothing.
    same_purchase(statement, line, row.merge("expected_head" => saved_head(line)))
    assert_response :success, response.body
    assert_equal({ "approved" => 0, "unchanged" => 1 }, response.parsed_body.fetch("result").slice("approved", "unchanged"))
  end

  test "Different purchase counts the bank line as well, on purpose" do
    purchase("Payless Supermarkets", "2026-08-03", { @groceries => 3488 }, source_type: "manual_chat")
    statement = build_source([ [ "PAYLESS SUPERMARKETS", -3488, "purchase", "2026-08-03" ] ])
    line = statement[:revision].financial_source_events.sole
    row = plan(statement).fetch("attention").sole
    assert_equal "Same purchase as Payless Supermarkets on Aug 3 ($34.88), already in your spending?", row.fetch("question")

    approve(statement, [ { event_id: line.id, decision: "different", shown: row.slice("event_type", "category_id"), expected_head: row.fetch("expected_head") } ])
    assert_response :success, response.body
    assert_equal "distinct", SourceReviewHead.find_by!(financial_source_event: line).approved_version.overlap_disposition
    # The bank line now has no category, so it asks for one; once chosen both purchases count.
    category_row = plan(statement).fetch("attention").sole
    assert_equal "no_category", category_row.fetch("kind")
    approve(statement, [ edit_entry(line, @groceries).merge(expected_head: category_row.fetch("expected_head")) ])
    assert_response :success, response.body
    assert_equal 2, @household.household_transactions.where(status: %w[confirmed reconciled]).count
    assert_equal 6976, budget_actual(@groceries, month: 8)
  end

  test "a voucher receipt is compared by its new money, and Count all keeps counting all of it" do
    receipt = purchase("Tasi Demo Home Store", "2026-06-23", { @household_goods => 18_488 },
      payment: { "receipt_total_cents" => 18_488, "new_money_cents" => 3488, "paid_with" => [ { "kind" => "voucher", "amount_cents" => 15_000, "new_money" => false }, { "kind" => "card", "amount_cents" => 3488, "new_money" => true } ] })
    statement = build_source([ [ "TASI DEMO HOME STORE", -3488, "purchase", "2026-06-23" ] ])
    line = statement[:revision].financial_source_events.sole
    row = plan(statement).fetch("attention").sole
    assert_equal [ "same_purchase", receipt.id ], [ row.fetch("kind"), row.dig("purchase_match", "transaction_id") ]

    same_purchase(statement, line, row)
    assert_response :success, response.body
    assert_equal 18_488, budget_actual(@household_goods, month: 6), "She chose to count all of the receipt; the bank line adds nothing"
  end

  test "Same purchase is refused when the purchase's amount changed after the question was shown" do
    receipt = purchase("Payless Supermarkets", "2026-08-03", { @groceries => 5000 })
    statement = build_source([ [ "PAYLESS SUPERMARKETS", -5000, "purchase", "2026-08-03" ] ])
    line = statement[:revision].financial_source_events.sole
    row = plan(statement).fetch("attention").sole
    assert_equal "same_purchase", row.fetch("kind")

    receipt.update_columns(total_amount_cents: 6000)
    same_purchase(statement, line, row)
    assert_response :conflict
    assert_nil SourceReviewHead.find_by(financial_source_event: line)&.approved_version, "Nothing is saved as a match"
  end

  test "a statement purchase without its line link is never offered as one she confirmed" do
    purchase("Payless Supermarkets", "2026-08-03", { @groceries => 5000 }, source_type: "statement")
    statement = build_source([ [ "PAYLESS SUPERMARKETS", -5000, "purchase", "2026-08-03" ] ])
    row = plan(statement).fetch("attention").sole
    refute_equal "same_purchase", row.fetch("kind")
    assert_nil row["purchase_match"]
  end

  test "an answer about a purchase that changed is refused, and a reopened receipt brings the bank line back" do
    receipt = purchase("Payless Supermarkets", "2026-08-03", { @groceries => 5000 })
    statement = build_source([ [ "PAYLESS SUPERMARKETS", -5000, "purchase", "2026-08-03" ] ])
    line = statement[:revision].financial_source_events.sole
    row = plan(statement).fetch("attention").sole

    approve(statement, [ { event_id: line.id, decision: "same_purchase", match_transaction_id: receipt.id + 1000, shown: row.slice("event_type", "category_id") } ])
    assert_response :conflict
    same_purchase(statement, line, row)
    assert_response :success, response.body

    # She reopens her receipt, so it no longer counts. The bank line is no longer finished and nothing counts as $0 silently.
    receipt.update!(status: "ignored")
    again = plan(statement)
    assert_equal 0, again.fetch("done")
    refute_includes FinancialDocuments::SourceReview::ApprovalState.new(@household, statement[:revision]).call[:deficiencies] - [ "matched_source_fact_changed" ], "unreviewed_source_rows"
    assert_includes FinancialDocuments::SourceReview::ApprovalState.new(@household, statement[:revision]).call[:deficiencies], "matched_source_fact_changed"
  end

  test "only a likely match is asked: same amount, within a few days, not from a statement, and not another line's" do
    purchase("Payless Supermarkets", "2026-08-01", { @groceries => 2500 })
    purchase("Payless Supermarkets", "2026-08-10", { @groceries => 2600 })
    purchase("Island Demo Hardware", "2026-08-12", { @household_goods => 4100 })
    two = purchase("Tasi Demo Coffee", "2026-08-20", { @groceries => 650 })
    statement = build_source([
      [ "PAYLESS SUPERMARKETS", -2500, "purchase", "2026-08-06" ], # five days later
      [ "PAYLESS SUPERMARKETS", -2601, "purchase", "2026-08-10" ], # a cent off
      [ "TASI DEMO COFFEE", -4100, "purchase", "2026-08-14" ],     # two days and another store
      [ "TASI DEMO COFFEE", -650, "purchase", "2026-08-20" ],
      [ "TASI DEMO COFFEE", -650, "purchase", "2026-08-20" ],
      [ "PAYLESS SUPERMARKETS", -2500, "fee", "2026-08-01" ]
    ])
    events = statement[:revision].financial_source_events.order(:position).to_a
    asked = plan(statement).fetch("attention").select { |row| row["kind"] == "same_purchase" }
    assert_equal events[3..4].map(&:id), asked.pluck("event_id"), "Both identical coffees are asked until one is answered"

    same_purchase(statement, events[3], asked.first)
    assert_response :success, response.body
    assert_empty plan(statement).fetch("attention").select { |row| row["kind"] == "same_purchase" }, "The coffee she matched is no longer offered to the other line"
    assert_equal [ two.id ], SourceReviewVersion.where.not(matched_transaction_id: nil).pluck(:matched_transaction_id)
  end

  test "a line she counted before this question existed is left as she saved it" do
    statement = build_source([ [ "PAYLESS SUPERMARKETS", -3000, "purchase", "2026-08-03" ] ])
    line = statement[:revision].financial_source_events.sole
    approve(statement, [ edit_entry(line, @groceries) ])
    assert_response :success, response.body
    purchase("Payless Supermarkets", "2026-08-03", { @groceries => 3000 })

    review = plan(statement)
    assert_empty review.fetch("attention"), "A purchase already counted twice is not changed or re-asked silently"
    approve(statement, [ edit_entry(line, @household_goods).merge(expected_head: saved_head(line)) ])
    assert_response :success, response.body
    assert_equal 3000, budget_actual(@household_goods, month: 8)
  end

  private

  def headers = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def plan(source)
    get "/api/v1/document_imports/#{source[:import].id}/source_review", params: { revision_id: source[:revision].id }, headers: headers
    assert_response :success
    response.parsed_body.dig("source_review", "participant_review", "plan")
  end

  def review_rows(source)
    get "/api/v1/document_imports/#{source[:import].id}/source_review", params: { revision_id: source[:revision].id }, headers: headers
    response.parsed_body.dig("source_review", "participant_review", "rows")
  end

  def approve(source, lines, **extra)
    post "/api/v1/document_imports/#{source[:import].id}/review/approve_lines", params: { revision_id: source[:revision].id, input: { lines: lines, **extra } },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
  end

  def same_purchase(source, event, row)
    approve(source, [ { event_id: event.id, decision: "same_purchase", match_transaction_id: row.dig("purchase_match", "transaction_id"),
      shown: row.slice("event_type", "category_id"), expected_head: row.fetch("expected_head") } ])
  end

  def saved_head(event)
    head = SourceReviewHead.find_by!(financial_source_event: event)
    { "approved_version_id" => head.approved_version_id, "lock_version" => head.lock_version, "account_version_id" => head.approved_version.source_account_identity_version_id }
  end

  def edit_entry(event, category)
    { event_id: event.id, decision: "edited", edit: { kind: "spending", amount_cents: -event.signed_amount_cents, merchant: event.financial_source_evidence.payload["merchant"], posted_on: event.posted_on.iso8601, category_id: category.id } }
  end

  # A purchase she confirmed herself: a receipt by default, with the entry that confirmed it.
  def purchase(merchant, on, parts, source_type: "receipt", payment: nil)
    date = Date.iso8601(on)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: date.year).current_period_for(date)
    row = @household.household_transactions.create!(budget_period: period, occurred_on: date, merchant: merchant, total_amount_cents: parts.values.sum, source_type: source_type, status: "confirmed")
    parts.each { |category, cents| row.transaction_splits.create!(budget_category: category, amount_cents: cents) }
    @household.transaction_drafts.create!(occurred_on: date, merchant: merchant, total_amount_cents: parts.values.sum, source_type: source_type, status: "confirmed", confirmed_transaction: row,
      draft_payload: payment ? { HouseholdFinance::ReceiptTenders::PAYLOAD_KEY => payment } : {})
    row
  end

  def budget_actual(category, month:)
    get "/api/v1/budget", params: { year: 2026 }, headers: headers
    assert_response :success
    HouseholdFinance::Money.cents(response.parsed_body.fetch("annual_plan").fetch("rows").find { |row| row["id"] == category.id }.fetch("months")[month - 1].fetch("actual"))
  end

  def report_total(start_on, end_on)
    get "/api/v1/spending_report", params: { start_on: start_on, end_on: end_on }, headers: headers
    assert_response :success
    HouseholdFinance::Money.cents!(response.parsed_body.fetch("spending_report").fetch("totals").fetch("actual"))
  end

  # rows: [merchant, signed cents, kind, posted date]
  def build_source(rows)
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "talun-demo.csv", content_type: "text/csv", byte_size: 10,
      s3_key: "synthetic/#{SecureRandom.hex(8)}.csv", checksum_sha256: SecureRandom.hex(32))
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    events = rows.each_with_index.map do |(name, cents, type, on), index|
      { account_key: "talun-checking", row_kind: "posted", limitations: [], event_type: type, signed_amount_cents: cents, posted_on: on, merchant: name, locator: { page: 1, row: index + 1 } }
    end
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "talun-checking", account_basis: "asset", label: "Talun Demo Checking ····4410" } ], events: events, reported_row_count: events.length },
      coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
    document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: document)
  end
end
