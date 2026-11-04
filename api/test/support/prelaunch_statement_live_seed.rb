# Synthetic fixtures for both prelaunch and postlaunch household browser journeys.
# QA_SEED_DB / DATABASE_TEST_NAME and HCFO_W14_FIXTURE_FILE must be explicit.
require_relative "persona_test_helper"
include PersonaTestHelper
raise "Set QA_SEED_DB to the dedicated test database" unless Rails.env.test? && ENV["QA_SEED_DB"].to_s.start_with?("household_cfo_qa_") && ActiveRecord::Base.connection_db_config.database == ENV["QA_SEED_DB"]
raise "Live model calls must be disabled" if ENV["OPENROUTER_API_KEY"].present?
fixtures = {}
%w[prelaunch postlaunch v1].each do |state|
  fixtures[state] = {}
  %w[desktop-chrome tablet-768-chrome tablet-1024-chrome mobile-chrome compact-mobile-chrome mobile-webkit].each do |project|
    suffix = SecureRandom.hex(5)
    user = persona_user(role: "participant")
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    coach = persona_user
    cohort = cohort_for(coach, name: "Synthetic household #{state} #{project}", status: "enrolling")
    cohort.cohort_memberships.create!(user: user, role: "participant")
    persona = create_persona(creator: coach, config: persona_configuration(assistant_name: "Mel’s Mia"))
    publish_persona(persona, actor: coach)
    configuration = cohort.cohort_experience_configuration
    configuration.update!(draft_config: CohortReleases::Contract::LEGACY_EXPERIENCE_DEFAULT_V1, last_edited_by_user: coach)
    if state != "prelaunch"
      publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
      digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
      publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)
      CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
      CohortReleases::RuntimeActivator.new(cohort: cohort).call! if state == "v1"
    end
    household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 0)
    document = household.financial_document_imports.create!(uploaded_by_user: user, document_kind: "statement", status: "needs_review", filename: "synthetic-october.csv", content_type: "text/csv", byte_size: 100, s3_key: "synthetic/#{suffix}.csv", checksum_sha256: SecureRandom.hex(32))
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    rows = [ { account_key: "acct", row_kind: "posted", event_type: "purchase", signed_amount_cents: -1250, posted_on: "2026-10-01", merchant: "Fictional Market", locator: { page: 1, row: 1 } } ]
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION, accounts: [ { account_key: "acct", account_basis: "asset", label: "Checking" } ], events: rows, reported_row_count: 1 }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
    document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_contract_version" => "source_accounting_v1", "source_accounting_review_pending" => true })
    fixtures[state][project] = { id: user.id, clerk_id: user.clerk_id, email: user.email, cohort_id: cohort.id, import_id: document.id, revision_id: result[:revision].id, coach_id: coach.id, coach_clerk_id: coach.clerk_id, coach_email: coach.email, persona_id: persona.id, persona_name: "Mel’s Mia", workspace_id: cohort.coach_workspace_id, group_name: cohort.name }
  end
end
File.write(ENV.fetch("HCFO_W14_FIXTURE_FILE"), JSON.generate(fixtures))
