module HouseholdFinance
  # Every household field Mia can set up or change in chat. The change card,
  # the reader's schema and the replies all read this one list, so a field is
  # never handled by one engine before Apply and another after it.
  #
  # kind decides how a value is held and saved:
  #   text    - the participant's own words (household name, goal)
  #   income  - monthly take-home; pay every week, two weeks or twice a month is
  #             offered as a monthly figure she confirms
  #   bills   - named monthly amounts, each saved as its own budget row in its
  #             Expense Stack layer
  #   balance - one amount she has now (an account, or the total owed)
  #   months  - a number of months
  #   debts   - named debts with a monthly minimum and an optional balance
  module HouseholdFieldRegistry
    Field = Data.define(:key, :kind, :label, :name, :required, :stack_key, :default_label, :other_label, :target, :questions, :help, :words) do
      def initialize(required: false, stack_key: nil, default_label: nil, other_label: nil, words: nil, **rest) = super
      def money? = kind.in?(%i[income bills])
      def proposes_pay? = kind == :income
    end

    FIELDS = [
      Field.new(key: "household_name", kind: :text, label: "Household name", name: "your household name", required: true, target: "Household#name",
        questions: [ "What would you like to call your household?", "What name should go on your household plan?" ],
        help: "A household name is just a label you choose, like your family name.", words: /\b(?:name|call(?:ed)?|ohana|family)\b/i),
      Field.new(key: "primary_goal", kind: :text, label: "Main goal", name: "your goal", required: true, target: "Household#primary_goal",
        questions: [ "What's the main thing you'd like your money to do for your household?", "What would you most like this plan to help with?" ],
        help: "A goal is something you want your money plan to help with, like covering the bills or building a little cushion. It can start small, or you can say skip.", words: /\bgoals?\b/i),
      Field.new(key: "primary_income", kind: :income, label: "Monthly income", name: "income", required: true, default_label: "Income", target: "IncomeSource(job)",
        questions: [ "About how much does your household bring home each month after taxes?", "What's your monthly take-home, roughly?" ],
        help: "Monthly take-home is the money you actually receive after taxes in a usual month.", words: /\b(?:income|take[- ]?home|pay(?:check)?s?|paid|salary|wages?|bring (?:home|in)|make|earn)\b/i),
      Field.new(key: "business_income", kind: :income, label: "Business income", name: "business income", default_label: "Business income", target: "IncomeSource(business)",
        questions: [ "About how much does the business bring home each month after its costs?", "What does the business usually bring in a month?" ],
        help: "Business income is what the business brings home for your household after its own costs.", words: /\b(?:business|side (?:job|hustle)|shop|store)\b/i),
      Field.new(key: "fixed_expenses", kind: :bills, label: "Fixed essentials", name: "fixed essentials", required: true, stack_key: "non_discretionary",
        default_label: "Bills", other_label: "Other must-pay bills", target: "BudgetCategory(non_discretionary)",
        questions: [ "What are your must-pay bills each month? One total or a list like rent 1500, power 140 both work.", "What do your regular bills come to each month?" ],
        help: "Fixed essentials are the bills you need to cover every month, like rent and utilities.", words: /\b(?:bills?|rent|essentials|fixed|mortgage|power|water|phone|internet|insurance|utilit(?:y|ies))\b/i),
      Field.new(key: "flexible_spend", kind: :bills, label: "Everyday spending", name: "everyday spending", required: true, stack_key: "discretionary",
        default_label: "Everyday spending", other_label: "Other everyday spending", target: "BudgetCategory(discretionary)",
        questions: [ "About how much goes to everyday spending each month, like groceries and gas?", "What's your usual everyday spending in a month?" ],
        help: "Everyday spending is what you plan for things like groceries, gas and other costs that change month to month.", words: /\b(?:everyday|groceries|grocery|food|gas|spending|extras?|flexible)\b/i),
      Field.new(key: "expected_sinking_fund", kind: :bills, label: "Planned yearly costs", name: "planned yearly costs", stack_key: "sinking_expected",
        default_label: "Planned yearly costs", other_label: "Other planned yearly costs", target: "BudgetCategory(sinking_expected)",
        questions: [ "What do you set aside each month for costs you know are coming, like registration or school?", "What do you put away each month for planned yearly costs?" ],
        help: "Planned yearly costs are things you know are coming, like car registration or back to school, saved for a little each month.", words: /\b(?:sinking|yearly|annual|registration|school|holidays?|christmas|planned)\b/i),
      Field.new(key: "unexpected_sinking_fund", kind: :bills, label: "Surprise fund", name: "your surprise fund", stack_key: "sinking_unexpected",
        default_label: "Surprise fund", other_label: "Other surprise costs", target: "BudgetCategory(sinking_unexpected)",
        questions: [ "What do you set aside each month for surprises, like repairs or a clinic visit?", "What goes into your surprise fund each month?" ],
        help: "A surprise fund is money set aside each month for things you can't plan, like repairs or a clinic visit.", words: /\b(?:surprise|unexpected|repairs?|emergenc(?:y|ies)|life happens)\b/i),
      Field.new(key: "emergency_fund", kind: :balance, label: "Emergency fund", name: "your emergency fund", target: "Account(emergency_fund)",
        questions: [ "How much is in your emergency fund right now?", "What does your emergency fund have in it today?" ],
        help: "Your emergency fund is the money you keep set aside for a real emergency, as it stands today.", words: /\b(?:emergency|rainy day|cushion)\b/i),
      Field.new(key: "other_assets", kind: :balance, label: "Other savings", name: "other savings", target: "Account(other)",
        questions: [ "Do you have other savings put away, and about how much?", "How much do you have in other savings?" ],
        help: "Other savings is money put away somewhere besides your emergency fund.", words: /\b(?:savings?|saved up|investments?|assets?)\b/i),
      Field.new(key: "credit_card_debt", kind: :balance, label: "Debt balance", name: "what you owe", target: "HouseholdProfile#debt_summary_balance",
        questions: [ "About how much do you owe in total on your debts?", "What's the total you still owe?" ],
        help: "This is the total you still owe on your debts, not the monthly payment.", words: /\b(?:owe|owed|owing|balance|debt)\b/i),
      Field.new(key: "debt_payment", kind: :debts, label: "Debts", name: "debts", required: true, target: "Debt",
        questions: [ "What do you pay on debts each month? List each one with its minimum, or say no debts.", "Which debts do you have, and what's the minimum on each? You can say no debts." ],
        help: "This is the minimum you have to pay on each debt every month, not the balance you owe.", words: /\b(?:debts?|loans?|cards?|visa|minimums?|owe)\b/i),
      Field.new(key: "target_runway_months", kind: :months, label: "Runway goal", name: "your runway goal", target: "Goal(runway)",
        questions: [ "How many months of bills would you like to have saved up?", "How many months of runway are you aiming for?" ],
        help: "Your runway goal is how many months of bills you'd like saved, so a hard month doesn't knock the plan over.", words: /\b(?:runway|months? of (?:bills|expenses|savings))\b/i)
    ].freeze

    BY_KEY = FIELDS.index_by(&:key).freeze
    KEYS = FIELDS.map(&:key).freeze
    REQUIRED_KEYS = FIELDS.select(&:required).map(&:key).freeze
    MONEY_KEYS = FIELDS.select(&:money?).map(&:key).freeze
    BILL_KEYS = FIELDS.select { |field| field.kind == :bills }.map(&:key).freeze
    INCOME_KEYS = FIELDS.select { |field| field.kind == :income }.map(&:key).freeze
    TEXT_KEYS = FIELDS.select { |field| field.kind == :text }.map(&:key).freeze
    BALANCE_KEYS = FIELDS.select { |field| field.kind == :balance }.map(&:key).freeze
    MONTHS_KEYS = FIELDS.select { |field| field.kind == :months }.map(&:key).freeze
    DEBT_KEY = "debt_payment".freeze
    # Paychecks a year for each stated pay rhythm. Twice a month is 24, so its
    # working reads as "× 2".
    PAY_TIMES = { "weekly" => 52, "biweekly" => 26, "twice_monthly" => 24 }.freeze
    MAX_TEXT = { "household_name" => 120, "primary_goal" => 500 }.freeze
    MAX_RUNWAY_MONTHS = 120

    module_function

    def fetch(key) = BY_KEY.fetch(key.to_s)
    def field?(key) = BY_KEY.key?(key.to_s)
    def kind(key) = fetch(key).kind
    def label(key) = fetch(key).label
    def name(key) = fetch(key).name
    def help(key) = fetch(key).help
    def questions(key) = fetch(key).questions
    def stack_key(key) = fetch(key).stack_key
    def bill_field_for_stack(stack_key) = BILL_KEYS.find { |key| fetch(key).stack_key == stack_key }
    def mentioned?(key, message) = fetch(key).words&.match?(message.to_s) || false
  end
end
