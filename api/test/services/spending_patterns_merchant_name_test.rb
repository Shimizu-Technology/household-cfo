require "test_helper"

class SpendingPatternsMerchantNameTest < ActiveSupport::TestCase
  test "coaching labels drop bank wording, card tails, references and places" do
    {
      "Purchase authorized on 10/14 Harbor Family Clinic Tamuning Gum S*····4410 Card 7302" => "Harbor Family Clinic",
      "Purchase authorized on 12/06 Reef Coffee Co Barrigada Gum S*····1186 Card 7302" => "Reef Coffee Co",
      "Purchase authorized on 12/07 Reef Coffee Co Barrigada Gum S*····2271 Card 7302" => "Reef Coffee Co",
      "Recurring Payment authorized on 09/08 Google Youtubeprem 650-····1111 CA S*····7788 Card 7302" => "Google Youtubeprem",
      "Zelle to Reyes Ana on 09/10 Ref # Demo1A2B3C4D" => "Zelle to Reyes Ana",
      "Purchase: Tasi Mart Barrigada Gum" => "Tasi Mart",
      "Purchase authorized on 12/03 Mobil Barrigada HI Barrigada Gum S*····3352 Card 7302" => "Mobil",
      "Payless Sprmkts Oka Tamuning GU" => "Payless Sprmkts Oka",
      "OPENROUTER, INC OPENROUTER.AI, NY" => "OPENROUTER, INC",
      "Render.Com Render.Com CA" => "Render.Com",
      "Openai *Chatgpt Su Openai.Com CA" => "Openai *Chatgpt Su",
      "Intuit *Qbooks Onl Cl.Intuit.Com CA" => "Intuit *Qbooks Onl",
      "Amazon.com" => "Amazon.com",
      "Ross Store #497 Tamuning" => "Ross",
      "1776 Coffee" => "1776 Coffee",
      "Guam Premier Outlets" => "Guam Premier Outlets",
      "Northstar IT" => "Northstar IT",
      "Northstar CA" => "Northstar CA",
      "NORTHSTAR SUPPLY, CA" => "NORTHSTAR SUPPLY",
      "Purchase authorized on 10/14 ROSS DRESS FOR LESS #123" => "Ross"
    }.each do |raw, label|
      assert_equal label, SpendingPatterns::MerchantName.call(raw), raw
    end
  end
end
