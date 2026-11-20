module HouseholdFinance
  module FinancialGenerationGuard
    module_function

    def request!(household)
      return unless FinancialPicture.household_id == household.id && !FinancialPicture.generation.nil?
      raise Operations::Base::StaleOperation, "Your financial picture changed. Reload and review again. Nothing changed." unless FinancialPicture.generation == household.financial_generation
    end

    def source!(source, locked_household: nil)
      household = locked_household || source.household
      current = locked_household ? household.financial_generation : Household.where(id: household.id).pick(:financial_generation)
      unless source.household_id == household.id && source.financial_generation == current
        raise Operations::Base::StaleOperation, "This source belongs to your previous financial picture. Its history is retained. Upload or reconnect a fresh source before applying it to the new picture. Nothing changed."
      end
    end
  end
end
