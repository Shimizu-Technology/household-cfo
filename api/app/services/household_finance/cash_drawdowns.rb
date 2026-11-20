module HouseholdFinance
  # Cash purchases paid from cash she already took out.
  #
  # Cash counts when it is withdrawn (Leon, 2026-11-19, decision 3): an approved ATM or branch withdrawal is spending in
  # the category she approved it with (her Cash category). A later purchase she says was paid from that cash names part
  # of it and adds nothing: its amount moves out of the withdrawal's category into the purchase's own categories, in the
  # month the cash was withdrawn, even when the purchase falls in a later month. A $100 withdrawal and a $40 cash lunch are
  # $100 of spending, $40 of it Dining and $60 still Cash.
  #
  # Budget, the spending report, Mia's spending analysis, Mia's category lookup and the scorecard all read these
  # drawdowns, so they cannot disagree about a month or a category.
  #
  # The link is her answer, saved on the purchase when she confirms it (metadata["cash_withdrawal"]). It is never made for
  # her. It counts only while both sides do: the purchase is confirmed, and the withdrawal is still an approved cash
  # withdrawal in her current picture with spending projected from it. Links never take more than the withdrawal: the
  # oldest links come first, and anything past the withdrawal's amount counts on its own. Reopening the purchase (or
  # re-reviewing the withdrawal) gives the cash back.
  class CashDrawdowns
    LINK_KEY = "cash_withdrawal".freeze
    COUNTED = %w[confirmed reconciled].freeze
    # How far back a withdrawal is offered: cash carries into later months, but not forever.
    LOOKBACK_DAYS = 92
    MAX_CANDIDATES = 3

    Drawdown = Struct.new(:purchase, :withdrawal, :amount_cents, :cash_parts, :purchase_parts, keyword_init: true) do
      def withdrawn_on = withdrawal.occurred_on
      def purchased_on = purchase.occurred_on
      def event_id = withdrawal.financial_source_event_id
    end
    Candidate = Struct.new(:withdrawal, :available_cents, keyword_init: true)

    def initialize(household)
      @household = household
    end

    def call
      @call ||= begin
        purchases = household.household_transactions.where(status: COUNTED, financial_source_event_id: nil)
          .where("household_transactions.metadata ? :key", key: LINK_KEY).includes(:transaction_splits).order(:id).to_a
        event_ids = purchases.filter_map { |purchase| link_event_id(purchase) }.uniq
        withdrawals = withdrawals_for(event_ids)
        used = Hash.new(0)
        purchases.filter_map do |purchase|
          event_id = link_event_id(purchase)
          withdrawal = withdrawals[event_id]
          next unless withdrawal && withdrawal.occurred_on <= purchase.occurred_on

          cents = [ purchase.metadata.dig(LINK_KEY, "amount_cents").to_i, purchase.total_amount_cents, withdrawal.total_amount_cents - used[event_id] ].min
          next unless cents.positive?

          cash_parts = RefundCredits.proportional(counted_parts(withdrawal), cents)
          purchase_parts = RefundCredits.proportional(counted_parts(purchase), cents)
          next if cash_parts.empty? || purchase_parts.empty?

          used[event_id] += cents
          Drawdown.new(purchase: purchase, withdrawal: withdrawal, amount_cents: cents, cash_parts: cash_parts, purchase_parts: purchase_parts)
        end
      end
    end

    def for_purchase(transaction) = transaction && call.find { |drawdown| drawdown.purchase.id == transaction.id }

    # { category_id => change in cents } for spending dated from..to. In the withdrawal's month the purchase's categories
    # gain what the withdrawal's category loses; in the purchase's own month the linked part no longer counts.
    def category_cents(from:, to:)
      range = from.to_date..to.to_date
      sums = Hash.new(0)
      call.each do |drawdown|
        if range.cover?(drawdown.withdrawn_on)
          drawdown.cash_parts.each { |part| sums[part[:category_id]] -= part[:amount_cents] }
          drawdown.purchase_parts.each { |part| sums[part[:category_id]] += part[:amount_cents] }
        end
        drawdown.purchase_parts.each { |part| sums[part[:category_id]] -= part[:amount_cents] } if range.cover?(drawdown.purchased_on)
      end
      sums.reject { |_id, cents| cents.zero? }
    end

    # The same by [category_id, budget period id], for Budget, which counts each transaction in its budget period.
    def by_category_and_period(periods)
      ids = periods.map(&:id).to_set
      sums = Hash.new(0)
      call.each do |drawdown|
        withdrawn = drawdown.withdrawal.budget_period_id
        if ids.include?(withdrawn)
          drawdown.cash_parts.each { |part| sums[[ part[:category_id], withdrawn ]] -= part[:amount_cents] }
          drawdown.purchase_parts.each { |part| sums[[ part[:category_id], withdrawn ]] += part[:amount_cents] }
        end
        purchased = drawdown.purchase.budget_period_id
        drawdown.purchase_parts.each { |part| sums[[ part[:category_id], purchased ]] -= part[:amount_cents] } if ids.include?(purchased)
      end
      sums.reject { |_key, cents| cents.zero? }
    end

    # Linked cash purchases dated from..to: they add nothing in their own month.
    def purchase_cents(from:, to:)
      range = from.to_date..to.to_date
      call.select { |drawdown| range.cover?(drawdown.purchased_on) }.sum(&:amount_cents)
    end

    # Withdrawals she could have paid a purchase on `on` from: approved, on or before that day (within LOOKBACK_DAYS),
    # with cash not yet named by another purchase. Most recent first.
    def candidates(on:)
      on = on.to_date
      withdrawals = withdrawals_for(nil, from: on - LOOKBACK_DAYS, to: on).values
      used = call.group_by(&:event_id).transform_values { |rows| rows.sum(&:amount_cents) }
      withdrawals.filter_map do |withdrawal|
        available = withdrawal.total_amount_cents - used.fetch(withdrawal.financial_source_event_id, 0)
        Candidate.new(withdrawal: withdrawal, available_cents: available) if available.positive? && counted_parts(withdrawal).any?
      end.sort_by { |candidate| [ -candidate.withdrawal.occurred_on.jd, -candidate.withdrawal.id ] }.first(MAX_CANDIDATES)
    end

    def candidate(event_id, on:) = candidates(on: on).find { |row| row.withdrawal.financial_source_event_id == event_id.to_i }

    # Saves her "Yes" on the purchase she is confirming: it names up to `cents` of that withdrawal's cash. Locks the
    # withdrawal so two purchases can't name the same cash at once. Raises when the withdrawal no longer has cash left.
    def self.link!(household, purchase, event_id:, cents:, user: nil)
      withdrawal = household.household_transactions.where(financial_source_event_id: event_id.to_i, status: COUNTED, source_type: "statement").order(:id).lock.first
      raise ArgumentError, "That cash withdrawal is no longer in your approved statements. Choose again." unless withdrawal

      candidate = new(household).candidate(event_id, on: purchase.occurred_on)
      raise ArgumentError, "That cash withdrawal has no cash left for this purchase. Choose again." unless candidate

      amount = [ cents.to_i, candidate.available_cents, purchase.total_amount_cents ].min
      raise ArgumentError, "This purchase has no cash to link." unless amount.positive?

      purchase.update!(metadata: purchase.metadata.to_h.merge(LINK_KEY => {
        "financial_source_event_id" => event_id.to_i, "amount_cents" => amount, "withdrawn_on" => candidate.withdrawal.occurred_on.iso8601,
        "linked_at" => Time.current.iso8601, "linked_by_user_id" => user&.id
      }.compact))
      amount
    end

    # What a purchase counts in Budget, by category.
    def counted_parts(transaction)
      transaction.transaction_splits.sort_by(&:id).select { |split| split.amount_cents.positive? && current_category_ids.include?(split.budget_category_id) }
        .map { |split| { category_id: split.budget_category_id, amount_cents: split.amount_cents } }
    end

    private

    attr_reader :household

    def link_event_id(purchase)
      value = purchase.metadata.to_h.dig(LINK_KEY, "financial_source_event_id")
      value.to_i if value.to_i.positive?
    end

    # { event id => counted withdrawal projection }: approved cash withdrawals in her current picture with spending
    # projected from them. Their projection says what the cash counts as in Budget.
    def withdrawals_for(event_ids, from: nil, to: nil)
      return {} if event_ids&.empty?

      versions = SourceReviewVersion
        .joins(source_review_head: { financial_source_event: :financial_extraction_revision }, source_account_identity_version: :source_account_review_head)
        .where(household_id: household.id, disposition: "include", event_type: "cash_withdrawal")
        .where("source_review_heads.approved_version_id = source_review_versions.id")
        .where("source_account_review_heads.approved_version_id = source_review_versions.source_account_identity_version_id")
        .where("source_review_versions.signed_amount_cents < 0").where.not(purchase_amount_cents: nil)
        .where(financial_extraction_revisions: { financial_document_import_id: household.financial_document_imports.current_picture.select(:id) })
      versions = versions.where(source_review_heads: { financial_source_event_id: event_ids }) if event_ids
      versions = versions.where(posted_on: from..to) if from && to
      events = versions.pluck("source_review_heads.financial_source_event_id").uniq
      return {} if events.empty?

      household.household_transactions.where(financial_source_event_id: events, status: COUNTED, source_type: "statement")
        .includes(:transaction_splits).order(:id).to_a.group_by(&:financial_source_event_id).transform_values(&:first)
    end

    def current_category_ids
      @current_category_ids ||= household.budget_categories.pluck(:id).to_set
    end
  end
end
