module SpendingPatterns
  # Coaching labels only. Statement review retains the participant's full descriptor.
  module MerchantName
    def self.call(value)
      full = FinancialDocuments::MerchantNormalizer.call(value)
      return full if full.blank?
      short = full.gsub(/\([^)]*\)/, " ").split(" - ", 2).first.to_s.squish
        .sub(/(?:\s+(?:store\s*)?\#\s*\d+|\s+(?:store\s*(?:no\.?|number)?\s*)?\d{3,})\z/i, "").squish
      short.presence || full
    end
  end
end
