# frozen_string_literal: true

module HouseholdFinance
  # Read-only monthly close: actuals vs. plan for income and every category,
  # plus what changed from the prior month. Never writes to the database and
  # never turns unknown income or missing statements into $0.
  class MonthlyClose
    STATUS_LABELS = {
      "future" => "Upcoming month",
      "open" => "Month in progress",
      "partial" => "Partial statements",
      "complete" => "Month closed",
      "no_actuals" => "No actuals yet"
    }.freeze
    MAX_MOVERS = 3

    def initialize(
      household,
      year:,
      month:,
      annual_plan: nil,
      prior_annual_plan: nil,
      method: nil,
      today: Time.current.in_time_zone("Pacific/Guam").to_date
    )
      @household = household
      @year = parse_year!(year)
      @month = parse_month!(month)
      @supplied_annual_plan = annual_plan
      @supplied_prior_annual_plan = prior_annual_plan
      @method = method || CohortExperience::MethodSettings.for_household(household)
      @today = today.to_date
    end

    def call
      target_date = Date.new(year, month, 1)
      prior_date = target_date.prev_month
      target_end = target_date.end_of_month
      prior_end = prior_date.end_of_month

      plan = current_plan
      prev_plan = prior_plan(prior_date)
      plan_available = plan.fetch(:plan_available, true) == true
      coverage_start = plan_coverage.starts_on
      before_plan_start = target_date < coverage_start

      target_period = Array(plan[:months])[month - 1].to_h
      prior_period = prev_plan ? Array(prev_plan[:months])[prior_date.month - 1].to_h : {}
      target_period_id = target_period[:id]
      prior_period_id = prior_period[:id]

      income_actual = actual_income_reader.month(target_date)
      prior_income_actual = AnnualBudgetManager.supported_year?(prior_date.year) ? actual_income_reader.month(prior_date) : nil

      income_value = plan_available && !before_plan_start ? lookup_monthly_income(plan, target_period_id) : nil
      planned_income_cents = income_value.nil? ? nil : Money.cents(income_value)
      income_complete = !income_actual[:actual_cents].nil? && !income_actual[:partial] && !income_actual[:month_open]
      prior_income_complete = !prior_income_actual.nil? && !prior_income_actual[:actual_cents].nil? && !prior_income_actual[:partial] && !prior_income_actual[:month_open]
      income_difference_cents = income_complete && !planned_income_cents.nil? ? income_actual[:actual_cents] - planned_income_cents : nil
      income_change_from_prior_cents = income_complete && prior_income_complete ? income_actual[:actual_cents] - prior_income_actual[:actual_cents] : nil

      activity_sets = activity_category_sets(
        target_period_id: target_period_id,
        target_range: target_date..target_end,
        target_rows: Array(plan[:rows]),
        prior_period_id: prior_period_id,
        prior_range: prior_date..prior_end,
        prior_rows: prev_plan ? Array(prev_plan[:rows]) : [],
        prior_month_index: prior_date.month - 1
      )
      target_active_ids = activity_sets.fetch(:target)
      prior_active_ids = activity_sets.fetch(:prior)
      target_month_has_activity = target_active_ids.any?
      prior_month_has_activity = prior_active_ids.any?

      category_items = build_category_items(
        plan: plan,
        prev_plan: prev_plan,
        prior_month_index: prior_date.month - 1,
        plan_available: plan_available,
        before_plan_start: before_plan_start,
        target_active_ids: target_active_ids,
        prior_active_ids: prior_active_ids,
        target_month_has_activity: target_month_has_activity,
        prior_month_has_activity: prior_month_has_activity
      )

      planned_spending_cents = compute_planned_spending_cents(category_items, plan_available: plan_available, before_plan_start: before_plan_start)
      actual_spending_cents = target_month_has_activity ? category_items.sum { |item| item.fetch(:actual_cents) } : nil
      spending_difference_cents = !actual_spending_cents.nil? && !planned_spending_cents.nil? ? actual_spending_cents - planned_spending_cents : nil
      prior_actual_spending_cents = prior_month_has_activity ? category_items.sum { |item| item[:prior_actual_cents].to_i } : nil
      spending_change_from_prior_cents = !actual_spending_cents.nil? && !prior_actual_spending_cents.nil? ? actual_spending_cents - prior_actual_spending_cents : nil

      debt_minimums_known = !before_plan_start && plan[:monthly_debt_minimums_known] == true
      debt_minimums_cents = debt_minimums_known ? Money.cents(plan[:monthly_debt_minimums]) : nil

      planned_net_before_debt_cents = !planned_income_cents.nil? && !planned_spending_cents.nil? ? planned_income_cents - planned_spending_cents : nil
      actual_net_before_debt_cents = income_complete && target_month_has_activity ? income_actual[:actual_cents] - actual_spending_cents : nil
      net_before_debt_difference_cents = !actual_net_before_debt_cents.nil? && !planned_net_before_debt_cents.nil? ? actual_net_before_debt_cents - planned_net_before_debt_cents : nil

      planned_net_after_debt_cents = !planned_net_before_debt_cents.nil? && debt_minimums_known ? planned_net_before_debt_cents - debt_minimums_cents : nil
      actual_net_after_debt_cents = !actual_net_before_debt_cents.nil? && debt_minimums_known ? actual_net_before_debt_cents - debt_minimums_cents : nil
      net_after_debt_difference_cents = !actual_net_after_debt_cents.nil? && !planned_net_after_debt_cents.nil? ? actual_net_after_debt_cents - planned_net_after_debt_cents : nil

      status = determine_status(target_date: target_date, target_end: target_end, income_actual: income_actual, target_month_has_activity: target_month_has_activity)
      changes = build_changes(
        category_items: category_items,
        prior_month_has_activity: prior_month_has_activity,
        target_month_has_activity: target_month_has_activity,
        prior_period_label: prior_date.strftime("%B %Y"),
        income_complete: income_complete,
        prior_income_complete: prior_income_complete,
        income_actual_cents: income_actual[:actual_cents],
        prior_income_actual_cents: prior_income_actual&.dig(:actual_cents),
        income_change_from_prior_cents: income_change_from_prior_cents
      )

      income_payload = {
        planned_cents: planned_income_cents,
        actual_cents: income_actual[:actual_cents],
        difference_cents: income_difference_cents,
        prior_month_actual_cents: prior_income_actual&.dig(:actual_cents),
        prior_month_complete: prior_income_complete,
        change_from_prior_cents: income_change_from_prior_cents,
        complete: income_complete,
        partial: income_actual[:partial],
        month_open: income_actual[:month_open],
        waiting_deposits: income_actual[:waiting_deposits],
        coverage_note: income_actual[:coverage_note]
      }

      totals_payload = {
        planned_spending_cents: planned_spending_cents,
        actual_spending_cents: actual_spending_cents,
        spending_difference_cents: spending_difference_cents,
        prior_actual_spending_cents: prior_actual_spending_cents,
        spending_change_from_prior_cents: spending_change_from_prior_cents,
        has_spending_activity: target_month_has_activity,
        prior_month_has_activity: prior_month_has_activity,
        debt_minimums_cents: debt_minimums_cents,
        debt_minimums_known: debt_minimums_known
      }

      highlights = build_highlights(
        status: status,
        period_label: target_date.strftime("%B %Y"),
        prior_period_label: prior_date.strftime("%B %Y"),
        before_plan_start: before_plan_start,
        income: income_payload,
        totals: totals_payload,
        categories: category_items,
        changes: changes
      )

      {
        year: year,
        month: month,
        period_id: target_period_id,
        period_label: target_date.strftime("%B %Y"),
        starts_on: target_date.iso8601,
        ends_on: target_end.iso8601,
        prior_year: prior_date.year,
        prior_month: prior_date.month,
        prior_period_label: prior_date.strftime("%B %Y"),
        plan_available: plan_available,
        plan_starts_on: coverage_start.iso8601,
        before_plan_start: before_plan_start,
        status: status,
        status_label: STATUS_LABELS.fetch(status),
        household_id: household.id,
        financial_generation: household.financial_generation,
        income: income_payload,
        totals: totals_payload,
        net: {
          planned_net_before_debt_cents: planned_net_before_debt_cents,
          actual_net_before_debt_cents: actual_net_before_debt_cents,
          net_before_debt_difference_cents: net_before_debt_difference_cents,
          planned_net_after_debt_cents: planned_net_after_debt_cents,
          actual_net_after_debt_cents: actual_net_after_debt_cents,
          net_after_debt_difference_cents: net_after_debt_difference_cents
        },
        categories: category_items,
        changes: changes,
        highlights: highlights
      }
    end

    private

    attr_reader :household, :year, :month, :method, :today

    def parse_year!(value)
      parsed = Integer(value.to_s, 10)
      unless AnnualBudgetManager.supported_year?(parsed)
        raise ArgumentError, "Year must be between #{AnnualBudgetManager::SUPPORTED_YEARS.min} and #{AnnualBudgetManager::SUPPORTED_YEARS.max}"
      end

      parsed
    rescue ArgumentError
      raise ArgumentError, "Year must be between #{AnnualBudgetManager::SUPPORTED_YEARS.min} and #{AnnualBudgetManager::SUPPORTED_YEARS.max}"
    end

    def parse_month!(value)
      parsed = Integer(value.to_s, 10)
      raise ArgumentError, "Month must be between 1 and 12" unless (1..12).cover?(parsed)

      parsed
    rescue ArgumentError
      raise ArgumentError, "Month must be between 1 and 12"
    end

    def plan_coverage
      @plan_coverage ||= PlanCoverage.new(household)
    end

    def actual_income_reader
      @actual_income_reader ||= ActualIncome.new(household, today: today)
    end

    def current_plan
      @current_plan ||= begin
        if supplied_plan_matches?(@supplied_annual_plan, year)
          @supplied_annual_plan.deep_symbolize_keys
        else
          AnnualBudgetManager.new(household, year: year).read_only_plan_data.deep_symbolize_keys
        end
      end
    end

    def prior_plan(prior_date)
      return current_plan if prior_date.year == year
      return nil unless AnnualBudgetManager.supported_year?(prior_date.year)

      if supplied_plan_matches?(@supplied_prior_annual_plan, prior_date.year)
        @supplied_prior_annual_plan.deep_symbolize_keys
      else
        AnnualBudgetManager.new(household, year: prior_date.year).read_only_plan_data.deep_symbolize_keys
      end
    end

    def supplied_plan_matches?(candidate, expected_year)
      return false unless candidate.is_a?(Hash)

      (candidate[:year] || candidate["year"]).to_i == expected_year
    end

    def lookup_monthly_income(plan, period_id)
      return nil if period_id.nil?

      incomes = plan[:monthly_income].to_h
      return incomes[period_id] if incomes.key?(period_id)
      return incomes[period_id.to_s] if incomes.key?(period_id.to_s)
      return incomes[period_id.to_sym] if period_id.respond_to?(:to_sym) && incomes.key?(period_id.to_sym)

      nil
    end

    def activity_category_sets(target_period_id:, target_range:, target_rows:, prior_period_id:, prior_range:, prior_rows:, prior_month_index:)
      target_ids = Set.new
      prior_ids = Set.new

      target_rows.each do |row|
        next unless row[:id].to_i.positive?

        cell = Array(row[:months])[month - 1].to_h
        target_ids.add(row[:id]) if Money.cents(cell[:actual]).nonzero?
      end

      prior_rows.each do |row|
        next unless row[:id].to_i.positive?

        cell = Array(row[:months])[prior_month_index].to_h
        prior_ids.add(row[:id]) if Money.cents(cell[:actual]).nonzero?
      end

      persisted_period_ids = [ target_period_id, prior_period_id ].select { |id| id.is_a?(Integer) }.uniq
      if persisted_period_ids.any?
        split_pairs = TransactionSplit
          .joins(:budget_category, :household_transaction)
          .where(budget_categories: { household_id: household.id, financial_generation: household.financial_generation })
          .where(household_transactions: { budget_period_id: persisted_period_ids, status: %w[confirmed reconciled] })
          .distinct
          .pluck(:budget_category_id, "household_transactions.budget_period_id")

        split_pairs.each do |category_id, period_id|
          target_ids.add(category_id) if period_id == target_period_id
          prior_ids.add(category_id) if period_id == prior_period_id
        end

        combined_from = [ target_range.begin, prior_range.begin ].min
        combined_to = [ target_range.end, prior_range.end ].max
        RefundCredits.new(household, from: combined_from, to: combined_to).counted.each do |credit|
          if target_period_id.is_a?(Integer) && target_range.cover?(credit.posted_on)
            credit.allocations.each { |part| target_ids.add(part[:category_id]) }
          end
          if prior_period_id.is_a?(Integer) && prior_range.cover?(credit.posted_on)
            credit.allocations.each { |part| prior_ids.add(part[:category_id]) }
          end
        end

        CashDrawdowns.new(household).call.each do |drawdown|
          withdrawn_period = drawdown.withdrawal.budget_period_id
          purchased_period = drawdown.purchase.budget_period_id

          if withdrawn_period == target_period_id
            drawdown.cash_parts.each { |part| target_ids.add(part[:category_id]) }
            drawdown.purchase_parts.each { |part| target_ids.add(part[:category_id]) }
          end
          if purchased_period == target_period_id
            drawdown.purchase_parts.each { |part| target_ids.add(part[:category_id]) }
          end

          if withdrawn_period == prior_period_id
            drawdown.cash_parts.each { |part| prior_ids.add(part[:category_id]) }
            drawdown.purchase_parts.each { |part| prior_ids.add(part[:category_id]) }
          end
          if purchased_period == prior_period_id
            drawdown.purchase_parts.each { |part| prior_ids.add(part[:category_id]) }
          end
        end
      end

      { target: target_ids, prior: prior_ids }
    end

    def build_category_items(
      plan:,
      prev_plan:,
      prior_month_index:,
      plan_available:,
      before_plan_start:,
      target_active_ids:,
      prior_active_ids:,
      target_month_has_activity:,
      prior_month_has_activity:
    )
      target_rows_by_id = Array(plan[:rows]).select { |row| row[:id].to_i.positive? }.index_by { |row| row[:id] }
      prior_rows_by_id = Array(prev_plan&.dig(:rows)).select { |row| row[:id].to_i.positive? }.index_by { |row| row[:id] }

      ordered_ids = (target_rows_by_id.keys + prior_rows_by_id.keys).uniq
      ordered_ids.filter_map do |category_id|
        target_row = target_rows_by_id[category_id]
        prior_row = prior_rows_by_id[category_id]
        source_row = target_row || prior_row
        active = source_row[:active] == true

        target_cell = target_row ? Array(target_row[:months])[month - 1].to_h : {}
        prior_cell = prior_row ? Array(prior_row[:months])[prior_month_index].to_h : {}

        actual_cents = Money.cents(target_cell[:actual])
        prior_cents = Money.cents(prior_cell[:actual])
        has_activity = target_active_ids.include?(category_id)
        prior_has_activity = prior_active_ids.include?(category_id)

        next unless active || has_activity || prior_has_activity || actual_cents.nonzero? || prior_cents.nonzero?

        planned_cents = if !plan_available || before_plan_start
          nil
        elsif !active
          0
        elsif target_cell.empty? || target_cell[:allocation_missing] == true
          nil
        else
          Money.cents(target_cell[:planned])
        end

        difference_cents = !planned_cents.nil? && target_month_has_activity ? actual_cents - planned_cents : nil
        prior_actual_cents = prior_month_has_activity ? prior_cents : nil
        change_from_prior_cents = prior_month_has_activity && target_month_has_activity ? actual_cents - prior_cents : nil

        stack_key = source_row[:stack_key].to_s
        {
          id: category_id,
          name: source_row[:name],
          stack_key: stack_key,
          stack_label: ExpenseGroups.label(stack_key, method),
          active: active,
          planned_cents: planned_cents,
          actual_cents: actual_cents,
          difference_cents: difference_cents,
          prior_actual_cents: prior_actual_cents,
          change_from_prior_cents: change_from_prior_cents,
          has_activity: has_activity,
          prior_has_activity: prior_has_activity,
          refund_net_negative: actual_cents.negative?
        }
      end
    end

    def compute_planned_spending_cents(category_items, plan_available:, before_plan_start:)
      return nil if !plan_available || before_plan_start

      active_items = category_items.select { |item| item[:active] }
      if active_items.empty?
        confirmed = SetupStatus.new(household).confirmed_field_keys
        return %w[fixed_expenses flexible_spend].all? { |field| confirmed.include?(field) } ? 0 : nil
      end

      return nil if active_items.any? { |item| item[:planned_cents].nil? }

      active_items.sum { |item| item[:planned_cents] }
    end

    def determine_status(target_date:, target_end:, income_actual:, target_month_has_activity:)
      return "future" if target_date > today
      return "open" if today.between?(target_date, target_end)
      return "no_actuals" if income_actual[:actual_cents].nil? && !target_month_has_activity
      return "partial" if income_actual[:partial] || income_actual[:actual_cents].nil?

      "complete"
    end

    def build_changes(
      category_items:,
      prior_month_has_activity:,
      target_month_has_activity:,
      prior_period_label:,
      income_complete:,
      prior_income_complete:,
      income_actual_cents:,
      prior_income_actual_cents:,
      income_change_from_prior_cents:
    )
      if prior_month_has_activity && target_month_has_activity
        increases = category_items
          .select { |item| item[:change_from_prior_cents].to_i.positive? }
          .sort_by { |item| [ -item[:change_from_prior_cents], item[:name].to_s.downcase ] }
          .first(MAX_MOVERS)
          .map { |item| mover_payload(item) }

        decreases = category_items
          .select { |item| item[:change_from_prior_cents].to_i.negative? }
          .sort_by { |item| [ item[:change_from_prior_cents], item[:name].to_s.downcase ] }
          .first(MAX_MOVERS)
          .map { |item| mover_payload(item) }
      else
        increases = []
        decreases = []
      end

      income_change = if income_complete && prior_income_complete && income_change_from_prior_cents.to_i.nonzero?
        {
          actual_cents: income_actual_cents,
          prior_actual_cents: prior_income_actual_cents,
          change_from_prior_cents: income_change_from_prior_cents
        }
      end

      {
        prior_month_has_activity: prior_month_has_activity,
        prior_period_label: prior_period_label,
        increases: increases,
        decreases: decreases,
        income_change: income_change
      }
    end

    def mover_payload(item)
      {
        category_id: item[:id],
        name: item[:name],
        stack_key: item[:stack_key],
        stack_label: item[:stack_label],
        active: item[:active],
        actual_cents: item[:actual_cents],
        prior_actual_cents: item[:prior_actual_cents],
        change_from_prior_cents: item[:change_from_prior_cents]
      }
    end

    def build_highlights(status:, period_label:, prior_period_label:, before_plan_start:, income:, totals:, categories:, changes:)
      lines = []

      if status == "future"
        lines << "#{period_label} has not started yet, so actual income and spending are not in yet."
        unless totals[:planned_spending_cents].nil?
          debt_clause = totals[:debt_minimums_known] && totals[:debt_minimums_cents].to_i.positive? ? ", plus #{Money.plain(totals[:debt_minimums_cents])} in monthly debt payments" : ""
          lines << "Planned category spending for #{period_label} is #{Money.plain(totals[:planned_spending_cents])}#{debt_clause}."
        end
        return lines
      end

      lines << income_highlight(period_label: period_label, income: income)
      lines << spending_highlight(period_label: period_label, before_plan_start: before_plan_start, totals: totals)

      if (mover_line = mover_highlight(prior_period_label: prior_period_label, totals: totals, changes: changes))
        lines << mover_line
      end

      top_over = categories
        .select { |item| item[:active] && item[:difference_cents].to_i.positive? }
        .max_by { |item| [ item[:difference_cents], item[:name].to_s ] }
      if top_over
        lines << "#{top_over[:name]} finished #{Money.plain(top_over[:difference_cents])} over plan — review whether to adjust its monthly target."
      elsif income[:waiting_deposits].to_i.positive?
        lines << ActualIncome.waiting_note(income[:waiting_deposits])
      end

      lines.first(4)
    end

    def income_highlight(period_label:, income:)
      actual = income[:actual_cents]
      planned = income[:planned_cents]
      diff = income[:difference_cents]

      if income[:complete] && !planned.nil?
        if diff.zero?
          "Money in matched the #{Money.plain(planned)} plan in #{period_label}."
        elsif diff.positive?
          "Money in came in at #{Money.plain(actual)}, #{Money.plain(diff)} above the #{Money.plain(planned)} plan."
        else
          "Money in came in at #{Money.plain(actual)}, #{Money.plain(-diff)} under the #{Money.plain(planned)} plan."
        end
      elsif income[:complete]
        "Approved statements show #{Money.plain(actual)} in for #{period_label}, with no income plan to compare against."
      elsif !actual.nil?
        "#{Money.plain(actual)} in approved income is recorded so far for #{period_label}; full income vs. plan waits for complete statements."
      else
        "Approved income for #{period_label} is not known yet."
      end
    end

    def spending_highlight(period_label:, before_plan_start:, totals:)
      unless totals[:has_spending_activity]
        return "No confirmed category spending is recorded for #{period_label} yet."
      end

      actual = totals[:actual_spending_cents]
      planned = totals[:planned_spending_cents]
      diff = totals[:spending_difference_cents]

      if !planned.nil? && !diff.nil?
        if diff.positive?
          "Category spending totaled #{Money.plain(actual)}, #{Money.plain(diff)} over the #{Money.plain(planned)} plan."
        elsif diff.negative?
          "Category spending totaled #{Money.plain(actual)}, #{Money.plain(-diff)} under the #{Money.plain(planned)} plan."
        else
          "Category spending matched the #{Money.plain(planned)} plan."
        end
      elsif before_plan_start
        "Confirmed category spending totaled #{Money.plain(actual)} in #{period_label}, before your plan started."
      else
        "Confirmed category spending totaled #{Money.plain(actual)} in #{period_label}, with no full category plan to compare against."
      end
    end

    def mover_highlight(prior_period_label:, totals:, changes:)
      return nil unless totals[:has_spending_activity]

      unless changes[:prior_month_has_activity]
        return "No confirmed activity in #{prior_period_label}, so month-over-month changes are not available yet."
      end

      inc = changes[:increases].first
      dec = changes[:decreases].first
      if inc && dec
        "Compared with #{prior_period_label}, #{inc[:name]} rose the most (+#{Money.plain(inc[:change_from_prior_cents])}) while #{dec[:name]} dropped the most (-#{Money.plain(-dec[:change_from_prior_cents])})."
      elsif inc
        "Compared with #{prior_period_label}, #{inc[:name]} increased the most (+#{Money.plain(inc[:change_from_prior_cents])})."
      elsif dec
        "Compared with #{prior_period_label}, #{dec[:name]} decreased the most (-#{Money.plain(-dec[:change_from_prior_cents])})."
      else
        "Category spending was unchanged from #{prior_period_label}."
      end
    end
  end
end
