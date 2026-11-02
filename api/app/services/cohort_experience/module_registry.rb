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

    # Keep MODULES as the runtime adapter for catalogs 1–5. Their sealed core flags
    # are historical evidence, not the editability rules for schema 4.
    CONFIGURABLE_MODULES = (MODULES.map do |item|
      item.merge(core: %w[home ask_mia].include?(item.fetch(:id))).tap do |definition|
        unless definition.fetch(:core)
          definition[:unavailable_message] ||= "#{item.fetch(:label)} is not included in this group right now. You can still ask Mia here."
        end
      end.freeze
    end + [ { id: "statements", label: "Statements", core: false,
      unavailable_message: "Statements is not included in this group right now. You can still ask Mia here." }.freeze ]).freeze

    module_function

    def for_schema(version)
      version == 4 ? CONFIGURABLE_MODULES : MODULES
    end

    def ordered(definitions, order)
      return definitions if order.blank?

      ids = order + (definitions.map { |item| item.fetch(:id) } - order)
      ids.filter_map { |id| definitions.find { |item| item.fetch(:id) == id } }
    end

    def find(id)
      MODULES.find { |item| item.fetch(:id) == id.to_s }
    end
  end
end
