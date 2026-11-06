require "test_helper"

class ParticipantCareTest < ActiveSupport::TestCase
  test "outage food loss in casual grammar keeps food help without guessing contacts" do
    text = "kids didnt eat today, we out of food money"
    assert_equal :food, HouseholdFinance::ParticipantCare.kind(text)
    assert_equal :food, HouseholdFinance::ParticipantCare.kind("we out of food money and the kids didnt eat")
    assert_match(/getting food today/, HouseholdFinance::ParticipantCare.answer(text))
    assert_match(/getting food today/, HouseholdFinance::ParticipantCare.answer("we have no grocery money", care: :food))
    refute HouseholdFinance::ParticipantCare.kind("what if we out of food money")
    refute HouseholdFinance::ParticipantCare.kind("we have no food allergies")
    refute HouseholdFinance::ParticipantCare.kind("what if payday is late, we out of food money")
  end

  test "care history restricts scenario sources without classifying followup words" do
    history = [ { role: "user", content: "my mom died and the funeral was 2500" } ]
    assert HouseholdFinance::ParticipantCare.scenario_current_only?(history: history)
    [ "how", "how?", "what?", "why", "?", "something wholly different" ].each do |text|
      refute HouseholdFinance::ParticipantCare.purchase_reference_current?(text, "So a $2,500 funeral would leave $20"), text
    end
    assert HouseholdFinance::ParticipantCare.purchase_reference_current?("can i buy $40 shoes", "So a $40 shoes would leave $20")
  end

  test "food floor does not mistake budget questions or zero expenses for hunger" do
    [ "We have no food expenses this week. Can I buy a $300 TV?", "can you help with food budget", "help with food budget for xmas", "i cant afford rent in tumon so we moved" ].each do |text|
      assert_nil HouseholdFinance::ParticipantCare.kind(text), text
    end
  end

  test "outage grief floor covers burial without matching hypothetical or objects" do
    assert_equal :grief, HouseholdFinance::ParticipantCare.kind("we buried my husband on tuesday and the funeral cost 2500")
    [ "what if we buried my husband", "we buried the cable", "my husband isn't dead" ].each do |text|
      refute HouseholdFinance::ParticipantCare.kind(text), text
    end
  end

  test "food and rent practical questions get relevant guarded help" do
    assert_match(/food.*coach/i, HouseholdFinance::ParticipantCare.answer("do yall know anywhere that can help w food", care: :hardship))
    assert_match(/landlord/i, HouseholdFinance::ParticipantCare.answer("what if i cant make rent in december", care: :hardship))
  end

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
