require "test_helper"
require_relative "../support/natural_purchase_phrases"

class HouseholdFinanceNaturalPurchaseReportTest < ActiveSupport::TestCase
  test "both workspaces read the same natural reports without a provider" do
    NaturalPurchasePhrases::NATURAL_PURCHASES.each do |message, expected|
      result = HouseholdFinance::MiaIntentResolver.new(user_message: message,
        context: { calendar: { today: NaturalPurchasePhrases::TODAY.iso8601 } }, api_key: nil).call
      assert result&.actionable?, message
      actions = result.transaction_report_plan? ? result.write_plan[:actions].map { |entry| entry[:action] } : [ result.action ]
      actual = actions.map { |action| [ HouseholdFinance::Money.chat_cents(action[:amount]), action[:merchant], Date.iso8601(action[:occurred_on]) ] }
      assert_equal expected, actual, message
      if result.transaction_report_plan?
        result.write_plan[:actions].each { |entry| assert_includes message, entry[:source_text] }
      end
      assert_equal "deterministic", result.source
      assert actions.all? { |action| action[:type] == "create_transaction_draft" }
    end
  end

  test "a reflection without an amount or a store is coaching, not a purchase question" do
    [ "I ordered takeout again tonight. That's the fourth time this week even though I told myself I'd stop.",
      "I keep buying snacks when I'm stressed", "I bought too much this week and feel bad" ].each do |message|
      result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: nil).call
      refute result&.clarification?, message
      refute result&.actionable?, message
    end
  end

  test "a purpose or category after the store is not part of its name" do
    { "I spent 7 at No Dollar Cafe for Dining Out today" => "No Dollar Cafe",
      "I spent $12 at Kmart for the kids yesterday" => "Kmart",
      "Spent $30 at Payless for groceries" => "Payless",
      "spent $5 at Ross Dress for Less today" => "Ross Dress for Less" }.each do |message, merchant|
      result = HouseholdFinance::MiaIntentResolver.new(user_message: message,
        context: { calendar: { today: NaturalPurchasePhrases::TODAY.iso8601 } }, api_key: nil).call
      assert_equal merchant, result.action[:merchant], message
    end
  end

  test "missing purchase prices ask specifically without creating a partial report" do
    result = HouseholdFinance::MiaIntentResolver.new(user_message: "I spent $8 at Shell and bought lunch at Kings",
      context: {}, api_key: nil).call
    assert result.clarification?
    assert_equal "How much was the Kings purchase?", result.clarification
    assert_equal "none", result.action[:type]
  end

  test "unclear and future dates cannot fall through to a legacy draft dated today" do
    [ "I spent $5 at Shell last week", "I spent $5 at Shell on #{(Date.current + 1).iso8601}" ].each do |message|
      result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: nil).call
      assert result.clarification?, message
      assert_nil HouseholdFinance::TransactionDraftBuilder.new(nil, message, user: nil).call
    end
    assert_nil HouseholdFinance::TransactionDraftBuilder.new(nil, "I spent $5 at Shell tomorrow", user: nil).call
  end

  test "unbound second prices cannot fall through to a partial legacy draft" do
    message = "I spent $8 at Shell and a backpack 12 at Kings"
    result = HouseholdFinance::MiaIntentResolver.new(user_message: message, context: {}, api_key: nil).call
    assert result.clarification?
    assert_equal "How much was the Kings purchase?", result.clarification
    assert_nil HouseholdFinance::TransactionDraftBuilder.new(nil, message, user: nil).call
    [ "I may spend $5 at May’s Cafe", "I spent $5 at Budget Mart tomorrow" ].each do |plan|
      assert_nil HouseholdFinance::TransactionDraftBuilder.new(nil, plan, user: nil).call
    end
  end

  test "explicit units are required and malformed compound amounts never become smaller purchases" do
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.new(2026, 1, 1), Date.current, Date.current)
    [ "I spent twelve fifty at Payless", "I spent twenty twelve dollars at Payless",
      "I spent 18 dollars and 147 cents at Payless", "I spent 18.47 dollars and 20 cents at Payless",
      "I spent one thousand dollars at Payless" ].each do |message|
      result = HouseholdFinance::PurchaseReportParser.new(calendar, message: message).call
      assert_not result.found?, message
    end
  end
end
