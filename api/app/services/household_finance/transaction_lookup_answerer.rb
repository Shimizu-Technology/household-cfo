module HouseholdFinance
  class TransactionLookupAnswerer
    FOOD_TERMS = /\b(food|eat|ate|dining|restaurant|restaurants|takeout|coffee|cafe|grocer(?:y|ies)?)\b/i
    LOOKUP_TERMS = /\b(how many|how much|what|show|find|search|list|total|did i|did we)\b/i
    BANK_SUMMARY_TERMS = /\b(?:summari[sz]e|summary|latest|recent|most recent)\b/i
    PLANNED_TERMS = /\b(set aside|budget(?:ed)?|planned|available|allowance|left|remaining)\b/i
    BANK_ACTIVITY_TERMS = /\b(?:bank|plaid|synced|account activity|bank activity|bank feed)\b/i
    ALL_BANK_ACTIVITY_TERMS = /\b(?:across|all|entire)\b.*\b(?:bank|plaid|synced|account activity|bank activity|bank feed)\b/i
    TOP_MERCHANT_TERMS = /\b(?:top|largest|highest|biggest)\s+(?:merchant|merchants|payee|payees)\b/i

    def self.bank_activity_question?(value)
      message = value.to_s.downcase.squish
      message.match?(BANK_ACTIVITY_TERMS) && (message.match?(LOOKUP_TERMS) || message.match?(BANK_SUMMARY_TERMS))
    end

    def initialize(household, message, today: Date.current)
      @household = household
      @message = message.to_s.downcase.squish
      @today = today
    end

    def call
      return nil unless lookup_like?

      target = lookup_target
      return nil unless target

      return build_merchant_comparison_answer(target.fetch(:labels)) if target.fetch(:type) == :merchant_comparison
      return build_bank_summary_answer if target.fetch(:type) == :bank_summary

      transactions = matching_transactions(target)
      build_answer(target, transactions)
    end

    private

    attr_reader :household, :message, :today

    def lookup_like?
      return false if message.match?(PLANNED_TERMS) && !message.match?(/\b(actuals?|transactions?|spent|spend)\b/i)

      message.match?(LOOKUP_TERMS) || self.class.bank_activity_question?(message)
    end

    def lookup_target
      return nil if external_cost_question?

      exact_category_target || merchant_comparison_target || merchant_target || food_category_target || bank_summary_target
    end

    def external_cost_question?
      message.match?(/\b(?:usually|typical|typically|average|current|rate|fee|fees)\b/i) &&
        message.match?(/\b(?:cost|costs|rate|fee|fees|price)\b/i) &&
        !message.match?(/\b(?:spend|spent|paid|confirmed|actual|transaction)\b/i)
    end

    def exact_category_target
      lookup_categories.each do |category|
        normalized_name = normalize(category.name)
        return { type: :category, label: category_label(category), category_ids: [ category.id ] } if normalized_name.present? && normalized_message.include?(normalized_name)
      end

      nil
    end

    def food_category_target
      return unless message.match?(FOOD_TERMS)

      food_categories = lookup_categories.select { |category| category.name.match?(FOOD_TERMS) }
      return if food_categories.empty?

      { type: :category, label: "food-like categories", category_ids: food_categories.map(&:id) }
    end

    def merchant_comparison_target
      return unless message.match?(/\b(more|less|compare|versus|vs\.?|or)\b/i)

      matches = known_merchants.select { |merchant| normalized_message.include?(normalize(merchant)) }.first(4)
      return if matches.length < 2

      { type: :merchant_comparison, labels: matches }
    end

    def merchant_target
      known_merchant = known_merchants.find do |merchant|
        normalized_merchant = normalize(merchant)
        normalized_merchant.present? && normalized_message.include?(normalized_merchant)
      end
      return { type: :merchant, label: known_merchant } if known_merchant.present?

      extracted = message.match(/\b(?:at|from)\s+([a-z0-9'&.\-\s]+?)(?:\s+(?:this|last|in|for|during|between|from|and how|how much|how many)|[?.!]|$)/i)&.[](1)&.squish
      extracted = extracted&.gsub(/\b(today|yesterday)\b/i, "")&.squish
      return if extracted.blank? || extracted.length > 80 || generic_bank_source_label?(extracted)

      { type: :merchant, label: extracted }
    end

    def bank_summary_target
      return unless message.match?(BANK_ACTIVITY_TERMS)

      { type: :bank_summary, label: "synced bank activity" }
    end

    def matching_transactions(target)
      transactions = base_transactions
      transactions = transactions.select { |transaction| merchant_matches?(transaction.merchant, target.fetch(:label)) } if target.fetch(:type) == :merchant
      transactions = transactions.select { |transaction| transaction_category_ids(transaction).intersect?(target.fetch(:category_ids)) } if target.fetch(:type) == :category
      transactions
    end

    def build_answer(target, transactions)
      return build_merchant_answer(target, transactions) if target.fetch(:type) == :merchant

      total_cents = transactions.sum { |transaction| amount_cents_for(transaction, target) }
      count = transactions.length
      label = target.fetch(:label)
      category_line = category_breakdown(transactions, target)
      merchant_line = merchant_breakdown(transactions, target)

      if count.zero?
        return "For #{period_label}, based on confirmed transactions, I do not see confirmed #{label} spending yet. Pending drafts are not counted until you confirm them."
      end

      noun = "transaction".pluralize(count)
      lines = [
        "For #{period_label}, based on confirmed transactions, I found #{count} confirmed #{label} #{noun} totaling #{money(total_cents)}.",
        category_line,
        merchant_line,
        "Pending drafts are not counted until you confirm them."
      ]
      lines.compact.join("\n\n")
    end

    def build_merchant_answer(target, transactions)
      label = target.fetch(:label)
      observed = matching_bank_transactions(label, pending: false)
      bank_pending = matching_bank_transactions(label, pending: true)
      needs_review = observed.select { |transaction| needs_household_review?(transaction) }
      confirmed_total = transactions.sum(&:total_amount_cents)
      observed_total = observed.sum(&:amount_cents)

      lines = [
        "For #{period_label}, your synced bank activity shows #{observed.length} posted #{label} #{'transaction'.pluralize(observed.length)} totaling #{money(observed_total)}.",
        "Based on confirmed transactions, I found #{transactions.length} confirmed #{label} #{'transaction'.pluralize(transactions.length)} totaling #{money(confirmed_total)}.",
        category_breakdown(transactions, target),
        "#{needs_review.length} posted #{label} #{'transaction'.pluralize(needs_review.length)} totaling #{money(needs_review.sum(&:amount_cents))} still #{needs_review.length == 1 ? 'needs' : 'need'} household review before categorization is final.",
        bank_pending.any? ? "#{bank_pending.length} bank-pending #{label} #{'transaction'.pluralize(bank_pending.length)} totaling #{money(bank_pending.sum(&:amount_cents))} #{bank_pending.length == 1 ? 'is' : 'are'} shown separately and excluded from posted spending." : "No bank-pending #{label} transactions are waiting in this period."
      ]
      lines.compact.join("\n\n")
    end

    def build_merchant_comparison_answer(labels)
      summaries = labels.map do |label|
        transactions = base_transactions.select { |transaction| merchant_matches?(transaction.merchant, label) }
        observed = matching_bank_transactions(label, pending: false)
        { label: label, count: transactions.length, cents: transactions.sum(&:total_amount_cents), observed_count: observed.length, observed_cents: observed.sum(&:amount_cents) }
      end
      winner = if summaries.any? { |summary| summary.fetch(:observed_cents).positive? }
        summaries.max_by { |summary| summary.fetch(:observed_cents) }
      else
        summaries.max_by { |summary| summary.fetch(:cents) }
      end
      winner_amount = summaries.any? { |summary| summary.fetch(:observed_cents).positive? } ? winner.fetch(:observed_cents) : winner.fetch(:cents)
      details = summaries.map do |summary|
        "#{summary.fetch(:label)} #{money(summary.fetch(:cents))} confirmed / #{money(summary.fetch(:observed_cents))} bank-observed"
      end.to_sentence

      "For #{period_label}, #{winner.fetch(:label)} is higher at #{money(winner_amount)}. Comparison: #{details}. Bank-observed and confirmed totals are separated so unreviewed activity is not presented as finalized budget truth."
    end

    def build_bank_summary_answer
      posted = base_bank_transactions.reject(&:pending?)
      pending = base_bank_transactions.select(&:pending?)
      inflows = posted.select { |transaction| transaction.amount_cents.negative? }
      outflows = posted.select { |transaction| transaction.amount_cents.positive? }
      needs_review = outflows.select { |transaction| needs_household_review?(transaction) }
      confirmed = household.household_transactions.where(source_type: "plaid", status: %w[confirmed reconciled], occurred_on: start_on..end_on)

      [
        "For #{period_label}, synced bank activity shows #{outflows.length} posted outflows totaling #{money(outflows.sum(&:amount_cents))} and #{inflows.length} inflows totaling #{money(inflows.sum { |transaction| transaction.amount_cents.abs })}.",
        recent_outflow_line(outflows),
        top_bank_merchants_line(outflows),
        "Confirmed Plaid-derived household actuals total #{money(confirmed.sum(:total_amount_cents))} across #{confirmed.count} #{'transaction'.pluralize(confirmed.count)}.",
        "#{needs_review.length} posted outflows totaling #{money(needs_review.sum(&:amount_cents))} still need household review or source reconciliation.",
        "#{pending.length} bank-pending #{'transaction'.pluralize(pending.length)} #{pending.length == 1 ? 'is' : 'are'} tracked separately and excluded from posted totals."
      ].compact.join("\n\n")
    end

    def recent_outflow_line(outflows)
      return unless message.match?(/\b(?:latest|recent|most recent)\b/i)
      return "There is no posted outflow in this period." if outflows.empty?

      transaction = outflows.first
      merchant = transaction.merchant_name.presence || transaction.name
      review_state = if needs_household_review?(transaction)
        "It still needs household review and is not included in confirmed budget actuals."
      else
        "Its linked review is already resolved."
      end
      "Most recent posted outflow: #{merchant} for #{money(transaction.amount_cents)} on #{transaction.occurred_on.strftime('%b %-d, %Y')}. #{review_state}"
    end

    def top_bank_merchants_line(outflows)
      return unless message.match?(TOP_MERCHANT_TERMS)
      return "There are no posted outflow merchants in this period." if outflows.empty?

      breakdown = Hash.new { |hash, key| hash[key] = { cents: 0, count: 0 } }
      outflows.each do |transaction|
        merchant = transaction.merchant_name.presence || transaction.name
        breakdown[merchant][:cents] += transaction.amount_cents
        breakdown[merchant][:count] += 1
      end
      merchants = breakdown.sort_by { |merchant, values| [ -values.fetch(:cents), merchant.to_s.downcase ] }.first(3).map do |merchant, values|
        "#{merchant} — #{money(values.fetch(:cents))} (#{values.fetch(:count)} #{'transaction'.pluralize(values.fetch(:count))})"
      end

      "Top merchants by posted outflow: #{merchants.join('; ')}."
    end

    def category_breakdown(transactions, target)
      return if target.fetch(:type) == :category

      breakdown = Hash.new(0)
      transactions.each do |transaction|
        lookup_splits(transaction).each { |split| breakdown[category_label(split.budget_category)] += split.amount_cents }
      end
      return if breakdown.empty?

      "Categories: #{breakdown.sort_by { |_name, cents| -cents }.map { |name, cents| "#{name} #{money(cents)}" }.to_sentence}."
    end

    def merchant_breakdown(transactions, target)
      return if target.fetch(:type) == :merchant

      breakdown = Hash.new { |hash, key| hash[key] = { cents: 0, count: 0 } }
      transactions.each do |transaction|
        breakdown[transaction.merchant][:cents] += amount_cents_for(transaction, target)
        breakdown[transaction.merchant][:count] += 1
      end
      return if breakdown.empty?

      top_merchants = breakdown.sort_by { |_merchant, values| -values.fetch(:cents) }.first(3).map do |merchant, values|
        "#{merchant} #{money(values.fetch(:cents))} (#{values.fetch(:count)} #{'time'.pluralize(values.fetch(:count))})"
      end
      "Top merchants: #{top_merchants.to_sentence}."
    end

    def amount_cents_for(transaction, target)
      return transaction.total_amount_cents if target.fetch(:type) == :merchant

      lookup_splits(transaction)
        .select { |split| target.fetch(:category_ids).include?(split.budget_category_id) }
        .sum(&:amount_cents)
    end

    def merchant_matches?(merchant, target_label)
      normalize(merchant).include?(normalize(target_label)) || normalize(target_label).include?(normalize(merchant))
    end

    def generic_bank_source_label?(value)
      normalize(value).match?(/\A(?:my|our|the)?(?:connected|linked|synced)?(?:bank)?accounts?\z/)
    end

    def lookup_splits(transaction)
      transaction.transaction_splits.select(&:budget_category)
    end

    def transaction_category_ids(transaction)
      lookup_splits(transaction).map(&:budget_category_id)
    end

    def known_merchants
      @known_merchants ||= (base_transactions.map(&:merchant) + base_bank_transactions.map { |transaction| transaction.merchant_name.presence || transaction.name }).compact.uniq
    end

    def base_transactions
      @base_transactions ||= household.household_transactions
        .includes(transaction_splits: :budget_category)
        .joins(transaction_splits: :budget_category)
        .where(status: %w[confirmed reconciled], occurred_on: start_on..end_on)
        .distinct
        .order(occurred_on: :desc, created_at: :desc)
        .to_a
    end

    def base_bank_transactions
      @base_bank_transactions ||= household.plaid_transactions.visible
        .includes(transaction_draft: :confirmed_transaction)
        .where(occurred_on: start_on..end_on)
        .order(occurred_on: :desc, created_at: :desc)
        .to_a
    end

    def matching_bank_transactions(label, pending:)
      base_bank_transactions.select do |transaction|
        transaction.pending? == pending && transaction.amount_cents.positive? && merchant_matches?(transaction.merchant_name.presence || transaction.name, label)
      end
    end

    def needs_household_review?(transaction)
      draft = transaction.transaction_draft
      source_changed = transaction.drafted_source_fingerprint.present? && transaction.source_fingerprint != transaction.drafted_source_fingerprint
      return true if source_changed
      return false if transaction.review_status == "ignored" || draft&.status == "ignored"

      draft.nil? || draft.pending?
    end

    def lookup_categories
      @lookup_categories ||= household.budget_categories.ordered.to_a
    end

    def category_label(category)
      return "Uncategorized" unless category

      category.active? ? category.name : "#{category.name} (archived)"
    end

    def range
      @range ||= all_bank_activity_range || SpendingReportQuery.new(message, today: today).range || { start_on: today.beginning_of_month, end_on: today }
    end

    def all_bank_activity_range
      return unless message.match?(ALL_BANK_ACTIVITY_TERMS)

      dates = [
        household.plaid_transactions.visible.minimum(:occurred_on),
        household.household_transactions.minimum(:occurred_on)
      ].compact
      { start_on: dates.min || today.beginning_of_month, end_on: [ dates.max, today ].compact.max }
    end

    def start_on
      range.fetch(:start_on)
    end

    def end_on
      range.fetch(:end_on)
    end

    def period_label
      return "all available bank history" if message.match?(ALL_BANK_ACTIVITY_TERMS)
      return start_on.strftime("%b %-d, %Y") if start_on == end_on

      if start_on == start_on.beginning_of_month && end_on == start_on.end_of_month
        start_on.strftime("%B %Y")
      elsif start_on == start_on.beginning_of_month && end_on == today
        "#{start_on.strftime('%B %Y')} so far"
      elsif start_on == start_on.beginning_of_year && end_on == today
        "#{start_on.year} so far"
      elsif start_on == start_on.beginning_of_year && end_on == start_on.end_of_year
        start_on.year.to_s
      else
        "#{start_on.strftime('%b %-d, %Y')} – #{end_on.strftime('%b %-d, %Y')}"
      end
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(
        Money.dollars(cents),
        precision: cents.to_i % 100 == 0 ? 0 : 2
      )
    end

    def normalized_message
      @normalized_message ||= normalize(message)
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end
  end
end
