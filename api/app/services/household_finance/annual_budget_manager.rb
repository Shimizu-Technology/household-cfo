module HouseholdFinance
  class AnnualBudgetManager
    MONTH_NAMES = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze
    SUPPORTED_YEARS = 2000..2100
    MAX_PENDING_TRANSACTION_DRAFTS = 500

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
      plan_data_for(budget_year).merge(plan_available: true)
    end

    def read_only_plan_data
      budget_year = household.budget_years.find_by(year: year)
      periods = budget_year&.budget_periods&.order(:starts_on)&.to_a || []
      return plan_data_for(budget_year).merge(plan_available: true) if periods.length == 12

      read_only_plan_preview
    end

    def plan_data_for(budget_year)
      periods = budget_year.budget_periods.order(:starts_on).to_a
      categories = plan_categories(periods)
      allocations_by_category_and_period = BudgetAllocation
        .where(budget_category: categories, budget_period: periods)
        .index_by { |allocation| [ allocation.budget_category_id, allocation.budget_period_id ] }
      actuals = actuals_by_category_and_period(categories.map(&:id), periods)

      rows = categories.map do |category|
        category_payload(category, periods, allocations_by_category_and_period, actuals)
      end
      monthly_income = monthly_income_by_period(periods)
      debt_portfolio = DebtPortfolio.new(household)
      monthly_debt_minimums = Money.dollars(debt_portfolio.monthly_minimum_cents)

      {
        year: budget_year.year,
        months: periods.map { |period| period_payload(period) },
        rows: rows,
        monthly_income: monthly_income,
        monthly_debt_minimums: monthly_debt_minimums,
        monthly_debt_minimums_known: debt_portfolio.minimum_payment_known?,
        income_sources: income_sources_payload,
        annual_outlook: annual_outlook_payload(periods, rows, monthly_income, monthly_debt_minimums),
        pending_transaction_drafts: pending_drafts_payload(budget_year),
        pending_transaction_drafts_meta: pending_drafts_meta(budget_year),
        pending_mia_action_drafts: pending_mia_action_drafts_payload(budget_year),
        recent_transactions: recent_transactions_payload(periods),
        archived_categories: archived_categories_payload
      }
    end

    def create_category!(name:, stack_key:, monthly_amount: 0, plan_prepared: false)
      ensure_plan! unless plan_prepared
      category = nil
      household.with_lock do
        category = create_category_inside_household_lock!(name: name, stack_key: stack_key, monthly_amount: monthly_amount)
      end
      category
    end

    def create_category_inside_household_lock!(name:, stack_key:, monthly_amount: 0)
      budget_year = household.budget_years.find_by!(year: year)
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
      category
    end

    def update_category!(category, name:, stack_key:, plan_prepared: false, representative_planned_cents: nil)
      ensure_plan! unless plan_prepared
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id

      household.with_lock do
        update_category_inside_household_lock!(
          category,
          name: name,
          stack_key: stack_key,
          representative_planned_cents: representative_planned_cents
        )
      end
      category
    end

    def update_category_inside_household_lock!(category, name:, stack_key:, representative_planned_cents: nil)
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id

      category.lock!
      old_name = category.name
      old_stack_key = category.stack_key
      category.assign_attributes(
        name: category_update_name(name, fallback: category.name),
        stack_key: stack_key.presence || category.stack_key
      )
      category.save!
      sync_expense_item_after_category_change!(
        category,
        old_name,
        old_stack_key,
        representative_planned_cents: representative_planned_cents
      )
      category
    end

    def archive_category!(category, plan_prepared: false)
      ensure_plan! unless plan_prepared
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id

      household.with_lock do
        archive_category_inside_household_lock!(category)
      end
      category
    end

    def archive_category_inside_household_lock!(category)
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id

      category.lock!
      ensure_category_can_archive!(category)
      category.update!(active: false)
      archive_synced_expense_item!(category)
      category
    end

    def restore_category!(category, plan_prepared: false, representative_planned_cents: nil)
      budget_year = plan_prepared ? household.budget_years.find_by!(year: year) : ensure_plan!
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id

      household.with_lock do
        restore_category_inside_household_lock!(
          category,
          budget_year: budget_year,
          representative_planned_cents: representative_planned_cents
        )
      end
      category
    end

    def restore_category_inside_household_lock!(
      category,
      budget_year: household.budget_years.find_by!(year: year),
      representative_planned_cents: nil
    )
      raise ActiveRecord::RecordNotFound unless category.household_id == household.id
      raise ActiveRecord::RecordNotFound unless budget_year.household_id == household.id && budget_year.year == year

      category.lock!
      category.update!(active: true, sort_order: category.sort_order.to_i.positive? ? category.sort_order : next_sort_order)
      sync_expense_item_after_category_change!(
        category,
        category.name,
        category.stack_key,
        representative_planned_cents: representative_planned_cents
      )
      budget_year.budget_periods.find_each do |period|
        BudgetAllocation.find_or_create_by!(budget_period: period, budget_category: category) do |allocation|
          allocation.planned_amount_cents = 0
          allocation.source = "manual"
        end
      rescue ActiveRecord::RecordNotUnique
        next
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

      period_for_year(date.year, date.month)
    end

    def canonical_category_name(value)
      bounded_name(value)
    end

    private

    attr_reader :household

    def read_only_plan_preview
      months = (1..12).map do |month|
        starts_on = Date.new(year, month, 1)
        {
          id: "preview-#{year}-#{month}",
          label: MONTH_NAMES.fetch(month - 1),
          starts_on: starts_on.iso8601,
          ends_on: starts_on.end_of_month.iso8601,
          status: starts_on.end_of_month < Date.current ? "closed" : "open"
        }
      end
      sources = scheduled_income_sources
      monthly_income = months.index_with do |month|
        starts_on = Date.iso8601(month.fetch(:starts_on))
        ends_on = Date.iso8601(month.fetch(:ends_on))
        Money.dollars(sources.sum { |source| IncomeTimeline.period_cents(source, starts_on: starts_on, ends_on: ends_on) })
      end.transform_keys { |month| month.fetch(:id) }
      categories = household.budget_categories.ordered.to_a
      expenses = active_expenses
      row_sources = categories.map do |category|
        [ category.id, category.name, category.stack_key, category.stack_label, category.active, expenses.find { |expense| expense.label.casecmp?(category.name) } ]
      end
      category_names = categories.map { |category| category.name.downcase }
      row_sources.concat(expenses.reject { |expense| category_names.include?(expense.label.downcase) }.map do |expense|
        [ 0, expense.label, expense.stack_key, SnapshotBuilder::STACK_LABELS.fetch(expense.stack_key), expense.active, expense ]
      end)
      rows = row_sources.map do |id, name, stack_key, stack_label, active, expense|
        cells = months.map do |month|
          planned_cents = if expense
            Money.period_cents(expense.amount_cents, expense.cadence, month: Date.iso8601(month.fetch(:starts_on)).month)
          else
            0
          end
          {
            period_id: month.fetch(:id),
            allocation_id: nil,
            planned: Money.dollars(planned_cents),
            actual: 0,
            remaining: Money.dollars(planned_cents),
            allocation_missing: true
          }
        end
        {
          id: id,
          name: name,
          stack_key: stack_key,
          stack_label: stack_label,
          active: active,
          months: cells,
          planned_total: cells.sum { |cell| cell.fetch(:planned) },
          actual_total: 0
        }
      end

      debt_portfolio = DebtPortfolio.new(household)
      {
        year: year,
        months: months,
        rows: rows,
        monthly_income: monthly_income,
        monthly_debt_minimums: Money.dollars(debt_portfolio.monthly_minimum_cents),
        monthly_debt_minimums_known: debt_portfolio.minimum_payment_known?,
        income_sources: income_sources_payload,
        annual_outlook: { typical_monthly_outflow: 0, months: [], upcoming_spikes: [], next_irregular_month: nil },
        pending_transaction_drafts: [],
        pending_transaction_drafts_meta: { total_count: 0, returned_count: 0, limit: MAX_PENDING_TRANSACTION_DRAFTS, truncated: false },
        pending_mia_action_drafts: [],
        recent_transactions: [],
        archived_categories: archived_categories_payload,
        plan_available: false
      }
    end

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

        periods.each do |period|
          allocation = BudgetAllocation.find_or_initialize_by(budget_period: period, budget_category: category)
          next if allocation.persisted? && (allocation.source == "manual" || period.starts_on < Date.current.beginning_of_month)

          period_cents = Money.period_cents(expense.amount_cents, expense.cadence, month: period.starts_on.month)
          allocation.update!(planned_amount_cents: period_cents, source: "setup")
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
      sources = scheduled_income_sources
      periods.index_with do |period|
        Money.dollars(sources.sum { |source| income_source_cents_for_period(source, period) })
      end.transform_keys(&:id)
    end

    def scheduled_income_sources
      @scheduled_income_sources ||= household.income_sources
        .where(active: true).or(household.income_sources.where.not(ends_on: nil))
        .includes(:income_schedule_entries)
        .order(:source_type, :label)
        .select { |source| source.intersects_year?(year) }
    end

    def income_source_cents_for_period(source, period)
      IncomeTimeline.period_cents(source, starts_on: period.starts_on, ends_on: period.ends_on)
    end

    def income_sources_payload
      scheduled_income_sources.map { |source| IncomeSourcePresenter.new(source).as_json }
    end

    def annual_outlook_payload(periods, rows, monthly_income, monthly_debt_minimums)
      active_rows = rows.select { |row| row[:active] }
      expected_rows = active_rows.select { |row| row[:stack_key] == "sinking_expected" }

      month_data = periods.map do |period|
        index = period.starts_on.month - 1
        cells = active_rows.map { |row| row[:months][index] }
        category_plan_cents = cells.sum { |cell| Money.cents(cell[:planned]) }
        debt_minimums_cents = Money.cents(monthly_debt_minimums)
        planned_outflow_cents = category_plan_cents + debt_minimums_cents
        income_cents = Money.cents(monthly_income.fetch(period.id))
        expected_cents = expected_rows.sum { |row| Money.cents(row[:months][index][:planned]) }
        contributors = expected_rows
          .filter_map { |row| [ row[:name], row[:months][index][:planned] ] if row[:months][index][:planned].positive? }
          .sort_by { |(_, amount)| -amount }
          .first(3)
          .map { |name, amount| { name: name, amount: amount } }

        {
          period_id: period.id,
          label: MONTH_NAMES[index],
          starts_on: period.starts_on.iso8601,
          income: Money.dollars(income_cents),
          category_plan: Money.dollars(category_plan_cents),
          debt_minimums: monthly_debt_minimums,
          planned_outflow: Money.dollars(planned_outflow_cents),
          baseline_surplus: Money.dollars(income_cents - planned_outflow_cents),
          expected_irregular: Money.dollars(expected_cents),
          expected_contributors: contributors
        }
      end
      typical_cents = median_cents(month_data.map { |month| Money.cents(month[:planned_outflow]) })
      threshold_cents = [ 10_000, (typical_cents + 5) / 10 ].max
      eligible = month_data.select { |month| Date.iso8601(month[:starts_on]) >= outlook_start_date }
      spikes = eligible
        .select { |month| Money.cents(month[:planned_outflow]) >= typical_cents + threshold_cents }
        .map do |month|
          month.merge(amount_above_typical: Money.dollars(Money.cents(month[:planned_outflow]) - typical_cents))
        end

      {
        typical_monthly_outflow: Money.dollars(typical_cents),
        months: month_data,
        upcoming_spikes: spikes.first(3),
        next_irregular_month: eligible.find { |month| month[:expected_irregular].positive? }
      }
    end

    def median_cents(values)
      sorted = values.sort
      midpoint = sorted.length / 2
      sorted.length.odd? ? sorted[midpoint] : (sorted[midpoint - 1] + sorted[midpoint] + 1) / 2
    end

    def outlook_start_date
      year == Date.current.year ? Date.current.beginning_of_month : Date.new(year, 1, 1)
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
        planned_total: Money.dollars(month_cells.sum { |cell| Money.cents(cell[:planned]) }),
        actual_total: Money.dollars(month_cells.sum { |cell| Money.cents(cell[:actual]) })
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
      Rails.logger.warn("Missing budget allocation for category_id=#{category.id} period_id=#{period.id}") if category.active?
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
      pending_drafts_scope(budget_year)
        .includes(:budget_category, transaction_draft_splits: :budget_category, transaction_draft_matches: { household_transaction: { transaction_splits: :budget_category } })
        .recent_first
        .limit(MAX_PENDING_TRANSACTION_DRAFTS)
        .map { |draft| draft_payload(draft) }
    end

    def pending_drafts_meta(budget_year)
      total_count = pending_drafts_scope(budget_year).count
      {
        total_count: total_count,
        returned_count: [ total_count, MAX_PENDING_TRANSACTION_DRAFTS ].min,
        limit: MAX_PENDING_TRANSACTION_DRAFTS,
        truncated: total_count > MAX_PENDING_TRANSACTION_DRAFTS
      }
    end

    def pending_drafts_scope(budget_year)
      household.transaction_drafts.pending
        .where(occurred_on: Date.new(budget_year.year, 1, 1)..Date.new(budget_year.year, 12, 31))
    end

    def pending_mia_action_drafts_payload(budget_year)
      household.mia_action_drafts.reviewable.for_budget_year(budget_year.year).includes(:mia_action_items)
        .recent_first
        .limit(10)
        .map { |draft| MiaActionDraftPresenter.new(draft).call }
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
        amount_cents: draft.total_amount_cents,
        status: draft.status,
        source_type: draft.source_type,
        financial_document_import_id: draft.financial_document_import_id,
        category_id: draft.budget_category_id,
        category_name: draft.budget_category&.name,
        stack_label: draft.budget_category&.stack_label,
        summary: draft_summary(draft),
        splits: ordered_draft_splits_for(draft).map { |split| draft_split_payload(split) },
        matches: ordered_draft_matches_for(draft).map { |match| draft_match_payload(match) }
      }
    end

    def ordered_draft_splits_for(draft)
      if draft.association(:transaction_draft_splits).loaded?
        draft.transaction_draft_splits.sort_by(&:id)
      else
        draft.transaction_draft_splits.ordered.includes(:budget_category)
      end
    end

    def ordered_draft_matches_for(draft)
      matches = if draft.association(:transaction_draft_matches).loaded?
        draft.transaction_draft_matches
      else
        draft.transaction_draft_matches.includes(household_transaction: { transaction_splits: :budget_category })
      end
      matches.sort_by { |match| [ -(match.confidence || 0).to_d, match.id || 0 ] }
    end

    def draft_split_payload(split)
      {
        id: split.id,
        budget_category_id: split.budget_category_id,
        category_name: split.budget_category&.name || split.category_name,
        stack_key: split.budget_category&.stack_key || split.stack_key,
        stack_label: split.budget_category&.stack_label || split.stack_key.to_s.humanize,
        amount: Money.dollars(split.amount_cents),
        amount_cents: split.amount_cents,
        notes: split.notes,
        confidence: split.confidence,
        metadata: split.metadata || {}
      }
    end

    def draft_match_payload(match)
      transaction = match.household_transaction
      {
        id: match.id,
        status: match.status,
        confidence: match.confidence,
        match_reason: match.match_reason,
        transaction: {
          id: transaction.id,
          occurred_on: transaction.occurred_on.iso8601,
          merchant: transaction.merchant,
          amount: Money.dollars(transaction.total_amount_cents),
          source_type: transaction.source_type,
          categories: transaction.transaction_splits.filter_map { |split| split.budget_category&.name }
        }
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

    def sync_expense_item_after_category_change!(category, old_name, old_stack_key, representative_planned_cents: nil)
      expense = household.expense_items
        .where("LOWER(label) = ?", old_name.downcase)
        .where(stack_key: old_stack_key)
        .order(active: :desc, id: :asc)
        .first || synced_expense_for(category)
      if expense.new_record?
        expense.amount_cents = representative_planned_cents.nil? ? self.representative_planned_cents(category) : representative_planned_cents
      end
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

      return ensure_period_for_month!(month) if period_year == year

      self.class.new(household, year: period_year).send(:ensure_period_for_month!, month)
    end

    def ensure_period_for_month!(month)
      starts_on = Date.new(year, month.to_i, 1)
      household.with_lock do
        budget_year = ensure_plan_records!
        @budget_year = budget_year
        budget_year.budget_periods.find_or_create_by!(starts_on: starts_on) do |period|
          period.ends_on = starts_on.end_of_month
          period.status = "open"
        end
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
