module FinancialDocuments
  module SourceReview
    class OverlapDetector
      CROSS_FILE_DAYS = 3

      # Shared account identities and narrowed current-picture matches for a save.
      class Context
        def initialize(household)
          @household = household
        end

        # After a write. The lines of every statement stay as they are while a page is saved; what has been approved, drafted or linked does.
        def refresh!
          @heads = @pending = @accounts = @tracked = @preloaded = nil
          self
        end

        attr_reader :heads, :pending

        def accounts = @accounts ||= SourceAccountReviewHead.where(household: @household).includes(:approved_version).index_by(&:financial_source_account_id)
        def tracked_account_for(identity_id) = (@tracked ||= {}).fetch(identity_id) { @tracked[identity_id] = SourceAccountIdentityVersion.find_by(household: @household, id: identity_id)&.source_tracked_account_id }

        # Read only possible matches from the current picture. Source, approved
        # and pending facts all participate; edited amounts must not hide copies.
        # Physical rows and reviewed references are strong regardless of date/amount.
        # A read-only page shares one narrowed superset, then applies the exact
        # rules per line. A locked save updates approved heads in that superset.
        def preload!(events, artifact)
          dated = events.select { |event| event.signed_amount_cents && event.posted_on }
          days = dated.map(&:posted_on)
          window = ((days.min - CROSS_FILE_DAYS)..(days.max + CROSS_FILE_DAYS)) if days.any?
          @preloaded = read_candidates({ signed_amount_cents: dated.map(&:signed_amount_cents).uniq }, artifact, nil, days: window, all_physical: true, known_events: events)
        end

        def candidates(facts, artifact, locator)
          @preloaded || read_candidates(facts, artifact, locator)
        end

        def record_approval!(event, head)
          if @preloaded && @preloaded.none? { |row| row.id == event.id }
            eligible = (@eligible_revisions ||= {}).fetch(event.financial_extraction_revision_id) do |id|
              @eligible_revisions[id] = FinancialExtractionRevision.where(id: @candidate_revisions).exists?(id: id)
            end
            @preloaded << event if eligible
          end
          @heads[event.id] = head if @heads
          @pending&.delete(head.id)
        end

        private

        def read_candidates(facts, artifact, locator, days: nil, all_physical: false, known_events: [])
          scope = FinancialSourceEvent.where(household: @household)
          revisions = FinancialExtractionRevision.where(household: @household)
            .where("financial_document_import_id IS NOT NULL OR EXISTS (SELECT 1 FROM source_review_heads h JOIN financial_source_events e ON e.id = h.financial_source_event_id WHERE e.financial_extraction_revision_id = financial_extraction_revisions.id AND h.approved_version_id IS NOT NULL)")
            .select("DISTINCT ON (financial_document_import_id, source_document_identity) id")
            .order(:financial_document_import_id, :source_document_identity, revision_number: :desc, id: :desc)
          @candidate_revisions = revisions
          versions = SourceReviewVersion.where(household: @household)
          matches = scope.none
          reviewed = versions.none
          if days || (facts[:signed_amount_cents] && facts[:posted_on].present?)
            day = facts[:posted_on].to_date unless days
            days ||= (day - CROSS_FILE_DAYS)..(day + CROSS_FILE_DAYS)
            matches = matches.or(scope.where(signed_amount_cents: facts[:signed_amount_cents], posted_on: days))
            reviewed = reviewed.or(versions.where(signed_amount_cents: facts[:signed_amount_cents], posted_on: days))
            drafts = SourceReviewDraft.where(household: @household).pending
              .where("facts->>'signed_amount_cents' IN (?) AND facts->>'posted_on' BETWEEN ? AND ?", Array(facts[:signed_amount_cents]).map(&:to_s), days.begin.iso8601, days.end.iso8601)
            matches = matches.or(scope.where(id: SourceReviewHead.where(id: drafts.select(:source_review_head_id)).select(:financial_source_event_id)))
          end
          if artifact.present? && (all_physical || locator&.fetch("row", nil).to_i.positive?)
            imports = FinancialDocumentImport.where(household: @household, checksum_sha256: artifact)
            physical = all_physical ? scope : scope.where(locator: locator)
            matches = matches.or(physical.where(financial_extraction_revision_id: FinancialExtractionRevision.where(financial_document_import_id: imports.select(:id)).select(:id)))
            artifact_heads = SourceReviewHead.where(approved_version_id: versions.where(source_artifact_digest: artifact).select(:id))
            matches = matches.or(physical.where(id: artifact_heads.select(:financial_source_event_id)))
          end
          reviewed = reviewed.or(versions.where(external_reference: facts[:external_reference])) if facts[:external_reference].present?
          matches = matches.or(scope.where(id: SourceReviewHead.where(approved_version_id: reviewed.select(:id)).select(:financial_source_event_id)))
          known = known_events.select(&:persisted?).index_by(&:id)
          rows = matches.where(financial_extraction_revision_id: revisions).map { |row| known[row.id] || row }
          ActiveRecord::Associations::Preloader.new(records: rows, associations: [ :financial_source_evidence, { financial_extraction_revision: :financial_document_import } ]).call
          @heads = SourceReviewHead.where(household: @household, financial_source_event_id: rows.map(&:id)).includes(approved_version: :matched_version).index_by(&:financial_source_event_id)
          @pending = SourceReviewDraft.where(household: @household, source_review_head_id: @heads.values.map(&:id)).pending.index_by(&:source_review_head_id)
          rows
        end
      end

      # unlinked: read the line as when its account was not linked yet, which is how she saw it. Linking an account during a save
      # must not turn a copy she was asked about into a line that no longer matches her screen.
      def initialize(household, event, facts, context: Context.new(household), unlinked: false)
        @household, @event, @facts, @context, @unlinked = household, event, facts.deep_symbolize_keys, context, unlinked
      end

      def call
        accounts = context.accounts
        own_account = @unlinked ? nil : context.tracked_account_for(facts[:source_account_identity_version_id])
        own_revision = event.financial_extraction_revision
        artifact = own_revision.financial_document_import&.checksum_sha256
        candidates = context.candidates(facts, artifact, event.locator)
        heads, pending = context.heads, context.pending
        candidates.filter_map do |other|
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
        merchant, other_key = merchant_key(facts[:merchant]), merchant_key(other_merchant)
        merchant.present? && other_key.present? && (merchant == other_key || names_merchant?(merchant, other_key))
      end

      # A bank export's long descriptor ("Non-WF ATM Withdrawal authorized on 03/17 Tamuning Gum…") has every word of the
      # statement's merchant ("Non-WF ATM Tamuning Gum"), in order. This only asks "Same charge?"; one word alone is too common to ask about.
      def names_merchant?(one, other)
        short, long = [ one, other ].map(&:split).sort_by(&:length)
        position = 0
        short.length >= 2 && short.all? do |word|
          found = long.drop(position).index(word)
          position += found + 1 if found
        end
      end

      def merchant_key(merchant)
        MerchantNormalizer.call(merchant)&.downcase&.squish
      end
    end
  end
end
