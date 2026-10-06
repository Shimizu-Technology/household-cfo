module HouseholdFinance
  module Operations
    module Budget
      class CategoryUpdate < Base
        KEY = "budget.category.update"
        VERSION = 1

        private

        def normalize(input)
          name = input[:name]
          {
            category_id: Integer(input.fetch(:category_id)),
            name: name.nil? ? nil : name.to_s.squish.truncate(80, omission: "…"),
            stack_key: input[:stack_key].presence,
            year: input.fetch(:year).to_i
          }
        end

        def subject_for(input, lock:)
          scope = household.budget_categories
          scope = scope.lock if lock
          scope.find(input.fetch(:category_id))
        end

        def canonical_snapshot(category, input, lock:)
          full_category_snapshot(category, input, lock: lock)
        end

        def full_category_snapshot(category, input, lock:, expense_ids: [])
          allocations = category.budget_allocations.joins(budget_period: :budget_year)
            .where(budget_years: { household_id: household.id, financial_generation: household.financial_generation, year: input.fetch(:year) }).order(:id)
          allocations = allocations.lock if lock
          {
            category: category_snapshot(category),
            expenses: expense_snapshots(category, lock: lock, additional_names: [ input[:name] ], ids: expense_ids),
            allocations: allocations.map do |row|
              {
                id: row.id, period_id: row.budget_period_id, month: row.budget_period.starts_on.month,
                year: row.budget_period.budget_year.year, planned_amount_cents: row.planned_amount_cents, source: row.source,
                updated_at: row.updated_at&.iso8601(6)
              }
            end,
            conflicting_category_ids: conflicting_category_ids(category, input, lock: lock)
          }
        end

        def conflicting_category_ids(category, input, lock:)
          name = input[:name].to_s.squish
          return [] if name.blank? || name.casecmp?(category.name)

          scope = household.budget_categories.where("LOWER(name) = ?", name.downcase).where.not(id: category.id)
          scope = scope.lock if lock
          scope.order(:id).pluck(:id)
        end

        def predicted_after(before, input)
          category = before.fetch("category").merge(
            "name" => input[:name].presence || before.dig("category", "name"),
            "stack_key" => input[:stack_key].presence || before.dig("category", "stack_key")
          )
          old_name = before.dig("category", "name")
          new_name = category.fetch("name")
          old_stack = before.dig("category", "stack_key")
          new_stack = category.fetch("stack_key")
          chosen = expense_for_category_change(
            before.fetch("expenses"),
            old_name: old_name,
            old_stack: old_stack,
            new_name: new_name,
            new_stack: new_stack
          )
          expenses = before.fetch("expenses").map do |expense|
            if chosen && expense.fetch("id") == chosen.fetch("id")
              expense.merge("label" => new_name, "stack_key" => new_stack, "cadence" => "monthly", "active" => category.fetch("active"))
            elsif expense.fetch("label").casecmp?(old_name) || expense.fetch("label").casecmp?(new_name)
              expense.merge("active" => false)
            else
              expense
            end
          end
          if expenses.empty?
            expenses << {
              "label" => new_name, "stack_key" => new_stack,
              "amount_cents" => representative_planned_cents(before),
              "cadence" => "monthly", "active" => category.fetch("active")
            }
          end
          { category: category, expenses: expenses, allocations: before.fetch("allocations"), conflicting_category_ids: before.fetch("conflicting_category_ids") }
        end

        def mutate!(category, input, prepared:)
          manager(input).update_category!(
            category,
            name: input[:name],
            stack_key: input[:stack_key],
            plan_prepared: true,
            representative_planned_cents: representative_planned_cents(prepared.before_snapshot)
          )
        end

        def canonical_after_snapshot(category, input, prepared:)
          expense_ids = prepared.before_snapshot.fetch("expenses", []).pluck("id")
          full_category_snapshot(category.reload, input, lock: false, expense_ids: expense_ids)
        end

        def verify_after!(predicted, actual)
          verify_category_prediction!(predicted, actual)
        end

        def verify_category_prediction!(predicted, actual)
          return true if category_semantics(predicted) == category_semantics(actual)

          raise ArgumentError, "The household operation result did not match the reviewed change. Nothing changed."
        end

        def category_semantics(snapshot)
          value = snapshot.deep_stringify_keys
          {
            category: value.fetch("category").slice("name", "stack_key", "active"),
            expenses: Array(value["expenses"]).map { |row| row.slice("label", "stack_key", "amount_cents", "cadence", "active") }.sort_by { |row| [ row["label"].to_s, row["stack_key"].to_s, row["amount_cents"].to_i, row["active"].to_s ] },
            allocations: Array(value["allocations"]).map { |row| row.slice("period_id", "month", "year", "planned_amount_cents", "source") }.sort_by { |row| [ row["year"].to_i, row["month"].to_i, row["period_id"].to_i ] }
          }
        end

        def representative_planned_cents(snapshot)
          Array(snapshot["allocations"] || snapshot[:allocations])
            .max_by { |row| [ row["updated_at"].to_s, row["id"].to_i ] }
            &.fetch("planned_amount_cents", 0).to_i
        end

        def expense_for_category_change(expenses, old_name:, old_stack:, new_name:, new_stack:)
          ordered_old_matches = expenses
            .select { |expense| expense.fetch("label").casecmp?(old_name) && expense.fetch("stack_key") == old_stack }
            .sort_by { |expense| [ expense.fetch("active") ? 0 : 1, expense.fetch("id").to_i ] }
          return ordered_old_matches.first if ordered_old_matches.any?

          ordered_new_matches = expenses
            .select { |expense| expense.fetch("label").casecmp?(new_name) }
            .sort_by { |expense| [ expense.fetch("active") ? 0 : 1, expense.fetch("id").to_i ] }
          ordered_new_matches.find { |expense| expense.fetch("stack_key") == new_stack } || ordered_new_matches.first
        end

        def stale_message
          name = stale_input&.fetch(:name, nil).to_s.squish
          if name.present? && household.budget_categories.where("LOWER(name) = ?", name.downcase).where.not(id: stale_input.fetch(:category_id)).exists?
            return "A budget category named #{name} now exists. Ask Mia to draft a fresh edit for the existing category. Nothing changed."
          end
          super
        end
      end
    end
  end
end
