# frozen_string_literal: true

module HouseholdFinance
  # One month picture for chat and Home. Values are cents; unknown stays nil.
  # Planned out includes debt minimums. Spent so far is confirmed category
  # spending, so it is compared with category budgets, never with bank cash.
  class MiaMonthAnswer
    QUESTION = /\bhow (?:am i|are we|is (?:my|our) (?:month|budget)) doing\b|\bhow (?:am i|are we) doing\b|\bhow (?:does|is) (?:this|my|our) month (?:look|going)\b/i

    def self.question?(message)
      message.to_s.match?(QUESTION)
    end

    def self.question_date(message, today: Date.current)
      relative = BudgetQuestionAnswerer.relative_month_date(message, today: today)
      return relative if relative

      numeric = message.to_s.match(/\b(20\d{2})-(0[1-9]|1[0-2])\b/)
      return Date.new(numeric[1].to_i, numeric[2].to_i, 1) if numeric

      month = MonthTerms.detect_number(message) || today.month
      year = message.to_s[/\b(20\d{2})\b/, 1]&.to_i || today.year
      Date.new(year, month, 1)
    end

    def self.for_question(household, message)
      date = question_date(message)
      plan = AnnualBudgetManager.new(household, year: date.year).read_only_plan_data
      new(household, annual_plan: plan, month: date.month)
    end

    def initialize(household, annual_plan:, month: Date.current.month)
      @household = household
      @plan = annual_plan.deep_symbolize_keys
      @month = month.to_i.clamp(1, 12)
    end

    def call
      @answer ||= begin
        rows = Array(plan[:rows])
        active = rows.select { |row| row.fetch(:active, true) }
        period = Array(plan[:months])[month - 1].to_h
        approved = plan.fetch(:plan_available, true)
        allocations_known = approved && active.all? { |row| cell(row).present? && !cell(row)[:allocation_missing] }
        fields = SetupStatus.new(household).confirmed_field_keys
        income_known = %w[primary_income business_income].all? { |field| fields.include?(field) }
        incomes = plan[:monthly_income].to_h
        income_value = incomes[period[:id]] || incomes[period[:id].to_s]
        income = approved && income_known && !income_value.nil? ? Money.cents(income_value) : nil
        categories = allocations_known ? active.sum { |row| Money.cents(cell(row)[:planned]) } : nil
        debt = plan[:monthly_debt_minimums_known] ? Money.cents(plan[:monthly_debt_minimums]) : nil
        planned = categories && debt ? categories + debt : nil
        actual = approved ? rows.sum { |row| Money.cents(cell(row)[:actual]) } : nil
        pending = Array(plan[:pending_transaction_drafts]).select { |draft| draft[:occurred_on].to_s.start_with?(format("%04d-%02d", year, month)) }
        truncated = plan.dig(:pending_transaction_drafts_meta, :truncated) == true
        pending_unknown = truncated && pending.empty?
        snapshot = SnapshotBuilder.new(household, reference_date: Date.new(year, month, 1), ensure_plan: false).call
        readiness_known = income && planned && snapshot[:liquid_assets_known] && SetupStatus.new(household).complete?
        {
          year: year, month: month, period_label: Date.new(year, month, 1).strftime("%B %Y"),
          money_in_cents: income, planned_out_cents: planned, category_plan_cents: categories,
          debt_minimums_cents: debt, spent_so_far_cents: actual,
          plan_left_cents: income && planned ? income - planned : nil,
          category_left_cents: categories && actual ? categories - actual : nil,
          pending_cents: approved && !pending_unknown ? pending.sum { |draft| draft[:amount_cents] || Money.cents(draft[:amount]) } : nil,
          pending_count: pending_unknown ? nil : pending.length, pending_list_truncated: truncated,
          readiness_tone: readiness_known ? snapshot[:readiness_tone] : nil,
          readiness_meaning: readiness_known ? snapshot[:readiness_label] : "Add the missing starting numbers before judging your cushion.",
          safe_to_spend_cents: readiness_known ? snapshot[:safe_to_spend_cents] : nil,
          spent_basis: "confirmed category spending; debt payments are separate",
          left_basis: "the plan after planned spending; not a bank balance or permission to spend"
        }
      end
    end

    def response
      facts = call
      income = figure(facts[:money_in_cents])
      planned = figure(facts[:planned_out_cents])
      left = facts[:plan_left_cents]
      plan_line = if left.nil?
        "I still need the missing income or planned costs to say what your plan leaves."
      elsif left.negative?
        "Your plan is short by #{money(-left)} after planned spending."
      else
        "Your plan leaves #{money(left)} after planned spending; that is planned breathing room, not cash available to spend."
      end
      pending_line = if facts[:pending_count].nil?
        "; the review list is incomplete, so I cannot tell how many purchases are waiting for review in this month."
      elsif facts[:pending_count].positive?
        qualifier = facts[:pending_list_truncated] ? "At least " : ""
        "; #{qualifier}#{figure(facts[:pending_cents])} is waiting for your review and is separate from spent so far."
      else
        "; no purchases are waiting for review."
      end
      next_move = if facts[:readiness_tone] == "red" && left&.positive?
        "Keep must-pay bills covered and give that breathing room a job building your cushion."
      elsif left&.negative?
        "Choose one flexible cost to reduce before adding a new commitment."
      else
        "Check the next bill due before deciding what to do with any money left."
      end
      "For #{facts[:period_label]}, money in is #{income} and planned out is #{planned}, including required debt payments. #{plan_line} Your spent so far is #{figure(facts[:spent_so_far_cents])} in confirmed category purchases#{pending_line} #{facts[:readiness_meaning]}. #{next_move}"
    end

    private

    attr_reader :household, :plan, :month

    def year
      plan.fetch(:year, Date.current.year).to_i
    end

    def cell(row)
      Array(row[:months])[month - 1].to_h
    end

    def figure(cents)
      cents.nil? ? "not known yet" : money(cents)
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)
    end
  end
end
