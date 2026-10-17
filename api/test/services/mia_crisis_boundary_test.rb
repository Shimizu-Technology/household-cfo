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
      "im so done with everything",
      "I'm done with it all",
      "i cant even anymore",
      "I can't anymore",
      "no point anymore",
      "whats even the point",
      "I just want it all to stop",
      "I'm so hopeless about our money",
      "whats the point",
      "What's the point in trying anymore, the bills never stop",
      "I'm tired of everything",
      "I just wanna disappear",
      "I feel like a burden to my family",
      "I don't want to be here anymore, this apartment is too expensive",
      "I want it to be over",
      "i dont see the point anymore",
      "I don't want to wake up, it's Monday lol",
      "i wish i wasnt here, prices in guam are crazy",
      "Should I give up because I feel hopeless?",
      "ugh we're so behind on everything, i feel like such a failure and hopeless honestly",
      "i feel like such a failure"
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
      "I'm done, I added all the receipts",
      "I'm done, what's next?",
      "I'm done!",
      "Im giving up on this budget",
      "I'm done paying this card off early",
      "I can't do this anymore with my budget",
      "no point anymore in keeping Netflix",
      "No point anymore paying for Hulu",
      "there's no point anymore in the coupon app",
      "I just want it all to stop going up",
      "I just want everything to stop costing so much",
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
      "i don't wanna be here anymore",
      "i dont want to be here anymore",
      "i'm done with life",
      "what's the point of living",
      "everyone would be better off if i was gone",
      "they'd all be better off without me",
      "my kids are better off without me tbh",
      "honestly everyone would be better off without me lol",
      "the kids r better off without me",
      "I want to go to sleep and not wake up",
      "Im done living",
      "I don't want to wake up tomorrow",
      "I wish I wasn't here",
      "no point in living",
      "i see no point in living",
      "its not worth living",
      "life isnt worth it",
      "I don't want to exist anymore",
      "i cant do life anymore",
      "i wanna kms fr",
      "lowkey want to kms",
      "i might unalive myself",
      "thinking of offing myself",
      "i wanna die",
      "honestly im gonna end it",
      "i wanna just die"
    ].each do |message|
      assert Mia::CrisisBoundary.matches?(message), message
    end

    [
      "my kids would be better off without me buying junk food",
      "my family would be better off without me working nights",
      "the kms on my car are adding up",
      "drove 40 kms to work",
      "my phone is gonna die",
      "this budget is killing me lol",
      "im gonna end it with my old bank and switch",
      "I'm done with life insurance, can I cancel it?",
      "I'm done with living paycheck to paycheck",
      "What's the point of life insurance?",
      "whats the point of living paycheck to paycheck",
      "what's the point of living on a budget if prices keep rising",
      "I don't wanna be here anymore at this job",
      "I don't want to be here anymore, this apartment is too expensive"
    ].each do |message|
      assert_not Mia::CrisisBoundary.matches?(message), message
    end
  end

  test "the safety check is added once and a dollar amount is not mistaken for 988" do
    [ "Your rent is $1,988 this month. Next CFO move: list what is due.", "Your rent is 988 dollars. Next CFO move: list what is due." ].each do |reply|
      assert_includes Mia::CrisisBoundary.with_wellbeing_check(reply), "call or text 988", reply
    end

    [ "Please call or text 988 now if you might hurt yourself.", "You can call or text 988.", "Call or text 988, the Lifeline." ].each do |already|
      assert_equal already, Mia::CrisisBoundary.with_wellbeing_check(already)
    end

    scripted = Mia::CrisisBoundary.with_wellbeing_check("Start with the bill that protects the household baseline first.")
    assert scripted.start_with?(Mia::CrisisBoundary::WELLBEING_OPENING)
    assert_equal 1, scripted.scan("988").length
  end
  test "explicit safety and plan statements are crisis phrasing" do
    [ "i am not safe", "im not safe", "im not safe rn", "i am not safe at home tonight", "I'm not safe right now", "i'm not safe tonight.", "i have a plan to kill myself",
      "I have a plan to end it", "i have a plan to end my life", "i'm going to end it tonight" ].each do |message|
      assert Mia::CrisisBoundary.matches?(message), message
    end
    [ "I have a plan for my budget", "my plan is to save $20", "I have a plan to pay off the card", "I'm not safe to drive on bald tires, need money for tires",
      "is it safe to keep cash at home", "I have a plan" ].each do |message|
      assert_not Mia::CrisisBoundary.matches?(message), message
    end
  end

  test "a bare plan statement is crisis only right after distress" do
    assert Mia::CrisisBoundary.plan_followup?("i have a plan", "i want to die")
    assert Mia::CrisisBoundary.plan_followup?("Yes, I have a plan.", "i dont see the point anymore")
    assert_not Mia::CrisisBoundary.plan_followup?("i have a plan", "how much is left in groceries")
    assert_not Mia::CrisisBoundary.plan_followup?("i have a plan", nil)
    assert_not Mia::CrisisBoundary.plan_followup?("I have a plan for my budget", "i want to die")
  end
  test "death wishes and texting forms are crisis phrasing" do
    [ "i'd be better off dead", "id be better off dead", "i’d be better off dead.", "i dont wanna be alive", "i don't want to be alive", "i don't want to be here anymore",
      "I don't wanna be alive", "i feel like dying", "i'm thinking of ending things", "thinking about ending it all", "wanna unalive",
      "i want to unalive", "kys", "KYS", "kys lol", "i wish i was dead" ].each do |message|
      assert Mia::CrisisBoundary.matches?(message), message
    end
  end

  test "softer despair gets the gentle check, not the crisis reply" do
    [ "i dont want to be here", "i dont wanna be here.", "i wish i could just not exist",
      "i wish i could disappear", "whats the point of anything", "nothing matters anymore", "nothing matters" ].each do |message|
      assert Mia::CrisisBoundary.hopeless?(message), message
      assert_not Mia::CrisisBoundary.matches?(message), message
    end
  end

  test "money talk with the same words is left alone" do
    # Borderline, decided: "I don't want to be here when the bill comes lol" names
    # a situation, so it does not match; the hopeless phrase must end its clause.
    [ "I don't want to be here when the bill comes lol", "this budget is killing me", "I'm dying to try that restaurant", "skys the limit",
      "I don't want to be here at the store all day", "the point of the challenge is saving", "the kys tool", "what is the point of the sinking fund",
      "I feel like dying of embarrassment", "thinking about ending it with my landlord" ].each do |message|
      assert_not Mia::CrisisBoundary.matches?(message), message
      assert_not Mia::CrisisBoundary.hopeless?(message), message
    end
  end
  test "review round: wider phrasings and typos are crisis" do
    [ "I feel like dying today", "i feel like dying rn", "im better off dead", "i'm better off dead", "ending it all tonight",
      "thinking about ending things with my life", "i have a plan to end it tonight", "i have a plan to die", "i have a plan to end my life",
      "i got a plan to hurt myself", "i have a plan for suicide", "i dnt wanna be alive", "i dont wana live", "i am not saf",
      "i dont want to live anymore", "i don't wanna live.", "i dont wanna live anymore, rent is too high", "wanna unalive", "i'm gonna unalive myself" ].each do |message|
      assert Mia::CrisisBoundary.matches?(message), message
    end
  end

  test "review round: money talk with kill, end, live and unalive is left alone" do
    [ "I have a plan to kill my debt by December", "i have a plan to kill the debt", "i have a plan to end it with the gym",
      "i have a plan to die down spending", "i got a plan for ending things with comcast", "i dont wanna live paycheck to paycheck",
      "i dont wanna live with debt", "i dont wanna live in this apartment", "i dont wanna live here anymore, rent is too high",
      "i don't want to live on ramen", "gonna unalive that card lol", "need to unalive the subscription", "thinking about ending things with comcast",
      "I'm not safe to drive on these tires" ].each do |message|
      assert_not Mia::CrisisBoundary.matches?(message), message
    end
  end

  test "the model's 988 sentence is never stripped from a reply after a prior crisis message" do
    history = [ { role: "user", content: "i wanna kms fr" }, { role: "assistant", content: Mia::CrisisBoundary.response } ]
    reply = "That sounds heavy. Please call or text 988 right now. Your power bill can wait."
    responder = Demo::MiaResponder.new(api_key: "test-key")
    [
      "i dont want to be here", "i'd be better off dead", "i have a plan", "i am not safe", "kys lol",
      "I'm not okay", "yes i still feel that way", "power bill due tomorrow"
    ].each do |message|
      assert_includes responder.send(:sanitize_assistant_content, reply, user_message: message, history: history), "988", message
    end
  end
end
