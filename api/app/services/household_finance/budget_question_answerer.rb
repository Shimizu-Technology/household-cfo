module HouseholdFinance
  class BudgetQuestionAnswerer
    BUDGET_TERMS = /\b(set aside|budget(?:ed)?|planned|plan|available|left|remaining|allowance)\b/i
    SPENDING_TERMS = /\b(spending|spend|food|grocer(?:y|ies)?|dining|restaurant|coffee|takeout|flexible|discretionary)\b/i
    ACTUAL_REPORT_TERMS = /\b(actuals?|transactions?|report|how was|how were|how did|did i spend|did we spend|spent)\b/i
    FOOD_TERMS = /\b(food|grocer(?:y|ies)?|dining|restaurant|coffee|takeout|lunch|dinner|breakfast)\b/i
    FOOD_CATEGORY_TERMS = /\b(food|grocer(?:y|ies)?|dining|restaurant|coffee|takeout)\b/i

    def initialize(message, annual_plan:, today: Date.current)
      @message = message.to_s.squish
      @annual_plan = annual_plan.deep_symbolize_keys
      @today = today
    end

    def call
      return nil unless budget_question?
      return nil if month_index.nil?

      discretionary_rows = rows.select { |row| row.fetch(:stack_key) == "discretionary" }
      explicit_rows = rows.select { |row| normalized(row.fetch(:name)).present? && normalized(message).include?(normalized(row.fetch(:name))) }
      food_rows = rows.select { |row| normalized(row.fetch(:name)).match?(FOOD_CATEGORY_TERMS) }
      selected_rows = explicit_rows.presence || (message.match?(FOOD_TERMS) && food_rows.any? ? food_rows : discretionary_rows)
      return nil if discretionary_rows.empty? && selected_rows.empty?

      [
        summary_line(discretionary_rows, selected_rows, focused: explicit_rows.any?),
        category_line(explicit_rows.presence || food_rows.presence || selected_rows),
        pending_line(selected_rows.presence || discretionary_rows)
      ].compact.join("\n\n")
    end

    private

    attr_reader :message, :annual_plan, :today

    def budget_question?
      return false unless message.match?(BUDGET_TERMS) && message.match?(SPENDING_TERMS)
      return false if message.match?(ACTUAL_REPORT_TERMS) && !message.match?(/set aside|budget(?:ed)?|planned|available|left|remaining/i)

      true
    end

    def summary_line(discretionary_rows, selected_rows, focused: false)
      target_rows = focused ? selected_rows : discretionary_rows.presence || selected_rows
      planned = sum_for(target_rows, :planned)
      actual = sum_for(target_rows, :actual)
      remaining = sum_for(target_rows, :remaining)
      plan_label = focused ? "active #{target_rows.map { |row| row.fetch(:name) }.to_sentence} plan" : "active discretionary plan"
      "Based on your active annual plan for #{month_label}, your #{plan_label} is #{money(planned)}. Confirmed actuals are #{money(actual)}, leaving #{money(remaining)} before any new approvals."
    end

    def category_line(target_rows)
      visible_rows = target_rows.first(4)
      return if visible_rows.empty?

      label = message.match?(FOOD_TERMS) ? "Food-like active categories I can see" : "Active discretionary categories"
      details = visible_rows.map do |row|
        month = row_month(row)
        "#{row.fetch(:name)} #{money(month.fetch(:planned))} planned, #{money(month.fetch(:actual))} actual, #{money(month.fetch(:remaining))} remaining"
      end.to_sentence
      "#{label}: #{details}."
    end

    def pending_line(target_rows)
      pending = pending_for(target_rows)
      base = "Archived categories stay out of this active budget view unless you restore them."
      return base if pending.zero?

      "#{money(pending)} is still pending review for these categories; I am not counting pending drafts as actuals until you confirm them. #{base}"
    end

    def rows
      @rows ||= annual_plan.fetch(:rows).select { |row| row.fetch(:active, true) }
    end

    def month
      @month ||= annual_plan.fetch(:months).fetch(month_index)
    end

    def month_index
      return @month_index if defined?(@month_index)

      @month_index = relative_month_date ? relative_month_index : explicit_month_index || default_month_index
    end

    def relative_month_index
      relative_date = relative_month_date
      return unless relative_date
      return unless relative_date.year == annual_plan_year

      relative_date.month - 1
    end

    def relative_month_date
      return today if normalized(message).match?(/\b(this|current) month\b/)
      return today.next_month if normalized(message).match?(/\bnext month\b/)

      today.prev_month if normalized(message).match?(/\blast month\b/)
    end

    def explicit_month_index
      MonthTerms.detect_index(message)
    end

    def default_month_index
      return unless annual_plan_year == today.year

      today.month - 1
    end

    def annual_plan_year
      annual_plan.fetch(:year).to_i
    end

    def month_label
      "#{month.fetch(:label)} #{annual_plan.fetch(:year)}"
    end

    def row_month(row)
      row.fetch(:months).fetch(month_index)
    end

    def sum_for(target_rows, key)
      target_rows.sum { |row| row_month(row).fetch(key).to_f }
    end

    def pending_for(target_rows)
      target_ids = target_rows.map { |row| row.fetch(:id) }
      annual_plan.fetch(:pending_transaction_drafts).sum do |draft|
        next 0 unless target_ids.include?(draft.fetch(:category_id)) && draft_occurs_in_month?(draft)

        draft.fetch(:amount).to_f
      end
    end

    def draft_occurs_in_month?(draft)
      occurred_on = Date.iso8601(draft.fetch(:occurred_on))
      starts_on = Date.iso8601(month.fetch(:starts_on))
      ends_on = Date.iso8601(month.fetch(:ends_on))
      occurred_on.between?(starts_on, ends_on)
    rescue ArgumentError
      false
    end

    def normalized(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end

    def money(value)
      ActiveSupport::NumberHelper.number_to_currency(value, precision: 0)
    end
  end
end
