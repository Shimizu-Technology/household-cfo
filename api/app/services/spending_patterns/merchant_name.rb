module SpendingPatterns
  # Coaching labels only. Statement review retains the participant's full descriptor.
  module MerchantName
    # Bank wording around the store name: "Purchase authorized on 10/14 …", "Recurring Payment: …".
    BANK_PREFIX = %r{\A(?:(?:recurring\s+payment|purchase(?:\s+with\s+cash\s+back\s+\$[\d.,]+)?|money\s+transfer|non-wf\s+atm\s+withdrawal)\s+authorized\s+on\s+\d{1,2}/\d{1,2}\s+|(?:purchase|recurring\s+payment|pos|purchase\s+return)\s*:\s*)}i
    # Card and reference tails: " S*····4410 Card 7302", " on 09/10 Ref # Demo1A2B3C4D".
    CARD_TAIL = /\s+[A-Z]\*\s*[·•*xX]*\d{2,}.*\z/
    REFERENCE_TAIL = %r{\s+on\s+\d{1,2}/\d{1,2}\s+ref\s*#.*\z}i
    # Trailing place and phone words: "Tamuning Gum", "Hagatna GU", "650-····1111 CA", ", NY".
    # A state code counts as a place only with context: after a comma, a Guam town or a phone number.
    # "Northstar IT" and "Northstar CA" keep their letters.
    STATE = /(?-i:#{FinancialDocuments::MerchantNormalizer::REGION.source})/
    GUAM = FinancialDocuments::MerchantNormalizer::GUAM_LOCATION
    PLACE_TAIL = /(?:,\s*#{STATE}|\s+#{GUAM}\s+#{STATE}|\s+(?:#{GUAM}|Gum|GU)|(?<=\d)\s+#{STATE}|\s+\d{3}-[\d·•*xX-]+)\z/
    STORE_NUMBER = /(?:\s+(?:store\s*)?\#\s*\d+|\s+(?:store\s*(?:no\.?|number)?\s*)?\d{3,})\z/i

    # Refund matching keeps the narrower label it has always used, so wider coaching labels never widen a refund match.
    def self.matching_label(value)
      full = FinancialDocuments::MerchantNormalizer.call(value)
      return full if full.blank?
      short = full.gsub(/\([^)]*\)/, " ").split(" - ", 2).first.to_s.squish.sub(STORE_NUMBER, "").squish
      short.presence || full
    end

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
      # Known stores read the same however the bank wrote them ("ROSS DRESS FOR LESS #123" is Ross).
      FinancialDocuments::MerchantNormalizer.known_merchant(short.presence || full) || short.presence || full
    end
  end
end
