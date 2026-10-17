require "test_helper"

class MiaLanguagePolicyTest < ActiveSupport::TestCase
  test "removes cultural language from routine financial explanations" do
    result = Mia::LanguagePolicy.new(user_message: "Why is my readiness red?").sanitize(
      "Your approved readiness is Red, chelu. Lanya, runway is below the threshold."
    )

    assert_equal "Your approved readiness is Red. Runway is below the threshold.", result
  end

  test "removes generic praise from an ordinary response" do
    result = Mia::LanguagePolicy.new(user_message: "How much is pending?").sanitize(
      "You're doing great. Two drafts are pending. You've got this! Review them before actuals change."
    )

    assert_equal "Two drafts are pending. Review them before actuals change.", result
  end

  test "allows restrained cultural language for a participant milestone" do
    result = Mia::LanguagePolicy.new(user_message: "I finally paid off my credit card!").sanitize(
      "Lanya, that payoff is a real milestone, chelu. Protect the freed-up payment in your plan."
    )

    assert_equal "Lanya, that payoff is a real milestone, chelu. Protect the freed-up payment in your plan.", result
  end

  test "allows a cultural greeting when the participant uses one" do
    result = Mia::LanguagePolicy.new(user_message: "Håfa Adai, Mia").sanitize(
      "Håfa Adai! Tell me the money decision you want to work through."
    )

    assert_equal "Håfa Adai! Tell me the money decision you want to work through.", result
  end

  test "suppresses cultural language when Mia recently used it" do
    result = Mia::LanguagePolicy.new(
      user_message: "I finally paid off my credit card!",
      history: [ { role: "assistant", content: "Biba! That was a real milestone." } ]
    ).sanitize("That is a meaningful win, chelu. Protect the freed-up payment next.")

    assert_equal "That is a meaningful win. Protect the freed-up payment next.", result
  end

  test "routine verbs and repeated mistakes do not earn generic praise" do
    result = Mia::LanguagePolicy.new(user_message: "I hit the spending limit again").sanitize(
      "You're doing great. Umbee gachong, this is the same spending pattern. Pause the next purchase."
    )

    assert_equal "Umbee gachong, this is the same spending pattern. Pause the next purchase.", result
  end

  test "common meeting language does not count as a milestone" do
    result = Mia::LanguagePolicy.new(user_message: "I met with my partner about the budget").sanitize(
      "Great job. That conversation gives you a shared starting point, chelu."
    )

    assert_equal "That conversation gives you a shared starting point.", result
  end

  test "ordinary requests to repeat an explanation do not trigger accountability language" do
    result = Mia::LanguagePolicy.new(user_message: "Can you explain that again?").sanitize(
      "Of course, chelu. Your approved readiness is Red because runway is below the threshold."
    )

    assert_equal "Of course. Your approved readiness is Red because runway is below the threshold.", result
  end

  test "again still qualifies when it clearly describes a repeated financial action" do
    policy = Mia::LanguagePolicy.new(user_message: "I bought takeout again after saying I would stop")

    assert policy.cultural_language_allowed?
  end

  test "removes just and simply used to minimize effort but keeps ordinary uses" do
    policy = Mia::LanguagePolicy.new(user_message: "How do I fix the name?")
    assert_equal "Edit it to \"Cruz Ohana\".", policy.sanitize("Edit it to just \"Cruz Ohana\".")
    assert_equal "Send me the amount.", policy.sanitize("Just send me the amount.")
    assert_equal "Pay the minimum first.", policy.sanitize("Simply pay the minimum first.")
    assert_equal "That is not just the minimum, it is the full balance.", policy.sanitize("That is not just the minimum, it is the full balance.")
    assert_equal "Rent was due just now.", policy.sanitize("Rent was due just now.")
  end

  test "never calls the participant par but leaves on par alone" do
    policy = Mia::LanguagePolicy.new(user_message: "How are we doing?")
    assert_equal "You are on track.", policy.sanitize("You are on track, par.")
    assert_equal "Spending is on par with last month.", policy.sanitize("Spending is on par with last month.")
  end

  test "plain_text unwraps markdown and list markers" do
    text = "**Here is the plan**\n- Pay rent\n- Save $50\n1. Review Friday"
    assert_equal "Here is the plan Pay rent. Save $50. Review Friday.", Mia::LanguagePolicy.plain_text(text)
  end
end
