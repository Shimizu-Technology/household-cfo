module HouseholdFinance
  class AssetPortfolio
    def initialize(household)
      @household = household
    end

    def active_accounts
      @active_accounts ||= household.accounts.active.order(:account_type, :label, :id).to_a
    end

    def archived_accounts
      @archived_accounts ||= household.accounts.archived.order(:account_type, :label, :id).to_a
    end

    def liquid_accounts
      @liquid_accounts ||= active_accounts.select(&:liquid?)
    end

    def nonliquid_accounts
      @nonliquid_accounts ||= active_accounts.reject(&:liquid?)
    end

    def liquid_assets_cents
      known_sum(liquid_accounts)
    end
    alias_method :liquid_balance_cents, :liquid_assets_cents

    def nonliquid_assets_cents
      known_sum(nonliquid_accounts)
    end
    alias_method :nonliquid_balance_cents, :nonliquid_assets_cents

    def total_assets_cents
      known_sum(active_accounts)
    end
    alias_method :total_balance_cents, :total_assets_cents

    def liquid_assets_known?
      liquid_accounts.any? && liquid_accounts.all?(&:balance_known?)
    end
    alias_method :liquid_balance_known?, :liquid_assets_known?

    def nonliquid_assets_known?
      nonliquid_accounts.any? && nonliquid_accounts.all?(&:balance_known?)
    end
    alias_method :nonliquid_balance_known?, :nonliquid_assets_known?

    def total_assets_known?
      liquid_assets_known? && nonliquid_assets_known?
    end
    alias_method :total_balance_known?, :total_assets_known?

    def as_json(*)
      {
        liquid_balance: Money.dollars(liquid_balance_cents),
        nonliquid_balance: Money.dollars(nonliquid_balance_cents),
        total_balance: Money.dollars(total_balance_cents),
        liquid_balance_known: liquid_balance_known?,
        nonliquid_balance_known: nonliquid_balance_known?,
        total_balance_known: total_balance_known?,
        active_count: active_accounts.length,
        archived_count: archived_accounts.length,
        unknown_balance_account_ids: active_accounts.reject(&:balance_known?).map(&:id)
      }
    end

    private

    attr_reader :household

    def known_sum(accounts)
      accounts.select(&:balance_known?).sum(&:balance_cents)
    end
  end
end
