require "test_helper"

class FinancialDocumentsAccountNumberMaskTest < ActiveSupport::TestCase
  test "stored statement text masks long account numbers but never part of a money amount" do
    mask = FinancialDocuments::AccountNumberMask
    assert_equal "Ross order $123456789.90", mask.stored("Ross order $123456789.90")
    assert_equal "Total 12345678.90", mask.stored("Total 12345678.90")
    assert_equal "Acct ACCT.****9012", mask.stored("Acct ACCT.123456789012")
    assert_equal "ANN,****1234", mask.stored("ANN,6715551234")
  end
end
