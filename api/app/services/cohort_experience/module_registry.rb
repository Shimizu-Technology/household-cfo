# frozen_string_literal: true

module CohortExperience
  module ModuleRegistry
    MODULES = [
      { id: "home", label: "Home", core: true },
      { id: "review", label: "Review", core: true },
      { id: "ask_mia", label: "Ask Mia", core: true },
      { id: "budget", label: "Budget", core: true },
      { id: "profile", label: "My Profile", core: true },
      { id: "wealth", label: "Wealth", core: true },
      { id: "cfo_filter", label: "CFO Filter", core: false, unavailable_message: "CFO Filter is not included in this cohort right now. You can still ask Mia about this decision." },
      { id: "optionality", label: "Optionality", core: false, unavailable_message: "Optionality is not included in this cohort right now. You can still ask Mia about your choices." }
    ].freeze

    module_function

    def find(id)
      MODULES.find { |item| item.fetch(:id) == id.to_s }
    end
  end
end
