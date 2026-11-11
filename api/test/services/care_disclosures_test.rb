require "test_helper"

class CareDisclosuresTest < ActiveSupport::TestCase
  test "first means plan and intent survive sixty two turns even when hardship came first" do
    contents = [ "Rent is late.", "I have a gun in my room.", "I want to die.", "I plan to act at 9 tonight." ] + Array.new(58) { |i| "Still here #{i}." }
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
