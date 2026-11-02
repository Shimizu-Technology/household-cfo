# frozen_string_literal: true

module FinancialDocuments
  # Display/grouping only: retain the original descriptor as source evidence.
  # Known aliases are anchored after removing bank/card boilerplate, so a store
  # whose name merely contains Ross (for example Rosslyn Cafe) is not renamed.
  module MerchantNormalizer
    module_function

    def call(value)
      text = value.to_s.unicode_normalize(:nfkc).squish
      text = text.sub(/\A(?:POS\s+(?:DEBIT|PURCHASE)|DEBIT\s+CARD|CARD\s+PURCHASE)\s+(?:\d{4}\s+)?/i, "")
        .gsub(/\b(?:XXXX|\*{4})\s*\d{4}\b/i, "").squish
      return "Ross" if text.match?(/\ARoss(?:\s+Stores|\s+Dress for Less)?(?:\s*#\s*\d+)?(?:\s+(?:Tamuning|Guam))?\z/i)
      return "Kmart" if text.match?(/\AKmart(?:\s*#\s*\d+)?(?:\s+(?:Tamuning|Guam))?\z/i)
      text.presence || value.to_s.squish
    rescue ArgumentError, Encoding::CompatibilityError
      value.to_s
    end
  end
end
