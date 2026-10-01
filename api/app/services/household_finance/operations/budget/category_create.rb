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
            .where(budget_years: { household_id: household.id, year: input.fetch(:year) }).order(:id)
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
          if expenses.empty? && category.fetch("active")
            expenses << {
              "label" => new_name, "stack_key" => new_stack,
              "amount_cents" => representative_planned_cents(before),
              "cadence" => "monthly", "active" => true
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

      class CategoryArchive < CategoryUpdate
        KEY = "budget.category.archive"

        private

        def predicted_after(before, input)
          category = before.fetch("category").merge("active" => false)
          { category: category, expenses: before.fetch("expenses").map { |expense| expense.merge("active" => false) }, allocations: before.fetch("allocations"), conflicting_category_ids: before.fetch("conflicting_category_ids") }
        end

        def mutate!(category, input, prepared:)
          manager(input).archive_category!(category, plan_prepared: true)
        end
      end

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
