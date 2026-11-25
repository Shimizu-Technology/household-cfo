module FinancialDocuments
  module SourceReview
    # Suggestions only: both accounts must already have participant-reviewed identities.
    # A unique match in both directions prevents equal repeated movements being guessed.
    class TransferPairs
      WINDOW = 3

      def self.person_wording?(event, merchant)
        return false if event.event_type.in?(%w[fee interest cash_withdrawal refund income debt_payment])

        names_person?(event, merchant)
      end

      def self.person_payment?(event, merchant)
        event.signed_amount_cents.to_i.negative? && person_wording?(event, merchant)
      end

      # "Zelle from …" or "Received from …" can be her own money from another account or money someone gave her.
      def self.incoming_person_payment?(event, merchant)
        event.signed_amount_cents.to_i.positive? && event.event_type.in?(%w[transfer income]) && names_person?(event, merchant)
      end

      def self.names_person?(event, merchant)
        payload = event.financial_source_evidence&.payload || {}
        words = [ merchant, payload["merchant"], payload["raw_description"] ].compact.map(&:to_s)
        words.any? do |text|
          [ text, text.sub(SpendingPatterns::MerchantName::BANK_PREFIX, "") ].any? do |label|
            # Review ownership separately from the broader cut-protection rule.
            next true if label.match?(/\b(?:zelle|venmo|cash\s*app)\b/i)
            next false if label.match?(/\b(?:card|loan|power|authority|utility|utilities|insurance|telecom|mortgage|inc|llc|corp)\b/i)
            label.match?(/\Apaypal\s*(?:to\s+|\*\s*)[a-z]+(?:[ .]+[a-z]+)+\z/i) && !label.match?(/\.[a-z]{2,}\b/i) ||
              label.match?(/\A(?:payment\s+)?to\s+\S+/i) || label.match?(/\Areceived\s+from\s+\S+/i)
          end
        end
      end

      # unlinked_account_ids: accounts confirmed by the save in progress. She saw their lines before that, when they
      # could not pair, so they are not offered as a pair here either: an answer to the question she saw is not stale.
      def initialize(household, unlinked_account_ids: [])
        @household = household
        @unlinked_account_ids = unlinked_account_ids.to_set
      end

      def candidate(event)
        row = rows.find { |entry| entry[:event].id == event.id }
        return unless row
        matches = matches_for(row)
        matches.first if matches.one? && matches_for(matches.first).one?
      end

      def paired(event)
        @groups ||= EconomicLinker.valid_current_versions(@household).select { |group| group.kind == "transfer" }
        @groups.find { |group| group.source_economic_memberships.any? { |member| member.source_review_version.financial_source_event.id == event.id } }
      end

      private

      def matches_for(row)
        rows.select do |other|
          other[:identity].source_tracked_account_id != row[:identity].source_tracked_account_id &&
            other[:amount] == -row[:amount] && (other[:date] - row[:date]).abs <= WINDOW
        end
      end

      def rows
        @rows ||= begin
          revisions = FinancialExtractionRevision.where(household: @household,
            financial_document_import_id: @household.financial_document_imports.current_picture.select(:id))
          paired_ids = EconomicLinker.active_memberships(@household).map { |member| member.source_review_version.financial_source_event.id }.to_set
          identities = SourceAccountReviewHead.where(household: @household).includes(:approved_version).to_h { |head| [ head.financial_source_account_id, head.approved_version ] }
          heads = SourceReviewHead.where(household: @household).includes(:approved_version, :source_review_drafts).index_by(&:financial_source_event_id)
          latest = FinancialExtractionRevision.where(id: revisions.group(:financial_document_import_id).select("MAX(id)"))
          blocked = latest.select do |revision|
            document = revision.financial_document_import
            file_open = document&.spreadsheet? && document.source_available? && !SpreadsheetSignAnswer.saved_decisions?(revision) &&
              revision.coverage["signed_amount_question"] == true
            file_open ||
              SpreadsheetSignAnswer.account_questions(revision).any? { |question| question[:answerable] && question[:answer].nil? }
          end.map(&:id).to_set
          FinancialSourceEvent.where(financial_extraction_revision_id: latest.select(:id), row_kind: "posted").includes(:financial_source_evidence).filter_map do |event|
            next if paired_ids.include?(event.id)
            next if blocked.include?(event.financial_extraction_revision_id)
            merchant = ParticipantPlan.merchant_for(event)
            next if event.signed_amount_cents.to_i.positive? && (self.class.person_wording?(event, merchant) || self.class.incoming_person_payment?(event, merchant))
            next if @unlinked_account_ids.include?(event.financial_source_account_id)
            identity = identities[event.financial_source_account_id]
            head = heads[event.id]
            next if head&.source_review_drafts&.any? { |draft| draft.status == "pending" }
            version = head&.approved_version
            next unless identity && (!version || version.source_account_identity_version_id == identity.id)
            next if version && (version.disposition != "include" || version.external_reference.to_s.start_with?("unpaired-transfer:"))
            type = version&.event_type || event.event_type
            amount = version ? version.signed_amount_cents : event.signed_amount_cents
            date = version ? version.posted_on : event.posted_on
            # Money in that may be her own money coming back can be the other half of a move between her accounts.
            movement = type.in?(%w[transfer debt_payment]) || (!version && (self.class.person_payment?(event, merchant) || ParticipantPlan.money_in_question?(event, merchant)))
            next unless movement && amount && !amount.zero? && date && date <= Date.current
            { event: event, identity: identity, version: version, amount: amount, date: date }
          end
        end
      end
    end
  end
end
