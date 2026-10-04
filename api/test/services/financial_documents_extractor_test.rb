require "test_helper"
require "tempfile"

class FinancialDocumentsExtractorTest < ActiveSupport::TestCase
  test "qualified native statement succeeds without provider credentials or model calls" do
    document_import = FinancialDocumentImport.new(document_kind: "statement", filename: "native.pdf", content_type: "application/pdf", s3_key: "test/native")
    extractor = FinancialDocuments::Extractor.new(api_key: "")
    native = FinancialDocuments::NativeStatementParser::Result.new(success: true, data: { source_accounting: { contract_version: "source_accounting_v1" } }, error: nil, metadata: { extraction_mode: "native_statement" })
    extractor.define_singleton_method(:native_statement_result) { |_import, _path| native }
    extractor.define_singleton_method(:batched_pdf_result) { |*_args| raise "native must not invoke model extraction" }
    with_s3_stubs(configured?: true, download_to_io: ->(_key, io) { io.write("private source placeholder"); true }) do
      result = extractor.call(document_import)
      assert result.success?
      assert_equal native.data, result.data
      assert_equal "native_statement", result.metadata[:extraction_mode]
    end
  end

  test "native rejection preserves the qualified model route rather than returning partial rows" do
    document_import = FinancialDocumentImport.new(document_kind: "statement", filename: "unknown.pdf", content_type: "application/pdf", s3_key: "test/unknown")
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    fallback_called = false
    extractor.define_singleton_method(:batched_pdf_result) do |_import, _path|
      fallback_called = true
      FinancialDocuments::Extractor::Result.new(success: true, data: { transaction_drafts: [] }, error: nil, metadata: { extraction_mode: "qualified_model_test" })
    end
    with_s3_stubs(configured?: true, download_to_io: ->(_key, io) { io.write("not a native PDF"); true }) do
      result = extractor.call(document_import)
      assert result.success?
      assert fallback_called
      assert_equal "qualified_model_test", result.metadata[:extraction_mode]
    end
  end

  test "disclosure-only batches do not conflict with typed accounting but nonempty legacy rows fail closed" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    typed = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic", account_basis: "asset" } ], events: [ { account_key: "synthetic", event_type: "purchase", row_kind: "posted", signed_amount_cents: -100, amount_column_cents: 100, posted_on: "2026-07-01", locator: { page: 1, row: 1 } } ] })
    result = extractor.send(:merge_source_accounting, [ { source_accounting: typed }, { transaction_drafts: [] } ], page_count: 2)
    assert_equal FinancialDocuments::AccountingContract::VERSION, result[:contract_version]
    assert_equal 1, result[:events].length
    assert_equal 1, result[:accounts].length
    assert_equal "asset", result[:accounts].sole[:account_basis]
    assert_equal [ 1, 2 ], result[:coverage][:processed_pages]
    mixed = extractor.send(:merge_source_accounting, [ { source_accounting: typed }, { transaction_drafts: [ { occurred_on: "2026-07-02", merchant: "Legacy row" } ] } ], page_count: 2)
    refute mixed.success?
    assert_match(/inconsistent source accounting/, mixed.error)
    empty = extractor.send(:merge_source_accounting, [ { transaction_drafts: [] }, { transaction_drafts: [] } ], page_count: 2)
    assert_equal FinancialDocuments::AccountingContract::LEGACY_VERSION, empty[:contract_version]
    assert_empty empty[:accounts]
  end

  test "an explicit zero-row legacy account header is retained without fabricating events or upgrading its contract" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    legacy = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::LEGACY_VERSION,
      accounts: [ { account_key: "synthetic-zero", account_basis: "asset", opening_balance_cents: 0, closing_balance_cents: 0, header_evidence: "Synthetic zero balance header" } ], events: [] })
    merged = extractor.send(:merge_source_accounting, [ { source_accounting: legacy }, { transaction_drafts: [] } ], page_count: 2)
    assert_equal FinancialDocuments::AccountingContract::LEGACY_VERSION, merged[:contract_version]
    assert_equal legacy[:accounts], merged[:accounts]
    assert_empty merged[:events]
    assert_equal [ 1, 2 ], merged[:coverage][:processed_pages]
    typed = legacy.deep_dup.merge(contract_version: FinancialDocuments::AccountingContract::VERSION)
    merged = extractor.send(:merge_source_accounting, [ { source_accounting: typed }, { transaction_drafts: [] } ], page_count: 2)
    assert_equal FinancialDocuments::AccountingContract::VERSION, merged[:contract_version]
    assert_equal typed[:accounts], merged[:accounts]
  end

  test "account merging resolves unknown basis and retains all limitations while preserving real conflicts" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    source = lambda do |basis, closing, limitations|
      { contract_version: FinancialDocuments::AccountingContract::VERSION, events: [], accounts: [ { source_key: "same-account", account_basis: basis, closing_balance_cents: closing, limitations: limitations } ] }
    end
    unknown = source.call("unknown", nil, [ "account_basis_unknown", "first_page_limit" ])
    known = source.call("asset", 100, [ "later_page_limit" ])
    [ [ unknown, known ], [ known, unknown ] ].each do |sources|
      account = extractor.send(:merge_source_accounting, sources.map { |value| { source_accounting: value } }, page_count: 2)[:accounts].sole
      assert_equal "asset", account[:account_basis]
      assert_equal 100, account[:closing_balance_cents]
      assert_equal %w[first_page_limit later_page_limit], account[:limitations].sort
    end
    conflict = extractor.send(:merge_source_accounting, [ known, source.call("liability", 200, [ "third_page_limit" ]) ].map { |value| { source_accounting: value } }, page_count: 2)[:accounts].sole
    assert_includes conflict[:limitations], "conflicting_header_account_basis"
    assert_includes conflict[:limitations], "conflicting_header_closing_balance_cents"
    assert_includes conflict[:limitations], "third_page_limit"
  end

  test "accepts canonical model money and rejects malformed or unbounded formats" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")

    assert_equal 123_456, extractor.send(:cents_or_nil, "$1,234.56")
    assert_equal 1_200, extractor.send(:cents_or_nil, 12)
    assert_nil extractor.send(:cents_or_nil, "$1,2,3")
    assert_nil extractor.send(:cents_or_nil, "$1 2 3")
    assert_nil extractor.send(:cents_or_nil, "1e6")
    assert_nil extractor.send(:cents_or_nil, "12.345")
    assert_nil extractor.send(:cents_or_nil, "1000000000")
    assert_nil extractor.send(:cents_or_nil, "$1,000,000,000")
    assert_nil extractor.send(:cents_or_nil, "($12.00)")
  end

  test "keeps negative document balances only for signed account types" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    checking = extractor.send(:normalize_item, {
      "target_type" => "account", "label" => "Checking", "balance" => "-125.50", "account_type" => "checking"
    })
    property = extractor.send(:normalize_item, {
      "target_type" => "account", "label" => "Home", "balance" => "-125.50", "account_type" => "property"
    })

    assert_equal(-12_550, checking.fetch(:balance_cents))
    assert_nil property
  end

  test "receipt prompt requires line-specific category evidence and preserves uncertainty" do
    user = User.create!(clerk_id: "clerk_extractor_category_prompt", email: "extractor-category-prompt@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Extractor Category Prompt Household")
    household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 1)
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "uploaded",
      filename: "mixed-receipt.png",
      content_type: "image/png",
      byte_size: 4,
      s3_key: "household-cfo/test/mixed-receipt.png"
    )
    file = Tempfile.new([ "mixed-receipt", ".png" ])
    file.binmode
    file.write("test")
    file.flush

    prompt = FinancialDocuments::Extractor.new(api_key: "test-key").send(:user_content, document_import, file.path).first.fetch(:text)

    assert_equal "financial_document_extraction_v6", FinancialDocuments::Extractor::PROMPT_VERSION
    assert_includes prompt, "Categorize each split from its own line items"
    assert_includes prompt, "never apply the merchant's usual category to every split"
    assert_includes prompt, "participant will choose the category during review"
  ensure
    file&.close!
  end

  test "data URLs are base64 encoded in chunks without changing payload" do
    file = Tempfile.new("document-source")
    file.binmode
    payload = "abc" * 20_000 + "tail"
    file.write(payload)
    file.flush

    data_url = FinancialDocuments::Extractor.new(api_key: "test-key").send(:data_url, file.path, "application/pdf")

    assert_equal "data:application/pdf;base64,#{Base64.strict_encode64(payload)}", data_url
  ensure
    file&.close!
  end

  test "spreadsheet prompt keeps values but omits per-cell type and format metadata" do
    user = User.create!(clerk_id: "clerk_extractor_sheet_prompt", email: "sheet-prompt@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Spreadsheet Prompt Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "spreadsheet",
      status: "uploaded",
      filename: "budget.csv",
      content_type: "text/csv",
      byte_size: 30,
      s3_key: "household-cfo/test/budget.csv"
    )
    file = Tempfile.new([ "budget", ".csv" ])
    file.write("Category,Amount\nGroceries,425\n")
    file.flush

    content = FinancialDocuments::Extractor.new(api_key: "test-key").send(:user_content, document_import, file.path)
    prompt = content.last.fetch(:text)

    assert_includes prompt, "Groceries"
    assert_includes prompt, "425"
    refute_includes prompt, "cell_types"
    refute_includes prompt, "cell_formats"
  ensure
    file&.close!
  end

  test "batches every page of a multi-page PDF and merges all transaction rows" do
    user = User.create!(clerk_id: "clerk_extractor_pdf_batch_user", email: "extractor-pdf-batch@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Extractor PDF Batch Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "statement",
      status: "uploaded",
      filename: "monthly-statement.pdf",
      content_type: "application/pdf",
      byte_size: 20,
      s3_key: "household-cfo/test/monthly-statement.pdf"
    )
    file = Tempfile.new([ "monthly-statement", ".pdf" ])
    file.close
    pdf = CombinePDF.new
    9.times { pdf << CombinePDF.create_page }
    pdf.save(file.path)
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    batches = []
    extractor.define_singleton_method(:extract_openrouter_document) do |_import, chunk_path, batch_label:|
      batches << { label: batch_label, pages: CombinePDF.load(chunk_path).pages.count }
      index = batches.length
      FinancialDocuments::Extractor::Result.new(
        success: true,
        data: {
          document_kind: "statement",
          document_date: nil,
          period_start_on: Date.new(2026, 7, index),
          period_end_on: Date.new(2026, 7, index),
          summary: "Batch #{index}",
          confidence: "high",
          warnings: [],
          items: [],
          transaction_drafts: [
            { occurred_on: Date.new(2026, 7, index).iso8601, merchant: "Merchant #{index}", total_amount: index.to_f, total_amount_cents: index * 100, splits: [] }
          ]
        },
        error: nil,
        metadata: { usage: { "total_tokens" => 100 }, provider: "test-provider" }
      )
    end

    result = extractor.send(:batched_pdf_result, document_import, file.path)

    assert result.success?
    assert_equal [ 2, 2, 2, 2, 1 ], batches.pluck(:pages)
    assert_equal [ "pages 1-2 of 9", "pages 3-4 of 9", "pages 5-6 of 9", "pages 7-8 of 9", "pages 9-9 of 9" ], batches.pluck(:label)
    assert_equal 5, result.data.fetch(:transaction_drafts).length
    assert_equal "Mia found 5 transaction drafts across 9 statement pages for review.", result.data.fetch(:summary)
    assert_equal "pdf_batches", result.metadata.fetch(:extraction_mode)
    assert_equal 9, result.metadata.fetch(:page_count)
    assert_equal 5, result.metadata.fetch(:batch_count)
    assert_equal 500, result.metadata.dig(:usage, "total_tokens")
    assert_includes result.data.fetch(:warnings), "Processed all 9 PDF pages in 5 extraction batches."
  ensure
    file&.close!
  end

  test "fails explicitly when document extraction reaches the provider output limit" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    extractor.define_singleton_method(:build_payload) { |_import, _path, batch_label: nil| { batch_label: batch_label } }
    extractor.define_singleton_method(:perform_openrouter_request) do |_payload|
      FinancialDocuments::Extractor::Result.new(
        success: true,
        data: { content: '{"transaction_drafts":[]}' },
        error: nil,
        metadata: { finish_reason: "length", provider: "test-provider" }
      )
    end

    result = extractor.send(:extract_openrouter_document, nil, "/tmp/not-read.pdf", batch_label: "pages 1-2 of 8")

    refute result.success?
    assert_match(/output limit/i, result.error)
    assert_equal "length", result.metadata.fetch(:finish_reason)
  end

  test "rejects PDFs above the bounded page limit before starting model batches" do
    user = User.create!(clerk_id: "clerk_extractor_pdf_limit_user", email: "extractor-pdf-limit@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Extractor PDF Limit Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "statement",
      status: "uploaded",
      filename: "oversized-pages.pdf",
      content_type: "application/pdf",
      byte_size: 20,
      s3_key: "household-cfo/test/oversized-pages.pdf"
    )
    file = Tempfile.new([ "oversized-pages", ".pdf" ])
    file.close
    pdf = CombinePDF.new
    (FinancialDocuments::Extractor::MAX_PDF_PAGES + 1).times { pdf << CombinePDF.create_page }
    pdf.save(file.path)

    result = FinancialDocuments::Extractor.new(api_key: "test-key").send(:batched_pdf_result, document_import, file.path)

    refute result.success?
    assert_includes result.error, "more than #{FinancialDocuments::Extractor::MAX_PDF_PAGES} pages"
  ensure
    file&.close!
  end

  test "fails safely when a PDF cannot be parsed for bounded batching" do
    user = User.create!(clerk_id: "clerk_extractor_pdf_parse_user", email: "extractor-pdf-parse@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Extractor PDF Parse Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "statement",
      status: "uploaded",
      filename: "unparseable-statement.pdf",
      content_type: "application/pdf",
      byte_size: 20,
      s3_key: "household-cfo/test/unparseable-statement.pdf"
    )
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    extractor.define_singleton_method(:extract_openrouter_document) do |*_args, **_kwargs|
      raise "full unsliced PDF extraction must not run"
    end
    original_load = CombinePDF.method(:load)
    CombinePDF.define_singleton_method(:load) { |_path| raise CombinePDF::ParsingError, "invalid cross-reference table" }

    with_s3_stubs(
      configured?: true,
      download_to_io: ->(_key, io) { io.write("unparseable-pdf-source"); true }
    ) do
      result = extractor.call(document_import)

      refute result.success?
      assert_match(/could not be safely split/i, result.error)
      assert_match(/export the transactions as CSV/i, result.error)
    end
  ensure
    CombinePDF.define_singleton_method(:load, original_load) if original_load
  end

  test "uses OpenRouter json_object response format for default Gemini model" do
    user = User.create!(clerk_id: "clerk_extractor_format_user", email: "extractor-format@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Extractor Format Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "spreadsheet",
      status: "uploaded",
      filename: "budget.csv",
      content_type: "text/csv",
      byte_size: 20,
      s3_key: "household-cfo/test/budget.csv"
    )
    file = Tempfile.new([ "budget", ".csv" ])
    file.write("type,label,amount\nincome_source,Primary,6200\n")
    file.flush

    payload = FinancialDocuments::Extractor.new(api_key: "test-key").send(:build_payload, document_import, file.path)

    assert_equal({ type: "json_object" }, payload.fetch(:response_format))
    assert_equal FinancialDocuments::Extractor::MAX_OUTPUT_TOKENS, payload.fetch(:max_tokens)
    assert_not payload.key?(:json_schema)
  ensure
    file&.close!
  end

  test "statement extraction uses upload context and explicit posted-date year rules" do
    user = User.create!(clerk_id: "clerk_extractor_statement_context_user", email: "statement-context@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Statement Context Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "statement",
      status: "uploaded",
      filename: "statement-page.png",
      content_type: "image/png",
      byte_size: 20,
      s3_key: "household-cfo/test/statement-page.png",
      metadata: { "upload_context" => "My bank statement from the past month" }
    )
    file = Tempfile.new([ "statement-page", ".png" ])
    file.binmode
    file.write("image-source")
    file.flush

    content = FinancialDocuments::Extractor.new(api_key: "test-key").send(:user_content, document_import, file.path)
    instruction = content.first.fetch(:text)

    assert_includes instruction, Date.current.iso8601
    assert_includes instruction, "My bank statement from the past month"
    assert_includes instruction, "infer it from the statement date"
    assert_includes instruction, "copyright years"
    assert_includes instruction, "EVERY visible transaction-table row in source_accounting"
  ensure
    file&.close!
  end

  test "normalizes LLM item metadata to bounded allowlisted keys" do
    item = FinancialDocuments::Extractor.new(api_key: "test-key").send(
      :normalize_item,
      {
        "target_type" => "goal",
        "label" => "Vehicle fund",
        "amount" => 12_000,
        "balance" => nil,
        "payment" => nil,
        "cadence" => nil,
        "source_type" => nil,
        "stack_key" => nil,
        "account_type" => nil,
        "debt_type" => nil,
        "confidence" => "high",
        "evidence" => "Goal amount was visible.",
        "metadata" => {
          "goal_type" => "purchase",
          "raw_document_text" => "sensitive " * 1_000,
          "nested" => { "ignored" => true }
        }
      }
    )

    assert_equal({ "goal_type" => "purchase" }, item.fetch(:metadata))
  end

  test "normalizes transaction confidence labels to decimals" do
    user = User.create!(clerk_id: "clerk_extractor_transaction_confidence_user", email: "transaction-confidence@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Transaction Confidence Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "receipt",
      status: "uploaded",
      filename: "receipt.jpg",
      content_type: "image/jpeg",
      byte_size: 20,
      s3_key: "household-cfo/test/receipt.jpg"
    )

    draft = FinancialDocuments::Extractor.new(api_key: "test-key").send(
      :normalize_transaction_draft,
      {
        "occurred_on" => "2026-07-05",
        "merchant" => "Penny Cafe",
        "total_amount" => 13.57,
        "source_type" => "receipt",
        "confidence" => "high",
        "splits" => [
          { "category_name" => "Dining Out", "stack_key" => "discretionary", "amount" => 13.57, "confidence" => "medium" }
        ]
      },
      document_import
    )

    assert_equal BigDecimal("0.90"), draft.fetch(:confidence)
    assert_equal BigDecimal("0.65"), draft.fetch(:splits).first.fetch(:confidence)
  end

  test "rejects oversized inline sources before building OpenRouter payload" do
    user = User.create!(clerk_id: "clerk_extractor_payload_user", email: "extractor-payload@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Extractor Payload Household")
    household.household_memberships.create!(user: user, role: "owner")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "statement",
      status: "uploaded",
      filename: "large-statement.png",
      content_type: "image/png",
      byte_size: 20,
      s3_key: "household-cfo/test/large-statement.png"
    )
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")

    extractor.define_singleton_method(:max_data_url_source_bytes) { 10 }
    with_s3_stubs(
      configured?: true,
      download_to_io: ->(_key, io) { io.write("oversized-source"); true }
    ) do
      result = extractor.call(document_import)

      assert_not result.success?
      assert_match(/too large/i, result.error)
    end
  end

  test "rejects model output above transaction and setup row caps instead of truncating" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")

    transaction_error = extractor.send(
      :extraction_row_limit_error,
      { "transaction_drafts" => Array.new(HouseholdFinance::DocumentTransactionDraftPersister::MAX_DRAFTS + 1) { {} } }
    )
    item_error = extractor.send(
      :extraction_row_limit_error,
      { "items" => Array.new(FinancialDocuments::Extractor::MAX_ITEMS + 1) { {} } }
    )

    assert_includes transaction_error, "more than 500 transaction rows"
    assert_includes transaction_error, "without silently truncating"
    assert_includes item_error, "more than 60 budget/profile values"
    assert_includes item_error, "without silently truncating"
  end

  test "rejects merged PDF batches above the setup value cap" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    items = Array.new(FinancialDocuments::Extractor::MAX_ITEMS + 1) do |index|
      { target_type: "expense_item", label: "Item #{index}", amount_cents: index + 1 }
    end

    result = extractor.send(:merge_pdf_batch_results, [ { items: items, transaction_drafts: [], warnings: [] } ], [], page_count: 2)

    refute result.success?
    assert_includes result.error, "more than 60 budget/profile values"
    assert_includes result.error, "without silently truncating"
  end

  test "treats oversized structured setup rows as terminal instead of falling back to the model" do
    extractor = FinancialDocuments::Extractor.new(api_key: "test-key")
    errors = [
      "This spreadsheet has more than 60 budget/profile rows. Split it into smaller files.",
      "This workbook has more than 50 worksheets and could not be inspected completely.",
      "This workbook has more than 200 columns and could not be inspected completely.",
      "This workbook could not be inspected completely within the safe cell limit."
    ]

    errors.each do |error|
      result = FinancialDocuments::StructuredSpreadsheetExtractor::Result.new(success: false, data: nil, error: error)
      assert extractor.send(:terminal_structured_spreadsheet_error?, result), error
    end
  end

  private

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
