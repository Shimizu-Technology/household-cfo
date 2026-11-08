require "test_helper"

class MiaSetupRoundTwoRoutingTest < ActiveSupport::TestCase
  def resolve(message, field: "primary_income", answer: nil, correction: false, question: false, complete: false, facts: [], pending: nil)
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, setup_field: field, pending_field: pending,
      transport: ->(_) { { care: "none", facts: facts, question: question, correction: correction,
        setup_answer: answer || { field: "none", value: "" } }.to_json })
    HouseholdFinance::MiaIntentResolver.new(user_message: message, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: complete, missing_fields: complete ? [] : [ { key: field } ] },
      conversation: { active_thread: pending ? { status: "pending_review", action: { type: "update_household_setup", setup_updates: { pending.to_sym => "3900" } } } : {},
        recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message(field) } ] }
    }).call
  end

  [ [ "i work 2 jobs and bring home 3900", "primary_income", "income", "3900" ],
    [ "rent is 1500 for 2 bedrooms", "fixed_expenses", "fixed", "1500" ],
    [ "groceries n gas for 5 ppl runs like 900", "flexible_spend", "flexible", "900" ],
    [ "3900 same as last month", "primary_income", "income", "3900" ] ].each do |message, field, key, value|
    test "reader scalar wins over incidental numbers #{message}" do
      result = resolve(message, field: field, answer: { field: key, value: value })
      assert result.actionable?, result.to_h.inspect
      assert_equal value.to_f, result.action.dig(:setup_updates, field.to_sym).to_f
    end
  end

  test "corrections remain answers after apply and across fields" do
    [ [ "my bad its 4250 not 3900", "primary_income", "income", "4250", nil ],
      [ "oh wait my income is more like 4250", "fixed_expenses", "income", "4250", nil ],
      [ "sorry bills are 1900 tho", "primary_income", "fixed", "1900", "primary_income" ] ].each do |message, field, key, value, pending|
      result = resolve(message, field: field, answer: { field: key, value: value }, correction: true, pending: pending)
      assert result.actionable?, result.to_h.inspect
      target = HouseholdFinance::ParticipantMessageReader::SETUP_FIELDS.fetch(key)
      assert_equal value.to_f, result.action.dig(:setup_updates, target.to_sym).to_f
    end
  end

  test "reader questions never become setup values" do
    HouseholdFinance::MiaSetupGuide::NEXT_QUESTIONS.each_key do |field|
      message = field == "household_name" ? "wat do u mean by a name for the house" : "what does 1500 mean"
      result = resolve(message, field: field, question: true)
      refute result&.actionable?, [ field, result&.to_h ].inspect
      pending = resolve(message, field: field, question: true, pending: field)
      refute pending&.actionable?, [ field, pending&.to_h ].inspect
    end
  end

  test "unsupported setup question targets do not crash" do
    reading = HouseholdFinance::ParticipantMessageReader.call(message: "can I buy shoes for 80", setup_field: nil,
      transport: ->(_) { { question: true, setup_answer: { field: "none", value: "" } }.to_json })
    resolver = HouseholdFinance::MiaIntentResolver.new(user_message: "can I buy shoes for 80", api_key: "",
      context: { participant_reading: reading, setup_status: { complete: true } })
    resolver.define_singleton_method(:next_missing_setup_field) { "emergency_fund" }
    resolver.define_singleton_method(:guided_setup_question_asked?) { |_| true }
    assert_nil resolver.send(:participant_setup_result)
  end

  test "debt replacement must cover earlier known amounts" do
    item = HouseholdFinance::MiaActionDraftBuilder::Item
    prior = item.new(action_type: "create_debt", target_record_type: "Debt", payload: {
      label: "Visa", debt_type: "credit_card", balance_cents: 120000, balance_known: true,
      minimum_payment_cents: 0, minimum_payment_known: false
    })
    replacement = item.new(action_type: "create_debt", target_record_type: "Debt", payload: {
      label: "Visa", debt_type: "credit_card", balance_cents: 0, balance_known: false,
      minimum_payment_cents: 4500, minimum_payment_known: true
    })
    proposal = HouseholdFinance::MiaActionDraftBuilder::Proposal.allocate
    proposal.instance_variable_set(:@items, [ replacement ])
    refute proposal.send(:replacement_covers_item?, prior)
  end

  test "outage unknown amounts never become zero" do
    %w[primary_income fixed_expenses flexible_spend debt_payment].each do |field|
      [ "rent 100 a week", "phones r 25 a week", "nonsense", "work", "junk", "blah thousand", "0junk", "" ].each do |message|
        reading = HouseholdFinance::ParticipantMessageReader.call(message: message, setup_field: field, api_key: "")
        assert_nil reading.answer_field, [ field, message, reading.to_h ].inspect
      end
    end
  end

  test "a minimum clause cannot turn rent or a paycheck into a debt" do
    result = resolve("visa min is 60 and rent is 1500", field: "debt_payment")
    refute_equal "action_plan", result&.intent
    result = resolve("visa min is 60 and my paycheck is 2000", field: "debt_payment")
    refute_equal "action_plan", result&.intent
  end

  test "missing payment guard respects the setup question" do
    facts = [ { kind: "bill", item: "car loan", amount: "", merchant: "", day: "" } ]
    [ [ "household_name", false ], [ "primary_income", true ] ].each do |field, complete|
      result = resolve("my car loan is due friday", field: field, facts: facts, complete: complete)
      refute_includes result&.clarification.to_s, "How much is that bill or payment"
    end
  end
  [ "add trash 20 and take out internet", "add trash 20 and water 30", "remove internet and rent" ].each do |message|
    test "a mixed pending edit asks instead of silently making only one change #{message}" do
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, setup_field: "fixed_expenses", transport: ->(_) {
      { care: "none", question: false, correction: false, facts: [], setup_answer: { field: "none", value: "" },
        setup_details: { edit: message.start_with?("remove") ? { operation: "remove", item: "internet", amount: "", source: message } : { operation: "add", item: "trash", amount: "20", source: "add trash 20" } } }.to_json
    })
    service = HouseholdFinance::MiaSetupCalculation.new(message: message, reading: reading, field: "fixed_expenses",
      prior: { field: "fixed_expenses", components: [ { label: "rent", amount: "1500" }, { label: "internet", amount: "75" } ] })
    assert_nil service.call
    assert service.clarification.present?
    end
  end

  test "raise without cadence never presumes monthly" do
    [ "$22", "$65,000", "5600" ].each do |amount|
      result = resolve("got a raise im at #{amount} now", complete: true)
      refute result.actionable?, result.to_h.inspect
      assert_includes result.clarification, "monthly"
    end
  end
  test "a pending list does not intercept a reader scalar that is not a list edit" do
    message = "i work 2 jobs and bring home 3900"
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, setup_field: "primary_income", transport: ->(_) {
      { care: "none", question: false, correction: true, facts: [], setup_answer: { field: "income", value: "3900" } }.to_json
    })
    resolver = HouseholdFinance::MiaIntentResolver.new(user_message: message, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: false, missing_fields: [ { key: "primary_income" } ] },
      conversation: { pending_setup_calculations: { primary_income: { field: "primary_income", components: [ { label: "job", amount: "3000" }, { label: "side work", amount: "500" } ] } },
        recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("primary_income") } ] }
    })
    result = resolver.call
    assert result.actionable?, result.to_h.inspect
    assert_equal "3900", result.action.dig(:setup_updates, :primary_income)
  end
  test "a reader list edit finds the pending list across setup fields without a preamble rule" do
    message = "oh n phone 85"
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, setup_field: "flexible_spend", transport: ->(_) {
      { care: "none", question: false, correction: false, facts: [], setup_answer: { field: "none", value: "" },
        setup_details: { edit: { operation: "add", item: "phone", amount: "85", source: message } } }.to_json
    })
    result = HouseholdFinance::MiaIntentResolver.new(user_message: message, api_key: "", context: {
      participant_reading: reading, setup_status: { complete: false, missing_fields: [ { key: "flexible_spend" } ] },
      conversation: { pending_setup_calculations: { fixed_expenses: { field: "fixed_expenses", components: [ { label: "rent", amount: "1500" }, { label: "power", amount: "200" } ] } },
        recent_messages: [ { role: "assistant", content: HouseholdFinance::MiaSetupGuide.question_message("flexible_spend") } ] }
    }).call
    assert result.actionable?, result.to_h.inspect
    assert_equal 1785, result.action.dig(:setup_updates, :fixed_expenses).to_f
  end
  test "an unknown single bill asks for its monthly amount" do
    result = resolve("just that one bill", field: "fixed_expenses")
    assert_includes result.clarification, "monthly amount"
    refute_includes result.clarification, "one step at a time"
  end

  test "a volunteered bill cannot make the income question ask for bills" do
    result = resolve("rent is 1500", facts: [ { kind: "bill", item: "rent", amount: "1500", merchant: "", day: "" } ])
    assert_includes result.clarification, "income source"
    refute_includes result.clarification, "monthly bill"
  end
end
