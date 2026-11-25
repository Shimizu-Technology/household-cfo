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

    # What catching this debt up pays: the past-due amount, never more than its recorded
    # balance. An unknown balance cannot cap it.
    def catch_up_cents(debt)
      return 0 unless debt.past_due?
      return debt.past_due_cents unless debt.balance_known?

      [ debt.past_due_cents, debt.balance_cents ].min
    end

    def total_catch_up_cents
      debts.sum { |debt| catch_up_cents(debt) }
    end

    # Records that cannot both be true: a past-due amount above the debt's own recorded
    # balance, or an approved summary total below what she is behind. Until she fixes
    # them, nothing may call her debt-free or estimate a payoff.
    def balance_conflict?(debt)
      debt.past_due? && debt.balance_known? && debt.past_due_cents > debt.balance_cents
    end

    def conflicts
      @conflicts ||= begin
        lines = debts.select { |debt| balance_conflict?(debt) }.map do |debt|
          "#{debt.label} shows #{Money.plain(debt.past_due_cents)} past due but a #{Money.plain(debt.balance_cents)} balance"
        end
        portfolio = DebtPortfolio.new(household)
        if any? && portfolio.mode == "summary" && portfolio.balance_known? && portfolio.total_balance_cents < total_cents
          lines << "your approved debt summary shows #{Money.plain(portfolio.total_balance_cents)} owed in all, less than the #{Money.plain(total_cents)} past due"
        end
        lines
      end
    end

    def conflict?
      conflicts.any?
    end

    def as_json(*)
      debts.map do |debt|
        { id: debt.id, label: debt.label, past_due_cents: debt.past_due_cents, due_day: debt.due_day, balance_conflict: balance_conflict?(debt) }
      end
    end

    private

    attr_reader :household

    def active_debts
      household.association(:debts).loaded? ? household.debts.select(&:active?) : household.debts.active.order(:id).to_a
    end
  end
end
