module HouseholdFinance
  class SpendingReport
    MAX_TRANSACTIONS = 100
    MAX_RANGE_DAYS = 400
    YEAR_RANGE = 2000..2100

    def initialize(household, start_on:, end_on:)
      @household = household
      @start_on = start_on.to_date
      @end_on = end_on.to_date
      raise ArgumentError, "end_on before start_on" if @end_on < @start_on
      raise ArgumentError, "report range is too large" if (@end_on - @start_on).to_i > MAX_RANGE_DAYS
      raise ArgumentError, "report year is out of range" unless YEAR_RANGE.cover?(@start_on.year) && YEAR_RANGE.cover?(@end_on.year)
    end

    def as_json
      ensure_plans!
      rows = category_rows

      {
        period_label: period_label,
        start_on: start_on.iso8601,
        end_on: end_on.iso8601,
        totals: {
          planned: Money.dollars(rows.sum { |row| row.fetch(:planned_cents) }),
          actual: Money.dollars(rows.sum { |row| row.fetch(:actual_cents) }),
          pending: Money.dollars(rows.sum { |row| row.fetch(:pending_cents) }),
          remaining: Money.dollars(rows.sum { |row| row.fetch(:planned_cents) - row.fetch(:actual_cents) })
        },
        categories: rows.map { |row| category_payload(row) },
        transactions: transactions_payload,
        pending_drafts: pending_drafts_payload
      }
    end

    private

    attr_reader :household, :start_on, :end_on

    def ensure_plans!
      household.with_lock do
        (start_on.year..end_on.year).each do |year|
          AnnualBudgetManager.new(household, year: year).ensure_plan_inside_household_lock!
        end
      end
    end

    def category_rows
      @category_rows ||= begin
        ids = (allocation_sums.keys + actual_sums.keys + pending_sums.keys + active_category_ids).compact.uniq
        categories = household.budget_categories.where(id: ids).ordered.index_by(&:id)
        ids.filter_map do |id|
          category = categories[id]
          next unless category

          {
            category: category,
            planned_cents: allocation_sums[id].to_i,
            actual_cents: actual_sums[id].to_i,
            pending_cents: pending_sums[id].to_i
          }
        end.sort_by { |row| [ row.fetch(:category).sort_order, row.fetch(:category).name ] }
      end
    end

    def active_category_ids
      household.budget_categories.active.pluck(:id)
    end

    def allocation_sums
      @allocation_sums ||= BudgetAllocation
        .joins(:budget_category, budget_period: :budget_year)
        .where(budget_categories: { household_id: household.id, active: true })
        .where(budget_years: { household_id: household.id })
        .where("budget_periods.starts_on <= ? AND budget_periods.ends_on >= ?", end_on, start_on)
        .group(:budget_category_id)
        .sum(:planned_amount_cents)
    end

    def actual_sums
      @actual_sums ||= TransactionSplit
        .joins(:budget_category, :household_transaction)
        .where(budget_categories: { household_id: household.id, active: true })
        .where(household_transactions: { household_id: household.id, status: %w[confirmed reconciled], occurred_on: start_on..end_on })
        .group(:budget_category_id)
        .sum(:amount_cents)
    end

    def pending_sums
      @pending_sums ||= household.transaction_drafts.pending
        .joins(:budget_category)
        .where(budget_categories: { active: true })
        .where(occurred_on: start_on..end_on)
        .group(:budget_category_id)
        .sum(:total_amount_cents)
    end

    def transactions_payload
      household.household_transactions
        .includes(transaction_splits: :budget_category)
        .joins(transaction_splits: :budget_category)
        .where(budget_categories: { active: true })
        .where(status: %w[confirmed reconciled], occurred_on: start_on..end_on)
        .distinct
        .order(occurred_on: :desc, created_at: :desc)
        .limit(MAX_TRANSACTIONS)
        .map do |transaction|
          {
            id: transaction.id,
            occurred_on: transaction.occurred_on.iso8601,
            merchant: transaction.merchant,
            amount: Money.dollars(transaction.total_amount_cents),
            source_type: transaction.source_type,
            categories: transaction.transaction_splits.filter_map { |split| split.budget_category.name if split.budget_category.active? }
          }
        end
    end

    def pending_drafts_payload
      household.transaction_drafts.pending.includes(:budget_category)
        .joins(:budget_category)
        .where(budget_categories: { active: true })
        .where(occurred_on: start_on..end_on)
        .recent_first
        .limit(MAX_TRANSACTIONS)
        .map do |draft|
          {
            id: draft.id,
            occurred_on: draft.occurred_on.iso8601,
            merchant: draft.merchant,
            amount: Money.dollars(draft.total_amount_cents),
            category_id: draft.budget_category_id,
            category_name: draft.budget_category&.name
          }
        end
    end

    def category_payload(row)
      category = row.fetch(:category)
      planned_cents = row.fetch(:planned_cents)
      actual_cents = row.fetch(:actual_cents)
      pending_cents = row.fetch(:pending_cents)

      {
        id: category.id,
        name: category.name,
        stack_key: category.stack_key,
        stack_label: category.stack_label,
        planned: Money.dollars(planned_cents),
        actual: Money.dollars(actual_cents),
        pending: Money.dollars(pending_cents),
        remaining: Money.dollars(planned_cents - actual_cents)
      }
    end

    def period_label
      if start_on == start_on.beginning_of_month && end_on == start_on.end_of_month
        start_on.strftime("%B %Y")
      elsif start_on == start_on.beginning_of_year && end_on == start_on.end_of_year
        start_on.year.to_s
      else
        "#{start_on.strftime('%b %-d, %Y')} – #{end_on.strftime('%b %-d, %Y')}"
      end
    end
  end
end
