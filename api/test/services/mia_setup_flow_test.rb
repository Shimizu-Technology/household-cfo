require "test_helper"

class MiaSetupFlowTest < ActiveSupport::TestCase
  test "casual minimum list updates both known debts without assuming balances" do
    result = resolve("just the visa, min is 60 and the car is 285", active_debts: [ { id: 7, label: "Visa" }, { id: 8, label: "Car loan" } ])
    assert_equal "action_plan", result.intent
    actions = result.write_plan[:actions].map { |entry| entry[:action] }
    assert_equal [ 7, 8 ], actions.pluck(:debt_id)
    assert_equal %w[60 285], actions.pluck(:minimum_payment)
    assert actions.all? { |action| !action.key?(:amount) }
    assert result.write_plan[:actions].all? { |entry| result.resolved_message.include?(entry[:source_text]) }
  end

  test "not knowing a goal gets a way forward" do
    result = resolve("idk what my goal should be", field: "primary_goal", data: { defer_setup: true })
    assert result.clarification?
    assert_match(/unknown for now|paused/, result.clarification)
    refute_includes result.clarification, "haven't used"
  end

  test "a payment without an amount gets a plain amount question" do
    result = resolve("its a car loan payment", data: {
      facts: [ { kind: "bill", item: "car loan payment", amount: "", merchant: "", day: "" } ] })
    refute result.actionable?
    assert_includes result.clarification, "How much is that bill or payment each month?"
    refute_match(/approved|participant-authored|verify/, result.clarification)
  end

  test "a bill volunteered at the goal question is acknowledged" do
    result = resolve("my rent is 1500 a month btw", field: "primary_goal", data: {
      facts: [ { kind: "bill", amount: "1500", item: "rent", merchant: "", day: "" } ] })
    assert result.clarification?
    assert_includes result.clarification, "Thanks for telling me"
    assert_empty result.action[:setup_updates].to_h
  end

  test "unsafe single amount quotes still ask instead of making a monthly card" do
    [ [ "rent half of 1200", "1200" ], [ "power 20% of that", "20" ], [ "rent due nov 20", "20" ],
      [ "not the 300 storage", "300" ], [ "rent 100 a week", "100" ], [ "power was 300 last month", "300" ] ].each do |message, amount|
      result = resolve(message, field: "fixed_expenses", data: { setup_answer: { field: "fixed", value: amount } })
      refute result.actionable?, message
      assert result.clarification?, message
    end
  end

  test "an outage raise is income rather than an incomplete purchase" do
    result = HouseholdFinance::MiaIntentResolver.new(user_message: "got a raise im at 5600 now", api_key: "", context: {
      setup_status: { complete: true, missing_fields: [] }, conversation: {},
      income_sources: [ { id: 1, label: "Job", source_type: "job", active: true } ] }).call
    refute result.actionable?
    assert_includes result.clarification, "monthly take-home"
    refute_includes result.clarification, "purchase"
  end

  def resolve(text, field: "debt_payment", data: {}, complete: false, active_debts: [])
    payload = { care: "none", facts: [], question: false, correction: false, setup_answer: { field: "none", value: "" }, spending_preferences: [] }.merge(data)
    parsed = HouseholdFinance::ParticipantMessageReader.new(message: text, setup_field: field).send(:validate, payload.deep_stringify_keys)
    HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: parsed, setup_status: { complete: complete, missing_fields: HouseholdFinance::MiaSetupGuide::NEXT_QUESTIONS.keys.drop(HouseholdFinance::MiaSetupGuide::NEXT_QUESTIONS.keys.index(field)).map { |key| { key: key } } },
      active_debts: active_debts, debt_tracking: { mode: "individual" },
      conversation: { recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message(field) } ], active_thread: {} }
    }).call
  end

  test "a reader scalar cannot bypass a ranged saved correction" do
    result = resolve("actually fixed essentials is 1200-1300", field: "fixed_expenses", data: { correction: true, setup_answer: { field: "fixed", value: "1200" } })
    refute result.actionable?, result.to_h.inspect
    assert result.clarification?
  end

  test "a skip escapes a which-debt question" do
    text = "skip"
    parsed = HouseholdFinance::ParticipantMessageReader.call(message: text, transport: ->(_) { { care: "none", facts: [], question: false, defer_setup: true }.to_json })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: text, api_key: "", context: {
      participant_reading: parsed, setup_status: { complete: false, missing_fields: [ { key: "debt_payment" } ] }, active_debts: [ { id: 7, label: "BOQ Visa" }, { id: 8, label: "Chase Visa" } ],
      conversation: { active_thread: { status: "needs_clarification", type: "household_setup", action: { type: "update_debt", debt_id: 0, debt_name: "visa", minimum_payment: "45" } }, recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("debt_payment") } ] }
    }).call
    refute_match(/Which debt/, result&.clarification.to_s)
    assert_match(/paused|unknown/, result.clarification)
  end

  test "distinctive debt tokens preserve word boundaries and casual minimums" do
    debts = [ { id: 7, label: "BOQ Visa" }, { id: 8, label: "Credit Card" }, { id: 9, label: "Car Loan" }, { id: 10, label: "Advisa Loan" } ]
    [ [ "the visa card min is 45", 7, "45" ], [ "my visa min is like 35", 7, "35" ], [ "car min 90", 9, "90" ],
      [ "we dont owe nobody but boq and thats 55 a month", 7, "55" ] ].each do |text, id, minimum|
      result = resolve(text, active_debts: debts)
      assert_equal "update_debt", result&.action&.dig(:type), text
      assert_equal id, result.action[:debt_id], text
      assert_equal minimum, result.action[:minimum_payment], text
    end
  end

  test "stated no debt at flexible does not become a flexible zero" do
    result = resolve("we dont have any debts", field: "flexible_spend", data: { setup_answer: { field: "flexible", value: "0" } })
    assert result.actionable?, result.to_h.inspect
    assert_equal "update_debt_tracking", result.action[:type]
    assert_equal "0", result.action[:minimum_payment]
    assert_empty result.action[:setup_updates].to_h
  end

  test "a known named debt uses the reader fact even with different minimum punctuation" do
    result = resolve("visa min=60", active_debts: [ { id: 7, label: "Visa", debt_type: "other" } ],
      data: { setup_answer: { field: "debt", value: "60" }, facts: [ { kind: "bill", amount: "60", item: "visa", merchant: "", day: "" } ] })
    assert result.actionable?, result.to_h.inspect
    assert_equal "update_debt", result.action[:type]
    assert_equal 7, result.action[:debt_id]
    refute result.action.key?(:debt_type)
  end

  test "asking to total actual quoted paychecks produces review instead of another monthly question" do
    text = "we get 2 paychecks of 1400, can you add that for our monthly income"
    result = resolve(text, field: "primary_income", data: { question: true, facts: [ { kind: "income", amount: "1400", item: "paychecks", merchant: "", day: "" } ],
      setup_details: { field: "primary_income", cadence: "monthly_count", count: "2", partial: false, components: [ { source: "2 paychecks of 1400", amount: "1400" } ] } })
    assert result.clarification?, result.to_h.inspect
    assert_includes result.clarification, "total"
  end

  test "a named minimum updates its existing individual debt instead of asking for a household total" do
    result = resolve("just the visa, min is 60", active_debts: [ { id: 7, label: "Visa", minimum_payment_known: false } ],
      data: { setup_answer: { field: "debt", value: "60" } })
    assert result.actionable?, result.to_h.inspect
    assert_equal "update_debt", result.action[:type]
    assert_equal 7, result.action[:debt_id]
    assert_equal "60", result.action[:minimum_payment]
    refute result.action.key?(:amount)
  end

  test "correction chatter is not part of the debt name" do
    result = resolve("oops visa minimum is 65", active_debts: [ { id: 7, label: "Visa" } ])
    assert_equal "update_debt", result.action[:type]
    assert_equal 7, result.action[:debt_id]
    assert_equal "65", result.action[:minimum_payment]
  end

  test "calculated totals preserve explicit spending group choices" do
    preferences = [ { family: "groceries", group: "fixed", evidence: "groceries go in fixed" } ]
    result = resolve("rent 1200 and groceries 300; groceries go in fixed", field: "fixed_expenses", data: {
      spending_preferences: preferences, setup_details: { field: "fixed_expenses", cadence: "monthly", count: "", partial: true,
        components: [ { source: "rent 1200", amount: "1200" }, { source: "groceries 300", amount: "300" } ] } })
    assert result.clarification?, result.to_h.inspect
    assert_includes result.clarification, "monthly total"
    assert_equal preferences, result.topic.fetch(:spending_preferences).map(&:deep_symbolize_keys)
  end

  test "a plain saved goal correction remains reviewable" do
    result = resolve("change my goal to cover school fees", field: "primary_goal", complete: true,
      data: { correction: true, setup_answer: { field: "goal", value: "cover school fees" } })
    assert result&.actionable?, result.to_h.inspect
    assert_equal "cover school fees", result.action.dig(:setup_updates, :primary_goal)
  end

  test "correcting fixed essentials while an income review is pending does not retarget the income" do
    message = "actually fixed essentials is 1450"
    parsed = HouseholdFinance::ParticipantMessageReader.new(message: message, pending_field: "primary_income").send(:validate,
      { "care" => "none", "facts" => [], "question" => false, "correction" => true, "setup_answer" => { "field" => "fixed", "value" => "1450" }, "spending_preferences" => [] })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: message, api_key: "", context: {
      participant_reading: parsed, setup_status: { complete: true, missing_fields: [ { key: "debt_payment" } ] },
      conversation: { active_thread: { status: "pending_review", action: { type: "schedule_income_change", amount: "3500", income_source_id: 1 } }, recent_messages: [] }
    }).call
    assert_equal "update_household_setup", result.action[:type]
    assert_equal 1450.0, result.action.dig(:setup_updates, :fixed_expenses).to_f
  end

  test "a question mentioning a bill is answered before asking for a setup total" do
    result = resolve("does rent 1200 count as fixed essentials", field: "primary_income", data: {
      question: true, facts: [ { kind: "bill", amount: "1200", item: "rent", merchant: "", day: "" } ] })
    refute result&.actionable?
    refute_match(/one monthly total/i, result&.clarification.to_s)
    assert_includes result&.clarification.to_s, "regular must-pay"
  end

  test "a monthly named card payment remains reviewable after optional debt stops gating setup" do
    result = resolve("$325 a month on the Mastercard", complete: true)
    assert result.actionable?, result.to_h.inspect
    assert_equal "325", result.action[:minimum_payment]
    refute result.action.key?(:amount)
    grocery = resolve("$325 a month on groceries", complete: true)
    refute_equal "create_debt", grocery&.action.to_h[:type]
  end

  test "an old pending setup card does not restart questioning after the form completes" do
    parsed = HouseholdFinance::ParticipantMessageReader.new(message: "thanks").send(:validate,
      { "care" => "none", "facts" => [], "question" => false, "correction" => false, "setup_answer" => { "field" => "none", "value" => "" }, "spending_preferences" => [] })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: "thanks", api_key: "", context: {
      participant_reading: parsed, setup_status: { complete: true, missing_fields: [ { key: "debt_payment" } ] },
      conversation: { active_thread: { status: "pending_review", action: { type: "update_household_setup", setup_updates: { household_name: "Old name" } } },
        recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("household_name") } ] }
    }).call
    refute result&.clarification?, result.to_h.inspect
  end

  test "the reader can recognize a new deferral without a wording regex" do
    result = resolve("could we park this one for now", field: "primary_income", data: { defer_setup: true })
    assert result.clarification?
    assert_includes result.clarification, "fixed essentials"
    assert_equal "none", result.action[:type]
  end

  test "two named debt minimums each get their own review action" do
    text = "visa min is 95 and the car is 310"
    result = resolve(text, data: { setup_details: { field: "debt_payment", cadence: "monthly", count: "", partial: true,
      components: [ { source: "visa min is 95", amount: "95" }, { source: "the car is 310", amount: "310" } ] } })
    assert_equal "action_plan", result.intent
    assert_equal %w[95 310], result.write_plan[:actions].map { |entry| entry[:action][:minimum_payment] }
    assert result.write_plan[:actions].all? { |entry| !entry[:action].key?(:amount) }
  end

  test "an everyday spending question is answered and resumes without becoming a value" do
    result = resolve("what do you mean by everyday spending", field: "flexible_spend", data: { question: true })
    assert result.clarification?
    assert_includes result.clarification, "groceries"
    assert_includes result.clarification, "what monthly amount would you like to review"
    assert_equal "none", result.action[:type]
  end

  test "no debt payments produces a minimum-only review even after setup completes" do
    result = resolve("no debt payments", complete: true)
    assert result.actionable?, result.to_h.inspect
    assert_equal "0", result.action[:minimum_payment]
    assert_equal "unknown", result.action[:amount]
  end

  test "a single named minimum needs no total clarification" do
    result = resolve("just the visa, min is 60")
    assert result.actionable?, result.to_h.inspect
    assert_equal "60", result.action[:minimum_payment]
  end

  test "a saved named field can be corrected with a review" do
    result = resolve("actually my monthly income is 4200", field: "fixed_expenses", data: { correction: true, setup_answer: { field: "income", value: "4200" } })
    assert result.actionable?, result.to_h.inspect
    assert_equal 4200.0, result.action.dig(:setup_updates, :primary_income).to_f
  end

  test "skipping asks another question without inventing zero" do
    result = resolve("idk yet", field: "primary_income")
    assert result.clarification?
    assert_includes result.clarification, "Enter my numbers"
    assert_includes result.clarification, "fixed essentials"
    assert_equal "none", result.action[:type]
  end
end
