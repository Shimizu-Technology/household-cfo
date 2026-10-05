class FinancialDocumentExtractionRecoveryJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 100

  def perform
    # Missing rows are inserted only once. Subsequent bounded sweeps advance past
    # them even when queue admission fails, rather than starving later uploads.
    FinancialDocumentImport.where(status: %w[uploaded processing]).where.not(s3_key: [ nil, "" ])
      .where.missing(:extraction_dispatch).order(:id).limit(BATCH_SIZE).each do |document_import|
        FinancialDocumentExtractionDispatch.request!(document_import)
      end
    FinancialDocumentExtractionDispatch.due.order(:next_attempt_at, :id).limit(BATCH_SIZE).each(&:enqueue_retry)
  end
end
