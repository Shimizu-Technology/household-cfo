# frozen_string_literal: true

module HouseholdFinance
  # Where one-time money goes under the program's windfall order: the emergency
  # fund gap, then consumer debt (cards and loans, never the mortgage), then surplus.
  # A step whose size is unknown stops the split: the rest waits on that fact
  # (room_known: false) and is never sent past it as if the step were $0.
  class WindfallSplit
    # Every listed debt but the mortgage, or nil when that is not known.
    # The setup summary is one total for all debts and may include a mortgage, so it
    # only counts when it is a confirmed $0. An empty list is not "no debt".
    def self.consumer_debt_cents(household)
      portfolio = DebtPortfolio.new(household)
      if portfolio.mode == "summary"
        return portfolio.balance_known? && portfolio.total_balance_cents.zero? ? 0 : nil
      end
      return nil if portfolio.active_debts.empty?

      debts = portfolio.active_debts.reject { |debt| debt.debt_type == "mortgage" }
      debts.all?(&:balance_known?) ? debts.sum(&:balance_cents) : nil
    end

    def initialize(amount_cents:, order:, emergency_fund_gap_cents:, consumer_debt_cents:)
      @amount_cents = amount_cents.to_i
      @order = order
      @room = { "emergency_fund" => emergency_fund_gap_cents, "consumer_debt" => consumer_debt_cents, "surplus" => Float::INFINITY }
    end

    # [{ key:, cents:, room_known: }] in order, summing exactly to the amount; a step
    # with no money left is left out. An unknown step holds the rest and ends the split.
    def call
      left = @amount_cents
      @order.each_with_object([]) do |key, steps|
        break steps unless left.positive?

        room = @room.fetch(key)
        cents = room.nil? ? left : [ left, room ].min.to_i
        steps << { key: key, cents: cents, room_known: !room.nil? } if cents.positive?
        left -= cents
      end
    end
  end
end
