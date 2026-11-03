module FinancialDocuments
  module SourceReview
    class OverlapDetector
      # What every line of one statement is compared against, read once. A statement that overlaps an earlier one
      # (the same file uploaded twice) asks the question for every line, so reading this per line costs minutes.
      class Context
        def initialize(household)
          @household = household
        end

        def heads = @heads ||= SourceReviewHead.where(household: @household).includes(:approved_version).index_by(&:financial_source_event_id)
        def pending = @pending ||= SourceReviewDraft.where(household: @household).pending.index_by(&:source_review_head_id)
        def accounts = @accounts ||= SourceAccountReviewHead.where(household: @household).includes(:approved_version).index_by(&:financial_source_account_id)
        def events = @events ||= FinancialSourceEvent.where(household: @household).includes(financial_extraction_revision: :financial_document_import).to_a
        def tracked_account_for(identity_id) = (@tracked ||= {}).fetch(identity_id) { @tracked[identity_id] = SourceAccountIdentityVersion.find_by(household: @household, id: identity_id)&.source_tracked_account_id }
      end

      # unlinked: read the line as when its account was not linked yet, which is how she saw it. Linking an account during a save
      # must not turn a copy she was asked about into a line that no longer matches her screen.
      def initialize(household, event, facts, context: Context.new(household), unlinked: false)
        @household, @event, @facts, @context, @unlinked = household, event, facts.deep_symbolize_keys, context, unlinked
      end

      def call
        heads, pending, accounts = context.heads, context.pending, context.accounts
        own_account = @unlinked ? nil : context.tracked_account_for(facts[:source_account_identity_version_id])
        artifact = event.financial_extraction_revision.financial_document_import&.checksum_sha256
        context.events.reject { |other| other.id == event.id }.filter_map do |other|
          head = heads[other.id]
          approved = head&.approved_version
          next if approved&.disposition.in?(%w[exclude informational])
          next if approved&.disposition == "match" && approved.matched_version&.source_review_head&.financial_source_event_id == event.id
          draft = pending[head&.id]
          candidate_amount, candidate_day = if approved then [ approved.signed_amount_cents, approved.posted_on ]
          elsif draft then draft.facts.values_at("signed_amount_cents", "posted_on")
          else [ other.signed_amount_cents, other.posted_on ]
          end
          other_account = accounts[other.financial_source_account_id]&.approved_version&.source_tracked_account_id
          other_artifact = approved&.source_artifact_digest || other.financial_extraction_revision.financial_document_import&.checksum_sha256
          same_artifact = artifact.present? && artifact == other_artifact
          same_locator = event.locator.present? && event.locator["row"].to_i.positive? && event.locator == other.locator
          same_reference = approved && facts[:external_reference].present? && facts[:external_reference] == approved.external_reference && own_account && own_account == other_account
          strength = if same_artifact && same_locator || same_reference
            "strong"
          elsif !same_artifact && (own_account.nil? || other_account.nil? || own_account == other_account) && facts[:signed_amount_cents].present? && facts[:signed_amount_cents] == candidate_amount && facts[:posted_on].to_s == candidate_day.to_s
            "ambiguous"
          end
          next unless strength
          { event_id: other.id, revision_id: other.financial_extraction_revision_id, approved_version_id: approved&.id,
            pending_draft_id: draft&.id, strength: strength, proof: strength == "strong" ? (same_reference ? "participant_reviewed_account_reference" : "verified_artifact_and_physical_row") : "date_and_amount_are_not_proof" }
        end.sort_by { |row| row[:event_id] }
      end

      private

      attr_reader :household, :event, :facts, :context
    end
  end
end
