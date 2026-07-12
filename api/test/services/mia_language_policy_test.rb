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
end
