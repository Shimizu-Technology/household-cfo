# frozen_string_literal: true

module HouseholdFinance
  # New monthly income (a raise or new job) split by the program's whole percentages.
  # Whole cents that add up exactly to the amount; Mia words them, never works them out.
  class IncomeSplit
    def initialize(amount_cents:, split:)
      @amount_cents = amount_cents.to_i
      @split = split.to_h.stringify_keys
    end

    # [[key, cents]] in the program's order, leaving out a 0% part. Rounding's leftover
    # cents go to the largest share (the first, on a tie).
    def call
      parts = @split.map { |key, percent| [ key, @amount_cents * percent.to_i / 100 ] }
      largest = @split.keys.index(@split.max_by { |_key, percent| percent.to_i }&.first)
      parts[largest][1] += @amount_cents - parts.sum(&:last) if largest
      parts.reject { |key, _cents| @split.fetch(key).to_i.zero? }
    end
  end
end
