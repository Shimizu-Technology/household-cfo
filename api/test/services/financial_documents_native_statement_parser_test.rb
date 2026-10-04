require "test_helper"

class FinancialDocumentsNativeStatementParserTest < ActiveSupport::TestCase
  test "PDF boundary checks reject rotation crop drift excess pages and unreadable content safely" do
    page_type = Struct.new(:attributes, :runs)
    reader_type = Struct.new(:page_count, :pages)
    [ { MediaBox: [ 0, 0, 612, 792 ], Rotate: 90 }, { MediaBox: [ 0, 0, 612, 792 ], CropBox: [ 0, 0, 500, 792 ] } ].each do |attributes|
      reader = reader_type.new(1, [ page_type.new(attributes, []) ])
      with_reader(reader) do
        result = FinancialDocuments::NativeStatementParser.new(file_path: "not-read").call
        refute result.success?
        assert_equal "page_geometry", result.error
        assert_nil result.data
      end
    end
    with_reader(reader_type.new(61, [])) do
      result = FinancialDocuments::NativeStatementParser.new(file_path: "not-read").call
      assert_equal "page_limit", result.error
      assert_nil result.data
    end
    result = FinancialDocuments::NativeStatementParser.new(file_path: "absent-source.pdf").call
    assert_equal "pdf_unreadable_or_unsupported", result.error
    assert_nil result.data
  end

  test "native money rejects internal digit spaces and descriptions mask long source identifiers" do
    parser = FinancialDocuments::NativeStatementParser.new(file_path: "not-read")
    assert_equal(-1234, parser.send(:money, "- 12.34"))
    assert_raises(FinancialDocuments::NativeStatementParser::InvalidTemplate) { parser.send(:money, "1 2.34") }
    body = parser.send(:description, [ glyph("Transfer From 112233445566", 90, 200) ], 200, 180, from: 90, to: 395)
    assert_equal "Transfer From ****5566", body
  end

  test "native checking preserves physical duplicates signed columns rollover dates and nonposted unpaid principal" do
    result = parse(wells_pages)
    assert result.success?
    source = result.data[:source_accounting]
    financial = source[:events].reject { |event| event[:row_kind] == "informational" }
    assert_equal 3, financial.size
    assert_equal [ -2500, -2500, 10_000 ], financial.pluck(:signed_amount_cents)
    assert_equal [ "2025-12-10", "2025-12-10", "2026-01-02" ], financial.pluck(:posted_on).map(&:iso8601)
    assert_equal Date.new(2025, 12, 9), financial.first[:authorized_on]
    assert_equal 3, financial.pluck(:row_identity).uniq.size
    assert_equal 2, source[:events].count { |event| event[:row_kind] == "informational" }
    unpaid = source[:events].find { |event| event.dig(:evidence, :raw_description).to_s.start_with?("Items returned unpaid") }
    assert_nil unpaid[:signed_amount_cents]
    assert_nil unpaid[:expense_amount_cents]
    assert_equal 4500, unpaid.dig(:evidence, :displayed_amount_cents)
    report = FinancialDocuments::SourceReconciliation.new(source).call
    assert report[:accounts].sole[:arithmetic_balanced]
    assert_nil source[:accounts].sole[:printed_row_count]
    refute_includes JSON.generate(source), "1234567890"
    assert_equal "****7890", source[:accounts].sole.dig(:evidence, :masked_identifier)
  end

  test "native wallet keeps monthly header balances and exact split funding without inventing an external posted movement or purchase" do
    result = parse(apple_pages)
    source = result.data[:source_accounting]
    financial = source[:events].reject { |event| event[:row_kind] == "informational" }
    assert_equal 4, financial.size
    assert_equal [ -1000, -1000, 5000, -1000 ], financial.pluck(:signed_amount_cents)
    assert_equal 2, financial.count { |event| event[:event_type] == "unknown" && event[:row_kind] == "unresolved" }
    assert_equal 2, financial.count { |event| event[:event_type] == "transfer" }
    split = financial.last
    assert_nil split[:expense_amount_cents]
    assert_equal [ 1000, 2000 ], split[:funding_components].pluck(:amount_cents)
    assert_equal source[:accounts].sole[:source_key], split[:funding_components].first[:source_key]
    assert_equal 1, source[:accounts].size, "An outside funding component is not a fabricated bank account statement"
    assert_equal 2, source[:events].count { |event| event[:row_kind] == "informational" }
    assert_equal 10_000, source[:accounts].sole[:opening_balance_cents]
    assert_equal 12_000, source[:accounts].sole[:closing_balance_cents]
    assert result.metadata[:printed_arithmetic_verified]
    assert_empty result.data[:items]
    assert_empty result.data[:transaction_drafts]
  end

  test "unrecognized scanned incomplete reordered and coordinate drift templates reject without partial accounting" do
    changed = wells_pages
    changed.first[:runs].find { |run| run[:text] == "Wells Fargo Everyday Checking" }[:text] = "Other Bank Checking"
    assert_rejected(changed)
    assert_rejected([ { number: 1, runs: [] } ])
    changed = wells_pages
    changed.first[:runs].find { |run| run[:text] == "Page 1 of 1" }[:text] = "Page 1 of 2"
    assert_rejected(changed)
    changed = wells_pages
    changed.first[:runs].find { |run| run[:text] == "Deposits/" }[:finish] += 3
    assert_rejected(changed)
    changed = wells_pages
    changed.first[:runs].find { |run| run[:text] == "12/10" }[:x] += 3
    assert_rejected(changed)
    changed = wells_pages
    changed.first[:runs].find { |run| run[:text] == "1/2" }[:text] = "12/9"
    assert_rejected(changed)
    changed = wells_pages
    changed.first[:runs] << glyph("1/4", 45, 200)
    assert_rejected(changed)
    changed = apple_pages
    changed.last[:runs] << glyph("01/05/2026", 45, 600)
    assert_rejected(changed)
  end

  test "extra amount without a date row missing row and wrong printed daily totals cannot silently pass arithmetic" do
    changed = wells_pages
    changed.first[:runs] << money("20.00", 385, 503)
    assert_rejected(changed)
    changed = wells_pages
    changed.first[:runs].reject! { |run| run[:y] == 380 }
    assert_rejected(changed)
    changed = wells_pages
    changed.first[:runs].find { |run| run[:text] == "$150.00" && run[:y] == 370 }[:text] = "$149.99"
    assert_rejected(changed)
    changed = wells_pages
    changed.first[:runs].find { |run| run[:text] == "$100.00" && run[:y] == 350 }[:text] = "$100.01"
    assert_rejected(changed)
  end

  test "wallet summary drift unknown split money missing field and extra duplicated amount fail closed" do
    changed = apple_pages
    changed.first[:runs].find { |run| run[:text] == "Account Statement Summary 2026" }[:text] = "Account Statement Summary 2025"
    assert_rejected(changed)
    changed = apple_pages
    changed[1][:runs].find { |run| run[:text] == "-$30.00" && run[:finish] == 573.25 }[:text] = "-$30.01"
    assert_rejected(changed)
    changed = apple_pages
    changed[1][:runs].find { |run| run[:text] == "-$20.00" }[:text] = "-$19.00"
    assert_rejected(changed)
    changed = apple_pages
    changed[1][:runs].reject! { |run| run[:text] == "AMOUNT" }
    assert_rejected(changed)
    changed = apple_pages
    changed[1][:runs] << money("+$20.00", 355, 517.83)
    assert_rejected(changed)
    changed = apple_pages
    changed[1][:runs].find { |run| run[:text] == "+$0.00" }[:text] = "+$1.00"
    assert_rejected(changed)
  end

  private

  def with_reader(reader)
    original = PDF::Reader.method(:new)
    PDF::Reader.define_singleton_method(:new) { |_path| reader }
    yield
  ensure
    PDF::Reader.define_singleton_method(:new, original) if original
  end

  def parse(pages)
    FinancialDocuments::NativeStatementParser.new(file_path: "unused").send(:parse_pages, pages)
  end

  def assert_rejected(pages)
    assert_raises(FinancialDocuments::NativeStatementParser::InvalidTemplate) { parse(pages) }
  end

  def glyph(text, x, y, finish = x + 20) = { text: text, x: x, y: y, finish: finish }
  def money(text, y, finish) = glyph(text, finish - 40, y, finish)

  def wells_pages
    runs = [ glyph("Wells Fargo Everyday Checking", 36, 770), glyph("January 8, 2026", 36, 757), glyph("Page 1 of 1", 102, 757),
      glyph("Statement period activity summary", 36, 630), glyph("Account number:", 356, 624, 414), glyph("1234567890 (primary account)", 419, 624),
      glyph("Beginning balance on 12/9", 64.5, 600), money("$100.00", 600, 328),
      glyph("Deposits/Additions", 64.5, 588), money("100.00", 588, 328),
      glyph("Withdrawals/Subtractions", 64.5, 576), money("- 50.00", 576, 328),
      glyph("Ending balance on 1/8", 64.5, 564), money("$150.00", 564, 328),
      glyph("Date", 63, 400), glyph("Deposits/", 404, 410, 434), glyph("Withdrawals/", 458, 410, 502), glyph("balance", 540, 400, 566),
      glyph("12/10", 61.5, 390), glyph("Purchase authorized on 12/09 Sample Store", 150, 390), money("25.00", 390, 503), money("75.00", 390, 566),
      glyph("12/10", 61.5, 380), glyph("Purchase authorized on 12/09 Sample Store", 150, 380), money("25.00", 380, 503), money("50.00", 380, 566),
      glyph("1/2", 61.5, 370), glyph("Zelle From Example Person", 150, 370), money("100.00", 370, 434), money("$150.00", 370, 566),
      glyph("Totals", 61.5, 350), money("$100.00", 350, 434), money("$50.00", 350, 503),
      glyph("Items returned unpaid", 36, 335), glyph("1/3", 61.5, 315), glyph("Unpaid example principal", 94.5, 315), money("45.00", 315, 563) ]
    [ { number: 1, runs: runs } ]
  end

  def apple_header_runs
    [ glyph("APPLE ID", 63, 654), glyph("••••1111", 510, 669), glyph("January 1, 2026 - January 31, 2026", 420, 642) ]
  end

  def apple_pages
    overview = [ *apple_header_runs, glyph("Account Statement Summary 2026", 278, 714), glyph("Page 1 / 3", 547, 33),
      glyph("Starting Balance", 38.75, 546), money("$100.00", 546, 573.25),
      glyph("January 31, 2026", 38.75, 528), money("+$50.00", 528, 365.37), money("-$0.00", 528, 447), money("-$30.00", 528, 502.52), money("$120.00", 528, 573.25),
      glyph("Ending Balance", 38.75, 284), money("$120.00", 284, 573.25) ]
    monthly = [ *apple_header_runs, glyph("Account Statement January 2026", 290, 714), glyph("Page 2 / 3", 547, 33),
      glyph("Summary January 2026", 35, 587), glyph("Transactions January 2026", 35, 456),
      glyph("Starting Balance", 38.75, 546), money("$100.00", 546, 573.25),
      glyph("Money In", 38.75, 528), money("+$50.00", 528, 415), money("+$0.00", 528, 501), money("+$50.00", 528, 573.25),
      glyph("Money Out", 38.75, 509), money("-$30.00", 509, 415), money("-$0.00", 509, 501), money("-$30.00", 509, 573.25),
      glyph("Ending Balance", 38.75, 490), money("$120.00", 490, 573.25),
      glyph("DATE", 38.75, 435.15), glyph("DESCRIPTION", 90.86, 435.15), glyph("ACCOUNT FEE", 430.79, 435.15), glyph("AMOUNT", 498.17, 435.15), glyph("BALANCE", 552.76, 435.15),
      glyph("Starting Balance", 90.86, 415), money("$100.00", 415, 573.25),
      glyph("01/02/2026", 38.75, 399), glyph("Sample merchant", 90.86, 399), money("-$10.00", 388, 517.83), money("$90.00", 388, 573.25),
      glyph("01/02/2026", 38.75, 374), glyph("Sample merchant", 90.86, 374), money("-$10.00", 363, 517.83), money("$80.00", 363, 573.25),
      glyph("01/03/2026", 38.75, 349), glyph("Added to Balance", 90.86, 349), money("+$50.00", 338, 517.83), money("$130.00", 338, 573.25),
      glyph("01/04/2026", 38.75, 324), glyph("Payment to Example Person", 90.86, 324),
      glyph("Total Payment", 241.73, 324), money("$30.00", 324, 395.61),
      glyph("From WELLS FARGO BANK", 241.73, 313), glyph("NATIONAL ASSOCIATION (••••", 241.73, 304), glyph("2222)", 241.73, 295), money("-$20.00", 295, 395.61),
      glyph("From Apple Cash", 241.73, 284), money("$10.00", 284, 395.61), money("-$10.00", 284, 517.83), money("$120.00", 284, 573.25),
      glyph("Ending Balance", 90.86, 250), money("$120.00", 250, 573.25) ]
    [ { number: 1, runs: overview }, { number: 2, runs: monthly }, { number: 3, runs: [ glyph("Page 3 / 3", 547, 33), glyph("Legal terms", 35, 700) ] } ]
  end
end
