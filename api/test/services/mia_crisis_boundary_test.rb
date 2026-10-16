require "test_helper"

class MiaCrisisBoundaryTest < ActiveSupport::TestCase
  test "hopeless language is recognized in everyday spellings" do
    [
      "I can't do this anymore. Every month I fall behind on bills.",
      "i cant take this no more",
      "Cant do this no more",
      "I can not do this anymore",
      "I can't do this.",
      "I give up.",
      "I gave up",
      "ugh i give up lol",
      "I'm done.",
      "im done",
      "I'm so hopeless about our money",
      "whats the point",
      "What's the point in trying anymore, the bills never stop",
      "I'm tired of everything",
      "I just wanna disappear",
      "I feel like a burden to my family"
    ].each do |message|
      assert Mia::CrisisBoundary.hopeless?(message), message
      assert_not Mia::CrisisBoundary.matches?(message), "#{message} should keep money help, not the crisis response"
    end
  end

  test "everyday money talk does not get the safety check" do
    [
      "Should I give up?",
      "Should I give up my gym membership?",
      "I want to give up dining out to save for the challenge",
      "I'm hopeless with money",
      "I'm hopeless at budgeting",
      "tired of everything costing so much",
      "I'm tired of trying to save",
      "is there any point in trying to save $5",
      "What's the point of a sinking fund?",
      "I wanna disappear from my creditors' call lists",
      "I can't do it, can you cut Dining Out instead?",
      "I'm done with takeout",
      "I can't do this budget alone, can you help me set it up?"
    ].each do |message|
      assert_not Mia::CrisisBoundary.hopeless?(message), message
    end
  end

  test "statements that others are better off without me are crisis language" do
    [
      "Everyone would be better off without me.",
      "Everyone's better off without me",
      "everyone is better off without me",
      "my kids are better off without me",
      "Nobody would miss me",
      "I want to go to sleep and not wake up"
    ].each do |message|
      assert Mia::CrisisBoundary.matches?(message), message
    end

    [
      "my kids would be better off without me buying junk food",
      "my family would be better off without me working nights"
    ].each do |message|
      assert_not Mia::CrisisBoundary.matches?(message), message
    end
  end

  test "the safety check is added once and a dollar amount is not mistaken for 988" do
    with_rent = Mia::CrisisBoundary.with_wellbeing_check("Your rent is $1,988 this month. Next CFO move: list what is due.")
    assert_includes with_rent, "call or text 988"

    already = "Please call or text 988 now if you might hurt yourself."
    assert_equal already, Mia::CrisisBoundary.with_wellbeing_check(already)

    scripted = Mia::CrisisBoundary.with_wellbeing_check("Start with the bill that protects the household baseline first.")
    assert scripted.start_with?(Mia::CrisisBoundary::WELLBEING_OPENING)
    assert_equal 1, scripted.scan("988").length
  end
end
