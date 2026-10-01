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
          raise StaleOperation, stale_message unless category.active?
          ids = input.fetch(:changes).map { |change| change.fetch(:allocation_id) }
          scope = scoped_allocations.where(id: ids).order(:id)
          scope = scope.lock if lock
          allocations = scope.to_a
          raise ActiveRecord::RecordNotFound, "Budget allocation not found" unless allocations.length == ids.length
          unless allocations.all? { |allocation| allocation.budget_category_id == category.id && allocation.budget_period.budget_year.year == input.fetch(:year) }
            raise ActiveRecord::RecordNotFound, "Budget allocation not found"
          end
          {
            category: category_snapshot(category),
            allocations: allocations.map { |allocation| allocation_snapshot(allocation) }
          }
        end

        def predicted_after(before, input)
          amounts = input.fetch(:changes).index_by { |change| change.fetch(:allocation_id) }
          {
            category: before.fetch("category"),
            allocations: before.fetch("allocations").map do |allocation|
              change = amounts.fetch(allocation.fetch("id"))
              allocation.merge("planned_amount_cents" => change.fetch(:after_cents), "source" => "manual")
            end
          }
        end

        def mutate!(_category, input, prepared:)
          allocations = scoped_allocations.lock.where(id: input.fetch(:changes).map { |change| change.fetch(:allocation_id) }).index_by(&:id)
          input.fetch(:changes).each do |change|
            allocation = allocations.fetch(change.fetch(:allocation_id)) { raise ActiveRecord::RecordNotFound, "Budget allocation not found" }
            allocation.update!(planned_amount_cents: change.fetch(:after_cents), source: "manual")
          end
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
            .where(budget_categories: { household_id: household.id }, budget_years: { household_id: household.id })
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
      end
    end
  end
end
