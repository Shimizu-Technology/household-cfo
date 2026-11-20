module FinancialDocuments
  module SourceReview
    # A statement purchase she may already have counted: a receipt, chat, check-in, form or Plaid purchase she
    # confirmed before the bank line was approved. OverlapDetector compares statement lines with each other; this
    # compares a bank line with her confirmed purchases that did not come from a statement.
    #
    # It only finds the question ("Same purchase as your receipt from Payless on Aug 3 ($103.42)?"). Nothing is
    # merged or counted twice until she answers: "Same purchase" saves the line as a match to that purchase, which
    # keeps counting as she confirmed it (her receipt's categories win); "Different purchase" counts the line too.
    class ConfirmedPurchaseMatch
      WINDOW_DAYS = 3
      MIN_SCORE = 0.74
      COUNTED = %w[confirmed reconciled].freeze
      RECEIPT_SOURCES = %w[receipt screenshot].freeze

      Match = Data.define(:transaction, :score) do
        def question
          day = transaction.occurred_on.strftime("%b %-d")
          amount = ActiveSupport::NumberHelper.number_to_currency(HouseholdFinance::Money.dollars(transaction.total_amount_cents))
          name = AccountNumberMask.display(transaction.merchant)
          question = if transaction.source_type.in?(RECEIPT_SOURCES)
            "Same purchase as your receipt from #{name} on #{day} (#{amount})?"
          else
            "Same purchase as #{name} on #{day} (#{amount}), already in your spending?"
          end
          [ question, cash_note ].compact.join(" ")
        end

        # A purchase she logged as cash: Same purchase says it went on this card instead (CashPayment.paid_by_card!).
        def cash_note
          link = transaction.metadata.to_h[HouseholdFinance::CashDrawdowns::LINK_KEY]
          taken = link.is_a?(Hash) && link["withdrawn_on"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(link["withdrawn_on"]) : nil
          return "If it is, it went on this card, so it no longer counts as paid from the cash you took out on #{taken.strftime('%b %-d')}." if taken
          return unless transaction.transaction_drafts.any? { |draft| HouseholdFinance::CashPayment.paid_in_cash?(draft) }

          "If it is, it went on this card, not in cash."
        end

        def summary
          { transaction_id: transaction.id, merchant: AccountNumberMask.display(transaction.merchant), occurred_on: transaction.occurred_on.iso8601,
            amount_cents: transaction.total_amount_cents, source_type: transaction.source_type,
            categories: transaction.transaction_splits.sort_by(&:id).filter_map { |split| split.budget_category&.name }.uniq }
        end
      end

      # Only a purchase can be one she logged herself; fees, interest and cash withdrawals are not.
      def self.applies?(event_type, signed_amount_cents)
        event_type.to_s == "purchase" && signed_amount_cents.to_i.negative?
      end

      # dates: the posted dates about to be checked, so a whole statement reads her purchases once.
      def initialize(household, dates: [])
        @household = household
        days = Array(dates).compact.map(&:to_date)
        @range = (days.min - WINDOW_DAYS)..(days.max + WINDOW_DAYS) if days.any?
      end

      # head_id: the line being checked. Its own saved match does not hide the purchase from it.
      def best(signed_amount_cents:, posted_on:, merchant:, event_type: "purchase", head_id: nil)
        candidates(signed_amount_cents: signed_amount_cents, posted_on: posted_on, merchant: merchant, event_type: event_type, head_id: head_id).first
      end

      def candidates(signed_amount_cents:, posted_on:, merchant:, event_type: "purchase", head_id: nil)
        return [] unless self.class.applies?(event_type, signed_amount_cents) && posted_on.present?

        day = posted_on.to_date
        amount = signed_amount_cents.to_i.abs
        pool_for(day).filter_map do |transaction|
          next unless (transaction.occurred_on - day).abs <= WINDOW_DAYS
          next unless match_amounts.fetch(transaction.id) == amount
          next if claimed.fetch(transaction.id, []).any? { |claimer| claimer != head_id }

          score = score(transaction, day, merchant)
          Match.new(transaction: transaction, score: score) if score >= MIN_SCORE
        end.sort_by { |match| [ -match.score, (match.transaction.occurred_on - day).abs, match.transaction.id ] }
      end

      # Still the same purchase she said it was: counted, not from a statement, and not taken by another line.
      def self.current?(household, version)
        transaction = household.household_transactions.find_by(id: version.matched_transaction_id)
        return false unless transaction && transaction.status.in?(COUNTED) && transaction.financial_source_event_id.nil? && transaction.source_type != "statement"

        SourceReviewVersion.joins(:source_review_head).where(household: household, matched_transaction_id: transaction.id)
          .where("source_review_heads.approved_version_id = source_review_versions.id")
          .where.not(source_review_head_id: version.source_review_head_id).none?
      end

      private

      attr_reader :household

      def pool_for(day)
        if @range&.cover?(day - WINDOW_DAYS) && @range.cover?(day + WINDOW_DAYS)
          @pool ||= read_pool(@range)
        else
          read_pool((day - WINDOW_DAYS)..(day + WINDOW_DAYS))
        end
      end

      def read_pool(range)
        # A statement purchase is never one she confirmed herself, even one whose source line link is missing.
        household.household_transactions.where(status: COUNTED, financial_source_event_id: nil, occurred_on: range).where.not(source_type: "statement")
          .includes(:transaction_drafts, transaction_splits: :budget_category).order(:id).to_a.tap { |rows| remember(rows) }
      end

      def remember(rows)
        @match_amounts ||= {}
        rows.each { |row| @match_amounts[row.id] ||= HouseholdFinance::ReceiptTenders.transaction_match_amount_cents(row, row.transaction_drafts) }
        ids = rows.map(&:id) - claimed.keys
        return if ids.empty?

        SourceReviewVersion.joins(:source_review_head).where(household: household, matched_transaction_id: ids)
          .where("source_review_heads.approved_version_id = source_review_versions.id")
          .pluck(:matched_transaction_id, :source_review_head_id).each { |id, head| claimed[id] = claimed.fetch(id, []) + [ head ] }
        ids.each { |id| claimed[id] ||= [] }
      end

      def match_amounts = @match_amounts ||= {}
      def claimed = @claimed ||= {}

      # The amount is equal, so this weighs the day and the store like TransactionDraftMatcher, with the category
      # left neutral: the same day is enough on its own, a day or more apart needs a similar store name.
      def score(transaction, day, merchant)
        days = (transaction.occurred_on - day).abs.to_i
        date = days.zero? ? 1.0 : [ 0.0, 1.0 - (days.to_f / (WINDOW_DAYS + 1)) ].max
        (0.42 + (date * 0.25) + (HouseholdFinance::MerchantMatchScore.call(transaction.merchant, merchant) * 0.25) + 0.04).round(2)
      end
    end
  end
end
