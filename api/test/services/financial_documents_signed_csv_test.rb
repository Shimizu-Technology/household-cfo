require "test_helper"
require "csv"

class FinancialDocumentsSignedCsvTest < ActiveSupport::TestCase
  test "running balances prove the whole bank CSV without a model" do
    data = extract(csv)
    rows = data.fetch(:source_accounting).fetch(:events)
    assert_equal 15, rows.length
    assert_equal [ "posted" ], rows.pluck(:row_kind).uniq
    assert_equal 2, rows.count { |row| row[:signed_amount_cents].positive? }
    assert_equal 13, rows.count { |row| row[:signed_amount_cents].negative? }
    assert_equal CSV.parse(csv, headers: true).map { |row| (BigDecimal(row["Amount"]) * 100).to_i }, rows.pluck(:signed_amount_cents)
    assert_not rows.any? { |row| row[:limitations].include?("transaction_direction_unclear") }
    assert_equal 2, rows.count { |row| row[:event_type] == "debt_payment" }
    assert_equal 11, data[:transaction_drafts].length
    assert_not data[:source_accounting][:coverage][:signed_amount_question]
  end

  test "mixed signs without balance ask once and either answer rederives every row" do
    data = extract(without_balance)
    assert data[:source_accounting][:coverage][:signed_amount_question]
    assert_equal 15, data[:source_accounting][:events].count { |row| row[:limitations].include?("transaction_direction_unclear") }
    [ true, false ].each do |answer|
      resolved = extract(without_balance, negative_is_money_out: answer, account_basis: "asset")
      rows = resolved[:source_accounting][:events]
      assert_equal 15, rows.count { |row| row[:row_kind] == "posted" }
      assert_equal answer ? 2 : 13, rows.count { |row| row[:signed_amount_cents].positive? }
      assert_not resolved[:source_accounting][:coverage][:signed_amount_question]
      assert_equal "asset", resolved[:source_accounting][:accounts].sole[:account_basis]
    end
  end

  test "one wrong balance invalidates the file proof" do
    data = extract(csv.sub("1670.55", "1671.55"))
    assert data[:source_accounting][:coverage][:signed_amount_question]
    assert_empty data[:transaction_drafts]
  end

  test "debit credit conflicts and limits keep existing protection" do
    data = extract("Date,Description,Debit,Credit\n2026-10-01,Store,10,\n2026-10-02,Deposit,,20\n2026-10-03,Conflict,10,20\n2026-10-04,Too large,99999999,20\n")
    rows = data[:source_accounting][:events]
    assert_equal(-1000, rows.first[:signed_amount_cents])
    assert_equal 2000, rows.second[:signed_amount_cents]
    assert_includes rows.third[:limitations], "conflicting_debit_credit"
    assert_equal "unresolved", rows.last[:row_kind]
    assert_nil rows.last[:signed_amount_cents]
    assert_not data[:source_accounting][:coverage][:signed_amount_question]
  end

  test "file answer appends facts at once without approving spending or losing physical rows" do
    user = User.create!(clerk_id: "r7-f4-#{SecureRandom.hex(4)}", email: "r7-f4-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document = household.financial_document_imports.create!(uploaded_by_user: user, document_kind: "statement", status: "needs_review", filename: "bank.csv", content_type: "text/csv", byte_size: 100, s3_key: "fictional/r7-f4.csv")
    original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(without_balance)[:source_accounting], structured_spreadsheet: true).call[:revision]
    domain = FinancialDocuments::SourceReview::Domain.new(household, user: user)
    FinancialDocuments::SourceReview::LineApprover.new(domain, original, { lines: [], accounts: [ { source_account_id: original.financial_source_accounts.sole.id, account_basis: "asset" } ] }).call
    updated = ApplicationRecord.transaction { FinancialDocuments::SpreadsheetSignAnswer.call(original, negative_is_money_out: true, user: user) }
    assert_equal updated.id, document.reload.metadata["source_accounting_revision_id"]
    assert_equal 15, updated.financial_source_events.where(row_kind: "posted").count
    assert_equal original.financial_source_events.order(:position).pluck(:locator), updated.financial_source_events.order(:position).pluck(:locator)
    assert_equal [ "asset" ], updated.financial_source_accounts.pluck(:account_basis)
    assert_equal 1, SourceTrackedAccount.where(household: household).count
    old_identity = SourceAccountReviewHead.find_by!(financial_source_account: original.financial_source_accounts.sole).approved_version
    new_identity = SourceAccountReviewHead.find_by!(financial_source_account: updated.financial_source_accounts.sole).approved_version
    assert_equal old_identity.source_tracked_account_id, new_identity.source_tracked_account_id
    assert_empty household.household_transactions
    assert_equal 0, SourceReviewVersion.where(household: household).count
    assert_equal 11, document.transaction_drafts.pending.count
    assert_equal 15, original.financial_source_events.where(row_kind: "unresolved").count
    reply = HouseholdFinance::UploadReadReply.call(household, [ document ])
    assert_includes reply, "I read 15 lines from your statement."
    assert_match(/\d+ look right and \d+ need a look/, reply)
    assert_not_includes reply, "structured values"
    assert_includes reply, "Nothing counts in your spending until you approve it."
    assert_not_includes reply, "Nothing from this message was saved"
  end

  test "a file answer preserves pending rows and never stages incoming money transfers refunds or debt payments as expenses" do
    user = User.create!(clerk_id: "f4-protection-#{SecureRandom.hex(4)}", email: "f4-protection-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document = household.financial_document_imports.create!(uploaded_by_user: user, document_kind: "statement", status: "needs_review", filename: "bank.csv", content_type: "text/csv", byte_size: 100, s3_key: "fictional/f4-protected.csv")
    content = "Date,Description,Amount,Status\n2026-10-01,Pay,2600,posted\n2026-10-02,Store,-10,posted\n2026-10-03,Own transfer,-30,posted\n2026-10-04,Card payment,-40,posted\n2026-10-05,Store refund,5,posted\n2026-10-06,Not posted yet,-99,pending\n"
    original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(content, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    resolved = ApplicationRecord.transaction { FinancialDocuments::SpreadsheetSignAnswer.call(original, negative_is_money_out: true, user: user) }
    assert_equal 1, resolved.financial_source_events.where(row_kind: "informational").count
    assert_nil resolved.financial_source_events.order(:position).last.signed_amount_cents
    assert_equal [ "transfer", "debt_payment", "refund" ], resolved.financial_source_events.order(:position).to_a[2..4].map(&:event_type)
    assert_equal 1, document.transaction_drafts.pending.count
    assert_equal "Store", document.transaction_drafts.pending.sole.merchant
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(household, resolved)
    assert_equal [ :transfer, :card_payment, :refund ], plan.attention.filter_map { |line| line.kind if line.kind.in?([ :transfer, :card_payment, :refund ]) }
    assert_empty household.household_transactions
  end

  test "a proven sign never turns a row labelled as incoming into spending" do
    data = extract("Date,Description,Amount,Balance,Category\n2026-10-01,Deposit,100,200,Income\n2026-10-02,Refund,-10,190,Refund\n2026-10-03,Store,-5,185,Groceries\n")
    rows = data[:source_accounting][:events]
    assert_equal "income", rows.first[:event_type]
    assert_includes rows.second[:limitations], "conflicting_debit_credit"
    assert_equal "unresolved", rows.second[:row_kind]
    assert_equal [ "Store" ], data[:transaction_drafts].pluck(:merchant)
  end

  private

  def csv = File.read(Rails.root.join("test/fixtures/files/r7_bank_statement.csv"))
  def without_balance = CSV.generate { |out| CSV.parse(csv).each { |row| out << row.first(3) } }

  def extract(content, **options)
    file = Tempfile.new([ "r7-f4", ".csv" ])
    file.write(content)
    file.flush
    result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "bank.csv", document_kind: "statement", **options).call
    assert result.success?, result.error
    result.data
  ensure
    file&.close!
  end
end
