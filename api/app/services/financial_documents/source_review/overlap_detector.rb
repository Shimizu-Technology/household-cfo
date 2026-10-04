module FinancialDocuments
  module SourceReview
    class OverlapDetector
      def initialize(household, event, facts)
        @household, @event, @facts = household, event, facts.deep_symbolize_keys
      end

      def call
        heads = SourceReviewHead.where(household: household).includes(:approved_version).index_by(&:financial_source_event_id)
        pending = SourceReviewDraft.where(household: household).pending.index_by(&:source_review_head_id)
        accounts = SourceAccountReviewHead.where(household: household).includes(:approved_version).index_by(&:financial_source_account_id)
        own_account = SourceAccountIdentityVersion.find_by(household: household, id: facts[:source_account_identity_version_id])&.source_tracked_account_id
        artifact = event.financial_extraction_revision.financial_document_import&.checksum_sha256
        FinancialSourceEvent.where(household: household).where.not(id: event.id).includes(financial_extraction_revision: :financial_document_import).filter_map do |other|
          head = heads[other.id]
          approved = head&.approved_version
          next if approved&.disposition.in?(%w[exclude informational])
          next if approved&.disposition == "match" && approved.matched_version&.source_review_head&.financial_source_event_id == event.id
          draft = pending[head&.id]
          candidate = approved&.attributes&.symbolize_keys || (draft ? draft.facts.deep_symbolize_keys : other.attributes.symbolize_keys)
          other_account = accounts[other.financial_source_account_id]&.approved_version&.source_tracked_account_id
          other_artifact = approved&.source_artifact_digest || other.financial_extraction_revision.financial_document_import&.checksum_sha256
          same_artifact = artifact.present? && artifact == other_artifact
          same_locator = event.locator.present? && event.locator["row"].to_i.positive? && event.locator == other.locator
          same_reference = approved && facts[:external_reference].present? && facts[:external_reference] == approved.external_reference && own_account && own_account == other_account
          strength = if same_artifact && same_locator || same_reference
            "strong"
          elsif !same_artifact && (own_account.nil? || other_account.nil? || own_account == other_account) && facts[:signed_amount_cents].present? && facts[:signed_amount_cents] == candidate[:signed_amount_cents] && facts[:posted_on].to_s == candidate[:posted_on].to_s
            "ambiguous"
          end
          next unless strength
          { event_id: other.id, revision_id: other.financial_extraction_revision_id, approved_version_id: approved&.id,
            pending_draft_id: draft&.id, strength: strength, proof: strength == "strong" ? (same_reference ? "participant_reviewed_account_reference" : "verified_artifact_and_physical_row") : "date_and_amount_are_not_proof" }
        end.sort_by { |row| row[:event_id] }
      end

      private

      attr_reader :household, :event, :facts
    end
  end
end
