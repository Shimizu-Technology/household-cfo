require "test_helper"

class FinancialDocumentsMerchantNormalizerTest < ActiveSupport::TestCase
  test "state suffixes do not merge unrelated Ross businesses" do
    [ "Ross and Sons CA", "Ross Electric Co HI", "Kmart Service Center CA" ].each do |name|
      assert_equal name, FinancialDocuments::MerchantNormalizer.call(name)
    end
    [ "Ross Dededo GU", "Ross Stores Hagåtña GU", "Ross Dress for Less Honolulu HI" ].each do |name|
      assert_equal "Ross", FinancialDocuments::MerchantNormalizer.call(name)
    end
  end

  test "bank descriptors and card masks group known merchants without changing unrelated names" do
    { "POS DEBIT 1234 ROSS STORES #567 XXXX1234" => "Ross", "Ross Dress for Less Tamuning" => "Ross",
      "POS PURCHASE KMART #101 ****1234" => "Kmart", "Rosslyn Cafe" => "Rosslyn Cafe",
      "Crossroads Market" => "Crossroads Market", "ACH CREDIT PAYROLL" => "ACH CREDIT PAYROLL",
      "ROSS DRESS FOR LESS #123 DEDEDO GU" => "Ross", "ROSS STORES #456 HAGATNA GU" => "Ross",
      "ROSS DRESS FOR LESS #123 HONOLULU HI" => "Ross", "KMART #101 SAN DIEGO CA" => "KMART #101 SAN DIEGO CA",
      "Kmart Yigo" => "Kmart", "CARD PURCHASE 1776 COFFEE" => "1776 COFFEE",
      "POS DEBIT 1776 COFFEE" => "1776 COFFEE", "DEBIT CARD 1776 COFFEE" => "1776 COFFEE",
      "1776 ROSS STORES" => "1776 ROSS STORES", "CARD PURCHASE 1234 ROSS STORES #567" => "Ross",
      "CARD PURCHASE 1234 ROSSLYN CAFE" => "1234 ROSSLYN CAFE", "Ross and Sons" => "Ross and Sons",
      "CARD PURCHASE 1776 ROSS COFFEE" => "1776 ROSS COFFEE", "POS DEBIT 1776 ROSS AND SONS" => "1776 ROSS AND SONS" }.each do |source, expected|
      assert_equal expected, FinancialDocuments::MerchantNormalizer.call(source)
    end
    assert_nil FinancialDocuments::MerchantNormalizer.call(nil)
  end

  test "long account numbers are hidden for display and known merchants still group around store numbers" do
    { "Coast360 transfer to own savings 00002468" => "Coast360 transfer to own savings ····2468", "Visa card payment 00009900" => "Visa card payment ····9900",
      "Transfer to 1234567890 savings" => "Transfer to ····7890 savings", "Check 1234" => "Check 1234", "Invoice $1234567.89" => "Invoice $1234567.89",
      "Paid 1,234,567 yen" => "Paid 1,234,567 yen", "Ross # 123456 Dededo GU" => "Ross", "Transfer to ****2468" => "Transfer to" }.each do |source, expected|
      assert_equal expected, FinancialDocuments::MerchantNormalizer.call(source), source
    end
    assert_equal "Account ····2468 and ····9900", FinancialDocuments::AccountNumberMask.display("Account XXXX 2468 and 00009900")
    assert_equal "Pay ****5678", FinancialDocuments::AccountNumberMask.call("Pay 12345678", min_digits: 8, marker: "****")
  end
end
