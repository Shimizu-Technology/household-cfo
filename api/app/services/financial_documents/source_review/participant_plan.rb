module FinancialDocuments
  module SourceReview
    # Sorts a statement's lines into "looks right" and the few that need the
    # participant's answer. The same plan drives what the review screen shows
    # and what "Approve the rest" is allowed to apply, so the two cannot drift.
    # Nothing here approves anything; unknown stays unknown and becomes a question.
    class ParticipantPlan
      # as_before: the category is only what she chose for this merchant on an earlier statement; the reader guessed nothing.
      # saved: the approved facts for a reopened income or uncategorized line, or a pending correction.
      # refund_to: for a refund whose purchase was found, the categories it goes back to (shown, never saved on the line).
      # purchase_match: a purchase she already confirmed (a receipt, chat, form or Plaid purchase) this bank line may be.
      Line = Struct.new(:event, :merchant, :category_id, :kind, :overlaps, :done, :as_before, :without_category, :saved, :expected_head, :refund_to, :purchase_match, :pair, keyword_init: true) do
        def ready? = kind.nil?
      end

      EXPENSE_TYPES = FinancialSourceEvent::EXPENSE_TYPES
      QUESTIONS = {
        correction: "Review your proposed correction.",
        unclear: "We couldn’t read this line clearly.",
        direction: "Was this money out or money in?",
        duplicate: "Is this the same charge as one you already have?",
        # Asked with the purchase: "Same purchase as your receipt from Payless on Aug 3 ($103.42)?"
        same_purchase: nil,
        person_payment: "Your own account or someone else?",
        money_in_source: "Money you earned or received, or your own money moving back?",
        person_payment_duplicate: "Is this the same payment, or a different one?",
        transfer_pair: "Do these two lines show money moved between your accounts?",
        transfer: "Did this move between your own accounts?",
        card_payment: "Is this a payment on your own card or loan?",
        refund: "Is this a refund?",
        # A refund goes back to the category of the purchase it refunds. When no purchase can be found she is asked.
        refund_category: "Which category does this refund go back to?",
        no_category: "What was this for?",
        # Asked with her own earlier category for the same merchant: "Still Dining out?"
        suggested_category: nil,
        still_category: nil
      }.freeze
      ANSWERS = {
        direction: [ { id: "money_out", label: "Money out" }, { id: "money_in", label: "Money in" } ],
        correction: [ { id: "edit", label: "Review correction" } ],
        unclear: [ { id: "edit", label: "Fix it" }, { id: "leave_out", label: "Leave it out" } ],
        duplicate: [ { id: "leave_out", label: "Same charge" }, { id: "different", label: "Different charge" } ],
        same_purchase: [ { id: "same_purchase", label: "Same purchase" }, { id: "different", label: "Different purchase" } ],
        person_payment_duplicate: [ { id: "leave_out", label: "Same payment" }, { id: "own_account", label: "Different payment — your own account" }, { id: "someone_else", label: "Different payment — someone else" } ],
        person_payment: [ { id: "own_account", label: "Your own account" }, { id: "someone_else", label: "Someone else" } ],
        money_in_source: [ { id: "someone_else", label: "Earned or received" }, { id: "own_account", label: "My own money moving back" }, { id: "edit", label: "Something else" } ],
        transfer_pair: [ { id: "pair_transfer", label: "Yes, pair them — not spending" }, { id: "edit", label: "Review separately" } ],
        transfer: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        card_payment: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        refund: [ { id: "as_read", label: "Yes" }, { id: "edit", label: "No" } ],
        refund_category: [ { id: "edit", label: "Choose one" }, { id: "leave_out", label: "Leave it out" } ],
        no_category: [ { id: "edit", label: "Choose one" }, { id: "leave_out", label: "Leave it out" } ],
        suggested_category: [ { id: "keep", label: "Yes" }, { id: "edit", label: "Change" } ],
        still_category: [ { id: "keep", label: "Yes" }, { id: "edit", label: "Change" } ]
      }.freeze
      # Answers that leave a line unfinished: it counts nowhere until the rest of its question is answered.
      UNFINISHED_REFERENCES = %w[unpaired-transfer: ownership-needed: overlap-cleared:].freeze
      # Payroll (including net pay), bonuses, benefits, pensions, tax refunds and interest are earned or received.
      EARNED_INCOME = /\b(?:payroll|net\s+pay|pay\s*check|salary|salaries|wages?|bonus(?:es)?|commissions?|stipend|direct\s+dep(?:osit)?|dir\s+dep|pension|annuity|social\s+security|soc\s+sec|ssa|ssi|ssdi|tax\s+ref(?:und)?|unemployment|benefits?|dividends?|interest)\b/i
      # Words that can mean her own money coming back from another account, a wallet or cash she put in.
      OWN_MONEY = /\b(?:cash|atm|branch|teller|mobile|remote|check|counter)\s+deposit\b|\bdeposit\s+(?:from|at)\b|\bfrom\s+(?:my\s+|own\s+)?(?:savings|checking|share|account|acct)\b|\btransfers?\b|\bown\b|\bpay\s*pal\b|\b(?:google|samsung|amazon)\s+pay\b|\bvenmo\b|\bcash\s*app\b|\bzelle\b|\bapple\s+(?:cash|pay)\b/i

      # unlinked_account_ids: accounts linked by the save in progress. Their copies are read as she saw them before the link.
      def initialize(household, revision, unlinked_account_ids: [], overlap_context: nil, accounts: nil)
        @household, @revision, @unlinked_account_ids = household, revision, unlinked_account_ids
        @overlap_context, @source_accounts = overlap_context, accounts
        @shared_overlap = overlap_context.present?
      end

      def lines
        @lines ||= build
      end

      attr_reader :review_heads

      def categories_for_save = @all_review_categories ||= household.budget_categories.ordered.to_a
      def accounts_for_save = @source_accounts

      def ready_ids = lines.select { |line| line.ready? && !line.done }.map { |line| line.event.id }
      # A saved purchase with no category counts nowhere, so it stays on her list as "What was this for?" until she picks one or leaves it out.
      def attention = lines.select { |line| line.without_category || !(line.ready? || line.done) }
      def category_lines
        attention.select { |line| !line.done && !review_heads[line.event.id]&.source_review_drafts&.any? { |draft| draft.status == "pending" } && line.kind.in?(%i[no_category suggested_category still_category]) && line.merchant.present? }
      end

      def category_groups
        category_lines.group_by { |line| merchant_key(line.merchant) }.values.flat_map { |group| group.each_slice(100).to_a }.select { |group| group.length > 1 }
      end

      # Only an unambiguous approved statement copy can share this answer.
      # Other guards take precedence even when overlap classification hid them.
      def repeated_lines
        return [] unless revision.financial_document_import&.document_kind == "statement"
        lines
        versions = (overlap_context.heads || {}).values.filter_map(&:approved_version)
        ActiveRecord::Associations::Preloader.new(records: versions, associations: [ { source_account_identity_version: :source_account_review_head }, { source_review_head: { financial_source_event: { financial_extraction_revision: :financial_document_import } } } ]).call
        claims = lines.flat_map { |line| line.overlaps.filter_map { |row| row[:approved_version_id] } }.tally
        lines.select do |line|
          next false if line.done || line.kind != :duplicate || line.purchase_match
          next false if review_heads[line.event.id]&.source_review_drafts&.any? { |draft| draft.status == "pending" }
          next false if self.class.ownership_question?(line.event, line.merchant)
          next false if line.event.event_type.in?(%w[transfer debt_payment]) && transfer_pairs.candidate(line.event)
          approved = line.overlaps.select { |row| row[:approved_version_id] }
          next false unless line.overlaps.one? && approved.one? && approved.first[:pending_draft_id].nil?
          next false unless claims[approved.first[:approved_version_id]] == 1
          match = overlap_context.heads[approved.first[:event_id]]&.approved_version
          own = overlap_context.accounts[line.event.financial_source_account_id]&.approved_version
          next false unless match && own && match.disposition == "include"
          next false unless match.financial_source_event.financial_extraction_revision.financial_document_import&.document_kind == "statement"
          next false unless match.source_account_identity_version.source_account_review_head.approved_version_id == match.source_account_identity_version_id
          start_on, end_on = match.source_account_identity_version.statement_facts.values_at("period_start_on", "period_end_on")
          next false unless start_on && end_on && line.event.posted_on&.between?(start_on.to_date, end_on.to_date)
          next false unless match.posted_on == line.event.posted_on || approved.first[:strength] == "strong"
          match.source_account_identity_version.source_tracked_account_id == own.source_tracked_account_id &&
            match.signed_amount_cents == line.event.signed_amount_cents &&
            match.posted_on && line.event.posted_on && (match.posted_on - line.event.posted_on).abs <= OverlapDetector::CROSS_FILE_DAYS &&
            merchant_key(line.merchant).present? && merchant_key(line.merchant) == merchant_key(match.merchant)
        end
      end

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
          # A refund keeps a category only when she was asked which one it goes back to.
          budget_category_id: expense || refund?(event) ? category_id : nil,
          overlap_disposition: informational ? "excluded" : "new",
          external_reference: nil
        }
      end

      def self.expense?(event)
        event.row_kind == "posted" && event.event_type.in?(EXPENSE_TYPES) && event.signed_amount_cents.to_i.negative?
      end

      # Money in read as income counts as income only when it plainly is pay, a benefit or interest. Anything that could be
      # her own money coming back ("ATM deposit", "Deposit from savings", "ACH credit PayPal", a deposit with no payer) is asked.
      def self.money_in_question?(event, merchant, event_type: event.event_type, amount: event.signed_amount_cents, row_kind: event.row_kind)
        return false unless row_kind == "posted" && event_type == "income" && amount.to_i.positive?
        text = [ merchant, event.financial_source_evidence&.payload&.dig("raw_description") ].compact.join(" ")
        !text.match?(EARNED_INCOME) || text.match?(OWN_MONEY)
      end

      # Old approvals remain immutable, but do not answer a newly required ownership question.
      def self.unanswered_money_in?(version)
        version.disposition == "include" && !version.external_reference.to_s.start_with?("received:") &&
          money_in_question?(version.financial_source_event, version.merchant, event_type: version.event_type, amount: version.signed_amount_cents, row_kind: "posted")
      end

      # Lines whose answer is whose money it was: a payment to or from a person, or money in that may be her own.
      def self.ownership_question?(event, merchant)
        TransferPairs.person_payment?(event, merchant) || TransferPairs.incoming_person_payment?(event, merchant) || money_in_question?(event, merchant)
      end

      def self.refund?(event)
        event.row_kind == "posted" && event.event_type == "refund" && event.signed_amount_cents.to_i.positive?
      end

      # The words she sees and approves. Long account numbers show as ····1234; the statement's own text stays stored as read.
      def self.merchant_for(event)
        payload = event.financial_source_evidence&.payload || {}
        AccountNumberMask.display(payload["merchant"].to_s.squish.presence || payload["raw_description"].to_s.squish.presence)
      end

      private

      attr_reader :household, :revision, :unlinked_account_ids

      def transfer_pairs
        @transfer_pairs ||= TransferPairs.new(household)
      end

      def everyday_policy
        @everyday_policy ||= HouseholdFinance::EverydaySpendingPolicy.new(household)
      end

      def review_categories
        @review_categories ||= categories_for_save.select(&:active?)
      end

      def build
        events = revision.financial_source_events.includes(:financial_source_evidence, financial_extraction_revision: :financial_document_import).order(:position, :id).to_a
        heads = SourceReviewHead.where(household: household, financial_source_event_id: events.map(&:id)).includes(:source_review_drafts, approved_version: { source_account_identity_version: :source_account_review_head }).index_by(&:financial_source_event_id)
        @review_heads = heads
        categories = review_categories.map(&:id).to_set
        suggestions, earlier = suggested_categories(events)
        accounts = @source_accounts ||= revision.financial_source_accounts.index_by(&:id)
        candidates = overlap_candidates(events)
        overlap_context.preload!(events, revision.financial_document_import&.checksum_sha256) if candidates.any?
        events.map do |event|
          merchant = self.class.merchant_for(event)
          if event.event_type == "cash_withdrawal"
            # Cash is a household category, never a merchant-policy guess or a new category.
            guess = review_categories.find { |category| category.name.casecmp?("Cash") }&.id
            default = policy = chosen = nil
          else
            guess = suggestions[event.id]
            guess = nil unless categories.include?(guess)
            default = guess ? nil : SavingsChallenge::Daily::ReviewCategories.suggestion(review_categories, merchant, event_type: event.event_type)
            guessed_category = review_categories.find { |category| category.id == guess }
            policy = everyday_policy.suggestion(merchant: merchant) if guessed_category.nil? || SavingsChallenge::Daily::ReviewCategories.broad?(guessed_category)
            if policy
              guess = policy[:category]&.id
              default = guess
            else
              guess ||= default
            end
            chosen = earlier[event.id]
            chosen = nil unless categories.include?(chosen)
          end
          # What she chose before for this merchant beats the reader's guess; if they disagree she is asked, not overruled.
          category_id = chosen || guess
          # Only spending carries a category; nothing else is shown or saved with one.
          category_id = nil unless self.class.expense?(event)
          overlaps = candidates.include?(event.id) ? overlaps_for(event, merchant, category_id) : []
          # Intermediate answers clear only the guard she answered; ownership remains unfinished.
          overlaps = [] if heads[event.id]&.approved_version&.external_reference.to_s.start_with?("overlap-cleared:", "ownership-needed:")
          purchase_match = purchase_matches.best(signed_amount_cents: event.signed_amount_cents, posted_on: event.posted_on, merchant: merchant, event_type: event.event_type, head_id: heads[event.id]&.id) unless heads[event.id]&.approved_version&.external_reference.to_s.start_with?("ownership-needed:")
          kind = classify(event, merchant, category_id, overlaps, accounts[event.financial_source_account_id], purchase_match: purchase_match, disagrees: chosen && guess && chosen != guess, confirm_suggestion: !chosen && default && policy&.dig(:reason) != "confirmed_spending_purpose" && !SavingsChallenge::Daily::ReviewCategories.broad?(review_categories.find { |category| category.id == default }))
          pair = transfer_pairs.candidate(event) if kind.in?(%i[transfer card_payment person_payment money_in_source]) && !heads[event.id]&.approved_version
          kind = :transfer_pair if pair && kind.in?(%i[transfer card_payment person_payment money_in_source])
          without_category = without_category?(heads[event.id]&.approved_version)
          # Saved with no category: show and ask exactly that, not the reader's earlier guess.
          kind, category_id = :no_category, nil if without_category
          # A retry compares the facts she actually saved, even if a later answer
          # in this same batch taught the store a different category.
          if done?(heads[event.id]&.approved_version) && !without_category
            kind = nil
            category_id = heads[event.id].approved_version.budget_category_id
          end
          kind = :money_in_source if !liability?(event, accounts[event.financial_source_account_id]) && heads[event.id]&.approved_version && self.class.unanswered_money_in?(heads[event.id].approved_version)
          pending = heads[event.id]&.source_review_drafts&.find { |draft| draft.status == "pending" }
          proposed = SourceReviewVersion.new(pending.facts) if pending
          kind, category_id = :correction, proposed.budget_category_id if pending
          Line.new(pair: pair, event: event, merchant: merchant, category_id: category_id, kind: kind, overlaps: overlaps, as_before: category_id.present? && chosen.present?,
            expected_head: { approved_version_id: heads[event.id]&.approved_version_id, lock_version: heads[event.id]&.lock_version || 0, account_version_id: overlap_context.accounts[event.financial_source_account_id]&.approved_version_id }.merge(pending ? { pending_digest: pending.digest } : {}),
            done: !pending && done?(heads[event.id]&.approved_version), without_category: without_category, saved: proposed || (heads[event.id]&.approved_version if without_category || kind == :money_in_source), purchase_match: purchase_match)
        end.tap { |lines| refund_lines!(lines, heads, earlier, categories) }
      end

      # A refund goes back to the category of the purchase it refunds (HouseholdFinance::RefundCredits). Before it is saved,
      # "Is this a refund?" names that category when the purchase can be found. Otherwise she is asked which category it goes
      # back to, with a category that came from her filled in for her tap: an earlier purchase from the same store on this
      # statement, else what she chose for this store before. A saved refund that counts nowhere stays on her list, like a
      # saved purchase with no category.
      def refund_lines!(lines, heads, earlier, categories)
        lines.each do |line|
          version = heads[line.event.id]&.approved_version
          if !line.kind.eql?(:correction) && done?(version) && version.disposition == "include" && version.event_type == "refund"
            next if refund_credits.for_version(version).counted?
            prefill = refund_prefill(line, lines, heads, earlier, categories, saved: version)
            line.kind, line.category_id, line.as_before, line.without_category, line.saved = :refund_category, prefill, prefill.present?, true, version
          elsif !line.done && line.kind == :refund
            original = refund_credits.same_store_original(line.merchant, line.event.posted_on)
            if original
              line.refund_to = refund_credits.counted_parts(original).pluck(:category_id).uniq
            else
              prefill = refund_prefill(line, lines, heads, earlier, categories)
              line.kind, line.category_id, line.as_before = :refund_category, prefill, prefill.present?
            end
          end
        end
      end

      def refund_prefill(line, lines, heads, earlier, categories, saved: nil)
        merchant = saved&.merchant.presence || line.merchant
        posted_on = saved&.posted_on || line.event.posted_on
        key = HouseholdFinance::RefundCredits.merchant_key(merchant)
        return unless key && posted_on
        # A line she already saved counts with the category she saved; one not saved yet with the category she is shown.
        category = lambda do |other|
          kept = heads[other.event.id]&.approved_version
          other.done && kept ? (kept.budget_category_id if kept.disposition == "include") : other.category_id
        end
        here = lines.select { |other| other.event.posted_on && other.event.posted_on <= posted_on && self.class.expense?(other.event) && category.call(other) && HouseholdFinance::RefundCredits.merchant_key(other.merchant) == key }
          .max_by { |other| [ other.event.posted_on, other.event.position.to_i ] }&.then(&category)
        id = here || (earlier[line.event.id] if merchant == line.merchant) || previous_choices([ merchant ])[merchant_key(merchant)]
        id if categories.include?(id)
      end

      def refund_credits = @refund_credits ||= HouseholdFinance::RefundCredits.new(household)

      # A row only counts as finished while its account is still the one it was approved against. A line saved as the same
      # purchase as one she confirmed stays finished only while that purchase still counts; otherwise it is asked about again.
      def done?(version)
        return false unless version
        return false if self.class.unanswered_money_in?(version)
        return false if version.external_reference.to_s.start_with?(*UNFINISHED_REFERENCES)
        return false if version.matched_transaction_id && !ConfirmedPurchaseMatch.current?(household, version)
        version.source_account_identity_version.source_account_review_head.approved_version_id == version.source_account_identity_version_id
      end

      def purchase_matches
        @purchase_matches ||= ConfirmedPurchaseMatch.new(household, dates: revision.financial_source_events.where(event_type: "purchase").where("signed_amount_cents < 0").pluck(:posted_on))
      end

      def without_category?(version)
        done?(version) && version.disposition == "include" && version.expense? && version.budget_category_id.nil?
      end

      def classify(event, merchant, category_id, overlaps, account, purchase_match: nil, disagrees: false, confirm_suggestion: false)
        return nil if event.row_kind == "informational"
        amount = event.signed_amount_cents
        if event.limitations.include?("transaction_direction_unclear") && HouseholdFinance::Money.document_cents(event.financial_source_evidence&.payload&.fetch("source_amount_text", nil), negative_as_magnitude: true).to_i.positive?
          return :direction
        end
        return :unclear if event.row_kind != "posted" || event.event_type.in?(%w[unknown adjustment]) || amount.nil? || amount.zero? || event.posted_on.nil?
        return :unclear if event.posted_on > Date.current || outside_period?(event, account)
        return :unclear if event.event_type.in?(%w[purchase fee]) && !amount.negative? || event.event_type.in?(%w[refund income]) && !amount.positive?
        person = TransferPairs.person_payment?(event, merchant) || TransferPairs.incoming_person_payment?(event, merchant)
        return ((person || self.class.money_in_question?(event, merchant)) && !purchase_match ? :person_payment_duplicate : :duplicate) if overlaps.any?
        return :same_purchase if purchase_match
        return :refund if event.event_type == "refund"
        return :person_payment if person
        # Money into a card or loan is a payment on it, never income.
        return :card_payment if event.event_type == "income" && liability?(event, account)
        return :money_in_source if self.class.money_in_question?(event, merchant)
        return :transfer if event.event_type == "transfer"
        return :card_payment if event.event_type == "debt_payment"
        if self.class.expense?(event)
          return :unclear unless merchant && event.expense_projection_eligible? && event.expense_amount_cents == amount.abs &&
            HouseholdFinance::AnnualBudgetManager.supported_year?(event.posted_on.year)
          # Before its category: if it is the purchase she already has, it needs none.
          return :same_purchase if purchase_match
          return :no_category unless category_id
          return :still_category if disagrees
          return :suggested_category if confirm_suggestion
        end
        nil
      end

      def liability?(event, account)
        basis = account&.account_basis
        basis = overlap_context.accounts[event.financial_source_account_id]&.approved_version&.source_tracked_account&.account_basis if basis.nil? || basis == "unknown"
        basis == "liability"
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

      # Current approved heads only, including this file. Superseded corrections and
      # excluded lines must never teach the next question an obsolete category.
      # A batch freezes its plan before any writes, so its own answers cannot
      # change the categories being validated halfway through that batch.
      def previous_choices(merchants)
        wanted = merchants.filter_map { |merchant| merchant_key(merchant) }.to_set
        return {} if wanted.empty?
        history = SourceReviewVersion.where(id: SourceReviewHead.where(household: household).select(:approved_version_id), disposition: "include")
          .where.not(budget_category_id: nil).where.not(merchant: nil)
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

      # A matching amount within the cross-file date window is enough to run
      # the full overlap check. Include dates from approved, pending and source
      # rows so the plan never offers a copy in "Approve the rest" by mistake.
      def overlap_candidates(events)
        amounts = events.filter_map(&:signed_amount_cents).uniq
        return Set.new if amounts.empty?
        others = FinancialSourceEvent.where(household: household).where(financial_extraction_revision_id: FinancialExtractionRevision.where("financial_document_import_id IS NOT NULL OR EXISTS (SELECT 1 FROM source_review_heads h JOIN financial_source_events e ON e.id = h.financial_source_event_id WHERE e.financial_extraction_revision_id = financial_extraction_revisions.id AND h.approved_version_id IS NOT NULL)").select(:id)).where.not(financial_extraction_revision_id: revision.id)
        heads = SourceReviewHead.where(household: household, financial_source_event_id: others.select(:id))
        keys = others.where(signed_amount_cents: amounts).pluck(:signed_amount_cents, :posted_on).to_set { |amount, day| [ amount, day.to_s ] }
        SourceReviewVersion.where(id: heads.pluck(:approved_version_id).compact, signed_amount_cents: amounts).pluck(:signed_amount_cents, :posted_on).each { |amount, day| keys << [ amount, day.to_s ] }
        SourceReviewDraft.where(household: household, source_review_head_id: heads.select(:id)).pending.pluck(:facts).each do |facts|
          keys << [ facts["signed_amount_cents"], facts["posted_on"].to_s ] if amounts.include?(facts["signed_amount_cents"])
        end
        window = OverlapDetector::CROSS_FILE_DAYS
        by_amount = events.filter_map do |event|
          amount, day = event.signed_amount_cents, event.posted_on
          next unless amount && day

          event.id if (-window..window).any? { |offset| keys.include?([ amount, (day + offset).iso8601 ]) }
        end.to_set
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

      def overlap_context = @overlap_context ||= OverlapDetector::Context.new(household, excluded_revision_id: revision.id)

      def overlaps_for(event, merchant, category_id)
        identity = overlap_context.accounts[event.financial_source_account_id]&.approved_version_id
        facts = self.class.facts_as_read(event, identity_id: identity, merchant: merchant, category_id: category_id)
        OverlapDetector.new(household, event, facts, context: overlap_context, unlinked: unlinked_account_ids.include?(event.financial_source_account_id)).call
      end
    end
  end
end
