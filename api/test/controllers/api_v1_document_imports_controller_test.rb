require "test_helper"
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
    assert_equal "https://private.example.test/inline", body.fetch("url")
    assert_equal "https://private.example.test/attachment", body.fetch("download_url")
    assert_equal [ :inline, :attachment ], dispositions
    assert_not body.key?("s3_key")
  end

  test "source_url serves csv sources inline for in-app preview and download separately" do
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
    assert_equal true, body.fetch("inline_supported")
    assert_equal "https://private.example.test/budget-inline.csv", body.fetch("url")
    assert_equal "https://private.example.test/budget-attachment.csv", body.fetch("download_url")
    assert_equal [ :inline, :attachment ], dispositions
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
