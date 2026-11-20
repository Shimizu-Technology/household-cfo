module FinancialDocuments
  module SourceReview
    class OverlapDetector
      CROSS_FILE_DAYS = 3

      # What every line of one statement is compared against, read once. A statement that overlaps an earlier one
      # (the same file uploaded twice) asks the question for every line, so reading this per line costs minutes.
      class Context
        def initialize(household)
          @household = household
        end

        # After a write. The lines of every statement stay as they are while a page is saved; what has been approved, drafted or linked does.
        def refresh!
          @heads = @pending = @accounts = @tracked = @reviewed_index = nil
          self
        end

        def heads = @heads ||= SourceReviewHead.where(household: @household).includes(:approved_version).index_by(&:financial_source_event_id)
        def pending = @pending ||= SourceReviewDraft.where(household: @household).pending.index_by(&:source_review_head_id)
        def accounts = @accounts ||= SourceAccountReviewHead.where(household: @household).includes(:approved_version).index_by(&:financial_source_account_id)
        def events = @events ||= FinancialSourceEvent.where(household: @household)
          .where(financial_extraction_revision_id: FinancialExtractionRevision.where(household: @household).where("financial_document_import_id IS NOT NULL OR EXISTS (SELECT 1 FROM source_review_heads h JOIN financial_source_events e ON e.id = h.financial_source_event_id WHERE e.financial_extraction_revision_id = financial_extraction_revisions.id AND h.approved_version_id IS NOT NULL)").select("DISTINCT ON (financial_document_import_id, source_document_identity) id").order(:financial_document_import_id, :source_document_identity, revision_number: :desc, id: :desc)).includes(:financial_source_evidence, financial_extraction_revision: :financial_document_import).to_a
        def tracked_account_for(identity_id) = (@tracked ||= {}).fetch(identity_id) { @tracked[identity_id] = SourceAccountIdentityVersion.find_by(household: @household, id: identity_id)&.source_tracked_account_id }
        # Compare rows in the amount bucket, plus physical rows and reviewed
        # references that can be strong matches even when amounts have changed.
        def candidates(facts, artifact, locator)
          amount = facts[:signed_amount_cents]
          row_key = [ artifact, locator ] if artifact.present? && locator&.fetch("row", nil).to_i.positive?
          reference = facts[:external_reference].presence
          ids = source_index[:amount].fetch(amount, []) + reviewed_index[:amount].fetch(amount, [])
          ids += source_index[:artifact].fetch(row_key, []) + reviewed_index[:artifact].fetch(row_key, []) if row_key
          ids += reviewed_index[:reference].fetch(reference, []) if reference
          ids.uniq.filter_map { |id| events_by_id[id] }
        end

        private

        def events_by_id = @events_by_id ||= events.index_by(&:id)

        def source_index
          @source_index ||= indexes do |index|
            events.each do |row|
              index[:amount][row.signed_amount_cents] << row.id if row.signed_amount_cents
              checksum = row.financial_extraction_revision.financial_document_import&.checksum_sha256
              index[:artifact][[ checksum, row.locator ]] << row.id if checksum.present? && row.locator&.fetch("row", nil).to_i.positive?
            end
          end
        end

        def reviewed_index
          @reviewed_index ||= indexes do |index|
            heads.each do |id, head|
              row = events_by_id[id]
              next unless row

              approved = head.approved_version
              amount = approved ? approved.signed_amount_cents : pending[head.id]&.facts&.fetch("signed_amount_cents", nil)
              index[:amount][amount] << id if amount
              checksum = approved&.source_artifact_digest
              index[:artifact][[ checksum, row.locator ]] << id if checksum.present? && row.locator&.fetch("row", nil).to_i.positive?
              index[:reference][approved.external_reference] << id if approved&.external_reference.present?
            end
          end
        end

        def indexes
          %i[amount artifact reference].index_with { Hash.new { |hash, key| hash[key] = [] } }.tap { |index| yield index }
        end
      end

      # unlinked: read the line as when its account was not linked yet, which is how she saw it. Linking an account during a save
      # must not turn a copy she was asked about into a line that no longer matches her screen.
      def initialize(household, event, facts, context: Context.new(household), unlinked: false)
        @household, @event, @facts, @context, @unlinked = household, event, facts.deep_symbolize_keys, context, unlinked
      end

      def call
        heads, pending, accounts = context.heads, context.pending, context.accounts
        own_account = @unlinked ? nil : context.tracked_account_for(facts[:source_account_identity_version_id])
        own_revision = event.financial_extraction_revision
        artifact = own_revision.financial_document_import&.checksum_sha256
        context.candidates(facts, artifact, event.locator).filter_map do |other|
          next if other.id == event.id
          other_revision = other.financial_extraction_revision
          same_source = if own_revision.financial_document_import_id && other_revision.financial_document_import_id
            own_revision.financial_document_import_id == other_revision.financial_document_import_id
          else
            own_revision.source_document_identity == other_revision.source_document_identity
          end
          next if same_source && other.financial_extraction_revision_id != event.financial_extraction_revision_id
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
          elsif !same_artifact && (own_account.nil? || other_account.nil? || own_account == other_account) && facts[:signed_amount_cents].present? && facts[:signed_amount_cents] == candidate_amount && near_posted_date?(candidate_day, other, approved, draft, same_source: same_source)
            "ambiguous"
          end
          next unless strength
          { event_id: other.id, revision_id: other.financial_extraction_revision_id, approved_version_id: approved&.id,
            pending_draft_id: draft&.id, strength: strength, proof: strength == "strong" ? (same_reference ? "participant_reviewed_account_reference" : "verified_artifact_and_physical_row") : "date_and_amount_are_not_proof" }
        end.sort_by { |row| row[:event_id] }
      end

      private

      attr_reader :household, :event, :facts, :context

      def near_posted_date?(candidate_day, other, approved, draft, same_source:)
        day = facts[:posted_on]
        return true if day.to_s == candidate_day.to_s
        return false if same_source || day.blank? || candidate_day.blank?
        return false if (day.to_date - candidate_day.to_date).abs > CROSS_FILE_DAYS

        other_merchant = if approved then approved.merchant
        elsif draft then draft.facts["merchant"]
        else ParticipantPlan.merchant_for(other)
        end
        merchant = merchant_key(facts[:merchant])
        merchant.present? && merchant == merchant_key(other_merchant)
      end

      def merchant_key(merchant)
        MerchantNormalizer.call(merchant)&.downcase&.squish
      end
    end
  end
end
