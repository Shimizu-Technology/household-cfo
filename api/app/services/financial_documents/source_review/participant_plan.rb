module FinancialDocuments
  module SourceReview
    # Sorts a statement's lines into "looks right" and the few that need the
    # participant's answer. The same plan drives what the review screen shows
    # and what "Approve the rest" is allowed to apply, so the two cannot drift.
    # Nothing here approves anything; unknown stays unknown and becomes a question.
    class ParticipantPlan
      # as_before: the category is only what she chose for this merchant on an earlier statement; the reader guessed nothing.
      Line = Struct.new(:event, :merchant, :category_id, :kind, :overlaps, :done, :as_before, keyword_init: true) do
        def ready? = kind.nil?
      end

      EXPENSE_TYPES = FinancialSourceEvent::EXPENSE_TYPES
      QUESTIONS = {
        unclear: "We couldn’t read this line clearly.",
        duplicate: "Is this the same charge as one you already have?",
        transfer: "Did this move between your own accounts?",
        card_payment: "Is this a payment on your own card or loan?",
        refund: "Is this a refund?",
        no_category: "What was this for?",
        # Asked with her own earlier category for the same merchant: "Still Dining out?"
        still_category: nil
      }.freeze
      ANSWERS = {
        unclear: [ { id: "edit", label: "Fix it" }, { id: "leave_out", label: "Leave it out" } ],
        duplicate: [ { id: "leave_out", label: "Same charge" }, { id: "different", label: "Different charge" } ],
        transfer: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        card_payment: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        refund: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        no_category: [ { id: "edit", label: "Choose one" }, { id: "leave_out", label: "Leave it out" } ],
        still_category: [ { id: "keep", label: "Yes" }, { id: "edit", label: "Change" } ]
      }.freeze

      def initialize(household, revision)
        @household, @revision = household, revision
      end

      def lines
        @lines ||= build
      end

      def ready_ids = lines.select { |line| line.ready? && !line.done }.map { |line| line.event.id }
      def attention = lines.reject { |line| line.ready? || line.done }
      def line_for(event_id) = lines.find { |line| line.event.id == event_id }

      # Facts exactly as read from the statement. Participant answers change these
      # before they are saved; nothing is filled in that the file did not say.
      def self.facts_as_read(event, identity_id:, merchant:, category_id:)
        expense = expense?(event)
        informational = event.row_kind == "informational"
        {
          source_account_identity_version_id: identity_id,
          disposition: informational ? "informational" : "include",
          event_type: event.event_type,
          signed_amount_cents: informational ? nil : event.signed_amount_cents,
          purchase_amount_cents: expense ? event.expense_amount_cents : nil,
          posted_on: event.posted_on&.iso8601,
          authorized_on: event.authorized_on&.iso8601,
          merchant: merchant,
          budget_category_id: expense ? category_id : nil,
          overlap_disposition: informational ? "excluded" : "new",
          external_reference: nil
        }
      end

      def self.expense?(event)
        event.row_kind == "posted" && event.event_type.in?(EXPENSE_TYPES) && event.signed_amount_cents.to_i.negative?
      end

      # The words she sees and approves. Long account numbers show as ····1234; the statement's own text stays stored as read.
      def self.merchant_for(event)
        payload = event.financial_source_evidence&.payload || {}
        AccountNumberMask.display(payload["merchant"].to_s.squish.presence || payload["raw_description"].to_s.squish.presence)
      end

      private

      attr_reader :household, :revision

      def build
        events = revision.financial_source_events.includes(:financial_source_evidence).order(:position, :id).to_a
        heads = SourceReviewHead.where(household: household, financial_source_event_id: events.map(&:id)).includes(approved_version: { source_account_identity_version: :source_account_review_head }).index_by(&:financial_source_event_id)
        categories = household.budget_categories.active.pluck(:id).to_set
        suggestions, earlier = suggested_categories(events)
        accounts = revision.financial_source_accounts.index_by(&:id)
        candidates = overlap_candidates(events)
        events.map do |event|
          merchant = self.class.merchant_for(event)
          guess = suggestions[event.id]
          guess = nil unless categories.include?(guess)
          chosen = earlier[event.id]
          chosen = nil unless categories.include?(chosen)
          # What she chose before for this merchant beats the reader's guess; if they disagree she is asked, not overruled.
          category_id = chosen || guess
          # Only spending carries a category; nothing else is shown or saved with one.
          category_id = nil unless self.class.expense?(event)
          overlaps = candidates.include?(event.id) ? overlaps_for(event, merchant, category_id) : []
          kind = classify(event, merchant, category_id, overlaps, accounts[event.financial_source_account_id], disagrees: chosen && guess && chosen != guess)
          Line.new(event: event, merchant: merchant, category_id: category_id, kind: kind, overlaps: overlaps, as_before: category_id.present? && guess.nil?,
            done: done?(heads[event.id]&.approved_version))
        end
      end

      # A row only counts as finished while its account is still the one it was approved against.
      def done?(version)
        return false unless version
        version.source_account_identity_version.source_account_review_head.approved_version_id == version.source_account_identity_version_id
      end

      def classify(event, merchant, category_id, overlaps, account, disagrees: false)
        return nil if event.row_kind == "informational"
        amount = event.signed_amount_cents
        return :unclear if event.row_kind != "posted" || event.event_type.in?(%w[unknown adjustment]) || amount.nil? || amount.zero? || event.posted_on.nil?
        return :unclear if event.posted_on > Date.current || outside_period?(event, account)
        return :unclear if event.event_type.in?(%w[purchase fee]) && !amount.negative? || event.event_type.in?(%w[refund income]) && !amount.positive?
        return :duplicate if overlaps.any?
        return :refund if event.event_type == "refund"
        return :transfer if event.event_type == "transfer"
        return :card_payment if event.event_type == "debt_payment"
        if self.class.expense?(event)
          return :unclear unless merchant && event.expense_projection_eligible? && event.expense_amount_cents == amount.abs &&
            HouseholdFinance::AnnualBudgetManager.supported_year?(event.posted_on.year)
          return :no_category unless category_id
          return :still_category if disagrees
        end
        nil
      end

      def outside_period?(event, account)
        return false unless account&.period_start_on && account.period_end_on
        !event.posted_on.between?(account.period_start_on, account.period_end_on)
      end

      # Two sources, kept apart: the reader's own guess (the expense it proposed for this line) and the category she
      # already chose for the same merchant on an earlier statement.
      def suggested_categories(events)
        drafts = household.transaction_drafts.where(financial_source_event_id: events.map(&:id)).includes(:transaction_draft_splits).order(:id)
        guesses = drafts.each_with_object({}) do |draft, result|
          result[draft.financial_source_event_id] = draft.budget_category_id || draft.transaction_draft_splits.map(&:budget_category_id).compact.uniq.then { |ids| ids.one? ? ids.first : nil }
        end
        previous = previous_choices(events.filter_map { |event| self.class.merchant_for(event) })
        earlier = events.to_h { |event| [ event.id, previous[merchant_key(self.class.merchant_for(event))] ] }
        [ guesses, earlier ]
      end

      # Same shop, different bank wording ("ZIPPYS DEDEDO #12" and "Zippy's") share one key.
      def merchant_key(merchant)
        FinancialDocuments::MerchantNormalizer.call(merchant)&.downcase&.squish
      end

      # What she chose for a merchant on any OTHER statement. This statement's own approvals are left out: they must not
      # change what an earlier line of the same statement looks like, or a retry of a save that already went through would
      # find its lines no longer matching what she was shown.
      def previous_choices(merchants)
        wanted = merchants.filter_map { |merchant| merchant_key(merchant) }.to_set
        return {} if wanted.empty?
        own = SourceReviewHead.where(household: household, financial_source_event_id: revision.financial_source_events.select(:id)).select(:id)
        history = SourceReviewVersion.where(household: household, disposition: "include").where.not(budget_category_id: nil).where.not(merchant: nil)
          .where.not(source_review_head_id: own)
        patterns = search_patterns(wanted)
        history = history.where("merchant ILIKE ANY (ARRAY[?])", patterns) if patterns
        latest = history.group(:merchant, :budget_category_id).maximum(:id)
        latest.sort_by { |_pair, id| id }.each_with_object({}) do |((merchant, category_id), _id), result|
          key = merchant_key(merchant)
          result[key] = category_id if wanted.include?(key)
        end
      end

      # A cheap first cut so the household's whole history is not normalised line by line: any merchant that normalises to
      # a wanted key still contains that key's first word. Falls back to no cut when a key has no plain ASCII word to match.
      def search_patterns(wanted)
        words = wanted.map { |key| key[/[a-z]{3,}/] }
        words.all? ? words.uniq.map { |word| "%#{word}%" } : nil
      end

      # Cheap pre-filter: only lines that share an amount and date with something
      # outside this statement can overlap, so only those pay for the full check.
      def overlap_candidates(events)
        keys = FinancialSourceEvent.where(household: household).where.not(financial_extraction_revision_id: revision.id)
          .where(signed_amount_cents: events.filter_map(&:signed_amount_cents).uniq).pluck(:signed_amount_cents, :posted_on).to_set
        events.select { |event| keys.include?([ event.signed_amount_cents, event.posted_on ]) }.map(&:id).to_set
      end

      def overlap_context = @overlap_context ||= OverlapDetector::Context.new(household)

      def overlaps_for(event, merchant, category_id)
        identity = overlap_context.accounts[event.financial_source_account_id]&.approved_version_id
        facts = self.class.facts_as_read(event, identity_id: identity, merchant: merchant, category_id: category_id)
        OverlapDetector.new(household, event, facts, context: overlap_context).call
      end
    end
  end
end
