require "test_helper"
require "tempfile"

class FinancialDocumentsExtractorTest < ActiveSupport::TestCase
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
    assert_includes instruction, "one transaction_draft per visible debit, withdrawal, or subtraction row"
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
      filename: "large-statement.pdf",
      content_type: "application/pdf",
      byte_size: 20,
      s3_key: "household-cfo/test/large-statement.pdf"
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
