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

  test "the plan says plainly whether the printed totals disagree, the line count differs, or nothing could be checked" do
    presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, @source[:revision], user: @user)
    balanced = { "accounts" => [ { "arithmetic_balanced" => true, "balance_residual_cents" => 0, "debit_residual_cents" => 0, "credit_residual_cents" => 0, "row_count_matches" => true } ], "row_census" => { "matches_reported" => true }, "page_coverage" => { "all_processed" => true } }
    {
      balanced => "matches",
      balanced.merge("accounts" => [ balanced["accounts"].first.merge("balance_residual_cents" => 4_250, "arithmetic_balanced" => false) ]) => "mismatch",
      balanced.merge("page_coverage" => { "all_processed" => false }) => "mismatch",
      balanced.merge("row_census" => { "matches_reported" => false }) => "count",
      balanced.merge("accounts" => [ balanced["accounts"].first.merge("row_count_matches" => false) ]) => "count",
      { "accounts" => [ { "arithmetic_balanced" => false, "balance_residual_cents" => nil } ], "row_census" => { "matches_reported" => nil } } => "unchecked"
    }.each do |report, expected|
      revision = @source[:revision]
      revision.define_singleton_method(:reconciliation) { report }
      assert_equal expected, presenter.plan_summary.fetch(:totals_check), report.inspect
    end
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
    # A system label such as "Spreadsheet account" is never saved as her account's name.
    assert_equal "Bank account", SourceTrackedAccount.where(household: @household).sole.label
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

  test "a long statement is approved a page at a time: exactly the lines on the page, all or none, and a retry changes nothing" do
    rows = (1..5).map { |index| [ "Pay #{index}", 10_000 + index, "income", index ] }
    long = build_source(rows: rows)
    ids = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, long[:revision]).ready_ids
    assert_equal 5, ids.length
    with_page_limit(2) do
      page = ->(slice, **extra) { approve_lines({ expect_ready_ids: slice, paged: true, lines: slice.map { |id| { event_id: id, decision: "as_read" } } }.merge(extra), source: long) }
      # More than a page in one request is refused outright, and saves nothing.
      approve_lines({ expect_ready_ids: ids, lines: ids.map { |id| { event_id: id, decision: "as_read" } } }, source: long)
      assert_response :unprocessable_entity
      assert_equal 0, SourceReviewVersion.where(household: @household).count
      # Without paged: true the request must cover every open line, as before.
      approve_lines({ expect_ready_ids: ids.first(2), lines: ids.first(2).map { |id| { event_id: id, decision: "as_read" } } }, source: long)
      assert_response :conflict
      assert_equal 0, SourceReviewVersion.where(household: @household).count
      page.call(ids.first(2))
      assert_equal({ "approved" => 2, "left_out" => 0, "unchanged" => 0, "complete" => false }, response.parsed_body.fetch("result"))
      page.call(ids.first(2))
      assert_equal({ "approved" => 0, "left_out" => 0, "unchanged" => 2, "complete" => false }, response.parsed_body.fetch("result"))
      assert_equal 2, SourceReviewVersion.where(household: @household).count
      # A page that holds a line she was never shown as looking right saves nothing.
      page.call(ids[2, 2] + [ -1 ])
      assert_response :unprocessable_entity
      assert_equal 2, SourceReviewVersion.where(household: @household).count
      page.call(ids[2, 2])
      page.call(ids.last(1))
      assert_equal 5, SourceReviewVersion.where(household: @household).count
      assert_equal 1, SourceAccountIdentityVersion.where(household: @household).count
      assert_equal true, response.parsed_body.dig("result", "complete")
    end
  end

  test "a page that holds a line that no longer looks right is refused and saves nothing" do
    long = build_source(rows: [ [ "Pay 1", 10_000, "income", 1 ], [ "Pay 2", 10_001, "income", 2 ] ])
    ids = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, long[:revision]).ready_ids
    changed = build_source(rows: [ [ "Ross", -500, "purchase", 1 ] ])
    approve_lines({ expect_ready_ids: ids + changed[:revision].financial_source_events.pluck(:id), paged: true, lines: ids.map { |id| { event_id: id, decision: "as_read" } } }, source: long)
    assert_response :conflict
    assert_equal 0, SourceReviewVersion.where(household: @household).count
  end

  test "account numbers are hidden in every description she reads, and the statement's own words stay stored" do
    rows = [ [ "Coast360 transfer to own savings 00002468", -20_000, "transfer", 1 ], [ "Visa card payment 00009900", -25_000, "debt_payment", 2 ], [ "Ross #12345678 order $1234567.89", -500, "purchase", 3 ] ]
    source = build_source(rows: rows)
    event = source[:revision].financial_source_events.joins(:financial_source_evidence).first
    assert_equal "Coast360 transfer to own savings 00002468", event.financial_source_evidence.payload["merchant"]
    get "/api/v1/document_imports/#{source[:import].id}/source_review", params: { revision_id: source[:revision].id }, headers: headers
    review = response.parsed_body.fetch("source_review")
    shown = review.fetch("events").map { |row| row.dig("evidence", "merchant") }
    assert_includes shown, "Coast360 transfer to own savings ····2468"
    assert_includes shown, "Visa card payment ····9900"
    assert_includes shown, "Ross #····5678 order $1234567.89"
    plan_merchants = review.dig("participant_review", "plan", "attention").pluck("merchant")
    assert_includes plan_merchants, "Coast360 transfer to own savings ····2468"
    assert_includes plan_merchants, "Visa card payment ····9900"
    %w[00002468 00009900 12345678].each { |number| refute_includes (plan_merchants + shown + review.fetch("events").pluck("evidence").flat_map(&:values).grep(String)).join(" "), number }
  end

  test "an account is named in plain words: the bank when the file says it, never a system label" do
    names = ->(label, masked) { FinancialDocuments::SourceReview::AccountName.parts(label, masked) }
    assert_equal({ name: nil, last4: nil }, names.call("Spreadsheet account 1", nil))
    assert_equal({ name: nil, last4: "1234" }, names.call("Statement account ****1234", "****1234"))
    assert_equal({ name: "Bank of Guam checking", last4: "1234" }, names.call("Bank of Guam checking", "****1234"))
    assert_equal({ name: "Bank of Guam checking", last4: "1234" }, names.call("Bank of Guam checking · ****1234", nil))
    assert_equal({ name: nil, last4: "1234" }, names.call("Bank account ····1234", nil))
    assert_equal "Credit card ····1234", FinancialDocuments::SourceReview::AccountName.default_label("Spreadsheet account 1", "****1234", "liability")
    account = @source[:revision].financial_source_accounts.sole
    presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, @source[:revision], user: @user)
    assert_equal [ nil, nil ], presenter.context(event_ids: []).fetch(:accounts).first.values_at(:name, :last4)
    approve_lines({ lines: [], accounts: [ { source_account_id: account.id, account_basis: "asset", label: "Bank of Guam checking" } ] })
    assert_equal "Bank of Guam checking", presenter.context(event_ids: []).fetch(:accounts).first.fetch(:name)
  end

  test "a merchant she categorized before keeps that category under different bank wording, and a conflicting reader guess is a question" do
    earlier = build_source(rows: [ [ "Ross Dededo GU", -1_000, "purchase", 1 ] ])
    approve_lines({ lines: [ { event_id: earlier[:revision].financial_source_events.sole.id, decision: "edited", edit: { kind: "spending", merchant: "Ross Dededo GU", posted_on: "2026-07-02", amount_cents: 1_000, category_id: @groceries.id } } ] }, source: earlier)
    assert_response :success
    shopping = @household.budget_categories.create!(name: "Shopping", stack_key: "discretionary", sort_order: 1)
    later = build_source(rows: [ [ "ROSS DRESS FOR LESS #123 HAGATNA GU", -700, "purchase", 3 ], [ "ROSS STORES #456 YIGO GU", -800, "purchase", 4 ], [ "Corner Cafe", -900, "purchase", 5 ] ])
    events = later[:revision].financial_source_events.includes(:financial_source_evidence).order(:position).to_a
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, later[:revision])
    # Her earlier answer arrives already chosen; an unfamiliar merchant is still a question.
    assert_equal [ @groceries.id, @groceries.id, nil ], plan.lines.map(&:category_id)
    assert_equal [ :no_category ], plan.attention.map(&:kind)
    # The reader guessed something else for one of them: ask with her own category, never overrule it silently.
    @household.transaction_drafts.create!(financial_document_import: later[:import], financial_source_event: events.second, occurred_on: events.second.posted_on, merchant: "Ross",
      total_amount_cents: 800, budget_category: shopping, source_type: "statement", status: "pending")
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, later[:revision])
    assert_equal [ :still_category, :no_category ].sort, plan.attention.map(&:kind).sort
    row = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, later[:revision], user: @user).plan_summary.fetch(:attention).find { |item| item[:kind] == :still_category }
    assert_equal "Still Groceries?", row.fetch(:question)
    assert_equal %w[Yes Change], row.fetch(:answers).pluck(:label)
    assert_equal @groceries.id, row.fetch(:category_id)
    assert_empty plan.ready_ids - events.first(1).map(&:id)
  end

  private

  def with_page_limit(count)
    approver = FinancialDocuments::SourceReview::LineApprover
    approver.send(:remove_const, :MAX_LINES)
    approver.const_set(:MAX_LINES, count)
    yield
  ensure
    approver.send(:remove_const, :MAX_LINES)
    approver.const_set(:MAX_LINES, 400)
  end

  def headers = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def approve_lines(input, key: SecureRandom.uuid, source: @source)
    post "/api/v1/document_imports/#{source[:import].id}/review/approve_lines", params: { revision_id: source[:revision].id, input: input }, headers: headers.merge("Idempotency-Key" => key), as: :json
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

  def build_source(basis: "asset", rows: DEFAULT_ROWS, label: "Spreadsheet account")
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.csv", content_type: "text/csv", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.csv", checksum_sha256: SecureRandom.hex(32))
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    events = rows.map do |name, cents, type, row|
      { account_key: "synthetic-account", row_kind: "posted", event_type: type, signed_amount_cents: cents, posted_on: (Date.new(2026, 7, 2) + ((row - 1) % 28)).iso8601, merchant: name, locator: { page: 1, row: row } }
    end
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic-account", account_basis: basis, label: label } ],
      events: events, reported_row_count: events.length }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
    document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: document)
  end
end
