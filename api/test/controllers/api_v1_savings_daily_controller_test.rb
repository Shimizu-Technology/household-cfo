require "test_helper"
require_relative "../support/savings_daily_test_support"

class ApiV1SavingsDailyControllerTest < ActionDispatch::IntegrationTest
  include SavingsDailyTestSupport

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "empty Today and explicit minimal category need no debt or full setup" do
    with_daily_operations do
      savings_enroll
      get daily_path, headers: auth_headers
      assert_response :success
      assert_nil response.parsed_body.dig("day", "reported_spend_cents")
      assert_equal "unknown", response.parsed_body.dig("day", "spending_state")
      assert_empty response.parsed_body.fetch("categories")
      assert_includes response.headers["Cache-Control"], "no-store"
      daily_post("category_create", { name: "Groceries", stack_key: "non_discretionary" }, "new-category")
      assert_response :success
      category_id = response.parsed_body.dig("record", "id")
      daily_post("category_create", { name: "Groceries", stack_key: "non_discretionary" }, "new-category")
      assert_response :success
      assert response.parsed_body.fetch("replayed")
      assert_equal category_id, response.parsed_body.dig("record", "id")
      assert_equal 1, @savings_household.budget_categories.count
      assert_empty @savings_household.budget_years
      assert_empty @savings_household.debts
      assert_empty @savings_household.confirmed_setup_fields
      daily_post("category_create", { name: "groceries", stack_key: "non_discretionary" }, "duplicate")
      assert_response :unprocessable_entity
      daily_post("category_create", { cohort_id: @savings_cohort.id, name: "Other", stack_key: "discretionary" }, "forged-cohort")
      assert_response :unprocessable_entity
    end
  end

  test "pending purchase review approval and recovery create one actual and separate optional reflection" do
    with_daily_operations do
      savings_enroll
      @daily_category = @savings_household.budget_categories.create!(name: "Food", stack_key: "discretionary")
      daily_post("purchase_stage", purchase_input, "purchase-stage")
      assert_response :success
      draft = response.parsed_body.fetch("record")
      assert_equal "pending", draft.fetch("status")
      assert_empty @savings_household.household_transactions
      get "#{daily_path}/records", params: { collection: "purchases" }, headers: auth_headers
      assert_response :success
      pending_head = response.parsed_body.fetch("records").sole
      assert_nil pending_head["current_version"]
      assert_nil pending_head["current_version_id"]
      assert_equal draft.fetch("savings_daily_purchase_id"), pending_head["id"]
      daily_post("reflection_save", { purchase_id: draft.fetch("savings_daily_purchase_id"), expected_version_id: nil,
        expected_head_lock_version: 0, feeling_then: "Private feeling", feeling_now: nil }, "reflection")
      assert_response :success
      get "#{daily_path}/records", params: { collection: "reflections", parent_id: draft.fetch("savings_daily_purchase_id") }, headers: auth_headers
      assert_response :success
      assert_equal "Private feeling", response.parsed_body.fetch("records").sole.dig("current_version", "feeling_then")
      assert_empty @savings_household.household_transactions
      approval = { draft_id: draft.fetch("id"), accepted: true, expected_draft_lock_version: draft.fetch("lock_version"),
        expected_version_id: nil, expected_head_lock_version: 0 }
      2.times { daily_post("purchase_approve", approval, "purchase-approve"); assert_response :success }
      assert response.parsed_body.fetch("replayed")
      assert_equal 1, @savings_household.household_transactions.count
      assert_equal 2500, @savings_household.household_transactions.sole.total_amount_cents
      get "#{daily_path}/request_status", params: { review_action: "purchase_approve" }, headers: auth_headers("purchase-approve")
      assert_response :success
      assert_equal "committed", response.parsed_body.fetch("state")
      get "#{daily_path}/request_status", params: { review_action: "purchase_stage" }, headers: auth_headers("purchase-approve")
      assert_response :conflict
      daily_post("check_in_save", { local_on: "2026-11-01", spending_state: "no_spend", accepted: true,
        expected_version_id: nil, expected_head_lock_version: 0, reason: "" }, "conflicting-no-spend")
      assert_response :unprocessable_entity
      assert_empty SavingsDailyCheckInVersion.where(savings_enrollment: @savings_enrollment)
    end
  end

  test "held challenge denies ordinary reads while self erasure and tombstone-only recovery remain available" do
    with_daily_operations do
      savings_enroll
      @daily_category = @savings_household.budget_categories.create!(name: "Food", stack_key: "discretionary")
      purchase = daily_stage.savings_daily_purchase
      reflection_version = daily_reflection(purchase).subject
      reflection = reflection_version.savings_daily_reflection.reload
      @savings_cohort.update!(savings_challenge_release_hold: true)
      get daily_path, headers: auth_headers
      assert_response :forbidden
      @savings_membership.destroy!
      get "#{daily_path}/records", params: { collection: "reflections" }, headers: auth_headers
      assert_response :unprocessable_entity
      path = "#{daily_path}/reflections/#{reflection.id}"
      post "#{path}/erase", params: { erase_accepted: true, expected_version_id: reflection.current_version_id,
        expected_head_lock_version: reflection.lock_version }, headers: auth_headers("erase"), as: :json
      assert_response :success
      assert_equal %w[erased reflection_id replayed version_id], response.parsed_body.keys.sort
      get "#{path}/erase_status", headers: auth_headers("erase")
      assert_response :success
      assert_equal "committed", response.parsed_body.fetch("state")
      assert_equal %w[erased reflection_id replayed state version_id], response.parsed_body.keys.sort
      assert_nil reflection_version.reload.feeling_then
      assert_nil reflection_version.feeling_now
      get "#{path}/erase_status", headers: auth_headers("not-sent")
      assert_equal({ "state" => "unknown", "can_retry" => true }, response.parsed_body)
      @savings_household.household_memberships.find_by!(user: @savings_user).update!(role: "coach_viewer")
      get "#{path}/erase_status", headers: auth_headers("erase")
      assert_response :forbidden
      assert_empty @savings_household.household_transactions
    end
  end

  test "upcoming enrollment has no forced future day while explicit future queries fail and role downgrade cannot replay" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 10, 31).in_time_zone("Pacific/Guam").noon
      get daily_path, headers: auth_headers
      assert_response :success
      assert_nil response.parsed_body.fetch("day")
      get daily_path, params: { local_on: "2026-11-01" }, headers: auth_headers
      assert_response :unprocessable_entity
      travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
      daily_post("category_create", { name: "Food", stack_key: "discretionary" }, "private-category")
      assert_response :success
      @savings_user.update!(role: "coach")
      get "#{daily_path}/request_status", params: { review_action: "category_create" }, headers: auth_headers("private-category")
      assert_response :forbidden
      get "#{daily_path}/records", params: { collection: "purchases" }, headers: auth_headers
      assert_response :forbidden
    end
  end

  # The reviewed authorization date is inside the personal window while its
  # statement posted date is outside it. The actual must still be selectable.
  test "canonical candidate retains reviewed purchase date at personal window boundary" do
    with_daily_operations do
      savings_enroll
      travel_to Date.new(2026, 11, 3).in_time_zone("Pacific/Guam").noon
      @daily_category = @savings_household.budget_categories.create!(name: "Food", stack_key: "discretionary")
      import = FinancialDocumentImport.create!(household: @savings_household, uploaded_by_user: @savings_user, document_kind: "statement", status: "needs_review",
        filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: SecureRandom.hex(32))
      attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
      normalized = FinancialDocuments::AccountingContract.normalize({ contract_version: "source_accounting_v1",
        accounts: [ { account_key: "synthetic", account_basis: "asset", period_start_on: "2026-10-31", period_end_on: "2026-11-03",
          opening_balance_cents: 300_000, closing_balance_cents: 297_500, printed_debit_cents: 2500, printed_credit_cents: 0, printed_row_count: 1 } ],
        events: [ { account_key: "synthetic", row_kind: "posted", event_type: "purchase", signed_amount_cents: -2500, posted_on: "2026-10-31",
          authorized_on: "2026-11-01", merchant: "Synthetic Cafe", locator: { page: 1, row: 1 } } ], reported_row_count: 1 },
        coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
      source = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: normalized).call
      account = source[:revision].financial_source_accounts.sole
      runner = HouseholdFinance::Operations::Runner.new(@savings_household, user: @savings_user)
      identity = runner.run(operation_key: "source_review.account.link", idempotency_key: SecureRandom.uuid,
        input: { source_account_id: account.id, tracked_account_id: nil, account_basis: "asset", label: "Synthetic source", base_version_id: nil, base_lock_version: 0,
          statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Reviewed synthetic identity" }).subject
      draft = runner.run(operation_key: "source_review.draft.stage", idempotency_key: SecureRandom.uuid,
        input: { event_id: source[:events].sole.id, base_version_id: nil, base_lock_version: 0, reason: "Reviewed source",
          projection: { action: "create" }, facts: { source_account_identity_version_id: identity.id, disposition: "include", event_type: "purchase",
            signed_amount_cents: -2500, purchase_amount_cents: 2500, posted_on: "2026-10-31", authorized_on: "2026-11-01",
            merchant: "Synthetic Cafe", budget_category_id: @daily_category.id, overlap_disposition: "distinct" } }).subject
      approved = runner.run(operation_key: "source_review.draft.approve", idempotency_key: SecureRandom.uuid,
        input: { draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest }).subject
      actual = approved.source_projection_revision.replacement_transaction
      get "#{daily_path}/candidates", params: { local_on: "2026-11-01" }, headers: auth_headers
      assert_response :success
      candidate = response.parsed_body.fetch("records").sole
      assert_equal actual.id, candidate.fetch("id")
      assert_equal "2026-10-31", candidate.fetch("posted_on")
      assert_includes candidate.fetch("purchased_on_candidates"), "2026-11-01"
      get "#{daily_path}/candidates", params: { local_on: "2026-11-02" }, headers: auth_headers
      assert_response :success
      assert_empty response.parsed_body.fetch("records")
    end
  end

  test "every ordinary daily response identifies the exact participant enrollment and cohort" do
    with_daily_operations do
      savings_enroll
      get daily_path, headers: auth_headers
      assert_response :success
      assert_daily_identity
      get "#{daily_path}/records", params: { collection: "purchases" }, headers: auth_headers
      assert_response :success
      assert_daily_identity
      get "#{daily_path}/candidates", params: { local_on: "2026-11-01" }, headers: auth_headers
      assert_response :success
      assert_daily_identity
      daily_post("category_create", { name: "Food", stack_key: "discretionary" }, "identity-category")
      assert_response :success
      assert_daily_identity
      get "#{daily_path}/request_status", params: { review_action: "category_create" }, headers: auth_headers("identity-category")
      assert_response :success
      assert_daily_identity
      assert_equal "committed", response.parsed_body.fetch("state")
      get "#{daily_path}/request_status", params: { review_action: "category_create" }, headers: auth_headers("identity-not-sent")
      assert_response :success
      assert_daily_identity
      assert_equal "unknown", response.parsed_body.fetch("state")
    end
  end

  test "metadata context remains explicit when no enrollment is verified" do
    controller = Api::V1::SavingsDailyController.new
    controller.define_singleton_method(:current_user) { @identity_user }
    controller.define_singleton_method(:current_household) { @identity_household }
    controller.instance_variable_set(:@identity_user, @savings_user)
    controller.instance_variable_set(:@identity_household, @savings_household)
    context = controller.send(:actor_context)
    assert_nil context.fetch(:enrollment_id)
    assert_nil context.fetch(:cohort_id)
    assert_equal({ user_id: @savings_user.id, household_id: @savings_household.id }, context.fetch(:actor_scope))
  end

  test "same participant cannot recover another enrollment's daily request under the selected program envelope" do
    with_daily_operations do
      savings_enroll
      original_cohort = @savings_cohort
      original_enrollment = @savings_enrollment
      @daily_category = @savings_household.budget_categories.create!(name: "Food", stack_key: "discretionary")
      daily_post("purchase_stage", purchase_input, "original-daily-purchase")
      assert_response :success
      draft_id = response.parsed_body.dig("record", "id")
      enroll_second_daily_program
      refute_equal original_enrollment.id, @savings_enrollment.id
      get "#{daily_path}/request_status", params: { review_action: "purchase_stage" }, headers: auth_headers("original-daily-purchase")
      assert_response :not_found
      refute response.parsed_body.key?("record")
      refute_includes response.body, "Synthetic Cafe"
      get "#{daily_path}/request_status", params: { review_action: "purchase_stage" },
        headers: auth_headers("original-daily-purchase").merge("X-Cohort-Id" => original_cohort.id.to_s)
      assert_response :success
      assert_equal draft_id, response.parsed_body.dig("record", "id")
      assert_equal original_enrollment.id, response.parsed_body.fetch("enrollment_id")
      assert_equal original_cohort.id, response.parsed_body.fetch("cohort_id")
    end
  end

  test "category request recovery uses the original durable program reference without retaining private input" do
    with_daily_operations do
      savings_enroll
      original_cohort = @savings_cohort
      original_enrollment = @savings_enrollment
      daily_post("category_create", { name: "Reviewed household category", stack_key: "discretionary" }, "original-category-program")
      assert_response :success
      category_id = response.parsed_body.dig("record", "id")
      execution = @savings_household.household_operation_executions.find_by!(operation_key: "savings.daily.category.create")
      assert_equal "SavingsEnrollment", execution.reviewable_type
      assert_equal original_enrollment.id, execution.reviewable_id
      assert_equal({}, execution.normalized_input)
      enroll_second_daily_program
      get "#{daily_path}/request_status", params: { review_action: "category_create" }, headers: auth_headers("original-category-program")
      assert_response :not_found
      refute response.parsed_body.key?("record")
      refute_includes response.body, "Reviewed household category"
      get "#{daily_path}/request_status", params: { review_action: "category_create" },
        headers: auth_headers("original-category-program").merge("X-Cohort-Id" => original_cohort.id.to_s)
      assert_response :success
      assert_equal category_id, response.parsed_body.dig("record", "id")
      assert_equal original_enrollment.id, response.parsed_body.fetch("enrollment_id")
      assert_equal original_cohort.id, response.parsed_body.fetch("cohort_id")
    end
  end

  test "old category executions without a program reference are not assigned to the selected enrollment" do
    with_daily_operations do
      savings_enroll
      result = savings_run("daily.category.create", { name: "Legacy household category", stack_key: "discretionary" }, token: "unbound-category-program")
      assert_nil result.execution.reviewable_type
      get "#{daily_path}/request_status", params: { review_action: "category_create" }, headers: auth_headers("unbound-category-program")
      assert_response :not_found
      refute response.parsed_body.key?("record")
      get daily_path, headers: auth_headers
      assert_response :success
      assert_includes response.parsed_body.fetch("categories").map { |row| row.fetch("id") }, result.subject.id
    end
  end

  private
  def enroll_second_daily_program
    @savings_cohort = Cohort.create!(name: "Second synthetic daily program", status: "enrolling", created_by_user: @savings_owner,
      starts_on: Date.new(2026, 11, 1), savings_challenge_enabled: true, savings_challenge_release_hold: false)
    @savings_membership = @savings_cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
    @savings_release = nil
    with_savings_runtime { savings_enroll }
  end
  def assert_daily_identity
    body = response.parsed_body
    assert_equal @savings_enrollment.id, body.fetch("enrollment_id")
    assert_equal @savings_cohort.id, body.fetch("cohort_id")
    assert_equal({ "user_id" => @savings_user.id, "household_id" => @savings_household.id }, body.fetch("actor_scope"))
  end
  def daily_path = "/api/v1/savings_challenge/daily"
  def auth_headers(key = nil)
    { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }.tap do |headers|
      headers["Idempotency-Key"] = key if key
    end
  end
  def daily_post(action, input, key)
    post "#{daily_path}/actions/#{action}", params: input, headers: auth_headers(key), as: :json
  end
  def purchase_input
    { amount_cents: 2500, merchant: "Synthetic Cafe", purchased_on: "2026-11-01", link_kind: "manual_new",
      splits: [ { budget_category_id: @daily_category.id, amount_cents: 2500 } ],
      purchase_id: nil, expected_version_id: nil, expected_head_lock_version: 0, reason: "" }
  end
end
