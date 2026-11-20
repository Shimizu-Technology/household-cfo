require "test_helper"

# Cash counts when it is withdrawn (decision 3, 2026-11-19). A purchase she paid in cash names part of that cash and
# adds nothing: "Paid with the $100 you took out on Aug 3?" Yes moves its amount out of Cash into its own category, in
# the month the cash was taken out. No counts it as its own purchase. Nothing is linked for her.
class ApiV1CashPurchaseDrawdownTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "cash-#{SecureRandom.hex(8)}", email: "cash-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @cash = @household.budget_categories.create!(name: "Cash", stack_key: "discretionary", sort_order: 1)
    @dining = @household.budget_categories.create!(name: "Dining", stack_key: "discretionary", sort_order: 2)
    @groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 3)
  end

  test "a $100 withdrawal plus a $40 cash lunch is $100 of spending, with $40 of it named" do
    withdrawal = withdraw(10_000, "2026-08-03")
    assert_equal 10_000, budget_actual(@cash, month: 8)
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)

    card = draft.fetch("cash_payment")
    assert_equal [ "participant", 4000 ], card.values_at("source", "cash_cents")
    assert_equal "Paid with the $100 you took out on Aug 3?", card.fetch("question")
    assert_equal [ [ withdrawal.id, "2026-08-03", 10_000, 10_000, 4000 ] ],
      card.fetch("candidates").map { |row| row.values_at("financial_source_event_id", "withdrawn_on", "amount_cents", "available_cents", "covers_cents") }

    # Confirm alone can't count it: the cash already counted.
    confirm(draft)
    assert_response :conflict
    assert_equal "cash_withdrawal_question", response.parsed_body.fetch("code")
    assert_equal "Paid with the $100 you took out on Aug 3? Choose on the purchase. Nothing was added to your spending.", response.parsed_body.fetch("errors").sole
    assert_equal "pending", TransactionDraft.find(draft.fetch("id")).status
    assert_equal 10_000, month_total(8)

    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_equal "Saved Tasi Demo Cafe for $40 in Dining, paid with cash you took out on Aug 3. That cash already counted, so $40 moved from Cash to Dining.",
      @household.chat_sessions.flat_map { |session| session.chat_messages.pluck(:content) }.last
    purchase = TransactionDraft.find(draft.fetch("id")).confirmed_transaction
    assert_equal({ "financial_source_event_id" => withdrawal.id, "amount_cents" => 4000 }, purchase.metadata.fetch("cash_withdrawal").slice("financial_source_event_id", "amount_cents"))

    # Budget, the spending report, Mia's analyzer and Mia's month answer: $100, $40 Dining and $60 Cash.
    assert_equal [ 6000, 4000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ]
    assert_equal 10_000, month_total(8)
    report = spending_report("2026-08-01", "2026-08-31")
    assert_equal 10_000, HouseholdFinance::Money.cents!(report.dig("totals", "actual"))
    assert_equal({ "Cash" => 6000, "Dining" => 4000 }, report.fetch("categories").select { |row| row["actual"].to_f.nonzero? }.to_h { |row| [ row["name"], HouseholdFinance::Money.cents(row["actual"]) ] })
    assert_equal({ "withdrawn_on" => "2026-08-03", "amount" => 40.0 }, report.fetch("transactions").find { |row| row["id"] == purchase.id }.fetch("cash_withdrawal"))
    assert_equal 10_000, analyzer("2026-08-01", "2026-08-31").fetch(:observed_spending_cents)
    assert_equal 10_000, mia_month(8).fetch(:spent_so_far_cents)

    # The card says what happened.
    confirmed_card = HouseholdFinance::CashPayment.presentation(TransactionDraft.find(draft.fetch("id")))
    assert_equal [ true, 4000 ], confirmed_card.values_at(:linked, :linked_cents)

    # Reopening gives the cash back, and confirming again asks again.
    post "/api/v1/transaction_drafts/#{draft.fetch('id')}/reopen", headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success, response.body
    assert_equal [ 10_000, 0 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ]
    assert_equal 10_000, month_total(8)
    confirm(draft)
    assert_response :conflict
    assert_equal "cash_withdrawal_question", response.parsed_body.fetch("code")
  end

  test "No counts it as its own purchase, cash from somewhere else" do
    withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_from_elsewhere: true)
    assert_response :success, response.body
    assert_equal [ 10_000, 4000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ]
    assert_equal 14_000, month_total(8)
    assert_equal 14_000, analyzer("2026-08-01", "2026-08-31").fetch(:observed_spending_cents)
    assert_equal "elsewhere", TransactionDraft.find(draft.fetch("id")).draft_payload.dig("cash_payment", "answer")
    assert_nil TransactionDraft.find(draft.fetch("id")).confirmed_transaction.metadata["cash_withdrawal"]
  end

  test "cash taken out in August and spent in September counts in August" do
    withdrawal = withdraw(10_000, "2026-08-28")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-09-02", @dining, paid_with_cash: true)
    assert_equal "Paid with the $100 you took out on Aug 28?", draft.dig("cash_payment", "question")
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body

    assert_equal [ 6000, 4000, 10_000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    assert_equal [ 0, 0, 0 ], [ budget_actual(@cash, month: 9), budget_actual(@dining, month: 9), month_total(9) ]
    assert_equal 10_000, HouseholdFinance::Money.cents!(spending_report("2026-08-01", "2026-08-31").dig("totals", "actual"))
    assert_equal 0, HouseholdFinance::Money.cents!(spending_report("2026-09-01", "2026-09-30").dig("totals", "actual"))
    assert_equal 10_000, analyzer("2026-08-01", "2026-08-31").fetch(:observed_spending_cents)
    assert_equal 0, analyzer("2026-09-01", "2026-09-30").fetch(:observed_spending_cents).to_i
    assert_equal 10_000, analyzer("2026-08-01", "2026-09-30").fetch(:observed_spending_cents)
    assert_equal [ 10_000, 0 ], [ mia_month(8).fetch(:spent_so_far_cents), mia_month(9).fetch(:spent_so_far_cents) ]
  end

  test "a link never takes more than the withdrawal: what is left is offered, and the rest counts on its own" do
    withdrawal = withdraw(10_000, "2026-08-03")
    first = log_purchase("Tasi Demo Market", 70, "2026-08-04", @groceries, paid_with_cash: true)
    confirm(first, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body

    second = log_purchase("Tasi Demo Cafe", 50, "2026-08-05", @dining, paid_with_cash: true)
    assert_equal "Paid with the $100 you took out on Aug 3 ($30 left)?", second.dig("cash_payment", "question")
    assert_equal [ 3000, 3000 ], second.dig("cash_payment", "candidates").sole.values_at("available_cents", "covers_cents")
    confirm(second, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_includes @household.chat_sessions.flat_map { |session| session.chat_messages.pluck(:content) }.last, "The other $20 counts as new spending."

    assert_equal [ 0, 7000, 5000 ], [ @cash, @groceries, @dining ].map { |category| budget_actual(category, month: 8) }
    assert_equal 12_000, month_total(8)

    # Nothing is left, so a third cash purchase is not asked about and counts on its own.
    third = log_purchase("Tasi Demo Bakery", 10, "2026-08-06", @dining, paid_with_cash: true)
    assert_empty third.dig("cash_payment", "candidates")
    assert_match(/counts as its own purchase/, third.dig("cash_payment", "message"))
    confirm(third)
    assert_response :success, response.body
    assert_equal 13_000, month_total(8)

    # Even a stale answer naming the empty withdrawal is refused.
    fourth = log_purchase("Tasi Demo Bakery", 5, "2026-08-07", @dining, paid_with_cash: true)
    confirm(fourth, cash_withdrawal_event_id: withdrawal.id)
    assert_response :unprocessable_entity
    assert_equal "pending", TransactionDraft.find(fourth.fetch("id")).status
  end

  test "several withdrawals are offered most recent first, and only ones taken out by the purchase date" do
    older = withdraw(6000, "2026-07-20")
    newer = withdraw(10_000, "2026-08-03")
    withdraw(20_000, "2026-08-10")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    card = draft.fetch("cash_payment")
    assert_equal "Which cash paid for this $40?", card.fetch("question")
    assert_equal [ newer.id, older.id ], card.fetch("candidates").pluck("financial_source_event_id")
    assert_equal [ "the $100 you took out on Aug 3", "the $60 you took out on Jul 20" ], card.fetch("candidates").pluck("label")

    confirm(draft, cash_withdrawal_event_id: older.id)
    assert_response :success, response.body
    assert_equal [ 2000, 4000 ], [ budget_actual(@cash, month: 7), budget_actual(@dining, month: 7) ]
    assert_equal [ 30_000, 0 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ], "The August withdrawals keep all their cash"
  end

  test "with no cash withdrawal it counts normally, and a purchase that wasn't cash is never asked" do
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    assert_equal "Paid with cash. No cash you took out by Aug 5 has any left in your approved statements, so this counts as its own purchase.", draft.dig("cash_payment", "message")
    confirm(draft)
    assert_response :success, response.body
    assert_equal 4000, month_total(8)

    withdraw(10_000, "2026-08-03")
    card = log_purchase("Tasi Demo Cafe", 25, "2026-08-06", @dining)
    assert_nil card.fetch("cash_payment")
    confirm(card)
    assert_response :success, response.body
    assert_equal 16_500, month_total(8)
  end

  test "a withdrawal re-reviewed as a transfer gives the purchase back its own spending" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_equal 10_000, month_total(8)

    version = SourceReviewHead.find_by!(financial_source_event: withdrawal).approved_version
    head = version.source_review_head
    approve(@sources.fetch(withdrawal.id), [ { event_id: withdrawal.id, expected_head: { approved_version_id: head.approved_version_id, lock_version: head.lock_version, account_version_id: version.source_account_identity_version_id },
      decision: "edited", edit: { kind: "moved" } } ])
    assert_response :success, response.body
    assert_equal [ 0, 4000, 4000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
  end

  test "Approve all never answers which cash paid for a purchase" do
    withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    post "/api/v1/transaction_drafts/bulk_confirm", params: { transaction_draft_ids: [ draft.fetch("id") ], year: 2026, confirmation: "CONFIRM 1" },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors").join, "Paid with the $100 you took out on Aug 3? Answer that on its card first."
    assert_equal "pending", TransactionDraft.find(draft.fetch("id")).status
  end

  test "she can say on the card that she paid with cash, or that she didn't" do
    withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining)
    patch "/api/v1/transaction_drafts/#{draft.fetch('id')}", params: { transaction_draft: { paid_with_cash: true } }, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success, response.body
    assert_equal "Paid with the $100 you took out on Aug 3?", response.parsed_body.dig("transaction_draft", "cash_payment", "question")
    patch "/api/v1/transaction_drafts/#{draft.fetch('id')}", params: { transaction_draft: { paid_with_cash: false } }, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success, response.body
    assert_nil response.parsed_body.dig("transaction_draft", "cash_payment")
  end

  private

  def headers = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def log_purchase(merchant, dollars, on, category, paid_with_cash: false)
    post "/api/v1/transaction_drafts", params: { transaction_draft: { occurred_on: on, merchant: merchant, amount: dollars, budget_category_id: category.id }.merge(paid_with_cash ? { paid_with_cash: true } : {}) },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :created, response.body
    response.parsed_body.fetch("transaction_draft")
  end

  def confirm(draft, **answer)
    post "/api/v1/transaction_drafts/#{draft.fetch('id')}/confirm", params: { transaction_draft: answer }, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
  end

  # A statement with one ATM withdrawal, approved as read into Cash.
  def withdraw(cents, on)
    source = build_source([ [ "Tasi Demo ATM withdrawal", -cents, "cash_withdrawal", on ] ])
    event = source[:revision].financial_source_events.sole
    row = plan(source).fetch("ready").sole
    assert_equal @cash.id, row.fetch("category_id")
    approve(source, [ { event_id: event.id, decision: "as_read", shown: row.slice("event_type", "category_id") } ], expect_ready_ids: [ event.id ])
    assert_response :success, response.body
    (@sources ||= {})[event.id] = source
    event
  end

  def plan(source)
    get "/api/v1/document_imports/#{source[:import].id}/source_review", params: { revision_id: source[:revision].id }, headers: headers
    assert_response :success
    response.parsed_body.dig("source_review", "participant_review", "plan")
  end

  def approve(source, lines, **extra)
    post "/api/v1/document_imports/#{source[:import].id}/review/approve_lines", params: { revision_id: source[:revision].id, input: { lines: lines, **extra } },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
  end

  def budget_plan
    get "/api/v1/budget", params: { year: 2026 }, headers: headers
    assert_response :success
    response.parsed_body.fetch("annual_plan")
  end

  def budget_actual(category, month:)
    HouseholdFinance::Money.cents(budget_plan.fetch("rows").find { |row| row["id"] == category.id }.fetch("months")[month - 1].fetch("actual"))
  end

  def month_total(month)
    budget_plan.fetch("rows").sum { |row| HouseholdFinance::Money.cents(row.fetch("months")[month - 1].fetch("actual")) }
  end

  def spending_report(start_on, end_on)
    get "/api/v1/spending_report", params: { start_on: start_on, end_on: end_on }, headers: headers
    assert_response :success
    response.parsed_body.fetch("spending_report")
  end

  def analyzer(from, to) = SpendingPatterns::Analyzer.new(@household.reload, today: Date.new(2026, 11, 1), from: from, to: to).call

  def mia_month(month)
    plan = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).read_only_plan_data
    HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan, month: month).call
  end

  # rows: [merchant, signed cents, kind, posted date]
  def build_source(rows)
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "talun-demo-#{SecureRandom.hex(3)}.csv", content_type: "text/csv", byte_size: 10,
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
