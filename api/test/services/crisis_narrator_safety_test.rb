require "test_helper"
require_relative "../support/reply_guard_test_helper"

class CrisisNarratorSafetyTest < ActiveSupport::TestCase
  include ReplyGuardTestHelper
  teardown { HouseholdFinance::ParticipantMessageReader::Current.reset }

  test "post-generation unread sensitive override retains crisis guidance in both narrators" do
    topic = HouseholdFinance::ParticipantCare.topic(:crisis).merge("disclosure" => "I have a gun in my room.")
    expected = HouseholdFinance::ParticipantCare.crisis_followup(topic)
    rewriter = Mia::ResponseShapeRewriter.method(:call)
    Mia::ResponseShapeRewriter.define_singleton_method(:call) do |*, **_|
      Mia::ResponseShapeRewriter::Result.new(content: "Talk with your landlord.",
        guard_result: Mia::ReplyGuard::Result.new([ "sensitive_moment" ], care: "hardship"))
    end
    [ HouseholdFinance::MiaNarrator, SavingsChallenge::Narrator ].each do |klass|
      [ "I can't pay my rent", "I lost my job", "My truck broke down and I can't get to work", "my mom just died" ].each do |message|
        narrator = klass.new(user_message: message, api_key: "synthetic-key",
          answer_packet: { kind: "coaching", care_context: topic, fallback_response: "Money can wait." })
        narrator.define_singleton_method(:openrouter_response) { expected }
        assert_equal expected, narrator.call, "#{klass}: #{message}"
        assert_equal "deterministic_safety", narrator.response_source
      end
    end
  ensure
    Mia::ResponseShapeRewriter.define_singleton_method(:call, rewriter) if rewriter
  end

  test "a model reply without hotline or means support is rejected during crisis" do
    topic = HouseholdFinance::ParticipantCare.topic(:crisis)
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "rent is overdue", api_key: "",
      answer_packet: { kind: "coaching", care_context: topic, fallback_response: "Money can wait." })
    [ "Contact your landlord.", "Please call 988. Is someone with you?" ].each do |reply|
      assert_equal :crisis_support_missing, narrator.send(:narration_rejection_reason, reply)
    end
    assert_includes narrator.call, "988"
    assert_includes narrator.call, "Put distance"
  end
end
