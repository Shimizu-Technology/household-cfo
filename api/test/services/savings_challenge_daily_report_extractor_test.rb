require "test_helper"

# The provider is always stubbed here: no live model calls.
class SavingsChallengeDailyReportExtractorTest < ActiveSupport::TestCase
  Enrollment = Struct.new(:starts_on, :ends_on, :local_today)
  TODAY = Date.new(2026, 10, 21)

  setup { @enrollment = Enrollment.new(Date.new(2026, 10, 5), Date.new(2027, 1, 2), TODAY) }

  def extract(message, response = nil, &transport)
    transport ||= ->(_payload) { response.is_a?(String) ? response : response.to_json }
    SavingsChallenge::DailyReportExtractor.new(@enrollment, message: message, api_key: nil, model: "openai/gpt-test", transport: transport).call
  end

  def reply(purchases: [], no_spend: false, feeling_when_spent: "", feeling_now: "")
    { purchases: purchases, no_spend: no_spend, feeling_when_spent: feeling_when_spent, feeling_now: feeling_now }
  end

  test "valid output becomes the same unreviewed daily report card" do
    message = "grabbed lunch w the girls, like 12.50 at Kings yesterday, kinda regret it, now im ok"
    seen = nil
    report = extract(message) do |payload|
      seen = payload
      reply(purchases: [ { amount: "12.50", merchant: "Kings", day: "yesterday" } ], feeling_when_spent: "kinda regret it", feeling_now: "ok").to_json
    end
    assert_equal({ kind: "daily_report", local_on: "2026-10-21", purchases: [ { amount_cents: 1250, merchant: "Kings", purchased_on: "2026-10-20" } ],
      no_spend: false, feelings: { when_spent: "kinda regret it", now: "ok" }, counted: false, approval_state: "unreviewed_input" }, report)
    assert_equal "json_schema", seen.dig(:response_format, :type)
    assert_includes seen[:messages].last[:content], message
  end

  test "a no-spend day needs the participant's own words and no purchases" do
    assert extract("nope, nothing today", reply(no_spend: true))[:no_spend]
    assert_nil extract("busy day at work", reply(no_spend: true))
    assert_nil extract("nothing today, ok 5 at Shell", reply(no_spend: true, purchases: [ { amount: "5", merchant: "Shell", day: "today" } ]))
  end

  test "invented amounts, places, days and extra fields are rejected or cleared" do
    message = "grabbed stuff at Payless for 20"
    assert_nil extract(message, reply(purchases: [ { amount: "25", merchant: "Payless", day: "today" } ])), "amount not in the message"
    assert_nil extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: "tomorrow" } ]))
    assert_nil extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: "2026-10-22" } ])), "future"
    assert_nil extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: "2026-10-01" } ])), "before the window"
    assert_nil extract(message, reply(purchases: [ { amount: "-20", merchant: "Payless", day: "today" } ]))
    assert_nil extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: "today", counted: true } ]))
    assert_nil extract(message, reply.merge(approved: true))
    assert_nil extract(message, reply), "nothing to show"
    cleared = extract(message, reply(purchases: [ { amount: "20", merchant: "Ross", day: "today" } ]))
    assert_equal "", cleared[:purchases].sole[:merchant], "a place the participant never named is left for them to fill"
    long = extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: "today" } ], feeling_now: "x" * 141))
    assert_nil long[:feelings]
    too_many = reply(purchases: Array.new(11) { { amount: "20", merchant: "Payless", day: "today" } })
    assert_nil extract(message, too_many)
  end

  test "invalid JSON, provider errors and timeouts fall back to nothing" do
    message = "grabbed stuff at Payless for 20"
    assert_nil extract(message, "not json")
    assert_nil extract(message, "[]")
    assert_nil(extract(message) { raise Net::ReadTimeout })
    assert_nil extract(message) { nil }, "denied provider admission returns no content"
  end

  test "without a provider key nothing is requested" do
    assert_nil SavingsChallenge::DailyReportExtractor.new(@enrollment, message: "grabbed stuff at Payless for 20", api_key: "").call
  end

  test "chat intake asks the extractor only when the parser found nothing plausible" do
    calls = []
    extractor = Struct.new(:calls) { def call = (calls << :called; nil) }.new(calls)
    intake = ->(message) { SavingsChallenge::ChatIntake.new(@enrollment, message: message, extractor: extractor).call }
    assert_equal "daily_report", intake.call("$8 at Shell")[:kind]
    intake.call("should I spend 20 at Ross?")
    intake.call("I have 2 kids")
    intake.call("spent $9 last week at Shell")
    intake.call("paid 300 on my credit card")
    assert_empty calls
    intake.call("I bought lunch with my cousins")
    intake.call("felt kind of guilty about lunch")
    assert_equal 2, calls.length
  end
end
