require "test_helper"

class ParticipantCareTest < ActiveSupport::TestCase
  test "outage care floor accepts only exact events without broad inference" do
    { "My sister died this weekend" => :grief,
      "My employer fired me today" => :job_loss, "I lost my job last week" => :job_loss,
      "We are about to be evicted" => :housing }.each do |text, expected|
      assert_equal expected, HouseholdFinance::ParticipantCare.kind(text), text
      assert_includes HouseholdFinance::ParticipantCare.answer(text), "when you're ready"
      assert_equal :hardship, HouseholdFinance::MiaCoachAnswerer.routing_priority(text)
    end
    [ "We are grieving after a death in our family", "My phone died", "What if my partner died?", "My dad has not passed away", "I lost my wallet",
      "I lost my job last year", "We are not going to be evicted", "Our car battery is dead" ].each do |text|
      assert_nil HouseholdFinance::ParticipantCare.kind(text), text
    end
  end
end
