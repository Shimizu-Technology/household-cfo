require "test_helper"

# "Approve the rest" must save exactly the lines that looked right, all or none, and be safe to repeat.
class ApiV1StatementLinesApproveTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "lines-#{SecureRandom.hex(8)}", email: "lines-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 0)
    @source = build_source
    @events = @source[:revision].financial_source_events.includes(:financial_source_evidence).order(:position).index_by { |event| merchant_of(event) }
    suggest(@events.fetch("Payless"), @groceries)
  end

  test "the plan sorts the statement into what looks right and the few lines that need an answer" do
    plan = review_plan
    assert_equal 5, plan.fetch("total")
    assert_equal 0, plan.fetch("done")
    assert_equal [ "Payroll", "Payless" ].map { |name| @events.fetch(name).id }, plan.fetch("ready_event_ids")
    kinds = plan.fetch("attention").to_h { |row| [ row.fetch("merchant"), row.fetch("kind") ] }
    assert_equal({ "Ross" => "no_category", "Own savings" => "transfer", "Unreadable" => "unclear" }, kinds)
    question = plan.fetch("attention").find { |row| row["merchant"] == "Own savings" }
    assert_equal "Did this move between your own accounts?", question.fetch("question")
    assert_equal %w[Yes No], question.fetch("answers").pluck("label")
    assert_equal "2026-07-02", plan.fetch("first_on")
    assert_equal "unchecked", plan.fetch("totals_check")
  end

  test "approving the rest links the account, saves exactly those lines and counts only categorized spending" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ expect_ready_ids: ready, lines: ready.map { |id| { event_id: id, decision: "as_read" } } })
    assert_response :success
    assert_equal({ "approved" => 2, "left_out" => 0, "unchanged" => 0, "complete" => false }, response.parsed_body.fetch("result"))
    assert_equal ready.sort, SourceReviewHead.where(household: @household).where.not(approved_version_id: nil).pluck(:financial_source_event_id).sort
    assert_equal 1, @household.household_transactions.where(status: "confirmed").count
    assert_equal 1_000, @household.household_transactions.sole.total_amount_cents
    assert_equal @groceries.id, @household.household_transactions.sole.transaction_splits.sole.budget_category_id
    assert_equal "Spreadsheet account", SourceTrackedAccount.where(household: @household).sole.label
    # Nothing she did not see is touched.
    assert_nil SourceReviewHead.find_by(financial_source_event_id: @events.fetch("Ross").id)&.approved_version_id
    assert_nil SourceReviewHead.find_by(financial_source_event_id: @events.fetch("Own savings").id)&.approved_version_id
    plan = review_plan
    assert_equal 2, plan.fetch("done")
    assert_empty plan.fetch("ready_event_ids")
  end

  test "repeating the same request changes nothing" do
    ready = review_plan.fetch("ready_event_ids")
    body = { expect_ready_ids: ready, lines: ready.map { |id| { event_id: id, decision: "as_read" } } }
    approve_lines(body, key: "same-key")
    approve_lines(body, key: "same-key")
    assert_response :success
    assert_equal({ "approved" => 0, "left_out" => 0, "unchanged" => 2, "complete" => false }, response.parsed_body.fetch("result"))
    assert_equal 2, SourceReviewVersion.where(household: @household).count
    assert_equal 1, SourceAccountIdentityVersion.where(household: @household).count
    assert_equal 1, @household.household_transactions.count
  end

  test "a request that no longer matches what was on screen saves nothing" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ expect_ready_ids: ready.first(1), lines: ready.map { |id| { event_id: id, decision: "as_read" } } })
    assert_response :conflict
    assert_match(/changed while you were reviewing/, response.parsed_body.fetch("errors").first)
    assert_equal 0, SourceReviewVersion.where(household: @household).count
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
  end

  test "one line that cannot be saved rolls the whole request back" do
    ready = review_plan.fetch("ready_event_ids")
    lines = ready.map { |id| { event_id: id, decision: "as_read" } } + [ { event_id: @events.fetch("Ross").id, decision: "as_read" } ]
    approve_lines({ lines: lines })
    assert_response :conflict
    assert_equal 0, SourceReviewVersion.where(household: @household).count
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
    assert_equal 0, @household.household_transactions.count
    assert_equal 0, SourceTrackedAccount.where(household: @household).count
  end

  test "a line with no category cannot be approved as read, but choosing one counts it as spending" do
    ross = @events.fetch("Ross")
    approve_lines({ lines: [ { event_id: ross.id, decision: "as_read" } ] })
    assert_response :conflict
    approve_lines({ lines: [ { event_id: ross.id, decision: "edited", edit: { kind: "spending", merchant: "Ross", posted_on: "2026-07-04", amount_cents: 500, category_id: @groceries.id } } ] })
    assert_response :success
    assert_equal 500, @household.household_transactions.sole.total_amount_cents
    version = SourceReviewHead.find_by!(financial_source_event_id: ross.id).approved_version
    assert_equal @groceries.id, version.budget_category_id
  end

  test "leaving a line out keeps it represented but never counts it" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ lines: ready.map { |id| { event_id: id, decision: "leave_out" } } })
    assert_response :success
    assert_equal 2, response.parsed_body.dig("result", "left_out")
    assert_equal %w[exclude], SourceReviewVersion.where(household: @household).pluck(:disposition).uniq
    assert_equal 0, @household.household_transactions.count
  end

  test "the statement is finished once every line is answered, and the uncertainty stays on the record" do
    ready = review_plan.fetch("ready_event_ids")
    ross, savings = @events.fetch("Ross"), @events.fetch("Own savings")
    approve_lines({ lines: ready.map { |id| { event_id: id, decision: "as_read" } } + [
      { event_id: savings.id, decision: "as_read" },
      { event_id: @events.fetch("Unreadable").id, decision: "leave_out" },
      { event_id: ross.id, decision: "edited", edit: { kind: "spending", merchant: "Ross", posted_on: "2026-07-04", amount_cents: 500, category_id: @groceries.id } }
    ] })
    assert_response :success
    assert_equal true, response.parsed_body.dig("result", "complete")
    approval = SourceRevisionApproval.where(household: @household).sole
    assert_equal "qualified", approval.coverage_status
    assert_includes approval.deficiencies, "account_period_unknown"
    assert_equal 0, @household.household_transactions.where(financial_source_event: savings).count
  end

  test "an account whose type is unknown asks before anything is saved" do
    other = build_source(basis: "unknown")
    post "/api/v1/document_imports/#{other[:import].id}/review/approve_lines", params: { revision_id: other[:revision].id, input: { lines: [ { event_id: other[:revision].financial_source_events.first.id, decision: "leave_out" } ] } },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :unprocessable_entity
    assert_equal "Choose whether this is a bank account or a credit card.", response.parsed_body.fetch("errors").first
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
  end

  test "the account name and dates can be changed, and the same change twice is one change" do
    account = @source[:revision].financial_source_accounts.sole
    change = { lines: [], accounts: [ { source_account_id: account.id, account_basis: "liability", label: "Visa", period_start_on: "2026-07-01", period_end_on: "2026-07-31" } ] }
    approve_lines(change, key: "k1")
    approve_lines(change, key: "k2")
    assert_response :success
    identity = SourceAccountIdentityVersion.where(household: @household).sole
    assert_equal "Visa", identity.source_tracked_account.label
    assert_equal "liability", identity.source_tracked_account.account_basis
    assert_equal "2026-07-31", identity.statement_facts["period_end_on"]
  end

  test "only the participant who owns the household can approve" do
    %w[coach admin].each do |role|
      @user.update!(role: role)
      approve_lines({ lines: [ { event_id: @events.fetch("Payroll").id, decision: "as_read" } ] })
      assert_response :forbidden
    end
    assert_equal 0, SourceReviewVersion.where(household: @household).count
  end

  test "a merchant she already categorized keeps that category on the next statement" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ lines: ready.map { |id| { event_id: id, decision: "as_read" } } })
    later = build_source(rows: [ [ "Payless", -700, "purchase", 1 ] ])
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, later[:revision])
    assert_equal [ @groceries.id ], plan.lines.map(&:category_id)
    assert_empty plan.attention
  end

  test "a copy of a charge she already approved is flagged and can only be left out" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ lines: ready.map { |id| { event_id: id, decision: "as_read" } } })
    copy = build_source(rows: [ [ "Payless", -1_000, "purchase", 2 ] ])
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, copy[:revision])
    assert_equal [ :duplicate ], plan.attention.map(&:kind)
  end

  private

  def headers = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def approve_lines(input, key: SecureRandom.uuid)
    post "/api/v1/document_imports/#{@source[:import].id}/review/approve_lines", params: { revision_id: @source[:revision].id, input: input }, headers: headers.merge("Idempotency-Key" => key), as: :json
  end

  def review_plan
    get "/api/v1/document_imports/#{@source[:import].id}/source_review", params: { revision_id: @source[:revision].id }, headers: headers
    assert_response :success
    response.parsed_body.dig("source_review", "participant_review", "plan")
  end

  def merchant_of(event) = event.financial_source_evidence.payload["merchant"]

  def suggest(event, category)
    @household.transaction_drafts.create!(financial_document_import: @source[:import], financial_source_event: event, occurred_on: event.posted_on, merchant: merchant_of(event),
      total_amount_cents: event.expense_amount_cents, budget_category: category, source_type: "statement", status: "pending")
  end

  DEFAULT_ROWS = [ [ "Payroll", 200_000, "income", 1 ], [ "Payless", -1_000, "purchase", 2 ], [ "Ross", -500, "purchase", 3 ], [ "Own savings", -3_000, "transfer", 4 ], [ "Unreadable", nil, "purchase", 5 ] ].freeze

  def build_source(basis: "asset", rows: DEFAULT_ROWS)
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.csv", content_type: "text/csv", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.csv", checksum_sha256: SecureRandom.hex(32))
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    events = rows.map do |name, cents, type, row|
      { account_key: "synthetic-account", row_kind: "posted", event_type: type, signed_amount_cents: cents, posted_on: "2026-07-0#{row + 1}", merchant: name, locator: { page: 1, row: row } }
    end
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic-account", account_basis: basis, label: "Spreadsheet account" } ],
      events: events, reported_row_count: events.length }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
    document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: document)
  end
end
