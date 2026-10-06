module HouseholdFinance
  module Operations
    module Budget
      class AllocationSet < Base
        KEY = "budget.allocation.set"
        VERSION = 1

        private

        def normalize(input)
          raw_changes = if input[:changes].present?
            Array(input[:changes])
          else
            [ { allocation_id: input.fetch(:allocation_id), planned_amount: input.fetch(:planned_amount) } ]
          end
          changes = raw_changes.map do |change|
            value = change.to_h.deep_symbolize_keys
            cents = value.key?(:after_cents) ? Integer(value.fetch(:after_cents)) : Money.cents!(value.fetch(:planned_amount), message: "Planned amount must be a number")
            raise ArgumentError, "Planned amount must be zero or more" if cents.negative?
            { allocation_id: Integer(value.fetch(:allocation_id)), after_cents: cents }
          end.sort_by { |change| change.fetch(:allocation_id) }
          raise ArgumentError, "Budget allocation changes are required" if changes.empty? || changes.map { |change| change[:allocation_id] }.uniq.length != changes.length

          category_id = input[:category_id].to_i
          if category_id.zero?
            category_id = scoped_allocations.where(id: changes.first.fetch(:allocation_id)).pick(:budget_category_id).to_i
          end
          { category_id: category_id, changes: changes, year: input.fetch(:year).to_i }
        end

        def subject_for(input, lock:)
          scope = household.budget_categories
          scope = scope.lock if lock
          scope.find(input.fetch(:category_id))
        end

        def canonical_snapshot(category, input, lock:)
          ids = input.fetch(:changes).map { |change| change.fetch(:allocation_id) }
          scope = scoped_allocations.where(
            budget_categories: { id: category.id },
            budget_years: { year: input.fetch(:year) }
          ).order(:id)
          scope = scope.lock if lock
          allocations = scope.to_a
          unless allocations.length == 12 && (ids - allocations.map(&:id)).empty?
            raise ActiveRecord::RecordNotFound, "Budget allocation not found"
          end
          {
            category: category_snapshot(category),
            allocations: allocations.map { |allocation| allocation_snapshot(allocation) },
            expenses: expense_snapshots(category, lock: lock)
          }
        end

        def validate_execution!(category, _input, prepared:, source:)
          raise StaleOperation, stale_message if source == "mia" && !category.active?
        end

        def predicted_after(before, input)
          amounts = input.fetch(:changes).index_by { |change| change.fetch(:allocation_id) }
          predicted = {
            category: before.fetch("category"),
            allocations: before.fetch("allocations").map do |allocation|
              change = amounts[allocation.fetch("id")]
              change ? allocation.merge("planned_amount_cents" => change.fetch(:after_cents), "source" => "manual") : allocation
            end,
            expenses: before.fetch("expenses")
          }
          sync = uniform_full_year_amount(predicted.fetch(:allocations), input.fetch(:year))
          predicted[:expenses] = synced_expense_prediction(before.fetch("expenses"), before.fetch("category"), sync) if sync
          predicted
        end

        def mutate!(_category, input, prepared:)
          allocations = scoped_allocations.lock.where(
            budget_categories: { id: input.fetch(:category_id) },
            budget_years: { year: input.fetch(:year) }
          ).index_by(&:id)
          raise ActiveRecord::RecordNotFound, "Budget allocation not found" unless allocations.length == 12

          input.fetch(:changes).each do |change|
            allocation = allocations.fetch(change.fetch(:allocation_id)) { raise ActiveRecord::RecordNotFound, "Budget allocation not found" }
            allocation.update!(planned_amount_cents: change.fetch(:after_cents), source: "manual")
          end
          sync = uniform_full_year_amount(
            allocations.values.map { |allocation| allocation_snapshot(allocation.reload) },
            input.fetch(:year)
          )
          sync_expense_item!(prepared.before_snapshot.fetch("expenses"), sync) if sync
          allocations.fetch(input.fetch(:changes).first.fetch(:allocation_id))
        end

        def canonical_after_snapshot(_allocation, input, prepared:)
          category = household.budget_categories.find(input.fetch(:category_id))
          canonical_snapshot(category, input, lock: false)
        end

        def verify_after!(predicted, actual)
          return true if predicted == actual

          raise ArgumentError, "The budget allocation result did not match the reviewed change. Nothing changed."
        end

        def scoped_allocations
          BudgetAllocation.includes(:budget_category, budget_period: :budget_year)
            .joins(:budget_category, budget_period: :budget_year)
            .where(budget_categories: { household_id: household.id, financial_generation: household.financial_generation }, budget_years: { household_id: household.id, financial_generation: household.financial_generation })
        end

        def allocation_snapshot(allocation)
          {
            id: allocation.id,
            budget_category_id: allocation.budget_category_id,
            period_id: allocation.budget_period_id,
            month: allocation.budget_period.starts_on.month,
            year: allocation.budget_period.budget_year.year,
            planned_amount_cents: allocation.planned_amount_cents,
            source: allocation.source
          }
        end

        def uniform_full_year_amount(allocations, year)
          rows = Array(allocations).select { |row| row.fetch("year", row[:year]).to_i == year.to_i }
          return unless rows.map { |row| row.fetch("month", row[:month]).to_i }.uniq.sort == (1..12).to_a

          amounts = rows.map { |row| row.fetch("planned_amount_cents", row[:planned_amount_cents]).to_i }.uniq
          amounts.one? ? amounts.first : nil
        end

        def synced_expense_prediction(expenses, category, amount_cents)
          chosen = expenses.find { |expense| expense.fetch("label").casecmp?(category.fetch("name")) && expense.fetch("stack_key") == category.fetch("stack_key") }
          return expenses unless chosen

          expenses.map do |expense|
            expense.fetch("id") == chosen.fetch("id") ? expense.merge("amount_cents" => amount_cents, "cadence" => "monthly", "active" => true) : expense
          end
        end

        def sync_expense_item!(expenses, amount_cents)
          category = household.budget_categories.find(stale_input.fetch(:category_id))
          chosen = expenses.find { |expense| expense.fetch("label").casecmp?(category.name) && expense.fetch("stack_key") == category.stack_key }
          return unless chosen

          household.expense_items.lock.find(chosen.fetch("id")).update!(amount_cents: amount_cents, cadence: "monthly", active: true)
        end
      end
    end
  end
end
