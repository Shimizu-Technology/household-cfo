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
        history: [ { role: "assistant", content: "Old stale fact: McDonald's is still pending." } ],
        answer_packet: {
          kind: "budget_question",
          fallback_response: "Based on your active annual plan, you have $55 remaining and $40 pending review.",
          write_state: "pending_review"
        },
        api_key: "test-key"
      ).call

      assert_equal "You have $55 left but $40 is still pending review. Review those drafts before actuals change.", answer
    end

    payload = JSON.parse(requests.first.body)
    system_prompts = payload.fetch("messages").select { |message| message.fetch("role") == "system" }.map { |message| message.fetch("content") }.join(" ")
    user_prompt = payload.fetch("messages").last.fetch("content")
    assert_equal HouseholdFinance::MiaNarrator::MAX_OUTPUT_TOKENS, payload.fetch("max_tokens")
    assert_equal HouseholdFinance::MiaNarrator::READ_TIMEOUT_SECONDS, start_options.first.fetch(:read_timeout)
    assert_includes system_prompts, "app has already verified the financial facts"
    assert_includes system_prompts, "The participant is the Household CFO"
    assert_includes user_prompt, "ANSWER_PACKET_JSON"
    assert_includes user_prompt, "pending_review"
    history_message = payload.fetch("messages").find { |message| message["role"] == "assistant" && message["content"].include?("Old stale fact") }
    assert history_message
    assert_includes system_prompts, "stale chat history cannot override ANSWER_PACKET_JSON"
  end

  test "strips reflexive cultural openers from model narration" do
    response = ok_response(
      choices: [
        { message: { content: "Okay, chelu. I drafted setting Fixed essentials to $3,950 for July 2026. Review the card before applying it." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Lower that to $3,950 for July",
        answer_packet: {
          kind: "budget_action",
          fallback_response: "I drafted setting Fixed essentials to $3,950 for July 2026. Review the card before applying it.",
          write_state: "pending_review"
        },
        api_key: "test-key"
      ).call

      assert_equal "I drafted setting Fixed essentials to $3,950 for July 2026. Review the card before applying it.", answer
    end
  end

  test "rejects a model claim that it created a draft when the verified result made no write" do
    response = ok_response(
      choices: [
        { message: { content: "I drafted a new category called Archived Buffer for September. Review the card to add it." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Create Archived Buffer for September",
        answer_packet: {
          kind: "budget_action",
          fallback_response: "Archived Buffer is archived. Restore it before editing it, or choose a different name for the new category.",
          write_state: "no_write"
        },
        api_key: "test-key"
      ).call

      assert_equal "Archived Buffer is archived. Restore it before editing it, or choose a different name for the new category.", answer
    end
  end

  test "strips reflexive Hafa Adai recall openers" do
    response = ok_response(
      choices: [
        { message: { content: "Håfa Adai, chelu! We were discussing the Fixed essentials July review. It is still pending your approval." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "What were we discussing?",
        answer_packet: {
          kind: "recall",
          fallback_response: "We were discussing the Fixed essentials July review. It is still pending your approval.",
          write_state: "pending_review"
        },
        api_key: "test-key"
      ).call

      assert_equal "We were discussing the Fixed essentials July review. It is still pending your approval.", answer
    end
  end

  test "strips a standalone chelu opener and preserves sentence capitalization" do
    response = ok_response(
      choices: [
        { message: { content: "Chelu, the category already exists. Choose a different name." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Create the category",
        answer_packet: {
          kind: "budget_action",
          fallback_response: "The category already exists. Choose a different name.",
          write_state: "no_write"
        },
        api_key: "test-key"
      ).call

      assert_equal "The category already exists. Choose a different name.", answer
    end
  end

  test "keeps no-write budget validation narration culturally neutral" do
    response = ok_response(
      choices: [
        { message: { content: "That category is archived. Restore it or choose another name. What would you like to do, chelu?" } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Create the archived category",
        answer_packet: {
          kind: "budget_action",
          fallback_response: "That category is archived. Restore it or choose another name.",
          write_state: "no_write"
        },
        api_key: "test-key"
      ).call

      assert_equal "That category is archived. Restore it or choose another name. What would you like to do?", answer
    end
  end

  test "falls back when narration contradicts the approved readiness status" do
    response = ok_response(
      choices: [
        { message: { content: "Your baseline is yellow because your current readiness is Red — pause and stabilize basics. Build runway next." } }
      ]
    )

    with_net_http_start_stub(response) do
      fallback = "Your approved readiness is Red — pause and stabilize basics. Positive cash flow is not Yellow yet because runway is below the protected threshold."
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Why is my baseline yellow?",
        answer_packet: {
          kind: "coaching",
          fallback_response: fallback,
          write_state: "no_write"
        },
        api_key: "test-key"
      ).call

      assert_equal fallback, answer
    end
  end

  test "suppresses repeated chelu when recent Mia history already used local phrasing" do
    response = ok_response(
      choices: [
        { message: { content: "The August review is ready, chelu. Check the month and amount before applying it." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Create the August category",
        history: [ { role: "assistant", content: "Lanya chelu, that was a real surprise." } ],
        answer_packet: {
          kind: "budget_action",
          fallback_response: "The August review is ready. Check the month and amount before applying it.",
          write_state: "pending_review"
        },
        api_key: "test-key"
      ).call

      assert_equal "The August review is ready. Check the month and amount before applying it.", answer
    end
  end

  test "removes cultural language and generic praise from a routine budget action" do
    response = ok_response(
      choices: [
        { message: { content: "You're doing great. This budget change is ready for review, chelu. Apply it only if July and $3,950 are right." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Set Fixed essentials to $3,950 for July",
        answer_packet: {
          kind: "budget_action",
          fallback_response: "I drafted setting Fixed essentials to $3,950 for July. Review it before applying.",
          write_state: "pending_review"
        },
        api_key: "test-key"
      ).call

      assert_equal "This budget change is ready for review. Apply it only if July and $3,950 are right.", answer
    end
  end

  test "falls back when readiness narration does not answer with the approved status first" do
    response = ok_response(
      choices: [
        { message: { content: "Your cash flow is positive by $4,795. Your approved readiness is Red because runway is 0.5 months." } }
      ]
    )
    fallback = "Your approved readiness is Red. Monthly cash flow is positive by $4,795, but runway is 0.5 months."

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Why is my readiness red?",
        answer_packet: { kind: "coaching", fallback_response: fallback, write_state: "no_write" },
        api_key: "test-key"
      ).call

      assert_equal fallback, answer
    end
  end

  test "falls back when readiness narration omits its approved numeric basis" do
    response = ok_response(
      choices: [
        { message: { content: "Your approved readiness is Red. Protect the baseline and build runway before expanding wants." } }
      ]
    )
    fallback = "Your approved readiness is Red. Monthly cash flow is positive by $4,795, but runway is 0.5 months."

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Why is my readiness red?",
        answer_packet: { kind: "coaching", fallback_response: fallback, write_state: "no_write" },
        api_key: "test-key"
      ).call

      assert_equal fallback, answer
    end
  end

  test "falls back when a pending transaction narration omits the actuals boundary" do
    response = ok_response(
      choices: [
        { message: { content: "I drafted Payless for $25. Review and confirm it if the amount is right." } }
      ]
    )
    fallback = "I drafted Payless for $25. Actuals will not change until you confirm it."

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "I spent $25 at Payless",
        answer_packet: { kind: "transaction_draft", fallback_response: fallback, write_state: "pending_review" },
        api_key: "test-key"
      ).call

      assert_equal fallback, answer
    end
  end

  test "logs a privacy-safe reason code when narration is rejected" do
    response = ok_response(
      choices: [
        { message: { content: "I recorded the $25 Payless transaction in actuals." } }
      ]
    )
    messages = []
    logger = Object.new
    logger.define_singleton_method(:info) { |message| messages << message }

    with_net_http_start_stub(response) do
      with_rails_logger_stub(logger) do
        HouseholdFinance::MiaNarrator.new(
          user_message: "I spent $25 at Payless",
          answer_packet: {
            kind: "transaction_draft",
            fallback_response: "I drafted Payless for $25. Actuals will not change until you confirm it.",
            write_state: "pending_review"
          },
          api_key: "test-key"
        ).call
      end
    end

    assert_equal 1, messages.length
    assert_includes messages.first, "reason=false_write_claim"
    assert_includes messages.first, "kind=transaction_draft"
    refute_includes messages.first, "Payless"
    refute_includes messages.first, "$25"
  end

  test "bounds narrator history by message count and aggregate characters" do
    history = 40.times.map do |index|
      { role: index.even? ? "user" : "assistant", content: "message-#{index} " + ("x" * 3_990) }
    end
    narrator = HouseholdFinance::MiaNarrator.new(
      user_message: "Continue",
      history: history,
      answer_packet: { kind: "coaching", fallback_response: "Continue safely.", write_state: "no_write" },
      api_key: nil
    )

    bounded_history = narrator.send(:conversation_history)

    assert_operator bounded_history.length, :<=, HouseholdFinance::MiaNarrator::MAX_HISTORY_MESSAGES
    assert_operator bounded_history.sum { |message| message.fetch(:content).length }, :<=, HouseholdFinance::MiaNarrator::MAX_HISTORY_CHARACTERS
    assert_includes bounded_history.last.fetch(:content), "message-39"
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
          fallback_response: "Based on confirmed transactions, I found three grocery purchases this month, including a recorded $85 Payless charge.",
          write_state: "no_write"
        },
        api_key: "test-key"
      ).call

      assert_equal "I found a recorded $85 Payless charge and two logged grocery purchases this month, based on confirmed transactions already on record. Use those confirmed rows to decide whether the grocery category needs a reset before the next shop.", answer
    end
  end

  test "falls back when narration invents a dollar amount not present in the packet" do
    response = ok_response(
      choices: [
        { message: { content: "The $25 concert tickets fit within your remaining discretionary plan, but readiness is Red." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Can I buy concert tickets?",
        answer_packet: {
          kind: "coaching",
          fallback_response: "Based on approved numbers, pause this want until the basics are stable.",
          write_state: "no_write",
          annual_plan_summary: { pending_draft_count: 0 }
        },
        api_key: "test-key"
      ).call

      assert_equal "Based on approved numbers, pause this want until the basics are stable.", answer
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

  test "falls back when narration claims a budget adjustment happened for pending review" do
    response = ok_response(
      choices: [
        { message: { content: "I've made the adjustment, and your budget has been changed to reflect the McDonald's transaction." } }
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

  test "allows a verified pending draft update while preserving actuals" do
    response = ok_response(
      choices: [
        { message: { content: "I updated the pending Walkthrough Cafe review from July 10 to July 9. It still needs your confirmation, and actuals did not change." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Actually it was yesterday",
        answer_packet: {
          kind: "transaction_draft_update",
          fallback_response: "I updated the pending Walkthrough Cafe review date to July 9. It is still pending, and actuals did not change.",
          write_state: "draft_updated"
        },
        api_key: "test-key"
      ).call

      assert_equal "I updated the pending Walkthrough Cafe review from July 10 to July 9. It still needs your confirmation, and actuals did not change.", answer
    end
  end

  test "rejects an actuals update claim from a pending draft edit" do
    response = ok_response(
      choices: [
        { message: { content: "I updated the pending Walkthrough Cafe review, and your actuals are now updated for July 9." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Actually it was yesterday",
        answer_packet: {
          kind: "transaction_draft_update",
          fallback_response: "I updated the pending Walkthrough Cafe review date to July 9. It is still pending, and actuals did not change.",
          write_state: "draft_updated"
        },
        api_key: "test-key"
      ).call

      assert_equal "I updated the pending Walkthrough Cafe review date to July 9. It is still pending, and actuals did not change.", answer
    end
  end

  test "falls back when budget narration invents a pending draft that the packet says is absent" do
    response = ok_response(
      choices: [
        { message: { content: "You still have a pending McDonald's draft waiting for your review before actuals change." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "Can I buy concert tickets?",
        answer_packet: {
          kind: "budget_question",
          fallback_response: "No pending drafts are waiting right now. Keep this as a pre-spend decision.",
          write_state: "no_write",
          annual_plan_summary: { pending_draft_count: 0 }
        },
        api_key: "test-key"
      ).call

      assert_equal "No pending drafts are waiting right now. Keep this as a pre-spend decision.", answer
    end
  end

  test "falls back when spending report narration invents a pending draft that the packet says is absent" do
    response = ok_response(
      choices: [
        { message: { content: "July confirmed spending is $0, but McDonald's is still a pending draft, so confirm or delete the pending draft next." } }
      ]
    )

    with_net_http_start_stub(response) do
      answer = HouseholdFinance::MiaNarrator.new(
        user_message: "How much did I spend this month?",
        answer_packet: {
          kind: "spending_report",
          fallback_response: "For July 2026, confirmed spending is $0 and no pending drafts are waiting on this period.",
          write_state: "no_write",
          spending_report_summary: { period_label: "July 2026", pending_draft_count: 0 }
        },
        api_key: "test-key"
      ).call

      assert_equal "For July 2026, confirmed spending is $0 and no pending drafts are waiting on this period.", answer
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

  def with_rails_logger_stub(logger)
    singleton = Rails.singleton_class
    original = Rails.method(:logger)
    singleton.define_method(:logger) { logger }
    yield
  ensure
    singleton.send(:remove_method, :logger) if singleton.method_defined?(:logger)
    singleton.define_method(:logger) { original.call }
  end
end
