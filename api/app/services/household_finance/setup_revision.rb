module HouseholdFinance
  # The setup form's before-state, including unknown/confirmed values and the
  # month those recurring amounts describe. A second device must review changes.
  class SetupRevision
    def self.for(household, values: DataPresenter.new(household, ensure_plan: false).setup_values)
      Operations::PreparedOperation.fingerprint(
        values: values, confirmed: Array(household.confirmed_setup_fields).sort,
        generation: household.financial_generation, month: Date.current.beginning_of_month.iso8601)
    end
  end
end
