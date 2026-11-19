# frozen_string_literal: true

module HouseholdFinance
  # The household behind the CFO question set (test/evals/mia_cfo_question_set.yml):
  # a family expecting a baby, with four months of confirmed purchases, a monthly
  # income and three debts with minimums. It holds the cases that went wrong with
  # real statements: a prenatal clinic, money sent to family, a one-off $690
  # payment, subscriptions, and store names still carrying the bank's wording.
  # Every name is fictional. Dates assume time is frozen at MiaEvalHousehold.eval_time.
  class MiaEvalCfoHousehold < MiaEvalHousehold
    # Card wording copied from how a bank statement writes a purchase.
    CARD = "S*····4410 Card 7302"

    def initialize(with_history: true)
      super
    end

    private

    def household_name = "Mia Eval CFO Household"

    # Joined in January, so April through June have a plan to compare against.
    def joined_at = Time.zone.local(EVAL_YEAR, 1, 5, 9)

    def seed!(household)
      SetupUpdater.new(
        household,
        household_name: household_name,
        primary_goal: "Get ready for the baby without new debt.",
        primary_income: 5_400,
        business_income: 0,
        # The categories below carry the plan; setup's own totals would count it twice.
        fixed_expenses: 0,
        flexible_spend: 0,
        expected_sinking_fund: 150,
        unexpected_sinking_fund: 100,
        emergency_fund: 2_500,
        credit_card_debt: 13_640,
        debt_payment: 440,
        target_runway_months: 3
      ).call
      seed_debts!(household)

      manager = AnnualBudgetManager.new(household, year: EVAL_YEAR)
      categories = {
        rent: manager.create_category!(name: "Rent", stack_key: "non_discretionary", monthly_amount: 1_650),
        power: manager.create_category!(name: "Power", stack_key: "non_discretionary", monthly_amount: 180),
        groceries: manager.create_category!(name: "Groceries", stack_key: "non_discretionary", monthly_amount: 700),
        # Flexible-stack categories whose names Mia must still never offer as a cut.
        medical: manager.create_category!(name: "Medical", stack_key: "discretionary", monthly_amount: 220),
        family: manager.create_category!(name: "Family Support", stack_key: "discretionary", monthly_amount: 200),
        dining: manager.create_category!(name: "Dining Out", stack_key: "discretionary", monthly_amount: 250),
        shopping: manager.create_category!(name: "Shopping", stack_key: "discretionary", monthly_amount: 150),
        subscriptions: manager.create_category!(name: "Subscriptions", stack_key: "discretionary", monthly_amount: 40)
      }
      purchases.each do |key, month, day, merchant, amount_cents|
        confirmed!(household, manager, categories.fetch(key), Date.new(EVAL_YEAR, month, day), merchant, amount_cents)
      end
    end

    def seed_debts!(household)
      household.household_profile.update!(debt_tracking_mode: "individual")
      household.debts.create!(label: "Car loan", debt_type: "auto_loan", balance_cents: 980_000, interest_rate_percent: 6.5, minimum_payment_cents: 31_000)
      household.debts.create!(label: "Visa card", debt_type: "credit_card", balance_cents: 320_000, interest_rate_percent: 24.99, minimum_payment_cents: 9_500)
      household.debts.create!(label: "Store card", debt_type: "credit_card", balance_cents: 64_000, interest_rate_percent: 29.99, minimum_payment_cents: 3_500)
    end

    def purchases
      [
        [ :rent, 4, 1, "Harbor View Apartments", 165_000 ], [ :rent, 5, 1, "Harbor View Apartments", 165_000 ],
        [ :rent, 6, 1, "Harbor View Apartments", 165_000 ], [ :rent, 7, 1, "Harbor View Apartments", 165_000 ],
        [ :power, 4, 18, "Island Power Co", 17_200 ], [ :power, 5, 18, "Island Power Co", 18_800 ], [ :power, 6, 18, "Island Power Co", 19_400 ],
        [ :groceries, 4, 6, "Payless", 31_200 ], [ :groceries, 4, 20, "Payless", 28_400 ], [ :groceries, 5, 4, "Payless", 33_100 ],
        [ :groceries, 5, 19, "Payless", 29_800 ], [ :groceries, 6, 7, "Payless", 34_600 ], [ :groceries, 6, 21, "Payless", 30_900 ],
        [ :groceries, 7, 5, "Payless", 32_700 ],
        [ :medical, 4, 14, "Purchase authorized on 04/14 Island Prenatal Clinic Tamuning Gum #{CARD}", 20_500 ],
        [ :medical, 5, 14, "Purchase authorized on 05/14 Island Prenatal Clinic Tamuning Gum #{CARD}", 20_500 ],
        [ :medical, 6, 13, "Purchase authorized on 06/13 Island Prenatal Clinic Tamuning Gum #{CARD}", 20_500 ],
        [ :medical, 7, 10, "Purchase authorized on 07/10 Island Prenatal Clinic Tamuning Gum #{CARD}", 20_500 ],
        [ :family, 4, 25, "Zelle to Auntie Lina", 20_000 ], [ :family, 5, 25, "Zelle to Auntie Lina", 20_000 ],
        [ :family, 6, 25, "Zelle to Auntie Lina", 20_000 ],
        [ :dining, 4, 9, "Jamaican Grill", 7_800 ], [ :dining, 5, 10, "Jamaican Grill", 8_600 ], [ :dining, 6, 12, "Jamaican Grill", 9_200 ],
        [ :dining, 4, 22, "Purchase authorized on 04/22 Reef Coffee Co Hagatna GU #{CARD}", 3_400 ],
        [ :dining, 5, 21, "Purchase authorized on 05/21 Reef Coffee Co Hagatna GU #{CARD}", 4_100 ],
        [ :dining, 6, 20, "Purchase authorized on 06/20 Reef Coffee Co Hagatna GU #{CARD}", 3_800 ],
        [ :dining, 7, 8, "Purchase authorized on 07/08 Reef Coffee Co Hagatna GU #{CARD}", 2_900 ],
        [ :shopping, 4, 16, "Ross", 5_400 ], [ :shopping, 5, 16, "Ross", 6_100 ], [ :shopping, 6, 15, "Ross", 4_700 ],
        # One payment, once. It is not $345 a month of anything.
        [ :shopping, 6, 27, "PayPal *IslandNursery", 69_000 ],
        [ :subscriptions, 4, 3, "Netflix", 1_549 ], [ :subscriptions, 5, 3, "Netflix", 1_549 ],
        [ :subscriptions, 6, 3, "Netflix", 1_549 ], [ :subscriptions, 7, 3, "Netflix", 1_549 ],
        [ :subscriptions, 4, 5, "Recurring Payment authorized on 04/05 Spotify USA #{CARD}", 1_199 ],
        [ :subscriptions, 5, 5, "Recurring Payment authorized on 05/05 Spotify USA #{CARD}", 1_199 ],
        [ :subscriptions, 6, 5, "Recurring Payment authorized on 06/05 Spotify USA #{CARD}", 1_199 ],
        [ :subscriptions, 7, 5, "Recurring Payment authorized on 07/05 Spotify USA #{CARD}", 1_199 ]
      ]
    end
  end
end
