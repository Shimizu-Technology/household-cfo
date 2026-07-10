module HouseholdFinance
  class BudgetQuestionAnswerer
    BUDGET_TERMS = /\b(set aside|budget(?:ed)?|planned|plan|available|left|remaining|allowance)\b/i
    SPENDING_TERMS = /\b(spending|spend|food|grocer(?:y|ies)?|dining|restaurant|coffee|takeout|flexible|discretionary)\b/i
    ACTUAL_REPORT_TERMS = /\b(actuals?|transactions?|report|how was|how were|how did|did i spend|did we spend|spent)\b/i
    FOOD_TERMS = /\b(food|grocer(?:y|ies)?|dining|restaurant|coffee|takeout|lunch|dinner|breakfast)\b/i
    FOOD_CATEGORY_TERMS = /\b(food|grocer(?:y|ies)?|dining|restaurant|coffee|takeout)\b/i
    BROAD_BUDGET_PATTERNS = [
      /\b(?:tell me about|explain|overview|summary)\b.*\b(?:budget|plan)\b/i,
      /\b(?:budget|plan)\b.*\b(?:overview|summary|breakdown|break down|categor(?:y|ies)|line items?)\b/i,
      /\b(?:what are all|all the|each)\b.*\b(?:breakdowns?|categor(?:y|ies)|line items?)\b/i,
      /\b(?:largest|biggest|highest|top)\b.*\b(?:category|budget|spending|expense|line item|planned)\b/i,
      /\bfollow up to previous budget report topic\b/i,
      /\bbudget report\b/i
    ].freeze
    BUDGET_HEALTH_PATTERN = /\b(?:how are we looking|where are we at|how do we look|are we on track|on track|off track|budget status)\b/i
    CATEGORY_BREAKDOWN_PATTERN = /\b(?:breakdowns?|break down|by category|each category|all categories|line items?)\b/i
    LARGEST_CATEGORY_PATTERN = /\b(?:largest|biggest|highest|top)\b.*\b(?:category|budget|spending|expense|line item|planned)\b/i

    def self.budget_question?(message)
      text = message.to_s.squish
      normalized_text = normalized(text)
      return true if BROAD_BUDGET_PATTERNS.any? { |pattern| normalized_text.match?(pattern) }
      return true if normalized_text.match?(BUDGET_HEALTH_PATTERN) && normalized_text.match?(/\b(?:budget|plan|category|spending|actual|budget report)\b/i)
      return false unless text.match?(BUDGET_TERMS) && text.match?(SPENDING_TERMS)
      return false if text.match?(ACTUAL_REPORT_TERMS) && !text.match?(/set aside|budget(?:ed)?|planned|available|left|remaining/i)

      true
    end

    def self.relative_month_date(message, today: Date.current)
      text = normalized(message)
      return today if text.match?(/\b(this|current) month\b/)
      return today.next_month if text.match?(/\bnext month\b/)

      today.prev_month if text.match?(/\blast month\b/)
    end

    def self.relative_budget_year(message, today: Date.current)
      relative_month_date(message, today: today)&.year
    end

    def self.normalized(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end

    def initialize(message, annual_plan:, today: Date.current)
      @message = message.to_s.squish
      @annual_plan = annual_plan.deep_symbolize_keys
      @today = today
    end

    def call
      return nil unless budget_question?
      return nil if month_index.nil?

      return largest_category_answer if largest_category_question?
      return category_breakdown_answer if category_breakdown_question?
      return budget_health_answer if budget_health_question?
      return budget_overview_answer if budget_overview_question?

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
      self.class.budget_question?(message)
    end

    def budget_overview_question?
      normalized_message.match?(/\b(?:tell me about|overview|summary|explain)\b.*\b(?:budget|plan)\b/) ||
        normalized_message.match?(/\b(?:budget|plan)\b.*\b(?:overview|summary)\b/)
    end

    def category_breakdown_question?
      normalized_message.match?(CATEGORY_BREAKDOWN_PATTERN)
    end

    def largest_category_question?
      normalized_message.match?(LARGEST_CATEGORY_PATTERN)
    end

    def budget_health_question?
      normalized_message.match?(BUDGET_HEALTH_PATTERN)
    end

    def budget_overview_answer
      planned = sum_for(rows, :planned)
      actual = sum_for(rows, :actual)
      remaining = sum_for(rows, :remaining)
      pending = pending_for(rows)
      surplus = monthly_income_cents - planned
      largest = largest_planned_row
      largest_line = largest ? " Your largest planned category is #{largest.fetch(:name)} at #{money(row_month_cents(largest, :planned))}." : ""

      "For #{month_label}, approved monthly income is #{money(monthly_income_cents)} and active planned outflow is #{money(planned)}, leaving a planned baseline surplus of #{money(surplus)}. Confirmed actuals are #{money(actual)}, so #{remaining_phrase(remaining)} before pending drafts. Pending transaction drafts total #{money(pending)} and are not counted as actuals until you confirm them. #{stack_totals_sentence}.#{largest_line} Next CFO move: review the largest planned category and any pending drafts before changing the plan."
    end

    def category_breakdown_answer
      return "I do not see active budget categories for #{month_label} yet. Next CFO move: add the core household categories first, then ask me for the breakdown again." if rows.empty?

      sections = rows.group_by { |row| row.fetch(:stack_label) }.map do |stack_label, stack_rows|
        planned = sum_for(stack_rows, :planned)
        actual = sum_for(stack_rows, :actual)
        remaining = sum_for(stack_rows, :remaining)
        details = stack_rows.map { |row| row_detail(row) }.to_sentence
        "#{stack_label}: #{money(planned)} planned, #{money(actual)} actual, #{money(remaining)} remaining — #{details}"
      end

      pending = pending_for(rows)
      "Here is the active #{month_label} budget by category, separating planned dollars from confirmed actuals: #{sections.join('. ')}. Pending transaction drafts total #{money(pending)} and are not counted as actuals until you confirm them. Next CFO move: compare the largest remaining category against what still needs to happen this month before approving new wants."
    end

    def largest_category_answer
      row = largest_planned_row
      return "I do not see active budget categories for #{month_label} yet. Next CFO move: add the household’s core categories, then ask me for the largest line again." unless row

      "Your largest planned spending category for #{month_label} is #{row.fetch(:name)}, under #{row.fetch(:stack_label)}, with #{money(row_month_cents(row, :planned))} planned, #{money(row_month_cents(row, :actual))} confirmed actuals, and #{money(row_month_cents(row, :remaining))} remaining. Pending drafts are not counted in that actual number. Next CFO move: review what makes up #{row.fetch(:name)} before reducing it; if you want to change it, I can draft the edit for your approval."
    end

    def budget_health_answer
      planned = sum_for(rows, :planned)
      actual = sum_for(rows, :actual)
      remaining = sum_for(rows, :remaining)
      pending = pending_for(rows)
      largest = largest_planned_row
      over_plan_rows = rows.select { |row| row_month_cents(row, :remaining).negative? }.sort_by { |row| row_month_cents(row, :remaining) }
      over_line = if over_plan_rows.any?
        " Categories over plan: #{over_plan_rows.first(3).map { |row| "#{row.fetch(:name)} by #{money(row_month_cents(row, :remaining).abs)}" }.to_sentence}."
      else
        " No active category is over plan on confirmed actuals yet."
      end
      largest_line = largest ? " Largest planned line: #{largest.fetch(:name)} at #{money(row_month_cents(largest, :planned))}." : ""

      "For #{month_label}, confirmed actuals are #{money(actual)} against #{money(planned)} planned, so #{remaining_phrase(remaining)}. Pending transaction drafts total #{money(pending)} and are waiting for approval, not counted as actuals.#{over_line}#{largest_line} Next CFO move: review pending drafts first, then decide whether the largest planned line needs a one-month adjustment."
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
        "#{row.fetch(:name)} #{money(row_month_cents(row, :planned))} planned, #{money(row_month_cents(row, :actual))} actual, #{money(row_month_cents(row, :remaining))} remaining"
      end.to_sentence
      "#{label}: #{details}."
    end

    def pending_line(target_rows)
      pending = pending_for(target_rows)
      base = "Archived categories stay out of this active budget view unless you restore them."
      return base if pending.zero?

      "#{money(pending)} is still pending review for these categories; I am not counting pending drafts as actuals until you confirm them. #{base}"
    end

    def stack_totals_sentence
      return "No active category breakdown is available yet" if rows.empty?

      rows.group_by { |row| row.fetch(:stack_label) }.map do |stack_label, stack_rows|
        "#{stack_label} #{money(sum_for(stack_rows, :planned))} planned"
      end.to_sentence
    end

    def row_detail(row)
      "#{row.fetch(:name)} #{money(row_month_cents(row, :planned))} planned, #{money(row_month_cents(row, :actual))} actual, #{money(row_month_cents(row, :remaining))} remaining"
    end

    def largest_planned_row
      rows.max_by { |row| row_month_cents(row, :planned) }
    end

    def remaining_phrase(remaining_cents)
      return "you have #{money(remaining_cents)} left on confirmed actuals" if remaining_cents >= 0

      "confirmed actuals are #{money(remaining_cents.abs)} over plan"
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
      self.class.relative_month_date(message, today: today)
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

    def row_month_cents(row, key)
      dollars_to_cents(row_month(row).fetch(key))
    end

    def sum_for(target_rows, key)
      target_rows.sum { |row| row_month_cents(row, key) }
    end

    def pending_for(target_rows)
      target_ids = target_rows.map { |row| row.fetch(:id) }
      annual_plan.fetch(:pending_transaction_drafts).sum do |draft|
        next 0 unless target_ids.include?(draft.fetch(:category_id)) && draft_occurs_in_month?(draft)

        dollars_to_cents(draft.fetch(:amount))
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

    def monthly_income_cents
      income_by_period = annual_plan.fetch(:monthly_income, {})
      dollars_to_cents(income_by_period[month.fetch(:id)] || income_by_period[month.fetch(:id).to_s] || 0)
    end

    def normalized_message
      @normalized_message ||= normalized(message)
    end

    def normalized(value)
      self.class.normalized(value)
    end

    def dollars_to_cents(value)
      (value.to_f * 100).round
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(
        Money.dollars(cents),
        precision: cents.to_i % 100 == 0 ? 0 : 2
      )
    end
  end
end
