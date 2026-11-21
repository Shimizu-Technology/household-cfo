# frozen_string_literal: true

module CohortExperience
  # Mrs. Mel's method as program settings. A coach edits them in the program
  # tools draft and they reach participants only through Go live (schema 5).
  # Anything older than schema 5 reads as these defaults.
  module MethodSettings
    PROTECTED_OPTIONS = %w[housing utilities medical childcare_school debt_minimums family_support].freeze
    PRIORITY_OPTIONS = %w[emergency_fund debt wealth experiences].freeze
    WINDFALL_OPTIONS = %w[emergency_fund consumer_debt surplus].freeze
    SPLIT_OPTIONS = %w[emergency_fund debt surplus].freeze
    STATUS_KEYS = %w[target_green_months target_yellow_months surplus_green_cents surplus_yellow_cents].freeze
    KEYS = %w[status emergency_fund_months protected priorities windfall income_split].freeze

    DEFAULTS = {
      "status" => { "target_green_months" => 12, "target_yellow_months" => 36, "surplus_green_cents" => 100_000, "surplus_yellow_cents" => 50_000 }.freeze,
      "emergency_fund_months" => 3,
      "protected" => PROTECTED_OPTIONS,
      "priorities" => PRIORITY_OPTIONS,
      "windfall" => WINDFALL_OPTIONS,
      "income_split" => { "emergency_fund" => 50, "debt" => 25, "surplus" => 25 }.freeze
    }.freeze

    LABELS = {
      "housing" => "Housing", "utilities" => "Utilities", "medical" => "Medical",
      "childcare_school" => "Childcare and school", "debt_minimums" => "Debt minimums", "family_support" => "Family support",
      "emergency_fund" => "Emergency fund", "debt" => "Debt acceleration", "wealth" => "Wealth building",
      "experiences" => "Experiences and life", "consumer_debt" => "Consumer debt (cards and loans, not the mortgage)",
      "surplus" => "Surplus"
    }.freeze

    module_function

    def errors(value)
      return [ "method must be an object" ] unless value.is_a?(Hash)

      input = value.deep_stringify_keys
      return [ "method must contain exactly #{KEYS.join(', ')}" ] unless input.keys.sort == KEYS.sort

      result = []
      status = input["status"]
      if status.is_a?(Hash) && status.keys.sort == STATUS_KEYS.sort && status.values.all? { |entry| entry.is_a?(Integer) }
        result << "method.status target months must be 1 to 120, green before yellow" unless status["target_green_months"].between?(1, 119) &&
          status["target_yellow_months"].between?(status["target_green_months"] + 1, 120)
        result << "method.status surplus amounts must be $0 to $100,000, yellow at or below green" unless status["surplus_yellow_cents"].between?(0, 10_000_000) &&
          status["surplus_green_cents"].between?(status["surplus_yellow_cents"], 10_000_000)
      else
        result << "method.status must contain whole-number #{STATUS_KEYS.join(', ')}"
      end
      months = input["emergency_fund_months"]
      result << "method.emergency_fund_months must be a whole number from 1 to 24" unless months.is_a?(Integer) && months.between?(1, 24)
      protected_list = input["protected"]
      unless protected_list.is_a?(Array) && protected_list.all? { |key| PROTECTED_OPTIONS.include?(key) } && protected_list.uniq == protected_list
        result << "method.protected must list unique supported categories"
      end
      result << "method.priorities must order every priority once" unless ordering?(input["priorities"], PRIORITY_OPTIONS)
      result << "method.windfall must order every windfall step once" unless ordering?(input["windfall"], WINDFALL_OPTIONS)
      split = input["income_split"]
      unless split.is_a?(Hash) && split.keys.sort == SPLIT_OPTIONS.sort && split.values.all? { |entry| entry.is_a?(Integer) && entry.between?(0, 100) } && split.values.sum == 100
        result << "method.income_split must be whole percentages that add up to 100"
      end
      result
    end

    def ordering?(value, options)
      value.is_a?(Array) && value.sort == options.sort
    end

    # Canonical key order so digests do not depend on how a client ordered keys.
    def normalize(value)
      input = value.deep_stringify_keys
      {
        "status" => STATUS_KEYS.index_with { |key| input.dig("status", key) },
        "emergency_fund_months" => input["emergency_fund_months"],
        "protected" => PROTECTED_OPTIONS & Array(input["protected"]),
        "priorities" => Array(input["priorities"]).dup,
        "windfall" => Array(input["windfall"]).dup,
        "income_split" => SPLIT_OPTIONS.index_with { |key| input.dig("income_split", key) }
      }
    end

    def defaults
      DEFAULTS.deep_dup
    end

    # The method a participant has, from their experience capabilities. Never raises.
    def from_capabilities(capabilities)
      value = capabilities.to_h.with_indifferent_access[:method]
      value.is_a?(Hash) && errors(value).empty? ? normalize(value) : defaults
    rescue StandardError
      defaults
    end

    # The household's method: the program its owner (or first seat) is in. Household facts
    # are the same whichever member asks. Never raises; a fault reads as the defaults.
    def for_household(household)
      return defaults unless household

      user = household.household_memberships.includes(:user).sort_by { |membership| [ membership.role == "owner" ? 0 : 1, membership.id ] }.first&.user
      return defaults unless user

      from_capabilities(Mia::ParticipantRuntimeResolver.new(user: user).call.capabilities)
    rescue StandardError => error
      Rails.logger.error("[CohortExperience::MethodSettings] default method household_id=#{household&.id} error=#{error.class}")
      defaults
    end

    def label(key)
      LABELS.fetch(key)
    end
  end
end
