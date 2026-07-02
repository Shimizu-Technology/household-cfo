module HouseholdFinance
  class TransactionLookupAnswerer
    FOOD_TERMS = /\b(food|eat|ate|dining|restaurant|restaurants|takeout|coffee|cafe|grocer(?:y|ies)?)\b/i
    LOOKUP_TERMS = /\b(how many|how much|what|show|find|search|list|total|did i|did we)\b/i
    PLANNED_TERMS = /\b(set aside|budget(?:ed)?|planned|available|allowance|left|remaining)\b/i

    def initialize(household, message, today: Date.current)
      @household = household
      @message = message.to_s.downcase.squish
      @today = today
    end

    def call
      return nil unless lookup_like?

      target = lookup_target
      return nil unless target

      transactions = matching_transactions(target)
      build_answer(target, transactions)
    end

    private

    attr_reader :household, :message, :today

    def lookup_like?
      return false if message.match?(PLANNED_TERMS) && !message.match?(/\b(actuals?|transactions?|spent|spend)\b/i)

      message.match?(LOOKUP_TERMS)
    end

    def lookup_target
      category_target || merchant_target
    end

    def category_target
      active_categories.each do |category|
        normalized_name = normalize(category.name)
        return { type: :category, label: category.name, category_ids: [ category.id ] } if normalized_name.present? && normalized_message.include?(normalized_name)
      end

      return unless message.match?(FOOD_TERMS)

      food_categories = active_categories.select { |category| category.name.match?(FOOD_TERMS) }
      return if food_categories.empty?

      { type: :category, label: "food-like categories", category_ids: food_categories.map(&:id) }
    end

    def merchant_target
      known_merchant = base_transactions.map(&:merchant).compact.uniq.find do |merchant|
        normalized_merchant = normalize(merchant)
        normalized_merchant.present? && normalized_message.include?(normalized_merchant)
      end
      return { type: :merchant, label: known_merchant } if known_merchant.present?

      extracted = message.match(/\b(?:at|from|to)\s+([a-z0-9'&.\-\s]+?)(?:\s+(?:this|last|in|for|during|between|from|and how|how much|how many)|[?.!]|$)/i)&.[](1)&.squish
      extracted = extracted&.gsub(/\b(today|yesterday)\b/i, "")&.squish
      return if extracted.blank? || extracted.length > 80

      { type: :merchant, label: extracted }
    end

    def matching_transactions(target)
      transactions = base_transactions
      transactions = transactions.select { |transaction| merchant_matches?(transaction.merchant, target.fetch(:label)) } if target.fetch(:type) == :merchant
      transactions = transactions.select { |transaction| transaction_category_ids(transaction).intersect?(target.fetch(:category_ids)) } if target.fetch(:type) == :category
      transactions
    end

    def build_answer(target, transactions)
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

    def category_breakdown(transactions, target)
      return if target.fetch(:type) == :category

      breakdown = Hash.new(0)
      transactions.each do |transaction|
        active_splits(transaction).each { |split| breakdown[split.budget_category.name] += split.amount_cents }
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

      active_splits(transaction)
        .select { |split| target.fetch(:category_ids).include?(split.budget_category_id) }
        .sum(&:amount_cents)
    end

    def merchant_matches?(merchant, target_label)
      normalize(merchant).include?(normalize(target_label)) || normalize(target_label).include?(normalize(merchant))
    end

    def active_splits(transaction)
      transaction.transaction_splits.select { |split| split.budget_category&.active? }
    end

    def transaction_category_ids(transaction)
      active_splits(transaction).map(&:budget_category_id)
    end

    def base_transactions
      @base_transactions ||= household.household_transactions
        .includes(transaction_splits: :budget_category)
        .joins(transaction_splits: :budget_category)
        .where(budget_categories: { active: true })
        .where(status: %w[confirmed reconciled], occurred_on: start_on..end_on)
        .distinct
        .order(occurred_on: :desc, created_at: :desc)
        .to_a
    end

    def active_categories
      @active_categories ||= household.budget_categories.active.ordered.to_a
    end

    def range
      @range ||= SpendingReportQuery.new(message, today: today).range || { start_on: today.beginning_of_month, end_on: today }
    end

    def start_on
      range.fetch(:start_on)
    end

    def end_on
      range.fetch(:end_on)
    end

    def period_label
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
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: 0)
    end

    def normalized_message
      @normalized_message ||= normalize(message)
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end
  end
end
