require "test_helper"

class ApiV1SourceReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "source-ui-#{SecureRandom.hex(8)}", email: "source-ui-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @category = @household.budget_categories.create!(name: "Synthetic category", stack_key: "non_discretionary", sort_order: 0)
    @source = build_source
  end

  test "participant approves account and row independently with replay safe redacted audit" do
    review_get
    assert_response :success
    review = response.parsed_body.fetch("source_review").fetch("participant_review")
    assert_nil review.fetch("accounts").sole.fetch("approved")
    mutate("account_link", account_input)
    assert_response :success
    identity = response.parsed_body.fetch("record")
    assert_not_includes response.body, @source[:import].s3_key
    input = stage_input(identity.fetch("id"))
    mutate("stage", input)
    assert_response :success
    draft = response.parsed_body.fetch("record")
    assert_nil SourceReviewHead.find_by!(financial_source_event: @source[:events].sole).approved_version_id
    assert_empty @household.household_transactions
    approval = draft.slice("id", "lock_version", "digest").transform_keys { |key| { "id" => "draft_id", "lock_version" => "draft_lock_version", "digest" => "draft_digest" }.fetch(key) }
    mutate("approve", approval, key: "one-explicit-approval")
    assert_response :success
    version_id = response.parsed_body.fetch("record").fetch("id")
    mutate("approve", approval, key: "one-explicit-approval")
    assert_response :success
    assert_equal true, response.parsed_body.fetch("replayed")
    assert_equal version_id, response.parsed_body.fetch("record").fetch("id")
    assert_equal 1, SourceReviewVersion.where(household: @household).count
    assert_empty @household.household_transactions
    audit = @household.household_audit_events.where(event_type: "household_operation.executed").last
    assert_not_includes audit.attributes.to_json, "Synthetic source merchant"
    review_get
    assert_response :success
    state = response.parsed_body.fetch("source_review").fetch("participant_review")
    assert_equal 1, state.fetch("coverage").fetch("approved_rows")
    assert_equal version_id, state.fetch("rows").fetch(@source[:events].sole.id.to_s).dig("approved", "id")
    assert_nil state.fetch("approved_coverage")
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "stale pending proposal cannot be overwritten and prior approved value survives a correction" do
    mutate("account_link", account_input)
    identity = response.parsed_body.fetch("record")
    input = stage_input(identity.fetch("id"))
    mutate("stage", input)
    assert_response :success
    draft = response.parsed_body.fetch("record")
    mutate("stage", input.merge(facts: input[:facts].merge(signed_amount_cents: -900, purchase_amount_cents: 900)))
    assert_response :conflict
    assert_equal(-1_000, SourceReviewDraft.find(draft.fetch("id")).facts.fetch("signed_amount_cents"))
    mutate("stage", input.merge(expected_pending_draft: draft.slice("id", "lock_version", "digest"), facts: input[:facts].merge(signed_amount_cents: -900, purchase_amount_cents: 900)))
    assert_response :success
    assert_equal(-900, response.parsed_body.fetch("record").dig("facts", "signed_amount_cents"))
  end

  test "review scope rejects another import and latest extraction changes before writes" do
    other = build_source
    mutate("account_link", account_input.merge(source_account_id: other[:revision].financial_source_accounts.sole.id))
    assert_response :not_found
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
    post "/api/v1/document_imports/#{@source[:import].id}/review/account_link", params: { revision_id: other[:revision].id, input: account_input }, headers: auth_headers(@user).merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :conflict
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
  end

  test "coaches admins and read only members cannot browse or mutate participant review controls" do
    %w[coach admin].each do |role|
      @user.update!(role: role)
      get "/api/v1/source_review_accounts", headers: auth_headers(@user)
      assert_response :forbidden
      mutate("account_link", account_input)
      assert_response :forbidden
    end
    @user.update!(role: "participant")
    @household.household_memberships.find_by!(user: @user).update!(role: "coach_viewer")
    get "/api/v1/source_review_accounts", headers: auth_headers(@user)
    assert_response :forbidden
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
  end

  test "legacy confirmation and matching cannot publish typed extraction bypassing reviewed heads" do
    event = @source[:events].sole
    draft = @household.transaction_drafts.create!(financial_document_import: @source[:import], financial_source_event: event,
      occurred_on: event.posted_on, merchant: "Synthetic merchant", total_amount_cents: 1_000, budget_category: @category, source_type: "statement", status: "pending")
    confirmer = HouseholdFinance::TransactionDraftConfirmer.new(draft).call
    refute confirmer.success?
    assert_includes confirmer.errors.join, "Statements"
    operation = HouseholdFinance::Operations::Transaction::DraftConfirm.new(@household)
    assert_raises(ArgumentError) { operation.prepare(draft_id: draft.id, source_type: "manual_ui") }
    matcher = HouseholdFinance::TransactionDraftMatchAccepter.new(draft).call
    refute matcher.success?
    assert_includes matcher.errors.join, "Statements"
    assert_empty @household.household_transactions
    assert_equal "pending", draft.reload.status
  end

  test "request recovery is scoped to the exact participant action and statement" do
    key = "recover-header"
    get "/api/v1/document_imports/#{@source[:import].id}/review_request_status", params: { review_action: "account_link" }, headers: auth_headers(@user).merge("Idempotency-Key" => key)
    assert_response :success
    assert_equal "unknown", response.parsed_body.fetch("state")
    mutate("account_link", account_input, key: key)
    identity = response.parsed_body.fetch("record")
    get "/api/v1/document_imports/#{@source[:import].id}/review_request_status", params: { review_action: "account_link" }, headers: auth_headers(@user).merge("Idempotency-Key" => key)
    assert_response :success
    assert_equal "committed", response.parsed_body.fetch("state")
    assert_equal identity.fetch("id"), response.parsed_body.fetch("record").fetch("id")
    assert_includes response.headers["Cache-Control"], "no-store"
    other = build_source
    get "/api/v1/document_imports/#{other[:import].id}/review_request_status", params: { review_action: "account_link" }, headers: auth_headers(@user).merge("Idempotency-Key" => key)
    assert_response :not_found
    get "/api/v1/document_imports/#{@source[:import].id}/review_request_status", params: { review_action: "stage" }, headers: auth_headers(@user).merge("Idempotency-Key" => key)
    assert_response :conflict
    @household.household_memberships.find_by!(user: @user).update!(role: "coach_viewer")
    get "/api/v1/document_imports/#{@source[:import].id}/review_request_status", params: { review_action: "account_link" }, headers: auth_headers(@user).merge("Idempotency-Key" => key)
    assert_response :forbidden
    assert_not_includes response.body, "Synthetic checking"
  end

  test "duplicate candidates use reviewed correction values and exact canonical account" do
    mutate("account_link", account_input)
    identity = response.parsed_body.fetch("record")
    mutate("stage", stage_input(identity.fetch("id")))
    draft = response.parsed_body.fetch("record")
    mutate("approve", approval_input(draft))
    approved = response.parsed_body.fetch("record")
    other = build_source
    old_source = @source
    @source = other
    mutate("account_link", account_input.merge(tracked_account_id: approved.dig("recognized_account", "tracked_account_id")))
    assert_response :success
    get "/api/v1/document_imports/#{other[:import].id}/review_candidates", params: { event_id: other[:events].sole.id, signed_amount_cents: -1_000, posted_on: "2026-07-07" }, headers: auth_headers(@user)
    assert_response :success
    assert_equal [ approved.fetch("id") ], response.parsed_body.fetch("records").map { |row| row.fetch("id") }
    get "/api/v1/document_imports/#{other[:import].id}/review_candidates", params: { event_id: other[:events].sole.id, signed_amount_cents: -900, posted_on: "2026-07-07" }, headers: auth_headers(@user)
    assert_response :success
    assert_empty response.parsed_body.fetch("records")
    get "/api/v1/document_imports/#{other[:import].id}/review_candidates", params: { event_id: other[:events].sole.id, signed_amount_cents: "10.01", posted_on: "2026-02-30" }, headers: auth_headers(@user)
    assert_response :unprocessable_entity
    @source = old_source
  end

  test "source only corrections preserve the visible actual until separately replaced" do
    mutate("account_link", account_input)
    identity = response.parsed_body.fetch("record")
    input = stage_input(identity.fetch("id"))
    mutate("stage", input.merge(projection: { action: "create" }))
    mutate("approve", approval_input(response.parsed_body.fetch("record")))
    first = response.parsed_body.fetch("record")
    old_actual = first.fetch("actual")
    head = SourceReviewHead.find_by!(financial_source_event: @source[:events].sole)
    corrected = input.merge(base_version_id: head.approved_version_id, base_lock_version: head.lock_version,
      facts: input[:facts].merge(signed_amount_cents: -900, purchase_amount_cents: 900))
    mutate("stage", corrected)
    mutate("approve", approval_input(response.parsed_body.fetch("record")))
    second = response.parsed_body.fetch("record")
    assert_equal old_actual, second.fetch("actual")
    assert_equal(-900, second.dig("facts", "signed_amount_cents"))
    assert_equal 1, @household.household_transactions.where(status: "confirmed").count
    mutate("project", { version_id: second.fetch("id"), expected_version_digest: second.fetch("digest"), reason: "I approve replacing spending", projection: { action: "replace", transaction_id: old_actual.fetch("id"), expected_digest: old_actual.fetch("digest") } })
    assert_response :success
    review_get
    current = response.parsed_body.dig("source_review", "participant_review", "rows", @source[:events].sole.id.to_s, "approved")
    assert_equal 900, current.dig("actual", "amount_cents")
    refute_equal old_actual.fetch("id"), current.dig("actual", "id")
    assert_equal "ignored", HouseholdTransaction.find(old_actual.fetch("id")).status
  end

  def approval_input(draft)
    { draft_id: draft.fetch("id"), draft_lock_version: draft.fetch("lock_version"), draft_digest: draft.fetch("digest") }
  end

  private

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def mutate(action, input, key: SecureRandom.uuid)
    post "/api/v1/document_imports/#{@source[:import].id}/review/#{action}",
      params: { revision_id: @source[:revision].id, input: input }, headers: auth_headers(@user).merge("Idempotency-Key" => key), as: :json
  end

  def review_get
    get "/api/v1/document_imports/#{@source[:import].id}/source_review", params: { revision_id: @source[:revision].id }, headers: auth_headers(@user)
  end

  def build_source
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: SecureRandom.hex(32))
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic-account", account_basis: "asset", period_start_on: "2026-07-01", period_end_on: "2026-07-31", opening_balance_cents: 20_000, closing_balance_cents: 19_000, printed_debit_cents: 1_000, printed_credit_cents: 0, printed_row_count: 1 } ],
      events: [ { account_key: "synthetic-account", row_kind: "posted", event_type: "purchase", signed_amount_cents: -1_000, posted_on: "2026-07-07", merchant: "Synthetic source merchant", locator: { page: 1, row: 1 } } ], reported_row_count: 1 }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
    document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: document)
  end

  def account_input
    account = @source[:revision].financial_source_accounts.sole
    { source_account_id: account.id, account_basis: "asset", label: "Synthetic checking", base_version_id: nil, base_lock_version: 0,
      statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "I checked the synthetic statement header" }
  end

  def stage_input(identity_id)
    { event_id: @source[:events].sole.id, base_version_id: nil, base_lock_version: 0, expected_pending_draft: nil, reason: "I checked this synthetic row", projection: { action: "none" },
      facts: { source_account_identity_version_id: identity_id, disposition: "include", event_type: "purchase", signed_amount_cents: -1_000, purchase_amount_cents: 1_000, posted_on: "2026-07-07", merchant: "Synthetic source merchant", budget_category_id: @category.id, overlap_disposition: "new" } }
  end
end
