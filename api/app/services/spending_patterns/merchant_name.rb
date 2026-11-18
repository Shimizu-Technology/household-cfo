module SpendingPatterns
  # Coaching labels only. Statement review retains the participant's full descriptor.
  module MerchantName
    # Bank wording around the store name: "Purchase authorized on 10/14 …", "Recurring Payment: …".
    BANK_PREFIX = %r{\A(?:(?:recurring\s+payment|purchase(?:\s+with\s+cash\s+back\s+\$[\d.,]+)?|money\s+transfer|non-wf\s+atm\s+withdrawal)\s+authorized\s+on\s+\d{1,2}/\d{1,2}\s+|(?:purchase|recurring\s+payment|pos|purchase\s+return)\s*:\s*)}i
    # Card and reference tails: " S*····5237 Card 1150", " on 09/10 Ref # Wfct22MR7Gpl".
    CARD_TAIL = /\s+[A-Z]\*\s*[·•*xX]*\d{2,}.*\z/
    REFERENCE_TAIL = %r{\s+on\s+\d{1,2}/\d{1,2}\s+ref\s*#.*\z}i
    # Trailing place and phone words: "Tamuning Gum", "Hagatna GU", "650-····0000 CA", ", NY".
    PLACE_TAIL = /(?:,?\s+(?:#{FinancialDocuments::MerchantNormalizer::GUAM_LOCATION}|Gum|GU|[A-Z]{2}|\d{3}-[\d·•*xX-]+))\z/
    STORE_NUMBER = /(?:\s+(?:store\s*)?\#\s*\d+|\s+(?:store\s*(?:no\.?|number)?\s*)?\d{3,})\z/i

    def self.call(value)
      full = FinancialDocuments::MerchantNormalizer.call(value)
      return full if full.blank?
      short = full.sub(BANK_PREFIX, "").sub(CARD_TAIL, "").sub(REFERENCE_TAIL, "").squish
      short = short.gsub(/\([^)]*\)/, " ").split(" - ", 2).first.to_s.squish.sub(STORE_NUMBER, "").squish
      4.times do
        trimmed = short.sub(PLACE_TAIL, "").sub(STORE_NUMBER, "").squish
        break if trimmed == short || trimmed.blank?
        short = trimmed
      end
      short.presence || full
    end
  end
end
