# Run with bin/rails runner test/scripts/source_review_concurrency.rb against a
# disposable test database. Approved facts intentionally remain until DB drop.
database = ActiveRecord::Base.connection.current_database
raise "Use an explicitly named disposable test database" unless Rails.env.test? &&
  ENV["SOURCE_REVIEW_CONCURRENCY_DISPOSABLE_DATABASE"] == database && database.end_with?("_test")

ops = HouseholdFinance::Operations::SourceReview
user = User.create!(clerk_id: "source-concurrency-#{SecureRandom.hex(8)}", email: "source-concurrency-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
household = Household.create!(created_by_user: user, name: "Synthetic two-connection source review")
household.household_memberships.create!(user: user, role: "owner")
category = household.budget_categories.create!(name: "Synthetic concurrency category", stack_key: "non_discretionary", sort_order: 0)
checksum = SecureRandom.hex(32)
execute = lambda do |klass, input|
  operation = klass.new(household, user: user)
  prepared = operation.prepare(input)
  ApplicationRecord.transaction do
    result = operation.execute!(prepared, source: "manual")
    operation.send(:verify_after!, prepared.predicted_after_snapshot, operation.after_snapshot(result, prepared))
    result
  end
end
tracked = nil
drafts = 2.times.map do
  import = FinancialDocumentImport.create!(household: household, uploaded_by_user: user, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: checksum)
  attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
  contract = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
    accounts: [ { account_key: "synthetic", account_basis: "asset", period_start_on: "2026-07-01", period_end_on: "2026-07-31", opening_balance_cents: 20_000, closing_balance_cents: 19_000, printed_debit_cents: 1_000, printed_credit_cents: 0, printed_row_count: 1 } ],
    events: [ { account_key: "synthetic", row_kind: "posted", event_type: "purchase", signed_amount_cents: -1_000, posted_on: "2026-07-07", merchant: "Synthetic merchant", locator: { page: 1, row: 1 } } ], reported_row_count: 1 }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
  source = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: contract).call
  account = source[:revision].financial_source_accounts.sole
  identity = execute.call(ops::AccountLink, source_account_id: account.id, tracked_account_id: tracked&.id, account_basis: "asset", label: "Synthetic canonical account", base_version_id: nil, base_lock_version: 0,
    statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Synthetic participant account approval")
  tracked = identity.source_tracked_account
  execute.call(ops::DraftStage, event_id: source[:events].first.id, base_version_id: nil, base_lock_version: 0, reason: "Synthetic participant canonical expense approval", projection: { action: "create" },
    facts: { source_account_identity_version_id: identity.id, disposition: "include", event_type: "purchase", signed_amount_cents: -1_000, purchase_amount_cents: 1_000, posted_on: "2026-07-07", merchant: "Synthetic merchant", budget_category_id: category.id, overlap_disposition: "canonical" })
end
prepared = drafts.map do |draft|
  ops::DraftApprove.new(household, user: user).prepare(draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest)
end
ready, release, outcomes = Queue.new, Queue.new, Queue.new
threads = prepared.map do |request|
  Thread.new do
    ActiveRecord::Base.connection_pool.with_connection do
      operation = ops::DraftApprove.new(Household.find(household.id), user: User.find(user.id))
      ready << true
      release.pop
      begin
        ApplicationRecord.transaction do
          result = operation.execute!(request, source: "manual")
          operation.send(:verify_after!, request.predicted_after_snapshot, operation.after_snapshot(result, request))
        end
        outcomes << "approved"
      rescue HouseholdFinance::Operations::Base::StaleOperation
        outcomes << "stale_blocked"
      end
    end
  end
end
2.times { ready.pop }
2.times { release << true }
threads.each(&:value)
results = 2.times.map { outcomes.pop }.sort
actuals = household.household_transactions.where(status: %w[confirmed reconciled]).count
versions = SourceReviewVersion.where(household: household).count
pending = SourceReviewDraft.where(household: household).pending.count
raise "Simultaneous duplicate approval created duplicate facts" unless results == %w[approved stale_blocked] && actuals == 1 && versions == 1 && pending == 1
puts({ check: "simultaneous_duplicate_approval", outcomes: results, active_actuals: actuals, approved_versions: versions, pending_copies: pending }.to_json)
