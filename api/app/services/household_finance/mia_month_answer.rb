# frozen_string_literal: true

require_relative "message_reply_intent"

module HouseholdFinance
  # One month picture for chat and Home. Values are cents; unknown stays nil.
  # Planned out includes debt minimums. Spent so far is confirmed category
  # spending, so it is compared with category budgets, never with bank cash.
  class MiaMonthAnswer
    QUESTION = /\bhow much (?:do (?:i|we) have|is) left (?:this|last) month\b|\bhow did (?:this month|last month|(?:#{MonthTerms.pattern})(?: 20\d{2})?) look\b|\bhow (?:am i|are we|is (?:my|our) (?:month|budget)) doing\b|\bhow (?:am i|are we) doing\b|\bhow (?:does|is) (?:this|my|our) month (?:look|going)\b|\bhow much is left in (?:my|our|the) plan (?:this|last) month\b/i

    def self.question?(message)
      return false if MessageReplyIntent.purchase_question?(message) || message.to_s.match?(/\b(?:bank|account|grocer(?:y|ies)|food|week)\b/i)

      message.to_s.match?(QUESTION) || MessageReplyIntent.matches?(message, "month_balance")
    end

    def self.question_date(message, today: Date.current)
      numeric = message.to_s.match(/\b(20\d{2})-(\d+)\b/)
      if numeric
        return unless numeric[2].to_i.between?(1, 12)

        return Date.new(numeric[1].to_i, numeric[2].to_i, 1)
      end
      relative = BudgetQuestionAnswerer.relative_month_date(message, today: today)
      return relative if relative

      month = MonthTerms.detect_number(message) || today.month
      year = message.to_s[/\b(?:#{MonthTerms.pattern})\s+(20\d{2})\b/i, 1]&.to_i || today.year
      Date.new(year, month, 1)
    end

    def self.for_question(household, message, annual_plan: nil)
      date = question_date(message)
      return new(household, annual_plan: {}, invalid_period: true) unless date

      plan = annual_plan if annual_plan && (annual_plan[:year] || annual_plan["year"]).to_i == date.year
      plan ||= AnnualBudgetManager.new(household, year: date.year).read_only_plan_data
      new(household, annual_plan: plan, month: date.month)
    end

    def initialize(household, annual_plan:, month: Date.current.month, invalid_period: false)
      @invalid_period = invalid_period
      @household = household
      @plan = annual_plan.deep_symbolize_keys
      @month = month.to_i.clamp(1, 12)
    end

    def plan_data
      plan unless @invalid_period
    end

    def call
      return { clarification: "Which month and year do you mean? Please use a valid month, such as October 2026." } if @invalid_period

      @answer ||= begin
        rows = Array(plan[:rows])
        active = rows.select { |row| row.fetch(:active, true) }
        period = Array(plan[:months])[month - 1].to_h
        approved = plan.fetch(:plan_available, true)
        fields = SetupStatus.new(household).confirmed_field_keys
        costs_known = { "fixed_expenses" => "non_discretionary", "flexible_spend" => "discretionary" }.all? do |field, stack|
          fields.include?(field) || active.any? { |row| row[:stack_key] == stack }
        end
        allocations_known = approved && Date.new(year, month, 1) >= PlanCoverage.new(household).starts_on && costs_known && active.all? { |row| cell(row).present? && !cell(row)[:allocation_missing] }
        # Business income is optional. Its unconfirmed absence must not hide an
        # approved source or a deliberately confirmed primary-income zero.
        income_known = PlanCoverage.new(household).income_known?(Date.new(year, month, 1))
        before_start = Date.new(year, month, 1) < PlanCoverage.new(household).starts_on
        incomes = plan[:monthly_income].to_h
        income_value = incomes[period[:id]] || incomes[period[:id].to_s]
        income = approved && income_known && !income_value.nil? ? Money.cents(income_value) : nil
        categories = allocations_known ? active.sum { |row| Money.cents(cell(row)[:planned]) } : nil
        debt = !before_start && plan[:monthly_debt_minimums_known] ? Money.cents(plan[:monthly_debt_minimums]) : nil
        planned = categories && debt ? categories + debt : nil
        # These cells are uncapped SQL aggregates of approved category splits,
        # independent of the capped recent/pending transaction lists.
        actual = approved || before_start ? rows.sum { |row| Money.cents(cell(row)[:actual]) } : nil
        actual = nil unless household.household_transactions.where(status: %w[confirmed reconciled], occurred_on: Date.new(year, month, 1).all_month).exists?
        pending = Array(plan[:pending_transaction_drafts]).select { |draft| draft[:occurred_on].to_s.start_with?(format("%04d-%02d", year, month)) }
        truncated = plan.dig(:pending_transaction_drafts_meta, :truncated) == true
        pending_unknown = truncated
        snapshot = SnapshotBuilder.new(household, reference_date: Date.new(year, month, 1), ensure_plan: false).call
        readiness_known = income && planned && snapshot[:liquid_assets_known] && SetupStatus.new(household).complete?
        {
          plan_available: approved, plan_starts_on: PlanCoverage.new(household).starts_on.iso8601, before_plan_start: before_start,
          main_income_missing: !income_known && !fields.include?("primary_income"),
          missing_plan_inputs: missing_plan_inputs(income, categories, debt),
          cushion_missing_inputs: cushion_missing_inputs(snapshot, income, categories, debt),
          year: year, month: month, period_label: Date.new(year, month, 1).strftime("%B %Y"),
          money_in_cents: income, planned_out_cents: planned, category_plan_cents: categories,
          debt_minimums_cents: debt, spent_so_far_cents: actual,
          plan_left_cents: income && planned ? income - planned : nil,
          category_left_cents: categories && actual ? categories - actual : nil,
          pending_cents: approved && !pending_unknown ? pending.sum { |draft| draft[:amount_cents] || Money.cents(draft[:amount]) } : nil,
          pending_review_count: pending_unknown ? nil : Array(plan[:pending_transaction_drafts]).length,
          pending_count: pending_unknown ? nil : pending.length, pending_unknown: pending_unknown, pending_list_truncated: truncated,
          readiness_tone: readiness_known ? snapshot[:readiness_tone] : nil,
          runway_months: readiness_known ? snapshot[:runway_months] : nil,
          readiness_guidance: readiness_known ? cushion_guidance(snapshot[:readiness_tone], income && planned ? income - planned : nil) : missing_cushion_guidance(snapshot, income, categories, debt),
          readiness_meaning: readiness_known ? snapshot[:readiness_label] : missing_cushion_guidance(snapshot, income, categories, debt),
          safe_to_spend_cents: readiness_known ? snapshot[:safe_to_spend_cents] : nil,
          spent_basis: "purchases you approved; debt payments are separate",
          left_basis: "the plan after planned spending; not a bank balance or permission to spend"
        }
      end
    end

    def response(next_move: nil)
      facts = call
      return [ facts[:clarification], next_move ].compact_blank.join(" ") if facts[:clarification]

      if facts[:before_plan_start]
        start = Date.iso8601(facts[:plan_starts_on]).strftime("%B %Y")
        spending = if facts[:spent_so_far_cents].nil?
          "Approved spending for #{facts[:period_label]} is not known yet."
        else
          "From your approved statement lines, you spent #{money(facts[:spent_so_far_cents])} in #{facts[:period_label]}."
        end
        return [ "Your plan starts in #{start}, so #{facts[:period_label]} has no plan to compare against. #{spending}", review_next_step(facts, next_move: next_move) ].compact.join(" ")
      end

      return "Your #{facts[:year]} plan is not set up yet, so I cannot show a plan comparison for #{facts[:period_label]}. Open Budget to set up that year’s plan when you are ready. Nothing has been created or saved." unless facts[:plan_available]

      left = facts[:plan_left_cents]
      plan_line = if left.nil?
        "For #{facts[:period_label]}, still to add: #{facts[:missing_plan_inputs].map { |input| input[:label] }.to_sentence}; I cannot total what your plan leaves yet"
      elsif left.negative?
        "Your plan is short by #{money(-left)} for #{facts[:period_label]}"
      else
        "Your plan leaves about #{money(left)} for #{facts[:period_label]}"
      end
      spent = facts[:spent_so_far_cents]
      spent_line = spent.nil? ? "spent so far is not known yet" : "you’ve spent #{money(spent)} so far"
      cushion_line = facts[:readiness_guidance]
      review_line = review_next_step(facts, next_move: next_move)
      review_line ||= "Check the next bill due before deciding where any money left should go."
      caveat = left.nil? ? "" : "; this is a plan figure, not a bank balance or permission to spend"
      "#{plan_line}#{caveat}, and #{spent_line}. #{cushion_line} #{review_line}"
    end

    private

    attr_reader :household, :plan, :month

    def review_next_step(facts, next_move: nil)
      count = facts[:pending_review_count]
      review = if count.nil?
        "The review list is incomplete, so check the purchases waiting there before deciding what comes next."
      elsif count.positive?
        "Review the #{count} #{'purchase'.pluralize(count)} waiting for you before deciding what comes next."
      end
      return review unless next_move.present?

      review ? "#{next_move.sub(/[.!?]\z/, '')}; #{review.sub(/\A./, &:downcase)}" : next_move
    end

    def cushion_guidance(tone, left)
      case tone
      when "red"
        left&.positive? ? "Your emergency cushion needs building, so give that breathing room a job first." : "Protect food, housing, utilities, and required payments while you rebuild your cushion."
      when "yellow" then "You have some cushion; keep strengthening it before adding new commitments."
      when "green" then "Your cushion is in a stronger place; keep essentials and upcoming costs protected."
      else missing_cushion_guidance(nil, nil, nil, nil)
      end
    end

    def missing_plan_inputs(income, categories, debt)
      [].tap do |inputs|
        inputs << { label: "your main income", destination: "profile" } if income.nil?
        inputs << { label: "planned household costs", destination: "budget" } if categories.nil?
        inputs << { label: "debt minimums", destination: "debt" } if debt.nil?
      end
    end

    def cushion_missing_inputs(snapshot, income, categories, debt)
      inputs = missing_plan_inputs(income, categories, debt)
      inputs << { label: "checking, savings, and emergency-fund balances", destination: "accounts" } unless snapshot[:liquid_assets_known]
      inputs
    end

    def missing_cushion_guidance(snapshot, income, categories, debt)
      # During construction use the current approved plan values, not guessed zeros.
      return "Add the missing starting numbers before judging your cushion." unless snapshot

      labels = cushion_missing_inputs(snapshot, income, categories, debt).map { |input| input[:label] }
      labels.empty? ? "Finish your household setup before judging your cushion." : "Add #{labels.to_sentence} before judging your emergency cushion."
    end

    def year
      plan.fetch(:year, Date.current.year).to_i
    end

    def cell(row)
      Array(row[:months])[month - 1].to_h
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(Money.dollars(cents), precision: 0)
    end
  end
end
