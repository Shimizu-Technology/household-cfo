require "test_helper"

class MiaFallbackReplyChallengeTest < ActiveSupport::TestCase
  PERSONA = Mia::Persona.default

  def reply(program: nil)
    context = JSON.generate(
      metrics: { "readiness" => "unavailable_until_setup_complete", "safe_to_spend" => nil },
      debts: { "records" => [] },
      program: program
    )
    Mia::FallbackReply.new(reason: :reply_rejected, message: "i feel hopeless about money", context: context,
      persona: PERSONA, hopeless: true).call
  end

  test "hopeless reply in the savings challenge gives a small challenge step, not setup" do
    text = reply(program: { "experience_mode" => "savings_challenge" })

    assert_includes text, "One small step for this week"
    assert_includes text, "smaller or later target"
    refute_match(/setup|income|readiness/i, text)
  end

  test "hopeless reply outside the challenge is unchanged" do
    text = reply

    assert_includes text, Mia::FallbackReply::HOPELESS_STEP
    assert_includes text, "setup essentials are not finished"
  end
end
