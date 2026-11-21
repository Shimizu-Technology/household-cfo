# frozen_string_literal: true

module CohortExperience
  # Mrs. Mel's method as program settings. A coach edits them in the program
  # tools draft and they reach participants only through Go live (schema 5).
  # Anything older than schema 5 reads as these defaults. The display choices
  # (OPTIONAL_KEYS) came later in schema 5: a block without them reads as their
  # defaults and keeps its bytes and digest.
  module MethodSettings
    # Never suggested as cuts in any program. A coach can protect more, never fewer.
    CORE_PROTECTED = %w[housing utilities medical childcare_school debt_minimums family_support].freeze
    OPTIONAL_PROTECTED = %w[groceries giving community].freeze
    PROTECTED_OPTIONS = (CORE_PROTECTED + OPTIONAL_PROTECTED).freeze
    PRIORITY_OPTIONS = %w[emergency_fund debt wealth experiences].freeze
    WINDFALL_OPTIONS = %w[emergency_fund consumer_debt surplus].freeze
    SPLIT_OPTIONS = %w[emergency_fund debt surplus].freeze
    STATUS_KEYS = %w[target_green_months target_yellow_months surplus_green_cents surplus_yellow_cents].freeze
    KEYS = %w[status emergency_fund_months protected priorities windfall income_split].freeze
    # Expense group names, what Home leads with, and the debt payoff order Mia leads with.
    CHOICES = {
      "group_names" => %w[plain method].freeze,
      "home_view" => %w[month year].freeze,
      "debt_order" => %w[both snowball avalanche].freeze
    }.freeze
    OPTIONAL_KEYS = CHOICES.keys.freeze
    OPTIONAL_DEFAULTS = CHOICES.transform_values(&:first).freeze
    # Only the people who own the household's picture choose its program.
    HOUSEHOLD_ROLES = %w[owner partner].freeze

    DEFAULTS = {
      "status" => { "target_green_months" => 12, "target_yellow_months" => 36, "surplus_green_cents" => 100_000, "surplus_yellow_cents" => 50_000 }.freeze,
      "emergency_fund_months" => 3,
      "protected" => CORE_PROTECTED,
      "priorities" => PRIORITY_OPTIONS,
      "windfall" => WINDFALL_OPTIONS,
      "income_split" => { "emergency_fund" => 50, "debt" => 25, "surplus" => 25 }.freeze
    }.freeze

    LABELS = {
      "housing" => "Housing", "utilities" => "Utilities", "medical" => "Medical",
      "childcare_school" => "Childcare and school", "debt_minimums" => "Debt minimums", "family_support" => "Family support",
      "groceries" => "Groceries", "giving" => "Giving (tithes and donations)", "community" => "Family & community",
      "emergency_fund" => "Emergency fund", "debt" => "Debt acceleration", "wealth" => "Wealth building",
      "experiences" => "Experiences and life", "consumer_debt" => "Consumer debt (cards and loans, not the mortgage)",
      "surplus" => "Surplus"
    }.freeze

    PROTECTED_CORE_MESSAGE = "method.protected always keeps housing, utilities, medical, childcare and school, debt minimums and family support; " \
      "a program can only add groceries, giving or family & community"

    # One lookup per household per request: a Mia turn reads the method many times.
    class Current < ActiveSupport::CurrentAttributes
      attribute :viewer, :cache
    end

    module_function

    def errors(value)
      return [ "method must be an object" ] unless value.is_a?(Hash)

      input = value.deep_stringify_keys
      unless (KEYS - input.keys).empty? && (input.keys - KEYS - OPTIONAL_KEYS).empty?
        return [ "method must contain #{KEYS.join(', ')} and may contain #{OPTIONAL_KEYS.join(', ')}" ]
      end

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
      if !list_of_strings?(protected_list) || !protected_list.all? { |key| PROTECTED_OPTIONS.include?(key) } || protected_list.uniq != protected_list
        result << "method.protected must list unique supported categories"
      elsif !(CORE_PROTECTED - protected_list).empty?
        result << PROTECTED_CORE_MESSAGE
      end
      result << "method.priorities must order every priority once" unless ordering?(input["priorities"], PRIORITY_OPTIONS)
      result << "method.windfall must order every windfall step once" unless ordering?(input["windfall"], WINDFALL_OPTIONS)
      split = input["income_split"]
      unless split.is_a?(Hash) && split.keys.sort == SPLIT_OPTIONS.sort && split.values.all? { |entry| entry.is_a?(Integer) && entry.between?(0, 100) } && split.values.sum == 100
        result << "method.income_split must be whole percentages that add up to 100"
      end
      CHOICES.each do |key, options|
        result << "method.#{key} must be one of #{options.join(', ')}" if input.key?(key) && !options.include?(input[key])
      end
      result
    end

    # Element types first: sorting [ "debt", 1, nil ] would raise, not report.
    def ordering?(value, options)
      list_of_strings?(value) && value.sort == options.sort
    end

    def list_of_strings?(value)
      value.is_a?(Array) && value.all?(String)
    end

    # Canonical key order so digests do not depend on how a client ordered keys. A display
    # choice the block does not carry stays absent, so earlier schema 5 digests hold.
    def normalize(value)
      input = value.deep_stringify_keys
      normalized = {
        "status" => STATUS_KEYS.index_with { |key| input.dig("status", key) },
        "emergency_fund_months" => input["emergency_fund_months"],
        "protected" => PROTECTED_OPTIONS & Array(input["protected"]),
        "priorities" => Array(input["priorities"]).dup,
        "windfall" => Array(input["windfall"]).dup,
        "income_split" => SPLIT_OPTIONS.index_with { |key| input.dig("income_split", key) }
      }
      OPTIONAL_KEYS.each { |key| normalized[key] = input[key] if input.key?(key) }
      normalized
    end

    # The full method a participant gets: absent display choices read as their defaults.
    def resolve(value)
      OPTIONAL_DEFAULTS.merge(normalize(value))
    end

    def defaults
      DEFAULTS.deep_dup.merge(OPTIONAL_DEFAULTS)
    end

    # The method a participant has, from their experience capabilities. Never raises.
    def from_capabilities(capabilities)
      value = capabilities.to_h.with_indifferent_access[:method]
      value.is_a?(Hash) && errors(value).empty? ? resolve(value) : defaults
    rescue StandardError
      defaults
    end

    # The household's method. The signed-in viewer's program when the request registered
    # one for this household (see .use_viewer), else the program of the given member or
    # the household's owner (then partner); a coach viewing never chooses it. Remembered
    # for the rest of the request. Never raises; a fault reads as the defaults.
    def for_household(household, user: nil)
      return defaults unless household

      cache = (Current.cache ||= {})
      viewer = Current.viewer
      if viewer && viewer.fetch(:household_id) == household.id
        return (cache[[ :viewer, household.id ]] ||= from_capabilities(viewer.fetch(:capabilities).call)).deep_dup
      end

      (cache[[ household.id, user&.id ]] ||= resolve_for(household, user)).deep_dup
    rescue StandardError => error
      Rails.logger.error("[CohortExperience::MethodSettings] default method household_id=#{household&.id} error=#{error.class}")
      defaults
    end

    # The request's caller and their experience capabilities (resolved lazily, once).
    def use_viewer(household_id, &capabilities)
      return if Current.viewer&.fetch(:household_id) == household_id

      Current.viewer = { household_id: household_id, capabilities: capabilities }
      Current.cache = {}
    end

    # Forget what this request resolved, after its program or household was reread.
    def forget!
      Current.cache = {}
    end

    def resolve_for(household, user)
      memberships = household.household_memberships.includes(:user).select { |membership| HOUSEHOLD_ROLES.include?(membership.role) }
      chosen = memberships.find { |membership| user && membership.user_id == user.id } ||
        memberships.min_by { |membership| [ HOUSEHOLD_ROLES.index(membership.role), membership.id ] }
      return defaults unless chosen

      from_capabilities(Mia::ParticipantRuntimeResolver.new(user: chosen.user).call.capabilities)
    end

    def label(key)
      LABELS.fetch(key)
    end
  end
end
