module FinancialDocuments
  module SourceReview
    # Sorts a statement's lines into "looks right" and the few that need the
    # participant's answer. The same plan drives what the review screen shows
    # and what "Approve the rest" is allowed to apply, so the two cannot drift.
    # Nothing here approves anything; unknown stays unknown and becomes a question.
    class ParticipantPlan
      # as_before: the category is only what she chose for this merchant on an earlier statement; the reader guessed nothing.
      Line = Struct.new(:event, :merchant, :category_id, :kind, :overlaps, :done, :as_before, :without_category, :expected_head, keyword_init: true) do
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
        suggested_category: nil,
        still_category: nil
      }.freeze
      ANSWERS = {
        unclear: [ { id: "edit", label: "Fix it" }, { id: "leave_out", label: "Leave it out" } ],
        duplicate: [ { id: "leave_out", label: "Same charge" }, { id: "different", label: "Different charge" } ],
        transfer: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        card_payment: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        refund: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        no_category: [ { id: "edit", label: "Choose one" }, { id: "leave_out", label: "Leave it out" } ],
        suggested_category: [ { id: "keep", label: "Yes" }, { id: "edit", label: "Change" } ],
        still_category: [ { id: "keep", label: "Yes" }, { id: "edit", label: "Change" } ]
      }.freeze

      # unlinked_account_ids: accounts linked by the save in progress. Their copies are read as she saw them before the link.
      def initialize(household, revision, unlinked_account_ids: [])
        @household, @revision, @unlinked_account_ids = household, revision, unlinked_account_ids
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

      attr_reader :household, :revision, :unlinked_account_ids

      def review_categories
        @review_categories ||= household.budget_categories.active.ordered.to_a
      end

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
          default = guess ? nil : SavingsChallenge::Daily::ReviewCategories.suggestion(review_categories, merchant, event_type: event.event_type)
          guess ||= default
          chosen = earlier[event.id]
          chosen = nil unless categories.include?(chosen)
          # What she chose before for this merchant beats the reader's guess; if they disagree she is asked, not overruled.
          category_id = chosen || guess
          # Only spending carries a category; nothing else is shown or saved with one.
          category_id = nil unless self.class.expense?(event)
          overlaps = candidates.include?(event.id) ? overlaps_for(event, merchant, category_id) : []
          kind = classify(event, merchant, category_id, overlaps, accounts[event.financial_source_account_id], disagrees: chosen && guess && chosen != guess)
          Line.new(event: event, merchant: merchant, category_id: category_id, kind: kind, overlaps: overlaps, as_before: category_id.present? && (guess.nil? || (chosen.present? && guess == default)),
            expected_head: { approved_version_id: heads[event.id]&.approved_version_id, lock_version: heads[event.id]&.lock_version || 0 },
            done: done?(heads[event.id]&.approved_version), without_category: without_category?(heads[event.id]&.approved_version))
        end
      end

      # A row only counts as finished while its account is still the one it was approved against.
      def done?(version)
        return false unless version
        version.source_account_identity_version.source_account_review_head.approved_version_id == version.source_account_identity_version_id
      end

      def without_category?(version)
        done?(version) && version.disposition == "include" && version.expense? && version.budget_category_id.nil?
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

      # Cheap pre-filter: only lines that share an amount and date with something outside this statement can overlap, so only
      # those pay for the full check. OverlapDetector compares against what an earlier line is now (her approved version, else
      # a pending edit, else the statement as read), so the keys here come from all three; a missed key would show a copy as
      # "looks right" and then refuse it when she approves. Extra keys only cost a full check.
      def overlap_candidates(events)
        amounts = events.filter_map(&:signed_amount_cents).uniq
        return Set.new if amounts.empty?
        others = FinancialSourceEvent.where(household: household).where.not(financial_extraction_revision_id: revision.id)
        heads = SourceReviewHead.where(household: household, financial_source_event_id: others.select(:id))
        keys = others.where(signed_amount_cents: amounts).pluck(:signed_amount_cents, :posted_on).to_set { |amount, day| [ amount, day.to_s ] }
        SourceReviewVersion.where(id: heads.select(:approved_version_id), signed_amount_cents: amounts).pluck(:signed_amount_cents, :posted_on).each { |amount, day| keys << [ amount, day.to_s ] }
        SourceReviewDraft.where(household: household, source_review_head_id: heads.select(:id)).pending.pluck(:facts).each do |facts|
          keys << [ facts["signed_amount_cents"], facts["posted_on"].to_s ] if amounts.include?(facts["signed_amount_cents"])
        end
        by_amount = events.select { |event| keys.include?([ event.signed_amount_cents, event.posted_on.to_s ]) }.map(&:id).to_set
        by_amount | same_physical_rows(events, others, heads)
      end

      # OverlapDetector treats the same file and physical row as a strong match whatever the amounts now say (she may have
      # edited the earlier line), so those lines must reach the full check too.
      def same_physical_rows(events, others, heads)
        artifact = revision.financial_document_import&.checksum_sha256
        return Set.new if artifact.blank?
        from_file = others.joins(financial_extraction_revision: :financial_document_import)
          .where(financial_document_imports: { checksum_sha256: artifact }).pluck(:locator)
        approved_ids = SourceReviewVersion.where(id: heads.select(:approved_version_id), source_artifact_digest: artifact)
          .joins(source_review_head: :financial_source_event).pluck("financial_source_events.locator")
        locators = (from_file + approved_ids).compact.to_set
        events.select { |event| event.locator.present? && event.locator["row"].to_i.positive? && locators.include?(event.locator) }.map(&:id).to_set
      end

      def overlap_context = @overlap_context ||= OverlapDetector::Context.new(household)

      def overlaps_for(event, merchant, category_id)
        identity = overlap_context.accounts[event.financial_source_account_id]&.approved_version_id
        facts = self.class.facts_as_read(event, identity_id: identity, merchant: merchant, category_id: category_id)
        OverlapDetector.new(household, event, facts, context: overlap_context, unlinked: unlinked_account_ids.include?(event.financial_source_account_id)).call
      end
    end
  end
end
