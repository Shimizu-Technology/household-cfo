require "test_helper"

class CasualMoneyReadingTest < ActiveSupport::TestCase
  def read(message, **extra)
    data = { care: "none", facts: [], question: false, setup_answer: { field: "none", value: "" }, correction: false, spending_preferences: [] }.merge(extra)
    HouseholdFinance::ParticipantMessageReader.call(message: message, transport: ->(_) { data.to_json })
  end

  test "purchase decisions retain exact price and item without becoming expenses" do
    text = "thinkin of gettin a 1500 tv on my card"
    reading = read(text, purchase_question: { amount: "1500", item: "tv" })
    assert_equal "1500", reading.purchase_question["amount"]
    assert_empty reading.facts
    HouseholdFinance::ParticipantMessageReader::Current.set(message: text, reading: reading) do
      assert HouseholdFinance::PurchaseQuestionText.read_only_purchase_question?(text)
      assert_equal "tv", HouseholdFinance::PurchaseQuestionText.item_label(text).downcase
    end
  end

  test "funding-description normalization retains the original shared purchase reading" do
    text = "thinkin of gettin a 1500 tv with money already set aside"
    reading = read(text, purchase_question: { amount: "1500", item: "tv" })
    HouseholdFinance::ParticipantMessageReader::Current.set(message: text, reading: reading) do
      assert HouseholdFinance::PurchaseQuestionText.read_only_purchase_question?(text)
    end
  end

  test "a purchase reading does not hide a separate debt decision" do
    text = "should i get a 700 phone or pay down my loan"
    reading = read(text, purchase_question: { amount: "700", item: "phone" })
    HouseholdFinance::ParticipantMessageReader::Current.set(message: text, reading: reading) do
      refute HouseholdFinance::PurchaseQuestionText.read_only_purchase_question?(text)
    end
  end

  test "future intentions cannot become completed facts even if the reader mislabels them" do
    [ "gonna put a $700 ps5 on my card", "gonna spend 12 at payless tomorrow", "spending 12 at payless tomorrow" ].each do |text|
      amount = text.include?("700") ? "$700" : "12"
      reading = read(text, facts: [ { kind: "purchase", amount: amount, merchant: "", item: "", day: "" } ])
      assert_empty reading.facts, text
    end
    reading = read("spent 12 today and gonna spend 40 tomorrow", facts: [ { kind: "purchase", amount: "12", merchant: "", item: "", day: "today" } ])
    assert_equal [ "12" ], reading.facts.pluck("amount")
  end

  test "completed action after abandoned future chatter remains a completed fact" do
    reading = read("i was gonna save 40 but spent 20 today", facts: [ { kind: "purchase", amount: "20", merchant: "", item: "", day: "today" } ])
    assert_equal [ "20" ], reading.facts.pluck("amount")
  end

  test "partial amounts are reported even alongside a valid fact" do
    reading = read("saved 10 today and like 5ish yesterday", facts: [ { kind: "set_aside", amount: "10", merchant: "", item: "", day: "today" }, { kind: "set_aside", amount: "5ish", merchant: "", item: "", day: "yesterday" } ])
    assert reading.unclear_amount
    assert_equal [ "10" ], reading.facts.pluck("amount")
  end

  test "goal and correction readings validate every money span" do
    reading = read("make my goal 600", goal_change: { amount: "600" })
    assert_equal "600", reading.goal_change["amount"]
    reading = read("oops the 25 i saved was really 20", savings_correction: { old_amount: "25", new_amount: "20", day: "" })
    assert_equal "20", reading.savings_correction["new_amount"]
    assert_empty read("make my goal 600", goal_change: { amount: "900" }).goal_change
  end

  test "merchant formatting keeps source evidence and normalizes review labels" do
    assert_equal "Payless", HouseholdFinance::PurchaseQuestionText.merchant_label("payless")
    assert_equal "Goodyear", HouseholdFinance::PurchaseQuestionText.merchant_label("goodyear")
    assert_equal "KIN", HouseholdFinance::PurchaseQuestionText.merchant_label("KIN")
  end

  test "shopping return language is distinct from refunds and money movements" do
    refute HouseholdFinance::TransactionDraftBuilder.non_expense_movement?("just got back from payless, dropped like 45 on groceries")
    [ "got $45 back from payless", "got 45 back from ross", "refund 45 at payless", "paid 45 on my visa", "put 45 into savings" ].each do |text|
      assert HouseholdFinance::TransactionDraftBuilder.non_expense_movement?(text), text
    end
  end

  test "halloween resolves on the participant calendar" do
    result = HouseholdFinance::ParticipantReportDay.call(day: "on halloween", message: "saved 20 on halloween", today: Date.new(2026, 11, 6))
    assert_equal Date.new(2026, 10, 31), result.date
  end
end
