module HouseholdFinance
  module Operations
    module Budget
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
    end
  end
end
