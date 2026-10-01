module HouseholdFinance
  module Operations
    module Budget
      class CategoryRestore < CategoryUpdate
        KEY = "budget.category.restore"

        private

        def predicted_after(before, input)
          category = before.fetch("category").merge("active" => true)
          chosen = expense_for_category_change(
            before.fetch("expenses"),
            old_name: category.fetch("name"),
            old_stack: category.fetch("stack_key"),
            new_name: category.fetch("name"),
            new_stack: category.fetch("stack_key")
          )
          expenses = before.fetch("expenses").map do |expense|
            chosen && expense.fetch("id") == chosen.fetch("id") ? expense.merge("active" => true, "label" => category.fetch("name"), "stack_key" => category.fetch("stack_key")) : expense.merge("active" => false)
          end
          if expenses.empty?
            expenses << {
              "label" => category.fetch("name"), "stack_key" => category.fetch("stack_key"),
              "amount_cents" => representative_planned_cents(before),
              "cadence" => "monthly", "active" => true
            }
          end
          allocations = before.fetch("allocations").dup
          present_months = allocations.pluck("month")
          household.budget_years.find_by!(year: input.fetch(:year)).budget_periods.order(:starts_on).each do |period|
            next if present_months.include?(period.starts_on.month)
            allocations << {
              "period_id" => period.id, "month" => period.starts_on.month, "year" => period.starts_on.year,
              "planned_amount_cents" => 0, "source" => "manual"
            }
          end
          { category: category, expenses: expenses, allocations: allocations.sort_by { |row| row.fetch("month") }, conflicting_category_ids: before.fetch("conflicting_category_ids") }
        end

        def mutate!(category, input, prepared:)
          manager(input).restore_category!(
            category,
            plan_prepared: true,
            representative_planned_cents: representative_planned_cents(prepared.before_snapshot)
          )
        end
      end
    end
  end
end
