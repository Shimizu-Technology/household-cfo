require "test_helper"
require "marcel"
require "zip"

class ApiV1DocumentImportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(
      clerk_id: "clerk_doc_import_user",
      email: "doc-import-user@example.com",
      role: "participant",
      invitation_status: "accepted"
    )
    @household = Household.create!(
      created_by_user: @user,
      name: "Document Test Household",
      location: "Guam",
      stage: "First cohort",
      primary_goal: "Use uploaded docs safely."
    )
    @household.household_memberships.create!(user: @user, role: "owner")
  end

  test "create requires private S3 configuration" do
    post "/api/v1/document_imports",
      params: { file: uploaded_csv, document_kind: "spreadsheet" },
      headers: auth_headers(@user)

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_includes body.fetch("errors").join, "Private S3"
  end

  test "create stores upload in private S3 and enqueues extraction" do
    uploaded_keys = []

    with_s3_stubs(
      configured?: true,
      upload: ->(key, io, content_type:) {
        uploaded_keys << [ key, io.read, content_type ]
        key
      }
    ) do
      assert_difference("FinancialDocumentImport.count", 1) do
        assert_enqueued_with(job: FinancialDocumentExtractionJob) do
          post "/api/v1/document_imports",
            params: { file: uploaded_csv, document_kind: "spreadsheet", upload_request_id: "request-1" },
            headers: auth_headers(@user)
        end
      end
    end

    assert_response :created
    document_import = FinancialDocumentImport.last
    assert_equal @household.id, document_import.household_id
    assert_equal "spreadsheet", document_import.document_kind
    assert_match %r{household-cfo/test/households/#{@household.id}/documents/#{document_import.id}/source/budget\.csv\z}, document_import.s3_key
    assert_equal document_import.s3_key, uploaded_keys.first.first
    assert_equal "text/csv", uploaded_keys.first.third

    body = JSON.parse(response.body).fetch("document_import")
    assert_equal true, body.fetch("source_available")
    assert_not body.key?("s3_key")
  end

  test "create rejects mismatched file contents before upload" do
    uploaded = false

    with_s3_stubs(
      configured?: true,
      upload: ->(_key, _io, content_type:) {
        uploaded = true
        content_type
      }
    ) do
      assert_no_difference("FinancialDocumentImport.count") do
        post "/api/v1/document_imports",
          params: { file: uploaded_html_disguised_as_pdf, document_kind: "statement" },
          headers: auth_headers(@user)
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/contents do not match/i, body.fetch("errors").join)
    assert_equal false, uploaded
  end

  test "create cleans up import record when private S3 upload fails" do
    with_s3_stubs(
      configured?: true,
      upload: ->(_key, _io, content_type:) { content_type && nil }
    ) do
      assert_no_difference("FinancialDocumentImport.count") do
        post "/api/v1/document_imports",
          params: { file: uploaded_csv, document_kind: "spreadsheet" },
          headers: auth_headers(@user)
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/Could not store document/, body.fetch("errors").join)
  end

  test "create accepts docx financial documents" do
    with_s3_stubs(
      configured?: true,
      upload: ->(key, _io, content_type:) { content_type && key }
    ) do
      assert_difference("FinancialDocumentImport.count", 1) do
        assert_enqueued_with(job: FinancialDocumentExtractionJob) do
          post "/api/v1/document_imports",
            params: { file: uploaded_docx, document_kind: "other" },
            headers: auth_headers(@user)
        end
      end
    end

    assert_response :created
    document_import = FinancialDocumentImport.last
    assert_equal "other", document_import.document_kind
    assert_equal "budget-plan.docx", document_import.filename
    assert_equal "application/vnd.openxmlformats-officedocument.wordprocessingml.document", document_import.content_type
  end

  test "create accepts valid docx files when Marcel reports application zip" do
    with_s3_stubs(
      configured?: true,
      upload: ->(key, _io, content_type:) { content_type && key }
    ) do
      with_singleton_stub(Marcel::MimeType, :for, ->(*, **) { "application/zip" }) do
        assert_difference("FinancialDocumentImport.count", 1) do
          post "/api/v1/document_imports",
            params: { file: uploaded_docx, document_kind: "other" },
            headers: auth_headers(@user)
        end
      end
    end

    assert_response :created
    assert_equal "application/vnd.openxmlformats-officedocument.wordprocessingml.document", FinancialDocumentImport.last.content_type
  end

  test "source_url returns preview and download links without exposing s3 key" do
    document_import = create_import!(s3_key: "household-cfo/test/households/#{@household.id}/documents/1/source/statement.pdf")

    dispositions = []
    with_s3_stubs(
      configured?: true,
      presigned_url: ->(key, expires_in:, filename:, disposition:) {
        assert_equal document_import.s3_key, key
        assert_equal 300, expires_in
        assert_equal "statement.pdf", filename
        dispositions << disposition
        "https://private.example.test/#{disposition}"
      }
    ) do
      get "/api/v1/document_imports/#{document_import.id}/source_url", headers: auth_headers(@user)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body.fetch("inline_supported")
    assert_equal "https://private.example.test/inline", body.fetch("url")
    assert_equal "https://private.example.test/attachment", body.fetch("download_url")
    assert_equal [ :inline, :attachment ], dispositions
    assert_not body.key?("s3_key")
  end

  test "source_url keeps server-previewed csv sources as attachment links" do
    document_import = create_import!(
      document_kind: "spreadsheet",
      filename: "budget.csv",
      content_type: "text/csv",
      s3_key: "household-cfo/test/source.csv"
    )

    dispositions = []
    with_s3_stubs(
      configured?: true,
      presigned_url: ->(_key, expires_in:, filename:, disposition:) {
        assert_equal 300, expires_in
        assert_equal "budget.csv", filename
        dispositions << disposition
        "https://private.example.test/budget-#{disposition}.csv"
      }
    ) do
      get "/api/v1/document_imports/#{document_import.id}/source_url", headers: auth_headers(@user)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body.fetch("inline_supported")
    assert_equal "https://private.example.test/budget-attachment.csv", body.fetch("url")
    assert_equal "https://private.example.test/budget-attachment.csv", body.fetch("download_url")
    assert_equal [ :attachment, :attachment ], dispositions
  end

  test "source_preview renders spreadsheet rows through Rails without a browser download" do
    document_import = create_import!(
      document_kind: "spreadsheet",
      filename: "budget.csv",
      content_type: "text/csv",
      s3_key: "household-cfo/test/source.csv"
    )

    with_s3_stubs(
      configured?: true,
      download_to_io: ->(_key, io) {
        io.write("type,label,amount\nincome_source,Primary salary,6200\nexpense_item,Dining out,420\n")
        true
      }
    ) do
      get "/api/v1/document_imports/#{document_import.id}/source_preview", headers: auth_headers(@user)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "spreadsheet", body.fetch("type")
    assert_equal "budget.csv", body.fetch("filename")
    assert_not body.key?("url")
    assert_not body.key?("s3_key")
    rows = body.fetch("sheets").first.fetch("rows")
    assert_equal [ "type", "label", "amount" ], rows.first.fetch("values")
    assert_equal [ "income_source", "Primary salary", "6200" ], rows.second.fetch("values")
  end

  test "destroy removes database record before deleting private source" do
    document_import = create_import!(s3_key: "household-cfo/test/source.pdf")
    record_existed_when_s3_deleted = []

    with_s3_stubs(
      configured?: true,
      delete: ->(_key) { record_existed_when_s3_deleted << FinancialDocumentImport.exists?(document_import.id); true }
    ) do
      delete "/api/v1/document_imports/#{document_import.id}", headers: auth_headers(@user)
    end

    assert_response :no_content
    assert_not FinancialDocumentImport.exists?(document_import.id)
    assert_equal [ false ], record_existed_when_s3_deleted
  end

  test "destroy blocks imports with resolved transaction drafts" do
    document_import = create_import!(status: "partially_applied", s3_key: "household-cfo/test/source.pdf")
    category = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Payless",
      total_amount_cents: 100_00,
      budget_category: category,
      source_type: "statement",
      status: "matched",
      raw_input: "Matched row"
    )
    deleted_keys = []

    with_s3_stubs(
      configured?: true,
      delete: ->(key) { deleted_keys << key; true }
    ) do
      delete "/api/v1/document_imports/#{document_import.id}", headers: auth_headers(@user)
    end

    assert_response :unprocessable_entity
    assert_match(/Delete the source file instead/i, JSON.parse(response.body).fetch("errors").join)
    assert FinancialDocumentImport.exists?(document_import.id)
    assert_empty deleted_keys
  end

  test "destroy does not delete private source when database destroy fails" do
    callback = lambda { |item| throw(:abort) if item.label == "Block destroy" }
    FinancialDocumentImportItem.set_callback(:destroy, :before, callback)
    document_import = create_import!(s3_key: "household-cfo/test/source.pdf")
    document_import.items.create!(
      target_type: "expense_item",
      label: "Block destroy",
      amount_cents: 100_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )
    deleted_keys = []

    with_s3_stubs(
      configured?: true,
      delete: ->(key) { deleted_keys << key; true }
    ) do
      delete "/api/v1/document_imports/#{document_import.id}", headers: auth_headers(@user)
    end

    assert_response :unprocessable_entity
    assert FinancialDocumentImport.exists?(document_import.id)
    assert_empty deleted_keys
  ensure
    FinancialDocumentImportItem.skip_callback(:destroy, :before, callback)
  end

  test "destroy_source marks source deleted before deleting private source" do
    document_import = create_import!(status: "applied", s3_key: "household-cfo/test/source.pdf", applied_at: Time.current)
    item = document_import.items.create!(
      target_type: "income_source",
      label: "Primary income",
      amount_cents: 4_000_00,
      cadence: "monthly",
      source_type: "job",
      confidence: "high",
      applied_at: Time.current,
      applied_by_user: @user
    )

    source_was_marked_deleted_before_s3_delete = []
    deleted_keys = []
    with_s3_stubs(
      configured?: true,
      delete: lambda { |key|
        deleted_keys << key
        source_was_marked_deleted_before_s3_delete << !document_import.reload.source_available?
        true
      }
    ) do
      delete "/api/v1/document_imports/#{document_import.id}/source", headers: auth_headers(@user)
    end

    assert_response :success
    document_import.reload
    assert_nil document_import.s3_key
    assert_equal "applied", document_import.status
    assert_not_nil document_import.source_deleted_at
    assert FinancialDocumentImportItem.exists?(item.id)
    assert_equal [ "household-cfo/test/source.pdf" ], deleted_keys
    assert_equal [ true ], source_was_marked_deleted_before_s3_delete
  end

  test "destroy_source does not delete private source when database update fails" do
    document_import = create_import!(status: "uploaded", s3_key: "household-cfo/test/source.pdf")
    callback = lambda { |import| throw(:abort) if import.id == document_import.id && import.source_deleted_at_changed? }
    FinancialDocumentImport.set_callback(:update, :before, callback)
    deleted_keys = []

    with_s3_stubs(
      configured?: true,
      delete: ->(key) { deleted_keys << key; true }
    ) do
      delete "/api/v1/document_imports/#{document_import.id}/source", headers: auth_headers(@user)
    end

    assert_response :unprocessable_entity
    document_import.reload
    assert document_import.source_available?
    assert_empty deleted_keys
  ensure
    FinancialDocumentImport.skip_callback(:update, :before, callback)
  end

  test "destroy_source leaves source unavailable and retryable when private source delete fails" do
    document_import = create_import!(status: "uploaded", s3_key: "household-cfo/test/source.pdf")

    with_s3_stubs(
      configured?: true,
      delete: ->(_key) { false }
    ) do
      delete "/api/v1/document_imports/#{document_import.id}/source", headers: auth_headers(@user)
    end

    assert_response :service_unavailable
    document_import.reload
    assert_not document_import.source_available?
    assert_equal "source_deleted", document_import.status
    assert_equal "household-cfo/test/source.pdf", document_import.s3_key
  end

  test "item update accepts dollar-form amount balance and payment parameters" do
    document_import = create_import!(status: "needs_review")
    expense = document_import.items.create!(
      target_type: "expense_item",
      label: "Dining",
      amount_cents: 300_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )
    debt = document_import.items.create!(
      target_type: "debt",
      label: "Visa",
      balance_cents: 1_000_00,
      payment_cents: 50_00,
      debt_type: "credit_card",
      confidence: "medium"
    )

    patch "/api/v1/document_imports/#{document_import.id}/items/#{expense.id}",
      params: { item: { amount: "425.50" } },
      headers: auth_headers(@user)

    assert_response :success
    assert_equal 425_50, expense.reload.amount_cents

    patch "/api/v1/document_imports/#{document_import.id}/items/#{debt.id}",
      params: { item: { balance: "2400.25", payment: "125" } },
      headers: auth_headers(@user)

    assert_response :success
    debt.reload
    assert_equal 2_400_25, debt.balance_cents
    assert_equal 125_00, debt.payment_cents
  end

  test "unapplied item update rolls back if import reconciliation fails" do
    document_import = create_import!(status: "needs_review")
    item = document_import.items.create!(
      target_type: "expense_item",
      label: "Dining",
      amount_cents: 300_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )

    with_singleton_stub(HouseholdFinance::DocumentImportStatusReconciler, :new, reconciler_failure) do
      patch "/api/v1/document_imports/#{document_import.id}/items/#{item.id}",
        params: { item: { label: "Dining corrected", amount: "425" } },
        headers: auth_headers(@user)
    end

    assert_response :unprocessable_entity
    assert_match(/reconciler failed/i, JSON.parse(response.body).fetch("errors").join)
    item.reload
    assert_equal "Dining", item.label
    assert_equal 300_00, item.amount_cents
  end

  test "item update can correct an applied saved household value" do
    document_import = create_import!(status: "applied", applied_at: Time.current, applied_by_user: @user)
    expense = @household.expense_items.create!(
      label: "Dining out",
      amount_cents: 420_00,
      cadence: "monthly",
      stack_key: "discretionary"
    )
    item = document_import.items.create!(
      target_type: "expense_item",
      label: "Dining out",
      amount_cents: 420_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium",
      applied_at: Time.current,
      applied_by_user: @user,
      applied_record: expense
    )

    patch "/api/v1/document_imports/#{document_import.id}/items/#{item.id}",
      params: { item: { amount: "400", stack_key: "sinking_expected", ignored: true, selected: false } },
      headers: auth_headers(@user)

    assert_response :success
    item.reload
    expense.reload
    assert_equal 400_00, item.amount_cents
    assert_equal "sinking_expected", item.stack_key
    assert_equal true, item.selected
    assert_equal false, item.ignored
    assert_equal 400_00, expense.amount_cents
    assert_equal "sinking_expected", expense.stack_key
    assert_equal true, expense.active?
    assert item.metadata.key?("last_corrected_at")
  end

  test "applied item update rolls back saved value if import reconciliation fails" do
    document_import = create_import!(status: "applied", applied_at: Time.current, applied_by_user: @user)
    expense = @household.expense_items.create!(
      label: "Dining out",
      amount_cents: 420_00,
      cadence: "monthly",
      stack_key: "discretionary"
    )
    item = document_import.items.create!(
      target_type: "expense_item",
      label: "Dining out",
      amount_cents: 420_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium",
      applied_at: Time.current,
      applied_by_user: @user,
      applied_record: expense
    )

    with_singleton_stub(HouseholdFinance::DocumentImportStatusReconciler, :new, reconciler_failure) do
      patch "/api/v1/document_imports/#{document_import.id}/items/#{item.id}",
        params: { item: { amount: "400", stack_key: "sinking_expected" } },
        headers: auth_headers(@user)
    end

    assert_response :unprocessable_entity
    assert_match(/reconciler failed/i, JSON.parse(response.body).fetch("errors").join)
    item.reload
    expense.reload
    assert_equal 420_00, item.amount_cents
    assert_equal "discretionary", item.stack_key
    assert_equal 420_00, expense.amount_cents
    assert_equal "discretionary", expense.stack_key
  end

  test "item update preserves applied expense amount missing from extracted item" do
    document_import = create_import!(status: "applied", applied_at: Time.current, applied_by_user: @user)
    expense = @household.expense_items.create!(
      label: "Dining out",
      amount_cents: 420_00,
      cadence: "monthly",
      stack_key: "discretionary",
      active: true
    )
    item = document_import.items.create!(
      target_type: "expense_item",
      label: "Dining out",
      amount_cents: 420_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium",
      applied_at: Time.current,
      applied_by_user: @user,
      applied_record: expense
    )
    item.update_columns(amount_cents: nil, updated_at: Time.current)

    patch "/api/v1/document_imports/#{document_import.id}/items/#{item.id}",
      params: { item: { label: "Dining out corrected" } },
      headers: auth_headers(@user)

    assert_response :success
    expense.reload
    assert_equal "Dining out corrected", expense.label
    assert_equal 420_00, expense.amount_cents
    assert_equal true, expense.active?
  end

  test "item update preserves applied debt fields missing from extracted item" do
    document_import = create_import!(status: "applied", applied_at: Time.current, applied_by_user: @user)
    debt = @household.debts.create!(
      label: "Visa card",
      balance_cents: 3_400_00,
      minimum_payment_cents: 175_00,
      debt_type: "credit_card"
    )
    item = document_import.items.create!(
      target_type: "debt",
      label: "Visa card",
      balance_cents: 3_400_00,
      payment_cents: nil,
      debt_type: "credit_card",
      confidence: "medium",
      applied_at: Time.current,
      applied_by_user: @user,
      applied_record: debt
    )

    patch "/api/v1/document_imports/#{document_import.id}/items/#{item.id}",
      params: { item: { label: "Visa rewards card" } },
      headers: auth_headers(@user)

    assert_response :success
    debt.reload
    assert_equal "Visa rewards card", debt.label
    assert_equal 3_400_00, debt.balance_cents
    assert_equal 175_00, debt.minimum_payment_cents
  end

  test "item update keeps selected and ignored mutually exclusive" do
    document_import = create_import!(status: "needs_review")
    item = document_import.items.create!(
      target_type: "expense_item",
      label: "Dining",
      amount_cents: 300_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )

    patch "/api/v1/document_imports/#{document_import.id}/items/#{item.id}",
      params: { item: { ignored: true } },
      headers: auth_headers(@user)

    assert_response :success
    item.reload
    assert_equal false, item.selected
    assert_equal true, item.ignored

    patch "/api/v1/document_imports/#{document_import.id}/items/#{item.id}",
      params: { item: { selected: true } },
      headers: auth_headers(@user)

    assert_response :success
    item.reload
    assert_equal true, item.selected
    assert_equal false, item.ignored
  end

  test "item update rejects explicit selected and ignored conflict" do
    document_import = create_import!(status: "needs_review")
    item = document_import.items.create!(
      target_type: "expense_item",
      label: "Dining",
      amount_cents: 300_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )

    patch "/api/v1/document_imports/#{document_import.id}/items/#{item.id}",
      params: { item: { selected: true, ignored: true } },
      headers: auth_headers(@user)

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/cannot be both selected and ignored/i, body.fetch("errors").join)
    item.reload
    assert_equal true, item.selected
    assert_equal false, item.ignored
  end

  test "reprocess clears stale extracted summary and draft facts before new extraction" do
    document_import = create_import!(
      status: "needs_review",
      extracted_summary: "Old summary should not survive failed reprocess.",
      document_date: Date.new(2026, 6, 1),
      period_start_on: Date.new(2026, 6, 1),
      period_end_on: Date.new(2026, 6, 30),
      metadata: {
        "confidence" => "high",
        "warnings" => [ "old warning" ],
        "extraction_model" => "old/model",
        "last_extracted_at" => "2026-06-01T00:00:00Z",
        "upload_request_id" => "keep-me"
      }
    )
    document_import.items.create!(
      target_type: "expense_item",
      label: "Dining",
      amount_cents: 300_00,
      cadence: "monthly",
      stack_key: "discretionary",
      confidence: "medium"
    )

    with_s3_stubs(configured?: true) do
      assert_enqueued_with(job: FinancialDocumentExtractionJob, args: [ document_import.id ]) do
        post "/api/v1/document_imports/#{document_import.id}/reprocess", headers: auth_headers(@user)
      end
    end

    assert_response :success
    document_import.reload
    assert_equal "uploaded", document_import.status
    assert_nil document_import.extracted_summary
    assert_nil document_import.document_date
    assert_nil document_import.period_start_on
    assert_nil document_import.period_end_on
    assert_empty document_import.items
    assert_equal({ "upload_request_id" => "keep-me" }, document_import.metadata)
  end

  test "reprocess rejects imports that already applied household values" do
    document_import = create_import!(status: "applied", s3_key: "household-cfo/test/source.pdf", applied_at: Time.current, applied_by_user: @user)
    document_import.items.create!(
      target_type: "income_source",
      label: "Primary income",
      amount_cents: 4_000_00,
      cadence: "monthly",
      source_type: "job",
      confidence: "high",
      applied_at: Time.current,
      applied_by_user: @user
    )

    with_s3_stubs(configured?: true) do
      assert_no_enqueued_jobs only: FinancialDocumentExtractionJob do
        post "/api/v1/document_imports/#{document_import.id}/reprocess", headers: auth_headers(@user)
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/cannot be reprocessed/i, body.fetch("errors").join)
    assert_equal "applied", document_import.reload.status
  end

  test "document transaction draft update and confirm creates split actuals with source lineage" do
    document_import = create_import!(status: "needs_review", document_kind: "receipt")
    dining = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_800,
      source_type: "receipt",
      status: "pending",
      raw_input: "Receipt upload"
    )
    draft.transaction_draft_splits.create!(budget_category: dining, amount_cents: 1_800, category_name: "Dining Out")

    patch "/api/v1/transaction_drafts/#{draft.id}",
      params: {
        transaction_draft: {
          amount: "18.00",
          splits: [
            { amount: "13.75", budget_category_id: dining.id, notes: "Meal" },
            { amount: "4.25", category_name: "Tips", stack_key: "discretionary", notes: "Tip" }
          ]
        }
      },
      headers: auth_headers(@user),
      as: :json

    assert_response :success
    draft.reload
    assert_equal [ 1_375, 425 ], draft.transaction_draft_splits.order(:id).pluck(:amount_cents)

    assert_difference("HouseholdTransaction.count", 1) do
      post "/api/v1/transaction_drafts/#{draft.id}/confirm", headers: auth_headers(@user), as: :json
    end

    assert_response :success
    transaction = HouseholdTransaction.last
    assert_equal document_import.id, transaction.source_import_id
    assert_equal "receipt", transaction.source_type
    assert_equal 1_800, transaction.total_amount_cents
    tips = @household.budget_categories.find_by!(name: "Tips")
    assert_equal [ [ dining.id, 1_375 ], [ tips.id, 425 ] ], transaction.transaction_splits.order(:id).pluck(:budget_category_id, :amount_cents)
    assert_equal "confirmed", draft.reload.status
    assert_equal "applied", document_import.reload.status
    assert @household.merchant_category_rules.where(merchant_pattern: "penny cafe", budget_category: dining).exists?
    assert @household.merchant_category_rules.where(merchant_pattern: "penny cafe", budget_category: tips).exists?
  end

  test "document transaction draft confirmation upserts existing merchant category rule" do
    document_import = create_import!(status: "needs_review", document_kind: "receipt")
    dining = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    rule = @household.merchant_category_rules.create!(
      merchant_pattern: "penny cafe",
      budget_category: dining,
      confidence: BigDecimal("0.80"),
      times_confirmed: 2,
      source: "system_inferred",
      active: false
    )
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_800,
      source_type: "receipt",
      status: "pending",
      raw_input: "Receipt upload"
    )
    draft.transaction_draft_splits.create!(budget_category: dining, amount_cents: 1_800, category_name: "Dining Out")

    assert_no_difference("MerchantCategoryRule.count") do
      post "/api/v1/transaction_drafts/#{draft.id}/confirm", headers: auth_headers(@user), as: :json
    end

    assert_response :success
    rule.reload
    assert_equal BigDecimal("0.83"), rule.confidence
    assert_equal 3, rule.times_confirmed
    assert_equal "user_confirmed", rule.source
    assert rule.active?
    assert rule.last_confirmed_at.present?
  end

  test "document transaction draft top-level category update collapses stale multi-split categories" do
    document_import = create_import!(status: "needs_review", document_kind: "receipt")
    dining = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 2)
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Payless",
      total_amount_cents: 10_342,
      source_type: "receipt",
      status: "pending",
      raw_input: "Receipt upload"
    )
    draft.transaction_draft_splits.create!(budget_category: groceries, amount_cents: 8_542, category_name: "Groceries")
    draft.transaction_draft_splits.create!(budget_category: dining, amount_cents: 1_800, category_name: "Dining Out")

    patch "/api/v1/transaction_drafts/#{draft.id}",
      params: { transaction_draft: { budget_category_id: dining.id } },
      headers: auth_headers(@user),
      as: :json

    assert_response :success
    draft.reload
    assert_equal dining.id, draft.budget_category_id
    assert_equal 1, draft.transaction_draft_splits.count
    split = draft.transaction_draft_splits.first
    assert_equal dining.id, split.budget_category_id
    assert_equal 10_342, split.amount_cents
  end

  test "confirming with split corrections clears stale proposed matches" do
    document_import = create_import!(status: "needs_review", document_kind: "statement")
    groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    dining = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 2)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 7, 5))
    existing = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Payless Supermarket",
      total_amount_cents: 10_342,
      source_type: "manual_chat",
      status: "confirmed"
    )
    existing.transaction_splits.create!(budget_category: groceries, amount_cents: 10_342)
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Payless Supermarket",
      total_amount_cents: 10_342,
      budget_category: groceries,
      source_type: "statement",
      status: "pending",
      raw_input: "Statement row"
    )
    draft.transaction_draft_splits.create!(budget_category: groceries, amount_cents: 10_342, category_name: "Groceries")
    draft.transaction_draft_matches.create!(household_transaction: existing, confidence: 0.98, match_reason: "same amount")

    assert_difference("HouseholdTransaction.count", 1) do
      post "/api/v1/transaction_drafts/#{draft.id}/confirm",
        params: {
          transaction_draft: {
            splits: [
              { amount: "85.42", budget_category_id: groceries.id, notes: "Food" },
              { amount: "18.00", budget_category_id: dining.id, notes: "Other" }
            ]
          }
        },
        headers: auth_headers(@user),
        as: :json
    end

    assert_response :success
    assert_equal "corrected", draft.reload.status
    assert_empty draft.transaction_draft_matches.reload
  end

  test "document transaction draft match accepts existing actual without changing actual totals" do
    document_import = create_import!(status: "needs_review", document_kind: "statement")
    category = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 7, 5))
    transaction = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      source_type: "manual_chat",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 1_357)
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "Statement row"
    )
    match = draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.98, match_reason: "same amount, same date, similar merchant")

    assert_no_difference("HouseholdTransaction.count") do
      post "/api/v1/transaction_drafts/#{draft.id}/match",
        params: { match_id: match.id },
        headers: auth_headers(@user),
        as: :json
    end

    assert_response :success
    draft.reload
    assert_equal "matched", draft.status
    assert_equal transaction.id, draft.matched_transaction_id
    assert_equal "accepted", match.reload.status
    assert_equal "applied", document_import.reload.status
  end

  test "confirmed document transaction draft can be reopened for correction" do
    document_import = create_import!(status: "needs_review", document_kind: "receipt")
    category = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Payless Supermarket",
      total_amount_cents: 10_342,
      budget_category: category,
      source_type: "receipt",
      status: "pending",
      raw_input: "Receipt row"
    )
    draft.transaction_draft_splits.create!(budget_category: category, amount_cents: 10_342, category_name: category.name, stack_key: category.stack_key)

    post "/api/v1/transaction_drafts/#{draft.id}/confirm", headers: auth_headers(@user), as: :json
    assert_response :success
    transaction = draft.reload.confirmed_transaction
    rule = MerchantCategoryRule.find_by!(
      household: @household,
      budget_category: category,
      merchant_pattern: MerchantCategoryRule.normalized_pattern(draft.merchant)
    )
    assert_equal "confirmed", transaction.status
    assert rule.active?
    assert_equal 1, rule.times_confirmed
    assert_equal "applied", document_import.reload.status
    assert document_import.applied_at

    post "/api/v1/transaction_drafts/#{draft.id}/reopen", headers: auth_headers(@user), as: :json

    assert_response :success
    assert_equal "pending", draft.reload.status
    assert_nil draft.confirmed_transaction_id
    assert_equal "ignored", transaction.reload.status
    assert_equal draft.id, transaction.metadata.fetch("voided_by_transaction_draft_id")
    assert_not rule.reload.active?
    assert_equal 0, rule.times_confirmed
    assert_equal "needs_review", document_import.reload.status
    assert_nil document_import.applied_at
    body = JSON.parse(response.body)
    assert_equal "pending", body.dig("transaction_draft", "status")
    assert_equal 1, body.dig("workspace", "budget", "annual_plan", "pending_transaction_drafts").length
  end

  test "matched document transaction draft can be reopened without changing actuals" do
    document_import = create_import!(status: "needs_review", document_kind: "statement")
    category = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 7, 5))
    transaction = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      source_type: "manual_chat",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 1_357)
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "Statement row"
    )
    match = draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.98, match_reason: "same amount")

    post "/api/v1/transaction_drafts/#{draft.id}/match",
      params: { match_id: match.id },
      headers: auth_headers(@user),
      as: :json
    assert_response :success
    assert_equal "matched", draft.reload.status
    assert_equal "accepted", match.reload.status

    post "/api/v1/transaction_drafts/#{draft.id}/reopen", headers: auth_headers(@user), as: :json

    assert_response :success
    assert_equal "pending", draft.reload.status
    assert_nil draft.matched_transaction_id
    assert_equal "proposed", match.reload.status
    assert_equal "confirmed", transaction.reload.status
    assert_equal "needs_review", document_import.reload.status
  end

  test "confirmed draft reopen is blocked while another draft claims the actual" do
    document_import = create_import!(status: "needs_review", document_kind: "receipt")
    category = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 7, 5))
    transaction = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Payless Supermarket",
      total_amount_cents: 10_342,
      source_type: "receipt",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 10_342)
    confirmed_draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Payless Supermarket",
      total_amount_cents: 10_342,
      budget_category: category,
      source_type: "receipt",
      status: "confirmed",
      confirmed_transaction: transaction,
      raw_input: "Receipt row"
    )
    statement_draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Payless Supermarket",
      total_amount_cents: 10_342,
      budget_category: category,
      source_type: "statement",
      status: "matched",
      matched_transaction: transaction,
      raw_input: "Statement row"
    )
    statement_draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.98, match_reason: "same amount", status: "accepted")

    post "/api/v1/transaction_drafts/#{confirmed_draft.id}/reopen", headers: auth_headers(@user), as: :json

    assert_response :unprocessable_entity
    assert_match(/Undo matched statement rows/i, JSON.parse(response.body).fetch("errors").join)
    assert_equal "confirmed", confirmed_draft.reload.status
    assert_equal "confirmed", transaction.reload.status
  end

  test "document transaction draft ignore rolls back if import reconciliation fails" do
    document_import = create_import!(status: "needs_review", document_kind: "statement")
    category = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "Statement row"
    )

    with_singleton_stub(HouseholdFinance::DocumentImportStatusReconciler, :new, reconciler_failure) do
      post "/api/v1/transaction_drafts/#{draft.id}/ignore",
        headers: auth_headers(@user),
        as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/reconciler failed/i, JSON.parse(response.body).fetch("errors").join)
    assert_equal "pending", draft.reload.status
    assert_equal "needs_review", document_import.reload.status
  end

  test "document transaction draft match rolls back if import reconciliation fails" do
    document_import = create_import!(status: "needs_review", document_kind: "statement")
    category = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 7, 5))
    transaction = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      source_type: "manual_chat",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 1_357)
    draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "Statement row"
    )
    match = draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.98, match_reason: "same amount")

    with_singleton_stub(HouseholdFinance::DocumentImportStatusReconciler, :new, reconciler_failure) do
      post "/api/v1/transaction_drafts/#{draft.id}/match",
        params: { match_id: match.id },
        headers: auth_headers(@user),
        as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/reconciler failed/i, JSON.parse(response.body).fetch("errors").join)
    assert_equal "pending", draft.reload.status
    assert_nil draft.matched_transaction_id
    assert_equal "proposed", match.reload.status
    assert_equal "needs_review", document_import.reload.status
  end

  test "document transaction draft match cannot claim an already matched actual" do
    document_import = create_import!(status: "needs_review", document_kind: "statement")
    category = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 7, 5))
    transaction = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      source_type: "manual_chat",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 1_357)
    first_draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "First statement row"
    )
    second_draft = document_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "Second statement row"
    )
    first_match = first_draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.98, match_reason: "same amount")
    second_match = second_draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.98, match_reason: "same amount")

    post "/api/v1/transaction_drafts/#{first_draft.id}/match",
      params: { match_id: first_match.id },
      headers: auth_headers(@user),
      as: :json
    assert_response :success

    post "/api/v1/transaction_drafts/#{second_draft.id}/match",
      params: { match_id: second_match.id },
      headers: auth_headers(@user),
      as: :json

    assert_response :unprocessable_entity
    assert_match(/already linked/i, JSON.parse(response.body).fetch("errors").join)
    assert_equal "matched", first_draft.reload.status
    assert_equal "pending", second_draft.reload.status
    assert_equal "proposed", second_match.reload.status
  end

  test "duplicate import transaction draft can match an actual already linked by another import" do
    first_import = create_import!(status: "needs_review", document_kind: "statement")
    second_import = create_import!(status: "needs_review", document_kind: "statement", filename: "statement-duplicate.csv")
    category = @household.budget_categories.create!(name: "Dining Out", stack_key: "discretionary", sort_order: 1)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 7, 5))
    transaction = @household.household_transactions.create!(
      budget_period: period,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      source_type: "manual_chat",
      status: "confirmed"
    )
    transaction.transaction_splits.create!(budget_category: category, amount_cents: 1_357)
    first_draft = first_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      budget_category: category,
      source_type: "statement",
      status: "matched",
      matched_transaction: transaction,
      raw_input: "First statement row"
    )
    first_draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.98, match_reason: "same amount", status: "accepted")
    second_draft = second_import.transaction_drafts.create!(
      household: @household,
      occurred_on: Date.new(2026, 7, 5),
      merchant: "Penny Cafe",
      total_amount_cents: 1_357,
      budget_category: category,
      source_type: "statement",
      status: "pending",
      raw_input: "Duplicate statement row"
    )
    second_match = second_draft.transaction_draft_matches.create!(household_transaction: transaction, confidence: 0.98, match_reason: "same amount")

    post "/api/v1/transaction_drafts/#{second_draft.id}/match",
      params: { match_id: second_match.id },
      headers: auth_headers(@user),
      as: :json

    assert_response :success
    assert_equal "matched", first_draft.reload.status
    assert_equal "matched", second_draft.reload.status
    assert_equal transaction.id, second_draft.matched_transaction_id
    assert_equal "accepted", second_match.reload.status
  end

  test "imports are scoped to the authenticated household" do
    other_user = User.create!(clerk_id: "clerk_other_doc_user", email: "other-doc@example.com", role: "participant", invitation_status: "accepted")
    other_household = Household.create!(created_by_user: other_user, name: "Other Household")
    other_household.household_memberships.create!(user: other_user, role: "owner")
    other_import = FinancialDocumentImport.create!(
      household: other_household,
      uploaded_by_user: other_user,
      document_kind: "statement",
      status: "uploaded",
      filename: "other.pdf",
      content_type: "application/pdf",
      byte_size: 10,
      s3_key: "household-cfo/test/other.pdf"
    )

    get "/api/v1/document_imports/#{other_import.id}", headers: auth_headers(@user)

    assert_response :not_found
  end

  private

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def uploaded_csv
    file = Tempfile.new([ "budget", ".csv" ])
    file.write("Category,Amount\nIncome,4000\nGroceries,800\n")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv", original_filename: "budget.csv")
  end

  def uploaded_docx
    file = Tempfile.new([ "budget-plan", ".docx" ])
    file.close
    Zip::File.open(file.path, create: true) do |zip|
      zip.get_output_stream("[Content_Types].xml") do |stream|
        stream.write <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          </Types>
        XML
      end
      zip.get_output_stream("word/document.xml") do |stream|
        stream.write <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Monthly income 6200</w:t></w:r></w:p></w:body></w:document>
        XML
      end
    end
    Rack::Test::UploadedFile.new(file.path, "application/vnd.openxmlformats-officedocument.wordprocessingml.document", original_filename: "budget-plan.docx")
  end

  def uploaded_html_disguised_as_pdf
    file = Tempfile.new([ "statement", ".pdf" ])
    file.write("<html><script>alert('not a pdf')</script></html>")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/pdf", original_filename: "statement.pdf")
  end

  def create_import!(attributes = {})
    FinancialDocumentImport.create!({
      household: @household,
      uploaded_by_user: @user,
      document_kind: "statement",
      status: "uploaded",
      filename: "statement.pdf",
      content_type: "application/pdf",
      byte_size: 100,
      s3_key: "household-cfo/test/statement.pdf"
    }.merge(attributes))
  end

  def reconciler_failure(message = "reconciler failed")
    ->(*) {
      Object.new.tap do |object|
        object.define_singleton_method(:call) { raise ArgumentError, message }
      end
    }
  end

  def with_singleton_stub(target, method_name, replacement)
    singleton = class << target; self; end
    original = singleton.instance_method(method_name)
    singleton.define_method(method_name) do |*args, **kwargs, &block|
      replacement.call(*args, **kwargs, &block)
    end
    yield
  ensure
    singleton.send(:remove_method, method_name) if singleton.method_defined?(method_name)
    singleton.define_method(method_name, original)
  end

  def with_s3_stubs(stubs)
    originals = {}
    singleton = class << S3Service; self; end
    stubs.each do |method_name, replacement|
      originals[method_name] = singleton.instance_method(method_name) if singleton.method_defined?(method_name)
      singleton.define_method(method_name) do |*args, **kwargs, &block|
        if replacement.respond_to?(:call)
          replacement.call(*args, **kwargs, &block)
        else
          replacement
        end
      end
    end
    yield
  ensure
    stubs.each_key do |method_name|
      singleton.send(:remove_method, method_name) if singleton.method_defined?(method_name)
      singleton.define_method(method_name, originals[method_name]) if originals[method_name]
    end
  end
end
