require "test_helper"

class ApiV1SourceReviewControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(clerk_id: "pager-#{SecureRandom.hex(8)}", email: "pager-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Synthetic pager household")
    @household.household_memberships.create!(user: @user, role: "owner")
    @import = @household.financial_document_imports.create!(uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/source-#{SecureRandom.hex}.pdf")
  end

  test "all 503 source rows are reachable once through bounded stable pages and filters" do
    result = source_rows(503)
    ids = []
    11.times do |offset|
      get review_path, params: { revision_id: result[:revision].id, page: offset + 1 }, headers: auth_headers(@user)
      assert_response :success
      body = JSON.parse(response.body).fetch("source_review")
      assert_equal 503, body.dig("counts", "all")
      assert_equal 50, body.dig("pagination", "per_page")
      assert_equal(offset == 10 ? 3 : 50, body.fetch("events").length)
      assert_equal false, body.dig("revision", "participant_approved")
      assert_equal body.dig("revision", "accounts"), body.fetch("accounts")
      ids.concat(body.fetch("events").map { |row| row.fetch("id") })
    end
    assert_equal result[:events].map(&:id), ids
    assert_equal 503, ids.uniq.length
    get review_path, params: { revision_id: result[:revision].id, filter: "unresolved" }, headers: auth_headers(@user)
    assert_response :success
    body = JSON.parse(response.body).fetch("source_review")
    assert_equal 1, body.dig("pagination", "total_count")
    assert_equal "unresolved", body.fetch("events").sole.fetch("row_kind")
    get review_path, params: { revision_id: result[:revision].id, filter: "informational" }, headers: auth_headers(@user)
    assert_response :success
    assert_equal "informational", JSON.parse(response.body).dig("source_review", "events").sole.fetch("row_kind")
  end

  test "stale or foreign revisions and malformed page parameters never expose another extraction" do
    old = source_rows(1)
    latest = source_rows(2)
    get review_path, params: { revision_id: old[:revision].id }, headers: auth_headers(@user)
    assert_response :conflict
    [ { page: "0" }, { page: "1junk" }, { page: "2" }, { per_page: "500" }, { filter: "unknown" } ].each do |invalid|
      get review_path, params: { revision_id: latest[:revision].id }.merge(invalid), headers: auth_headers(@user)
      assert_response :unprocessable_entity
    end
    foreign = User.create!(clerk_id: "foreign-#{SecureRandom.hex}", email: "foreign-#{SecureRandom.hex}@example.com", role: "participant", invitation_status: "accepted")
    get review_path, params: { revision_id: latest[:revision].id }, headers: auth_headers(foreign)
    assert_response :not_found
  end

  test "linked expense draft is returned only with its authorized source row" do
    result = source_rows(2)
    HouseholdFinance::DocumentTransactionDraftPersister.new(@import, result[:transaction_drafts]).call
    get review_path, params: { revision_id: result[:revision].id }, headers: auth_headers(@user)
    assert_response :success
    body = JSON.parse(response.body).fetch("source_review")
    row = body.fetch("events").first
    assert_equal row.fetch("id"), row.dig("transaction_draft", "financial_source_event_id")
    assert_equal 2, body.dig("counts", "pending_transaction_drafts")
    get "/api/v1/document_imports/#{@import.id}", headers: auth_headers(@user)
    assert_equal result[:revision].id, JSON.parse(response.body).dig("document_import", "metadata", "source_accounting_revision_id")
    assert_empty JSON.parse(response.body).dig("document_import", "transaction_drafts")
  end

  test "source deletion revokes reads despite missing storage and erases evidence across revisions" do
    old = source_rows(1)
    latest = source_rows(2)
    assert_equal 5, FinancialSourceEvidence.count
    with_s3_stub(:configured?, false) do
      delete "/api/v1/document_imports/#{@import.id}/source", headers: auth_headers(@user)
    end
    assert_response :service_unavailable
    refute @import.reload.source_available?
    assert_equal 0, FinancialSourceEvidence.count
    assert_equal 3, FinancialSourceEvent.count
    assert_equal "failed", FinancialDocumentSourceCleanup.last.status
    with_s3_stub(:configured?, true) do
      get "/api/v1/document_imports/#{@import.id}/source_content", headers: auth_headers(@user)
      assert_response :not_found
    end
    get review_path, params: { revision_id: latest[:revision].id }, headers: auth_headers(@user)
    assert_response :success
    body = JSON.parse(response.body).fetch("source_review")
    assert_equal false, body.dig("revision", "source_available")
    assert body.fetch("events").all? { |row| row["evidence"].nil? && row["evidence_available"] == false }
    assert_equal(-100, old[:events].first.reload.signed_amount_cents)
  end

  test "source content checks authentication on every read and does not cache bytes" do
    with_s3_stub(:configured?, true) do
      with_s3_stub(:download_to_io!, ->(_key, io) { io.write("%PDF-synthetic"); true }) do
        get "/api/v1/document_imports/#{@import.id}/source_content", headers: auth_headers(@user)
        assert_response :success
        assert_equal "%PDF-synthetic", response.body
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_equal "nosniff", response.headers["X-Content-Type-Options"]
        get "/api/v1/document_imports/#{@import.id}/source_content?download=1", headers: auth_headers(@user)
        assert_response :success
        assert_includes response.headers["Content-Disposition"], "attachment"
      end
      get "/api/v1/document_imports/#{@import.id}/source_content"
      assert_response :unauthorized
    end
  end

  test "deletion or membership removal during storage IO prevents bytes being returned" do
    [ :source, :membership ].each do |revocation|
      @import.update!(source_deleted_at: nil)
      @household.household_memberships.find_or_create_by!(user: @user) { |membership| membership.role = "owner" }
      with_s3_stub(:configured?, true) do
        with_s3_stub(:download_to_io!, ->(_key, io) {
          io.write("private synthetic bytes")
          revocation == :source ? @import.update!(source_deleted_at: Time.current) : @household.household_memberships.where(user: @user).delete_all
          true
        }) do
          get "/api/v1/document_imports/#{@import.id}/source_content", headers: auth_headers(@user)
        end
      end
      assert_response :not_found
      refute_includes response.body, "private synthetic bytes"
    end
  end

  test "removing an unresolved import preserves immutable source facts without raw evidence" do
    result = source_rows(1)
    with_s3_stub(:configured?, true) do
      with_s3_stub(:delete, true) do
        delete "/api/v1/document_imports/#{@import.id}", headers: auth_headers(@user)
      end
    end
    assert_response :no_content
    assert_equal 0, FinancialSourceEvidence.count
    assert_equal 1, FinancialSourceEvent.count
    assert_nil result[:revision].reload.financial_document_import_id
  end

  private

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}", "Idempotency-Key" => SecureRandom.uuid }
  end

  def with_s3_stub(method_name, replacement)
    singleton = S3Service.singleton_class
    original = singleton.instance_method(method_name)
    singleton.define_method(method_name) do |*args, **kwargs|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs) : replacement
    end
    yield
  ensure
    singleton.send(:remove_method, method_name)
    singleton.define_method(method_name, original)
  end

  def review_path
    "/api/v1/document_imports/#{@import.id}/source_review"
  end

  def source_rows(count)
    attempt = @import.attempts.create!(provider: "synthetic", model: "synthetic", status: "processing", prompt_version: "synthetic", schema_version: "synthetic", started_at: Time.current)
    rows = count.times.map do |position|
      { account_key: "synthetic-account", row_kind: position == 501 ? "informational" : "posted", event_type: "purchase", signed_amount_cents: -100, amount_column_cents: 100,
        posted_on: position == 502 ? nil : "2026-07-07", locator: { page: 1, row: position + 1 }, merchant: "Private synthetic merchant" }
    end
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic-account", account_basis: "asset", period_start_on: "2026-07-01", period_end_on: "2026-07-31" } ], events: rows }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(@import, attempt: attempt, accounting: accounting).call
    @import.update!(metadata: { source_accounting_revision_id: result[:revision].id, source_accounting_contract_version: FinancialDocuments::AccountingContract::VERSION, source_accounting_review_pending: true })
    result
  end
end
