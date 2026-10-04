require_relative "savings_daily_test_support"

module SavingsEvidenceTestSupport
  include SavingsDailyTestSupport

  def with_evidence_operations
    registry = HouseholdFinance::Operations::Registry
    original = registry.method(:operations)
    classes = [ HouseholdFinance::Operations::Savings::Evidence::Attach, HouseholdFinance::Operations::Savings::Evidence::Revoke ]
    with_daily_operations do
      daily_registry = registry.method(:operations)
      registry.define_singleton_method(:operations) { daily_registry.call.merge(classes.index_by { |klass| klass::KEY }) }
      yield
    end
  ensure
    registry.define_singleton_method(:operations, original) if original
  end

  def evidence_source(amount = 20_000, type: "income", on: @savings_enrollment.local_today, tracked: nil)
    import = FinancialDocumentImport.create!(household: @savings_household, uploaded_by_user: @savings_user, document_kind: "statement", status: "needs_review", filename: "synthetic-evidence.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: SecureRandom.hex(32))
    attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic", account_basis: "asset", period_start_on: on.beginning_of_month.iso8601, period_end_on: on.end_of_month.iso8601,
        opening_balance_cents: 100_000, closing_balance_cents: 100_000 + amount, printed_debit_cents: [ -amount, 0 ].max, printed_credit_cents: [ amount, 0 ].max, printed_row_count: 1 } ],
      events: [ { account_key: "synthetic", row_kind: "posted", event_type: type, signed_amount_cents: amount, posted_on: on.iso8601, merchant: "Synthetic evidence", locator: { page: 1, row: 1 } } ], reported_row_count: 1 }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    source = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: accounting).call
    account = source[:revision].financial_source_accounts.sole
    identity = source_operation(HouseholdFinance::Operations::SourceReview::AccountLink, source_account_id: account.id, account_basis: "asset", label: "Synthetic reserve account", tracked_account_id: tracked&.id,
      base_version_id: nil, base_lock_version: 0, statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Reviewed synthetic header")
    version = evidence_source_review(source[:events].sole, identity: identity, amount: amount, type: type, on: on)
    [ version, import ]
  end

  def evidence_source_review(event, identity:, amount:, type:, on:, disposition: "include", matched: nil)
    head = SourceReviewHead.find_by(financial_source_event: event)
    draft = source_operation(HouseholdFinance::Operations::SourceReview::DraftStage, event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0,
      reason: "Reviewed synthetic facts", projection: { action: "none" }, facts: { source_account_identity_version_id: identity.id,
        disposition: disposition, event_type: type, signed_amount_cents: amount, purchase_amount_cents: nil, posted_on: on.iso8601,
        merchant: "Synthetic evidence", overlap_disposition: matched ? "match" : "distinct", matched_version_id: matched&.id })
    source_operation(HouseholdFinance::Operations::SourceReview::DraftApprove, draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest)
  end

  def source_operation(klass, input)
    operation = klass.new(@savings_household, user: @savings_user)
    ApplicationRecord.transaction do
      @savings_household.lock!
      prepared = operation.prepare(input)
      operation.execute!(prepared, source: "manual")
    end
  end

  def evidence_group(debit, credit, amount: credit.signed_amount_cents)
    source_operation(HouseholdFinance::Operations::SourceReview::EconomicLink, kind: "transfer", base_version_id: nil, base_lock_version: 0,
      reason: "Reviewed synthetic transfer", members: [ debit, credit ].map { |row| { source_review_version_id: row.id, role: "movement", allocation_cents: amount } })
  end

  def evidence_proof(source, amount:, group: nil)
    { source_review_version_id: source.id, expected_source_digest: source.digest, expected_account_identity_digest: source.source_account_identity_version.digest,
      amount_cents: amount, economic_group_version_id: group&.id, expected_group_digest: group&.digest }
  end

  def evidence_input(entry, proofs)
    head = SavingsEvidenceAllocation.find_by(savings_entry_version: entry)
    { entry_version_id: entry.id, expected_evidence_version_id: head&.current_version_id, expected_head_lock_version: head&.lock_version || 0,
      accepted: true, participant_ownership_accepted: true, new_money_reservation_accepted: true, proofs: proofs, reason: "I reviewed ownership and new money reserved" }
  end

  def evidence_attach(entry, proofs, token: SecureRandom.uuid)
    savings_run("evidence.attach", evidence_input(entry, proofs), token: token)
  end

  def evidence_revoke(version)
    head = version.savings_evidence_allocation.reload
    savings_run("evidence.revoke", { entry_version_id: head.savings_entry_version_id, expected_evidence_version_id: head.current_version_id,
      expected_head_lock_version: head.lock_version, accepted: true, reason: "Withdraw this reviewed evidence allocation" })
  end
end
