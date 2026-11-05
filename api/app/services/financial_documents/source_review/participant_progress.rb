module FinancialDocuments
  module SourceReview
    # Upload history needs current saved counts, not merchant matching or a
    # reconciliation of every line in every upload. Keep this read bounded.
    class ParticipantProgress
      def initialize(household, revision)
        @household, @revision = household, revision
      end

      def call
        versions = SourceReviewVersion.joins(source_review_head: :financial_source_event, source_account_identity_version: :source_account_review_head)
          .where(household: @household, financial_source_events: { financial_extraction_revision_id: @revision.id })
          .where("source_review_heads.approved_version_id = source_review_versions.id")
          .where("source_account_review_heads.approved_version_id = source_review_versions.source_account_identity_version_id")
        total = @revision.financial_source_events.count
        done = versions.count
        without_category = versions.where(budget_category_id: nil, disposition: "include", event_type: FinancialSourceEvent::EXPENSE_TYPES).where("source_review_versions.signed_amount_cents < 0").count
        { total: total, done: done, without_category: without_category,
          coverage: { question: CoverageQuestion.text(@revision, deficiencies: CoverageQuestion.document_covered?(@revision) ? [] : [ "document_page_or_sheet_coverage_unverified" ]), answer: CoverageQuestion.answer(@revision), version_id: CoverageQuestion.latest(@revision)&.id } }
      end
    end
  end
end
