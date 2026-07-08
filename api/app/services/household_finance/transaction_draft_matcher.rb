require "set"

module HouseholdFinance
  class TransactionDraftMatcher
    SEARCH_WINDOW_DAYS = 3
    MIN_CONFIDENCE = 0.74

    Result = Data.define(:transaction, :confidence, :reason)

    def initialize(draft)
      @draft = draft
      @household = draft.household
    end

    def call
      candidate_results.first(5).each do |result|
        next if result.confidence < MIN_CONFIDENCE

        draft.transaction_draft_matches.find_or_create_by!(household_transaction: result.transaction) do |match|
          match.status = "proposed"
          match.confidence = result.confidence
          match.match_reason = result.reason
          match.metadata = { "matched_by" => "transaction_draft_matcher_v1" }
        end
      end
      draft.transaction_draft_matches.proposed.best_first.to_a
    end

    private

    attr_reader :draft, :household

    def candidate_results
      candidates.filter_map do |transaction|
        confidence = confidence_for(transaction)
        next if confidence < MIN_CONFIDENCE

        Result.new(transaction: transaction, confidence: confidence, reason: reason_for(transaction, confidence))
      end.sort_by { |result| [ -result.confidence, (result.transaction.occurred_on - draft.occurred_on).abs, -result.transaction.id ] }
    end

    def candidates
      @candidates ||= household.household_transactions
        .includes(transaction_splits: :budget_category)
        .where(status: %w[confirmed reconciled])
        .where(occurred_on: (draft.occurred_on - SEARCH_WINDOW_DAYS)..(draft.occurred_on + SEARCH_WINDOW_DAYS))
        .where(total_amount_cents: amount_range)
        .to_a
    end

    def amount_range
      drift = [ (draft.total_amount_cents * 0.02).round, 100 ].max
      (draft.total_amount_cents - drift)..(draft.total_amount_cents + drift)
    end

    def confidence_for(transaction)
      amount_score = amount_score(transaction)
      date_score = date_score(transaction)
      merchant_score = merchant_score(transaction)
      category_score = category_score(transaction)

      ((amount_score * 0.42) + (date_score * 0.25) + (merchant_score * 0.25) + (category_score * 0.08)).round(2)
    end

    def amount_score(transaction)
      delta = (transaction.total_amount_cents - draft.total_amount_cents).abs
      return 1.0 if delta.zero?

      [ 0.0, 1.0 - (delta.to_f / [ draft.total_amount_cents, 1 ].max) ].max
    end

    def date_score(transaction)
      delta_days = (transaction.occurred_on - draft.occurred_on).abs.to_i
      return 1.0 if delta_days.zero?

      [ 0.0, 1.0 - (delta_days.to_f / (SEARCH_WINDOW_DAYS + 1)) ].max
    end

    def merchant_score(transaction)
      left = normalized(transaction.merchant)
      right = normalized(draft.merchant)
      return 0.4 if left.blank? || right.blank?
      return 1.0 if left == right
      return 0.88 if left.include?(right) || right.include?(left)

      overlap = token_overlap(left, right)
      overlap >= 0.5 ? overlap : 0.2
    end

    def category_score(transaction)
      return 0.5 if draft_category_ids.empty?

      transaction_category_ids = transaction.transaction_splits.map(&:budget_category_id).compact
      transaction_category_ids.intersect?(draft_category_ids) ? 1.0 : 0.25
    end

    def draft_category_ids
      @draft_category_ids ||= draft.transaction_draft_splits.map(&:budget_category_id).compact
    end

    def token_overlap(left, right)
      left_tokens = left.split.to_set
      right_tokens = right.split.to_set
      return 0.0 if left_tokens.empty? || right_tokens.empty?

      (left_tokens & right_tokens).length.to_f / [ left_tokens.length, right_tokens.length ].max
    end

    def reason_for(transaction, confidence)
      parts = []
      parts << "same amount" if transaction.total_amount_cents == draft.total_amount_cents
      parts << "same date" if transaction.occurred_on == draft.occurred_on
      parts << "similar merchant" if merchant_score(transaction) >= 0.8
      parts << "same category" if category_score(transaction) >= 1.0
      parts.presence&.to_sentence || "#{(confidence * 100).round}% match on amount, date, and merchant"
    end

    def normalized(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end
  end
end
