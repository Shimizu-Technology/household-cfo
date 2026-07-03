module HouseholdFinance
  class AnnualBudgetManager
    MONTH_NAMES = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze
    SUPPORTED_YEARS = 2000..2100

    def self.supported_year?(value)
      SUPPORTED_YEARS.cover?(value.to_i)
    end

    attr_reader :year

    def initialize(household, year: Date.current.year)
      @household = household
      @year = year.to_i
    end

    def ensure_plan!
      return @budget_year if defined?(@budget_year) && @budget_year.present?

      @budget_year = household.with_lock { ensure_plan_records! }
    end

    def ensure_plan_inside_household_lock!
      return @budget_year if defined?(@budget_year) && @budget_year.present?

      @budget_year = ensure_plan_records!
    end

    def plan_data
      budget_year = ensure_plan!
      periods = budget_year.budget_periods.order(:starts_on).to_a
      categories = plan_categories(periods)
      allocations_by_category_and_period = BudgetAllocation
        .where(budget_category: categories, budget_period: periods)
        .index_by { |allocation| [ allocation.budget_category_id, allocation.budget_period_id ] }
      actuals = actuals_by_category_and_period(categories.map(&:id), periods)

      {
        year: budget_year.year,
        months: periods.map { |period| period_payload(period) },
        rows: categories.map do |category|
          category_payload(category, periods, allocations_by_category_and_period, actuals)
        end,
        monthly_income: monthly_income_by_period(periods),
        pending_transaction_drafts: pending_drafts_payload(budget_year),
        recent_transactions: recent_transactions_payload(periods),
        archived_categories: archived_categories_payload
      }
    end

    def create_category!(name:, stack_key:, monthly_amount: 0)
      budget_year = ensure_plan!
      category = nil
      household.with_lock do
        bounded = bounded_name(name)
        monthly_cents = parsed_monthly_amount_cents(monthly_amount)
        if (existing_category = household.budget_categories.where("LOWER(name) = ?", bounded.downcase).first)
          existing_category.errors.add(:name, "already exists. Edit the existing category instead.")
          raise ActiveRecord::RecordInvalid, existing_category
        end

        category = household.budget_categories.new(
          name: bounded,
          stack_key: stack_key.presence || "discretionary",
          active: true,
          sort_order: next_sort_order
        )
        category.save!
        sync_expense_item!(category, monthly_cents)
        apply_monthly_amount!(budget_year, category, monthly_cents, source: "manual")
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

    def restore_category!(category)
      budget_year = ensure_plan!
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id

      household.with_lock do
        category.lock!
        category.update!(active: true, sort_order: category.sort_order.to_i.positive? ? category.sort_order : next_sort_order)
        sync_expense_item_after_category_change!(category, category.name, category.stack_key)
        ensure_allocations_for_active_categories!(budget_year)
      end
      category
    end

    def update_allocation!(allocation, amount)
      budget_year = ensure_plan!
      raise ActiveRecord::RecordNotFound unless allocation.budget_category.household_id == household.id
      raise ActiveRecord::RecordNotFound unless allocation.budget_period.budget_year_id == budget_year.id

      allocation.update!(planned_amount_cents: Money.cents!(amount, message: "Planned amount must be a number"), source: "manual")
      allocation
    end

    def current_period_for(date)
      date = date.to_date
      raise ArgumentError, "Budget year is outside supported range" unless self.class.supported_year?(date.year)
      return period_for_year(date.year, date.month) unless date.year == year

      budget_year = ensure_plan!
      starts_on = Date.new(date.year, date.month, 1)
      budget_year.budget_periods.find_by(starts_on: starts_on) || period_for_year(date.year, date.month)
    end

    private

    attr_reader :household

    def ensure_plan_records!
      raise ArgumentError, "Budget year is outside supported range" unless self.class.supported_year?(year)

      budget_year = household.budget_years.find_or_create_by!(year: year) do |record|
        record.status = "active"
      end
      ensure_periods!(budget_year)
      ensure_categories_from_expenses!
      ensure_allocations_from_expenses!(budget_year)
      ensure_allocations_for_active_categories!(budget_year)
      budget_year
    end

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
        category = budget_category_for_active_expense(expense)
        next unless category

        category.assign_attributes(
          name: bounded_name(expense.label),
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
        category = active_budget_category_for_name(expense.label)
        next unless category

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

    def plan_categories(periods)
      active_ids = household.budget_categories.active.pluck(:id)
      actual_ids = category_ids_with_actuals(periods)
      household.budget_categories.where(id: (active_ids + actual_ids).uniq).ordered.to_a
    end

    def category_ids_with_actuals(periods)
      TransactionSplit
        .joins(:budget_category, :household_transaction)
        .where(budget_categories: { household_id: household.id })
        .where(household_transactions: { budget_period_id: periods.map(&:id), status: %w[confirmed reconciled] })
        .distinct
        .pluck(:budget_category_id)
    end

    def actuals_by_category_and_period(category_ids, periods)
      TransactionSplit
        .joins(:budget_category, :household_transaction)
        .where(budget_categories: { household_id: household.id })
        .where(budget_category_id: category_ids, household_transactions: { budget_period_id: periods.map(&:id), status: %w[confirmed reconciled] })
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

    def pending_drafts_payload(budget_year)
      household.transaction_drafts.pending.includes(:budget_category)
        .where(occurred_on: Date.new(budget_year.year, 1, 1)..Date.new(budget_year.year, 12, 31))
        .recent_first
        .limit(20)
        .map { |draft| draft_payload(draft) }
    end

    def recent_transactions_payload(periods)
      household.household_transactions
        .includes(transaction_splits: :budget_category)
        .where(budget_period_id: periods.map(&:id), status: %w[confirmed reconciled])
        .order(occurred_on: :desc, created_at: :desc)
        .limit(8)
        .map do |transaction|
          {
            id: transaction.id,
            occurred_on: transaction.occurred_on.iso8601,
            merchant: transaction.merchant,
            amount: Money.dollars(transaction.total_amount_cents),
            source_type: transaction.source_type,
            categories: transaction.transaction_splits.filter_map { |split| split.budget_category&.name }
          }
        end
    end

    def archived_categories_payload
      household.budget_categories.archived.ordered.map do |category|
        {
          id: category.id,
          name: category.name,
          stack_key: category.stack_key,
          stack_label: category.stack_label,
          active: category.active
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
        upsert_budget_allocation!(period, category, monthly_cents, source)
      end
    end

    def upsert_budget_allocation!(period, category, monthly_cents, source)
      BudgetAllocation.find_or_initialize_by(budget_period: period, budget_category: category).update!(
        planned_amount_cents: monthly_cents,
        source: source
      )
    rescue ActiveRecord::RecordNotUnique
      BudgetAllocation.find_by!(budget_period: period, budget_category: category).update!(
        planned_amount_cents: monthly_cents,
        source: source
      )
    end

    def sync_expense_item!(category, monthly_cents)
      expense = synced_expense_for(category)
      expense.update!(
        label: category.name,
        stack_key: category.stack_key,
        amount_cents: monthly_cents,
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
        .update_all(active: false, updated_at: Time.current)
    end

    def synced_expense_for(category)
      expenses = household.expense_items.where("LOWER(label) = ?", category.name.downcase).order(active: :desc, id: :asc).to_a
      expenses.find { |expense| expense.stack_key == category.stack_key } || expenses.first || household.expense_items.new(label: category.name)
    end

    def period_for_year(period_year, month)
      period_year = period_year.to_i
      raise ArgumentError, "Budget year is outside supported range" unless self.class.supported_year?(period_year)

      manager = self.class.new(household, year: period_year)
      budget_year = manager.ensure_plan!
      starts_on = Date.new(period_year, month.to_i, 1)
      budget_year.budget_periods.find_or_create_by!(starts_on: starts_on) do |period|
        period.ends_on = starts_on.end_of_month
        period.status = "open"
      end
    end

    def ensure_category_can_archive!(category)
      return unless category.transaction_drafts.pending.exists?

      category.errors.add(:base, "Category has pending drafts. Confirm, correct, or ignore those drafts before archiving.")
      raise ActiveRecord::RecordInvalid, category
    end

    def representative_planned_cents(category)
      category.budget_allocations.order(updated_at: :desc, id: :desc).first&.planned_amount_cents.to_i
    end

    def parsed_monthly_amount_cents(value)
      return 0 if value.blank?

      Money.cents!(value, message: "Planned amount must be a number")
    end

    def category_update_name(name, fallback:)
      return fallback if name.nil?

      name.to_s.squish.truncate(80, omission: "…").presence
    end

    def bounded_name(name)
      name.to_s.squish.truncate(80, omission: "…").presence || "Custom category"
    end

    def budget_category_for_active_expense(expense)
      active_budget_category_for_name(expense.label) || new_budget_category_unless_archived(expense.label)
    end

    def active_budget_category_for_name(name)
      bounded = bounded_name(name)
      household.budget_categories.active.where("LOWER(name) = ?", bounded.downcase).first
    end

    def new_budget_category_unless_archived(name)
      bounded = bounded_name(name)
      return if household.budget_categories.archived.where("LOWER(name) = ?", bounded.downcase).exists?

      household.budget_categories.new(name: bounded)
    end

    def next_sort_order
      household.budget_categories.maximum(:sort_order).to_i + 1
    end
  end
end
