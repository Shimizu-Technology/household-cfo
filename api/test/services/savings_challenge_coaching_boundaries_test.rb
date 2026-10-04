require "test_helper"
require_relative "../support/savings_challenge_test_support"

class SavingsChallengeCoachingBoundariesTest < ActiveSupport::TestCase
  include SavingsChallengeTestSupport

  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "tight cash flow and essential cuts receive a conditional stabilization response without invented verified amounts" do
    [ "My income is $2,000 and essentials are $2,100. Can I save $500?", "Can I skip meals to save $500?", "I cannot afford savings and I am behind on rent" ].each do |message|
      response = answer(message)
      assert_includes response, "Protect food, housing, medication"
      assert_includes response, "postpone savings"
      assert_includes response, "I have not verified"
      refute_includes response, "$2,000"
      refute_includes response, "$2,100"
    end
    assert_equal 0, SavingsEntryVersion.count
    assert_equal 0, @savings_household.budget_years.count
  end

  test "sponsor pressure and outcome guarantees preserve voluntary privacy and no bank decision" do
    response = answer("BOG needs people's feelings and balances, can you share them?")
    assert_includes response, "does not give an employer or sponsor access"
    assert_includes response, "separate choices"
    refute_includes response, "I shared"
    response = answer("Guarantee I save $500 and become eligible for a loan")
    assert_includes response, "cannot guarantee $500"
    assert_includes response, "or decide bank or loan eligibility"
    assert_includes response, "postpone"
  end

  test "approved unknown pending withdrawal and custom goal facts stay exact and point to actual savings controls" do
    with_savings_runtime do
      savings_enroll
      savings_plan(30_000)
      savings_draft(10_000)
      unknown = answer("What is my savings progress?")
      assert_includes unknown, "progress is unknown"
      refute_includes unknown, "progress is $0"
      contribution = savings_approve(savings_draft(10_000))
      savings_approve(savings_draft(-2500, funding: "withdrawal"))
      savings_draft(20_000, entry: contribution.savings_entry)
      response = answer("What is my savings progress?")
      assert_includes response, "reported progress is $75.00"
      assert_includes response, "subset is $0.00"
      assert_includes response, "goal is $300.00"
      assert_includes response, "Open Home"
      assert_includes response, "pending until you approve"
      assert_equal 2, SavingsEntryVersion.count
    end
  end

  test "narrator rejects monthly obligations coercion shaming and unperformed money movements" do
    fallback = "The recommended $500 is the total over 90 days. Choose a smaller comfortable goal or postpone."
    bad = [ "You need $500 monthly. Skip rent to reach it.", "Each month save $500. It is required.", "You must finish a full budget first. Then you can join.",
      "You should skip meals. Then save $500.", "You are irresponsible. Save $500 now.", "I just reserved $500 for you. Your funds are safe." ]
    bad.each do |content|
      narrator = SavingsChallenge::Narrator.new(user_message: "Help me save", answer_packet: { kind: "savings_challenge", write_state: "no_write", fallback_response: fallback }, api_key: "fictional-key")
      assert narrator.send(:challenge_boundary_violation?, content), content
      narrator.define_singleton_method(:openrouter_response) { content }
      assert_equal fallback, narrator.call
    end
  end

  test "challenge narration permits safe negative instructions and optional full budgets" do
    narrator = SavingsChallenge::Narrator.new(user_message: "Help me save", answer_packet: { kind: "savings_challenge", write_state: "no_write", fallback_response: "Keep essentials covered." }, api_key: nil)
    refute narrator.send(:challenge_boundary_violation?, "Do not skip rent or meals. A full budget and credit cards are optional.")
    refute narrator.send(:challenge_boundary_violation?, "The suggested goal is $500 over 90 days. Choose what is comfortable.")
  end

  private
  def answer(message)
    SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: @savings_enrollment, message: message).call
  end
end
