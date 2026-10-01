module HouseholdFinance
  class DebtPortfolio
    attr_reader :household

    def initialize(household)
      @household = household
    end

    def mode
      profile.debt_tracking_mode
    end

    def active_debts
      @active_debts ||= if household.association(:debts).loaded?
        household.debts.select(&:active?)
      else
        household.debts.active.order(:debt_type, :label, :id).to_a
      end
    end

    def archived_debts
      @archived_debts ||= household.debts.archived.order(archived_at: :desc, id: :desc).to_a
    end

    def total_balance_cents
      mode == "summary" ? profile.debt_summary_balance_cents : active_debts.select(&:balance_known?).sum(&:balance_cents)
    end

    def monthly_minimum_cents
      mode == "summary" ? profile.debt_summary_minimum_payment_cents : active_debts.select(&:minimum_payment_known?).sum(&:minimum_payment_cents)
    end

    def balance_known?
      mode == "summary" ? profile.debt_summary_balance_known? : active_debts.any? && active_debts.all?(&:balance_known?)
    end

    def minimum_payment_known?
      mode == "summary" ? profile.debt_summary_minimum_payment_known? : active_debts.any? && active_debts.all?(&:minimum_payment_known?)
    end

    def as_json(*)
      {
        mode: mode,
        total_balance: Money.dollars(total_balance_cents),
        monthly_minimum: Money.dollars(monthly_minimum_cents),
        balance_known: balance_known?,
        minimum_payment_known: minimum_payment_known?,
        active_count: active_debts.length,
        archived_count: archived_debts.length
      }
    end

    private

    def profile
      @profile ||= household.household_profile || household.create_household_profile!
    end
  end
end
