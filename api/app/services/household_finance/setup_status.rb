# frozen_string_literal: true

module HouseholdFinance
  class SetupStatus
    REQUIRED_FIELDS = %i[
      household_name
      primary_goal
      primary_income
      fixed_expenses
      flexible_spend
    ].freeze
    FIELD_LABELS = {
      household_name: "Household name",
      primary_goal: "Primary goal",
      primary_income: "Primary monthly income",
      fixed_expenses: "Fixed essentials",
      flexible_spend: "Flexible spending"
    }.freeze

    def initialize(household, additional_confirmed_fields: [], proposed_values: {})
      @household = household
      @additional_confirmed_fields = Array(additional_confirmed_fields).map(&:to_s)
      @proposed_values = proposed_values.to_h.stringify_keys
    end

    def complete?
      missing_field_keys.empty?
    end

    def confirmed_field_keys
      @confirmed_field_keys ||= (
        Array(household.confirmed_setup_fields).map(&:to_s) +
        additional_confirmed_fields
      ).select { |field| field.in?(SetupUpdater::INPUT_KEYS.map(&:to_s)) }
        .select { |field| confirmed_value_present?(field) }
        .uniq
    end

    def missing_field_keys
      REQUIRED_FIELDS.map(&:to_s) - confirmed_field_keys
    end

    def as_json(*)
      required_fields = REQUIRED_FIELDS.map do |key|
        {
          key: key.to_s,
          label: FIELD_LABELS.fetch(key),
          confirmed: confirmed_field_keys.include?(key.to_s)
        }
      end
      {
        complete: complete?,
        completed_count: required_fields.count { |field| field.fetch(:confirmed) },
        required_count: required_fields.length,
        required_fields: required_fields,
        confirmed_fields: confirmed_field_keys,
        missing_fields: required_fields.reject { |field| field.fetch(:confirmed) }
      }
    end

    private

    attr_reader :household, :additional_confirmed_fields, :proposed_values

    def confirmed_value_present?(field)
      value = proposed_values.fetch(field) do
        case field
        when "household_name" then household.name
        when "primary_goal" then household.primary_goal
        end
      end

      case field
      when "household_name", "primary_goal"
        value.present?
      else
        true
      end
    end
  end
end
