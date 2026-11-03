require "test_helper"

class FinancialDocumentsMerchantNormalizerTest < ActiveSupport::TestCase
  test "bank descriptors and card masks group known merchants without changing unrelated names" do
    { "POS DEBIT 1234 ROSS STORES #567 XXXX1234" => "Ross", "Ross Dress for Less Tamuning" => "Ross",
      "POS PURCHASE KMART #101 ****1234" => "Kmart", "Rosslyn Cafe" => "Rosslyn Cafe",
      "Crossroads Market" => "Crossroads Market", "ACH CREDIT PAYROLL" => "ACH CREDIT PAYROLL" }.each do |source, expected|
      assert_equal expected, FinancialDocuments::MerchantNormalizer.call(source)
    end
    assert_nil FinancialDocuments::MerchantNormalizer.call(nil)
  end
end
