# frozen_string_literal: true

module HouseholdFinance
  class ProfileCompletenessCalculator
    def initialize(household, income_sources: nil)
      @household = household
      @income_sources = income_sources
    end

    def call
      checks = [
        household.name.present?,
        household.primary_goal.present?,
        active_records(:income_sources).any? do |income|
          IncomeTimeline.recurring_monthly_cents(income, on: Date.current).positive?
        end,
        active_records(:expense_items).any? { |expense| expense.amount_cents.positive? },
        records(:accounts).any? { |account| account.balance_cents.positive? },
        records(:debts).any? || records(:accounts).any?,
        records(:goals).any?
      ]

      ((checks.count(true) / checks.length.to_f) * 100).round
    end

    private

    attr_reader :household

    def active_records(name)
      return income_sources if name == :income_sources && income_sources

      records(name).select(&:active?)
    end

    attr_reader :income_sources

    def records(name)
      association = household.association(name)
      association.loaded? ? association.target : household.public_send(name).to_a
    end
  end
end
