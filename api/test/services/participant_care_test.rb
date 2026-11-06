require "test_helper"

class ParticipantCareTest < ActiveSupport::TestCase
  test "outage food loss in casual grammar keeps food help without guessing contacts" do
    text = "kids didnt eat today, we out of food money"
    assert_equal :food, HouseholdFinance::ParticipantCare.kind(text)
    assert_match(/getting food today/, HouseholdFinance::ParticipantCare.answer(text))
    assert_match(/getting food today/, HouseholdFinance::ParticipantCare.answer("we have no grocery money", care: :food))
    refute HouseholdFinance::ParticipantCare.kind("what if we out of food money")
  end

  test "explicit financial questions do not carry the reader's prior care label" do
    [ "how much is left", "can i buy shoes", "what is my balance", "how much have i saved", "hows my plan looking?", "which bill comes next" ].each do |text|
      assert_nil HouseholdFinance::ParticipantCare.reader_context(text, "grief"), text
    end
    assert_equal "grief", HouseholdFinance::ParticipantCare.reader_context("i feel completely lost", "grief")
  end

  test "care continuity keeps uncertainty but releases explicit money questions" do
    %w[idk yeah ok].push("thanks mia", "sounds good", "i just dunno", "ok thanks. what do i do first", "i cant think straight").each do |text|
      assert HouseholdFinance::ParticipantCare.followup?(text), text
    end
    [ "how much is left", "can i buy 40 shoes", "what did i spend" ].each do |text|
      refute HouseholdFinance::ParticipantCare.followup?(text), text
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
