module HouseholdFinance
  module FinancialGenerationGuard
    module_function

    def request!(household)
      return unless FinancialPicture.household_id == household.id && !FinancialPicture.generation.nil?
      raise Operations::Base::StaleOperation, "Your financial picture changed. Reload and review again. Nothing changed." unless FinancialPicture.generation == household.financial_generation
    end

    def source!(source)
      household = source.household
      unless source.financial_generation == Household.where(id: household.id).pick(:financial_generation)
        raise Operations::Base::StaleOperation, "This source belongs to your previous financial picture. Its history is retained. Upload or reconnect a fresh source before applying it to the new picture. Nothing changed."
      end
    end
  end
end
