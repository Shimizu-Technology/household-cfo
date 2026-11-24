# frozen_string_literal: true

module HouseholdFinance
  # Where one-time money goes under the program's windfall order: the emergency
  # fund gap, then consumer debt (cards and loans, never the mortgage), then surplus.
  # A step whose size is unknown stops the split: the rest waits on that fact
  # (room_known: false) and is never sent past it as if the step were $0.
  #
  # Within the consumer-debt step, known past-due amounts are caught up first
  # ("consumer_debt_catch_up"), then extra principal. The catch-up is part of the same
  # balance, so it lowers the room for extra principal; known arrears are reported even
  # when the total balance is unknown.
  class WindfallSplit
    # Every listed debt but the mortgage, or nil when that is not known.
    # The setup summary is one total for all debts and may include a mortgage, so it
    # only counts when it is a confirmed $0. An empty list is not "no debt".
    #
    # Records that disagree (a past-due amount above a balance or above a $0 summary)
    # leave the consumer-debt step unknown until she checks her debts.
    def self.consumer_debt_cents(household)
      return nil if DebtArrears.new(household).conflict?

      portfolio = DebtPortfolio.new(household)
      if portfolio.mode == "summary"
        return portfolio.balance_known? && portfolio.total_balance_cents.zero? ? 0 : nil
      end
      return nil if portfolio.active_debts.empty?

      debts = portfolio.active_debts.reject { |debt| debt.debt_type == "mortgage" }
      debts.all?(&:balance_known?) ? debts.sum(&:balance_cents) : nil
    end

    # Known past-due amounts on cards and loans (never the mortgage), each capped at its
    # balance. $0 when nothing past due is entered; a blank amount is not behind.
    def self.consumer_catch_up_cents(household)
      arrears = DebtArrears.new(household)
      arrears.debts.reject { |debt| debt.debt_type == "mortgage" }.sum { |debt| arrears.catch_up_cents(debt) }
    end

    def initialize(amount_cents:, order:, emergency_fund_gap_cents:, consumer_debt_cents:, catch_up_cents: 0)
      @amount_cents = amount_cents.to_i
      @order = order
      @catch_up = catch_up_cents.to_i
      principal_room = consumer_debt_cents && [ consumer_debt_cents - @catch_up, 0 ].max
      @room = { "emergency_fund" => emergency_fund_gap_cents, "consumer_debt" => principal_room, "surplus" => Float::INFINITY }
    end

    # [{ key:, cents:, room_known: }] in order, summing exactly to the amount; a step
    # with no money left is left out. An unknown step holds the rest and ends the split.
    def call
      left = @amount_cents
      @order.each_with_object([]) do |key, steps|
        break steps unless left.positive?

        if key == "consumer_debt" && @catch_up.positive?
          catch_up = [ left, @catch_up ].min
          steps << { key: "consumer_debt_catch_up", cents: catch_up, room_known: true }
          left -= catch_up
          next unless left.positive?
        end

        room = @room.fetch(key)
        cents = room.nil? ? left : [ left, room ].min.to_i
        steps << { key: key, cents: cents, room_known: !room.nil? } if cents.positive?
        left -= cents
      end
    end
  end
end
