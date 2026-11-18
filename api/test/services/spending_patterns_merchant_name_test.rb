require "test_helper"

class SpendingPatternsMerchantNameTest < ActiveSupport::TestCase
  test "coaching labels drop bank wording, card tails, references and places" do
    {
      "Purchase authorized on 10/14 Dr Shiehs Clinic Tamuning Gum S*····5237 Card 1150" => "Dr Shiehs Clinic",
      "Purchase authorized on 12/06 Island Girl Coffee Barrigada Gum S*····2895 Card 1150" => "Island Girl Coffee",
      "Purchase authorized on 12/07 Island Girl Coffee Barrigada Gum S*····9956 Card 1150" => "Island Girl Coffee",
      "Recurring Payment authorized on 09/08 Google Youtubeprem 650-····0000 CA S*····3903 Card 1150" => "Google Youtubeprem",
      "Zelle to Shimizu Kami on 09/10 Ref # Wfct22MR7Gpl" => "Zelle to Shimizu Kami",
      "Purchase: Super Happy Mart Barrigada Gum" => "Super Happy Mart",
      "Purchase authorized on 12/03 Mobil Barrigada HI Barrigada Gum S*····5647 Card 1150" => "Mobil",
      "Payless Sprmkts Oka Tamuning GU" => "Payless Sprmkts Oka",
      "OPENROUTER, INC OPENROUTER.AI, NY" => "OPENROUTER, INC OPENROUTER.AI",
      "Ross Store #497 Tamuning" => "Ross",
      "1776 Coffee" => "1776 Coffee",
      "Guam Premier Outlets" => "Guam Premier Outlets"
    }.each do |raw, label|
      assert_equal label, SpendingPatterns::MerchantName.call(raw), raw
    end
  end
end
