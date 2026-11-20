# frozen_string_literal: true

module HouseholdFinance
  # The figures and names Mia eval checks compare a reply with, read from the eval
  # household the way the app reads them: Budget's category actuals and plan, the
  # debt portfolio, and the spending-pattern analyzer's store labels. A runner takes
  # the snapshot inside its own transaction, so the live runner can roll back.
  class MiaEvalLedger
    KINDS = %w[month_spending month_planned month_planned_out month_income month_plan_left category_spending debt_minimums].freeze
    Unavailable = Class.new(StandardError)

    # One plain, JSON-ready hash per case: every ledger amount the case names, plus
    # what the global rules need.
    def self.snapshot(household, eval_case = {})
      new(household).snapshot(eval_case.to_h.deep_stringify_keys)
    end

    def self.ledger_specs(eval_case)
      %w[expected_amounts allowed_amounts].flat_map { |key| Array(eval_case[key]) }.select { |spec| spec.is_a?(Hash) }
    end

    def self.spec_key(spec)
      spec.to_h.stringify_keys.sort.to_h.to_json
    end

    def initialize(household, today: Time.current.in_time_zone("Pacific/Guam").to_date)
      @household, @today = household, today
    end

    def snapshot(eval_case)
      amounts = self.class.ledger_specs(eval_case).to_h do |spec|
        [ self.class.spec_key(spec), amount(spec) ]
      rescue Unavailable => e
        [ self.class.spec_key(spec), { "unavailable" => e.message } ]
      end
      {
        "today" => @today.iso8601,
        "amounts" => amounts,
        "month_spending" => (1..@today.month).to_h { |month| [ format("%04d-%02d", @today.year, month), month_spending(month_date(month)) ] },
        # nil where the plan has no income for the month.
        "month_income" => (1..@today.month).to_h { |month| [ format("%04d-%02d", @today.year, month), known_month_income(month_date(month)) ] },
        "protected_names" => protected_names,
        "one_month_merchants" => one_month_merchants
      }
    end

    def amount(spec)
      spec = spec.to_h.stringify_keys
      kind = spec["ledger"].to_s
      raise Unavailable, "unknown ledger #{kind.inspect}; use one of #{KINDS.join(', ')}" unless kind.in?(KINDS)

      month = spec["month"] ? Date.iso8601("#{spec['month']}-01") : @today.beginning_of_month
      value = case kind
      when "month_spending" then months(month, spec["through"]).sum { |each_month| month_spending(each_month) }
      when "month_planned" then month_planned(month)
      when "month_planned_out" then month_planned(month) + Money.cents(plan_for(month)[:monthly_debt_minimums])
      when "month_income" then month_income(month)
      when "month_plan_left" then month_plan_left(month)
      when "category_spending" then category_spending(spec.fetch("category"), month)
      when "debt_minimums" then DebtPortfolio.new(@household).monthly_minimum_cents
      end
      # plus/minus state the arithmetic a reply should do ("a $650 TV would leave …").
      value + MiaEvalAmounts.cents(spec["plus"]) - MiaEvalAmounts.cents(spec["minus"])
    rescue Date::Error, KeyError, ArgumentError => e
      raise Unavailable, "#{kind}: #{e.message}"
    end

    private

    # What Budget shows as spent: confirmed and reconciled category splits for the month.
    def month_spending(month)
      cells(month).sum { |cell| Money.cents(cell[:actual]) }
    end

    # The category plan only, without debt minimums. Budget's "planned out" adds them (month_planned_out).
    def month_planned(month)
      cells(month, active_only: true).sum { |cell| Money.cents(cell[:planned]) }
    end

    def known_month_income(month)
      month_income(month)
    rescue Unavailable
      nil
    end

    def month_income(month)
      plan = plan_for(month)
      period_id = Array(plan[:months])[month.month - 1].to_h[:id]
      value = plan[:monthly_income].to_h[period_id] || plan[:monthly_income].to_h[period_id.to_s]
      raise Unavailable, "no planned income for #{month.strftime('%B %Y')}" if value.nil?

      Money.cents(value)
    end

    # The same "plan leaves" figure Home and Mia's month answer use.
    def month_plan_left(month)
      left = MiaMonthAnswer.new(@household, annual_plan: plan_for(month), month: month.month).call[:plan_left_cents]
      raise Unavailable, "the plan for #{month.strftime('%B %Y')} is incomplete" if left.nil?

      left
    end

    def category_spending(name, month)
      row = Array(plan_for(month)[:rows]).find { |candidate| candidate[:name].to_s.casecmp?(name.to_s) }
      raise Unavailable, "no category named #{name.inspect}" unless row

      Money.cents(Array(row[:months])[month.month - 1].to_h[:actual])
    end

    def months(first, through)
      last = through ? Date.iso8601("#{through}-01") : first
      (first..last).select { |day| day.day == 1 }
    end

    # Planned totals count active categories, as Mia's month answer does; spent counts every row.
    def cells(month, active_only: false)
      rows = Array(plan_for(month)[:rows])
      rows = rows.select { |row| row.fetch(:active, true) } if active_only
      rows.map { |row| Array(row[:months])[month.month - 1].to_h }
    end

    def plan_for(month)
      @plans ||= {}
      @plans[month.year] ||= AnnualBudgetManager.new(@household, year: month.year).read_only_plan_data.deep_symbolize_keys
    end

    def month_date(month) = Date.new(@today.year, month, 1)

    # Category names the method never cuts, the stores paid from them, stores that are care or a bill,
    # and money sent to a person.
    def protected_names
      categories = @household.budget_categories.select { |category| SpendingPatterns::Analyzer.protected_category?(category.name) }
      merchants = @household.household_transactions.where(status: %w[confirmed reconciled])
        .joins(:transaction_splits).where(transaction_splits: { budget_category_id: categories.map(&:id) })
        .distinct.pluck(:merchant).map { |merchant| SpendingPatterns::MerchantName.call(merchant) }
      never_cut = patterns[:merchants].select { |row| row[:transfer_to_person] || SpendingPatterns::Analyzer.protected_merchant?(row[:label]) }.pluck(:label)
      (categories.map(&:name) + merchants + never_cut).compact_blank.uniq
    end

    # Stores that aren't a monthly habit once one-off payments are left out (SpendingPatterns::Analyzer),
    # with what was paid there: no monthly saving can come from them.
    def one_month_merchants
      patterns[:merchants].reject { |row| row[:monthly_habit] }
        .map { |row| { "label" => row[:label], "total_cents" => row[:total_cents], "months" => row[:observed_months].length } }
    end

    def patterns
      @patterns ||= SpendingPatterns::Analyzer.new(@household, today: @today, from: (@today - 365).iso8601, to: @today.iso8601).call
    end
  end
end
