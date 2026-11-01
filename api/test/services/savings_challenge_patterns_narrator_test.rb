require "test_helper"

class SavingsChallengePatternsNarratorTest < ActiveSupport::TestCase
  REFERENCE = "From Aug to Oct in the recorded purchases, Ross ($600) and Kmart ($360) were your biggest flexible spends. 25 small buys of $25 or less stacked up around Friday through Sunday — $227.99 altogether. Spending half as much at Ross could free about $100 a month, based on the months recorded. Would you feel more comfortable cutting back on Ross or Kmart?".freeze

  def narrator
    SavingsChallenge::PatternsNarrator.new(user_message: "What patterns do you see?", persona: Mia::Persona.default,
      api_key: "fictional", answer_packet: { kind: "challenge_patterns", write_state: "no_write", fallback_response: REFERENCE,
        verified_facts: { merchants: [ { label: "Ross", total_cents: 60_000 }, { label: "Kmart", total_cents: 36_000 } ],
          cluster: { purchase_count: 25, total_cents: 22_799, label: "Friday through Sunday" },
          choices: [ { merchant: "Ross", monthly_impact_cents: 10_000 } ], months_with_purchases: %w[Aug Sep Oct], missing_months: false } })
  end

  test "uses the assigned persona and accepts concise narration with exact figures" do
    subject = narrator
    payload = subject.send(:payload)
    assert_equal Mia::Persona.default.system_prompt, payload[:messages].first[:content]
    content = "Ross ($600) and Kmart ($360) led your flexible spending from Aug to Oct. Those 25 buys of $25 or less on Friday through Sunday added up to $227.99, a little end-of-week waterfall. Halving Ross could free about $100 a month. Would you feel more comfortable pulling back on Ross or Kmart?"
    subject.define_singleton_method(:openrouter_response) { content }
    assert_equal content, subject.call
  end

  test "falls back for new figures, swapped totals, subscriptions and long replies" do
    [ REFERENCE.sub("Would you", "You made twelve purchases at Ross. Would you"),
      REFERENCE.sub("Would you", "The $100 is also from Kmart. Would you"), REFERENCE.sub("$227.99", "$228"), REFERENCE.sub("Aug to Oct", "Sep to Nov"), REFERENCE.sub("25 small", "26 small"),
      REFERENCE.sub("Ross ($600) and Kmart ($360)", "Ross ($360) and Kmart ($600)"),
      REFERENCE.sub("at Ross could free", "at Kmart could free"),
      REFERENCE.sub("Spending half as much at Ross could free about $100 a month, based on the months recorded.", "Unlike Ross, halving Kmart could free about $100 a month."), REFERENCE.sub("25 small buys", "Small buys"),
      REFERENCE + " Ross is a subscription.", REFERENCE + " Here is more. And more." ].each do |content|
      subject = narrator
      subject.define_singleton_method(:openrouter_response) { content }
      assert_equal REFERENCE, subject.call, content
    end
  end

  test "provider failures keep the concise deterministic answer" do
    subject = narrator
    subject.define_singleton_method(:openrouter_response) { raise IOError, "offline" }
    assert_equal REFERENCE, subject.call
  end
end
