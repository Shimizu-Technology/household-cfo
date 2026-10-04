class FinancialDocumentSourceCleanupRecoveryJob < ApplicationJob
  queue_as :default

  def perform
    FinancialDocumentSourceCleanup.due.find_each(batch_size: 100) do |cleanup|
      cleanup.enqueue_retry
    end
  end
end
