# frozen_string_literal: true

module HouseholdFinance
  # Where one-time money goes under the program's windfall order: the emergency
  # fund gap, then consumer debt (cards and loans, never the mortgage), then surplus.
  # A step whose size is unknown takes the rest and says so; unknown is never $0.
  class WindfallSplit
    # Every debt but the mortgage. The setup summary is the household's card debt.
    def self.consumer_debt_cents(household)
      portfolio = DebtPortfolio.new(household)
      return portfolio.balance_known? ? portfolio.total_balance_cents : nil if portfolio.mode == "summary"

      debts = portfolio.active_debts.reject { |debt| debt.debt_type == "mortgage" }
      debts.all?(&:balance_known?) ? debts.sum(&:balance_cents) : nil
    end

    def initialize(amount_cents:, order:, emergency_fund_gap_cents:, consumer_debt_cents:)
      @amount_cents = amount_cents.to_i
      @order = order
      @room = { "emergency_fund" => emergency_fund_gap_cents, "consumer_debt" => consumer_debt_cents, "surplus" => Float::INFINITY }
    end

    # [{ key:, cents:, room_known: }]; a step with no money left is left out.
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
