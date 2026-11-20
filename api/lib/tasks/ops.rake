namespace :ops do
  desc "Count possible double-counted purchases for HOUSEHOLD_ID (read-only; counts only)"
  task double_counted_purchases: :environment do
    id = ENV["HOUSEHOLD_ID"].to_s
    abort "HOUSEHOLD_ID is required" unless id.match?(/\A[1-9]\d*\z/)
    household = Household.find_by(id: id)
    abort "Household not found" unless household
    puts JSON.generate(FinancialDocuments::SourceReview::DoubleCountedPurchases.call(household))
  end
end
