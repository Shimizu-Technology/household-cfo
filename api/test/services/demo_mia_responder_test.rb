require "test_helper"

class DemoMiaResponderTest < ActiveSupport::TestCase
  test "chat uses OpenRouter for ordinary messages when api key is configured" do
    responder = stubbed_model_responder("Real model response")

    assert_equal "Real model response", responder.call("hi")
    assert_equal "Real model response", responder.call("Can I buy the purse?")
  end

  test "default chat model uses Claude Sonnet latest through OpenRouter" do
    with_env("OPENROUTER_MODEL" => nil) do
      responder = Demo::MiaResponder.new(api_key: nil)

      assert_equal "~anthropic/claude-sonnet-latest", responder.instance_variable_get(:@model)
    end
  end

  test "fallback discretionary purchase response preserves local demo line when api key is missing" do
    response = Demo::MiaResponder.new(api_key: nil).call("Can I buy the purse?")

    assert_includes response, "Lanya chelu"
    assert_includes response, "that purse isn’t in the cards right now"
    assert_includes response, "30-day list"
    refute_includes response, "*"
  end

  test "fallback bag purchase intent also preserves the screenshot-ready purse line" do
    response = Demo::MiaResponder.new(api_key: nil).call("Should I buy this bag?")

    assert_includes response, "Lanya chelu"
    assert_includes response, "that purse isn’t in the cards right now"
  end

  test "fallback generic safe to spend question uses local spending check without forcing purse wording" do
    response = Demo::MiaResponder.new(api_key: nil).call("Can I spend money on this?")

    assert_includes response, "Pump the brakes"
    assert_includes response, "household baseline"
    refute_includes response, "purse"
  end

  test "fallback non-screenshot discretionary purchases use spending check instead of purse wording" do
    response = Demo::MiaResponder.new(api_key: nil).call("Can I buy coffee today?")

    assert_includes response, "Pump the brakes"
    assert_includes response, "household baseline"
    refute_includes response, "that purse isn’t in the cards right now"
  end

  test "discretionary terms without purchase intent do not trigger spending guardrails" do
    responder = Demo::MiaResponder.new(api_key: nil)

    [
      "How do I track restaurant spending?",
      "I went to a concert last month.",
      "Are shoes a good tax deduction?",
      "I can finally afford it.",
      "I'd love to spend on this someday."
    ].each do |message|
      response = responder.call(message)

      refute_includes response, "that purse isn’t in the cards right now", message
      refute_includes response, "Pump the brakes", message
      assert_includes response, "protecting the household baseline", message
    end
  end

  test "essential purchase questions are not treated as discretionary splurges" do
    response = Demo::MiaResponder.new(api_key: nil).call("Can I buy groceries?")

    refute_includes response, "that purse isn’t in the cards right now"
    refute_includes response, "Pump the brakes"
    assert_includes response, "protecting the household baseline"
  end

  test "crisis language bypasses money coaching and returns immediate safety support" do
    response = Demo::MiaResponder.new(api_key: "test-key").call("My money is making me so depressed I want to kill myself")

    assert_includes response, "988"
    assert_includes response, "911"
    assert_includes response, "trusted person"
    assert_includes response, "not budgeting"
    refute_includes response.downcase, "safe-to-spend"
    refute_includes response.downcase, "monthly cushion"
  end

  test "standalone can't go on crisis language still returns immediate safety support" do
    response = Demo::MiaResponder.new(api_key: "test-key").call("I can't go on anymore")

    assert_includes response, "988"
    assert_includes response, "911"
    assert_includes response, "getting support"
  end

  test "financial frustration using can't go on does not over-trigger crisis response" do
    responder = Demo::MiaResponder.new(api_key: nil)

    [
      "I can't go on with this budget",
      "I cannot go on paying these fees"
    ].each do |message|
      response = responder.call(message)

      refute_includes response, "988", message
      refute_includes response, "not budgeting", message
      assert_includes response, "protecting the household baseline", message
    end
  end

  test "can't go on with debt anymore is treated as safety language" do
    response = Demo::MiaResponder.new(api_key: nil).call("I can't go on with this debt anymore")

    assert_includes response, "988"
    assert_includes response, "911"
    assert_includes response, "getting support"
  end

  test "fallback low signal greeting does not force a Chamorro phrase every time" do
    response = Demo::MiaResponder.new(api_key: nil).call("hi")

    assert_includes response, "I’m ready"
    refute_includes response, "Håfa Adai"
  end

  test "safety prompt preserves product frame, crisis routing, and generic opener ban" do
    prompt = Demo::MiaResponder::SAFETY_SYSTEM_PROMPT

    assert_includes prompt, "The participant is the Household CFO"
    assert_includes prompt, "Mia is not the CFO"
    assert_includes prompt, "call or text 988"
    assert_includes prompt, "That's a good question"
    assert_includes prompt, "Do not use Chamorro words reflexively"
    assert_includes prompt, "month-to-date actuals change only after the Household CFO confirms the draft"
    assert_includes prompt, "pre-spend CFO decision"
    assert_includes prompt, "That's a smart question"
    assert_includes prompt, "answer the direct question first"
    assert_includes prompt, "separate planned budget from confirmed actuals and pending drafts"
    assert_includes prompt, "say so plainly instead of guessing"
  end

  test "verified conversation resolution tells the narrator not to repeat a rejected prerequisite" do
    responder = Demo::MiaResponder.new(api_key: nil)
    messages = responder.send(
      :verified_conversation_resolution_messages,
      {
        intent: "recall",
        action: {
          type: "set_allocation",
          category_id: 42,
          category_name: "Fixed essentials",
          amount: "3000",
          months: [ 7 ],
          year: 2026
        }
      }
    )

    assert_equal [ "system" ], messages.pluck(:role)
    assert_includes messages.first.fetch(:content), "VERIFIED_CURRENT_CONVERSATION_RESOLUTION_JSON"
    assert_includes messages.first.fetch(:content), "do not repeat an older assistant request for underlying items"
    assert_includes messages.first.fetch(:content), '"category_id":42'
  end

  test "model responses have generic opener stripped" do
    responder = Demo::MiaResponder.new(api_key: nil)

    assert_equal "Check the annual plan first.", responder.send(:sanitize_assistant_content, "That’s a good question. Check the annual plan first.")
    assert_equal "Build runway first.", responder.send(:sanitize_assistant_content, "That's a smart question. Build runway first.")
    assert_equal "Use the active plan.", responder.send(:sanitize_assistant_content, "That's a great question. Use the active plan.")
    assert_equal "Use the active plan.", responder.send(:sanitize_assistant_content, "This is a great question. Use the active plan.")
  end

  test "model responses have rejected brand phrases stripped" do
    responder = Demo::MiaResponder.new(api_key: nil)

    response = responder.send(:sanitize_assistant_content, "I cannot say \"Mia, your household CFO.\" You are the Household CFO.")

    refute_includes response, "Mia, your household CFO"
    assert_includes response, "You are the Household CFO"
  end

  test "model responses cannot claim a reported transaction was already applied" do
    response = Demo::MiaResponder.new(api_key: nil).send(
      :sanitize_assistant_content,
      "I've added that $25 to Dining Out and updated actuals.",
      user_message: "I spent $25 at McDonald's for Dining Out today",
      draft_capable: true
    )

    assert_includes response, "draft that transaction for review"
    assert_includes response, "actuals will not change until you confirm"
    refute_includes response, "added"
  end

  test "generic replies cannot claim a current draft was created when the route created no review card" do
    responder = Demo::MiaResponder.new(api_key: nil)

    [
      "Okay, I'll draft that under Dining Out.",
      "Yes, I did draft it under Dining Out.",
      "I have prepared the transaction review."
    ].each do |claim|
      response = responder.send(
        :sanitize_assistant_content,
        claim,
        user_message: "Yes",
        draft_capable: false
      )

      assert_includes response, "did not create a new transaction review", claim
      assert_includes response, "Nothing changed", claim
    end
  end

  test "recall may describe an existing supervised budget review without becoming a transaction error" do
    response = Demo::MiaResponder.new(api_key: nil).send(
      :sanitize_assistant_content,
      "We were discussing the Fixed essentials budget edit I drafted for July.",
      user_message: "What were we discussing?",
      draft_capable: false,
      conversation_resolution: {
        intent: "recall",
        action: { type: "set_allocation", category_id: 42, category_name: "Fixed essentials", amount: "3950", months: [ 7 ], year: 2026 }
      }
    )

    assert_includes response, "Fixed essentials"
    assert_includes response, "I drafted"
    refute_includes response, "transaction review"
  end

  test "reflexive cultural openers are removed and recent use suppresses repeated chelu" do
    responder = Demo::MiaResponder.new(api_key: nil)
    direct = responder.send(:sanitize_assistant_content, "Okay, chelu. I drafted the July edit for review.", draft_capable: true)
    recall = responder.send(:sanitize_assistant_content, "Håfa Adai, chelu! We were discussing the July edit.\n\nIt is still pending.", draft_capable: true)
    restrained = responder.send(
      :sanitize_assistant_content,
      "The August plan is ready, chelu. Review it before applying.",
      draft_capable: true,
      history: [ { role: "assistant", content: "Lanya chelu, that is a real surprise." } ]
    )

    assert_equal "I drafted the July edit for review.", direct
    assert_equal "We were discussing the July edit. It is still pending.", recall
    assert_equal "The August plan is ready. Review it before applying.", restrained
  end

  test "demo mode does not tell users to confirm unavailable drafts" do
    response = Demo::MiaResponder.new(api_key: nil).send(
      :sanitize_assistant_content,
      "I drafted that transaction for review. Confirm the draft.",
      user_message: "I spent $25 at McDonald's today",
      draft_capable: false
    )

    assert_includes response, "demo chat cannot create reviewable transaction drafts"
  end

  test "zero dollar reported spend does not say a draft was created" do
    response = Demo::MiaResponder.new(api_key: nil).send(
      :sanitize_assistant_content,
      "I drafted that transaction for review.",
      user_message: "I spent $0 at McDonald's today"
    )

    assert_includes response, "did not draft a transaction"
    assert_includes response, "amount is $0"
  end

  private

  def stubbed_model_responder(response)
    Demo::MiaResponder.new(api_key: "test-key").tap do |responder|
      responder.define_singleton_method(:openrouter_response) do |_message, _history, context:, draft_capable: false, conversation_resolution: nil|
        raise "expected household context" if context.blank?

        response
      end
    end
  end

  def with_env(values)
    previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
