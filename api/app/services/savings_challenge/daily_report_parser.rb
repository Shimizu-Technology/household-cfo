module SavingsChallenge
  # The challenge adds its enrollment calendar to the purchase reader shared
  # with household Mia. This produces review input only, never saved purchases.
  class DailyReportParser < HouseholdFinance::PurchaseReportParser
  end
end
