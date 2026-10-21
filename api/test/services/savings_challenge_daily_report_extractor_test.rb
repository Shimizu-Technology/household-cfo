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
    assert_nil extract(message, reply(purchases: [ { amount: "-20", merchant: "Payless", day: "today" } ]))
    assert_nil extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: "today", counted: true } ]))
    assert_nil extract(message, reply.merge(approved: true))
    assert_nil extract(message, reply), "nothing to show"
    # The model's day counts only when the message names that day; otherwise it is today.
    %w[tomorrow yesterday 2026-10-22 2026-10-01].each do |day|
      assert_equal "2026-10-21", extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: day } ]))[:purchases].sole[:purchased_on], day
    end
    cleared = extract(message, reply(purchases: [ { amount: "20", merchant: "Ross", day: "today" } ]))
    assert_equal "", cleared[:purchases].sole[:merchant], "a place the participant never named is left for them to fill"
    %w[P ay Pay].each do |fragment|
      assert_equal "", extract(message, reply(purchases: [ { amount: "20", merchant: fragment, day: "today" } ]))[:purchases].sole[:merchant], fragment
    end
    long = extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: "today" } ], feeling_now: "x" * 141))
    assert_nil long[:feelings]
    invented = extract(message, reply(purchases: [ { amount: "20", merchant: "Payless", day: "today" } ], feeling_when_spent: "ashamed", feeling_now: "stuff"))
    assert_equal({ when_spent: nil, now: "stuff" }, invented[:feelings], "feelings are kept only in the participant's words")
    too_many = reply(purchases: Array.new(11) { { amount: "20", merchant: "Payless", day: "today" } })
    assert_nil extract(message, too_many)
  end

  test "amounts must be written as money with their cents, never read from dates, times or counts" do
    one = ->(message, amount) { extract(message, reply(purchases: [ { amount: amount, merchant: "", day: "today" } ])) }
    assert_nil one.call("grabbed a shirt at Ross 20.99", "20"), "20 from 20.99"
    assert_equal 2099, one.call("grabbed a shirt at Ross 20.99", "20.99")[:purchases].sole[:amount_cents]
    assert_nil one.call("grabbed lunch at Kings on Oct 20", "20"), "20 from Oct 20"
    assert_nil one.call("grabbed lunch for my 2 kids at Kings", "2"), "2 from 2 kids"
    assert_nil one.call("grabbed lunch at Kings at 12:30", "12.30"), "a time is not money"
    assert_equal 1200, one.call("grabbed lunch at Kings, 12 bucks", "12")[:purchases].sole[:amount_cents]
    assert_equal 1425, one.call("lunch w the kids came to 14.25 over at Kings", "14.25")[:purchases].sole[:amount_cents], "dollars and cents are money wherever they sit"
    assert_equal "2026-10-20", extract("grabbed lunch at Kings yesterday, 12 bucks", reply(purchases: [ { amount: "12", merchant: "Kings", day: "yesterday" } ]))[:purchases].sole[:purchased_on]
    # The participant's own day wins when the model disagrees.
    assert_equal "2026-10-20", extract("lunch w my cousins came to 12 at Kings yesterday", reply(purchases: [ { amount: "12", merchant: "Kings", day: "today" } ]))[:purchases].sole[:purchased_on]
    assert_nil extract("lunch w my cousins came to 12 at Kings yesterday", reply(purchases: [ { amount: "12", merchant: "Kings", day: 20 } ])), "a malformed day field is rejected"
    # A message naming two days: each purchase must take one of those days, and both must be used.
    two_days = "lunch w cousins came to 12 at Kings yesterday and dinner w friends came to 15 at Ross today"
    both = extract(two_days, reply(purchases: [ { amount: "12", merchant: "Kings", day: "yesterday" }, { amount: "15", merchant: "Ross", day: "today" } ]))
    assert_equal [ [ 1200, "2026-10-20" ], [ 1500, "2026-10-21" ] ], both[:purchases].map { |row| [ row[:amount_cents], row[:purchased_on] ] }
    assert_nil extract(two_days, reply(purchases: [ { amount: "12", merchant: "Kings", day: "today" }, { amount: "15", merchant: "Ross", day: "today" } ])), "never defaults a two-day message to today"
    assert_nil extract(two_days, reply(purchases: [ { amount: "12", merchant: "Kings", day: "2026-10-19" }, { amount: "15", merchant: "Ross", day: "today" } ])), "a day the message never named"
    assert_nil extract(two_days, reply(purchases: [ { amount: "12", merchant: "Kings", day: "yesterday" } ])), "every named day must be used"
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

  test "chat intake asks the extractor only when it could make a card" do
    calls = []
    extractor = Struct.new(:calls) { def call = (calls << :called; nil) }.new(calls)
    intake = ->(message) { SavingsChallenge::ChatIntake.new(@enrollment, message: message, extractor: extractor).call }
    assert_equal "daily_report", intake.call("$8 at Shell")[:kind]
    [ "should I spend 20 at Ross?", "I have 2 kids", "spent $9 last week at Shell", "paid 300 on my credit card", "I bought lunch with my cousins",
      "felt kind of guilty about lunch", "My car payment is $450", "Got 2 for 1 at Jamba", "My daughter turned 5 today" ].each { |message| intake.call(message) }
    assert_empty calls
    intake.call("bought lunch with my 3 cousins")
    intake.call("lunch w my cousins came to 12 at Kings")
    assert_equal 2, calls.length
  end
end
