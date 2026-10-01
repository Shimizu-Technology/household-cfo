module HouseholdFinance
  module Operations
    module Budget
      class CategoryCreate < Base
        KEY = "budget.category.create"
        VERSION = 1

        private

        def normalize(input)
          months = Array(input[:month_numbers]).map(&:to_i).select { |month| month.between?(1, 12) }.uniq.sort
          months = (1..12).to_a if months.empty?
          cents = if input.key?(:monthly_amount_cents)
            Integer(input[:monthly_amount_cents])
          else
            Money.cents!(input[:monthly_amount] || 0, message: "Planned amount must be a number")
          end
          raise ArgumentError, "Monthly amount must be zero or more" if cents.negative?

          {
            name: AnnualBudgetManager.new(household, year: input.fetch(:year).to_i).canonical_category_name(input[:name]),
            stack_key: input[:stack_key].presence || "discretionary",
            monthly_amount_cents: cents,
            month_numbers: months,
            year: input.fetch(:year).to_i
          }
        rescue TypeError
          raise ArgumentError, "Planned amount must be a number"
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(_subject, input, lock:)
          scope = household.budget_categories.where("LOWER(name) = ?", input.fetch(:name).downcase)
          scope = scope.lock if lock
          expenses = household.expense_items.where("LOWER(label) = ?", input.fetch(:name).downcase).order(active: :desc, id: :asc)
          expenses = expenses.lock if lock
          {
            category: nil,
            conflicting_category_ids: scope.order(:id).pluck(:id),
            expenses: expenses.map do |expense|
              {
                id: expense.id, label: expense.label, stack_key: expense.stack_key,
                amount_cents: expense.amount_cents, cadence: expense.cadence, active: expense.active
              }
            end
          }
        end

        def predicted_after(before, input)
          full_year = input.fetch(:month_numbers) == (1..12).to_a
          periods = household.budget_years.find_by!(year: input.fetch(:year)).budget_periods.order(:starts_on)
          chosen = before.fetch("expenses").find { |expense| expense.fetch("stack_key") == input.fetch(:stack_key) } || before.fetch("expenses").first
          expenses = before.fetch("expenses").map do |expense|
            if chosen && expense.fetch("id") == chosen.fetch("id")
              expense.merge(
                "label" => input.fetch(:name), "stack_key" => input.fetch(:stack_key),
                "amount_cents" => full_year ? input.fetch(:monthly_amount_cents) : 0,
                "cadence" => "monthly", "active" => true
              )
            else
              expense.merge("active" => false)
            end
          end
          if expenses.empty?
            expenses << {
              label: input.fetch(:name), stack_key: input.fetch(:stack_key),
              amount_cents: full_year ? input.fetch(:monthly_amount_cents) : 0,
              cadence: "monthly", active: true
            }
          end
          {
            category: input.slice(:name, :stack_key).merge(active: true),
            expenses: expenses,
            allocations: periods.map do |period|
              {
                period_id: period.id, month: period.starts_on.month, year: period.starts_on.year,
                planned_amount_cents: input.fetch(:month_numbers).include?(period.starts_on.month) ? input.fetch(:monthly_amount_cents) : 0,
                source: "manual"
              }
            end
          }
        end

        def mutate!(_subject, input, prepared:)
          months = input.fetch(:month_numbers)
          full_year = months == (1..12).to_a
          category = manager(input).create_category!(
            name: input.fetch(:name),
            stack_key: input.fetch(:stack_key),
            monthly_amount: Money.dollars(full_year ? input.fetch(:monthly_amount_cents) : 0),
            plan_prepared: true
          )
          unless full_year || input.fetch(:monthly_amount_cents).zero?
            starts_on = months.map { |month| Date.new(input.fetch(:year), month, 1) }
            allocations = category.budget_allocations.joins(:budget_period).where(budget_periods: { starts_on: starts_on }).lock.to_a
            raise ActiveRecord::RecordNotFound, "Budget allocation not found" unless allocations.length == months.size
            allocations.each { |allocation| allocation.update!(planned_amount_cents: input.fetch(:monthly_amount_cents), source: "manual") }
          end
          category
        end

        def canonical_after_snapshot(category, input, prepared:)
          CategoryUpdate.new(household).send(:full_category_snapshot, category, input, lock: false)
        end

        def verify_after!(predicted, actual)
          CategoryUpdate.new(household).send(:verify_category_prediction!, predicted, actual)
        end

        def stale_message
          name = stale_input&.fetch(:name, nil).to_s.squish.presence || "that name"
          "A budget category named #{name} now exists. Ask Mia to draft a fresh edit for the existing category. Nothing changed."
        end
      end
    end
  end
end
