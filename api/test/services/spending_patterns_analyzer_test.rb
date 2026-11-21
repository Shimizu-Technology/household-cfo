require "test_helper"
require_relative "../support/savings_evidence_test_support"

class SpendingPatternsAnalyzerTest < ActiveSupport::TestCase
  include SavingsEvidenceTestSupport
  setup do
    @user = User.create!(clerk_id: "patterns-#{SecureRandom.hex(8)}", email: "patterns-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @category = @household.budget_categories.create!(name: "Optional shopping", stack_key: "discretionary", sort_order: 1)
  end

  test "the bills-excluded claim requires every named part of the list to be bill free" do
    ordinary = [ { label: "Talun Demo Market" } ]
    assert SpendingPatterns::Answerer.bill_free_list?(ordinary, [ "Optional shopping" ], [], nil)
    refute SpendingPatterns::Answerer.bill_free_list?([ { label: "Talun Demo Power" } ], [], [], nil)
    refute SpendingPatterns::Answerer.bill_free_list?(ordinary, [ "Electricity" ], [], nil)
    refute SpendingPatterns::Answerer.bill_free_list?(ordinary, [ "Internet" ], [], nil)
    refute SpendingPatterns::Answerer.bill_free_list?(ordinary, [], [ { merchant: "Talun Demo Water" } ], nil)
    refute SpendingPatterns::Answerer.bill_free_list?(ordinary, [], [], { label: "Talun Demo Sewer" })
  end

  test "utility companies stay protected while ordinary stores and fuel stay ordinary" do
    protected = [ "Tasi Demo Power", "Island Water Co", "Demo Electric Company", "Guam Power Authority", "Talun Electricity Services", "Talun Gas Co", "Island Gas Company", "Gas Authority", "Island Water Co., Ltd.", "Talun Sewer Inc", "Talun Telecom", "Talun Internet", "Talun Telephone Company LLC" ]
    ordinary = [ "Power Mart", "Powerhouse Gym", "Water World Toys", "Gas Station", "Talun Gas Station", "Costco Gas", "Shell Gas" ]
    protected.each { |name| assert SpendingPatterns::Analyzer.protected_merchant?(name), name }
    ordinary.each { |name| refute SpendingPatterns::Analyzer.protected_merchant?(name), name }
    [ Date.new(2026, 9, 12), Date.new(2026, 10, 12) ].each do |date|
      (protected + ordinary).each { |name| purchase(date, name, 3000) }
    end
    result = analyze
    assert_empty(result[:candidate_changes].pluck(:merchant) & protected)
    ordinary.each { |name| assert_includes result[:discretionary_merchants].pluck(:label), name }
  end

  test "fuel retailers ending in gas can be recurring cut choices" do
    [ Date.new(2026, 9, 12), Date.new(2026, 10, 12) ].each do |date|
      [ "Costco Gas", "Shell Gas" ].each { |name| purchase(date, name, 3000) }
    end
    result = analyze
    [ "Costco Gas", "Shell Gas" ].each do |name|
      assert_includes result[:discretionary_merchants].pluck(:label), name
      assert_includes result[:candidate_changes].pluck(:merchant), name
    end
  end

  test "household and challenge pattern references answer the question focus" do
    observed = "I only see purchases for Oct: Ross ($300) was your biggest flexible spending stop."
    messages = [ "what do you notice in my spending", "what stands out on the statement i just did", "where can i cut back", "any small buys adding up" ]
    replies = messages.map do |message|
      SpendingPatterns::Answerer.question_reference(message: message, observed: observed,
        waterfall: " 3 small buys stacked up around month-end — $36 altogether.",
        estimate: " Spending half as much at Ross could free about $150 a month.", question: "Which feels comfortable?")
    end
    assert_equal 4, replies.uniq.length
    assert_includes replies[2], "Which purchase felt optional?"
    refute_includes replies[2], "Spending half"
    assert replies[3].start_with?("3 small buys")
    assert_includes replies[3], "Oct"
  end

  test "Mia never offers medical care, family support, money sent to people or a one-off as a cut" do
    medical = @household.budget_categories.create!(name: "Doctor and medical", stack_key: "discretionary", sort_order: 2)
    support = @household.budget_categories.create!(name: "Money sent", stack_key: "discretionary", sort_order: 3)
    dining = @household.budget_categories.create!(name: "Eating out and coffee", stack_key: "discretionary", sort_order: 4)
    [ Date.new(2026, 9, 14), Date.new(2026, 10, 14) ].each do |date|
      purchase(date, "Purchase authorized on #{date.strftime('%m/%d')} Harbor Family Clinic Tamuning Gum S*····4410 Card 7302", 41_000, category: medical)
      purchase(date, "Zelle to Reyes Ana on #{date.strftime('%m/%d')} Ref # Demo1A2B3C4D", 30_000, category: support)
      purchase(date, "Purchase authorized on #{date.strftime('%m/%d')} Reef Coffee Co Barrigada Gum S*····#{date.day}95 Card 7302", 9_000, category: dining)
    end
    purchase(Date.new(2026, 9, 17), "Money Transfer authorized on 09/17 Paypal *Jordan.Cruz San Jose CA S*····5519 Card", 69_000, category: @category)
    purchase(Date.new(2026, 10, 3), "Ross", 50_000)
    pharmacy = @household.budget_categories.create!(name: "Medication", stack_key: "discretionary", sort_order: 5)
    [ Date.new(2026, 9, 20), Date.new(2026, 10, 20) ].each do |date|
      purchase(date, "Mega Drug Tamuning", 12_000, category: pharmacy)
      purchase(date, "PAYPAL *JANEDOE.SMITH", 8_000)
      purchase(date, "Purchase: Venmo to Alex Rivera", 6_000)
    end
    result = analyze
    labels = result[:candidate_changes].map { |row| row[:merchant] }
    assert_equal [ "Reef Coffee Co" ], labels
    assert_equal 9_000, result[:candidate_changes].first[:monthly_impact_cents] * 2
    refute_includes result[:discretionary_categories].map { |row| row[:label] }, "Doctor and medical"
    refute(result[:discretionary_merchants].any? { |row| row[:label].include?("Harbor Family") })
    assert_equal 1, result[:discretionary_merchants].count { |row| row[:label] == "Reef Coffee Co" }
    assert_equal 41_000 * 2 + 30_000 * 2 + 9_000 * 2 + 69_000 + 50_000 + (12_000 + 8_000 + 6_000) * 2, result[:observed_spending_cents]
  end

  test "the core categories are always protected; a program can add more; store names and insurance stay protected" do
    analyzer = SpendingPatterns::Analyzer
    assert analyzer.protected_category?("Family outings")
    assert analyzer.protected_category?("Family outings", %w[housing utilities]), "family support is core; a list cannot drop it"
    assert analyzer.protected_category?("Car payment", [])
    assert analyzer.protected_category?("Car insurance", [])
    refute analyzer.protected_category?("Groceries")
    assert analyzer.protected_category?("Groceries", %w[groceries])
    assert analyzer.protected_category?("Church tithes", %w[giving])
    assert analyzer.protected_category?("Fiesta and community", %w[community])
    refute analyzer.protected_category?("Eating out", %w[groceries giving community])
    family = @household.budget_categories.create!(name: "Family outings", stack_key: "discretionary", sort_order: 2)
    groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 3)
    [ Date.new(2026, 9, 12), Date.new(2026, 10, 12) ].each do |date|
      purchase(date, "Island Fun Center", 12_000, category: family)
      purchase(date, "Talofofo Prenatal Clinic", 20_500, category: family)
      purchase(date, "Payless Market", 15_000, category: groceries)
    end
    default = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2)).call
    assert_equal [ "Payless Market" ], default[:candidate_changes].pluck(:merchant)
    assert_equal CohortExperience::MethodSettings::CORE_PROTECTED, default[:protected_categories]
    added = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), protected: %w[groceries]).call
    assert_empty added[:candidate_changes]
    assert_equal CohortExperience::MethodSettings::CORE_PROTECTED + %w[groceries], added[:protected_categories]
  end

  test "a clinic, pharmacy, daycare, insurer or money for family filed as flexible spending is never a cut" do
    family = @household.budget_categories.create!(name: "Sent to Nana", stack_key: "discretionary", sort_order: 2)
    cover = @household.budget_categories.create!(name: "Car insurance", stack_key: "discretionary", sort_order: 3)
    [ Date.new(2026, 9, 12), Date.new(2026, 10, 12) ].each do |date|
      # "Optional shopping" names nothing protected; the store names do.
      purchase(date, "Purchase authorized on #{date.strftime('%m/%d')} Talofofo Prenatal Clinic Talofofo GU S····5237 Card 5237", 20_500)
      purchase(date, "Coral Reef Pharmacy", 4_200)
      purchase(date, "Little Tasi Daycare", 30_000)
      purchase(date, "Zelle to Tia Rosa", 15_000)
      purchase(date, "Remittance to Nana Talun", 10_000, category: family)
      purchase(date, "Harbor Mutual Insurance", 9_000, category: cover)
      purchase(date, "Seabreeze Snack Bar", 3_000)
    end
    result = analyze
    assert_equal [ "Seabreeze Snack Bar" ], result[:candidate_changes].pluck(:merchant)
    assert_equal [ "Seabreeze Snack Bar" ], result[:discretionary_merchants].pluck(:label)
    assert_equal [ "Optional shopping" ], result[:discretionary_categories].pluck(:label)
    assert_equal 3_000 * 2, result[:discretionary_categories].first[:total_cents]
    # They still count as spending, and "where does it go" still sees them.
    assert_equal (20_500 + 4_200 + 30_000 + 15_000 + 10_000 + 9_000 + 3_000) * 2, result[:observed_spending_cents]
    assert_includes result[:merchants].pluck(:label), "Talofofo Prenatal Clinic"
    assert_equal [ "Optional shopping", "Sent to Nana", "Car insurance" ], result[:categories].pluck(:label)
  end

  test "remittances, childcare, pharmacies and doctors filed as flexible spending are never a cut" do
    travel_to Time.zone.local(2026, 11, 2, 12) do
      [ Date.new(2026, 9, 12), Date.new(2026, 10, 12) ].each do |date|
        [ "WESTERN UNION 1234", "Remittance to Nana Talun", "Island Nursery", "WALGREENS #1234", "GUAM OB/GYN ASSOCIATES",
          "Sent to Tia Rosa", "MONEYGRAM 5521", "Island Eye Care", "Dr. Ana Cruz", "Ana Cruz MD", "Island Rx" ].each { |name| purchase(date, name, 10_000) }
        # Ordinary stores whose names only look close: still flexible spending.
        purchase(date, "Rx Pizza", 4_000)
        purchase(date, "Seabreeze Snack Bar", 3_000)
      end
      result = analyze
      assert_equal [ "Rx Pizza", "Seabreeze Snack Bar" ], result[:candidate_changes].pluck(:merchant)
      assert_equal [ "Rx Pizza", "Seabreeze Snack Bar" ], result[:discretionary_merchants].pluck(:label)
      assert_equal (10_000 * 11 + 4_000 + 3_000) * 2, result[:observed_spending_cents]
      assert(result[:merchants].select { |row| row[:label].match?(/WESTERN UNION|Remittance|Sent to|MONEYGRAM/) }.all? { |row| row[:transfer_to_person] })

      cut = SpendingPatterns::Answerer.new(household: @household, message: "What should I cut first?", persona: Mia::Persona.neutral, history: [], approved_content: []).call
      refute_match(/WESTERN|Remittance|Nursery|WALGREENS|OB\/GYN|Tia Rosa|MONEYGRAM|Eye Care|Cruz|Island Rx/i, cut)
      assert_includes cut, "I left out stores and categories that look like rent, bills, medical care, childcare or money for family."
      refute_includes cut, "aren’t on this list"
    end
  end

  test "a store whose name only looks like care, rent or a bill can still be a cut" do
    stores = [ "Dr Juice Bar", "Whole Health Foods", "Vision Buffet", "Rent-A-Center", "Utility Trailer Sales", "Island Garden Nursery", "TARGET 1234 BALTIMORE MD" ]
    stores.each { |name| refute SpendingPatterns::Analyzer.protected_merchant?(name), name }
    [ "Ana Cruz MD", "ANA CRUZ MD", "Cruz, M.D.", "Dr. Ana Cruz", "DR LEON GUERRERO", "Little Stars Daycare", "Island Nursery", "Island Pediatric Clinic",
      "Island Vision Center", "Guam Health Care", "Tamuning Apartments Rent", "Monthly rent", "Guam Power Authority", "City Utilities", "UTILITY PAYMENT",
      "Guam Waterworks", "Harbor Mutual Insurance", "Coral Reef Pharmacy" ].each { |name| assert SpendingPatterns::Analyzer.protected_merchant?(name), name }
    refute SpendingPatterns::Analyzer.protected_category?("Health and beauty")
    refute SpendingPatterns::Analyzer.protected_category?("Health & fitness")
    [ "Health", "Healthcare", "Medical", "Childcare", "Rent", "Utilities", "Car insurance", "Family support" ].each { |name| assert SpendingPatterns::Analyzer.protected_category?(name), name }

    beauty = @household.budget_categories.create!(name: "Health and beauty", stack_key: "discretionary", sort_order: 2)
    [ Date.new(2026, 9, 12), Date.new(2026, 10, 12) ].each do |date|
      stores.each { |name| purchase(date, name, 4_000) }
      purchase(date, "Island Beauty Supply", 3_000, category: beauty)
      purchase(date, "Little Stars Daycare", 30_000)
      purchase(date, "Zelle to Tia Rosa", 15_000)
    end
    result = analyze
    flexible = result[:discretionary_merchants].pluck(:label)
    assert_includes flexible, "Dr Juice Bar"
    assert_includes flexible, "Island Garden Nursery"
    assert_includes flexible, "Island Beauty Supply"
    assert_equal stores.length + 1, flexible.length
    refute_includes flexible, "Little Stars Daycare"
    refute_includes flexible, "Zelle to Tia Rosa"
    assert_includes result[:discretionary_categories].pluck(:label), "Health and beauty"
  end

  test "a family support category is protected, other support is not" do
    assert SpendingPatterns::Analyzer.protected_category?("Family support")
    assert SpendingPatterns::Analyzer.protected_category?("Child support")
    assert SpendingPatterns::Analyzer.protected_category?("Support for Nana")
    refute SpendingPatterns::Analyzer.protected_category?("Tech support")
  end

  test "two purchases of different sizes are never a monthly cut" do
    # $250 in September and $690 in October: maybe two one-offs, never "about $235 a month".
    purchase(Date.new(2026, 9, 27), "Coral Crib Outlet", 25_000)
    purchase(Date.new(2026, 10, 20), "Coral Crib Outlet", 69_000)
    # Two months of about the same size are still a habit.
    purchase(Date.new(2026, 9, 6), "Reef Coffee Co", 4_000)
    purchase(Date.new(2026, 10, 6), "Reef Coffee Co", 5_000)
    result = analyze
    assert_equal [ "Reef Coffee Co" ], result[:candidate_changes].pluck(:merchant)
    refute_includes result[:recurring_discretionary_merchants].pluck(:label), "Coral Crib Outlet"
    # Still counted where the money went.
    assert_equal 94_000, result[:merchants].find { |row| row[:label] == "Coral Crib Outlet" }[:total_cents]

    snapshot = HouseholdFinance::MiaEvalLedger.new(@household, today: Date.new(2026, 11, 2)).snapshot({})
    assert_includes snapshot["one_month_merchants"].pluck("label"), "Coral Crib Outlet"
    refute_includes snapshot["one_month_merchants"].pluck("label"), "Reef Coffee Co"
    assert_equal [ "one_month_saving" ], HouseholdFinance::MiaEvalRules.violations(prompt: "What should I cut first?",
      response: "Spending half as much at Coral Crib Outlet could free about $235 a month.", ledger: snapshot).pluck("rule")
  end

  test "a one-off split across categories is still one payment, and three times usual is not yet a one-off" do
    toys = @household.budget_categories.create!(name: "Toys", stack_key: "discretionary", sort_order: 2)
    gifts = @household.budget_categories.create!(name: "Gifts", stack_key: "discretionary", sort_order: 3)
    purchase(Date.new(2026, 8, 6), "Seabreeze Snack Bar", 6_000)
    purchase(Date.new(2026, 9, 6), "Seabreeze Snack Bar", 7_000)
    split = purchase(Date.new(2026, 10, 6), "Seabreeze Snack Bar", 69_000)
    split.transaction_splits.sole.update!(amount_cents: 23_000)
    [ toys, gifts ].each { |category| split.transaction_splits.create!(budget_category: category, amount_cents: 23_000) }
    # Exactly three times the middle of the others ($65) stays a usual payment.
    purchase(Date.new(2026, 8, 9), "Reef Coffee Co", 6_000)
    purchase(Date.new(2026, 9, 9), "Reef Coffee Co", 7_000)
    purchase(Date.new(2026, 10, 9), "Reef Coffee Co", 19_500)
    result = analyze
    seabreeze = result[:discretionary_merchants].find { |row| row[:label] == "Seabreeze Snack Bar" }
    assert_equal 3, seabreeze[:purchase_count]
    assert_equal 82_000, seabreeze[:total_cents]
    assert_equal 3_250, result[:candidate_changes].find { |row| row[:merchant] == "Seabreeze Snack Bar" }[:monthly_impact_cents]
    assert_equal (6_000 + 7_000 + 19_500) / 3 / 2, result[:candidate_changes].find { |row| row[:merchant] == "Reef Coffee Co" }[:monthly_impact_cents]
    # Category totals still read each split.
    assert_equal 23_000, result[:discretionary_categories].find { |row| row[:label] == "Toys" }[:total_cents]
  end

  test "stores that are care are protected names in the eval ledger" do
    [ Date.new(2026, 9, 12), Date.new(2026, 10, 12) ].each do |date|
      purchase(date, "Island Nursery", 30_000)
      purchase(date, "WESTERN UNION 1234", 10_000)
      purchase(date, "Seabreeze Snack Bar", 3_000)
    end
    snapshot = HouseholdFinance::MiaEvalLedger.new(@household, today: Date.new(2026, 11, 2)).snapshot({})
    assert_includes snapshot["protected_names"], "Island Nursery"
    assert_includes snapshot["protected_names"], "WESTERN UNION"
    refute_includes snapshot["protected_names"], "Seabreeze Snack Bar"
    assert_equal [ "protected_cut" ], HouseholdFinance::MiaEvalRules.violations(prompt: "What should I cut first?",
      response: "Spending half as much at Island Nursery could free about $150 a month.", ledger: snapshot).pluck("rule")
  end

  test "a one-off payment is never averaged into a monthly saving" do
    # Bought once: never a monthly habit, whatever the months recorded.
    purchase(Date.new(2026, 9, 27), "Coral Crib Outlet", 69_000)
    # A $690 one-off at a store she visits for $20 leaves only one regular month: no cut.
    purchase(Date.new(2026, 9, 3), "Hafa Home Goods", 2_000)
    purchase(Date.new(2026, 10, 18), "Hafa Home Goods", 69_000)
    # A store she keeps going back to: the one-off is left out of its monthly figure.
    purchase(Date.new(2026, 8, 6), "Seabreeze Snack Bar", 6_000)
    purchase(Date.new(2026, 9, 6), "Seabreeze Snack Bar", 7_000)
    purchase(Date.new(2026, 10, 6), "Seabreeze Snack Bar", 69_000)
    result = analyze
    assert_equal [ "Seabreeze Snack Bar" ], result[:candidate_changes].pluck(:merchant)
    # Half of the $65 regular months, not half of ($60 + $70 + $690) / 3.
    assert_equal 3_250, result[:candidate_changes].first[:monthly_impact_cents]
    assert_equal [ "Seabreeze Snack Bar" ], result[:recurring_discretionary_merchants].pluck(:label)
    refute_includes result[:recurring_discretionary_merchants].pluck(:label), "Coral Crib Outlet"
    # Totals are unchanged: the one-offs were spent.
    assert_equal 82_000, result[:discretionary_merchants].find { |row| row[:label] == "Seabreeze Snack Bar" }[:total_cents]
  end

  test "cut first and where the money goes are different answers" do
    travel_to Time.zone.local(2026, 11, 2, 12) do
      rent = @household.budget_categories.create!(name: "Rent", stack_key: "non_discretionary", sort_order: 2)
      [ 9, 10 ].each do |month|
        purchase(Date.new(2026, month, 1), "Harbor View Apartments", 150_000, category: rent)
        purchase(Date.new(2026, month, 8), "Purchase authorized on #{month}/08 Seabreeze Snack Bar Hagatna GU S····5237 Card 5237", 6_000)
        purchase(Date.new(2026, month, 14), "Talofofo Prenatal Clinic", 20_500)
      end
      purchase(Date.new(2026, 10, 20), "Coral Crib Outlet", 69_000)
      reply = ->(message) { SpendingPatterns::Answerer.new(household: @household, message: message, persona: Mia::Persona.neutral, history: [], approved_content: []).call }
      assert SpendingPatterns::Answerer.observation_question?("What should I cut first?")
      assert SpendingPatterns::Answerer.observation_question?("Where is my money going?")
      [ "What should we cut first?", "Where can I cut back on spending?", "What can I cut?" ].each { |message| assert SpendingPatterns::Answerer.cut_question?(message), message }
      [ "What if I cut dining out to cover it?", "where can we cut back weekend shifts" ].each { |message| refute SpendingPatterns::Answerer.cut_question?(message), message }
      [ "Which of these should I cut?", "What else can we cut?" ].each { |message| assert SpendingPatterns::Answerer.cut_question?(message), message }
      # Work, not spending: never routed to the spending answer with the reader unavailable.
      [ "Which weekend shifts should we cut?", "Where can we cut back weekend shifts?" ].each do |message|
        refute SpendingPatterns::Answerer.cut_question?(message), message
        refute SpendingPatterns::Answerer.matches?(message), message
      end
      cut = reply.call("What should I cut first?")
      where = reply.call("Where is my money going?")
      refute_equal cut, where
      assert_includes cut, "Seabreeze Snack Bar ($120)"
      assert_includes cut, "could free about $30 a month"
      assert_includes cut, "medical care, childcare or money for family"
      refute_match(/Prenatal|Crib|Harbor View|Purchase authorized|S····/, cut)
      assert_includes where, "most of your money went to Rent ($3,000)"
      assert_includes where, "Harbor View Apartments ($3,000)"
      assert_includes where, "Coral Crib Outlet ($690)"
      refute_match(/could free|cut|Purchase authorized|S····/i, where)
    end
  end

  test "a plan for money still to come is not a where-it-went question, and a named month is read" do
    [ "Where should my tax refund money go?", "Where should the extra cash go, savings or debt?",
      "Where is the money for rent going to come from?", "Where will my bonus go?" ].each do |message|
      refute SpendingPatterns::WhereMoneyGoes.question?(message), message
      refute SpendingPatterns::Answerer.observation_question?(message), message
    end
    [ "Where is my money going?", "Where did my money go in August?", "Where does my money go?", "Where am I spending the most?", "Where did it all go?" ].each do |message|
      assert SpendingPatterns::WhereMoneyGoes.question?(message), message
    end
    travel_to Time.zone.local(2026, 11, 2, 12) do
      purchase(Date.new(2026, 8, 6), "Seabreeze Snack Bar", 6_000)
      purchase(Date.new(2026, 10, 6), "Coral Crib Outlet", 69_000)
      reply = SpendingPatterns::Answerer.new(household: @household, message: "Where did my money go in August?", persona: Mia::Persona.neutral, history: [], approved_content: []).call
      assert_includes reply, "For August 2026 in your reviewed purchases, most of your money went to Optional shopping ($60)."
      refute_includes reply, "Coral Crib"
    end
  end

  test "R2 current month reviewed purchases are visible without claiming a complete month" do
    purchase(Date.new(2026, 11, 3), "Ross", 6000)
    result = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 7)).call
    assert_equal 6000, result[:observed_spending_cents]
    assert_equal "2026-11-07", result[:window][:end_on]
    assert_equal "partial", result[:coverage][:status]
  end

  test "bank fees stay in spending totals but are excluded from small buys" do
    purchase(Date.new(2026, 10, 23), "Cafe", 1200)
    purchase(Date.new(2026, 10, 24), "Cafe", 1000)
    purchase(Date.new(2026, 10, 25), "Cafe", 1449)
    purchase(Date.new(2026, 10, 25), "Monthly service fee", 500)
    purchase(Date.new(2026, 10, 25), "NSF Charge", 600)
    result = analyze
    assert_equal 4749, result[:observed_spending_cents]
    cluster = result[:small_purchase_clusters].find { |row| row[:label] == "Friday through Sunday" }
    assert_equal 3, cluster[:purchase_count]
    assert_equal 3649, cluster[:total_cents]
  end

  test "review one separately ranked merchants never inherit unrelated category names" do
    travel_to Time.zone.local(2026, 11, 5, 12) do
      dining = @household.budget_categories.create!(name: "Meals out", stack_key: "discretionary", sort_order: 2)
      travel = @household.budget_categories.create!(name: "Trips", stack_key: "discretionary", sort_order: 3)
      purchase(Date.new(2026, 10, 5), "Ross", 15000)
      purchase(Date.new(2026, 10, 6), "Penny Cafe", 10000, category: dining)
      purchase(Date.new(2026, 10, 7), "Island Flights", 5000, category: travel)
      answer = SpendingPatterns::Answerer.new(household: @household, message: "What spending patterns do you see?", persona: Mia::Persona.neutral, history: [], approved_content: []).call
      refute_match(/spending stops? in /, answer)
      assert_includes answer, "largest flexible spending categories"
      assert_includes answer, "biggest flexible spending stops"
    end
  end

  test "a real category named Discretionary survives method group naming" do
    travel_to Time.zone.local(2026, 11, 5, 12) do
      @category.update!(name: "Discretionary")
      purchase(Date.new(2026, 10, 5), "Ross", 10_000)
      settings = CohortExperience::MethodSettings.for_household(@household).merge("group_names" => "method")
      CohortExperience::MethodSettings.use_viewer(@household.id) { { method: settings } }
      begin
        answer = SpendingPatterns::Answerer.new(household: @household, message: "What spending patterns do you see?",
          persona: Mia::Persona.neutral, history: [], approved_content: []).call
        assert_includes answer, "largest Discretionary category was Discretionary"
      ensure
        CohortExperience::MethodSettings::Current.reset
      end
    end
  end

  test "pattern provider must use the selected phrase in the merchant observation" do
    reference = "In Oct, Ross ($100) was your biggest Discretionary stop. Look at what you bought. Would you feel comfortable looking at Ross?"
    packet = { fallback_response: reference, verified_facts: { group_phrase: "Discretionary", merchants: [ { label: "Ross", total_cents: 10_000 } ], choices: [] } }
    narrator = SpendingPatterns::Narrator.new(user_message: "What spending patterns do you see?", answer_packet: packet, persona: Mia::Persona.neutral)
    assert_includes narrator.send(:narrator_contract), "biggest Discretionary stops"
    assert_nil narrator.send(:patterns_rejection, reference)
    assert_equal :missing_pattern_group_phrase, narrator.send(:patterns_rejection, reference.sub("Discretionary", "flexible spending"))
    assert_equal :missing_pattern_group_phrase, narrator.send(:patterns_rejection, reference.sub("Discretionary stop", "flexible spending stop").sub("Look at what you bought", "Discretionary is your group"))
  end

  test "partial pattern coverage joins the merchant clause grammatically for one or several months" do
    travel_to Time.zone.local(2026, 11, 2, 12) do
      purchase(Date.new(2026, 10, 5), "Ross", 10_000)
      answer = SpendingPatterns::Answerer.new(household: @household, message: "What spending patterns do you see?",
        persona: Mia::Persona.neutral, history: [], approved_content: []).call
      assert_includes answer, "I only see purchases for Oct: Ross ($100) was"
      purchase(Date.new(2026, 8, 5), "Ross", 10_000)
      answer = SpendingPatterns::Answerer.new(household: @household, message: "What spending patterns do you see?",
        persona: Mia::Persona.neutral, history: [], approved_content: []).call
      assert_includes answer, "I only see purchases for Aug and Oct: Ross ($200) was"
    end
  end

  test "a named month answers the total first and preserves a real category named Flexible spending" do
    travel_to Time.zone.local(2026, 11, 2, 12) do
      @category.update!(name: "Flexible spending")
      purchase(Date.new(2026, 9, 5), "Ross", 10_000)
      purchase(Date.new(2026, 9, 9), "Kmart", 5_000)
      answer = SpendingPatterns::Answerer.new(household: @household, message: "what did i spend in september",
        persona: Mia::Persona.neutral, history: [], approved_content: []).call
      assert_match(/\AYour reviewed purchases for this period total \$150/, answer)
      assert_match(/category was Flexible spending/, answer)
    end
  end

  test "both pattern narrator contracts reject a comma splice in partial coverage" do
    [ [ "Oct" ], [ "Aug", "Oct" ] ].each do |months|
      reference = "I only see purchases for #{months.to_sentence}: Ross ($100) was your biggest flexible spend. Look at what you bought. Would you feel comfortable cutting back on Ross?"
      packet = { fallback_response: reference, verified_facts: { months_with_purchases: months, missing_months: true,
        merchants: [ { label: "Ross", total_cents: 10_000 } ], choices: [] } }
      [ SpendingPatterns::Narrator, SavingsChallenge::PatternsNarrator ].each do |klass|
        narrator = klass.new(user_message: "What spending patterns do you see?", answer_packet: packet, persona: Mia::Persona.neutral)
        assert_nil narrator.send(:patterns_rejection, reference)
        assert_equal :pattern_coverage_comma_splice, narrator.send(:patterns_rejection, reference.sub(": Ross", ", Ross"))
        assert_includes narrator.send(:narrator_contract), "never a comma splice"
      end
    end
  end

  test "coaching groups location parenthetical and store number variants with short names" do
    originals = [ "Island Table - Tamuning (includes tip)", "Island Table - Dededo", "Island Table (includes tip) #123" ]
    originals.each { |name| purchase(Date.new(2026, 10, 5), name, 2240) }
    purchase(Date.new(2026, 9, 5), "Island Table - Dededo", 2240)
    purchase(Date.new(2026, 10, 6), "Ross #123", 5525)
    result = analyze
    assert_equal [ [ "Island Table", 8960 ], [ "Ross", 5525 ] ], result[:discretionary_merchants].map { |row| [ row[:label], row[:total_cents] ] }
    # Ross appears in one month only, so it is a one-off and never offered as a monthly cut.
    assert_equal [ "Island Table" ], result[:candidate_changes].map { |row| row[:merchant] }
    assert_equal 2240, result[:candidate_changes].first[:monthly_impact_cents]
    originals.each { |name| assert @household.household_transactions.exists?(merchant: name) }
  end

  test "three full months use exact reviewed amounts and ignore the current month, ignored purchases and other households" do
    [ 8, 9, 10 ].each { |month| purchase(Date.new(2026, month, 5), "POS DEBIT 1234 ROSS STORES #567 XXXX1234", 20_000) }
    purchase(Date.new(2026, 11, 1), "Current month", 999_999)
    purchase(Date.new(2026, 10, 2), "Ignored", 888_888, status: "ignored")
    other_user = User.create!(clerk_id: "patterns-other-#{SecureRandom.hex(8)}", email: "patterns-other-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    other = HouseholdFinance::WorkspaceResolver.new(other_user).household
    other_category = other.budget_categories.create!(name: "Optional shopping", stack_key: "discretionary", sort_order: 1)
    purchase(Date.new(2026, 9, 9), "Other household Ross", 777_777, household: other, category: other_category)
    result = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: Date.new(2026, 8, 1), to: Date.new(2026, 10, 31)).call
    assert_equal({ start_on: "2026-08-01", end_on: "2026-10-31" }, result[:window])
    assert_equal 60_000, result[:observed_spending_cents]
    assert_equal "Ross", result[:discretionary_merchants].sole[:label]
    assert_equal 20_000, result[:discretionary_merchants].sole[:monthly_average_cents]
    assert_equal 10_000, result[:candidate_changes].sole[:monthly_impact_cents]
    assert_empty result[:possible_subscriptions], "Repeated retail visits are not subscriptions"
    assert_equal "partial", result[:coverage][:status]
    assert_equal "unknown", result[:coverage][:account_completeness]
    refute result[:savings_inferred]
  end

  test "missing months and no purchases stay unknown without dividing by missing months" do
    purchase(Date.new(2026, 8, 5), "Ross", 20_000)
    purchase(Date.new(2026, 10, 5), "Ross", 10_000)
    result = analyze
    assert_nil result[:coverage][:months][1][:spending_cents]
    assert_equal 15_000, result[:merchants].sole[:monthly_average_cents]
    assert_empty result[:coverage][:accounts]
    @household.household_transactions.update_all(status: "ignored")
    assert_nil analyze[:observed_spending_cents]
    assert_empty analyze[:candidate_changes]
  end

  test "real bank descriptors retain the Ross 600 and Kmart 360 comparison" do
    [ 8, 9, 10 ].each do |month|
      purchase(Date.new(2026, month, 5), "POS DEBIT 1234 ROSS STORES #567 XXXX1234", 20_000)
      purchase(Date.new(2026, month, 9), "POS DEBIT 1234 KMART #101 XXXX1234", 12_000)
    end
    merchants = analyze[:discretionary_merchants].to_h { |row| [ row[:label], row[:total_cents] ] }
    assert_equal({ "Ross" => 60_000, "Kmart" => 36_000 }, merchants)
  end

  test "a long account number in a merchant never reaches what Mia quotes, while the stored wording stays" do
    stored = purchase(Date.new(2026, 10, 5), "Coast360 payment 00009900", 4500)
    labels = analyze[:merchants].pluck(:label)
    assert_equal [ "Coast360 payment ····9900" ], labels
    assert_equal "Coast360 payment 00009900", stored.reload.merchant
  end

  test "grouping normalizes locations without rewriting participant merchant wording or numeric names" do
    [ "Ross Dress for Less", "ROSS DRESS FOR LESS #123 DEDEDO GU", "ROSS STORES #456 HAGATNA GU", "ROSS DRESS FOR LESS #123 HONOLULU HI" ].each do |merchant|
      purchase(Date.new(2026, 10, 5), merchant, 1000)
    end
    coffee = purchase(Date.new(2026, 10, 6), "CARD PURCHASE 1776 COFFEE", 500)
    merchants = analyze[:merchants].to_h { |row| [ row[:label], row[:total_cents] ] }
    assert_equal({ "Ross" => 4000, "1776 COFFEE" => 500 }, merchants)
    assert_equal "CARD PURCHASE 1776 COFFEE", coffee.reload.merchant
    assert @household.household_transactions.exists?(merchant: "Ross Dress for Less")
  end

  test "a selected window loads only the transactions it analyzes" do
    purchase(Date.new(2025, 1, 5), "Old purchase", 90_000)
    purchase(Date.new(2026, 10, 5), "Ross", 20_000)
    purchase(Date.new(2026, 11, 1), "Current month", 80_000)
    loaded = 0
    observer = lambda do |*args|
      payload = args.last
      loaded += payload[:record_count] if payload[:class_name] == "HouseholdTransaction"
    end
    result = ActiveSupport::Notifications.subscribed(observer, "instantiation.active_record") do
      SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: "2026-10-01", to: "2026-10-31").call
    end
    assert_equal 1, loaded
    assert_equal 20_000, result[:observed_spending_cents]
    assert_equal "Ross", result[:merchants].sole[:label]
  end

  test "small purchases reveal weekday and end-of-month clusters without guessing motivation" do
    [ Date.new(2026, 10, 23), Date.new(2026, 10, 24), Date.new(2026, 10, 30) ].each { |date| purchase(date, "Kopi", 650) }
    result = analyze
    cluster = result[:small_purchase_clusters].find { |row| row[:label] == "Friday through Sunday" }
    assert_equal 3, cluster[:purchase_count]
    assert_equal 1950, cluster[:total_cents]
    assert result[:small_purchase_clusters].any? { |row| row[:label] == "the end of the month" }
  end

  test "repeated same-date same-amount purchases are possible subscriptions, never confirmed subscriptions" do
    [ 8, 9, 10 ].each { |month| purchase(Date.new(2026, month, 8), "Stream service", 1599) }
    result = analyze
    assert_equal({ merchant: "Stream service", typical_amount_cents: 1599, latest_amount_cents: 1599, last_charged_on: "2026-10-08", observed_payments: 3, confirmed_subscription: false }, result[:possible_subscriptions].sole)
    assert_raises(ArgumentError) { SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: "2026-11-01", to: "2026-12-01").call }
  end

  test "essential categories and merchant names alone never become discretionary cuts" do
    @category.update!(stack_key: "non_discretionary")
    purchase(Date.new(2026, 10, 8), "Ross", 20_000)
    assert_equal 20_000, analyze[:observed_spending_cents]
    assert_empty analyze[:discretionary_merchants]
    assert_empty analyze[:candidate_changes]
  end

  test "reviewed statement heads count once beside their projection and retained old financial pictures are excluded" do
    @savings_household, @savings_user = @household, @user
    source, _import = evidence_source(2_000, type: "income", on: Date.new(2026, 10, 5))
    identity = source.source_account_identity_version
    draft = source_operation(HouseholdFinance::Operations::SourceReview::DraftStage,
      event_id: source.financial_source_event.id, base_version_id: source.id, base_lock_version: source.source_review_head.reload.lock_version,
      reason: "Reviewed synthetic category and expense", projection: { action: "create" }, facts: {
        source_account_identity_version_id: identity.id, disposition: "include", event_type: "purchase", signed_amount_cents: -2_000,
        purchase_amount_cents: 2_000, posted_on: "2026-10-05", merchant: "Kmart", budget_category_id: @category.id,
        overlap_disposition: "distinct", matched_version_id: nil })
    source_operation(HouseholdFinance::Operations::SourceReview::DraftApprove, draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest)
    assert_equal 1, @household.household_transactions.count
    result = analyze
    assert_equal 2_000, result[:observed_spending_cents]
    assert_equal 1, result[:purchase_count]
    assert_equal [ "Synthetic reserve account" ], result[:coverage][:accounts]
    @household.update!(financial_generation: 1)
    FinancialPicture.set(household_id: @household.id, generation: 1) do
      assert_nil analyze[:observed_spending_cents]
      assert_empty analyze[:coverage][:accounts]
    end
  end

  test "subscription wording needs near-identical amounts and a regular monthly cadence" do
    [ 8, 9, 10 ].each { |month| purchase(Date.new(2026, month, 8), "Island Gym", 5000) }
    assert_equal "Island Gym", analyze[:possible_subscriptions].sole[:merchant]
    @household.household_transactions.find_by(occurred_on: Date.new(2026, 9, 8)).update!(total_amount_cents: 5400)
    assert_empty analyze[:possible_subscriptions]
    @household.household_transactions.find_by(occurred_on: Date.new(2026, 9, 8)).update!(total_amount_cents: 5000, occurred_on: Date.new(2026, 9, 22))
    assert_empty analyze[:possible_subscriptions]
  end

  test "same day-of-month in nonconsecutive months is not a monthly subscription" do
    [ 6, 8, 10 ].each { |month| purchase(Date.new(2026, month, 8), "Software subscription", 1599) }
    result = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: "2026-06-01").call
    assert_empty result[:possible_subscriptions]
  end

  test "known services and the bank's recurring marker read as subscriptions through a price rise or a missed statement" do
    purchase(Date.new(2026, 8, 23), "Recurring Payment authorized on 08/23 Disney Plus 888-····4242 CA S*····8141 Card 7302", 1899)
    purchase(Date.new(2026, 9, 23), "Recurring Payment authorized on 09/23 Disney Plus 888-····4242 CA S*····8141 Card 7302", 2149)
    purchase(Date.new(2026, 10, 23), "Recurring Payment authorized on 10/23 Disney Plus 888-····4242 CA S*····8141 Card 7302", 2149)
    # The bank marks it recurring, so one missed statement (July) still reads as monthly.
    [ 5, 6, 8 ].each { |month| purchase(Date.new(2026, month, 8), "Recurring Payment authorized on #{month.to_s.rjust(2, '0')}/08 Google Youtubeprem 650-····1111 CA S*····7788 Card 7302", 1399) }
    [ 8, 9, 10 ].each { |month| purchase(Date.new(2026, month, 5), "ROSS STORES #567", 20_000) }
    found = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: "2026-05-01").call[:possible_subscriptions]
    assert_equal [ "Disney Plus", "Google Youtubeprem" ], found.pluck(:merchant)
    assert_equal [ 2149, 1399 ], found.pluck(:latest_amount_cents)
    refute_includes found.pluck(:merchant), "Ross", "Repeated retail visits are not subscriptions"
  end

  test "two purchases two months apart, or a charge every two months, is not a monthly subscription" do
    purchase(Date.new(2026, 8, 10), "NINTENDO *AMERICA", 5999)
    purchase(Date.new(2026, 10, 12), "NINTENDO *AMERICA", 5999)
    purchase(Date.new(2026, 6, 19), "Recurring Payment authorized on 06/19 GTA Teleguam", 37_468)
    purchase(Date.new(2026, 8, 19), "Recurring Payment authorized on 08/19 GTA Teleguam", 37_468)
    purchase(Date.new(2026, 10, 19), "Recurring Payment authorized on 10/19 GTA Teleguam", 37_468)
    result = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2), from: "2026-06-01").call
    assert_empty result[:possible_subscriptions]
  end

  test "a marked service seen once, or at a changing price, is not a monthly subscription" do
    purchase(Date.new(2026, 10, 19), "Recurring Payment authorized on 10/19 Starlink Internet", 8500)
    assert_empty analyze[:possible_subscriptions]
    purchase(Date.new(2026, 9, 19), "Recurring Payment authorized on 09/19 Starlink Internet", 4000)
    assert_empty analyze[:possible_subscriptions]
  end

  private
  def analyze = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 2)).call
  def purchase(date, merchant, cents, status: "confirmed", household: @household, category: @category)
    year = household.budget_years.find_or_create_by!(year: date.year)
    period = year.budget_periods.find_or_create_by!(starts_on: date.beginning_of_month) { |row| row.ends_on = date.end_of_month }
    row = household.household_transactions.create!(budget_period: period, occurred_on: date, merchant: merchant, total_amount_cents: cents, source_type: "statement", status: status)
    row.transaction_splits.create!(budget_category: category, amount_cents: cents)
    row
  end
end
