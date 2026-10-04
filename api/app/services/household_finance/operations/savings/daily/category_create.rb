module HouseholdFinance
  module Operations
    module Savings
      module Daily
        # One explicitly chosen category lets a participant review a purchase
        # without creating an annual budget or claiming setup is complete.
        class CategoryCreate < Base
          KEY = "savings.daily.category.create"
          VERSION = 1

          def authorize_replay!(subject)
            raise ArgumentError, "Private category is unavailable" unless subject.is_a?(BudgetCategory) && subject.household_id == household.id
            FinancialDocuments::SourceReview::Domain.new(household, user: user).authorize!
          end

          private
          def normalize(input)
            input = normal_ids(input, required: %i[name stack_key])
            name = input[:name].to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish
            raise ArgumentError, "Choose a specific category name up to eighty characters" if name.blank? || name.length > 80 || name.match?(/\A(?:uncategorized|needs category)\z/i)
            raise ArgumentError, "Choose this category's purpose" unless BudgetCategory::STACK_KEYS.include?(input[:stack_key])
            input.merge(name: name)
          end
          def subject_for(input, lock:) = enrollment_for(input, lock: lock)
          def canonical_snapshot(_subject, input, lock:)
            { categories: household.budget_categories.order(:id).pluck(:id, :name, :stack_key, :active) }
          end
          def mutate!(_subject, input, prepared:)
            raise ArgumentError, "A category with this name already exists. Choose the existing category." if household.budget_categories.where("LOWER(name) = ?", input[:name].downcase).exists?
            household.budget_categories.create!(name: input[:name], stack_key: input[:stack_key], active: true,
              sort_order: household.budget_categories.maximum(:sort_order).to_i + 1)
          end
        end
      end
    end
  end
end
