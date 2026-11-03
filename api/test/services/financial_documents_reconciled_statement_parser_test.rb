require "test_helper"
require "digest"

class FinancialDocumentsReconciledStatementParserTest < ActiveSupport::TestCase
  ROOT = Rails.root.join("test/fixtures/files/documents/v2")
  NATIVE = %w[bank-descriptors.pdf running-balance.pdf continued-pages.pdf cross-month-cycle.pdf credit-card-signed.pdf].freeze
  ORIGINAL = JSON.parse(ROOT.join("../manifest.json").read).fetch("documents").select do |doc|
    doc["kind"] == "statement" && doc["format"] == "pdf" && !doc["filename"].include?("scanned")
  end.freeze

  test "a later invalid date aborts repair eligibility and never calls the provider" do
    [ "08/31", "09/31/2026" ].each do |invalid_date|
      pages = pages_for("continued-pages.pdf")
      pages.first[:rotation] = 90
      pages.last[:runs].find { |run| run[:text].match?(FinancialDocuments::ReconciledStatementParser::DATE) }[:text] = invalid_date
      subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
      result = subject.call
      refute result.success?
      assert_nil result.data
      assert_empty subject.failed_pages
      refute subject.recover({}).success?

      source = FinancialDocuments::SourceSafety.singleton_class
      original = source.instance_method(:pdf_text_pages)
      source.define_method(:pdf_text_pages) { |*args, **kwargs| pages }
      begin
        extractor = FinancialDocuments::Extractor.new(api_key: "offline")
        extractor.define_singleton_method(:extract_openrouter_document) { |*args, **kwargs| flunk "Invalid statements must never enter page repair" }
        document = FinancialDocumentImport.new(document_kind: "statement", filename: "continued-pages.pdf", content_type: "application/pdf")
        rejected = extractor.send(:native_statement_result, document, ROOT.join("continued-pages.pdf"))
        refute rejected.success?
        assert_nil rejected.data
      ensure
        source.define_method(:pdf_text_pages, original)
      end
    end
  end

  test "a dated row without description requires repair and preserves printed monetary evidence" do
    filename = "review-1/merchant-locations-numeric-name.pdf"
    pages = pages_for(filename)
    pages.first[:runs].reject! { |run| run[:y] == 690 && run[:x].between?(100, 450) }
    subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
    result = subject.call
    refute result.success?
    assert_nil result.data
    assert_equal [ 1 ], subject.failed_pages
    bad = accounting_for(filename, page: 1)
    bad[:events].first[:signed_amount_cents] += 1
    refute subject.recover(1 => bad).success?

    subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
    subject.call
    recovered = subject.recover(1 => accounting_for(filename, page: 1))
    assert recovered.success?, recovered.error
    assert_accounting(fixture(filename), recovered.data[:source_accounting])
  end

  ORIGINAL.each do |expected|
    test "original #{expected['filename']} reaches native extraction and exactly matches independent expected accounting" do
      filename = expected.fetch("filename")
      doc = FinancialDocumentImport.new(document_kind: "statement", filename: filename, content_type: "application/pdf")
      extractor = FinancialDocuments::Extractor.new(api_key: "")
      extractor.define_singleton_method(:extract_openrouter_document) { |*| flunk "Reconciled text must not request a model" }
      result = extractor.send(:native_statement_result, doc, ROOT.join("..", filename))
      assert result&.success?, result&.error || "No native result"
      assert_equal "native_statement", result.metadata[:extraction_mode]
      assert result.metadata[:printed_arithmetic_verified]
      assert_accounting(expected, result.data[:source_accounting])
      assert_equal "****#{expected.fetch('expected_events').first.fetch('account_key')[-4..]}", result.data[:source_accounting][:accounts].sole.dig(:evidence, :masked_identifier)
      assert_equal expected.values_at("period_start_on", "period_end_on"), result.data.values_at(:period_start_on, :period_end_on).map(&:iso8601)
      events = result.data[:source_accounting][:events]
      assert_equal expected["expected_events"].map { |row| row["locator"].symbolize_keys }, events.pluck(:locator)
      assert_equal expected["expected_events"].map { |row| row["status"] == "pending" ? row["signed_amount_cents"] : nil }, events.map { |row| row.dig(:evidence, :displayed_amount_cents) }
    end
  end

  test "qualified account identifiers retain only their token and fail on conflicting identifiers" do
    [ "Account: SAMPLE XXXX1234", "Account number: Everyday checking 00001234", "Account no.: Test ****1234" ].each do |identifier|
      pages = pages_for("review-1/merged-account-period.pdf")
      account = pages.first[:runs].find { |run| run[:text].start_with?("Account:") }
      account[:text] = identifier
      result = FinancialDocuments::ReconciledStatementParser.new(pages: pages).call
      assert result.success?, result.error
      assert_equal "****1234", result.data[:source_accounting][:accounts].sole.dig(:evidence, :masked_identifier)
      account[:text] += " | Account: Other 00005678"
      refute FinancialDocuments::ReconciledStatementParser.new(pages: pages).call.success?
    end
  end

  test "a year or short bare number after a qualifier is never an account identifier" do
    [ "Account: Everyday Checking Member since 2014", "Account: Checking opened 1998", "Account number: Joint 4321" ].each do |identifier|
      pages = pages_for("review-1/merged-account-period.pdf")
      pages.first[:runs].find { |run| run[:text].start_with?("Account:") }[:text] = identifier
      refute FinancialDocuments::ReconciledStatementParser.new(pages: pages).call.success?, identifier
    end
  end

  test "contradictory sign conventions and duplicate column sides never publish" do
    pages = pages_for("running-balance.pdf")
    pages.first[:runs] << { text: "Credits positive; debits negative", x: 36, y: 880 }
    pages.first[:runs] << { text: "Purchases positive; payments and refunds negative", x: 36, y: 870 }
    refute FinancialDocuments::ReconciledStatementParser.new(pages: pages).call.success?, "both sign conventions"

    pages = pages_for("running-balance.pdf")
    pages.each { |page| page[:runs].each { |run| run[:text] = "Payments" if run[:text] == "Debit" } }
    pages.each { |page| page[:runs].each { |run| run[:text] = "Deposits" if run[:text] == "Credit" } }
    refute FinancialDocuments::ReconciledStatementParser.new(pages: pages).call.success?, "two credit-side columns"
  end

  test "column words and explicit signed asset amounts work independently of institution or coordinates" do
    pages = pages_for("running-balance.pdf")
    pages.each do |page|
      page[:runs].each do |run|
        run[:text] = { "Debit" => "Withdrawals", "Credit" => "Deposits" }.fetch(run[:text], run[:text])
        run[:x] += 17
        run[:finish] += 17 if run[:finish]
      end
    end
    result = FinancialDocuments::ReconciledStatementParser.new(pages: pages).call
    assert result.success?, result.error
    assert_accounting(fixture("running-balance.pdf"), result.data[:source_accounting])

    pages.each do |page|
      page[:runs].reject! { |run| run[:text] == "Deposits" }
      page[:runs].each do |run|
        if run[:text] == "Withdrawals"
          run[:text] = "Amount"
        elsif run[:text].match?(FinancialDocuments::ReconciledStatementParser::MONEY) && run[:x].between?(450, 600)
          if run[:x] < 540
            run[:text] = "-#{run[:text]}"
          else
            run[:x] -= 57
          end
        end
      end
    end
    refute FinancialDocuments::ReconciledStatementParser.new(pages: pages).call.success?, "Amount signs need a printed convention"
    pages.first[:runs] << { text: "Credits positive; debits negative", x: 36, y: 880 }
    result = FinancialDocuments::ReconciledStatementParser.new(pages: pages).call
    assert result.success?, result.error
    assert_accounting(fixture("running-balance.pdf"), result.data[:source_accounting])
  end

  test "original statements with missing evidence or corrupted totals never publish native accounting" do
    ORIGINAL.each do |expected|
      [ "Beginning balance:", "Ending balance:", "Posted credits:", "Posted rows:" ].each do |label|
        pages = FinancialDocuments::SourceSafety.pdf_text_pages(ROOT.join("..", expected["filename"]), max_pages: 60, max_runs: 60_000)
        pages.each { |page| page[:runs].reject! { |run| run[:text].include?(label) } }
        refute FinancialDocuments::ReconciledStatementParser.new(pages: pages).call.success?, "#{expected['filename']} missing #{label}"
      end
      pages = FinancialDocuments::SourceSafety.pdf_text_pages(ROOT.join("..", expected["filename"]), max_pages: 60, max_runs: 60_000)
      pages.first[:runs].find { |run| run[:text].include?("Ending balance:") }[:text].sub!(/(Ending balance: \$[\d,]+\.)(\d\d)/) { "#{Regexp.last_match(1)}99" }
      result = FinancialDocuments::ReconciledStatementParser.new(pages: pages).call
      refute result.success?
      assert_nil result.data
    end
  end

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
    assert_nil result.data[:source_accounting][:accounts].sole[:opening_balance_cents]
    assert_nil result.data[:source_accounting][:accounts].sole[:closing_balance_cents]
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
          assert_nil result.data[:source_accounting][:accounts].sole[:opening_balance_cents]
          assert_nil result.data[:source_accounting][:accounts].sole[:closing_balance_cents]
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
      FinancialDocuments::Extractor::Result.new(success: true, data: { source_accounting: accounting, confidence: "low", warnings: [ "One merchant name needs a closer look." ] }, error: nil, metadata: { usage: { "total_tokens" => 10 } })
    end
    result = extractor.send(:native_statement_result, doc, ROOT.join("wrapped-page.pdf"))
    assert result.success?, result.error
    assert_equal [ "pages 2-2 of 3" ], requested
    assert_equal 1, result.metadata[:batch_count]
    assert_equal 10, result.metadata.dig(:usage, "total_tokens")
    assert_equal "low", result.data[:confidence]
    assert_includes result.data[:warnings], "One merchant name needs a closer look."
    assert_accounting(fixture("wrapped-page.pdf"), result.data[:source_accounting])
  end

  test "review corpus bytes and every native expected row are independently verified" do
    names = JSON.parse(ROOT.join("review-1/manifest.json").read).fetch("documents")
    assert_equal 7, names.length
    names.each do |name|
      filename = "review-1/#{name}"
      expected = fixture(filename)
      assert expected["synthetic"]
      assert_equal expected["sha256"], Digest::SHA256.file(ROOT.join(filename)).hexdigest
      assert_equal expected["size_bytes"], ROOT.join(filename).size
      subject = parser(filename)
      result = subject.call
      assert_equal expected["native"], result.success?, "#{name}: #{result.error}"
      assert_equal expected["failed_pages"], subject.failed_pages
      next unless result.success?

      assert_accounting(expected, result.data[:source_accounting])
      assert_equal expected["masked_identifier"], result.data[:source_accounting][:accounts].sole.dig(:evidence, :masked_identifier)
      assert_equal expected["expected_events"].pluck("expected_merchant"), result.data[:source_accounting][:events].map { |event| event.dig(:evidence, :merchant) }
      assert result.metadata[:printed_arithmetic_verified]
    end
  end

  test "returned unpaid fee is posted spending but a relabelled summary cannot claim reconciliation" do
    result = parser("review-1/nsf-return-fee.pdf").call
    assert result.success?, result.error
    fee = result.data[:source_accounting][:events].sole
    assert_equal "posted", fee[:row_kind]
    assert_equal "fee", fee[:event_type]
    assert_equal(-3500, fee[:signed_amount_cents])
    assert_equal 3500, fee[:expense_amount_cents]

    result = parser("review-1/relabelled-summary.pdf").call
    refute result.success?, "Post-normalization rows must still be exactly the rows whose arithmetic was checked"
    assert_nil result.data
    refute result.metadata[:printed_arithmetic_verified]
  end

  test "classification repair cannot swap readable credits even when totals and closing still agree" do
    filename = "review-1/classification-repair.pdf"
    subject = parser(filename)
    refute subject.call.success?
    repaired = review_accounting(filename, page: 1)
    assert subject.recover(1 => repaired).success?

    subject = parser(filename)
    subject.call
    repaired[:events][0][:signed_amount_cents], repaired[:events][1][:signed_amount_cents] = repaired[:events][1][:signed_amount_cents], repaired[:events][0][:signed_amount_cents]
    result = subject.recover(1 => repaired)
    refute result.success?
    assert_nil result.data
  end

  test "readable running balance survives an unreadable amount on the same repaired row" do
    filename = "review-1/classification-repair.pdf"
    pages = pages_for(filename)
    pages.first[:runs].find { |run| run[:text] == "50.00" }[:text] = "?"
    subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
    subject.call
    assert subject.recover(1 => review_accounting(filename, page: 1)).success?

    subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
    subject.call
    repaired = review_accounting(filename, page: 1)
    repaired[:events][0][:signed_amount_cents] += 1000
    # Leave the second amount unreadable too: the net change still reconciles,
    # but the first printed running balance proves the repair wrong.
    pages.first[:runs].find { |run| run[:text] == "75.00" }[:text] = "?"
    subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
    subject.call
    repaired[:events][1][:signed_amount_cents] -= 1000
    refute subject.recover(1 => repaired).success?
  end

  test "summary and disclosure dates do not create transactions or model calls" do
    filename = "review-1/summary-and-disclosure.pdf"
    subject = parser(filename)
    result = subject.call
    assert result.success?, result.error
    assert_equal({ 1 => :non_transaction, 2 => :transaction, 3 => :non_transaction }, subject.page_types)
    assert_equal [ 1, 2, 3 ], result.data[:source_accounting].dig(:coverage, :processed_pages)
    assert_equal [ 2 ], result.data[:source_accounting][:events].map { |event| event.dig(:locator, :page) }.uniq

    extractor = FinancialDocuments::Extractor.new(api_key: "offline")
    extractor.define_singleton_method(:extract_openrouter_document) { |*| flunk "Supporting pages must not call the model" }
    doc = FinancialDocumentImport.new(document_kind: "statement", filename: filename, content_type: "application/pdf")
    assert extractor.send(:native_statement_result, doc, ROOT.join(filename)).success?

    pages = pages_for(filename)
    pages.first[:runs] += [ { text: "11/05", x: 36, y: 600 }, { text: "Store", x: 102, y: 600 }, { text: "35.00", x: 490, y: 600 } ]
    subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
    refute subject.call.success?
    assert_equal :unreadable, subject.page_types[1], "A summary heading cannot hide printed transaction rows"
  end

  test "scan with a dated text footer repairs its page without treating the footer as a row census" do
    filename = "review-1/scanned-text-footer.pdf"
    subject = parser(filename)
    refute subject.call.success?
    assert_equal :unreadable, subject.page_types[2]
    assert_equal [ 2 ], subject.failed_pages
    result = subject.recover(2 => review_accounting(filename, page: 2))
    assert result.success?, result.error
    assert_accounting(fixture(filename), result.data[:source_accounting])
    assert_equal "reconciled_statement_hybrid", result.metadata[:extraction_mode]

    pages = pages_for(filename)
    pages.last[:runs] = pages.last[:runs].reject { |run| run[:text].match?(FinancialDocuments::ReconciledStatementParser::DATE) }
    subject = FinancialDocuments::ReconciledStatementParser.new(pages: pages)
    refute subject.call.success?
    assert subject.recover(2 => review_accounting(filename, page: 2)).success?, "A footer without dates must not create an empty native census either"
  end

  private

  def fixture(filename) = JSON.parse(ROOT.join("#{filename}.expected.json").read)
  def pages_for(filename) = FinancialDocuments::SourceSafety.pdf_text_pages(ROOT.join(filename), max_pages: 60, max_runs: 60_000)
  def parser(filename) = FinancialDocuments::ReconciledStatementParser.new(pages: pages_for(filename))

  def review_accounting(filename, page:)
    expected = fixture(filename)
    rows = expected.fetch("expected_events")
    rows = rows.drop(1) if filename.end_with?("scanned-text-footer.pdf")
    events = rows.map.with_index do |row, index|
      row.slice("posted_on", "signed_amount_cents", "row_kind", "event_type").symbolize_keys.merge(account_key: "fixture", merchant: row["description"], raw_description: row["description"], locator: { page: page, row: index + 1 })
    end
    FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "fixture", account_basis: "asset", period_start_on: expected["period_start_on"], period_end_on: expected["period_end_on"] } ], events: events },
      coverage: { expected_page_count: expected["page_count"], processed_pages: [ page ] })
  end

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
