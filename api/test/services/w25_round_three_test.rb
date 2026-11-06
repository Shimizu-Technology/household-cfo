require "test_helper"

class W25RoundThreeTest < ActiveSupport::TestCase
  EXPLICIT = [ "i really want to kill myself", "i just wanna die", "im going to slit my wrists", "gonna swallow all my meds tonight", "i got a gun and im going to use it on myself", "i took a whole bottle of tylenol just now", "im gonna k1ll myself",
    *%w[really just honestly seriously actually].product([ "kill myself", "die", "hang myself", "hurt myself" ]).map { |adverb, action| "i #{adverb} want to #{action}" },
    "ijustwannadie", "i rlly want to k1ll myself", "ireallywanttokillmyself" ].freeze
  SAFETY_NET = [ "paid it all off for my kids so theres no reason to keep going now. goodbye", "the debt dies with me right? asking for real", "might as well be dead with these bills", "this will be my last budget", "im a burden on my kids with all this debt" ].freeze
  SOFT = [ "better off if i just wasnt here", "driving off the road", "not making it to christmas", "tired of being here", "better off w the insurance money", "last budget" ].freeze
  ORDINARY = [ "pills cost 30 this month", "my pills need a refill", "that car note is a real burden", "my tax burden went up", "my money vanished", "my savings disappeared", "i wont be around on friday", "i wont be around because im traveling", "i have a tax burden", "my 200 dollars vanished" ].freeze

  teardown { HouseholdFinance::ParticipantMessageReader::Current.reset }

  def with_method(object, name, replacement)
    original = object.method(name)
    object.define_singleton_method(name, replacement)
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  test "plain explicit variants never wait for a reader" do
    with_method(HouseholdFinance::ParticipantMessageReader, :read_once, ->(**_) { flunk "explicit called reader" }) do
      EXPLICIT.each { |text| assert Mia::CrisisBoundary.explicit?(text), text; assert Mia::CrisisBoundary.matches?(text), text }
    end
  end

  test "death farewell last and personal burden retain a net after none or shame" do
    %w[none shame].each do |care|
      SAFETY_NET.each do |text|
        result = HouseholdFinance::ParticipantMessageReader.call(message: text, transport: ->(_) { { care: care }.to_json })
        HouseholdFinance::ParticipantMessageReader::Current.message = text
        HouseholdFinance::ParticipantMessageReader::Current.reading = result
        refute Mia::CrisisBoundary.matches?(text), text
        assert Mia::CrisisBoundary.hopeless?(text), text
        assert_includes Mia::CrisisBoundary.with_wellbeing_check("We can talk through the next step."), "988"
      end
    end
  end

  test "clear ambiguous families reach the outage floor" do
    SOFT.each do |text|
      assert Mia::CrisisBoundary.soft?(text), text
      assert Mia::CrisisBoundary.matches?(text), text
    end
  end

  test "bounded medicine money burden and travel stay outside the outage floor" do
    ORDINARY.each do |text|
      refute Mia::CrisisBoundary.explicit?(text), text
      refute Mia::CrisisBoundary.soft?(text), text
      refute Mia::CrisisBoundary.hopeless?(text), text
    end
  end

  test "conditional fee idiom is not immediate" do
    refute Mia::CrisisBoundary.explicit?("if i see one more fee im gonna die lol")
  end

  test "reader cache squishes and carries context on its first call" do
    calls = []
    result = Object.new
    with_method(HouseholdFinance::ParticipantMessageReader, :call, ->(**options) { calls << options; result }) do
      assert_same result, HouseholdFinance::ParticipantMessageReader.read_once(message: "  im a burden  ", goal_conversation: true, recent_care: { care_kind: "crisis" }, setup_field: "primary_goal")
      assert_same result, HouseholdFinance::ParticipantMessageReader.read_once(message: "im a burden")
      assert_equal 1, calls.length
      assert_equal true, calls.first[:goal_conversation]
      assert_equal "primary_goal", calls.first[:setup_field]
    end
  end
end
