# Synthetic extracted statements for web/e2e/prelaunch-statement-live.spec.ts.
# Set QA_SEED_DB, DATABASE_TEST_NAME and HCFO_W14_FIXTURE_FILE, then run in test.
raise "Set QA_SEED_DB to the dedicated test database" unless ENV["QA_SEED_DB"].to_s.start_with?("household_cfo_qa_") && ActiveRecord::Base.connection_db_config.database == ENV["QA_SEED_DB"]
fixtures = {}
%w[desktop-chrome mobile-webkit compact-mobile-chrome].each do |project|
  suffix = SecureRandom.hex(5)
  user = User.create!(clerk_id: "w14-#{suffix}", email: "w14-#{suffix}@example.invalid", role: "participant", invitation_status: "accepted")
  household = HouseholdFinance::WorkspaceResolver.new(user).household
  coach = User.create!(clerk_id: "w14-coach-#{suffix}", email: "w14-coach-#{suffix}@example.invalid", role: "coach", invitation_status: "accepted")
  cohort = Cohort.create!(name: "Prelaunch #{suffix}", status: "enrolling", created_by_user: coach)
  cohort.cohort_memberships.create!(user: user, role: "participant")
  household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 0)
  document = household.financial_document_imports.create!(uploaded_by_user: user, document_kind: "statement", status: "needs_review", filename: "synthetic-october.csv", content_type: "text/csv", byte_size: 100, s3_key: "synthetic/#{suffix}.csv", checksum_sha256: SecureRandom.hex(32))
  attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
  rows = [ { account_key: "acct", row_kind: "posted", event_type: "purchase", signed_amount_cents: -1250, posted_on: "2026-10-01", merchant: "Fictional Market", locator: { page: 1, row: 1 } } ]
  accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION, accounts: [ { account_key: "acct", account_basis: "asset", label: "Checking" } ], events: rows, reported_row_count: 1 }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
  result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
  document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_contract_version" => "source_accounting_v1", "source_accounting_review_pending" => true })
  fixtures[project] = { id: user.id, clerk_id: user.clerk_id, email: user.email, cohort_id: cohort.id, import_id: document.id, revision_id: result[:revision].id }
end
File.write(ENV.fetch("HCFO_W14_FIXTURE_FILE"), JSON.generate(fixtures))
