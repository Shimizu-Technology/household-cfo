require "test_helper"

class CareDisclosuresTest < ActiveSupport::TestCase
  test "first means plan and intent survive sixty two turns even when hardship came first" do
    contents = [ "Rent is due today.", "I have a gun in my room.", "I want to die.", "I plan to act at 9 tonight." ] + Array.new(58) { |i| "Still here #{i}." }
    topic = HouseholdFinance::CareDisclosures.bound_topic("disclosures" => contents.map { |text| { "content" => text } })
    assert_equal 12, topic["disclosures"].size
    contents.first(4).each { |fact| assert_includes topic.to_json, fact }
    assert_includes topic.to_json, "Still here 57"
  end

  test "a safety fact after long unicode filler is kept within the per-entry byte cap" do
    text = ("🌺 " * 800) + "I have a gun in my room and plan to act at 9 tonight."
    content = HouseholdFinance::CareDisclosures.content(text)
    assert content.valid_encoding?
    assert_operator content.bytesize, :<=, HouseholdFinance::CareDisclosures::ENTRY_BYTES
    assert_includes content, "gun in my room"
    assert_includes content, "9 tonight"
  end
end

class CareDisclosuresTest
  test "first three episode turns and expanded means vocabulary survive repeated bounding" do
    [ "I've been saving up my meds for this.", "I'll drive off the cliff at Two Lovers Point.", "I have medications.", "I'm on a bridge.", "I have knives and rope." ].each do |means|
      contents = [ "I want to end it all.", "My friend is here.", "I don't know what to say.", means ]
      topic = { "disclosures" => [] }
      (contents + Array.new(30) { |i| "Still here #{i}." }).each do |text|
        topic = HouseholdFinance::CareDisclosures.bound_topic(topic.merge("disclosures" => topic["disclosures"] + [ { "content" => text } ]))
      end
      contents.each { |text| assert_includes topic.to_json, text }
      assert_equal 12, topic["disclosures"].size
      assert_operator topic.to_json.bytesize, :<, 6_000
    end
  end
end

class CareDisclosuresTest
  test "each category survives a long intent sentence before separate means and timing" do
    text = "I want to die " + ("because everything feels impossible " * 11) + ". I have a gun. I plan to act at 9 tonight."
    bounded = HouseholdFinance::CareDisclosures.content(text)
    assert_operator bounded.bytesize, :<=, 400
    %w[die gun].each { |word| assert_includes bounded, word }
    assert_includes bounded, "9 tonight"
  end

  test "earlier hardship never displaces later distinct safety facts" do
    [ [ "My car broke down.", "Rent is due tomorrow.", "I'm worried.", "I want to die.", "I have a gun.", "I plan to act at 9 tonight." ],
      [ "I want to end it all.", "idk", "I don't know", "My truck broke down too", "I've been saving up my meds for this." ] ].each do |episode|
      topic = { "disclosures" => [] }
      (episode + Array.new(30) { |i| "Still here #{i}" }).each do |content|
        topic = HouseholdFinance::CareDisclosures.bound_topic(topic.merge("disclosures" => topic["disclosures"] + [ { "content" => content } ]))
      end
      episode.select { |text| text.match?(/die|gun|9 tonight|meds|end it all/) }.each { |fact| assert_includes topic.to_json, fact }
      assert_operator topic["disclosures"].size, :<=, 12
    end
    refute HouseholdFinance::CareDisclosures.means?("My truck broke down")
    refute HouseholdFinance::CareDisclosures.safety_fact?("Rent is due tomorrow")
  end
  test "vehicle means near intent also receive excerpt space in oversized text" do
    text = ("Ordinary details. " * 100) + "I'll drive my truck to end my life tonight."
    bounded = HouseholdFinance::CareDisclosures.content(text)
    assert_includes bounded, "drive"
    assert_includes bounded, "truck"
    assert_includes bounded, "end my life"
    assert_operator bounded.bytesize, :<=, 400
  end
end
