require "test_helper"

class FinancialDocumentsStructuredSpreadsheetExtractorTest < ActiveSupport::TestCase
  test "extracts Household CFO Excel template rows without AI" do
    file_path = Rails.root.join("..", "web", "public", "household-cfo-budget-template.xlsx")

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file_path.to_s, filename: "household-cfo-budget-template.xlsx").call

    assert result.success?, result.error
    items = result.data.fetch(:items)
    assert_equal 10, items.length
    assert_equal "job", items.find { |item| item[:label] == "Primary salary" }.fetch(:source_type)
    assert_equal "non_discretionary", items.find { |item| item[:label] == "Rent or mortgage" }.fetch(:stack_key)
    assert_equal "sinking_expected", items.find { |item| item[:label] == "Car maintenance fund" }.fetch(:stack_key)
    assert_equal "sinking_unexpected", items.find { |item| item[:label] == "Medical and family buffer" }.fetch(:stack_key)
    assert_equal "emergency_fund", items.find { |item| item[:label] == "Emergency fund" }.fetch(:account_type)
    debt = items.find { |item| item[:label] == "Visa card" }
    assert_equal "credit_card", debt.fetch(:debt_type)
    assert_equal 3400_00, debt.fetch(:balance_cents)
    assert_equal 175_00, debt.fetch(:payment_cents)
  end

  test "skips non-finite spreadsheet amounts without failing whole extraction" do
    file = Tempfile.new([ "budget", ".csv" ])
    file.write("type,label,amount,cadence,category,notes\nexpense_item,Broken formula,NaN,monthly,discretionary,Ignore\nexpense_item,Dining out,420,monthly,discretionary,Valid\n")
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "budget.csv").call

    assert result.success?, result.error
    items = result.data.fetch(:items)
    assert_equal 1, items.length
    assert_equal "Dining out", items.first.fetch(:label)
  ensure
    file&.close!
  end

  test "rejects malformed grouped scientific and fractional-cent spreadsheet money" do
    file = Tempfile.new([ "budget", ".csv" ])
    file.write(<<~CSV)
      type,label,amount,cadence,category,notes
      expense_item,Bad grouping,"$1,2,3",monthly,discretionary,Reject
      expense_item,Scientific notation,1e6,monthly,discretionary,Reject
      expense_item,Fractional cents,12.345,monthly,discretionary,Reject
      expense_item,Valid grouped,"$1,234.56",monthly,discretionary,Keep
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "budget.csv").call

    assert result.success?, result.error
    assert_equal [ "Valid grouped" ], result.data.fetch(:items).map { |item| item.fetch(:label) }
    assert_equal 123_456, result.data.fetch(:items).first.fetch(:amount_cents)
  ensure
    file&.close!
  end

  test "parses accounting negative expenses and debts as positive magnitudes" do
    file = Tempfile.new([ "budget", ".csv" ])
    file.write(<<~CSV)
      type,label,amount,cadence,category,payment,notes
      expense_item,Dining out,($420.25),monthly,discretionary,,Accounting export expense
      debt,Visa card,"($3,400)",monthly,credit_card,($175),Accounting export liability
      income_source,Reversal,($100),monthly,job,,Negative income adjustment should not import as income
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "budget.csv").call

    assert result.success?, result.error
    items = result.data.fetch(:items)
    assert_equal 2, items.length
    dining_out = items.find { |item| item[:label] == "Dining out" }
    debt = items.find { |item| item[:label] == "Visa card" }
    assert_equal 42_025, dining_out.fetch(:amount_cents)
    assert_equal 340_000, debt.fetch(:balance_cents)
    assert_equal 17_500, debt.fetch(:payment_cents)
  ensure
    file&.close!
  end

  test "extracts statement transaction rows from structured spreadsheets without AI" do
    file = Tempfile.new([ "statement", ".csv" ])
    file.write(<<~CSV)
      date,description,amount,category,notes
      not-a-date,Bad Row,10,Dining Out,Invalid date should skip only this row
      "May 12, 2026",Ross,45.25,Discretionary,Long-form date should parse
      2026-07-05,Penny Cafe,13.57,Dining Out,Lunch
      07/06/2026,Payless,"($103.42)",Groceries,Receipt total
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "statement.csv", document_kind: "statement").call

    assert result.success?, result.error
    drafts = result.data.fetch(:transaction_drafts)
    assert_equal 3, drafts.length
    assert_equal "statement", result.data.fetch(:document_kind)
    assert_equal Date.new(2026, 5, 12), result.data.fetch(:period_start_on)
    assert_equal Date.new(2026, 7, 6), result.data.fetch(:period_end_on)
    assert_equal "Ross", drafts.first.fetch(:merchant)
    assert_equal Date.new(2026, 5, 12), drafts.first.fetch(:occurred_on)
    assert_equal BigDecimal("0.90"), drafts.first.fetch(:confidence)
    assert_equal "Penny Cafe", drafts.second.fetch(:merchant)
    assert_equal 1_357, drafts.second.fetch(:total_amount_cents)
    assert_equal "Dining Out", drafts.second.fetch(:splits).first.fetch(:category_name)
    assert_equal BigDecimal("0.90"), drafts.second.fetch(:splits).first.fetch(:confidence)
    assert_equal 10_342, drafts.third.fetch(:total_amount_cents)
  ensure
    file&.close!
  end

  test "imports only debit amounts and never mistakes deposits or running balances for spending" do
    file = Tempfile.new([ "bank-statement", ".csv" ])
    file.write(<<~CSV)
      date,description,debit,credit,balance
      2026-08-01,Grocery Store,100.00,,4900.00
      2026-08-02,Payroll,,2000.00,6900.00
      2026-08-03,Store refund,,25.00,6925.00
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "bank-statement.csv", document_kind: "statement").call

    assert result.success?, result.error
    drafts = result.data.fetch(:transaction_drafts)
    assert_equal [ "Grocery Store" ], drafts.map { |draft| draft.fetch(:merchant) }
    assert_equal 10_000, drafts.first.fetch(:total_amount_cents)
    assert_includes result.data.fetch(:warnings).join(" "), "Payroll"
    assert_includes result.data.fetch(:warnings).join(" "), "Store refund"
    refute_includes drafts.to_json, "490000"
    refute_includes drafts.to_json, "690000"
  ensure
    file&.close!
  end

  test "keeps a credit-only statement on the structured path without inventing spending" do
    file = Tempfile.new([ "credits-only", ".csv" ])
    file.write(<<~CSV)
      date,description,debit,credit,balance
      2026-08-01,Payroll,,2000.00,7000.00
      2026-08-02,Merchant refund,,50.00,7050.00
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "credits-only.csv", document_kind: "statement").call

    assert result.success?, result.error
    assert_empty result.data.fetch(:items)
    assert_empty result.data.fetch(:transaction_drafts)
    assert_equal 2, result.data.fetch(:warnings).length
    assert_includes result.data.fetch(:summary), "no spending transactions"
  ensure
    file&.close!
  end

  test "recognizes bank withdrawal deposit and running-balance header variants" do
    file = Tempfile.new([ "bank-export", ".csv" ])
    file.write(<<~CSV)
      transaction date,description,withdrawal,deposit,running balance
      2026-08-01,Hardware Store,75.50,,4924.50
      2026-08-02,Employer,,2500.00,7424.50
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "bank-export.csv", document_kind: "statement").call

    assert result.success?, result.error
    assert_equal [ "Hardware Store" ], result.data.fetch(:transaction_drafts).map { |draft| draft.fetch(:merchant) }
    assert_equal 7_550, result.data.fetch(:transaction_drafts).first.fetch(:total_amount_cents)
    assert_includes result.data.fetch(:warnings).join(" "), "Employer"
  ensure
    file&.close!
  end

  test "rejects conflicting debit and credit signals without guessing" do
    file = Tempfile.new([ "conflicting-statement", ".csv" ])
    file.write(<<~CSV)
      date,description,debit,credit,type,balance
      2026-08-01,Both columns populated,20.00,10.00,,4990.00
      2026-08-02,Contradictory direction,25.00,,credit,5015.00
      2026-08-03,Valid groceries,30.00,,debit,4985.00
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "conflicting-statement.csv", document_kind: "statement").call

    assert result.success?, result.error
    assert_equal [ "Valid groceries" ], result.data.fetch(:transaction_drafts).map { |draft| draft.fetch(:merchant) }
    assert_equal 2, result.data.fetch(:warnings).length
    assert result.data.fetch(:warnings).all? { |warning| warning.include?("conflicting debit and credit") }
  ensure
    file&.close!
  end

  test "uses explicit transaction direction before treating signed amounts as expenses" do
    file = Tempfile.new([ "directed-statement", ".csv" ])
    file.write(<<~CSV)
      date,description,amount,type,balance
      2026-08-01,Coffee Shop,-12.50,debit,4987.50
      2026-08-02,Refund,-25.00,credit,5012.50
      2026-08-03,Paycheck,2000.00,deposit,7012.50
      2026-08-04,Pharmacy,18.25,withdrawal,6994.25
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "directed-statement.csv", document_kind: "statement").call

    assert result.success?, result.error
    drafts = result.data.fetch(:transaction_drafts)
    assert_equal [ "Coffee Shop", "Pharmacy" ], drafts.map { |draft| draft.fetch(:merchant) }
    assert_equal [ 1_250, 1_825 ], drafts.map { |draft| draft.fetch(:total_amount_cents) }
    assert_includes result.data.fetch(:warnings).join(" "), "Refund"
    assert_includes result.data.fetch(:warnings).join(" "), "Paycheck"
  ensure
    file&.close!
  end

  test "does not guess the direction of uncategorized signed transaction amounts" do
    file = Tempfile.new([ "ambiguous-statement", ".csv" ])
    file.write(<<~CSV)
      date,description,amount,category
      2026-08-01,Unclear reversal,-30.00,
      2026-08-02,Unclear incoming,45.00,
      2026-08-03,Payless,-25.00,Groceries
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "ambiguous-statement.csv", document_kind: "statement").call

    assert result.success?, result.error
    assert_equal [ "Payless" ], result.data.fetch(:transaction_drafts).map { |draft| draft.fetch(:merchant) }
    assert_equal 2_500, result.data.fetch(:transaction_drafts).first.fetch(:total_amount_cents)
    assert_equal 2, result.data.fetch(:warnings).length
    assert_includes result.data.fetch(:warnings).join(" "), "direction"
  ensure
    file&.close!
  end

  test "keeps balance headers available for approved Household CFO setup rows" do
    file = Tempfile.new([ "household-balances", ".csv" ])
    file.write(<<~CSV)
      type,label,balance,cadence,category,payment
      account,Emergency fund,5000,monthly,emergency_fund,
      debt,Visa card,3400,monthly,credit_card,175
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "household-balances.csv").call

    assert result.success?, result.error
    items = result.data.fetch(:items).index_by { |item| item.fetch(:label) }
    assert_equal 500_000, items.fetch("Emergency fund").fetch(:balance_cents)
    assert_equal 340_000, items.fetch("Visa card").fetch(:balance_cents)
    assert_equal 17_500, items.fetch("Visa card").fetch(:payment_cents)
    assert_empty result.data.fetch(:transaction_drafts)
  ensure
    file&.close!
  end

  test "extracts a full monthly CSV beyond the old eighty-row sample" do
    file = Tempfile.new([ "large-statement", ".csv" ])
    file.write("date,description,amount,category,notes\n")
    150.times do |index|
      date = Date.new(2026, 7, 1) + (index % 28).days
      file.write("#{date.iso8601},Merchant #{index + 1},#{format('%.2f', index + 1.25)},Dining Out,Statement row #{index + 1}\n")
    end
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "large-statement.csv", document_kind: "statement").call

    assert result.success?, result.error
    drafts = result.data.fetch(:transaction_drafts)
    assert_equal 150, drafts.length
    assert_equal "Merchant 1", drafts.first.fetch(:merchant)
    assert_equal "Merchant 150", drafts.last.fetch(:merchant)
  ensure
    file&.close!
  end

  test "rejects oversized statement CSVs instead of silently truncating transaction rows" do
    file = Tempfile.new([ "oversized-statement", ".csv" ])
    file.write("date,description,amount,category,notes\n")
    501.times do |index|
      file.write("2026-07-10,Merchant #{index + 1},1.25,Dining Out,Statement row #{index + 1}\n")
    end
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "oversized-statement.csv", document_kind: "statement").call

    refute result.success?
    assert_includes result.error, "more than 500 rows"
    assert_includes result.error, "without silently truncating"
  ensure
    file&.close!
  end

  test "does not import transaction-like combined rows as budget setup items" do
    file = Tempfile.new([ "combined", ".csv" ])
    file.write(<<~CSV)
      type,date,description,amount,category,notes
      expense,2026-07-05,Penny Cafe,13.57,Dining Out,Lunch transaction
      expense_item,,Monthly dining budget,400,discretionary,Budget planning row
    CSV
    file.rewind

    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "combined.csv").call

    assert result.success?, result.error
    items = result.data.fetch(:items)
    drafts = result.data.fetch(:transaction_drafts)
    assert_equal [ "Monthly dining budget" ], items.map { |item| item.fetch(:label) }
    assert_equal 1, drafts.length
    assert_equal "Penny Cafe", drafts.first.fetch(:merchant)
  ensure
    file&.close!
  end

  test "extractor uses structured spreadsheet path without OpenRouter key" do
    user = User.create!(clerk_id: "clerk_structured_extractor_user", email: "structured-extractor@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Structured Extractor Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "spreadsheet",
      status: "uploaded",
      filename: "budget.csv",
      content_type: "text/csv",
      byte_size: 100,
      s3_key: "household-cfo/test/budget.csv"
    )

    with_s3_download("type,label,amount,cadence,category,payment,notes\ndebt,Visa card,3400,monthly,credit_card,175,Minimum payment\n") do
      result = FinancialDocuments::Extractor.new(api_key: nil).call(document_import)

      assert result.success?, result.error
      assert_equal "structured_spreadsheet", result.metadata.fetch(:extraction_mode)
      assert_equal 1, result.data.fetch(:items).length
      assert_equal 175_00, result.data.fetch(:items).first.fetch(:payment_cents)
    end
  end

  test "credit-only bank CSV never falls through to AI extraction" do
    user = User.create!(clerk_id: "clerk_credit_only_extractor_user", email: "credits-only-extractor@example.com", role: "participant", invitation_status: "accepted")
    household = Household.create!(created_by_user: user, name: "Credit-only Statement Household")
    document_import = FinancialDocumentImport.create!(
      household: household,
      uploaded_by_user: user,
      document_kind: "statement",
      status: "uploaded",
      filename: "credits-only.csv",
      content_type: "text/csv",
      byte_size: 100,
      s3_key: "household-cfo/test/credits-only.csv"
    )

    with_s3_download("date,description,debit,credit,balance\n2026-08-01,Payroll,,2000,7000\n") do
      result = FinancialDocuments::Extractor.new(api_key: nil).call(document_import)

      assert result.success?, result.error
      assert_equal "structured_spreadsheet", result.metadata.fetch(:extraction_mode)
      assert_empty result.data.fetch(:transaction_drafts)
      assert_includes result.data.fetch(:warnings).join(" "), "Payroll"
    end
  end

  private

  def with_s3_download(contents)
    singleton = class << S3Service; self; end
    configured_original = singleton.instance_method(:configured?)
    download_original = singleton.instance_method(:download_to_io)
    singleton.define_method(:configured?) { true }
    singleton.define_method(:download_to_io) do |_key, io|
      io.write(contents)
      true
    end
    yield
  ensure
    singleton.send(:remove_method, :configured?) if singleton.method_defined?(:configured?)
    singleton.send(:remove_method, :download_to_io) if singleton.method_defined?(:download_to_io)
    singleton.define_method(:configured?, configured_original)
    singleton.define_method(:download_to_io, download_original)
  end
end
