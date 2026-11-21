# frozen_string_literal: true

module HouseholdFinance
  # Past-due amounts she entered on her active debts. Catching these up comes before any
  # extra principal, whichever payoff order (snowball or avalanche) the program uses.
  #
  # A past-due amount is the part of the balance owed now, not a debt on top of the
  # balance. A blank amount is unknown and never counts as $0 behind or as caught up.
  # Individual records are read in either tracking mode: an approved summary sets the
  # totals, but a lender she is behind on is still urgent.
  class DebtArrears
    def initialize(household)
      @household = household
    end

    def debts
      @debts ||= active_debts.select(&:past_due?).sort_by { |debt| [ -debt.past_due_cents, debt.label.downcase, debt.id ] }
    end

    def any?
      debts.any?
    end

    def total_cents
      debts.sum(&:past_due_cents)
    end

    # "Car loan: $1,500 past due"
    def headline(debt)
      "#{debt.label}: #{Money.plain(debt.past_due_cents)} past due"
    end

    # "Car loan $1,500 past due (payment due on the 15th)"
    def detail(debt)
      due = debt.due_day ? " (payment due on the #{debt.due_day.ordinalize})" : ""
      "#{debt.label} #{Money.plain(debt.past_due_cents)} past due#{due}"
    end

    def as_json(*)
      debts.map { |debt| { id: debt.id, label: debt.label, past_due_cents: debt.past_due_cents, due_day: debt.due_day } }
    end

    private

    attr_reader :household

    def active_debts
      household.association(:debts).loaded? ? household.debts.select(&:active?) : household.debts.active.order(:id).to_a
    end
  end
end
