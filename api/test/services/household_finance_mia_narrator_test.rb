require "test_helper"

class HouseholdFinanceMiaNarratorTest < ActiveSupport::TestCase
  test "falls back to Rails answer when no API key is configured" do
    answer = HouseholdFinance::MiaNarrator.new(
      user_message: "Can I buy this?",
      answer_packet: { kind: "coaching", fallback_response: "Based on approved numbers, wait until bills clear.", write_state: "no_write" },
      api_key: nil
    ).call

    assert_equal "Based on approved numbers, wait until bills clear.", answer
  end

  test "narrates answer packets through OpenRouter and strips generic openers" do
    requests = []
    start_options = []
    response = ok_response(
      choices: [
        { message: { content: "That's a good question. You have $55 left, chelu, but $40 is still pending review. Review those drafts before actuals change." } }
      ]
    )

    with_net_http_start_stub(response, requests, start_options) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Can I order takeout?",
        answer_packet: {
          kind: "budget_question",
          fallback_response: "Based on your active annual plan, you have $55 remaining and $40 pending review.",
          write_state: "pending_review"
        },
        api_key: "test-key"
      ).call

      assert_equal "You have $55 left, chelu, but $40 is still pending review. Review those drafts before actuals change.", answer
    end

    payload = JSON.parse(requests.first.body)
    system_prompts = payload.fetch("messages").select { |message| message.fetch("role") == "system" }.map { |message| message.fetch("content") }.join(" ")
    user_prompt = payload.fetch("messages").last.fetch("content")
    assert_equal HouseholdFinance::MiaNarrator::MAX_OUTPUT_TOKENS, payload.fetch("max_tokens")
    assert_equal HouseholdFinance::MiaNarrator::READ_TIMEOUT_SECONDS, start_options.first.fetch(:read_timeout)
    assert_includes system_prompts, "Rails has already computed the financial truth"
    assert_includes system_prompts, "The participant is the Household CFO"
    assert_includes user_prompt, "ANSWER_PACKET_JSON"
    assert_includes user_prompt, "pending_review"
  end

  test "allows historical transaction lookup narration without treating recorded language as a write claim" do
    response = ok_response(
      choices: [
        { message: { content: "I found a recorded $85 Payless charge and two logged grocery purchases this month, based on confirmed transactions already on record. Use those confirmed rows to decide whether the grocery category needs a reset before the next shop." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Show my grocery transactions",
        answer_packet: {
          kind: "transaction_lookup",
          fallback_response: "Based on confirmed transactions, I found three grocery purchases this month.",
          write_state: "no_write"
        },
        api_key: "test-key"
      ).call

      assert_equal "I found a recorded $85 Payless charge and two logged grocery purchases this month, based on confirmed transactions already on record. Use those confirmed rows to decide whether the grocery category needs a reset before the next shop.", answer
    end
  end

  test "falls back when OpenRouter truncates the narration" do
    response = ok_response(
      choices: [
        { finish_reason: "length", message: { content: "You have $55 left, but" } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Can I order takeout?",
        answer_packet: {
          kind: "budget_question",
          fallback_response: "Based on your active annual plan, you have $55 remaining and $40 pending review.",
          write_state: "pending_review"
        },
        api_key: "test-key"
      ).call

      assert_equal "Based on your active annual plan, you have $55 remaining and $40 pending review.", answer
    end
  end

  test "falls back when narration claims a write happened for pending review" do
    response = ok_response(
      choices: [
        { message: { content: "I recorded that $25 McDonald's transaction in your actuals." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "I spent $25 at McDonald's",
        answer_packet: {
          kind: "transaction_draft",
          fallback_response: "I drafted this for review: McDonald's for $25. Month-to-date actuals will not change until you approve it.",
          write_state: "pending_review"
        },
        api_key: "test-key"
      ).call

      assert_equal "I drafted this for review: McDonald's for $25. Month-to-date actuals will not change until you approve it.", answer
    end
  end

  private

  def ok_response(payload)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
      response.instance_variable_set(:@body, payload.to_json)
      response.instance_variable_set(:@read, true)
    end
  end

  def with_net_http_start_stub(response, requests = [], start_options = [])
    singleton = class << Net::HTTP; self; end
    original = singleton.instance_method(:start)
    singleton.define_method(:start) do |*_args, **kwargs, &block|
      start_options << kwargs
      http = Object.new
      http.define_singleton_method(:request) do |request|
        requests << request
        response
      end
      block.call(http)
    end
    yield
  ensure
    singleton.send(:remove_method, :start) if singleton.method_defined?(:start)
    singleton.define_method(:start, original)
  end
end
