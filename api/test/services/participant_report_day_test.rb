require "test_helper"

class ParticipantReportDayTest < ActiveSupport::TestCase
  def intake(text, kind:, day: "")
    data = { care: "none", question: false, correction: false, facts: [ { kind: kind, amount: "20", merchant: "", item: "", day: day } ], setup_answer: { field: "none", value: "" }, spending_preferences: [] }
    reading = HouseholdFinance::ParticipantMessageReader.call(message: text, transport: ->(_) { data.to_json })
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.new(2026, 10, 1), Date.new(2026, 12, 31), Date.new(2026, 11, 6))
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: reading)
    parser.call
    parser
  end

  test "quoted or omitted past day phrases never become today" do
    { "last friday"=>"2026-10-30", "two days ago"=>"2026-11-04", "on monday"=>"2026-11-02", "October 20"=>"2026-10-20" }.each do |phrase, date|
      [ phrase, "" ].each do |quoted|
        parser=intake("saved 20 #{phrase}", kind: "set_aside", day: quoted)
        assert_equal date, parser.intakes.sole[:effective_on], phrase
      end
    end
  end

  test "an unresolved stated day leaves a review date empty instead of guessing" do
    parser=intake("saved 20 last week", kind: "set_aside", day: "last week")
    assert_equal "", parser.intakes.sole[:effective_on]
    assert_equal true, parser.intakes.sole[:date_required]
    parser=intake("spent 20 recently", kind: "purchase", day: "recently")
    assert_equal "", parser.intakes.sole.dig(:purchases, 0, :purchased_on)
  end

  test "no stated day matches main savings and purchase behavior" do
    assert_empty intake("saved 20", kind: "set_aside").intakes
    assert_equal "2026-11-06", intake("spent 20", kind: "purchase").intakes.sole[:local_on]
  end
end
