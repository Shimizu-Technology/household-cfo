require "test_helper"

class DemoMiaResponderTest < ActiveSupport::TestCase
  test "deterministic discretionary purchase response preserves local demo line even with api key" do
    response = Demo::MiaResponder.new(api_key: "test-key").call("Can I buy the purse?")

    assert_includes response, "Lanya chelu"
    assert_includes response, "that purse isn’t in the cards right now"
    assert_includes response, "30-day list"
    refute_includes response, "*"
  end

  test "bag purchase intent also preserves the screenshot-ready purse line" do
    response = Demo::MiaResponder.new(api_key: "test-key").call("Should I buy this bag?")

    assert_includes response, "Lanya chelu"
    assert_includes response, "that purse isn’t in the cards right now"
  end

  test "generic safe to spend question uses local spending check without forcing purse wording" do
    response = Demo::MiaResponder.new(api_key: "test-key").call("Can I spend money on this?")

    assert_includes response, "Pump the brakes"
    assert_includes response, "household baseline"
    refute_includes response, "purse"
  end

  test "non-screenshot discretionary purchases use spending check instead of purse wording" do
    response = Demo::MiaResponder.new(api_key: "test-key").call("Can I buy coffee today?")

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

  test "low signal greeting still works" do
    response = Demo::MiaResponder.new(api_key: "test-key").call("hi")

    assert_includes response, "Håfa Adai"
  end
end
