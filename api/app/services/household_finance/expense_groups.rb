# frozen_string_literal: true

module HouseholdFinance
  # The names of the four expense groups. A program chooses plain words (the default) or
  # Mrs. Mel's terms in its method settings (group_names). Labels only: categories,
  # stack keys and every total stay the same whichever names a program uses.
  module ExpenseGroups
    LABELS = {
      "plain" => {
        "non_discretionary" => "Must-pay bills",
        "discretionary" => "Flexible spending",
        "sinking_expected" => "Planned yearly costs",
        "sinking_unexpected" => "Surprise fund"
      }.freeze,
      "method" => {
        "non_discretionary" => "Non-discretionary",
        "discretionary" => "Discretionary",
        "sinking_expected" => "Sinking Fund — Expected",
        "sinking_unexpected" => "Sinking Fund — Unexpected"
      }.freeze
    }.freeze
    # Inside a sentence: "belongs in planned yearly costs", "belongs in Sinking Fund — Expected".
    PHRASES = LABELS.merge("plain" => LABELS.fetch("plain").transform_values(&:downcase).freeze).freeze
    DEFAULT = "plain"

    module_function

    def names(method)
      choice = method.is_a?(Hash) ? method["group_names"] || method[:group_names] : method
      LABELS.key?(choice) ? choice : DEFAULT
    end

    def labels(method = nil)
      LABELS.fetch(names(method))
    end

    def label(stack_key, method = nil)
      labels(method).fetch(stack_key.to_s, stack_key.to_s.humanize.presence || "Custom")
    end

    def phrase(stack_key, method = nil)
      PHRASES.fetch(names(method)).fetch(stack_key.to_s)
    end

    # The household's program names, resolved once per request (see MethodSettings).
    def for_household(household)
      labels(CohortExperience::MethodSettings.for_household(household))
    end
  end
end
