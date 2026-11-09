require "test_helper"

class MiaLanguagePolicyTest < ActiveSupport::TestCase
  teardown { HouseholdFinance::ParticipantMessageReader::Current.reset }

  def reader_says(message, intent:, care: "none", item: "")
    data = { care: care, facts: [], question: false, reply_intent: intent, setup_answer: { field: "none", value: "" }, correction: false, spending_preferences: [], purchase_question: { amount: "", item: item } }
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, transport: ->(_payload) { data.to_json })
    HouseholdFinance::ParticipantMessageReader::Current.message = message
    HouseholdFinance::ParticipantMessageReader::Current.reading = reading
  end

  def one_phrase(text, meaning, frequency: "as_needed")
    entry = { "text" => text, "meaning" => meaning, "allowed_contexts" => [ "general" ], "frequency" => frequency }
    Struct.new(:cultural_phrases, :all_cultural_phrases).new([ entry ], [ entry ])
  end

  def reader_win(message)
    data = { care: "none", facts: [], question: false, reply_intent: "win", setup_answer: { field: "none", value: "" }, correction: false, spending_preferences: [] }
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, transport: ->(_payload) { data.to_json })
    HouseholdFinance::ParticipantMessageReader::Current.message = message
    HouseholdFinance::ParticipantMessageReader::Current.reading = reading
  end

  test "an explicit unfunded card swipe fits a caution phrase even when reader intent is none" do
    phrase = { "text" => "Chelu, pump the brakes.", "meaning" => "if someone is bout to charge something they cant cover", "allowed_contexts" => [ "general" ], "frequency" => "as_needed" }
    persona = Struct.new(:cultural_phrases, :all_cultural_phrases).new([ phrase ], [ phrase ])
    assert_equal phrase["text"], Mia::LanguagePolicy.new(user_message: "ima charge a 180 purse this week even tho i cant pay it off rn", persona: persona).server_phrase
  end

  test "published general phrase meanings follow the reader intent and frequency" do
    phrase = { "text" => "Small wins count, chelu.", "meaning" => "when they do good", "allowed_contexts" => [ "general" ], "frequency" => "as_needed" }
    persona = Struct.new(:cultural_phrases, :all_cultural_phrases).new([ phrase ], [ phrase ])
    message = "packed my lunch all week yay"
    reader_win(message)
    policy = Mia::LanguagePolicy.new(user_message: message, persona: persona, history: [ { role: "assistant", content: phrase["text"] } ])
    assert_equal phrase["text"], policy.server_phrase
    phrase["frequency"] = "sparing"
    assert_nil Mia::LanguagePolicy.new(user_message: message, persona: persona, history: [ { role: "assistant", content: phrase["text"] } ]).server_phrase
  end

  test "win phrases require a reader win even when milestone words or the phrase occur" do
    phrase = { "text"=>"Small wins count, chelu.", "meaning"=>"Celebrate a win", "allowed_contexts"=>[ "milestone" ], "frequency"=>"as_needed" }
    persona = Struct.new(:cultural_phrases, :all_cultural_phrases).new([ phrase ], [ phrase ])
    [ "they said no raise this year", "i never paid off my card", "i paid off my card finally", "they said no raise this year. Small wins count, chelu." ].each do |message|
      HouseholdFinance::ParticipantMessageReader::Current.reset
      assert_nil Mia::LanguagePolicy.new(user_message: message, persona: persona).server_phrase, message
    end
  ensure
    HouseholdFinance::ParticipantMessageReader::Current.reset
  end

  test "R2 ordinary shared phrase words are not variants and broken stripped clauses disappear" do
    phrase = { "text" => "Small wins count, chelu.", "meaning" => "Win", "allowed_contexts" => [ "win" ], "prohibited_contexts" => [], "frequency" => "as_needed" }
    persona = Struct.new(:cultural_phrases, :all_cultural_phrases).new([ phrase ], [ phrase ])
    policy = Mia::LanguagePolicy.new(user_message: "what counts", persona: persona)
    assert_nil policy.model_phrase_rejection_reason("That doesn't count as savings.")
    assert_equal "What will you try?", policy.remove_model_phrases("That's a real win, and Small wins count, chelu., so keep going. What will you try?")
  end

  test "a coach's own words for a win deliver her phrase on a real win" do
    [ "if they did something good even small i say", "when she sticks to it", "for the little victories", "when somebody makes progress", "whenever they do right by themselves" ].each do |meaning|
      message = "took my lunch to work all wk"
      reader_win(message)
      assert_equal "Small wins count, chelu.", Mia::LanguagePolicy.new(user_message: message, persona: one_phrase("Small wins count, chelu.", meaning)).server_phrase, meaning
    end
  end

  test "a win phrase stays off messages that are not wins" do
    message = "how much is left this month"
    reader_says(message, intent: "none")
    assert_nil Mia::LanguagePolicy.new(user_message: message, persona: one_phrase("Small wins count, chelu.", "if they did something good even small i say")).server_phrase
  end

  test "the reader's caution reading delivers the phrase however she says she is short" do
    persona = one_phrase("Chelu, pump the brakes.", "when somebody wanna swipe for something they cant cover i tell them")
    [ "gonna grab a 60 perfume at the mall im low on cash rn", "wanna put a 450 phone on my card, aint got the cash", "thinkin bout them 75 slippers, wallet empty til the 15th" ].each do |message|
      reader_says(message, intent: "purchase_caution", item: "phone")
      assert_equal "Chelu, pump the brakes.", Mia::LanguagePolicy.new(user_message: message, persona: persona).server_phrase, message
    end
  end

  test "a funded purchase question does not get the caution phrase" do
    message = "thinkin of gettin a 300 tv, i saved up for it already"
    reader_says(message, intent: "purchase_question", item: "tv")
    assert_nil Mia::LanguagePolicy.new(user_message: message, persona: one_phrase("Chelu, pump the brakes.", "when somebody wanna swipe for something they cant cover i tell them")).server_phrase
  end

  test "her phrase never lands on a hard moment even with a caution reading" do
    persona = one_phrase("Chelu, pump the brakes.", "when somebody wanna swipe for something they cant cover i tell them")
    message = "im behind on rent n thinkin of puttin groceries on the card, im scared"
    reader_says(message, intent: "purchase_caution", care: "hardship", item: "groceries")
    assert_nil Mia::LanguagePolicy.new(user_message: message, persona: persona).server_phrase
    message = "wanna swipe for a new car seat, no money til friday"
    reader_says(message, intent: "purchase_caution", item: "car seat")
    assert_nil Mia::LanguagePolicy.new(user_message: message, persona: persona).server_phrase
  end

  test "the reader's caution reading counts as a purchase question and as unfunded" do
    message = "wanna get them shoes, broke til payday"
    reader_says(message, intent: "purchase_caution")
    assert HouseholdFinance::MessageReplyIntent.purchase_question?(message)
    assert HouseholdFinance::PurchaseQuestionText.unfunded?(message)
    refute HouseholdFinance::PurchaseQuestionText.unfunded?("wanna get them shoes")
  end

  test "CR3 legacy crisis-allowed phrases never reach a crisis reply" do
    phrase = { "text" => "One small step", "meaning" => "A phrase", "allowed_contexts" => [ "crisis" ], "prohibited_contexts" => [], "frequency" => "rare" }
    persona = Struct.new(:cultural_phrases, :all_cultural_phrases).new([ phrase ], [ phrase ])
    result = Mia::LanguagePolicy.new(user_message: "I want to die", persona: persona).sanitize("One small step. Please reach someone now.")
    refute_includes result, "One small step"
  end

  test "a repeated store visit permits accountability but recall does not" do
    assert Mia::LanguagePolicy.new(user_message: "I went to Ross again").cultural_language_allowed?
    refute Mia::LanguagePolicy.new(user_message: "What was that Ross amount again?").cultural_language_allowed?
  end

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
    reader_win("I finally paid off my credit card!")
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

  test "wording rules for just, simply and par live in the prompt, so real names pass through unchanged" do
    policy = Mia::LanguagePolicy.new(user_message: "What did we spend?")
    [
      "Just Desserts was $18 and Simply Orange was $4.",
      "Par 3 Golf is in Discretionary. Just pay the minimum.",
      "Simply Gum is $4.\nYou are on par, ok."
    ].each { |text| assert_equal text.gsub("\n", " "), policy.sanitize(text) }
  end
  test "model phrase removal preserves coaching and leaves eligibility to the server" do
    phrase = { "text" => "Small wins count, chelu.", "meaning" => "Celebrate a win", "allowed_contexts" => [ "milestone" ], "frequency" => "as_needed" }
    persona = Struct.new(:cultural_phrases, :all_cultural_phrases).new([ phrase ], [ phrase ])
    [ "I paid off my card", "What is my plan?", "I cannot pay rent" ].each do |message|
      policy = Mia::LanguagePolicy.new(user_message: message, persona: persona)
      reply = policy.remove_model_phrases("That took real effort. Small wins count, chelu. What helped you keep going?")
      assert_equal "That took real effort. What helped you keep going?", reply
      assert_nil policy.model_phrase_rejection_reason(reply)
      assert_equal "That took real effort. What helped?", policy.remove_model_phrases("That took real effort, and small wins count, chelu. What helped?")
    end
  end
  test "as needed differs from sparing and wins can use their own phrase" do
    reader_win("I paid off my card!")
    phrase = { "text" => "Small wins count, chelu.", "meaning" => "Celebrate a win", "allowed_contexts" => [ "milestone" ], "frequency" => "as_needed" }
    persona = Struct.new(:cultural_phrases, :all_cultural_phrases).new([ phrase ], [ phrase ])
    history = [ { role: "assistant", content: phrase["text"] } ]
    assert_equal phrase["text"], Mia::LanguagePolicy.new(user_message: "I paid off my card!", history: history, persona: persona).server_phrase
    phrase["frequency"] = "sparing"
    assert_nil Mia::LanguagePolicy.new(user_message: "I paid off my card!", history: history, persona: persona).server_phrase
  end
end
