require "test_helper"
require "digest"

class FinancialDocumentsReconciledStatementParserTest < ActiveSupport::TestCase
  ROOT = Rails.root.join("test/fixtures/files/documents/v2")
  NATIVE = %w[bank-descriptors.pdf running-balance.pdf continued-pages.pdf cross-month-cycle.pdf credit-card-signed.pdf].freeze

  NATIVE.each do |filename|
    test "#{filename} proves every row month and printed total without a model" do
      expected = fixture(filename)
      result = parser(filename).call
      assert result.success?, result.error
      assert_equal "native_statement", result.metadata[:extraction_mode]
      assert_accounting(expected, result.data[:source_accounting])
      assert_equal expected["expected_events"].length, result.data[:source_accounting].dig(:coverage, :reported_row_count)
      if expected["expected_events"].any? { |row| row["status"] == "pending" }
        assert_nil result.data[:source_accounting][:accounts].sole[:printed_row_count], "A posted-only count is not a printed count of all rows"
      end
      assert_empty result.data[:items], "Statement movements never invent recurring budget items"
    end
  end

  test "all nine sources have independent expected outputs and verified bytes" do
    names = JSON.parse(ROOT.join("manifest.json").read).fetch("documents")
    assert_equal 9, names.length
    names.each do |filename|
      expected = fixture(filename)
      assert expected["synthetic"]
      assert_equal expected["sha256"], Digest::SHA256.file(ROOT.join(filename)).hexdigest
      assert_equal expected["size_bytes"], ROOT.join(filename).size
    end
  end

  test "a printed overdraft is a signed balance rather than a negative debit column" do
    pages = pages_for("running-balance.pdf")
    pages.first[:runs].select { |run| run[:text].start_with?("Beginning balance:", "Ending balance:") }.each do |run|
      run[:text] = run[:text].sub("$2,450.00", "$-2,000.00").sub("$7,163.34", "$2,713.34")
    end
    pages.first[:runs].select { |run| run[:x] >= 603 && run[:text].match?(/\A[\d,]+\.\d{2}\z/) }.each do |run|
      cents = (BigDecimal(run[:text].delete(",")) * 100).to_i - 445_000
      run[:text] = format("%.2f", cents / 100.0)
    end
    result = FinancialDocuments::ReconciledStatementParser.new(pages: pages).call
    assert result.success?, result.error
    assert_equal(-200_000, result.data[:source_accounting][:accounts].sole[:opening_balance_cents])
    assert_equal 271_334, result.data[:source_accounting][:accounts].sole[:closing_balance_cents]
  end

  test "metadata before the CSV header retains physical row locators and the correct month" do
    filename = "metadata-before-header.csv"
    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: ROOT.join(filename), filename: filename, document_kind: "statement").call
    assert result.success?, result.error
    assert_accounting(fixture(filename), result.data[:source_accounting], balances: false, merchants: false)
    assert_equal 6, result.data[:source_accounting][:events].first[:locator][:row]
  end

  %w[angled-creased-receipt.jpg wide-phone-capture.png].each do |filename|
    test "#{filename} fallback contract preserves the expected dates rows and totals" do
      expected = fixture(filename)
      user = User.create!(clerk_id: SecureRandom.uuid, email: "v2-#{SecureRandom.hex(4)}@example.invalid", role: "participant", invitation_status: "accepted")
      household = HouseholdFinance::WorkspaceResolver.new(user).household
      doc = FinancialDocumentImport.new(household: household, filename: filename, document_kind: expected["kind"], content_type: filename.end_with?("jpg") ? "image/jpeg" : "image/png", s3_key: "v2-only")
      response = ROOT.join("#{filename}.response.json").read
      calls = []
      extractor = FinancialDocuments::Extractor.new(api_key: "offline")
      extractor.define_singleton_method(:perform_openrouter_request) do |payload|
        calls << payload
        FinancialDocuments::Extractor::Result.new(success: true, data: { content: response }, error: nil, metadata: {})
      end
      singleton = S3Service.singleton_class
      originals = %i[configured? download_to_io].to_h { |name| [ name, singleton.instance_method(name) ] }
      singleton.define_method(:configured?) { true }
      singleton.define_method(:download_to_io) { |_key, io| io.write(ROOT.join(filename).binread); true }
      begin
        result = extractor.call(doc)
        assert result.success?, result.error
        assert_equal 1, calls.length
        assert_equal "image_url", calls.sole.dig(:messages, 1, :content).last[:type]
        if expected["kind"] == "receipt"
          receipt = expected.fetch("expected_receipt")
          draft = result.data[:transaction_drafts].sole
          assert_equal receipt["occurred_on"], draft[:occurred_on].to_s
          assert_equal receipt["total_amount_cents"], draft[:total_amount_cents]
          assert_equal receipt["items_cents"], draft[:splits].pluck(:amount_cents)
        else
          assert_accounting(expected, result.data[:source_accounting], balances: false, merchants: false)
        end
      ensure
        originals.each { |name, method| singleton.define_method(name, method) }
      end
    end
  end

  test "a wrapped numeric continuation requires only its own page and cannot discard printed running balances" do
    subject = parser("wrapped-page.pdf")
    result = subject.call
    refute result.success?
    assert_nil result.data
    assert_equal [ 2 ], subject.failed_pages
    repaired = subject.recover(2 => accounting_for("wrapped-page.pdf", page: 2))
    assert repaired.success?, repaired.error
    assert_equal "reconciled_statement_hybrid", repaired.metadata[:extraction_mode]
    assert_accounting(fixture("wrapped-page.pdf"), repaired.data[:source_accounting])

    subject = parser("wrapped-page.pdf")
    subject.call
    bad = accounting_for("wrapped-page.pdf", page: 2)
    bad[:events][0][:signed_amount_cents] -= 1
    bad[:events][1][:signed_amount_cents] += 1
    refute subject.recover(2 => bad).success?, "Equal net totals cannot excuse altered printed row amounts"
  end

  test "partial duplicate reordered wrong-sign and mismatched-total statements never publish accounting" do
    mutations = [
      ->(pages) { pages[0][:runs].find { |run| run[:text].start_with?("Posted rows:") }[:text] = "Posted rows: 25" },
      ->(pages) { pages[0][:runs].find { |run| run[:text].start_with?("Beginning balance:") }[:text].sub!("2,450.00", "2,450.01") },
      ->(pages) { pages[0][:runs].find { |run| run[:text] == "55.25" }[:text] = "-55.25" },
      ->(pages) { pages[0][:runs].reject! { |run| run[:y] == 690 } },
      ->(pages) { pages[0][:runs].find { |run| run[:text] == "09/01" }[:text] = "08/31" },
      ->(pages) { pages[0][:runs].find { |run| run[:text] == "09/02" }[:text] = "09/04" },
      ->(pages) { pages[0][:runs] += pages[0][:runs].select { |run| run[:y] == 690 }.map { |run| run.merge(y: 680) } },
      ->(pages) { pages[0][:runs] << { text: "1234", x: 102, y: 680, finish: 125 } }
    ]
    mutations.each_with_index do |change, index|
      pages = pages_for("running-balance.pdf")
      change.call(pages)
      result = FinancialDocuments::ReconciledStatementParser.new(pages: pages).call
      refute result.success?, "mutation #{index}"
      assert_nil result.data
    end
    pages = pages_for("continued-pages.pdf").first(2)
    refute FinancialDocuments::ReconciledStatementParser.new(pages: pages).call.success?
  end

  test "fallback rejects missing extra wrong-page or unresolved rows" do
    [ ->(data) { data[:events].pop }, ->(data) { data[:events] << data[:events].first },
      ->(data) { data[:events].first[:locator][:page] = 1 }, ->(data) { data[:events].first[:row_kind] = "unresolved" } ].each do |mutate|
      subject = parser("wrapped-page.pdf")
      subject.call
      accounting = accounting_for("wrapped-page.pdf", page: 2)
      mutate.call(accounting)
      result = subject.recover(2 => accounting)
      refute result.success?
      assert_nil result.data
    end
  end

  test "one scanned or rotated page does not resend the native pages and still requires full arithmetic" do
    [ :scan, :rotation, :crop ].each do |kind|
      pages = pages_for("continued-pages.pdf")
      pages[1][:runs] = [] if kind == :scan
      pages[1][:rotation] = 90 if kind == :rotation
      pages[1][:crop] = [ 0, 0, 600, 800 ] if kind == :crop
      subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
      refute subject.call.success?
      assert_equal [ 2 ], subject.failed_pages
      result = subject.recover(2 => accounting_for("continued-pages.pdf", page: 2))
      assert result.success?, result.error
      assert_accounting(fixture("continued-pages.pdf"), result.data[:source_accounting])
    end
  end

  test "extractor repairs only the ambiguous page and keeps full source coverage" do
    doc = FinancialDocumentImport.new(document_kind: "statement", filename: "wrapped-page.pdf", content_type: "application/pdf")
    extractor = FinancialDocuments::Extractor.new(api_key: "offline")
    requested = []
    accounting = accounting_for("wrapped-page.pdf", page: 2)
    extractor.define_singleton_method(:extract_openrouter_document) do |_document, path, batch_label:|
      requested << batch_label
      raise "not a single page" unless CombinePDF.load(path).pages.one?
      FinancialDocuments::Extractor::Result.new(success: true, data: { source_accounting: accounting }, error: nil, metadata: { usage: { "total_tokens" => 10 } })
    end
    result = extractor.send(:native_statement_result, doc, ROOT.join("wrapped-page.pdf"))
    assert result.success?, result.error
    assert_equal [ "pages 2-2 of 3" ], requested
    assert_equal 1, result.metadata[:batch_count]
    assert_equal 10, result.metadata.dig(:usage, "total_tokens")
    assert_accounting(fixture("wrapped-page.pdf"), result.data[:source_accounting])
  end

  private

  def fixture(filename) = JSON.parse(ROOT.join("#{filename}.expected.json").read)
  def pages_for(filename) = FinancialDocuments::SourceSafety.pdf_text_pages(ROOT.join(filename), max_pages: 60, max_runs: 60_000)
  def parser(filename) = FinancialDocuments::ReconciledStatementParser.new(pages: pages_for(filename))

  def accounting_for(filename, page:)
    expected = fixture(filename)
    events = expected.fetch("expected_events").slice((page - 1) * 10, 10).each_with_index.map do |row, index|
      { account_key: "fixture", posted_on: row["posted_on"], signed_amount_cents: row["signed_amount_cents"], row_kind: row["row_kind"],
        event_type: row["event_type"], locator: { page: page, row: index + 1 }, merchant: row["expected_merchant"], raw_description: row["description"] }
    end
    FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "fixture", account_basis: expected["account_basis"], period_start_on: expected["period_start_on"], period_end_on: expected["period_end_on"] } ], events: events },
      coverage: { expected_page_count: 3, processed_pages: [ page ] })
  end

  def assert_accounting(expected, accounting, balances: true, merchants: true)
    rows = expected.fetch("expected_events")
    actual = accounting.fetch(:events)
    assert_equal rows.length, actual.length
    assert_equal rows.map { |row| row["posted_on"] }, actual.map { |row| row[:posted_on].iso8601 }
    assert_equal rows.map { |row| row["status"] == "pending" ? nil : row["signed_amount_cents"] }, actual.pluck(:signed_amount_cents)
    assert_equal rows.pluck("row_kind"), actual.pluck(:row_kind)
    assert_equal rows.pluck("event_type"), actual.pluck(:event_type)
    assert_equal rows.map { |row| row["posted_on"][0, 7] }.uniq, actual.map { |row| row[:posted_on].strftime("%Y-%m") }.uniq
    if merchants
      rows.each_with_index do |row, index|
        next unless row["expected_merchant"].in?(%w[Ross Kmart])
        assert_equal row["expected_merchant"], actual[index].dig(:evidence, :merchant)
      end
    end
    posted = actual.select { |row| row[:row_kind] == "posted" }
    assert_equal expected.dig("totals_cents", "printed_credit_cents"), posted.sum { |row| [ row[:signed_amount_cents], 0 ].max }
    assert_equal expected.dig("totals_cents", "printed_debit_cents"), posted.sum { |row| [ -row[:signed_amount_cents], 0 ].max }
    if balances
      %w[opening_balance_cents closing_balance_cents].each { |key| assert_equal expected.dig("totals_cents", key), accounting[:accounts].sole[key.to_sym] }
    end
  end
end
