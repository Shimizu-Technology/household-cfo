module HouseholdFinance
  # The reader stores participant-safe copy, also shown on the Statements card.
  class UploadFailureReply
    def self.call(document)
      document.extraction_error.presence || (document.metadata.to_h["extraction_failure_permanent"] ? FinancialDocuments::Extractor::REJECTED_FILE_MESSAGE : FinancialDocuments::Extractor::TEMPORARY_FAILURE_MESSAGE)
    end

    def self.for_files(documents)
      failed = documents.select(&:failed?)
      failed.map do |document|
        message = call(document)
        documents.many? ? "#{FinancialDocuments::AccountNumberMask.display(document.filename)}: #{message}" : message
      end.join(" ").presence
    end
  end
end
