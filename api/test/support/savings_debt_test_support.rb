require_relative "savings_evidence_test_support"

module SavingsDebtTestSupport
  include SavingsEvidenceTestSupport

  def debt_terms(**changes)
    { label: "Synthetic reviewed card", as_of_on: "2026-11-01", balance_cents: 30_000, minimum_payment_cents: nil, apr_bps: nil }.merge(changes)
  end

  def debt_stage(terms = debt_terms, card: nil, source: nil, token: SecureRandom.uuid)
    card&.reload
    savings_run("debt.stage", { card_id: card&.id, terms: terms, source_mapping: source,
      expected_version_id: card&.current_version_id, expected_head_lock_version: card&.lock_version || 0,
      reason: card&.current_version_id ? "Reviewed correction of card terms" : "" }, token: token).subject
  end

  def debt_approval_input(draft)
    { draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version,
      expected_version_id: draft.base_version_id, expected_head_lock_version: draft.base_head_lock_version }
  end

  def debt_approve(draft, token: SecureRandom.uuid)
    savings_run("debt.approve", debt_approval_input(draft), token: token).subject
  end

  def debt_read = SavingsChallenge::Debt::Reader.new(@savings_enrollment.reload, user: @savings_user).call

  def debt_source(on: Date.new(2026, 10, 31), tracked: nil, basis: "liability")
    import = FinancialDocumentImport.create!(household: @savings_household, uploaded_by_user: @savings_user, document_kind: "statement", status: "needs_review", filename: "synthetic-card.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: SecureRandom.hex(32))
    attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
    account_basis = basis
    opening = basis == "liability" ? 20_000 : 40_000
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic-card", account_basis: account_basis, period_start_on: on.beginning_of_month.iso8601, period_end_on: on.iso8601,
        opening_balance_cents: opening, closing_balance_cents: 30_000, printed_debit_cents: 10_000, printed_credit_cents: 0, printed_row_count: 1 } ],
      events: [ { account_key: "synthetic-card", row_kind: "posted", event_type: "purchase", signed_amount_cents: -10_000, posted_on: on.iso8601, merchant: "Synthetic purchase", locator: { page: 1, row: 1 } } ], reported_row_count: 1 }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    source = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: accounting).call
    account = source[:revision].financial_source_accounts.sole
    identity = source_operation(HouseholdFinance::Operations::SourceReview::AccountLink, source_account_id: account.id, account_basis: basis, label: "Synthetic account", tracked_account_id: tracked&.id,
      base_version_id: nil, base_lock_version: 0, statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Reviewed synthetic card header")
    version = debt_source_review(source[:events].sole, identity: identity, amount: -10_000, type: "purchase", on: on)
    debt_source_coverage(source[:revision], identity)
    [ identity, import, version ]
  end

  def debt_source_review(event, identity:, amount:, type:, on:)
    head = SourceReviewHead.find_by(financial_source_event: event)
    draft = source_operation(HouseholdFinance::Operations::SourceReview::DraftStage, event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0,
      reason: "Reviewed synthetic facts", projection: { action: "none" }, facts: { source_account_identity_version_id: identity.id,
        disposition: "include", event_type: type, signed_amount_cents: amount, purchase_amount_cents: amount.abs, budget_category_id: nil, posted_on: on.iso8601,
        merchant: "Synthetic purchase", overlap_disposition: "distinct", matched_version_id: nil })
    source_operation(HouseholdFinance::Operations::SourceReview::DraftApprove, draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest)
  end

  def debt_source_coverage(revision, identity)
    state = FinancialDocuments::SourceReview::ApprovalState.new(@savings_household, revision).call
    source_operation(HouseholdFinance::Operations::SourceReview::RevisionApprove, revision_id: revision.id, requested_status: "qualified", expected_digest: state[:content_digest], reason: "Reviewed exact synthetic coverage",
      coverage_attestation: { all_document_rows_accounted: true, accounts: [ { source_account_id: identity.source_account_review_head.financial_source_account_id, identity_version_id: identity.id,
        period_start_on: identity.statement_facts["period_start_on"], period_end_on: identity.statement_facts["period_end_on"], all_rows_accounted: true } ] })
  end

  def debt_mapping(identity)
    candidate = SavingsChallenge::Debt::SourceMapping.new(@savings_household).candidate(identity)
    candidate.slice(*SavingsChallenge::Debt::SourceMapping::KEYS)
  end
end
