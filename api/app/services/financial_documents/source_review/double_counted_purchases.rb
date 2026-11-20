module FinancialDocuments
  module SourceReview
    # Diagnostic only: never repairs or exposes financial facts.
    class DoubleCountedPurchases
      def self.call(household)
        counts = nil
        household.class.transaction(requires_new: true) do
          versions = SourceReviewVersion.joins(source_review_head: { financial_source_event: { financial_extraction_revision: :financial_document_import } }).where(household: household)
            .where(financial_document_imports: { document_kind: "statement" })
            .where("source_review_heads.approved_version_id = source_review_versions.id")
          included = versions.where(disposition: "include").to_a
          matcher = ConfirmedPurchaseMatch.new(household, dates: included.map(&:posted_on), include_claimed: true)
          separate = included.count do |version|
            matcher.best(signed_amount_cents: version.signed_amount_cents, posted_on: version.posted_on,
              merchant: version.merchant, event_type: version.event_type).present?
          end
          confirmed_ids = household.household_transactions.where(status: ConfirmedPurchaseMatch::COUNTED, financial_source_event_id: nil).where.not(source_type: "statement").select(:id)
          multiple = versions.where(matched_transaction_id: confirmed_ids).group(:matched_transaction_id).having("COUNT(*) > 1").count.size
          counts = { separately_approved_lines: separate, purchases_matched_by_multiple_lines: multiple }
          raise ActiveRecord::Rollback
        end
        counts
      end
    end
  end
end
