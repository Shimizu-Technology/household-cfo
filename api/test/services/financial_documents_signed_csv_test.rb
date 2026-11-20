require "test_helper"
require "csv"
require "spreadsheet"

class FinancialDocumentsSignedCsvTest < ActiveSupport::TestCase
  test "CSV cash withdrawals project spending and ATM fees stay fees" do
    descriptions = [ "Non-WF ATM Withdrawal authorized on 10/04 Tasi Demo S*····4410 Card 7302", "Branch withdrawal", "Cash withdrawal", "Withdrawal - Branch", "ATM Transaction Fee", "Non-WF ATM Fee" ]
    content = CSV.generate do |csv|
      csv << %w[Date Description Debit Credit]
      descriptions.each { |description| csv << [ "2026-10-04", description, "80.00", nil ] }
    end
    data = extract(content, account_basis: "asset")
    events = data[:source_accounting][:events]
    assert_equal %w[cash_withdrawal cash_withdrawal cash_withdrawal cash_withdrawal fee fee], events.pluck(:event_type)
    assert_equal [ 8000 ] * 6, events.pluck(:expense_amount_cents)
    assert_equal 48_000, data[:transaction_drafts].sum { |draft| draft[:total_amount_cents] }
  end

  test "a CSV with Merchant, Description and Type columns still reads an ATM withdrawal from its description" do
    content = CSV.generate do |csv|
      csv << %w[Date Description Merchant Type Debit Credit]
      csv << [ "2026-10-04", "ATM Withdrawal", "Tasi Demo Bank", "purchase", "80.00", nil ]
      csv << [ "2026-10-05", "ATM/POS Purchase", "Tasi Demo Market", "purchase", "45.00", nil ]
    end
    events = extract(content, account_basis: "asset")[:source_accounting][:events]
    assert_equal %w[cash_withdrawal purchase], events.pluck(:event_type)
  end

  test "running balances prove the whole bank CSV without a model" do
    data = extract(csv, account_basis: "asset")
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
    # The store purchase is not saved yet, so the refund asks which category it goes back to (filled in from that purchase).
    assert_equal [ :transfer, :card_payment, :refund_category ], plan.attention.filter_map { |line| line.kind if line.kind.in?([ :transfer, :card_payment, :refund, :refund_category ]) }
    assert_empty household.household_transactions
  end

  test "a proven sign never turns a row labelled as incoming into spending" do
    data = extract("Date,Description,Amount,Balance,Category\n2026-10-01,Deposit,100,200,Income\n2026-10-02,Refund,-10,190,Refund\n2026-10-03,Store,-5,185,Groceries\n", account_basis: "asset")
    rows = data[:source_accounting][:events]
    assert_equal "income", rows.first[:event_type]
    assert_includes rows.second[:limitations], "conflicting_debit_credit"
    assert_equal "unresolved", rows.second[:row_kind]
    assert_equal [ "Store" ], data[:transaction_drafts].pluck(:merchant)
  end

  test "a participant supplied incoming direction preserves a known transfer without staging spending" do
    user = User.create!(clerk_id: "f4-direction-#{SecureRandom.hex(4)}", email: "f4-direction-#{SecureRandom.hex(4)}@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document = household.financial_document_imports.create!(uploaded_by_user: user, document_kind: "statement", status: "needs_review", filename: "bank.csv", content_type: "text/csv", byte_size: 100, s3_key: "fictional/f4-direction.csv")
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract("Date,Description,Amount\n2026-10-01,Own transfer,-30\n", account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    event = revision.financial_source_events.sole
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(household, revision)
    assert_equal :direction, plan.attention.sole.kind
    domain = FinancialDocuments::SourceReview::Domain.new(household, user: user)
    input = { lines: [ { event_id: event.id, decision: "edited", edit: { kind: "moved", amount_cents: 3000, money_direction: "in", merchant: "Own transfer", posted_on: "2026-10-01" } } ] }
    FinancialDocuments::SourceReview::LineApprover.new(domain, revision, input).call
    version = SourceReviewHead.find_by!(financial_source_event: event).approved_version
    assert_equal "transfer", version.event_type
    assert_equal 3000, version.signed_amount_cents
    assert_empty household.household_transactions
  end

  test "separate worksheet accounts use individual directions even when each sheet has one sign" do
    file = Tempfile.new([ "f4-workbook", ".xls" ])
    workbook = Spreadsheet::Workbook.new
    [ [ "Spending", "-30" ], [ "Deposits", "40" ] ].each do |name, amount|
      sheet = workbook.create_worksheet(name: name)
      sheet.row(0).replace(%w[Date Description Amount])
      sheet.row(1).replace([ "2026-10-01", "Fictional row one", amount ])
      sheet.row(2).replace([ "2026-10-02", "Fictional row two", amount ])
    end
    workbook.write(file.path)
    original = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "bank.xls", document_kind: "statement").call
    assert original.success?, original.error
    assert_not original.data[:source_accounting][:coverage][:signed_amount_question]
    assert_equal 2, original.data[:source_accounting][:accounts].length
    assert_equal [ nil, nil, nil, nil ], original.data[:source_accounting][:events].pluck(:signed_amount_cents)
  ensure
    file&.close!
  end

  test "two running balance rows are not enough to prove direction" do
    rows = extract("Date,Description,Amount,Balance\n2026-10-01,Store one,-30,100\n2026-10-02,Store two,-20,80\n")[:source_accounting][:events]
    assert_equal [ "unresolved", "unresolved" ], rows.pluck(:row_kind)
    assert_equal [ nil, nil ], rows.pluck(:signed_amount_cents)
  end

  test "liability balance arithmetic handles both signs and both chronological orders" do
    [ 1, -1 ].each do |factor|
      rows = [ [ "2026-10-01", "Store", 126.42 * factor, 626.42 ], [ "2026-10-02", "Store two", 65 * factor, 691.42 ], [ "2026-10-03", "PAYMENT THANK YOU", -300 * factor, 391.42 ] ]
      [ rows, rows.reverse ].each do |ordered|
        content = CSV.generate { |out| out << %w[Date Description Amount Balance]; ordered.each { |row| out << row } }
        result = extract(content, account_basis: "liability")[:source_accounting]
        expected = ordered.map { |row| -(BigDecimal(row[2].to_s) * 100).round.to_i * factor }
        assert_equal expected, result[:events].pluck(:signed_amount_cents)
        assert_not result[:coverage][:signed_amount_question]
        unknown = extract(content)[:source_accounting]
        assert unknown[:coverage][:signed_amount_question]
        assert unknown[:events].all? { |event| event[:signed_amount_cents].nil? }
      end
    end
  end

  test "equal amounts and a single sign still ask while explicit directions do not" do
    result = extract("Date,Description,Amount,Balance\n2026-10-03,Store,10,130\n2026-10-02,Store,10,120\n2026-10-01,Store,10,110\n", account_basis: "liability")[:source_accounting]
    assert result[:coverage][:signed_amount_question]
    assert result[:events].all? { |event| event[:signed_amount_cents].nil? }
    assert extract("Date,Description,Amount\n2026-10-01,Store,10\n")[:source_accounting][:coverage][:signed_amount_question]
    explicit = extract("Date,Description,Amount,Direction\n2026-10-01,Store,-10,Debit\n2026-10-02,Pay,20,Credit\n")[:source_accounting]
    assert_not explicit[:coverage][:signed_amount_question]
    assert_equal [ -1000, 2000 ], explicit[:events].pluck(:signed_amount_cents)
  end

  test "two explicit accounts fall back to individual directions without a file block" do
    result = extract("Date,Description,Amount,Account,Account type\n2026-10-01,Store,10,Bank,asset\n2026-10-02,Card store,-20,Card,liability\n")[:source_accounting]
    assert_not result[:coverage][:signed_amount_question]
    assert_equal [ nil, nil ], result[:events].pluck(:signed_amount_cents)
    user, document = sign_document("two-accounts.csv")
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: result, structured_spreadsheet: true).call[:revision]
    event = revision.financial_source_events.order(:position).first
    domain = FinancialDocuments::SourceReview::Domain.new(document.household, user: user)
    FinancialDocuments::SourceReview::LineApprover.new(domain, revision, { lines: [ { event_id: event.id, decision: "edited", edit: { kind: "money_in", money_direction: "in", amount_cents: 1000, posted_on: "2026-10-01" } } ] }).call
    assert_equal 1000, SourceReviewHead.find_by!(financial_source_event: event).approved_version.signed_amount_cents
    assert_nil revision.financial_source_events.order(:position).last.signed_amount_cents
    assert_empty document.household.household_transactions
  end

  test "a workbook answer preserves debit credit and proven rows for either answer" do
    [ true, false ].each do |answer|
      file = Tempfile.new([ "mixed-workbook", ".xls" ])
      workbook = Spreadsheet::Workbook.new
      sheet = workbook.create_worksheet(name: "Explicit")
      sheet.row(0).replace(%w[Date Description Debit Credit Account])
      sheet.row(1).replace([ "2026-10-01", "Settled debit", "50", nil, "bank" ])
      sheet.row(2).replace([ "2026-10-02", "Settled credit", nil, "60", "bank" ])
      sheet = workbook.create_worksheet(name: "Signed")
      sheet.row(0).replace(%w[Date Description Amount Account])
      sheet.row(1).replace([ "2026-10-03", "Unclear", "-70", "bank" ])
      sheet = workbook.create_worksheet(name: "Proven")
      sheet.row(0).replace([ "Date", "Description", "Amount", "Balance", "Account", "Account type" ])
      sheet.row(1).replace([ "2026-10-04", "Known one", "100", "200", "bank", "asset" ])
      sheet.row(2).replace([ "2026-10-05", "Known two", "-20", "180", "bank", "asset" ])
      sheet.row(3).replace([ "2026-10-06", "Known three", "-30", "150", "bank", "asset" ])
      workbook.write(file.path)
      result = FinancialDocuments::StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "mixed.xls", document_kind: "statement", account_basis: "asset").call
      user, document = sign_document("mixed.xls")
      revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: result.data[:source_accounting], structured_spreadsheet: true).call[:revision]
      changed = FinancialDocuments::SpreadsheetSignAnswer.call(revision, negative_is_money_out: answer, user: user)
      assert_equal [ -5000, 6000, answer ? -7000 : 7000, 10000, -2000, -3000 ], changed.financial_source_events.order(:position).pluck(:signed_amount_cents)
      before = revision.financial_source_events.order(:position).first(2)
      after = changed.financial_source_events.order(:position).first(2)
      assert_equal before.map { |event| [ event.event_type, event.limitations, event.locator, event.financial_source_evidence.payload ] }, after.map { |event| [ event.event_type, event.limitations, event.locator, event.financial_source_evidence.payload ] }
      file.close!
    end
  end

  test "checksum import can change its answer then load and approve without self overlaps" do
    user, document = sign_document("bank.csv")
    accounting = extract(without_balance, account_basis: "asset")[:source_accounting]
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: accounting, structured_spreadsheet: true).call[:revision]
    yes = FinancialDocuments::SpreadsheetSignAnswer.call(revision, negative_is_money_out: true, user: user)
    no = FinancialDocuments::SpreadsheetSignAnswer.call(yes, negative_is_money_out: false, user: user)
    assert_equal(-yes.financial_source_events.order(:position).first.signed_amount_cents, no.financial_source_events.order(:position).first.signed_amount_cents)
    assert_equal 2, document.reload.metadata["signed_amount_answers"].length
    assert document.metadata["signed_amount_answers"].all? { |answer| answer["user_id"] == user.id && answer["answered_at"].present? }
    document.update!(metadata: document.metadata.merge("warnings" => [ "You described this as bank statement, but I detected credit card statement." ]))
    approve_income(user, document, no)
    reply = HouseholdFinance::UploadReadReply.call(document.household, [ document ])
    assert_includes reply, "You already reviewed 1 line"
    assert_includes reply, "You described this as"
    assert_not_includes reply, "Nothing counts in your spending until you approve it."
    assert_raises(ArgumentError) { FinancialDocuments::SpreadsheetSignAnswer.call(no, negative_is_money_out: true, user: user) }
  end

  test "reprocessing the same checksum does not create self overlaps" do
    user, document = sign_document("bank.csv")
    accounting = extract(csv, account_basis: "asset")[:source_accounting]
    2.times { FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: accounting, structured_spreadsheet: true).call }
    revision = document.financial_extraction_revisions.order(:revision_number).last
    approve_income(user, document, revision)
  end

  test "an unknown line cannot be saved without a deliberate direction" do
    user, document = sign_document("bank.csv")
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract("Date,Description,Amount\n2026-10-01,Unknown,50\n", account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    domain = FinancialDocuments::SourceReview::Domain.new(document.household, user: user)
    %w[spending moved card].each do |kind|
      error = assert_raises(ArgumentError) do
        FinancialDocuments::SourceReview::LineApprover.new(domain, revision, { lines: [ { event_id: revision.financial_source_events.sole.id, decision: "edited", edit: { kind: kind, amount_cents: 5000, posted_on: "2026-10-01" } } ] }).call
      end
      assert_includes error.message, "money out or money in"
    end
    assert_empty document.household.household_transactions
  end

  test "read replies distinguish empty and already reviewed statements" do
    user, document = sign_document("bank.csv")
    empty = { contract_version: FinancialDocuments::AccountingContract::VERSION, accounts: [], events: [], coverage: {} }
    FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: empty, structured_spreadsheet: true).call
    reply = HouseholdFinance::UploadReadReply.call(document.household, [ document ])
    assert_includes reply, "There are no lines to approve."
    assert_not_includes reply, "card below is waiting"
    accounting = extract("Date,Description,Amount,Direction\n2026-10-01,Pay,50,Credit\n", account_basis: "asset")[:source_accounting]
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: accounting, structured_spreadsheet: true).call[:revision]
    approve_income(user, document, revision)
    reply = HouseholdFinance::UploadReadReply.call(document.household, [ document ])
    assert_includes reply, "You already reviewed every line."
    assert_not_includes reply, "card below is waiting"
    assert_not_includes reply, "Nothing counts in your spending until you approve it."
  end

  test "latest revision filtering excludes deleted unapproved imports and retains approved history" do
    user, first = sign_document("first.csv")
    second = first.dup
    second.s3_key = "fictional/fix1-retained-#{SecureRandom.hex(6)}"
    second.save!
    accounting = extract("Date,Description,Amount,Direction\n2026-10-01,Pay,50,Credit\n", account_basis: "asset")[:source_accounting]
    FinancialDocuments::SourceAccountingPersister.new(first, attempt: nil, accounting: accounting).call
    first_latest = FinancialDocuments::SourceAccountingPersister.new(first, attempt: nil, accounting: accounting).call[:revision]
    approve_income(user, first, first_latest)
    second_latest = FinancialDocuments::SourceAccountingPersister.new(second, attempt: nil, accounting: accounting).call[:revision]
    expected = [ first_latest.financial_source_events.sole.id, second_latest.financial_source_events.sole.id ].sort
    context = FinancialDocuments::SourceReview::OverlapDetector::Context.new(first.household)
    facts = { signed_amount_cents: 5000, posted_on: "2026-10-01" }
    assert_equal expected, context.candidates(facts, nil, nil).map(&:id).sort
    first.destroy!
    second.destroy!
    retained = FinancialDocuments::SourceReview::OverlapDetector::Context.new(first.household)
    assert_equal [ first_latest.financial_source_events.sole.id ], retained.candidates(facts, nil, nil).map(&:id)
  end

  test "negative card balances prove both amount conventions" do
    [ 1, -1 ].each do |factor|
      content = "Date,Description,Amount,Balance\n2026-10-01,Store,#{126.42 * factor},-626.42\n2026-10-02,Store two,#{65 * factor},-691.42\n2026-10-03,Payment,#{-300 * factor},-391.42\n"
      result = extract(content, account_basis: "liability")[:source_accounting]
      assert_equal [ -12642, -6500, 30000 ], result[:events].pluck(:signed_amount_cents)
      assert_not result[:coverage][:signed_amount_question]
    end
  end

  test "a liability balance crossing zero cannot prove a convention" do
    result = extract("Date,Description,Amount,Balance\n2026-10-01,Store,10,-20\n2026-10-02,Store two,30,10\n2026-10-03,Payment,-5,5\n", account_basis: "liability")[:source_accounting]
    assert result[:coverage][:signed_amount_question]
    assert_equal [ nil, nil, nil ], result[:events].pluck(:signed_amount_cents)
  end

  test "unrecognized types and categories do not establish a mixed sign convention" do
    content = "Date,Description,Amount,Type,Category\n2026-10-01,PAYROLL DEPOSIT,2600,POS,Paycheck\n2026-10-02,Store,-10,DEBIT_CARD,Groceries\n2026-10-03,Other,-20,CHECK,Shopping\n"
    result = extract(content, account_basis: "asset")[:source_accounting]
    assert result[:coverage][:signed_amount_question]
    assert_equal [ nil, nil, nil ], result[:events].pluck(:signed_amount_cents)
    assert_equal [ 260000, -1000, -2000 ], extract(content, account_basis: "asset", negative_is_money_out: true)[:source_accounting][:events].pluck(:signed_amount_cents)
  end

  test "one sign offers all out all in or individual questions without approving anything" do
    %w[all_out all_in individual].each do |choice|
      user, document = sign_document("one-sign.csv")
      original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract("Date,Description,Amount\n2026-10-01,Store,10\n2026-10-02,Paycheck,20\n", account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
      assert original.coverage["signed_amount_single_sign"]
      changed = FinancialDocuments::SpreadsheetSignAnswer.call(original, negative_is_money_out: choice, user: user)
      expected = { "all_out" => [ -1000, -2000 ], "all_in" => [ 1000, 2000 ], "individual" => [ nil, nil ] }.fetch(choice)
      assert_equal expected, changed.financial_source_events.order(:position).pluck(:signed_amount_cents)
      plan = FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, changed, user: user).plan_summary
      assert_not plan[:signed_amount_question]
      assert_empty document.household.household_transactions
    end
  end

  test "all out reads the sign from a row that has an amount, not from a blank or unreadable first row" do
    [ "0.00", "bad1" ].each do |first_amount|
      { "all_out" => [ -1000, -2000 ], "all_in" => [ 1000, 2000 ] }.each do |choice, expected|
        user, document = sign_document("first-row-#{first_amount}.csv")
        original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract("Date,Description,Amount\n2026-10-01,Opening entry,#{first_amount}\n2026-10-02,Store,-10\n2026-10-03,Shop,-20\n", account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
        assert original.coverage["signed_amount_single_sign"]
        changed = FinancialDocuments::SpreadsheetSignAnswer.call(original, negative_is_money_out: choice, user: user)
        assert_equal expected, changed.financial_source_events.order(:position).pluck(:signed_amount_cents).compact
      end
    end
  end

  test "not sure withdraws the mixed sign question and shows individual questions" do
    user, document = sign_document("mixed.csv")
    original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(without_balance, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    changed = FinancialDocuments::SpreadsheetSignAnswer.call(original, negative_is_money_out: "individual", user: user)
    plan = FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, changed, user: user).plan_summary
    assert_not plan[:signed_amount_question]
    assert plan[:signed_amount_answerable]
    assert_equal 15, changed.financial_source_events.where(signed_amount_cents: nil).count
  end

  test "individual answer can be replaced until a line is saved, recording both answers" do
    user, document = sign_document("change-individual.csv")
    original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(without_balance, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    individual = FinancialDocuments::SpreadsheetSignAnswer.call(original, negative_is_money_out: "individual", user: user)
    changed = FinancialDocuments::SpreadsheetSignAnswer.call(individual, negative_is_money_out: true, user: user)
    assert_equal [ "individual", true ], document.reload.metadata["signed_amount_answers"].pluck("choice")
    assert_equal 15, changed.financial_source_events.where.not(signed_amount_cents: nil).count

    individual = FinancialDocuments::SpreadsheetSignAnswer.call(changed, negative_is_money_out: "individual", user: user)
    event = individual.financial_source_events.order(:position).first
    domain = FinancialDocuments::SourceReview::Domain.new(document.household, user: user)
    FinancialDocuments::SourceReview::LineApprover.new(domain, individual, { lines: [ { event_id: event.id, decision: "leave_out" } ] }).call
    assert_not FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, individual, user: user).plan_summary[:signed_amount_answerable]
    assert_raises(ArgumentError) { FinancialDocuments::SpreadsheetSignAnswer.call(individual, negative_is_money_out: true, user: user) }
  end

  test "ATM deposits are income while outgoing and unresolved ATM rows keep their kind" do
    data = extract("Date,Description,Debit,Credit\n2026-10-01,ATM DEPOSIT,,100\n2026-10-02,ATM,20,\n", account_basis: "asset")
    assert_equal [ "income", "cash_withdrawal" ], data[:source_accounting][:events].pluck(:event_type)
    unresolved = extract("Date,Description,Amount\n2026-10-01,ATM,20\n", account_basis: "asset")
    assert_equal "cash_withdrawal", unresolved[:source_accounting][:events].first[:event_type]
  end

  test "saving a line or removing the original withdraws the file question" do
    user, document = sign_document("mixed.csv")
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(without_balance, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, revision, user: user)
    assert presenter.plan_summary[:signed_amount_question]
    event = revision.financial_source_events.order(:position).first
    domain = FinancialDocuments::SourceReview::Domain.new(document.household, user: user)
    FinancialDocuments::SourceReview::LineApprover.new(domain, revision, { lines: [ { event_id: event.id, decision: "leave_out" } ] }).call
    assert_not presenter.plan_summary[:signed_amount_question]
    assert presenter.plan_summary[:attention].any?
    remaining = revision.financial_source_events.where.not(id: event.id).map { |line| { event_id: line.id, decision: "leave_out" } }
    result = FinancialDocuments::SourceReview::LineApprover.new(domain, revision, { lines: remaining, coverage_answer: "nothing_missing" }).call
    assert result[:complete]
    user, document = sign_document("removed.csv")
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(without_balance, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    document.update!(source_deleted_at: Time.current)
    assert_not FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, revision, user: user).plan_summary[:signed_amount_question]
  end

  test "derived history names balance evidence and counts only affected lines" do
    user, document = sign_document("card.csv")
    content = "Date,Description,Amount,Balance\n2026-10-01,Store,126.42,-626.42\n2026-10-02,Store two,65,-691.42\n2026-10-03,Payment,-300,-391.42\n"
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(content)[:source_accounting], structured_spreadsheet: true).call[:revision]
    account = revision.financial_source_accounts.sole
    domain = FinancialDocuments::SourceReview::Domain.new(document.household, user: user)
    FinancialDocuments::SourceReview::LineApprover.new(domain, revision, { lines: [], accounts: [ { source_account_id: account.id, account_basis: "liability" } ] }).call
    changed = FinancialDocuments::SpreadsheetSignAnswer.call(revision, negative_is_money_out: nil, user: user)
    assert_equal [ -12642, -6500, 30000 ], changed.financial_source_events.order(:position).pluck(:signed_amount_cents)
    assert_equal "balance", document.reload.metadata.dig("signed_amount_answer", "source")
    effect = FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, changed).plan_summary[:sign_effect]
    assert_equal "The balance column shows spending as positive. That set the direction of 3 lines.", effect
  end

  test "mixed sign categories never silently override the convention" do
    content = "Date,Description,Amount,Category\n2026-10-01,PAYROLL DEPOSIT,2600,Paycheck\n2026-10-02,Store,-10,Groceries\n"
    original = extract(content, account_basis: "asset")[:source_accounting]
    assert_equal [ nil, nil ], original[:events].pluck(:signed_amount_cents)
    [ true, false ].each do |answer|
      rows = extract(content, account_basis: "asset", negative_is_money_out: answer)[:source_accounting][:events]
      if answer
        assert_equal 260000, rows.first[:signed_amount_cents]
      else
        assert_nil rows.first[:signed_amount_cents]
        assert_includes rows.first[:limitations], "conflicting_debit_credit"
      end
    end
  end

  test "answer effects count only the lines set and use singular and plural" do
    [ 1, 2 ].each do |count|
      user, document = sign_document("effect.csv")
      content = "Date,Description,Amount,Direction\n2026-10-01,Known,50,Credit\n" + count.times.map { |index| "2026-10-0#{index + 2},Store,-10,POS\n" }.join
      original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(content, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
      changed = FinancialDocuments::SpreadsheetSignAnswer.call(original, negative_is_money_out: true, user: user)
      effect = FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, changed).plan_summary[:sign_effect]
      assert_equal "You said spending is shown as negative. That set the direction of #{count} #{count == 1 ? 'line' : 'lines'}.", effect
    end
  end

  test "a saved decision keeps the file question withdrawn after an account edit makes it stale" do
    user, document = sign_document("stale-saved.csv")
    original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(without_balance, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    domain = FinancialDocuments::SourceReview::Domain.new(document.household, user: user)
    event = original.financial_source_events.order(:position).first
    FinancialDocuments::SourceReview::LineApprover.new(domain, original, { lines: [ { event_id: event.id, decision: "leave_out" } ] }).call
    FinancialDocuments::SourceReview::LineApprover.new(domain, original, { lines: [], accounts: [ { source_account_id: event.financial_source_account_id, account_basis: "asset", period_start_on: "2026-09-30" } ] }).call
    plan = FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, original, user: user).plan_summary
    assert_equal 0, plan[:done], "the saved decision is stale under the new account identity"
    assert_not plan[:signed_amount_question]
    assert_not plan[:signed_amount_answerable]
    assert plan[:attention].any?
    assert_raises(ArgumentError) { FinancialDocuments::SpreadsheetSignAnswer.call(original, negative_is_money_out: true, user: user) }
  end

  test "a derived effect for one line excludes recognized directions" do
    user, document = sign_document("derived-one.csv")
    content = "Date,Description,Amount,Balance,Direction\n2026-10-01,Pay,100,1000,Credit\n2026-10-02,Known shop,-10,990,Debit\n2026-10-03,Other shop,-20,970,POS\n"
    original = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(content, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    plan = FinancialDocuments::SourceReview::ParticipantPresenter.new(document.household, original, user: user).plan_summary
    assert_equal "The balance column shows spending as negative. That set the direction of 1 line.", plan[:sign_effect]
    assert_not plan[:signed_amount_question]
  end

  private

  test "a multi-account file asks money in or out once per account and applies each answer to that account only" do
    user, document = sign_document("talun-accounts.csv")
    household = document.household
    { "Groceries" => 0, "dining" => 1, "Utility" => 2 }.each { |name, index| household.budget_categories.create!(name: name, stack_key: "discretionary", sort_order: index) }
    categories = household.budget_categories.count
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(multi_account_csv)[:source_accounting], structured_spreadsheet: true).call[:revision]
    assert_not revision.coverage["signed_amount_question"]
    assert revision.financial_source_events.all? { |event| event.signed_amount_cents.nil? }
    link_accounts(user, revision, "Talun card" => "liability")
    questions = FinancialDocuments::SpreadsheetSignAnswer.account_questions(revision)
    assert_equal [ "Talun checking", "Talun card", "Talun savings" ], questions.map { |question| question[:account].financial_source_evidence.payload["label"] }
    assert_equal [ false, false, true ], questions.pluck(:single_sign)
    summary = FinancialDocuments::SourceReview::ParticipantPresenter.new(household, revision, user: user).plan_summary
    assert summary[:signed_amount_question], "lines wait until every account is answered"
    assert_equal [ nil, nil, nil ], summary[:account_sign_questions].pluck(:choice)
    checking, card, savings = questions.map { |question| question[:account] }
    answered = FinancialDocuments::SpreadsheetSignAnswer.call(revision, negative_is_money_out: true, user: user, source_account_id: checking.id)
    by_label = ->(rev, label) { rev.financial_source_events.joins(:financial_source_account).order(:position).select { |event| event.financial_source_account.financial_source_evidence.payload["label"] == label } }
    assert_equal [ 210_000, -10_379, -1_850, -4_200 ], by_label.(answered, "Talun checking").map(&:signed_amount_cents)
    assert by_label.(answered, "Talun card").all? { |event| event.signed_amount_cents.nil? && event.limitations.include?("transaction_direction_unclear") }
    assert_equal 0, SourceReviewVersion.where(household: household).count
    summary = FinancialDocuments::SourceReview::ParticipantPresenter.new(household, answered, user: user).plan_summary
    assert summary[:signed_amount_question]
    assert_equal "You said spending in Talun checking is shown as negative. That set the direction of 4 lines.", summary[:account_sign_questions].first[:effect]
    card_id = answered.financial_source_accounts.find_by!(source_key: card.source_key).id
    error = assert_raises(ArgumentError) { FinancialDocuments::SpreadsheetSignAnswer.call(answered, negative_is_money_out: "all_out", user: user, source_account_id: card_id) }
    assert_includes error.message, "both signs"
    answered = FinancialDocuments::SpreadsheetSignAnswer.call(answered, negative_is_money_out: false, user: user, source_account_id: card_id)
    assert_equal [ -6_720, 25_000 ], by_label.(answered, "Talun card").map(&:signed_amount_cents)
    answered = FinancialDocuments::SpreadsheetSignAnswer.call(answered, negative_is_money_out: "all_in", user: user, source_account_id: answered.financial_source_accounts.find_by!(source_key: savings.source_key).id)
    assert_equal [ 20_000, 2_500 ], by_label.(answered, "Talun savings").map(&:signed_amount_cents)
    assert_equal [ 210_000, -10_379, -1_850, -4_200 ], by_label.(answered, "Talun checking").map(&:signed_amount_cents), "a later account's answer leaves earlier accounts as they were"
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(household, answered)
    assert_empty plan.lines.select { |line| line.kind == :direction }
    # The file's own category is offered when it names one of her categories (exact, any case, or singular and plural); nothing else is invented.
    suggested = plan.lines.select { |line| FinancialDocuments::SourceReview::ParticipantPlan.expense?(line.event) }.to_h { |line| [ line.merchant, household.budget_categories.find_by(id: line.category_id)&.name ] }
    assert_equal({ "Tasi Demo Market" => "Groceries", "Tasi Demo Power" => "Utility", "Tasi Demo Toys" => nil, "Tasi Demo Dining Room" => "dining" }, suggested)
    assert_equal categories, household.budget_categories.count
    summary = FinancialDocuments::SourceReview::ParticipantPresenter.new(household, answered, user: user).plan_summary
    assert_not summary[:signed_amount_question]
    assert_equal [ true, false, "all_in" ], summary[:account_sign_questions].pluck(:choice)
    assert_equal 3, document.reload.metadata["signed_amount_answers"].length
    assert_empty household.household_transactions
  end

  test "an account she is not sure about keeps its line questions and an approved line closes every account question" do
    user, document = sign_document("talun-accounts.csv")
    household = document.household
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(multi_account_csv)[:source_accounting], structured_spreadsheet: true).call[:revision]
    error = assert_raises(ArgumentError) { FinancialDocuments::SpreadsheetSignAnswer.call(revision, negative_is_money_out: true, user: user, source_account_id: revision.financial_source_accounts.first.id) }
    assert_includes error.message, "bank account or a credit card"
    link_accounts(user, revision, "Talun card" => "liability")
    checking = FinancialDocuments::SpreadsheetSignAnswer.account_questions(revision).first[:account]
    assert_raises(ArgumentError) { FinancialDocuments::SpreadsheetSignAnswer.call(revision, negative_is_money_out: nil, user: user, source_account_id: checking.id) }
    unsure = FinancialDocuments::SpreadsheetSignAnswer.call(revision, negative_is_money_out: "individual", user: user, source_account_id: checking.id)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(household, unsure)
    assert_equal 4, plan.lines.count { |line| line.kind == :direction && line.event.financial_source_account.source_key == checking.source_key }
    summary = FinancialDocuments::SourceReview::ParticipantPresenter.new(household, unsure, user: user).plan_summary
    assert_equal "You chose to answer money out or money in for each line in Talun checking.", summary[:account_sign_questions].first[:effect]
    # She can still change it while nothing is approved: her answer reads the file's own amounts again.
    changed = FinancialDocuments::SpreadsheetSignAnswer.call(unsure, negative_is_money_out: true, user: user, source_account_id: unsure.financial_source_accounts.find_by!(source_key: checking.source_key).id)
    assert_equal [ 210_000, -10_379, -1_850, -4_200 ], changed.financial_source_events.order(:position).first(4).map(&:signed_amount_cents)
    domain = FinancialDocuments::SourceReview::Domain.new(household, user: user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(household, changed).lines.find { |row| row.event.signed_amount_cents == 210_000 }
    FinancialDocuments::SourceReview::LineApprover.new(domain, changed, { lines: [ { event_id: line.event.id, decision: "as_read", shown: { event_type: line.event.event_type, category_id: line.category_id } } ] }).call
    card = changed.financial_source_accounts.find { |account| account.financial_source_evidence.payload["label"] == "Talun card" }
    assert_raises(ArgumentError) { FinancialDocuments::SpreadsheetSignAnswer.call(changed, negative_is_money_out: true, user: user, source_account_id: card.id) }
    summary = FinancialDocuments::SourceReview::ParticipantPresenter.new(household, changed, user: user).plan_summary
    assert_not summary[:signed_amount_question]
    assert_equal [ [ true, false ] ], summary[:account_sign_questions].map { |question| [ question[:choice], question[:answerable] ] }, "her answer stays readable; unanswered accounts fall back to line questions"
  end

  test "a balance-proven or labelled account takes no account answer" do
    content = "Date,Account,Description,Amount,Balance,Direction\n2026-10-01,Proven,Pay,100,200,\n2026-10-02,Proven,Store,-20,180,\n2026-10-03,Proven,Store two,-30,150,\n" \
      "2026-10-04,Labelled,Refund,15,,Credit\n2026-10-05,Unclear,Store,-12,,\n2026-10-06,Unclear,Pay,40,,\n"
    user, document = sign_document("mixed-accounts.csv")
    revision = FinancialDocuments::SourceAccountingPersister.new(document, attempt: nil, accounting: extract(content, account_basis: "asset")[:source_accounting], structured_spreadsheet: true).call[:revision]
    link_accounts(user, revision)
    questions = FinancialDocuments::SpreadsheetSignAnswer.account_questions(revision)
    assert_equal [ "Unclear" ], questions.map { |question| question[:account].financial_source_evidence.payload["label"] }
    answered = FinancialDocuments::SpreadsheetSignAnswer.call(revision, negative_is_money_out: false, user: user, source_account_id: questions.sole[:account].id)
    assert_equal [ 10_000, -2_000, -3_000, 1_500, 1_200, -4_000 ], answered.financial_source_events.order(:position).pluck(:signed_amount_cents)
    proven = FinancialDocuments::SpreadsheetSignAnswer.account_questions(answered).map { |question| question[:account].id }
    assert_equal 1, proven.length
  end

  test "card interest in the category column does not contradict a known sign" do
    rows = extract("Date,Description,Amount,Category\n2026-10-01,Purchase interest charge,-21.75,Interest\n2026-10-02,Store,-5,Groceries\n", account_basis: "liability", negative_is_money_out: true)[:source_accounting][:events]
    assert_equal [ -2_175, -500 ], rows.pluck(:signed_amount_cents)
    assert_equal %w[posted posted], rows.pluck(:row_kind)
    assert_equal "interest", rows.first[:event_type]
  end

  def multi_account_csv
    <<~CSV
      Date,Account,Description,Amount,Category
      2026-01-01,Talun checking,Lina DEMO payroll,2100.00,Income
      2026-01-04,Talun checking,Tasi Demo Market,-103.79,groceries
      2026-01-06,Talun checking,Tasi Demo Power,-18.50,Utilities
      2026-01-07,Talun checking,Tasi Demo Toys,-42.00,Toys
      2026-01-14,Talun card,Tasi Demo Dining Room,67.20,Dining
      2026-01-20,Talun card,Payment received from Talun checking,-250.00,Transfer
      2026-01-09,Talun savings,Online Transfer from own checking DEMO,200.00,Transfer
      2026-01-31,Talun savings,Savings interest,25.00,Interest
    CSV
  end

  def link_accounts(user, revision, bases = {})
    domain = FinancialDocuments::SourceReview::Domain.new(revision.financial_document_import.household, user: user)
    accounts = revision.financial_source_accounts.map { |account| { source_account_id: account.id, account_basis: bases.fetch(account.financial_source_evidence.payload["label"], "asset") } }
    FinancialDocuments::SourceReview::LineApprover.new(domain, revision, { lines: [], accounts: accounts }).call
  end

  def sign_document(filename)
    user = User.create!(clerk_id: "fix1-#{SecureRandom.hex(5)}", email: "fix1-#{SecureRandom.hex(5)}@example.com", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    document = household.financial_document_imports.create!(uploaded_by_user: user, document_kind: "statement", status: "needs_review", filename: filename,
      content_type: "text/csv", byte_size: 100, s3_key: "fictional/fix1-#{SecureRandom.hex(6)}", checksum_sha256: "a" * 64)
    [ user, document ]
  end

  def approve_income(user, document, revision)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(document.household, revision)
    assert plan.lines.all? { |line| line.overlaps.empty? }
    line = plan.lines.find { |row| row.event.event_type == "income" }
    assert line.ready?
    domain = FinancialDocuments::SourceReview::Domain.new(document.household, user: user)
    FinancialDocuments::SourceReview::LineApprover.new(domain, revision, { lines: [ { event_id: line.event.id, decision: "as_read", shown: { event_type: line.event.event_type, category_id: line.category_id } } ] }).call
    assert SourceReviewHead.find_by!(financial_source_event: line.event).approved_version
  end

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

  test "a spreadsheet transfer or card payment that mentions a fee keeps its own type" do
    extractor = FinancialDocuments::StructuredSpreadsheetExtractor.allocate
    assert_equal "transfer", extractor.send(:source_event_type, [], {}, "Online Transfer to Savings service charge", -5_000)
    assert_equal "debt_payment", extractor.send(:source_event_type, [], {}, "Visa payment incl late fee", -31_000)
    assert_equal "fee", extractor.send(:source_event_type, [], {}, "Branch Withdrawal Service Charge", -300)
    # A "Type: purchase" column can't turn an explicit ATM withdrawal into a purchase.
    assert_equal "cash_withdrawal", extractor.send(:source_event_type, [ "purchase" ], { "type" => 0 }, "ATM Withdrawal", -8_000)
    assert_equal "purchase", extractor.send(:source_event_type, [], {}, "ATM/POS Purchase Walmart", -4_500)
    # Both a Merchant and a Description column: the description still counts.
    assert_equal "cash_withdrawal", extractor.send(:source_event_type, [ "purchase", "ATM Withdrawal" ], { "type" => 0, "label" => 1 }, "Tasi Demo Bank", -8_000)
  end
end
