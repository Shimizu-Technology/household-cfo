require "test_helper"

# Regressions from the October 2026 Mia chat QA pass (findings F5, F6, F8, F9,
# F10, F11). Provider responses are stubbed with the shapes the QA transcripts
# imply; Rails stays the authority on what becomes a review card.
class HouseholdFinanceMiaIntentResolverQaChatTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  QA_SETUP_PARAGRAPH = "ok so me and my husband we make like 4800 a month together after taxes, rent is 1650 power and water like 280 car note 390, groceries and gas and stuff maybe 900, we wanna save up for emergencies cuz last year the car broke down and we had to borrow from my mom".freeze

  # F6
  test "call us with a trailing goal clause names the household without swallowing the sentence" do
    provider_called = false
    result = resolve("call us the cruz ohana lol and our main goal is to build an emergency fund of like 3 months",
      transport: ->(_) { provider_called = true; nil })

    refute provider_called
    assert result.actionable?, result.to_h.inspect
    assert_equal "The Cruz Ohana", result.action.dig(:setup_updates, :household_name)
    assert_equal "Build an emergency fund of like 3 months", result.action.dig(:setup_updates, :primary_goal)
  end

  test "household name stops at clause starts and filler but keeps ordinary names whole" do
    {
      "Call us the Santos Family and our goal is to pay off the card" => "the Santos Family",
      "call us Will and Grace" => "Will and Grace",
      "Our household is called Taitano House haha" => "Taitano House",
      "call us cruz ohana!!" => "Cruz Ohana",
      "Call my household Leon & Kids. Our goal is to build savings." => "Leon & Kids",
      "call us The Rent Family" => "The Rent Family"
    }.each do |message, expected|
      result = resolve(message)
      assert result&.actionable?, "#{message}: #{result.to_h.inspect}"
      assert_equal expected, result.action.dig(:setup_updates, :household_name), message
    end
  end

  test "a run-on name clause never becomes a whole-sentence household name" do
    result = resolve("call us the cruz ohana we make like 4800 a month and rent is 1650")
    refute result&.action.to_h.dig(:setup_updates, :household_name).to_s.include?("4800")

    long = resolve("call us the family of the people who live in the yellow house near the beach")
    assert long.clarification?
    refute long.actionable?
    assert_includes long.clarification, "Send only the name"
  end

  test "a provider household name that is really a sentence is set aside and only the name is asked for" do
    sentence = "the cruz ohana lol and our main goal is to build an emergency fund of like 3 months"
    result = resolve("ok so call us the cruz ohana lol, we wanna build an emergency fund", transport: provider(
      intent: "household_action",
      action: action(type: "update_household_setup", setup_updates: setup(household_name: sentence, primary_goal: "Build an emergency fund"))
    ))

    refute result.actionable?
    assert result.clarification?
    assert_equal "update_household_setup", result.action.fetch(:type)
    refute result.action.fetch(:setup_updates).key?(:household_name)
    assert_equal "Build an emergency fund", result.action.dig(:setup_updates, :primary_goal)
    assert_includes result.clarification, "What household name should I use?"

    clean = resolve("ok so call us the cruz ohana lol, we wanna build an emergency fund", transport: provider(
      intent: "household_action",
      action: action(type: "update_household_setup", setup_updates: setup(household_name: "Cruz Ohana", primary_goal: "Build an emergency fund"))
    ))
    assert clean.actionable?
    assert_equal "Cruz Ohana", clean.action.dig(:setup_updates, :household_name)
  end

  test "guided name replies drop chat filler" do
    result = resolve("the cruz ohana lol", context: setup_zero_context("household_name"))
    assert result.actionable?
    assert_equal({ household_name: "The Cruz Ohana" }, result.action.fetch(:setup_updates))
    assert_nil resolve("lol", context: setup_zero_context("household_name"))
  end

  # F5
  test "a provider total that is a sum of written amounts is never accepted, and the written numbers are listed" do
    result = resolve(QA_SETUP_PARAGRAPH, transport: provider(
      intent: "household_action",
      action: action(type: "update_household_setup", setup_updates: setup(
        primary_income: "4800", fixed_expenses: "2320", flexible_spend: "900", primary_goal: "Save up for emergencies"
      ))
    ))

    refute result.actionable?, result.to_h.inspect
    assert result.clarification?
    assert_equal "4800", result.action.dig(:setup_updates, :primary_income)
    assert_equal "900", result.action.dig(:setup_updates, :flexible_spend)
    assert_nil result.action.dig(:setup_updates, :fixed_expenses)
    assert_includes result.clarification, "$1,650"
    assert_includes result.clarification, "$280"
    assert_includes result.clarification, "$390"
    assert_includes result.clarification, "monthly total"
  end

  test "no subset sum of written numbers passes as a setup total" do
    # rent+power+car, car+power, income+rent, savings-like subsets, swapped fixed/flexible
    { fixed_expenses: %w[2320 670 6450 2050], flexible_spend: %w[2320 1930] }.each do |field, values|
      values.each do |value|
        result = resolve(QA_SETUP_PARAGRAPH, transport: provider(
          intent: "household_action",
          action: action(type: "update_household_setup", setup_updates: setup(field => value))
        ))
        refute result.actionable?, "#{field} #{value}: #{result.to_h.inspect}"
      end
    end
  end

  test "an untraceable setup total keeps verified fields and asks only about that field" do
    result = resolve(QA_SETUP_PARAGRAPH, transport: provider(
      intent: "household_action",
      action: action(type: "update_household_setup", setup_updates: setup(
        primary_income: "4800", fixed_expenses: "2400", flexible_spend: "900"
      ))
    ))

    refute result.actionable?
    assert result.clarification?
    assert_equal "update_household_setup", result.action.fetch(:type)
    assert_equal({ primary_income: "4800", flexible_spend: "900" }, result.action.fetch(:setup_updates))
    assert_includes result.clarification, "fixed essentials"
    refute_includes result.clarification, "Please restate the amount"
    refute_includes result.clarification, "primary monthly income to a number"
  end

  test "the follow-up answer completes the same setup card" do
    context = intent_context.deep_merge(conversation: {
      active_thread: {
        schema_version: 2, type: "household_setup", title: "Starting household picture", subject: "Household setup",
        status: "needs_clarification",
        action: action(type: "update_household_setup", setup_updates: { primary_income: "4800", flexible_spend: "900" })
      },
      recent_messages: [ { role: "user", content: QA_SETUP_PARAGRAPH } ]
    })
    result = resolve("fixed essentials are 2320", context: context)

    assert result.actionable?, result.to_h.inspect
    assert_equal({ primary_income: "4800", flexible_spend: "900", fixed_expenses: "2320" }, result.action.fetch(:setup_updates).slice(:primary_income, :flexible_spend, :fixed_expenses))
  end

  test "sums are only accepted for expense totals and must use the participant's own amounts" do
    income = resolve(QA_SETUP_PARAGRAPH, transport: provider(
      intent: "household_action",
      action: action(type: "update_household_setup", setup_updates: setup(primary_income: "2320"))
    ))
    refute income.actionable?
    assert_equal "none", income.action.fetch(:type)

    history_only = resolve("fixed essentials are the bills I listed", context: intent_context.deep_merge(conversation: {
      recent_messages: [ { role: "user", content: "rent is 1650 power 280 car note 390" } ]
    }), transport: provider(
      intent: "household_action",
      action: action(type: "update_household_setup", setup_updates: setup(fixed_expenses: "2320"))
    ))
    refute history_only.actionable?
  end

  # F8
  test "saying there is no debt drafts a reviewed zero debt summary instead of asking again" do
    provider_called = false
    result = resolve("we dont have any debt, no credit cards nothing", context: debt_context,
      transport: ->(_) { provider_called = true; nil })

    refute provider_called
    assert result.actionable?, result.to_h.inspect
    assert_equal "debt_action", result.intent
    assert_equal({ type: "update_debt_tracking", debt_tracking_mode: "summary", amount: "0", minimum_payment: "0" },
      result.action.slice(:type, :debt_tracking_mode, :amount, :minimum_payment))
  end

  test "zero pair and affirmation replies to Mia's debt question complete the summary" do
    asked = debt_context(recent: [
      { role: "user", content: "we dont have any debt, no credit cards nothing. the car note is in the fixed essentials already" },
      { role: "assistant", content: "Got it. Do you want me to save a confirmed no-debt summary, meaning $0 debt balance and $0 monthly minimums, for the household?" }
    ])
    [ "yes", "yes please", "0 and 0", "$0 and $0", "both zero" ].each do |reply|
      result = resolve(reply, context: asked)
      assert result&.actionable?, "#{reply}: #{result.to_h.inspect}"
      assert_equal "0", result.action.fetch(:minimum_payment)
    end

    question = debt_context(recent: [
      { role: "user", content: "yes" },
      { role: "assistant", content: "What are the approved total balance and total monthly minimum? Say unknown for either one you have not confirmed." }
    ])
    assert resolve("0 and 0", context: question).actionable?
    assert_nil resolve("yes", context: question), "a bare yes is not a $0 answer without a no-debt statement"
  end

  test "no-debt shortcuts stay out of real debt and hypotheticals" do
    [
      "we dont have any debt except the car loan",
      "we don't have any debt but we owe $200 to my mom",
      "do we have any debt?",
      "what if we had no debt, could we save more",
      "we dont have any debt, how much can we save each month"
    ].each do |message|
      assert_nil resolve(message, context: debt_context), message
    end
    assert_nil resolve("we dont have any debt", context: debt_context(active_debts: [ { id: 4, label: "Visa", debt_type: "credit_card" } ]))
    assert_nil resolve("we dont have any debt", context: debt_context(minimum_known: true))
    assert_nil resolve("0 and 0", context: debt_context), "zero pair without a pending debt question"
  end

  test "no-debt shortcut needs a clean whole-message present-tense statement" do
    [
      "I don't have any debt, my husband owes 3000 on his truck",
      "we don't have any debt just the credit card",
      "we don't have any debt right now, just the car",
      "we were debt free before covid",
      "we dont have any debt but the card is 500"
    ].each do |message|
      assert_nil resolve(message, context: debt_context), message
    end
    [ "no debt", "we're debt free", "we don't owe anything", "we dont have any debt right now", "I don't have any debt" ].each do |message|
      assert resolve(message, context: debt_context)&.actionable?, message
    end
  end

  test "bare zero and yes need Mia's immediately previous question to match" do
    both = debt_context(recent: [ { role: "assistant", content: "What are the approved total balance and total monthly minimum? Say unknown for either one you have not confirmed." } ])
    assert_nil resolve("0", context: both), "a bare 0 answers only one of two questions"
    assert_nil resolve("yes", context: both)
    offer_only = debt_context(recent: [ { role: "user", content: "we don't have any debt" },
      { role: "assistant", content: "Do you want me to save a confirmed no-debt summary, meaning $0 debt balance and $0 monthly minimums?" } ])
    assert resolve("yes", context: offer_only)&.actionable?
    two_part = debt_context(recent: [ { role: "user", content: "we don't have any debt" },
      { role: "assistant", content: "I can save a no-debt summary with $0 debt balance and $0 monthly minimums. What are the approved total balance and total monthly minimum?" } ])
    assert_nil resolve("yes", context: two_part)
    assert_nil resolve("0 and 0", context: debt_context(recent: [ { role: "assistant", content: "How is the budget looking?" } ]))
    compound = debt_context(recent: [ { role: "user", content: "we don't have any debt" },
      { role: "assistant", content: "Do you want me to save a confirmed no-debt summary? Also do you want to add your checking account?" } ])
    assert_nil resolve("yes", context: compound)
    two_questions = debt_context(recent: [ { role: "user", content: "we don't have any debt" },
      { role: "assistant", content: "Do you want me to save a confirmed no-debt summary, meaning $0 debt balance and $0 monthly minimums? Is checking your main account?" } ])
    assert_nil resolve("yes", context: two_questions)
  end

  # F9
  test "multiple purchases must keep each merchant in its own span" do
    travel_to Date.new(2026, 10, 16) do
      message = "$12 at Payless and $30 at Shell"
      swapped = resolve(message, transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("$12 at Payless", "Shell", "12"), expense("$30 at Shell", "Payless", "30") ]
      }))
      refute swapped.transaction_report_plan?
      good = resolve(message, transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("$12 at Payless", "Payless", "12"), expense("$30 at Shell", "Shell", "30") ]
      }))
      assert good.transaction_report_plan?, good.to_h.inspect
    end
  end

  test "savings moves and money received never become expense drafts beside a purchase" do
    travel_to Date.new(2026, 10, 16) do
      message = "moved 200 to my savings and paid 30 at KFC"
      plan = resolve(message, transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("moved 200 to my savings", "Savings", "200"), expense("paid 30 at KFC", "KFC", "30") ]
      }))
      refute plan.transaction_report_plan?
      kfc = resolve(message, transport: provider(intent: "transaction_report", action: action(type: "create_transaction_draft", merchant: "KFC", amount: "30", occurred_on: "2026-10-16")))
      assert kfc.actionable?, kfc.to_h.inspect
      assert_equal "30", kfc.action.fetch(:amount)
      wrong = resolve(message, transport: provider(intent: "transaction_report", action: action(type: "create_transaction_draft", merchant: "KFC", amount: "200", occurred_on: "2026-10-16")))
      refute wrong.actionable?

      refund = resolve("got $40 back from Ross", transport: provider(intent: "transaction_report", action: action(type: "create_transaction_draft", merchant: "Ross", amount: "40", occurred_on: "2026-10-16")))
      refute refund.actionable?
      assert HouseholdFinance::TransactionDraftBuilder.non_expense_movement?("got $40 back from Ross")
      mixed = resolve("spent $12 at Payless and got $40 back from Ross", transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("spent $12 at Payless", "Payless", "12"), expense("got $40 back from Ross", "Ross", "40") ]
      }))
      refute mixed.transaction_report_plan?
    end
  end

  test "one purchase split into parts is not several purchases" do
    travel_to Date.new(2026, 10, 16) do
      message = "spent $50 at Costco, $30 was groceries and $20 was diapers"
      result = resolve(message, transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("$30 was groceries", "Costco", "30"), expense("$20 was diapers", "Costco", "20") ]
      }))
      refute result.transaction_report_plan?
      with_total = resolve(message, transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("spent $50 at Costco", "Costco", "50"), expense("$30 was groceries", "Costco", "30") ]
      }))
      refute with_total.transaction_report_plan?
    end
  end

  # F6
  test "guided name replies keep real names and never save a sentence" do
    {
      "Ty and Leilani" => "Ty and Leilani",
      "Mama and my babies" => "Mama and My Babies",
      "Santos and Cruz family" => "Santos and Cruz family",
      "Ohana Lee" => "Ohana Lee",
      "The Lujans" => "The Lujans",
      "we are the cruz family" => "The Cruz Family",
      "its gonna be the cruz family i guess" => "The Cruz Family"
    }.each do |reply, expected|
      result = resolve(reply, context: setup_zero_context("household_name"))
      assert result&.actionable?, "#{reply}: #{result.to_h.inspect}"
      name = result.action.dig(:setup_updates, :household_name)
      assert_equal expected.downcase, name.downcase, reply
    end
  end

  # F10
  test "moving a pending draft to another category does not require restating its amount" do
    context = intent_context.merge(pending_transaction_reviews: [
      { id: 12, merchant: "McDonald's", occurred_on: "2026-07-10", amount: 27.0, category_id: 43, category_name: "Rent",
        splits: [ { id: 120, category_id: 43, category_name: "Rent", amount: 27.0 } ] }
    ])
    edit = action(type: "update_transaction_draft", draft_id: 12, category_id: 42, category_name: "Fixed essentials")
    [ edit.merge(amount: "27"), edit.merge(splits: [ { id: 120, category_id: 42, category_name: "Fixed essentials", amount: "27" } ]), edit ].each do |candidate|
      result = resolve("put the mcdonalds one under fixed essentials", context: context,
        transport: provider(intent: "transaction_draft_action", action: candidate))
      assert result.actionable?, result.to_h.inspect
      assert_equal 42, result.action.fetch(:category_id)
    end

    changed = resolve("put the mcdonalds one under fixed essentials", context: context,
      transport: provider(intent: "transaction_draft_action", action: edit.merge(amount: "30")))
    refute changed.actionable?
    assert_includes changed.clarification, "participant-authored amount"
  end

  # F11
  test "family lending questions are not turned into purchase scenarios" do
    message = "my sister wants to borrow $300 for her kids school stuff, can we afford that?"
    outage = ->(_) { nil }
    offline = resolve(message, transport: outage)
    refute offline&.read_only_plan?
    model = resolve(message, transport: provider(intent: "coaching", action: action(type: "none")))
    refute model.read_only_plan?
    assert_equal "coaching", model.intent

    purchase = resolve("can we afford a $300 stroller", transport: outage)
    assert purchase.read_only_plan?
    assert_equal "Stroller", purchase.read_only_plan.dig(:items, 0, :scenario_label)
    function_word = resolve("can we afford $300 for school shoes", transport: outage)
    assert function_word.read_only_plan?
    assert_equal "", function_word.read_only_plan.dig(:items, 0, :scenario_label)
  end

  # F9
  test "several reported expenses in one message become one validated review each" do
    travel_to Date.new(2026, 10, 16) do
      message = "yesterday i got gas at shell for 45 and then kfc 18.50 for the kids and 32 at ace hardware"
      result = resolve(message, transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Reported expenses",
        actions: [
          expense("gas at shell for 45", "Shell", "45"),
          expense("kfc 18.50", "KFC", "18.50"),
          expense("32 at ace hardware", "Ace Hardware", "32")
        ]
      }))

      assert result.actionable?, result.to_h.inspect
      assert result.transaction_report_plan?
      assert_equal %w[Shell KFC Ace\ Hardware], result.write_plan.fetch(:actions).map { |entry| entry.dig(:action, :merchant) }
      assert_equal %w[45 18.50 32], result.write_plan.fetch(:actions).map { |entry| entry.dig(:action, :amount) }
    end
  end

  test "multi-expense plans reject amounts outside each expense's own words, future dates and mixed writes" do
    travel_to Date.new(2026, 10, 16) do
      message = "spent 45 at shell yesterday, 18.50 at kfc, and 32 at ace hardware"
      swapped = resolve(message, transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("45 at shell yesterday", "Shell", "32"), expense("18.50 at kfc", "KFC", "18.50") ]
      }))
      refute swapped.actionable?
      refute swapped.transaction_report_plan?

      future = resolve(message, transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("45 at shell yesterday", "Shell", "45", on: "2026-10-20"), expense("18.50 at kfc", "KFC", "18.50") ]
      }))
      refute future.actionable?

      deposit = resolve("put 150 into savings and spent 18.50 at kfc", transport: provider(intent: "action_plan", action: action(type: "none"), write_plan: {
        title: "Expenses", actions: [ expense("put 150 into savings", "Savings", "150"), expense("18.50 at kfc", "KFC", "18.50") ]
      }))
      refute deposit.actionable?
    end
  end

  private

  def resolve(message, context: intent_context, transport: nil, api_key: :default)
    key = api_key == :default ? (transport ? "test-key" : nil) : api_key
    HouseholdFinance::MiaIntentResolver.new(user_message: message, context: context, api_key: key, transport: transport).call
  end

  def provider(intent:, action:, write_plan: { title: "", actions: [] }, continuation: false)
    lambda do |_payload|
      {
        intent: intent, confidence: 0.97, continuation: continuation, resolved_message: "resolved",
        needs_clarification: false, clarification: "",
        topic: { type: intent, title: "QA", subject: "QA" },
        read_only_plan: { title: "", items: [] }, write_plan: write_plan, action: action
      }.to_json
    end
  end

  def expense(source, merchant, amount, on: "2026-10-15")
    { source_text: source, depends_on: [], action: action(type: "create_transaction_draft", merchant: merchant, amount: amount, occurred_on: on) }
  end

  def action(**overrides)
    {
      type: "none", category_id: 0, category_name: "", target_category_id: 0, target_category_name: "", new_name: "",
      stack_key: "", amount: "", months: [], year: 0, draft_id: 0, selected_item_ids: [], occurred_on: "", merchant: "",
      all_pending: false, splits: [], setup_updates: setup, income_source_id: 0, income_source_name: "",
      income_schedule_entry_id: 0, source_type: "", cadence: "", retained_after_transition: false, entry_type: "",
      effective_on: "", schedule_label: "", debt_id: 0, debt_name: "", debt_type: "", minimum_payment: "",
      interest_rate_percent: "", debt_tracking_mode: "", account_id: 0, account_name: "", account_type: "",
      balance_as_of_on: "", plaid_account_id: 0, reconcile_decision: ""
    }.merge(overrides)
  end

  def setup(**values)
    %i[household_name primary_goal primary_income business_income fixed_expenses flexible_spend expected_sinking_fund
      unexpected_sinking_fund emergency_fund other_assets target_runway_months].index_with { "" }.merge(values)
  end

  def debt_context(recent: [], active_debts: [], minimum_known: false)
    intent_context.merge(
      active_debts: active_debts,
      debt_tracking: { mode: "individual", minimum_payment_known: minimum_known, active_count: active_debts.length },
      conversation: { active_thread: {}, recent_messages: recent }
    )
  end

  def setup_zero_context(field)
    intent_context.deep_merge(
      setup_status: { complete: false, missing_fields: [ { key: field, label: HouseholdFinance::SetupStatus::FIELD_LABELS.fetch(field.to_sym) } ] },
      conversation: {
        active_thread: { schema_version: 2, type: "household_setup", title: "Starting household picture", status: "applied" },
        recent_messages: [ { role: "assistant", content: "Applied the reviewed household update. #{HouseholdFinance::MiaSetupGuide.question_message(field)}" } ]
      }
    )
  end

  def intent_context
    {
      calendar: { today: Date.current.iso8601 },
      budget_view_period: { year: 2026, month: 7, label: "Jul 2026" },
      conversation: { active_thread: {}, recent_messages: [] },
      budget_categories: [
        { id: 42, name: "Fixed essentials", stack_key: "non_discretionary" },
        { id: 43, name: "Rent", stack_key: "non_discretionary" }
      ],
      archived_categories: [],
      pending_budget_reviews: [],
      pending_transaction_reviews: [],
      approved_household_setup: setup,
      income_sources: []
    }
  end
end
