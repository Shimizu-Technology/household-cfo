namespace :document_extraction do
  desc "Recover a bounded batch of durable extraction intents directly from the primary database"
  task recover: :environment do
    FinancialDocumentExtractionRecoveryJob.perform_now
  end
end
