# frozen_string_literal: true

module HouseholdFinance
  # The synthetic household every Mia eval talks to: the deterministic CI
  # harness and the opt-in live model runner (mia:evals:live). Dates assume the
  # caller has frozen time at EVAL_TIME.
  class MiaEvalHousehold
    EVAL_YEAR = 2026
    EVAL_MONTH = 7

    def self.eval_time
      Time.zone.local(EVAL_YEAR, EVAL_MONTH, 15, 12)
    end

    # with_history adds Groceries plus April and May activity so "last three
    # months" questions have something real to read. The deterministic harness
    # leaves it off so its exact-phrase expectations stay stable.
    def self.create!(with_history: false)
      new(with_history: with_history).create!
    end

    def initialize(with_history:)
      @with_history = with_history
    end

    def create!
      user = User.create!(
        clerk_id: "clerk_#{SecureRandom.hex(6)}",
        email: "mia-eval-#{SecureRandom.hex(6)}@example.com",
        role: "participant",
        invitation_status: "accepted"
      )
      household = Household.create!(created_by_user: user, name: "Mia Eval Household", primary_goal: "Keep the household calm and honest.")
      household.household_memberships.create!(user: user, role: "owner")
      seed!(household)
      [ user, household ]
    end

    private

    attr_reader :with_history

    def seed!(household)
      SetupUpdater.new(
        household,
        household_name: "Mia Eval Household",
        primary_goal: "Build a calm money rhythm.",
        primary_income: 8_000,
        business_income: 0,
        fixed_expenses: 4_000,
        flexible_spend: 1_000,
        expected_sinking_fund: 300,
        unexpected_sinking_fund: 200,
        emergency_fund: 8_000,
        credit_card_debt: 2_000,
        debt_payment: 150,
        target_runway_months: 6
      ).call

      manager = AnnualBudgetManager.new(household, year: EVAL_YEAR)
      dining = manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 310)
      software = manager.create_category!(name: "Software", stack_key: "discretionary", monthly_amount: 100)
      manager.create_category!(name: "Car Registration", stack_key: "sinking_expected", monthly_amount: 50)
      confirmed!(household, manager, dining, Date.new(EVAL_YEAR, 7, 6), "Cafe", 4_500)
      confirmed!(household, manager, software, Date.new(EVAL_YEAR, 6, 28), "Netlify", 2_000)
      seed_history!(household, manager, dining) if with_history
      household.transaction_drafts.create!(
        occurred_on: Date.current,
        merchant: "Starbucks",
        total_amount_cents: 2_200,
        budget_category: dining,
        source_type: "manual_chat",
        status: "pending",
        raw_input: "I spent 2200 at Starbucks"
      )
    end

    def seed_history!(household, manager, dining)
      groceries = manager.create_category!(name: "Groceries", stack_key: "non_discretionary", monthly_amount: 650)
      [
        [ dining, 4, 5, "Jamaican Grill", 6_800 ], [ dining, 4, 19, "Cafe", 4_200 ], [ groceries, 4, 8, "Payless", 18_400 ],
        [ dining, 5, 3, "Jamaican Grill", 7_400 ], [ dining, 5, 17, "Cafe", 5_100 ], [ dining, 5, 24, "Pizza Hut", 3_900 ],
        [ groceries, 5, 10, "Payless", 21_200 ], [ dining, 6, 7, "Jamaican Grill", 8_200 ], [ dining, 6, 14, "Cafe", 4_800 ],
        [ dining, 6, 21, "Pizza Hut", 4_600 ], [ groceries, 6, 12, "Payless", 22_900 ], [ groceries, 7, 3, "Payless", 9_800 ]
      ].each do |category, month, day, merchant, amount_cents|
        confirmed!(household, manager, category, Date.new(EVAL_YEAR, month, day), merchant, amount_cents)
      end
    end

    def confirmed!(household, manager, category, occurred_on, merchant, amount_cents)
      transaction = household.household_transactions.create!(
        budget_period: manager.current_period_for(occurred_on),
        occurred_on: occurred_on,
        merchant: merchant,
        total_amount_cents: amount_cents,
        source_type: "manual_ui",
        status: "confirmed"
      )
      transaction.transaction_splits.create!(budget_category: category, amount_cents: amount_cents)
    end
  end
end
