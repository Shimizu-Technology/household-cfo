require "test_helper"

class W27FinalShortTest < ActiveSupport::TestCase
  teardown { HouseholdFinance::ParticipantMessageReader::Current.reset }

  test "month response failure degrades without raising" do
    controller = Api::V1::MiaMessagesController.new
    broken = Object.new
    broken.define_singleton_method(:response) { |**| raise "month unavailable" }
    controller.instance_variable_set(:@mia_month_answer, broken)
    assert_match(/couldn’t load/, controller.send(:safe_month_response))
  end

  test "history attribution belongs to the amount clause" do
    responder = Demo::MiaResponder.new(api_key: nil)
    [ "You said your income was $5,600, and your income is $5,600 now.", "You said your income was lower, but your income is $5,600." ].each do |text|
      mention = responder.send(:currency_mentions, text).last
      refute responder.send(:historical_amount_attributed?, text, mention)
    end
    text = "You said your income was $5,600. You can pay rent."
    refute responder.send(:historical_amount_attributed?, text, responder.send(:currency_mentions, text).first)
    text = "You said you got a raise to $5,600. Check what is available today."
    assert responder.send(:historical_amount_attributed?, text, responder.send(:currency_mentions, text).first)
  end

  test "refunds and savings statements are not purchase questions" do
    [ "I got $50 back from a refund", "I got $200 into savings", "I purchased a $300 chair" ].each do |text|
      refute HouseholdFinance::MessageReplyIntent.purchase_question?(text), text
    end
  end

  test "named month accepts a day or comma before the year" do
    [ "December 5, 2027", "Dec, 2027" ].each do |text|
      assert_equal Date.new(2027, 12, 1), HouseholdFinance::MiaMonthAnswer.question_date(text)
    end
  end

  test "win reflection defers a completed savings movement" do
    text = "I put $200 into savings!"
    HouseholdFinance::ParticipantMessageReader::Current.reply_intent = { message: text, intent: "win" }
    answerer = HouseholdFinance::MiaCoachAnswerer.allocate
    answerer.define_singleton_method(:message) { text }
    assert_nil answerer.send(:reflective_answer)
  end
end
