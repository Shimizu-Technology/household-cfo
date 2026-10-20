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
    [ "My income is $2,000 and essentials are $2,100. Can I save $500?", "Can I skip meals to save $500?", "Can I skip buying food this week so I can save more for the challenge?", "I cannot afford savings and I am behind on rent" ].each do |message|
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

  test "food insecurity in the challenge puts food ahead of savings and points to help" do
    with_savings_runtime do
      [ false, true ].each do |enrolled|
        savings_enroll if enrolled
        [ "We can't afford groceries this week", "My kids are skipping meals because we have no money", "We ran out of food and payday is Friday", "I have nothing to eat until payday" ].each do |message|
          response = answer(message)
          assert_includes response, "Food comes first, ahead of the savings challenge", message
          assert_includes response, "program team or a local food pantry", message
          refute_match(/\$\d+\.\d{2}|progress is/, response, message)
        end
      end
    end
    [ "Can I skip meals to save $500?", "I cannot afford savings and I am behind on rent", "Can we afford groceries this week?", "We can't afford to eat out anymore" ].each do |message|
      refute_includes answer(message), "local food pantry", message
    end
  end

  test "challenge deposits point to the contribution review and crypto buys are not purchase check-ins" do
    with_savings_runtime do
      savings_enroll
      [ "Transferred $100 to my challenge account", "Put $40 cash in my savings yesterday" ].each do |message|
        response = answer(message)
        assert_includes response, "Open Home to review a contribution", message
        refute_includes response, "For a purchase, enter the amount", message
      end
      [ "I spent $100 on crypto yesterday", "Bought $200 worth of bitcoin" ].each do |message|
        response = answer(message)
        assert_includes response, "not a purchase check-in, and it does not count as money reserved for the challenge", message
        assert_includes response, "cannot give licensed investment advice", message
      end
      assert_includes answer("I bought lunch yesterday"), "amount, where and date"

      household_answer = HouseholdFinance::MiaCoachAnswerer.new(@savings_household, "Paid $50 to Bank of Guam savings for the challenge", user: @savings_user).call
      assert_includes household_answer, "Putting $50 into savings counts as saving, not spending"
      assert_includes household_answer, "open Home and review it as a contribution"

      # Enrollment belongs to the participant, not to everyone in the household.
      partner = User.create!(clerk_id: "clerk_partner_#{SecureRandom.hex(6)}", email: "partner-#{SecureRandom.hex(6)}@example.com", role: "participant", invitation_status: "accepted")
      [ partner, nil ].each do |other|
        other_answer = HouseholdFinance::MiaCoachAnswerer.new(@savings_household, "Put $40 in my savings", user: other).call
        assert_includes other_answer, "Putting $40 into savings counts as saving, not spending"
        refute_includes other_answer, "open Home"
      end
    end
  end

  test "chat intake offers deposits as contributions and never turns crypto into a purchase" do
    with_savings_runtime do
      enrollment = savings_enroll
      intake = ->(message) { SavingsChallenge::ChatIntake.new(enrollment, message: message).call }

      deposit = intake.call("Put $40 in my savings today")
      assert_equal "contribution", deposit.fetch(:kind)
      assert_equal 4_000, deposit.fetch(:signed_cents)
      assert deposit.fetch(:new_money_confirmation_required)
      assert_equal "contribution", intake.call("Paid $50 to Bank of Guam savings today").fetch(:kind)
      assert_equal 150_000, intake.call("I set aside $1.5k today").fetch(:signed_cents)
      assert_nil intake.call("I bought $200 of bitcoin at Coinbase today")
      assert_nil intake.call("I'm going to put $40 in my savings today")
      [ "Set $200 for savings each month today", "Put $100 in the savings category today", "Kids want me to put $40 in savings today",
        "I usually put $50 in savings today", "I sent $200 to my mom's savings today", "I bought $50 of Apple stock today" ].each do |message|
        assert_nil intake.call(message), message
      end
      assert_equal "daily_report", intake.call("I spent $12 at Payless today").fetch(:kind)
      assert_equal "withdrawal", intake.call("I took $50 from savings today").fetch(:kind)
    end
  end

  private
  def answer(message)
    SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: @savings_enrollment, message: message).call
  end
end
