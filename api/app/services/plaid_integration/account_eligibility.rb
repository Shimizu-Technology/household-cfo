module PlaidIntegration
  class AccountEligibility
    RETIREMENT_SUBTYPES = %w[401a 401k 403b 457b ira roth sep_ira simple_ira pension profit_sharing thrift_savings_plan variable_annuity].freeze
    DEPOSITORY_SUBTYPES = %w[checking savings money_market cash_management].freeze

    def initialize(plaid_account)
      @plaid_account = plaid_account
    end

    def eligible?
      allowed_account_types.any?
    end

    def allowed_account_types
      case plaid_account.account_type
      when "depository"
        depository_types
      when "investment"
        RETIREMENT_SUBTYPES.include?(plaid_account.account_subtype.to_s.downcase) ? %w[retirement] : %w[investment retirement]
      else
        []
      end
    end

    def suggested_account_type
      allowed_account_types.first
    end

    def active_observation?
      plaid_account.active? && plaid_account.plaid_item.connected? && plaid_account.plaid_item.status == "active"
    end

    def current_balance_available?
      !plaid_account.current_balance_cents.nil?
    end

    private

    attr_reader :plaid_account

    def depository_types
      case plaid_account.account_subtype.to_s.downcase
      when "checking", "cash_management" then %w[checking]
      when "savings", "money_market" then %w[savings emergency_fund]
      else []
      end
    end
  end
end
