module HouseholdFinance
  class AnnualBudgetManager
    MONTH_NAMES = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

    def initialize(household, year: Date.current.year)
      @household = household
      @year = year.to_i
    end

    def ensure_plan!
      return @budget_year if defined?(@budget_year) && @budget_year.present?

      @budget_year = household.with_lock do
        budget_year = household.budget_years.find_or_create_by!(year: year) do |record|
          record.status = "active"
        end
        ensure_periods!(budget_year)
        ensure_categories_from_expenses!
        ensure_allocations_from_expenses!(budget_year)
        ensure_allocations_for_active_categories!(budget_year)
        budget_year
      end
    end

    def plan_data
      budget_year = ensure_plan!
      periods = budget_year.budget_periods.order(:starts_on).to_a
      categories = household.budget_categories.active.ordered.to_a
      allocations_by_category_and_period = BudgetAllocation
        .where(budget_category: categories, budget_period: periods)
        .index_by { |allocation| [ allocation.budget_category_id, allocation.budget_period_id ] }
      actuals = actuals_by_category_and_period(categories, periods)

      {
        year: budget_year.year,
        months: periods.map { |period| period_payload(period) },
        rows: categories.map do |category|
          category_payload(category, periods, allocations_by_category_and_period, actuals)
        end,
        monthly_income: monthly_income_by_period(periods),
        pending_transaction_drafts: pending_drafts_payload,
        recent_transactions: recent_transactions_payload
      }
    end

    def create_category!(name:, stack_key:, monthly_amount: 0)
      budget_year = ensure_plan!
      category = nil
      household.with_lock do
        category = budget_category_for_name(bounded_name(name))
        category.assign_attributes(
          name: bounded_name(name),
          stack_key: stack_key.presence || "discretionary",
          active: true,
          sort_order: category.sort_order.to_i.positive? ? category.sort_order : next_sort_order
        )
        category.save!
        sync_expense_item!(category, monthly_amount)
        apply_monthly_amount!(budget_year, category, Money.cents(monthly_amount), source: "manual")
      end
      category
    end

    def update_category!(category, name:, stack_key:)
      ensure_plan!
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id

      household.with_lock do
        category.lock!
        old_name = category.name
        old_stack_key = category.stack_key
        category.assign_attributes(
          name: category_update_name(name, fallback: category.name),
          stack_key: stack_key.presence || category.stack_key
        )
        category.save!
        sync_expense_item_after_category_change!(category, old_name, old_stack_key)
      end
      category
    end

    def archive_category!(category)
      ensure_plan!
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id

      household.with_lock do
        category.lock!
        ensure_category_can_archive!(category)
        category.update!(active: false)
        archive_synced_expense_item!(category)
      end
      category
    end

    def update_allocation!(allocation, amount)
      budget_year = ensure_plan!
      raise ActiveRecord::RecordNotFound unless allocation.budget_category.household_id == household.id
      raise ActiveRecord::RecordNotFound unless allocation.budget_period.budget_year_id == budget_year.id

      allocation.update!(planned_amount_cents: Money.cents(amount), source: "manual")
      allocation
    end

    def current_period_for(date)
      budget_year = ensure_plan!
      date = date.to_date
      budget_year.budget_periods.where("starts_on <= ? AND ends_on >= ?", date, date).first || period_for_year(date.year, date.month)
    end

    private

    attr_reader :household, :year

    def ensure_periods!(budget_year)
      (1..12).each do |month|
        starts_on = Date.new(budget_year.year, month, 1)
        budget_year.budget_periods.find_or_create_by!(starts_on: starts_on) do |period|
          period.ends_on = starts_on.end_of_month
          period.status = "open"
        end
      end
    end

    def ensure_categories_from_expenses!
      active_expenses.each_with_index do |expense, index|
        category = budget_category_for_name(expense.label)
        category.assign_attributes(
          name: expense.label,
          stack_key: expense.stack_key,
          active: true,
          sort_order: category.sort_order.to_i.positive? ? category.sort_order : index + 1
        )
        category.save!
      end
    end

    def ensure_allocations_from_expenses!(budget_year)
      periods = budget_year.budget_periods.to_a
      active_expenses.each do |expense|
        category = budget_category_for_name(expense.label)
        monthly_cents = Money.monthly_cents(expense.amount_cents, expense.cadence)
        periods.each do |period|
          allocation = BudgetAllocation.find_or_initialize_by(budget_period: period, budget_category: category)
          next if allocation.persisted? && allocation.source == "manual"

          allocation.update!(planned_amount_cents: monthly_cents, source: "setup")
        end
      end
    end

    def ensure_allocations_for_active_categories!(budget_year)
      periods = budget_year.budget_periods.to_a
      household.budget_categories.active.find_each do |category|
        periods.each do |period|
          BudgetAllocation.find_or_create_by!(budget_period: period, budget_category: category) do |allocation|
            allocation.planned_amount_cents = 0
            allocation.source = "manual"
          end
        rescue ActiveRecord::RecordNotUnique
          next
        end
      end
    end

    def active_expenses
      @active_expenses ||= household.expense_items.where(active: true).order(:stack_key, :label).to_a
    end

    def actuals_by_category_and_period(categories, periods)
      TransactionSplit
        .joins(:household_transaction)
        .where(budget_category: categories, household_transactions: { budget_period_id: periods.map(&:id), status: %w[confirmed reconciled] })
        .group(:budget_category_id, "household_transactions.budget_period_id")
        .sum(:amount_cents)
    end

    def monthly_income_by_period(periods)
      monthly_income_cents = household.income_sources.where(active: true).sum { |income| Money.monthly_cents(income.amount_cents, income.cadence) }
      monthly_income = Money.dollars(monthly_income_cents)
      periods.index_with { monthly_income }.transform_keys(&:id)
    end

    def category_payload(category, periods, allocations, actuals)
      month_cells = periods.map do |period|
        allocation = allocations[[ category.id, period.id ]]
        actual_cents = actuals[[ category.id, period.id ]] || 0
        allocation ? allocation_cell(period, allocation, actual_cents) : missing_allocation_cell(period, category, actual_cents)
      end

      {
        id: category.id,
        name: category.name,
        stack_key: category.stack_key,
        stack_label: category.stack_label,
        active: category.active,
        months: month_cells,
        planned_total: month_cells.sum { |cell| cell[:planned] },
        actual_total: month_cells.sum { |cell| cell[:actual] }
      }
    end

    def allocation_cell(period, allocation, actual_cents)
      {
        period_id: period.id,
        allocation_id: allocation.id,
        planned: Money.dollars(allocation.planned_amount_cents),
        actual: Money.dollars(actual_cents),
        remaining: Money.dollars(allocation.planned_amount_cents - actual_cents),
        allocation_missing: false
      }
    end

    def missing_allocation_cell(period, category, actual_cents)
      Rails.logger.warn("Missing budget allocation for category_id=#{category.id} period_id=#{period.id}")
      {
        period_id: period.id,
        allocation_id: nil,
        planned: 0,
        actual: Money.dollars(actual_cents),
        remaining: Money.dollars(-actual_cents),
        allocation_missing: true
      }
    end

    def period_payload(period)
      {
        id: period.id,
        label: MONTH_NAMES.fetch(period.starts_on.month - 1),
        starts_on: period.starts_on.iso8601,
        ends_on: period.ends_on.iso8601,
        status: period.status
      }
    end

    def pending_drafts_payload
      household.transaction_drafts.pending.includes(:budget_category).recent_first.limit(20).map { |draft| draft_payload(draft) }
    end

    def recent_transactions_payload
      household.household_transactions
        .includes(transaction_splits: :budget_category)
        .where(status: %w[confirmed reconciled])
        .order(occurred_on: :desc, created_at: :desc)
        .limit(8)
        .map do |transaction|
          {
            id: transaction.id,
            occurred_on: transaction.occurred_on.iso8601,
            merchant: transaction.merchant,
            amount: Money.dollars(transaction.total_amount_cents),
            source_type: transaction.source_type,
            categories: transaction.transaction_splits.map { |split| split.budget_category.name }
          }
        end
    end

    def draft_payload(draft)
      {
        id: draft.id,
        occurred_on: draft.occurred_on.iso8601,
        merchant: draft.merchant,
        amount: Money.dollars(draft.total_amount_cents),
        status: draft.status,
        source_type: draft.source_type,
        category_id: draft.budget_category_id,
        category_name: draft.budget_category&.name,
        stack_label: draft.budget_category&.stack_label,
        summary: draft_summary(draft)
      }
    end

    def draft_summary(draft)
      category = draft.budget_category&.name || "Uncategorized"
      "#{draft.merchant} — #{ActiveSupport::NumberHelper.number_to_currency(Money.dollars(draft.total_amount_cents), precision: 2)} — #{category}"
    end

    def apply_monthly_amount!(budget_year, category, monthly_cents, source:)
      budget_year.budget_periods.find_each do |period|
        BudgetAllocation.find_or_initialize_by(budget_period: period, budget_category: category).update!(
          planned_amount_cents: monthly_cents,
          source: source
        )
      end
    end

    def sync_expense_item!(category, monthly_amount)
      expense = synced_expense_for(category)
      expense.update!(
        label: category.name,
        stack_key: category.stack_key,
        amount_cents: Money.cents(monthly_amount),
        cadence: "monthly",
        active: true
      )
      household.expense_items.where("LOWER(label) = ?", category.name.downcase).where.not(id: expense.id).update_all(active: false, updated_at: Time.current)
    end

    def sync_expense_item_after_category_change!(category, old_name, old_stack_key)
      expense = household.expense_items
        .where("LOWER(label) = ?", old_name.downcase)
        .where(stack_key: old_stack_key)
        .order(active: :desc, id: :asc)
        .first || synced_expense_for(category)
      expense.amount_cents = representative_planned_cents(category) if expense.new_record?
      expense.update!(label: category.name, stack_key: category.stack_key, cadence: "monthly", active: category.active?)
      household.expense_items.where("LOWER(label) = ?", old_name.downcase).where.not(id: expense.id).update_all(active: false, updated_at: Time.current)
      household.expense_items.where("LOWER(label) = ?", category.name.downcase).where.not(id: expense.id).update_all(active: false, updated_at: Time.current)
    end

    def archive_synced_expense_item!(category)
      household.expense_items
        .where("LOWER(label) = ?", category.name.downcase)
        .where(stack_key: category.stack_key)
        .update_all(active: false, updated_at: Time.current)
    end

    def synced_expense_for(category)
      expenses = household.expense_items.where("LOWER(label) = ?", category.name.downcase).order(active: :desc, id: :asc).to_a
      expenses.find { |expense| expense.stack_key == category.stack_key } || expenses.first || household.expense_items.new(label: category.name)
    end

    def period_for_year(period_year, month)
      manager = self.class.new(household, year: period_year)
      manager.ensure_plan!
      household.budget_years.find_by!(year: period_year).budget_periods.find_by!(starts_on: Date.new(period_year, month, 1))
    end

    def ensure_category_can_archive!(category)
      return unless category.transaction_splits.exists? || category.transaction_drafts.pending.exists?

      category.errors.add(:base, "Category has transaction history or pending drafts. Rename or reclassify it instead of archiving.")
      raise ActiveRecord::RecordInvalid, category
    end

    def representative_planned_cents(category)
      category.budget_allocations.order(updated_at: :desc, id: :desc).first&.planned_amount_cents.to_i
    end

    def category_update_name(name, fallback:)
      return fallback if name.nil?

      name.to_s.squish.truncate(80, omission: "…").presence
    end

    def bounded_name(name)
      name.to_s.squish.truncate(80, omission: "…").presence || "Custom category"
    end

    def budget_category_for_name(name)
      bounded = bounded_name(name)
      household.budget_categories.where("LOWER(name) = ?", bounded.downcase).first_or_initialize
    end

    def next_sort_order
      household.budget_categories.maximum(:sort_order).to_i + 1
    end
  end
end
