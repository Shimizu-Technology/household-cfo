module Scorecard
  class ExtractionJob < FinancialDocumentExtractionJob
    attr_accessor :scorecard_extractor

    private

    def build_extractor = scorecard_extractor
  end
end
